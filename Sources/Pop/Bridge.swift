import WebKit

/// JS <-> native bridge. Messages arrive on the main thread; replies are
/// evaluated back into the page via `window.__popPong()`.
final class Bridge: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    static let handlerName = "popBridge"
    private static let pongScript = "window.__popPong();"

    private weak var webView: WKWebView?

    /// Routes non-ping UI messages (chatSend, chatStop, uiReady, …) to whoever
    /// owns the conversation. Set once by `AppWebView`'s owner; `nil` until then
    /// means those messages are simply ignored.
    var onMessage: ((String, [String: Any]) -> Void)?

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

        // `ping` keeps its original reply path so BRIDGE_PONG still prints.
        guard type == "ping" else {
            onMessage?(type, body)
            return
        }
        MainActor.assumeIsolated { reply() }
    }

    private func reply() {
        webView?.evaluateJavaScript(Self.pongScript) { _, error in
            if let error {
                print("BRIDGE_ERROR \(error.localizedDescription)")
                fflush(stdout)
                return
            }
            print("BRIDGE_PONG")
            fflush(stdout)
            // THE PAGE'S OWN VERSION, printed once at launch. The composer
            // marker used to sit unchanged for three milestones, so a web view
            // running a cached page was indistinguishable from a fresh one —
            // every symptom then looked like a logic bug. One line in the log
            // makes a stale page a visible fact.
            let versionScript = "window.__POP_COMPOSER_V ?? null"
            self.webView?.evaluateJavaScript(versionScript) { value, _ in
                if let version = value as? String, !version.isEmpty {
                    print("PAGE_VERSION=\(version)")
                } else {
                    print("PAGE_VERSION_MISSING")
                }
                fflush(stdout)
            }
        }
    }
}