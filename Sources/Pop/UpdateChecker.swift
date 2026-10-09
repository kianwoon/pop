import AppKit
import Foundation

/// In-app update flow: check GitHub for a newer release, and — only with the
/// user's explicit consent — download it, MOVE the running bundle aside, drop
/// the new one in its place, and relaunch.
///
/// INVARIANT: every update decision flows through ONE check → compare → prompt
/// pipeline, and the only version truth is the shipped Info.plist (itself built
/// from the repo-root VERSION file). A failed check is never load-bearing: it
/// reports a human line and alerts nobody.
@MainActor
enum UpdateChecker {
    /// Public, unauthenticated latest-release endpoint.
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/kianwoon/pop/releases/latest"
    )!

    /// The shipped version, read once from the Info.plist. Unbundled dev runs
    /// (no Info.plist) fall back to "0.0" so a comparison is still well-defined
    /// rather than a crash or an empty string.
    static func currentVersion() -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty {
            return v
        }
        return "0.0"
    }

    /// A resolved release: the tag as GitHub writes it, the bare version the
    /// comparison uses, and the exact asset URL to download.
    struct Release: Sendable {
        let tag: String
        let version: String
        let zipURL: URL
    }

    /// The ONE check result. `available` carries the whole `Release` so the
    /// caller that shows the install button has the URL it must download.
    enum CheckResult {
        case upToDate(current: String)
        case available(Release, current: String)
        case failed(reason: String)
    }

    /// Typed update failures. LocalizedError so `\(error)` reads as a reason the
    /// user can act on, never a raw enum dump.
    enum UpdateError: LocalizedError {
        case http(Int)
        case badPayload
        case noAsset
        case unzipFailed
        case newBundleInvalid

        var errorDescription: String? {
            switch self {
            case .http(let code): return "GitHub returned HTTP \(code)"
            case .badPayload: return "unexpected release payload"
            case .noAsset: return "release has no .zip asset"
            case .unzipFailed: return "could not unpack the downloaded archive"
            case .newBundleInvalid: return "the downloaded bundle is not a valid Pop.app"
            }
        }
    }

    /// Strips a leading `v`/`V`. Both `v1.0` and a bare `1.0` tag normalise to
    /// the same comparable version.
    static func normalized(_ tag: String) -> String {
        if tag.hasPrefix("v") || tag.hasPrefix("V") { return String(tag.dropFirst()) }
        return tag
    }

    /// Numeric, component-wise comparison. Shorter versions pad with zeros
    /// (`1.0` == `1.0.0`). A non-numeric component makes the whole comparison
    /// FALSE — never prompt on garbage.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".", omittingEmptySubsequences: false)
        let b = current.split(separator: ".", omittingEmptySubsequences: false)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? String(a[i]) : "0"
            let y = i < b.count ? String(b[i]) : "0"
            guard let xi = Int(x), let yi = Int(y) else { return false }
            if xi != yi { return xi > yi }
        }
        return false
    }

    /// Fetches and parses the latest release. First `.zip` asset wins (not a
    /// hardcoded name), so an asset rename does not break the updater.
    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let assets = root["assets"] as? [[String: Any]],
              let asset = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".zip") == true
              }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString) else {
            throw UpdateError.badPayload
        }
        return Release(tag: tag, version: normalized(tag), zipURL: url)
    }

    /// The single check→compare step, with the house trace line. Both the manual
    /// button and the auto launch check call THIS; the only difference is what
    /// they do with the result.
    static func check() async -> CheckResult {
        let current = currentVersion()
        do {
            let release = try await latestRelease()
            if isNewer(release.version, than: current) {
                log("UPDATE_CHECK current=\(current) latest=\(release.version) outcome=available")
                return .available(release, current: current)
            }
            log("UPDATE_CHECK current=\(current) latest=\(release.version) outcome=up-to-date")
            return .upToDate(current: current)
        } catch {
            log("UPDATE_CHECK current=\(current) outcome=failed reason=\(error)")
            return .failed(reason: "\(error)")
        }
    }

    /// Human one-liner for the check, for callers that only want text.
    static func checkForUpdate() async -> String {
        switch await check() {
        case .upToDate(let current):
            return "You're up to date (version \(current))."
        case .available(let release, let current):
            return "Update available: \(release.tag) (you have \(current))."
        case .failed(let reason):
            return "Could not check for updates: \(reason)."
        }
    }

    /// Downloads `zipURL`, unpacks it, and swaps it in for the RUNNING bundle.
    ///
    /// ORDER IS THE SAFETY PROPERTY: the new `Pop.app` is fully unpacked and
    /// verified BEFORE the old bundle is touched, and the old bundle is MOVED
    /// ASIDE (`<path>.old`), never deleted — the running executable stays mapped
    /// until its replacement is in place. If the move-in fails, the old bundle
    /// is moved back, so a failed swap is a no-op rather than a brick.
    static func downloadAndRelaunch(zipURL: URL, tag: String) async throws {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        // A scratch dir on the SAME volume as the bundle, so the swap is an
        // atomic rename rather than a cross-volume copy.
        let workDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: bundleURL,
            create: true
        )

        let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        let zipPath = workDir.appendingPathComponent("release.zip")
        try? fm.removeItem(at: zipPath)
        try fm.moveItem(at: downloaded, to: zipPath)

        let extractDir = workDir.appendingPathComponent("extract")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        guard try runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path]) == 0 else {
            throw UpdateError.unzipFailed
        }

        let newBundle = extractDir.appendingPathComponent("Pop.app")
        let newBinary = newBundle.appendingPathComponent("Contents/MacOS/Pop")
        guard fm.isExecutableFile(atPath: newBinary.path) else {
            throw UpdateError.newBundleInvalid
        }

        // Both moves share a volume. Clear any stale swap leftover first so the
        // rename target is free.
        let oldBundle = bundleURL.appendingPathExtension("old")
        try? fm.removeItem(at: oldBundle)
        try fm.moveItem(at: bundleURL, to: oldBundle)
        do {
            try fm.moveItem(at: newBundle, to: bundleURL)
        } catch {
            // Restore the original: the user must never be left with no app.
            try? fm.moveItem(at: oldBundle, to: bundleURL)
            throw error
        }

        try? fm.removeItem(at: workDir)
        log("UPDATE_INSTALLED tag=\(tag)")
        // Launch the new copy and retire this process. The short delay lets the
        // trace flush before the relaunch.
        _ = try? runTool("/usr/bin/open", [bundleURL.path])
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    /// The AUTO path: check once, and ONLY when a newer release exists show a
    /// one-shot prompt. "Later" (or up-to-date / a failed check) does nothing —
    /// an update check never nags and never alerts on failure.
    static func promptAndInstallIfAvailable() async {
        guard case .available(let release, let current) = await check() else { return }
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "Pop \(release.tag) is available (you have \(current))."
        alert.addButton(withTitle: "Download and Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await downloadAndRelaunch(zipURL: release.zipURL, tag: release.tag)
        } catch {
            log("UPDATE_INSTALL_FAILED reason=\(error)")
            let fail = NSAlert()
            fail.messageText = "Update failed"
            fail.informativeText = "Could not install the update: \(error)"
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
    }

    // MARK: - Helpers

    /// Runs a tool synchronously and returns its exit status. Used for `ditto`
    /// (unpack) and `open` (relaunch) rather than reimplementing either.
    @discardableResult
    static func runTool(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func log(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
