import AppKit
import SwiftUI

/// A malformed line in the custom-headers editor.
///
/// The message quotes the offending line, which is user-typed config and not a
/// secret — but an API key must never be typed there, since this file is saved
/// in plain text.
private enum SettingsError: LocalizedError {
    case badHeader(String)

    var errorDescription: String? {
        switch self {
        case .badHeader(let line):
            return "expected \"Name: Value\", got \"\(line)\""
        }
    }
}

/// Plain settings window. Unlike the mascot and chat panel this one is allowed
/// to become key — editing a SecureField requires it.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private func makeWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pop Settings"
        // The close button must HIDE this window, not release it. Left at the
        // AppKit default of `true`, the close button freed the window while
        // `shared.window` still cached it, so every later `show()` handed back
        // the dead window and `makeKeyAndOrderFront` did nothing — the settings
        // window could never be reopened.
        window.isReleasedWhenClosed = false
        // Settings floats: it must stay visible above other apps' windows while
        // open — the user reads/edits it while working elsewhere. `.floating`
        // lifts it above every normal-level window; canJoinAllSpaces keeps it on
        // the current Space, and fullScreenAuxiliary lets it coexist with a
        // fullscreen app instead of being hidden behind one.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Size the window to what the form ACTUALLY needs. A hard-coded
        // contentRect silently clipped the top of the form once extra rows
        // were added: SwiftUI centred the overflow, so the Provider picker
        // scrolled out of view and only a sliver of it showed.
        let host = NSHostingView(rootView: SettingsForm(generation: refreshGeneration))
        window.contentView = host
        // A placeholder size first: `fittingSize` on a zero-sized hosting view
        // can settle on a degenerate width, which the min/max clamp below would
        // then lock in.
        host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.setContentSize(host.fittingSize)
        window.contentMinSize = NSSize(width: 420, height: 300)
        window.contentMaxSize = NSSize(width: 900, height: 1400)
        window.center()
        self.window = window
        return window
    }

    func show() {
        let window = makeWindow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Re-fit on every show: the form's intrinsic height changes with
        // content (permission text length, the reveal toggle row), and a stale
        // size from construction time would clip it again.
        if let host = window.contentView as? NSHostingView<SettingsForm> {
            window.setContentSize(host.fittingSize)
        }
        // THE ACCOUNT ROW MUST RE-READ ITS STATE ON EVERY SHOW. SwiftUI keeps
        // this view alive for the app's lifetime, so a `.task`/`.onAppear` that
        // ran once at construction never ran again — the row kept saying
        // "Not signed in" after the user had signed in, which was measured
        // (`SETTINGS_ROW_FLIPPED_TO_SIGNOUT=false`). Re-showing the window is
        // the moment the state can have changed, so that is when it is bumped.
        refreshGeneration.value += 1
    }

    /// Bumped on every `show()`; the form re-reads the account state whenever
    /// it changes.
    final class Generation: ObservableObject {
        @Published var value = 0
    }
    let refreshGeneration = Generation()

    /// The window itself, so a probe can measure what this screen actually
    /// shows rather than assuming a row exists because code added one.
    var windowForProbe: NSWindow? { window }
}

/// Every accessibility label under a window, walked depth-first. SwiftUI
/// publishes its text through the accessibility tree, so this is how a probe
/// sees the real rendered rows. Labels only — this is UI text, never a value
/// read out of the Keychain or a cookie store.
func accessibilityLabels(of window: NSWindow?, depth: Int = 0) -> [String] {
    guard let window, depth < 12 else { return [] }
    var found: [String] = []
    var stack: [Any] = [window.contentView].compactMap { $0 }
    while let element = stack.popLast() {
        guard let object = element as? NSObject else { continue }
        if let label = accessibilityString(object, "accessibilityLabel"),
           !label.isEmpty, !found.contains(label) {
            found.append(label)
        }
        if let children = accessibilityChildren(object) {
            stack.append(contentsOf: children)
        }
        if let view = element as? NSView {
            stack.append(contentsOf: view.subviews)
        }
    }
    return found
}

/// Swift has no bridged spelling for the accessibility accessors, so they are
/// read through the runtime. A missing selector is simply "no label", never a
/// crash and never a guess.
private func accessibilityString(_ object: NSObject, _ selector: String) -> String? {
    let sel = NSSelectorFromString(selector)
    guard object.responds(to: sel) else { return nil }
    return object.perform(sel)?.takeUnretainedValue() as? String
}

private func accessibilityChildren(_ object: NSObject) -> [Any]? {
    let sel = NSSelectorFromString("accessibilityChildren")
    guard object.responds(to: sel) else { return nil }
    return object.perform(sel)?.takeUnretainedValue() as? [Any]
}

/// The form itself. Reads config on appear and writes only on Save, so a
/// half-typed value never clobbers a working provider.
private struct SettingsForm: View {
    /// Bumped by the controller on every `show()`. Driving the account-state
    /// read off this is what keeps the row honest about the store.
    @ObservedObject var generation: SettingsWindowController.Generation
    @State private var provider = PopConfig.defaults.provider
    @State private var model = ""
    @State private var baseURL = ""
    @State private var temperature = PopConfig.defaults.temperature
    @State private var pcc = false
    @State private var allowExternalPaths = true
    /// Standing approval for reversible screen acts. Defaults ON (the user asked
    /// for end-to-end); the toggle turns it off.
    @State private var autoRunScreenActions = PopConfig.defaults.autoRunScreenActions
    /// Hover buzz: opt-in master gate and its 0...1 gain. Both persisted, and
    /// applied live on Save via `ArcBuzzSound.refreshFromConfig()`.
    @State private var buzzEnabled = PopConfig.defaults.buzzEnabled
    @State private var buzzVolume = PopConfig.defaults.buzzVolume
    /// jev advisory: optional HTTP decision service. Its bearer token lives in
    /// the Keychain (account "jev"), NEVER in config.json.
    @State private var jevEnabled = PopConfig.defaults.jevEnabled
    @State private var jevEndpoint = PopConfig.defaults.jevEndpoint
    @State private var jevModel = PopConfig.defaults.jevModel
    @State private var jevThreshold = PopConfig.defaults.jevThreshold
    @State private var jevToken = ""
    /// Whether the jev token field shows in clear. Reset on every `load()`, like
    /// the provider-key reveal.
    @State private var revealJevToken = false
    /// Existence only of the stored jev token: "present" / "not readable". Never
    /// the token itself.
    @State private var storedJevStatus = ""
    @State private var apiKey = ""
    /// Whether the key field shows the secret in clear. Never persisted, and
    /// reset on every `load()` so a revealed secret does not survive a reopen.
    @State private var revealKey = false
    /// Custom HTTP headers, one `Name: Value` per line. Never contains a key.
    @State private var headersText = ""
    @State private var status = ""
    /// Read-only existence of the stored key: "present" or the actionable
    /// "not readable" phrase. NEVER the key and never a fragment of it \u2014
    /// this string ends up on screen and in a screenshot.
    @State private var storedKeyStatus = ""
    @State private var accessibility = Permissions.accessibility().rawValue
    @State private var screenRecording = Permissions.screenRecording().rawValue
    /// Whether the shared store holds a Google account session, as the account
    /// row shows it. Cookie NAMES only — a value is a credential.
    @State private var googleSignedIn = false

    /// Update row state. NOT part of config.json: it is a live query result, not
    /// a preference, so `load()`/`save()` never touch it.
    @State private var updateChecking = false
    @State private var updateStatus = ""
    /// Set only when the last check found a newer release; its presence is what
    /// reveals the install button, and it carries the exact zip URL to fetch.
    @State private var pendingRelease: UpdateChecker.Release?

    private var providers: [String] { ["apple-fm", "openai-compat"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Regrouped into one GroupBox per subsystem so every row sits with
            // the subsystem it configures (LAYOUT ONLY — no binding, @State, or
            // save-path change). One Save below persists every group.
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provider").font(.headline)
                    Picker("", selection: $provider) {
                        ForEach(providers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    // The ids are kept raw on purpose (they are what config.json holds),
                    // so each one needs saying out loud here.
                    Text("apple-fm = Apple's on-device model (no key) · openai-compat = any OpenAI-style endpoint (needs base URL + key)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Model").font(.headline)
                    TextField("model id (blank = system default)", text: $model)
                        .textFieldStyle(.roundedBorder)

                    Text("Base URL").font(.headline)
                    // ALWAYS editable, deliberately. The provider picker governs which
                    // transport is used; it has no business deciding what the user is
                    // allowed to type. Locking this field behind a provider choice was
                    // a trap — a value typed while `apple-fm` was selected simply could
                    // not be entered at all. (The Private Cloud Compute toggle below is
                    // different: that one gates a real capability.)
                    TextField("http://127.0.0.1:18790/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)

                    Text("Temperature").font(.headline)
                    HStack {
                        Slider(value: $temperature, in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", temperature)).monospacedDigit()
                    }

                    Toggle("Private Cloud Compute", isOn: $pcc)
                        .disabled(provider != "apple-fm")

                    // Heading and toggle share a row so the control sits next to the label it
                    // affects. The toggle is pure UI state; the key itself is untouched
                    // by it and nothing here ever prints it.
                    HStack {
                        Text("API key").font(.headline)
                        Button(revealKey ? "hide" : "reveal") { revealKey.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    // Always editable: the key is written to the Keychain whatever
                    // provider is selected, so refusing to type one was purely a lock.
                    // A SecureField shows only dots, which makes a pasted key
                    // impossible to verify — hence the plain-text variant behind the
                    // same binding and the same placeholder.
                    if revealKey {
                        TextField("stored in Keychain, never in config.json", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("stored in Keychain, never in config.json", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    // WHY A KEY DISAPPEARS. Pop is certificate-signed with a PINNED
                    // designated requirement, so the code signature macOS binds to the
                    // Keychain item's ACL is stable across rebuilds. It can still stop
                    // being readable if the identity changed (a different certificate
                    // yields a different DR) or the grant was never "Always Allow". The
                    // symptom used to be a bare 401 from the endpoint; this row answers
                    // "is my key still there?" BEFORE the user ever sends anything.
                    Text(storedKeyStatus.isEmpty ? " " : "Stored key: \(storedKeyStatus)")
                        .font(.callout)
                        .foregroundStyle(storedKeyStatus == "present" ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pop is signed with a stable certificate and a pinned identity, so keychain grants survive rebuilds. If macOS asks for keychain access, choose Always Allow — once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Request headers").font(.headline)
                    Text("coding plans may require specific headers (e.g. X-Priority, User-Agent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $headersText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.4))
                        )
                    Button("coding-plan preset") {
                        headersText = PopConfig.codingPlanPreset()
                            .map { "\($0.key): \($0.value)" }
                            .sorted()
                            .joined(separator: "\n")
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("AI Provider").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    // Opt-in, DEFAULT OFF: the synthesized hum is feedback the user may
                    // not want, so silence is the resting state until they ask for it.
                    Toggle("Electric arc buzz on hover", isOn: $buzzEnabled)
                    HStack {
                        Slider(value: $buzzVolume, in: 0...1, step: 0.05)
                        Text("\(Int((buzzVolume * 100).rounded()))%").monospacedDigit()
                    }
                    Text("Plays a quiet electric-arc hum while the pointer hovers the robot. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Sound").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    // OPTIONAL and DEFAULT OFF: an advisory service the user points Pop
                    // at. It only LABELS approval cards; unreachable jev never blocks.
                    Toggle("Enable jev advisory", isOn: $jevEnabled)
                    TextField("endpoint URL", text: $jevEndpoint)
                        .textFieldStyle(.roundedBorder)
                    TextField("model id (blank = jev-latest)", text: $jevModel)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Slider(value: $jevThreshold, in: 0...1, step: 0.05)
                        Text("\(Int((jevThreshold * 100).rounded()))%").monospacedDigit()
                    }
                    // Token row, the SAME pattern as the provider key: Keychain-backed,
                    // blank means "leave the stored token alone", reveal is UI-only.
                    HStack {
                        Text("Token").font(.headline)
                        Button(revealJevToken ? "hide" : "reveal") { revealJevToken.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if revealJevToken {
                        TextField("stored in Keychain, never in config.json", text: $jevToken)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("stored in Keychain, never in config.json", text: $jevToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(storedJevStatus.isEmpty ? " " : "Stored token: \(storedJevStatus)")
                        .font(.callout)
                        .foregroundStyle(storedJevStatus == "present" ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Optional advisory service: labels approval cards with a suggestion and strength. "
                         + "Pop defines the contract: POST {goal, question, options} \u{2192} "
                         + "{choice, probabilities}. Unreachable jev never blocks anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("jev Advisory").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Accessibility")
                        Spacer()
                        Text(accessibility).foregroundStyle(accessibility == "granted" ? .green : .orange)
                        Button("Grant…") {
                            Permissions.requestAccessibility()
                            accessibility = Permissions.accessibility().rawValue
                        }
                    }
                    // Tighter than the field rows: these are status rows, not inputs,
                    // and the vertical budget is what keeps the whole form on screen.
                    .padding(.vertical, 2)

                    HStack {
                        Text("Screen Recording")
                        Spacer()
                        Text(screenRecording).foregroundStyle(screenRecording == "granted" ? .green : .orange)
                        Button("Grant…") {
                            Permissions.requestScreenRecording()
                            screenRecording = Permissions.screenRecording().rawValue
                        }
                    }
                    .padding(.vertical, 2)
                    .onAppear(perform: refreshPermissions)

                    Toggle("Allow access outside working folders", isOn: $allowExternalPaths)
                    // The one setting whose consequence is not visible from the toggle
                    // itself, so it states itself: with this on the assistant may read
                    // AND write any file on this account. The approval click still
                    // stands in front of every write — this widens the paths, not the
                    // permission.
                    Text("With this on, the assistant can read and write anywhere on this account. "
                         + "Every write and shell command still needs your approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Act without asking (auto-run screen actions)", isOn: $autoRunScreenActions)
                    Text("Pop runs screen actions (clicks, scrolling, keys, accessibility actions) "
                         + "in the apps on your screen without asking — the point/window guard is "
                         + "the safety line, even for a control whose name sounds destructive. "
                         + "File writes, shell commands, typing, and quitting apps still ask. "
                         + "You can turn this off any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Privacy & Permissions").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    // The account row. State is read from the shared persistent store
                    // by cookie NAME (SID / HSID / SSID / SAPISID / __Secure-1PAPISID);
                    // no cookie value is ever read or shown. Signing in opens a real
                    // window on screen and the user types their own credentials there —
                    // Pop reads none of them and keeps none of them.
                    HStack {
                        Text(googleSignedIn ? "Signed in" : "Not signed in")
                            .foregroundStyle(googleSignedIn ? .green : .secondary)
                        Spacer()
                        if googleSignedIn {
                            Button("Sign out") {
                                Task { @MainActor in
                                    await GoogleSignInWindowController.shared.signOut()
                                    await refreshGoogleSignIn()
                                }
                            }
                        } else {
                            Button("Sign in…") {
                                Task { @MainActor in
                                    await GoogleSignInWindowController.shared.signIn()
                                    await refreshGoogleSignIn()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    Text("Signing in opens a window where you type your credentials. Pop never sees or stores them; "
                         + "afterwards web lookups use the same browser session you signed in with.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Account").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    // The version is read live from the Info.plist (itself built from the
                    // repo-root VERSION file), never from config.json — there is one
                    // version truth and it ships in the bundle.
                    HStack {
                        Text("Version \(UpdateChecker.currentVersion())")
                        Spacer()
                        if updateChecking {
                            Text("Checking…").foregroundStyle(.secondary)
                        } else {
                            Button("Check for Updates…") { checkForUpdates() }
                        }
                    }
                    .padding(.vertical, 2)
                    if !updateStatus.isEmpty {
                        Text(updateStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Only a CONFIRMED newer release reveals this, and it installs the
                    // exact asset the check resolved — no second lookup.
                    if let release = pendingRelease {
                        Button("Download and Relaunch") {
                            Task { @MainActor in await installUpdate(release) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("App").font(.headline)
            }

            // The status line sits UNDER the button on its own row: sharing the
            // button's row let a long error string push the text out of the
            // fixed-width frame, so a save could report "saved" or a failure
            // that nobody ever saw.
            Button("Save") { save() }

            Text(status.isEmpty ? " " : status)
                .font(.callout)
                .foregroundStyle(status.hasPrefix("saved") ? .green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(20)
        // Width is a preference; HEIGHT is left to the content and the window
        // fits to it. A fixed height that the form outgrew clipped the top rows.
        .frame(minWidth: 380)
        .task(id: generation.value) {
            // State is read on APPEAR and on every RE-SHOW, which is what the
            // row needs: it must already say the truth before the user touches
            // anything, and it must not survive a sign-in that happened since.
            await refreshGoogleSignIn()
            load()
        }
    }

    /// Re-reads the account state from the shared store and refreshes the row.
    /// Called when the form appears and after the sign-in window closes, so the
    /// row can never show a state the store no longer holds.
    private func refreshGoogleSignIn() async {
        googleSignedIn = await GoogleSignIn.state() == "signed-in"
    }

    /// Existence only. Read through the SAME `KeychainStore.apiKey` call the
    /// provider uses, so the row can never disagree with the request the app
    /// actually makes \u2014 and the value is discarded the moment it is known
    /// to exist or not.
    private func refreshStoredKeyStatus() {
        let stored = KeychainStore.apiKey(for: provider)
        storedKeyStatus = (stored?.isEmpty == false) ? "present" : "not readable \u{2014} paste it again"
    }

    /// Existence only, through the SAME `KeychainStore.apiKey` call `JevBridge`
    /// uses, so the row can never disagree with the request. The value is
    /// discarded the moment it is known to exist or not \u2014 never shown.
    private func refreshStoredJevStatus() {
        let stored = KeychainStore.apiKey(for: JevBridge.tokenAccount)
        storedJevStatus = (stored?.isEmpty == false) ? "present" : "not readable \u{2014} paste it again"
    }

    /// Ad-hoc signing can reset TCC grants on every rebuild, so the rows are
    /// re-read whenever the window comes forward rather than trusted once.
    private func refreshPermissions() {
        accessibility = Permissions.accessibility().rawValue
        screenRecording = Permissions.screenRecording().rawValue
    }

    private func load() {
        // Re-hide first, before anything else can read the field: a window
        // reopened while `revealKey` was left on would otherwise show a secret
        // in clear with no action from the user.
        revealKey = false
        revealJevToken = false
        refreshStoredKeyStatus()
        refreshStoredJevStatus()
        guard let config = try? PopConfig.load() else { return }
        provider = config.provider
        model = config.model
        baseURL = config.baseURL
        temperature = config.temperature
        pcc = config.pcc
        allowExternalPaths = config.allowExternalPaths
        autoRunScreenActions = config.autoRunScreenActions
        buzzEnabled = config.buzzEnabled
        buzzVolume = config.buzzVolume
        jevEnabled = config.jevEnabled
        jevEndpoint = config.jevEndpoint
        jevModel = config.jevModel
        jevThreshold = config.jevThreshold
        headersText = config.headers
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        // The stored secret is never rendered back into the field; blank means
        // "leave the existing Keychain item alone".
        // Re-read after the provider is known: the Keychain account IS the
        // provider id, so the first read above could have described the
        // previous selection.
        refreshStoredKeyStatus()
    }

    /// The MANUAL update path. It shares the ONE `UpdateChecker.check()`
    /// pipeline with the auto launch check — this only adds the UI state around
    /// it. A failed check shows a line; it never alerts.
    private func checkForUpdates() {
        updateChecking = true
        updateStatus = ""
        pendingRelease = nil
        Task { @MainActor in
            let result = await UpdateChecker.check()
            updateChecking = false
            switch result {
            case .upToDate(let current):
                updateStatus = "You're up to date (version \(current))."
            case .available(let release, let current):
                updateStatus = "Update available: \(release.tag) (you have \(current))."
                pendingRelease = release
            case .failed(let reason):
                updateStatus = "Could not check for updates: \(reason)."
            }
        }
    }

    /// Installs the release the check already resolved. Success exits the
    /// process (relaunch); a failure is shown and changes nothing.
    private func installUpdate(_ release: UpdateChecker.Release) async {
        updateStatus = "Downloading and installing \(release.tag)…"
        do {
            try await UpdateChecker.downloadAndRelaunch(
                zipURL: release.zipURL,
                tag: release.tag
            )
        } catch {
            updateStatus = "Could not install the update: \(error)."
        }
    }

    /// Parses `headersText` into header pairs.
    ///
    /// One `Name: Value` per line, split on the FIRST colon so a value may
    /// itself contain colons (`User-Agent: ZCodeX-Client: ZCode`). Blank lines
    /// and `#` comments are skipped; a line with no colon at all is a typo
    /// worth reporting rather than silently dropping.
    private func parseHeaders() throws -> [String: String] {
        var result: [String: String] = [:]
        for raw in headersText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw SettingsError.badHeader(line)
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name.isEmpty || value.isEmpty {
                throw SettingsError.badHeader(line)
            }
            result[name] = value
        }
        return result
    }

    private func save() {
        var config = PopConfig.defaults
        config.provider = provider
        config.model = model
        config.baseURL = baseURL
        config.temperature = temperature
        config.pcc = pcc
        config.allowExternalPaths = allowExternalPaths
        config.autoRunScreenActions = autoRunScreenActions
        config.buzzEnabled = buzzEnabled
        config.buzzVolume = buzzVolume
        config.jevEnabled = jevEnabled
        config.jevEndpoint = jevEndpoint
        config.jevModel = jevModel
        config.jevThreshold = jevThreshold

        // Parse BEFORE writing anything: a bad header line must not leave the
        // config half-saved with the previous provider settings.
        let headers: [String: String]
        do {
            headers = try parseHeaders()
        } catch {
            status = "header parse error: \(error)"
            return
        }
        config.headers = headers

        do {
            try config.write()
        } catch {
            // Previously silent: a failed save looked identical to a successful
            // one, which is how a typed model id could vanish unnoticed.
            print("CONFIG_SAVE_FAILED \(error)")
            fflush(stdout)
            status = "config write failed: \(error.localizedDescription)"
            return
        }

        // The write succeeded, so the persisted policy is now the truth: apply
        // it LIVE. This is what stops a buzz already playing when the user
        // switches it off mid-hover, without a relaunch.
        ArcBuzzSound.shared.refreshFromConfig()

        var keychainResult = "unchanged"
        if !apiKey.isEmpty {
            defer { refreshStoredKeyStatus() }
            switch KeychainStore.setAPIKey(apiKey, for: provider) {
            case .success:
                keychainResult = "saved"
                status = "saved"
                apiKey = ""
            case .failure(let error):
                keychainResult = "failed"
                print("CONFIG_SAVED provider=\(config.provider) model=\(config.model) baseURL=\(config.baseURL) keychain=failed")
                fflush(stdout)
                status = "config saved, keychain failed: \(error)"
                return
            }
        } else {
            status = "saved"
        }

        // jev token: Keychain-only, account "jev". Blank means leave the stored
        // token alone — the same semantics as the provider key above. The token
        // is never written to config.json and never logged.
        if !jevToken.isEmpty {
            defer { refreshStoredJevStatus() }
            switch KeychainStore.setAPIKey(jevToken, for: JevBridge.tokenAccount) {
            case .success:
                jevToken = ""
            case .failure(let error):
                print("CONFIG_SAVED provider=\(config.provider) model=\(config.model) baseURL=\(config.baseURL) keychain=\(keychainResult) jev=failed")
                fflush(stdout)
                status = "config saved, jev token failed: \(error)"
                return
            }
        }

        // The config carries no secret: the API key lives in the Keychain only.
        print("CONFIG_SAVED provider=\(config.provider) model=\(config.model) baseURL=\(config.baseURL) keychain=\(keychainResult)")
        fflush(stdout)

        // Tells the panel to re-pull history under the new model.
        NotificationCenter.default.post(name: Notification.Name("popConfigChanged"), object: nil)
    }
}