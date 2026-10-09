import AppKit
import WebKit

/// The user's own Google account, as far as Pop is concerned.
///
/// POP IMPLEMENTS NO PART OF SIGNING IN. There is no username field, no
/// password field, no token exchange and no credential store anywhere in this
/// file — the only thing Pop knows is which account ORIGIN to open and whether
/// the shared store holds a session cookie afterwards. The credentials are
/// typed by the user into a real WebKit view on screen, exactly as they would be
/// in their own browser, and whatever the page keeps stays in WebKit's store.
/// A cookie VALUE is a credential and is never read, logged or stored by Pop:
/// the signed-in test below is the presence of cookie NAMES and nothing else.

/// Where the user signs in. A probe substitutes a loopback fixture with
/// `POP_SIGNIN_URL` so no test ever loads a real account page; the shipped
/// default is the account origin.
enum GoogleSignIn {
    static var accountURL: String {
        let override = ProcessInfo.processInfo.environment["POP_SIGNIN_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (override?.isEmpty == false) ? override! : "https://accounts.google.com"
    }

    /// The cookie NAMES that only exist once an account session exists. Names
    /// only: their presence in the store is the whole test, and no value is
    /// ever read to decide or to report.
    static let sessionCookieNames: Set<String> = [
        "SID", "HSID", "SSID", "SAPISID", "__Secure-1PAPISID"
    ]

    /// `signed-in` when the shared store holds any account session cookie,
    /// `signed-out` otherwise. Reads NAMES from the persistent store and never
    /// logs anything but the verdict.
    static func state() async -> String {
        let names = await BrowserController.shared.cookieNames(for: "google.com")
        let present = names.filter { sessionCookieNames.contains($0) }.sorted()
        let verdict = present.isEmpty ? "signed-out" : "signed-in"
        print("GOOGLE_SIGNIN_STATE=\(verdict)")
        // NAMES only — never a value.
        print("GOOGLE_SIGNIN_COOKIE_NAMES=\(present.joined(separator: " | "))")
        fflush(stdout)
        return verdict
    }
}

/// The VISIBLE, KEY window the user signs in in.
///
/// A separate window rather than the panel's browser pane, and that is the fix
/// for the reported failure: the pane is hidden unless the panel is `full`
/// (`PanelController.layoutContent`: `pane.isHidden = (next != .full) || !isPaneVisible`),
/// so a sign-in started from the resting launcher state navigated a page nobody
/// could see. A real window is unconditionally on screen, can become key, and
/// therefore can take keyboard focus — which signing in requires.
///
/// SAME STORE, WHICH IS THE WHOLE POINT. This view is built on the very
/// `WKWebsiteDataStore` instance `web_lookup` uses, so the session the user
/// establishes here is the session lookups ride afterwards. Cookies live in the
/// store, not in a view, so a second view on the same store shares them.
@MainActor
final class GoogleSignInWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = GoogleSignInWindowController()

    private var window: NSWindow?
    private var signInWebView: WKWebView?

    override private init() {
        super.init()
    }

    /// Built on FIRST USE, not in `init`. Constructing a `WKWebView` here would
    /// force `BrowserController.shared` — the lookup's own web view, and a
    /// whole WebKit process — into existence from inside this controller's own
    /// initialiser, and the view built that way never started its first load
    /// (measured: `SIGNIN_SURFACE_LOADED_URL=` empty, `isLoading=false`).
    private func makeSignInWebView() -> WKWebView {
        if let signInWebView { return signInWebView }
        let configuration = WKWebViewConfiguration()
        // THE SAME PERSISTENT STORE OBJECT as the lookup webview — not a
        // second store, not a default one. This single line is what makes a
        // signed-in lookup possible.
        configuration.websiteDataStore =
            BrowserController.shared.webView.configuration.websiteDataStore
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 720),
            configuration: configuration
        )
        // Same end-user profile the lookup sends, so the account page sees the
        // same request Pop always makes.
        view.customUserAgent = BrowserController.shared.webView.customUserAgent
        view.navigationDelegate = self
        signInWebView = view
        return view
    }

    private func makeWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Google"
        window.contentView = makeSignInWebView()
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        return window
    }

    /// Opens the account page on screen and puts the keyboard in it. Returns a
    /// one-line report; the credentials themselves only ever exist in the page.
    @discardableResult
    func signIn() async -> String {
        let target = GoogleSignIn.accountURL
        let window = makeWindow()
        let view = makeSignInWebView()
        let fallback = URL(string: "https://accounts.google.com")!
        view.load(URLRequest(url: URL(string: target) ?? fallback))
        NSApp.activate()
        // `makeKeyAndOrderFront` + explicit first responder: a window that is
        // merely on screen cannot receive the keystrokes signing in requires.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        print("SIGNIN_SURFACE_SHOWN=true")
        print("SIGNIN_SURFACE_URL=\(target)")
        print("SIGNIN_STORE_SAME_AS_LOOKUP=\(view.configuration.websiteDataStore === BrowserController.shared.webView.configuration.websiteDataStore)")
        fflush(stdout)
        return "opened \(target)"
    }

    /// Whether the sign-in window is actually on screen right now. Read from
    /// AppKit rather than remembered from `signIn()`, so it cannot report a
    /// window the user has already closed.
    var isSignInSurfaceVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    /// What the surface is actually showing, read from the live view. A probe
    /// measures this rather than trusting the URL that was asked for.
    var currentURL: String { signInWebView?.url?.absoluteString ?? "" }

    var surfaceIsLoading: Bool { signInWebView?.isLoading ?? false }
    var surfaceTitle: String { signInWebView?.title ?? "" }

    /// Whether this view's store IS the lookup webview's store object. The one
    /// assertion the whole feature rests on, made checkable.
    var signInStoreIsLookupStore: Bool {
        guard let signInWebView else { return false }
        return signInWebView.configuration.websiteDataStore
            === BrowserController.shared.webView.configuration.websiteDataStore
    }

    func closeSignInSurface() {
        window?.close()
    }

    /// The user closed the surface (or the window). Re-read the state so the
    /// settings row says what is true NOW, not what it said before sign-in.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        print("SIGNIN_SURFACE_LOAD_ERROR=\(error.localizedDescription)")
        fflush(stdout)
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            _ = await GoogleSignIn.state()
            // CLOSING THE SURFACE IS A MOMENT THE ACCOUNT STATE CAN CHANGE.
            // The user signs in while the settings window stays OPEN, so the
            // `show()` bump in `SettingsWindowController` never fires and the
            // row kept showing "Sign in…" after a successful sign-in (measured:
            // the store held SID/HSID/SSID/SAPISID/__Secure-1PAPISID while the
            // row still said signed-out). The bump makes the open form re-read
            // cookie NAMES — never values — with no re-show.
            SettingsWindowController.shared.refreshGeneration.value += 1
        }
    }

    /// Removes ONLY Google's cookies from the shared store, so every other
    /// site's session in that store survives.
    @discardableResult
    func signOut() async -> String {
        let result = await BrowserController.shared.signOutOfGoogle()
        // Same reason as `windowWillClose`: the row must follow the store now,
        // not at the next `show()`.
        SettingsWindowController.shared.refreshGeneration.value += 1
        return "removed \(result.cleared) Google cookie(s)"
    }
}
