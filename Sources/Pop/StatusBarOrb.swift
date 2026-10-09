import AppKit

/// Menu-bar presence: a template-image status item is the only UI the app owns
/// while the panel is hidden.
@MainActor
final class StatusBarOrb: NSObject {
    private let onShow: () -> Void
    private let onHide: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    private var statusItem: NSStatusItem?

    init(
        onShow: @escaping () -> Void,
        onHide: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShow = onShow
        self.onHide = onHide
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.orbImage()
        item.button?.toolTip = "Pop"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Pop", action: #selector(showPop), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Pop", action: #selector(hidePop), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitPop), keyEquivalent: "q"))
        for entry in menu.items where !entry.isSeparatorItem {
            entry.target = self
        }
        item.menu = menu

        statusItem = item
    }

    @objc private func showPop() { onShow() }
    @objc private func hidePop() { onHide() }
    @objc private func openSettings() { onSettings() }
    @objc private func quitPop() { onQuit() }

    private static func orbImage() -> NSImage? {
        if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Pop") {
            symbol.isTemplate = true
            return symbol
        }
        let fallback = NSImage(size: NSSize(width: 16, height: 16))
        fallback.lockFocus()
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        fallback.unlockFocus()
        fallback.isTemplate = true
        return fallback
    }
}