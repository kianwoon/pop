import AppKit
import WebKit

/// Locates `Resources/index.html`. Inside `build/Pop.app` the script copies the
/// web resources to `Contents/Resources/`, so `Bundle.main` resolves it; the
/// source-tree fallback keeps the raw `swift build` binary runnable.
enum WebResources {
    static func indexURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html") {
            return bundled
        }
        let fromSourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/Pop
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Resources/index.html")
        return FileManager.default.fileExists(atPath: fromSourceTree.path) ? fromSourceTree : nil
    }
}

/// Spotlight-style input panel: `.nonactivatingPanel` keeps the summon from
/// stealing focus, so the panel never becomes key on its own. The click→key
/// promotion lives in `PanelController.installFocusMonitor()`; these two
/// overrides make the web view the view that participates in key-window
/// negotiation once the monitor asks for it.
final class FocusableWebView: WKWebView {
    override var needsPanelToBecomeKey: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the WKWebView inside the panel and owns the script bridge.
@MainActor
final class AppWebView: NSView {
    let webView: FocusableWebView

    private let bridge = Bridge()

    /// Installed by the owner so bridge messages can reach a chat session.
    var onBridgeMessage: ((String, [String: Any]) -> Void)? {
        get { bridge.onMessage }
        set { bridge.onMessage = newValue }
    }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: Bridge.handlerName)
        webView = FocusableWebView(frame: frameRect, configuration: configuration)
        // The launcher floats over the desktop: the page background is
        // transparent, so both layers must be too or the bar renders as a
        // black rectangle.
        webView.setValue(false, forKey: "drawsBackground")

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        bridge.attach(to: webView)
        loadIndex()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func loadIndex() {
        guard let url = WebResources.indexURL() else {
            print("WEB_RESOURCES_MISSING index.html")
            fflush(stdout)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}