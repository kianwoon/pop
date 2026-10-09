import AppKit
import Foundation

/// RAISES A BURIED BROWSER TAB — the missing driver.
///
/// Pop can PERCEIVE only the VISIBLE content of on-screen browser windows
/// (`screen_read`, via ScreenCaptureKit). A tab that is behind another tab, a
/// window on another Space, or a minimized window is invisible to it, and the
/// only acting tools before this one were `browser_open_url`/`ui_click`/
/// `ui_type`. None of them can BRING a specific existing tab to the front.
///
/// This is that driver, and it is deliberately DETERMINISTIC: it asks the
/// browser's own AppleScript dictionary which windows and tabs exist, matches
/// on URL/title text, and asks the browser to select the tab and raise its
/// window. There is no pixel guessing and no coordinate arithmetic.
///
/// Guards, all in code and none model-dependent:
///  * AUTONOMOUS NAVIGATION. The tool is `.localNav`, so it runs with no
///    approval card; every action is logged. It never closes, navigates or
///    edits anything.
///  * ONLY ALLOWLISTED BROWSERS. The addressable set is `ScreenOCR`'s browser
///    allowlist — the same session detail, no second list to drift.
///  * THE QUERY IS THE ONLY INTERPOLATED TEXT, escaped for an AppleScript
///    string literal. Nothing else the model said reaches the script; the
///    bundle id is interpolated only after an exact allowlist match.
///  * HONEST RESULTS ONLY. A raised tab is reported from what the AppleScript
///    itself returned; a missing tab, a stopped browser and a denied
///    Automation grant are each reported as exactly that, with nothing changed.
///
/// No site, task or page name lives here: the run is generic over whatever
/// `query` the model passed.
enum TabFocus {
    /// Longest accepted query. Bounded so a runaway string cannot become a
    /// pathological script; the model matches on a site name or URL fragment.
    static let maxQueryLength = 200

    // MARK: - Seams (nil in production)

    /// The script result channel. `nil` in production runs the real
    /// `/usr/bin/osascript`; the probe injects a canned Chromium-style output
    /// so parsing and honesty are measured WITHOUT touching a real browser.
    static var scriptRunnerOverride: (@Sendable (String) async -> ScriptOutcome)?

    /// Whether a browser is running. `nil` in production reads the real
    /// `NSRunningApplication` list; the probe injects the answer so the
    /// not-running arm does not depend on what the user has open.
    static var runningCheckerOverride: (@Sendable (String) -> Bool)?

    // MARK: - Result types

    /// What running the script produced. `output` is the script's stdout (the
    /// script returns its own verdict); `failure` is a nonzero exit — an
    /// AppleScript error, including a denied Automation grant.
    enum ScriptOutcome: Sendable, Equatable {
        case output(String)
        case failure(String)
    }

    // MARK: - Script construction

    /// Escapes the query for a double-quoted AppleScript string literal.
    ///
    /// Backslash FIRST, then quote — the reverse order would turn `\"` into
    /// `\\"` and leak the quote. Control characters (newline, tab, carriage
    /// return) are folded to spaces: a bare newline cannot appear inside an
    /// AppleScript literal, and folding keeps the script from being malformed.
    static func escapeForAppleScript(_ value: String) -> String {
        let folded = value.map { character -> Character in
            switch character {
            case "\n", "\r", "\t": return " "
            default: return character
            }
        }
        return String(folded)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Browser resolution

    /// The user's default browser, resolved the same way the system opener
    /// resolves it for `browser_open_url` — through LaunchServices' handler for
    /// https. Returns the bundle id, or nil when it cannot be determined.
    static func defaultBrowserBundleID() -> String? {
        guard let probe = URL(string: "https://example.com") else { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// An AppleScript error that means the Automation (Apple Events) TCC grant
    /// is missing or was refused, so the user gets the place to fix it rather
    /// than a raw `-1743`.
    static func looksLikeAutomationDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return message.contains("-1743")
            || lowered.contains("not authorized")
            || lowered.contains("not allowed")
            || lowered.contains("apple events")
            || lowered.contains("automation")
    }

    // MARK: - Tab enumeration + in-place navigation (tab reuse)

    /// One enumerated tab PLUS the stable locators the single-walk navigate
    /// script needs. `windowIndex`/`tabIndex` are 1-based and come from the SAME
    /// `windows → tabs` traversal the enumeration performed, so resolving a tab
    /// and navigating to it share ONE traversal — the navigate script indexes
    /// `tab t of window w` directly instead of re-walking with a counter.
    ///
    /// `active` is whether the tab is its window's active tab; `isActiveWindow`
    /// is whether its window is the frontmost (index 1 of `windows`). Both feed
    /// the selection preference (active tab of the active window wins).
    struct OpenTab: Sendable, Equatable {
        let title: String
        let url: String?
        var windowIndex: Int = 1
        var tabIndex: Int = 0
        var active: Bool = false
        var isActiveWindow: Bool = false
    }

    /// Every tab of `bundleID` as an `OpenTab` (title, url, locators, active
    /// flags). Returns `[]` when the browser is not running, the Automation grant
    /// is missing, or the reply is unreadable — the caller then falls back to
    /// `open`. Never throws.
    static func openTabs(bundleID: String) async -> [OpenTab] {
        await openTabsOutcome(bundleID: bundleID).tabs
    }

    /// `openTabs` PLUS the underlying failure, so a caller that must stay HONEST
    /// about a denied Automation grant (focus) can tell "no tabs" from "could not
    /// read". Reuse does not need the distinction — it falls through to `open`
    /// either way — so it uses the plain `openTabs`. Never throws.
    static func openTabsOutcome(bundleID: String) async -> (tabs: [OpenTab], failure: String?) {
        // Chromium and Safari differ on the active-tab property; pick the
        // spelling by bundle id (same split as `activateTab`).
        let isSafari = bundleID == "com.apple.Safari"
        let activeIndex = isSafari ? "index of (current tab of w)" : "active tab index of w"
        let script = """
        tell application id "\(bundleID)"
            set out to ""
            set wIndex to 0
            repeat with w in windows
                set wIndex to wIndex + 1
                set aIndex to \(activeIndex)
                set tIndex to 0
                repeat with t in tabs of w
                    set tIndex to tIndex + 1
                    set out to out & (title of t) & "\t" & (URL of t) & "\t" & wIndex & "\t" & tIndex & "\t" & ((tIndex = aIndex) as integer) & "\t" & ((wIndex = 1) as integer) & "\n"
                end repeat
            end repeat
            return out
        end tell
        """
        let runner = scriptRunnerOverride ?? runAppleScript
        switch await runner(script) {
        case .output(let output):
            return (parseOpenTabs(output), nil)
        case .failure(let message):
            return ([], message)
        }
    }

    /// Reads the tab list the enumeration script returned: one
    /// `title\turl\twindow\ttab\tactive\tfront` line per tab. A line without a
    /// readable URL yields `url: nil` (title only), which the reuse decision
    /// treats as no host match. Older/shorter lines degrade to defaults.
    static func parseOpenTabs(_ output: String) -> [OpenTab] {
        output.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let parts = line.components(separatedBy: "\t")
            let title = parts.first ?? ""
            let url = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            return OpenTab(
                title: title,
                url: url,
                windowIndex: parts.count > 2 ? (Int(parts[2]) ?? 1) : 1,
                tabIndex: parts.count > 3 ? (Int(parts[3]) ?? 0) : 0,
                active: parts.count > 4 && parts[4] == "1",
                isActiveWindow: parts.count > 5 && parts[5] == "1"
            )
        }
    }

    /// Raises `tab tabIndex of window windowIndex` (the locators `openTabs`
    /// returned) and, when `navigateTo` is given, sets that tab's URL first
    /// (in-place navigation). ONE `tell`, ONE traversal: the enumeration already
    /// walked windows/tabs, so this script addresses the tab by stable index —
    /// no counter re-walk, no window for the user to interact between scripts.
    ///
    /// `true` only when AppleScript itself returned `OK`; a non-allowlisted
    /// browser, a denied grant, or a vanished tab is `false` and changes nothing.
    /// Chromium and Safari differ on the active-tab property, so the spelling is
    /// chosen by bundle id; setting a tab's `URL` is shared by both.
    static func activateTab(bundleID: String, windowIndex: Int, tabIndex: Int, navigateTo: String?) async -> Bool {
        let isSafari = bundleID == "com.apple.Safari"
        let navLine = navigateTo.map { "set URL of t to \"\(escapeForAppleScript($0))\"" } ?? ""
        let selectLine = isSafari
            ? "set current tab of w to t"
            : "set active tab index of w to \(tabIndex)"
        let script = """
        tell application id "\(bundleID)"
            if (count of windows) ≥ \(windowIndex) then
                set w to window \(windowIndex)
                if (count of tabs of w) ≥ \(tabIndex) then
                    set t to tab \(tabIndex) of w
                    \(navLine)
                    \(selectLine)
                    set index of w to 1
                    activate
                    return "OK"
                end if
            end if
            return "NOMATCH"
        end tell
        """
        let runner = scriptRunnerOverride ?? runAppleScript
        guard case .output(let output) = await runner(script) else { return false }
        return output.contains("OK")
    }

    // MARK: - Run

    /// PURE selection among tabs that MATCH a focus query.
    ///
    /// THE INVARIANT: focus targets the tab the USER means. Preference order:
    /// (a) the ACTIVE tab of the ACTIVE (front) window, if it matches — what the
    /// user is looking at; (b) otherwise the EARLIEST match (enumeration order,
    /// today's behavior). WHY: with several look-alike tabs (LinkedIn feed vs
    /// notifications) a first-match walk kept raising the feed; preferring the
    /// on-screen active tab reaches the page the user is actually on. This is the
    /// SAME shape as `BrowserActions.ReuseDecision`'s active-first preference, so
    /// focus and open cannot drift. Returns nil when nothing matched.
    enum FocusPreference {
        static func pick(_ matches: [OpenTab]) -> OpenTab? {
            if let active = matches.first(where: { $0.active && $0.isActiveWindow }) {
                return active
            }
            return matches.first
        }
    }

    /// Focuses the tab matching `query` and reports exactly what happened.
    ///
    /// SELECTION reuses the SHARED tab path: `openTabsOutcome` enumerates once,
    /// the pure `FocusPreference.pick` chooses among matches (active tab of the
    /// front window first, else the earliest), and `activateTab` raises it in a
    /// single walk — the SAME enumeration + activator `browser_open_url`'s reuse
    /// uses. It reports which tab it raised (title + host), or a precise
    /// not-found, or that the browser could not be read.
    ///
    /// `browser_focus_tab` is a `.localNav` tool in `ToolRegistry.execute` —
    /// navigation-class, so it runs autonomously inside the allowlisted
    /// browsers; the permission check in `ToolRegistry` is what stands
    /// between a denied call and this function.
    static func focus(query rawQuery: String, browser: String?) async -> String {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "ERROR: `query` is empty, so no tab was searched for."
        }
        guard query.count <= maxQueryLength else {
            return "ERROR: `query` is longer than \(maxQueryLength) characters, so no tab was searched for."
        }

        let allowlisted = ScreenOCR.browserBundleIDs.sorted()
        let bundleID: String
        if let requested = browser?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard ScreenOCR.browserBundleIDs.contains(requested) else {
                return """
                    ERROR: '\(requested)' is not a browser Pop can address \
                    (allowed: \(allowlisted.joined(separator: ", "))).
                    """
            }
            bundleID = requested
        } else {
            guard let resolved = defaultBrowserBundleID() else {
                return "ERROR: could not determine your default browser, so no tab was focused."
            }
            guard ScreenOCR.browserBundleIDs.contains(resolved) else {
                return """
                    ERROR: your default browser is not one Pop can address \
                    (allowed: \(allowlisted.joined(separator: ", "))).
                    """
            }
            bundleID = resolved
        }

        let running = (runningCheckerOverride ?? isRunning)(bundleID)
        guard running else {
            return "ERROR: \(bundleID) is not running, so there is no tab to focus. Open it first."
        }

        // ONE enumeration, the SAME `OpenTab` locators the activator addresses.
        let outcome = await openTabsOutcome(bundleID: bundleID)
        if let failure = outcome.failure {
            if looksLikeAutomationDenied(failure) {
                return """
                    ERROR: Automation permission was denied, so Pop cannot \
                    control \(bundleID). Grant it in System Settings → Privacy \
                    & Security → Automation (Pop → \(bundleID)), then ask again.
                    """
            }
            return "ERROR: could not read \(bundleID)'s tabs: \(failure)"
        }

        let needle = query.lowercased()
        let matches = outcome.tabs.filter { tab in
            tab.title.lowercased().contains(needle)
                || (tab.url?.lowercased().contains(needle) ?? false)
        }
        guard let chosen = FocusPreference.pick(matches) else {
            print("UI_ACTION focus_tab query=\(query) found=none")
            fflush(stdout)
            return "no tab matching \"\(query)\" is open in \(bundleID); nothing was changed."
        }

        let host = chosen.url.flatMap { URL(string: $0)?.host } ?? "unknown host"
        let raised = await activateTab(
            bundleID: bundleID,
            windowIndex: chosen.windowIndex,
            tabIndex: chosen.tabIndex,
            navigateTo: nil
        )
        guard raised else {
            print("UI_ACTION focus_tab query=\(query) found=\(chosen.windowIndex):\(chosen.tabIndex) raise-failed")
            fflush(stdout)
            return """
                found a matching tab ("\(chosen.title)") but could not raise it — \
                it may have closed, or Automation permission was denied; nothing was changed.
                """
        }
        print("UI_ACTION focus_tab query=\(query) found=\(chosen.windowIndex):\(chosen.tabIndex)")
        fflush(stdout)
        return """
            focus_tab: raised window \(chosen.windowIndex), tab \(chosen.tabIndex) — \
            "\(chosen.title)" (\(host)) in \(bundleID). Use `screen_read` to verify it is \
            now visible.
            """
    }

    /// The real driver: `/usr/bin/osascript -e <script>`. Arguments are passed
    /// directly (no shell), so the only thing that can reach AppleScript is the
    /// already-escaped script text.
    static func runAppleScript(_ script: String) async -> ScriptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure("could not run osascript: \(error.localizedDescription)")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message?.isEmpty == false ? message! : "osascript exited with status \(process.terminationStatus).")
        }
        return .output(String(data: outData, encoding: .utf8) ?? "")
    }
}
