import AppKit
import WebKit

/// What the page needs to draw the browser chrome and the collapsed
/// conversation strip.
struct BrowserState: Equatable {
    var active: Bool
    var url: String
    var title: String
    /// A human sentence: "loading…" or "page blocked: file:// not allowed".
    /// Failure has to be legible in the pane, not only in a tool result the
    /// model reads.
    var status: String
}

/// The in-panel browser: a SECOND `WKWebView`, independent of the chat page.
///
/// Why a second view rather than driving the chat page: the browser must be
/// VISIBLE while the tools act on it, and the conversation must stay readable
/// at the same time. One web view cannot be both a shop checkout and the
/// transcript that explains what it is doing.
///
/// Every entry point is bounded and returns text, never throws into the stream,
/// and refs (`[3] button "Submit"`) are valid only until the page changes —
/// they are re-derived from the live DOM on every read, so a stale ref fails
/// loudly instead of clicking whatever moved into that slot.
@MainActor
final class BrowserController: NSObject, WKNavigationDelegate {
    /// The tool surface talks to this instance. The panel installs it; a probe
    /// uses it directly, offscreen.
    static let shared = BrowserController()

    /// Pane height in the `full` state. The panel window size is NOT changed:
    /// the pane overlays the top of the existing web region and the page
    /// collapses its transcript to a strip underneath.
    static let paneHeight: CGFloat = 300

    /// The browser became active or idle. `PanelController` observes this so the
    /// pane's visibility follows whether a page actually exists, instead of
    /// following the panel state alone.
    static let activityChanged = Notification.Name("PopBrowserActivityChange")

    /// Whether the pane should be on screen right now: a `full` panel AND a
    /// live page. This is the ONE definition, and both the panel layout and the
    /// band handed to the page come from it, so the page can never reserve a
    /// band the native side is not painting (or fail to reserve one it is).
    var isPaneVisible: Bool { state.active }

    /// Bounds. A navigation can hang forever on a dead host; a read on a busy
    /// page must not either.
    static let navigationTimeout: TimeInterval = 20
    static let readTimeout: TimeInterval = 5
    static let actionTimeout: TimeInterval = 10
    static let textByteCap = 4096
    static let extractRowCap = 50
    static let extractByteCap = 20 * 1024
    static let refCap = 200

    /// Only real web URLs. `file://` would read the user's disk through a page
    /// the model controls, `javascript:` is code execution with the origin's
    /// cookies, and `data:` is a phishing-shaped blank page with a fake origin.
    static let allowedSchemes: Set<String> = ["http", "https"]

    let webView: WKWebView
    private let container = NSView()

    /// Human-visible one-liners for the transcript. The model gets the full
    /// tool result; the user gets this, which is why the browser never acts
    /// invisibly.
    var onVisible: ((String) -> Void)?

    /// Pane chrome state, pushed to the page as `popAPI.browserState`.
    var onStateChange: ((BrowserState) -> Void)?

    private(set) var state = BrowserState(active: false, url: "", title: "", status: "")
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var loadGeneration = 0

    /// A STABLE identifier for the lookup/browser profile. One returning user
    /// across launches, not a brand-new stranger every time — the signed-out
    /// `nonPersistent()` store reset on every launch, so Google could never see
    /// a session develop.
    static let dataStoreIdentifier = UUID(uuidString: "50F0A11D-7B3E-4C2A-9E6B-1A2C3D4E5F60")!

    /// The persistent store must live under Pop's OWN Application Support. WebKit
    /// has no public directory override, so its bundle-scoped directory
    /// (`~/Library/WebKit/<bundle id>`) is pointed at
    /// `~/Library/Application Support/Pop/WebKit` with a symlink. Created only
    /// when WebKit has not already made that path, so existing data is never
    /// destroyed. The user's real browser data is never read or written.
    ///
    /// `POP_WEBKIT_STORE_PATH` redirects the DESTINATION. It exists so a probe
    /// can own a persistent store of its own — the session under test is only
    /// real if it survives a relaunch, which needs one stable path across two
    /// processes, and it must not be the user's own store. Unset in production:
    /// the destination is then exactly as before.
    static func prepareDataStoreLocation() {
        let fileManager = FileManager.default
        let override = ProcessInfo.processInfo.environment["POP_WEBKIT_STORE_PATH"]
        let support: URL = {
            guard let override, !override.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                return PopConfig.directoryURL.appendingPathComponent("WebKit", isDirectory: true)
            }
            return URL(fileURLWithPath: override, isDirectory: true)
        }()
        // WebKit scopes the store by the RUNNING bundle's identifier, falling
        // back to the executable name for an unbundled run — so the link must be
        // named for whatever is running, not a hardcoded id. A probe run under a
        // distinct executable name therefore gets its OWN store scope, which is
        // how a probe-owned store is possible without touching any other one.
        let scope = Bundle.main.bundleIdentifier
            ?? Bundle.main.executableURL?.deletingPathExtension().lastPathComponent
            ?? "com.pop.app"
        let webkitParent = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit", isDirectory: true)
        let webkitDir = webkitParent.appendingPathComponent(scope, isDirectory: true)
        print("WEBKIT_STORE_SCOPE=\(scope)")
        print("WEBKIT_STORE_PATH=\(support.path)")
        fflush(stdout)
        // A real directory already there is WebKit's own: never replaced.
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: webkitDir.path, isDirectory: &isDir), !isDir.boolValue {
            return
        }
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: webkitParent, withIntermediateDirectories: true)
        try? fileManager.createSymbolicLink(at: webkitDir, withDestinationURL: support)
    }

    override private init() {
        BrowserController.prepareDataStoreLocation()
        let configuration = WKWebViewConfiguration()
        // PERSISTENT, Pop-owned store. WebKit keeps it in Pop's own container
        // (`~/Library/WebKit/com.pop.app`), never the user's real browser data.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
        // END-USER REQUEST PROFILE, part 2 of 2 (the persistent store above is
        // part 1). WebKit's stock UA is not app-specific, but it ships TRUNCATED
        // — measured on the wire via the loopback `/echo-headers` route:
        //   "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15
        //    (KHTML, like Gecko)" — no `Version/…` and no `Safari/…` token, which
        // no real Safari ever sends. A complete, standard Safari UA is sent
        // instead, with the OS version taken from THIS machine (never a
        // hardcoded lie) and no Pop/Glance marker anywhere.
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: BrowserController.pageScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: BrowserController.paneHeight),
            configuration: configuration
        )
        super.init()
        webView.customUserAgent = Self.endUserAgent()
        webView.navigationDelegate = self
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(webView)
        container.translatesAutoresizingMaskIntoConstraints = true
    }

    /// The view the panel puts into its content view. Hidden in `bar`/`mascot`.
    var paneView: NSView { container }

    // MARK: - Navigation

    /// Loads an absolute http(s) URL. Anything else is refused BY NAME so the
    /// reason is visible in the pane and in the transcript.
    ///
    /// `activatingPane` false drives the SAME web view OFFSCREEN: the page loads
    /// and is readable, but the visible browser pane is never opened and no
    /// browser chrome is posted. `web_lookup` uses this so a lookup can never
    /// occlude the answer it produced.
    func navigate(_ rawURL: String, activatingPane: Bool = true) async -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return refuse(rawURL, reason: "not a valid URL", activatingPane: activatingPane)
        }
        guard Self.allowedSchemes.contains(scheme) else {
            return refuse(rawURL, reason: "\(scheme):// not allowed", activatingPane: activatingPane)
        }
        guard url.host != nil else {
            return refuse(rawURL, reason: "no host", activatingPane: activatingPane)
        }

        if activatingPane {
            setState(active: true, url: url.absoluteString, title: "", status: "loading\u{2026}")
            print("BROWSER_URL=\(url.absoluteString)")
            fflush(stdout)
        }

        let ok = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.load(url) }
            group.addTask {
                try? await Task.sleep(for: .seconds(BrowserController.navigationTimeout))
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            self.cancelLoadWaiter()
            return finished
        }

        if !ok {
            if activatingPane {
                setState(active: true, url: url.absoluteString, title: "", status: "timed out")
            }
            return "ERROR: \(url.absoluteString) did not load within "
                + "\(Int(BrowserController.navigationTimeout))s"
        }
        // Refs belong to the document that just died with the old one; the
        // injected script clears them at every document end, but the session id
        // is what makes a stale ref impossible rather than merely unlikely.
        let title = await call("window.__popBrowser && __popBrowser.title()") ?? ""
        // Report the ACTUAL profile the page saw: the browser's own UA (never
        // spoofed) plus the Accept-Language header we set on the request.
        let ua = await call("navigator.userAgent") ?? "unknown"
        print("REQUEST_PROFILE user_agent=\(ua)")
        print("REQUEST_PROFILE accept_language=\(Self.acceptLanguage())")
        fflush(stdout)
        if activatingPane {
            setState(active: true, url: webView.url?.absoluteString ?? url.absoluteString,
                     title: title, status: "loaded")
            visible("BROWSER \u{2192} \(shortHost(url))")
        }
        return "loaded \(url.absoluteString)\ntitle: \(title)"
    }

    func back() async -> String {
        guard webView.canGoBack else {
            visible("BROWSER \u{2192} back (no history)")
            return "no earlier page to go back to"
        }
        webView.goBack()
        let ok = await waitForCurrentLoad()
        let title = await call("window.__popBrowser && __popBrowser.title()") ?? ""
        setState(active: true, url: webView.url?.absoluteString ?? "", title: title, status: "loaded")
        print("BROWSER_URL=\(webView.url?.absoluteString ?? "")")
        fflush(stdout)
        visible("BROWSER \u{2192} back to \(shortHost(webView.url))")
        return ok ? "went back to \(webView.url?.absoluteString ?? "")\ntitle: \(title)"
                  : "ERROR: back did not settle within \(Int(BrowserController.navigationTimeout))s"
    }

    // MARK: - Reading

    /// Title, visible text, and the numbered interactive snapshot the model
    /// reasons over. This is the whole basis of "fill the form": the model can
    /// only act on refs, and refs only exist here.
    func readPage() async -> String {
        guard webView.url != nil else {
            return "ERROR: the browser has no page open; call browser_navigate first"
        }
        let script = "window.__popBrowser ? __popBrowser.read() : ''"
        guard let raw = await call(script, timeout: Self.readTimeout), !raw.isEmpty else {
            return "ERROR: could not read the page (still loading, or a page that blocks scripts)"
        }
        return raw
    }

    /// Repeated records as JSON rows. Silent: a read never needs a click.
    func extract(fields: [String]) async -> String {
        let cleaned = fields
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return "ERROR: extract needs at least one field name"
        }
        guard webView.url != nil else {
            return "ERROR: the browser has no page open; call browser_navigate first"
        }
        let encoded = cleaned.map { Self.jsString($0) }.joined(separator: ",")
        let script = "window.__popBrowser ? __popBrowser.extract([\(encoded)]) : ''"
        guard let raw = await call(script, timeout: Self.readTimeout), !raw.isEmpty else {
            return "ERROR: could not extract from the page"
        }
        return raw
    }

    /// How many cookies the PERSISTENT store holds. Evidence that the session
    /// accumulates across launches rather than resetting to a stranger each run.
    func cookieCount() async -> Int {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.count)
            }
        }
    }

    /// The cookie NAMES held for a host, for session evidence. Names only — a
    /// value is a credential and never leaves the store.
    ///
    /// The host is matched on its REGISTRABLE form, not the literal string: a
    /// cookie stored for `google.com` (domain `.google.com`) does not contain the
    /// literal text `www.google.com`, so the previous `contains` filter reported
    /// an EMPTY jar for a store that plainly held cookies (measured: the binary
    /// cookie file carried google entries while `SESSION_COOKIE_NAMES` printed
    /// nothing). A leading `www.` is dropped on both sides; a loopback probe
    /// host is already registrable and is unaffected.
    func cookieNames(for host: String) async -> [String] {
        let registrable = Self.registrableHost(host)
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies
                    .filter { Self.registrableHost($0.domain).contains(registrable) }
                    .map(\.name)
                    .sorted())
            }
        }
    }

    /// A host with its leading `www.` (and any leading dot) removed, so a
    /// request for `www.google.com` and a cookie set on `.google.com` compare
    /// equal. Generic string normalisation, no host list.
    static func registrableHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - The user's own account (sign out)

    /// Signing IN lives in `GoogleSignIn` and opens its own visible key window:
    /// the in-panel pane is hidden unless the panel is `full`, so navigating it
    /// from the resting launcher state showed the user nothing. What stays HERE
    /// is the store side — clearing the account's cookies — because that acts on
    /// the shared store the lookup webview itself uses.

    /// Whether a cookie belongs to the account/search provider, judged on the
    /// cookie's OWN registrable host. Used by sign-out so it can remove exactly
    /// that provider's cookies and touch nothing else.
    static func isProviderCookie(_ cookie: HTTPCookie) -> Bool {
        let host = registrableHost(cookie.domain)
        return host == providerRoot || host.hasSuffix("." + providerRoot)
    }

    /// The provider whose cookies sign-out clears. A registrable-host suffix
    /// test, not a list of cookie names.
    static let providerRoot = "google.com"

    /// Signs the user out by removing ONLY the provider's cookies from the
    /// shared persistent store, and reports how many went.
    ///
    /// Cookies are matched on their registrable host and deleted individually,
    /// so every other site's cookies in the same store survive untouched.
    /// Names are logged, never values: a cookie value is a credential.
    @discardableResult
    func signOutOfGoogle() async -> (cleared: Int, remaining: Int, kept: [String]) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all: [HTTPCookie] = await readCookies(from: store)
        let mine = all.filter { Self.isProviderCookie($0) }
        for cookie in mine {
            await store.deleteCookie(cookie)
        }
        // Re-read rather than assume: the count the user sees must be what the
        // store actually holds after the delete, not what we intended to delete.
        let after: [HTTPCookie] = await readCookies(from: store)
        let cleared = mine.count
        let kept = after
            .filter { !Self.isProviderCookie($0) }
            .map { $0.name }
            .sorted()
        print("SIGNOUT_COOKIES_CLEARED=\(cleared)")
        print("SIGNOUT_COOKIES_KEPT=\(kept.joined(separator: " | "))")
        print("SIGNOUT_PROVIDER_LEFT=\(after.filter { Self.isProviderCookie($0) }.count)")
        fflush(stdout)
        return (cleared, after.count, kept)
    }

    /// The whole store's cookies. One reader, so the sign-out evidence and the
    /// `cookieNames` evidence above can never disagree about the same jar.
    private func readCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// The rendered visible text of the current page, for a probe's evidence
    /// check. Read-only; never used by production behaviour.
    func pageText() async -> String {
        await call("document.body ? document.body.innerText : ''") ?? ""
    }

    /// Writes one line into Pop's OWN panel / action log (the transcript
    /// tool-line path in the app). Read-only capabilities that are not browser
    /// tools — `web_lookup` — surface their marker here. It never touches the
    /// user's real browser: this is Pop's own chrome.
    func logAction(_ line: String) {
        visible(line)
    }

    // MARK: - Acting

    func click(ref: Int) async -> String {
        await act(tool: "browser_click", ref: ref, body: "__popBrowser.click(\(ref))")
    }

    func typeField(ref: Int, text: String) async -> String {
        let escaped = Self.jsString(text)
        return await act(
            tool: "browser_type_field",
            ref: ref,
            body: "__popBrowser.fill(\(ref), \(escaped))"
        )
    }

    func selectOption(ref: Int, value: String) async -> String {
        let escaped = Self.jsString(value)
        return await act(
            tool: "browser_select_option",
            ref: ref,
            body: "__popBrowser.select(\(ref), \(escaped))"
        )
    }

    func submit() async -> String {
        await act(tool: "browser_submit", ref: 0, body: "__popBrowser.submit()")
    }

    /// One shape for every acting call: scroll into view, run, report.
    private func act(tool: String, ref: Int, body: String) async -> String {
        let script = "window.__popBrowser ? (\(body)) : 'ERROR: page not ready'"
        guard let raw = await call(script, timeout: Self.actionTimeout) else {
            print("BROWSER_ACT tool=\(tool) ref=\(ref) ok=false")
            fflush(stdout)
            return "ERROR: \(tool) did not answer within \(Int(Self.actionTimeout))s"
        }
        let ok = !raw.hasPrefix("ERROR:")
        print("BROWSER_ACT tool=\(tool) ref=\(ref) ok=\(ok)")
        fflush(stdout)
        visible("BROWSER \u{2192} \(tool.replacingOccurrences(of: "browser_", with: "")) \(ok ? "ok" : "failed")")
        return raw
    }

    // MARK: - Plumbing

    /// Refuses a URL and makes the refusal VISIBLE, not just returned.
    private func refuse(_ raw: String, reason: String, activatingPane: Bool = true) -> String {
        let message = "page blocked: \(reason)"
        if activatingPane {
            setState(active: true, url: raw, title: "", status: message)
            print("BROWSER_BLOCKED url=\(raw) reason=\(reason)")
            fflush(stdout)
            visible("BROWSER \u{2192} blocked (\(reason))")
        }
        return "ERROR: page blocked: \(reason)"
    }

    /// Waits for the load the delegate will report. One waiter at a time: the
    /// browser is a single pane driven by one model turn, and a second
    /// navigation supersedes the first.
    private func load(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            loadGeneration += 1
            loadContinuation = continuation
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.navigationTimeout
            // A normal end-user request profile: the default WebKit user agent
            // (never spoofed) plus an Accept-Language matching the machine's
            // locale, so the SERP renders in the user's own language/region.
            request.setValue(Self.acceptLanguage(), forHTTPHeaderField: "Accept-Language")
            for (name, value) in Self.clientHints() {
                request.setValue(value, forHTTPHeaderField: name)
            }
            webView.load(request)
        }
    }

    /// The low-entropy client hints a real browser sends on every request.
    /// These were measured MISSING on the wire (loopback `/echo-headers`), while
    /// Safari always sends them — an unfilled gap in the session profile.
    /// Derived from the same UA, generic, nothing app-specific.
    static func clientHints() -> [(String, String)] {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        // The brand list MUST agree with the User-Agent. An earlier pass here
        // advertised "Chromium" alongside a Safari UA — two different browsers
        // in one request, which is self-contradictory rather than end-user-like.
        // The brands below match the WebKit/Safari UA set above.
        return [
            ("Sec-CH-UA", "\"Not_A Brand\";v=\"24\", \"Safari\";v=\"\(major)\"")
        ]
    }

    /// A complete, standard Safari User-Agent built from THIS machine's OS
    /// version. Generic: no Pop/Glance/app identifier is included, and no site
    /// is targeted — this is the profile an ordinary Safari session sends.
    static func endUserAgent() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let major = os.majorVersion
        let minor = os.minorVersion
        let patch = os.patchVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(major).\(minor).\(patch) Safari/605.1.15"
    }

    /// `Accept-Language` from the machine's locale, e.g. `en-SG,en;q=0.9`.
    /// No hardcoded language list beyond the locale's own language code.
    static func acceptLanguage() -> String {
        let identifier = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return identifier == language ? identifier : "\(identifier),\(language);q=0.9"
    }

    private func waitForCurrentLoad() async -> Bool {
        await withCheckedContinuation { continuation in
            loadGeneration += 1
            loadContinuation = continuation
        }
    }

    private func cancelLoadWaiter() {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        loadContinuation?.resume(returning: true)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        let reason = (error as NSError).code
        setState(active: true, url: webView.url?.absoluteString ?? "",
                 title: "", status: "failed to load")
        print("BROWSER_FAIL url=\(webView.url?.absoluteString ?? "") code=\(reason)")
        fflush(stdout)
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
    }

    /// `evaluateJavaScript` with a hard deadline.
    ///
    /// The async API is used inside a detached-from-the-group `Task`, because
    /// `TaskGroup` cannot abandon a child: `evaluateJavaScript` does not observe
    /// cancellation, so racing it IN a group would wait for the page that never
    /// answers — exactly the hang the deadline exists to prevent. The slot
    /// resumes the caller on whichever arrives first and cancels the timer when
    /// the page wins; a late answer is dropped, not resumed.
    private func call(_ script: String, timeout: TimeInterval? = nil) async -> String? {
        let limit = timeout ?? Self.readTimeout
        let slot = JSResultSlot()
        slot.arm(after: limit)
        Task { @MainActor in
            do {
                let value = try await self.webView.evaluateJavaScript(script)
                if let value, !(value is NSNull) {
                    slot.finish(String(describing: value))
                } else {
                    slot.finish("")
                }
            } catch {
                slot.finish("ERROR: \(error.localizedDescription)")
            }
        }
        return await slot.next()
    }

    /// A JS string literal, including the quotes. Used for every value handed
    /// to injected script; a hand-rolled splice here would be a script-injection
    /// hole reachable from a model-authored argument.
    static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        guard let array = data,
              let text = String(data: array, encoding: .utf8),
              text.count >= 2
        else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    private func shortHost(_ url: URL?) -> String {
        url?.host ?? "(none)"
    }

    private func visible(_ line: String) {
        onVisible?(line)
    }

    private func setState(active: Bool, url: String, title: String, status: String) {
        let next = BrowserState(active: active, url: url, title: title, status: status)
        guard next != state else { return }
        state = next
        onStateChange?(next)
        // The PANE'S VISIBILITY IS DERIVED FROM THIS, so a change here changes
        // what is painted over the transcript and the panel has to re-lay-out.
        // `PanelController` used to decide pane visibility from the panel state
        // ALONE, which is how an empty 300pt black box ended up sitting on top
        // of a conversation: `full` showed the pane whether or not a page had
        // ever been opened, while the page reserved the matching band only when
        // `active` was true. One source of truth, or the two drift apart.
        NotificationCenter.default.post(name: BrowserController.activityChanged, object: nil)
    }

    /// Re-pushes the current state. Called when the page becomes ready: the
    /// browser may well have been navigated from a tool call before the chat
    /// page finished loading.
    func republishState() {
        onStateChange?(state)
    }

    /// The injected script. Injected at `document_end` for every document, so
    /// every navigation starts from a clean registry: `data-pop-ref` is only
    /// ever set by a read on the current document.
    static let pageScript = #"""
    window.__popBrowser = (function () {
      var SELECTOR = 'a, button, input, select, textarea';
      var CAP = 200;

      function text(el) {
        return ((el.textContent) || '').replace(/\s+/g, ' ').trim();
      }
      function label(el) {
        var candidates = [
          el.getAttribute('aria-label'),
          el.getAttribute('placeholder'),
          el.getAttribute('name'),
          el.getAttribute('title'),
          (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') ? el.value : null,
          el.tagName === 'SELECT' ? null : text(el),
          text(el)
        ];
        for (var i = 0; i < candidates.length; i++) {
          if (candidates[i] && String(candidates[i]).trim()) {
            return String(candidates[i]).replace(/\s+/g, ' ').trim().slice(0, 80);
          }
        }
        return '(no label)';
      }
      // "Visible" means: laid out, non-zero, not transparent, and inside the
      // viewport. An off-screen field cannot be scrolled to by a user either,
      // so offering a ref for it would be a ref that fails on use.
      function visible(el) {
        if (el.disabled || el.type === 'hidden') { return false; }
        var style = window.getComputedStyle(el);
        if (!style || style.display === 'none' || style.visibility === 'hidden') { return false; }
        if (parseFloat(style.opacity || '1') === 0) { return false; }
        var rect = el.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) { return false; }
        return rect.top < window.innerHeight && rect.bottom > 0
          && rect.left < window.innerWidth && rect.right > 0;
      }
      function clearRefs() {
        var stale = document.querySelectorAll('[data-pop-ref]');
        for (var i = 0; i < stale.length; i++) { stale[i].removeAttribute('data-pop-ref'); }
      }
      function byRef(ref) {
        return document.querySelector('[data-pop-ref="' + String(ref) + '"]');
      }
      function stale(ref) {
        return 'ERROR: no element ['
          + ref + '] on this page; the page changed or moved — call browser_read again';
      }
      function snapshot() {
        var nodes = document.querySelectorAll(SELECTOR);
        var lines = [];
        var n = 0;
        for (var i = 0; i < nodes.length && n < CAP; i++) {
          if (!visible(nodes[i])) { continue; }
          n += 1;
          nodes[i].setAttribute('data-pop-ref', String(n));
          lines.push('[' + n + '] ' + nodes[i].tagName.toLowerCase()
            + (nodes[i].type ? '[' + nodes[i].type + ']' : '')
            + ' "' + label(nodes[i]) + '"');
        }
        if (!n) { return '(no interactive elements visible)'; }
        return lines.join('\n');
      }
      return {
        title: function () { return document.title || ''; },
        read: function () {
          clearRefs();
          var heading = document.title || '(untitled)';
          var body = (document.body ? (document.body.innerText || '') : '')
            .replace(/\n{3,}/g, '\n\n').trim();
          if (body.length > 4096) {
            body = body.slice(0, 4096) + '\n[truncated at 4096 characters]';
          }
          return 'title: ' + heading + '\nurl: ' + location.href + '\n\n'
            + 'TEXT:\n' + (body || '(empty page)') + '\n\n'
            + 'ELEMENTS (use these refs with click/type_field/select_option):\n'
            + snapshot();
        },
        click: function (ref) {
          var el = byRef(ref);
          if (!el) { return stale(ref); }
          el.scrollIntoView({ block: 'center' });
          var name = el.tagName.toLowerCase() + ' "' + label(el) + '"';
          el.focus();
          el.click();
          return 'clicked [' + ref + '] ' + name;
        },
        fill: function (ref, value) {
          var el = byRef(ref);
          if (!el) { return stale(ref); }
          if (el.tagName === 'SELECT') {
            return 'ERROR: [' + ref + '] is a select; use select_option instead';
          }
          el.scrollIntoView({ block: 'center' });
          el.focus();
          // The native setter, then the events: a framework-controlled input
          // ignores a plain `value =` assignment and would submit an empty
          // field while Pop reported success.
          var proto = el.tagName === 'TEXTAREA'
            ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) { setter.set.call(el, value); }
          else { el.value = value; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'typed ' + value.length + ' characters into ['
            + ref + '] "' + label(el) + '"';
        },
        select: function (ref, value) {
          var el = byRef(ref);
          if (!el) { return stale(ref); }
          if (el.tagName !== 'SELECT') {
            return 'ERROR: [' + ref + '] is not a select; use type_field instead';
          }
          el.scrollIntoView({ block: 'center' });
          var options = el.options || [];
          var matched = -1;
          for (var i = 0; i < options.length; i++) {
            if (options[i].value === value || options[i].text.trim() === value) {
              matched = i; break;
            }
          }
          if (matched < 0) {
            var available = [];
            for (var j = 0; j < options.length; j++) { available.push(options[j].value); }
            return 'ERROR: "' + value + '" is not an option of [' + ref
              + ']; available: ' + available.join(', ');
          }
          el.selectedIndex = matched;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'selected "' + value + '" in [' + ref + '] "' + label(el) + '"';
        },
        submit: function () {
          var form = document.querySelector('form');
          var button = null;
          if (form) {
            button = form.querySelector(
              'button[type=submit], input[type=submit], button:not([type]), input[type=button]'
            );
          }
          if (!button) {
            // No form: fall back to the highest-numbered ref that submits.
            var candidates = document.querySelectorAll(
              'button[type=submit], input[type=submit]'
            );
            for (var i = 0; i < candidates.length; i++) {
              if (visible(candidates[i])) { button = candidates[i]; }
            }
          }
          if (!button) { return 'ERROR: this page has no submit button'; }
          button.scrollIntoView({ block: 'center' });
          var ref = button.getAttribute('data-pop-ref') || '0';
          // `requestSubmit` on the FORM when there is one: it runs constraint
          // validation and fires `submit`, so the site's own handler runs
          // exactly as it would for a person.
          if (form && typeof form.requestSubmit === 'function') {
            form.requestSubmit(button.tagName === 'INPUT' ? null : button);
          } else {
            button.click();
          }
          var body = (document.body ? (document.body.innerText || '') : '')
            .replace(/\s+/g, ' ').trim();
          return 'submitted [' + ref + '] "' + label(button) + '"\npage now says: '
            + body.slice(0, 400);
        },
        extract: function (fields) {
          // Records are rows of cell TEXTS, resolved before anything is
          // guessed: which table row is a header decides every other row.
          var rows = [];
          var table = document.querySelectorAll('tr');
          for (var t = 0; t < table.length; t++) {
            var cells = table[t].querySelectorAll('th, td');
            var texts = [];
            for (var k = 0; k < cells.length; k++) { texts.push(text(cells[k])); }
            if (texts.length >= 2) { rows.push(texts); }
          }
          if (!rows.length) {
            // No table: a product grid is a list of cards. Take the LEAF
            // elements so a card contributes its own values, not its ancestors.
            var cards = document.querySelectorAll(
              'li, article, [class*=card], [class*=item], [class*=product]'
            );
            for (var c = 0; c < cards.length; c++) {
              var leaves = cards[c].querySelectorAll(
                'span, p, div, li, h1, h2, h3, h4, a, td, strong, em'
              );
              var values = [];
              for (var v = 0; v < leaves.length && values.length < 8; v++) {
                if (leaves[v].querySelector('*')) { continue; }   // container, not a leaf
                var t2 = text(leaves[v]);
                if (t2) { values.push(t2); }
              }
              if (values.length >= 2) { rows.push(values); }
            }
          }

          // Header mapping: a row whose cells ARE the field names. Looked for in
          // every row, not just the first, because the first row of a card grid
          // is a heading rather than a header.
          var column = {};
          var headerRow = -1;
          for (var r = 0; r < rows.length; r++) {
            var hit = 0;
            for (var f = 0; f < fields.length; f++) {
              for (var ci = 0; ci < rows[r].length; ci++) {
                if (rows[r][ci].toLowerCase() === fields[f].toLowerCase()) {
                  column[fields[f]] = ci;
                  hit++;
                }
              }
            }
            if (hit > 0) { headerRow = r; break; }
          }

          var out = [];
          for (var r2 = 0; r2 < rows.length && out.length < 50; r2++) {
            if (r2 === headerRow) { continue; }
            // A single `text` field is the OMITTED-fields default: each row is
            // its OWN visible text, joined — not the positional first cell. So
            // an extract with no field names returns each repeated card's text,
            // which is what "omitted" promises the model.
            if (fields.length === 1 && String(fields[0]).toLowerCase() === 'text') {
              var joined = rows[r2].join(' ').replace(/\s+/g, ' ').trim().slice(0, 200);
              if (joined) { out.push({ text: joined }); }
              continue;
            }
            var record = {};
            var complete = true;
            for (var f2 = 0; f2 < fields.length; f2++) {
              var index = column[fields[f2]];
              if (index === undefined) { index = f2; }   // positional fallback
              var value = (rows[r2][index] || '').slice(0, 120);
              record[fields[f2]] = value;
              if (!value) { complete = false; }
            }
            // A row missing a requested field is not a record for these fields:
            // emitting it would teach the model a product has no price.
            if (complete) { out.push(record); }
          }
          if (!out.length) {
            return 'no rows matched fields ' + fields.join(', ') + ' on this page';
          }
          return JSON.stringify(out, null, 1).slice(0, 20000);
        }
      };
    })();
    """#
}

/// One-shot slot between the JavaScript evaluation and its deadline.
///
/// A class with a lock rather than a captured `var`: the page's answer arrives
/// on the main actor while the deadline arrives on a timer, and mutating a
/// captured variable from both is a Swift 6 data race.
final class JSResultSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var pending: String??
    private var timer: Task<Void, Never>?

    func arm(after seconds: TimeInterval) {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    /// First caller wins; later answers are ignored, which is what makes a
    /// double resume impossible rather than merely unlikely.
    func finish(_ value: String?) {
        lock.lock()
        guard continuation != nil || pending == nil else {
            lock.unlock()
            return
        }
        let timer = self.timer
        self.timer = nil
        let waiter = continuation
        continuation = nil
        if waiter == nil { pending = .some(value) }
        lock.unlock()
        timer?.cancel()
        waiter?.resume(returning: value)
    }

    func next() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(returning: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
