import AppKit

/// Pop's application main menu.
///
/// Pop runs as an `.accessory` app, so it gets no Dock icon and — with nothing
/// here — no menu bar at all. That is not merely cosmetic: on macOS the standard
/// clipboard and text-editing keystrokes (⌘V, ⌘C, ⌘X, ⌘A, ⌘Z) are dispatched
/// through the Edit menu of the FRONTMOST application. Typing reached a text
/// field directly through the field editor, which is why typing worked while
/// paste silently did nothing — the user could not paste a URL into Settings.
///
/// The Edit items therefore carry `target = nil`, which is the load-bearing
/// detail: AppKit sends the action to the first responder instead of the app.
@MainActor
enum MainMenu {
    static func install() {
        NSApp.mainMenu = makeMainMenu()
        NSApp.windowsMenu = makeWindowsMenu()
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // - App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Pop")
        appMenu.addItem(
            withTitle: "About Pop",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(AppActions.showSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Pop",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Quit Pop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        // - Edit menu. Standard selectors, nil target: routed to the first
        // responder, which is what makes them act on the focused text field.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // `pasteAsPlainText:` is not exposed on NSText in this SDK. Going
        // through the responder chain's own declaration keeps the selector
        // typed AND first-responder routed, which is what the item needs.
        editMenu.addItem(
            withTitle: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "V"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        // The Window menu must be in the main menu as well as installed as the
        // app's `windowsMenu`, or Close and Minimize are unreachable.
        let windowsItem = NSMenuItem()
        windowsItem.submenu = makeWindowsMenu()
        main.addItem(windowsItem)

        return main
    }

    private static func makeWindowsMenu() -> NSMenu {
        let windowsMenu = NSMenu(title: "Window")
        windowsMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowsMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        return windowsMenu
    }
}

// MARK: - Actions

/// Menu actions live on a class, not on the enum: `@objc` cannot decorate enum
/// members, and a menu selector needs an Objective-C visible target.
@MainActor
final class AppActions: NSObject {
    /// Routes the Settings… item to the existing settings window, which
    /// previously had no main-menu route at all.
    @objc func showSettingsFromMenu(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}