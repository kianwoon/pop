import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// What Pop saw about the user's current screen. Every field is optional by
/// design: a denied permission is a normal outcome, not an error.
struct Observation: Sendable {
    struct Screenshot: Sendable {
        let data: Data
        let width: Int
        let height: Int
        /// Window the capture was scoped to, in points. Nil on the display fallback.
        var windowFrame: CGRect?
        /// Pixels per point. A mismatch between this and the display's real scale
        /// is the signature of a wrongly-scoped capture.
        var scale: Double = 0
    }

    enum AXState: String, Sendable {
        case ok
        case denied
        case empty
    }

    var bundleID: String = ""
    var appName: String = ""
    var windowTitle: String = ""
    var url: String?
    var selection: String?
    var axExcerpt: [String] = []
    var axState: AXState = .empty
    var screenshot: Screenshot?
    var screenshotDenied: Bool = false
    /// True when the frontmost window could not be identified and the capture
    /// fell back to the whole display.
    var screenshotFellBackToDisplay: Bool = false
    var wallMilliseconds: Int = 0
}

/// Read-only probes of what the user is looking at.
///
/// Everything here is bounded by construction: the AX tree walk carries its own
/// depth and node budget, and the ScreenCaptureKit bridge has a hard 2 s cap.
/// AX refusals come back as error codes immediately, so nothing here can hang.
enum Observe {
    /// Observation captured at SUMMON time, not at send time.
    ///
    /// MEASURED ROOT CAUSE: observing when the user pressed send saw Pop's own
    /// window as the frontmost app (the user had already clicked into the panel),
    /// so "what am I looking at?" answered about Pop's chat box instead of the
    /// page they meant. At summon time the frontmost app is still theirs.
    ///
    /// Deliberately NOT cleared after use: it is overwritten by the next summon,
    /// so a multi-turn conversation about one screen keeps working. Main-actor
    /// confined (every read/write site is a UI callback).
    @MainActor
    static var summonSnapshot: Observation?

    /// AX refuses fast with an error code, so a single call is already bounded.
    private static let axTimeout: TimeInterval = 1.5
    static let maxAXDepth = 10
    static let maxAXNodes = 250

    private static let browserBundleIDs = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.mozilla.firefox"
    ]

    // MARK: - App

    /// TEST-ONLY frontmost app. `nil` in production, where the real
    /// `NSWorkspace` frontmost application is read. A probe uses it to drive the
    /// `ui_observe` ref-staleness check (an app switch) without switching apps.
    static var frontmostOverride: (bundleID: String, name: String)?

    static func frontmostApp() -> (bundleID: String, name: String) {
        if let frontmostOverride { return frontmostOverride }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ("nil", "nil")
        }
        return (app.bundleIdentifier ?? "nil", app.localizedName ?? "nil")
    }

    static func isBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(where: { bundleID.hasPrefix($0) })
    }

    static func windowTitle(bundleID: String) -> String {
        guard let element = axApplication(bundleID: bundleID) else { return "nil" }
        guard let window = copyElement(element, kAXFocusedWindowAttribute) else { return "nil" }
        return copyString(window, kAXTitleAttribute) ?? "nil"
    }

    // MARK: - URL

    /// The focused page's URL. Browsers expose it differently, so this tries the
    /// documented window attribute first, then an address-bar heuristic. Returns
    /// nil for non-browsers and for anything unreadable.
    static func browserURL(bundleID: String) -> String? {
        guard isBrowser(bundleID: bundleID),
              let app = axApplication(bundleID: bundleID),
              let window = copyElement(app, kAXFocusedWindowAttribute)
        else { return nil }

        if let url = copyString(window, kAXURLAttribute), !url.isEmpty {
            return url
        }

        // Address-bar heuristic: the first text field in the toolbar, whose
        // identifier or description mentions URL/address/search.
        guard let toolbar = copyElement(window, kAXToolbarButtonAttribute) else { return nil }
        guard let field = firstElementMatching(
            of: toolbar,
            predicate: { element in
                guard let role = copyString(element, kAXRoleAttribute),
                      role == (kAXTextFieldRole as String)
                else { return false }
                let haystack = [
                    copyString(element, kAXIdentifierAttribute),
                    copyString(element, kAXDescriptionAttribute)
                ].compactMap { $0?.lowercased() }.joined(separator: " ")
                return haystack.contains("url") || haystack.contains("address")
                    || haystack.contains("search") || haystack.contains("smart")
            }
        ) else { return nil }

        guard let value = copyString(field, kAXValueAttribute) else { return nil }
        return value.isEmpty ? nil : value
    }

    // MARK: - Selection

    static func selectedText(bundleID: String) -> String? {
        guard let app = axApplication(bundleID: bundleID),
              let focused = copyElement(app, kAXFocusedUIElementAttribute)
        else { return nil }
        guard let value = copyString(focused, kAXSelectedTextAttribute) else { return nil }
        return value.isEmpty ? nil : value
    }

    // MARK: - AX tree

    /// Depth- and node-limited excerpt of the frontmost app's accessibility tree.
    /// Chromium/Electron expose no accessibility tree to clients until one sets
    /// `AXManualAccessibility` on the app element. Without this, a Brave or
    /// Chrome window yields a skeleton and Pop cannot see the page.
    private static let chromiumBundleIDs = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.microsoft.EDGE",
        "com.chromium.Chromium"
    ]

    static func isChromium(bundleID: String) -> Bool {
        if chromiumBundleIDs.contains(where: { bundleID.hasPrefix($0) }) { return true }
        // Electron apps carry no distinctive suffix; they all report the same
        // `com.github.Electron` bundle id.
        return bundleID.hasPrefix("com.github.Electron")
    }

    /// Turns on manual accessibility for the app. Logs the outcome so a probe
    /// can tell "not a Chromium app" from "asked and refused".
    static func enableManualAXIfChromium(bundleID: String) {
        guard isChromium(bundleID: bundleID) else { return }
        guard let app = axApplication(bundleID: bundleID) else {
            print("OBS_AX_MANUAL=failed no-app")
            fflush(stdout)
            return
        }
        let error = AXUIElementSetAttributeValue(
            app,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        if error.rawValue == 0 {
            print("OBS_AX_MANUAL=set")
            fflush(stdout)
        } else {
            print("OBS_AX_MANUAL=failed \(error.rawValue)")
            fflush(stdout)
        }
    }

    static func axExcerpt(bundleID: String) -> (lines: [String], state: Observation.AXState) {
        guard let app = axApplication(bundleID: bundleID) else {
            return ([], .denied)
        }

        func read() -> [String] {
            var lines: [String] = []
            var budget = maxAXNodes
            walk(app, depth: 0, budget: &budget, into: &lines)
            return lines
        }

        var lines = read()
        // A skeleton (root only) means the tree was read before Chromium turned
        // it on. ONE bounded retry after a short settle — never a loop.
        if isChromium(bundleID: bundleID), lines.count <= 1 {
            Thread.sleep(forTimeInterval: 0.3)
            lines = read()
        }

        if lines.isEmpty { return ([], .empty) }
        return (lines, .ok)
    }

    /// Finds the first element in `bundleID`'s AX tree whose title or
    /// description contains `needle` (case-insensitive), depth-first. Returns
    /// the element's role and display title with the element, or nil. Bounded
    /// by the SAME depth/node budget the excerpt walk uses, so a search can
    /// never traverse further than an observation would.
    static func findElement(
        bundleID: String,
        matching needle: String
    ) -> (role: String, title: String, element: AXUIElement)? {
        guard let app = axApplication(bundleID: bundleID) else { return nil }
        let query = needle.lowercased()
        guard !query.isEmpty else { return nil }
        var budget = maxAXNodes
        return search(app, depth: 0, budget: &budget, query: query)
    }

    private static func search(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Int,
        query: String
    ) -> (role: String, title: String, element: AXUIElement)? {
        guard depth < maxAXDepth, budget > 0 else { return nil }
        budget -= 1

        let title = copyString(element, kAXTitleAttribute)
        let description = copyString(element, kAXDescriptionAttribute)
        let haystack = [title, description].compactMap { $0?.lowercased() }
        if haystack.contains(where: { $0.contains(query) }) {
            let role = copyString(element, kAXRoleAttribute) ?? "?"
            let label = (title?.isEmpty == false ? title : description) ?? ""
            return (role, label, element)
        }

        guard let children = copyElements(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            guard budget > 0 else { return nil }
            if let found = search(child, depth: depth + 1, budget: &budget, query: query) {
                return found
            }
        }
        return nil
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Int,
        into lines: inout [String]
    ) {
        // Both stop conditions are checked before doing any more work, so a deep
        // or wide tree cannot turn this into an unbounded traversal.
        guard depth < maxAXDepth, budget > 0, !lines.isEmpty || depth == 0 else { return }
        budget -= 1

        let role = copyString(element, kAXRoleAttribute) ?? "?"
        var label = copyString(element, kAXTitleAttribute)
            ?? copyString(element, kAXDescriptionAttribute)
            ?? copyString(element, kAXIdentifierAttribute)
            ?? ""
        label = label.replacingOccurrences(of: "\n", with: " ")
        if label.count > 60 { label = String(label.prefix(57)) + "..." }

        var line = String(repeating: "  ", count: depth) + role
        if !label.isEmpty { line += ":\(label)" }
        if let value = copyString(element, kAXValueAttribute), !value.isEmpty {
            let short = value.count <= 40 ? value : String(value.prefix(37)) + "..."
            line += " (=\(short.replacingOccurrences(of: "\n", with: " ")))"
        }
        // Action names live under the "AXActions" attribute; reading them by
        // literal keeps this compiling without importing the AX private header.
        if let actions = copyStrings(element, "AXActions"), !actions.isEmpty {
            line += " [\(actions.prefix(3).joined(separator: ","))]"
        }
        lines.append(line)

        guard let children = copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            guard budget > 0 else { return }
            walk(child, depth: depth + 1, budget: &budget, into: &lines)
        }
    }

    // MARK: - Actionable elements (ui_observe)

    /// One ACTIONABLE element from the frontmost app's AX tree — the row a
    /// `ui_observe` snapshot exposes. `position` is the element's top-left in
    /// Quartz global coordinates when it publishes one.
    struct ActionableRow {
        let role: String
        let title: String
        let value: String
        let position: CGPoint?
        let element: AXUIElement
    }

    /// Walks the app's AX tree depth-first and collects up to `limit` ACTIONABLE
    /// elements: those exposing at least one AX action (a button, menu item) or
    /// a SETTABLE value (a field, checkbox). Bounded by the SAME depth/node
    /// budget the excerpt walk uses, so an observation can never traverse
    /// further than a read. No task knowledge: role/title/value are whatever the
    /// app publishes.
    static func actionableElements(bundleID: String, limit: Int = 30) -> [ActionableRow] {
        guard let app = axApplication(bundleID: bundleID) else { return [] }
        var budget = maxAXNodes
        var rows: [ActionableRow] = []
        collectActionable(app, depth: 0, budget: &budget, limit: limit, into: &rows)
        return rows
    }

    private static func collectActionable(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Int,
        limit: Int,
        into rows: inout [ActionableRow]
    ) {
        guard depth < maxAXDepth, budget > 0, rows.count < limit else { return }
        budget -= 1

        let actions = copyStrings(element, "AXActions") ?? []
        if !actions.isEmpty || isValueSettable(element) {
            let role = copyString(element, kAXRoleAttribute) ?? "?"
            let title = copyString(element, kAXTitleAttribute)
                ?? copyString(element, kAXDescriptionAttribute) ?? ""
            let rawValue = copyString(element, kAXValueAttribute) ?? ""
            let value = rawValue.count <= 40 ? rawValue : String(rawValue.prefix(37)) + "..."
            rows.append(ActionableRow(
                role: role,
                title: title.replacingOccurrences(of: "\n", with: " "),
                value: value.replacingOccurrences(of: "\n", with: " "),
                position: elementPosition(element),
                element: element
            ))
        }

        guard rows.count < limit,
              let children = copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            guard budget > 0, rows.count < limit else { return }
            collectActionable(child, depth: depth + 1, budget: &budget, limit: limit, into: &rows)
        }
    }

    /// Whether the element's value is writable (`ui_ax setValue` target).
    private static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return error.rawValue == 0 && settable.boolValue
    }

    /// The element's top-left position, or nil when it publishes none.
    private static func elementPosition(_ element: AXUIElement) -> CGPoint? {
        guard let value = copyAttribute(element, kAXPositionAttribute, as: AXValue.self),
              AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    // MARK: - Shareable-content cache

    /// MEASURED ROOT CAUSE of multi-second summons: the first
    /// `SCShareableContent.excludingDesktopWindows` per launch enumerates every
    /// on-screen window in the session, which costs seconds on a multi-display
    /// setup. Enumerating once on a background queue at launch and reusing the
    /// result turns the capture path from a cold stall into a map lookup.
    /// A serial queue rather than a lock: `NSLock.lock/unlock` is unavailable
    /// from an async context, and this cache is touched from a `Task`.
    private static let contentQueue = DispatchQueue(label: "com.pop.observe.content")
    private static var cachedContent: SCShareableContent?
    private static var cachedAt: Date?
    /// The window list changes as the user works; 30 s is short enough to be
    /// accurate and long enough to serve a burst of summons.
    private static let contentTTL: TimeInterval = 30

    /// Warms the cache off the main thread at launch. Fire-and-forget: a failure
    /// here just means the first capture pays the enumeration itself.
    nonisolated static func warmShareableContentCache() {
        DispatchQueue.global(qos: .utility).async {
            guard CGPreflightScreenCaptureAccess() else { return }
            Task {
                _ = try? await shareableContent()
            }
        }
    }

    /// The cached window list, re-enumerating at most every `contentTTL`.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = contentQueue.sync(execute: { () -> SCShareableContent? in
            guard let cachedContent, let cachedAt,
                  Date().timeIntervalSince(cachedAt) < contentTTL
            else { return nil }
            return cachedContent
        }) {
            return cached
        }

        let fresh = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        contentQueue.sync {
            cachedContent = fresh
            cachedAt = Date()
        }
        return fresh
    }

    // MARK: - Screenshot

    /// Still capture of the frontmost window. Capped at 2 s because ScreenCaptureKit
    /// can stall indefinitely when the permission prompt is unanswered.
    /// Window-scoped still capture of the frontmost app.
    ///
    /// MEASURED DEFECT: the previous version matched windows by title alone and
    /// fell back to `windows.first`, which captured an unrelated window — on a
    /// 7680x2160 single display that produced a fixed 1920x1080 quarter-region
    /// crop, and the model described the wrong part of the screen. Selection is
    /// now scoped by OWNING APPLICATION plus largest-area, and any mismatch
    /// between point size and pixel count is logged so it cannot hide again.
    ///
    /// THE WHOLE-DISPLAY PATH WAS REMOVED BY USER DIRECTIVE. Capture is
    /// WINDOW-SCOPED or it does not happen: when the target app's window cannot
    /// be located, the result is a typed "no window" outcome (nil shot, not
    /// denied), never a wider capture that would sweep in every other app's
    /// private content. The `fellBack` element is retained ONLY so the tuple
    /// shape does not change; it is now ALWAYS false and is deprecated in
    /// place — do not put a display capture behind it again.
    static func screenshot(bundleID: String, windowTitleHint: String) -> (shot: Observation.Screenshot?, denied: Bool, fellBack: Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ScreenshotBox()

        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            do {
                guard CGPreflightScreenCaptureAccess() else { return }
                let content = try await Self.shareableContent()

                let image: CGImage
                let windowFrame: CGRect?
                if let window = Self.pickWindow(
                    in: content,
                    bundleID: bundleID,
                    titleHint: windowTitleHint
                ) {
                    image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window),
                        configuration: Self.captureConfiguration(for: window.frame)
                    )
                    windowFrame = window.frame
                } else {
                    // NO WHOLE-DISPLAY CAPTURE, EVER (user directive). When the
                    // target app's window cannot be located — minimized, on
                    // another Space, or not yet open — the honest outcome is a
                    // typed "no window" result, not a wider grab. Nothing is
                    // captured, no fallback flag is set, and the displays are
                    // not touched: the log is the only trace.
                    _ = Self.noWindowResult(bundleID: bundleID, titleHint: windowTitleHint)
                    return
                }

                let scale = windowFrame.map { frame -> Double in
                    frame.width > 0 ? Double(image.width) / Double(frame.width) : 0
                }
                box.shot = Observation.Screenshot(
                    data: NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                        ?? Data(),
                    width: image.width,
                    height: image.height,
                    windowFrame: windowFrame,
                    scale: scale ?? 0
                )
            } catch {
                print("OBS_SCREENSHOT_ERROR \(error)")
                fflush(stdout)
                box.denied = true
            }
        }

        _ = semaphore.wait(timeout: .now() + 2.0)
        return (box.shot, box.denied, box.fellBack)
    }

    /// MEASURED: with only `showsCursor` set, ScreenCaptureKit clamped the
    /// capture to a default 1920x1080 regardless of window size — an unrelated
    /// window produced a quarter-screen crop. The output size must therefore be
    /// requested explicitly from the window's point size times the display's
    /// backing scale, or the image silently lies about what it shows.
    private static func captureConfiguration(for windowFrame: CGRect?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false

        let backingScale = windowFrame.flatMap { Self.backingScale(containing: $0) } ?? 1
        if let windowFrame {
            config.width = max(1, Int(windowFrame.width * backingScale))
            config.height = max(1, Int(windowFrame.height * backingScale))
        }
        return config
    }

    private static func backingScale(containing frame: CGRect) -> CGFloat? {
        NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.backingScaleFactor
    }

    /// The typed "no target window" outcome. Logs one sanitized line and returns
    /// an empty, NON-denied result — the window-scoped capture found nothing, so
    /// there is no image and no wider fallback. Extracted as its own seam so a
    /// headless probe can assert the log + the typed nil without a window server.
    @discardableResult
    static func noWindowResult(
        bundleID: String,
        titleHint: String
    ) -> (shot: Observation.Screenshot?, denied: Bool) {
        print(noWindowLogLine(bundleID: bundleID, titleHint: titleHint))
        fflush(stdout)
        return (nil, false)
    }

    /// PURE: the one-line log for a missing target window. Newlines/tabs become
    /// spaces and the hint is capped at 80 chars, so a hostile window title
    /// cannot forge log lines.
    static func noWindowLogLine(bundleID: String, titleHint: String) -> String {
        let flat = titleHint
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return "OBS_SCREENSHOT_NO_WINDOW bundle=\(bundleID) hint=\(String(flat.prefix(80)))"
    }

    private final class ScreenshotBox: @unchecked Sendable {
        var shot: Observation.Screenshot?
        var denied = false
        /// DEPRECATED IN PLACE: the whole-display path was removed by user
        /// directive, so this is ALWAYS false. Kept only for the return tuple.
        var fellBack = false
    }

    /// PURE ownership + size rule: a selectable window belongs to the target app
    /// and is larger than the 40×40 floor (drops tooltips, shadows and menu-bar
    /// extras). Extracted so a probe can exercise the rule without an SCWindow.
    static func isOwnedWindow(
        bundleID: String,
        ownerBundleID: String?,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        ownerBundleID == bundleID && width > 40 && height > 40
    }

    /// The frontmost app's largest on-screen window. Ownership is the primary
    /// filter: on a single wide display, several apps' windows are on screen at
    /// once and title matching alone picked the wrong one.
    private static func pickWindow(
        in content: SCShareableContent,
        bundleID: String,
        titleHint: String
    ) -> SCWindow? {
        let candidates = content.windows.filter {
            Self.isOwnedWindow(
                bundleID: bundleID,
                ownerBundleID: $0.owningApplication?.bundleIdentifier,
                width: $0.frame.width,
                height: $0.frame.height
            )
        }
        guard !candidates.isEmpty else { return nil }

        if titleHint != "nil", let match = candidates.first(where: { $0.title == titleHint }) {
            return match
        }
        // Largest area: the main window of the focused app, not a tooltip.
        return candidates.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }

    // MARK: - Aggregate

    /// The CHEAP half of a summon-time capture: frontmost app identity, window
    /// title, URL and selection. No AX tree walk, no screenshot — both of which
    /// cost hundreds of milliseconds to seconds. Must return fast enough to sit
    /// on the hotkey path.
    static func observeQuick() -> Observation {
        let start = Date()
        let (bundleID, name) = frontmostApp()

        let queue = DispatchQueue(label: "com.pop.observe.quick", attributes: .concurrent)
        let group = DispatchGroup()
        let box = AXBox()

        queue.async(group: group) { box.title = windowTitle(bundleID: bundleID) }
        queue.async(group: group) { box.url = browserURL(bundleID: bundleID) }
        queue.async(group: group) { box.selection = selectedText(bundleID: bundleID) }
        _ = group.wait(timeout: .now() + axTimeout)

        var observation = Observation()
        observation.bundleID = bundleID
        observation.appName = name
        observation.windowTitle = box.title ?? "nil"
        observation.url = box.url
        observation.selection = box.selection
        observation.axState = .empty
        observation.wallMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        return observation
    }

    /// The EXPENSIVE half, run OFF the summon path against the app the quick pass
    /// already recorded.
    ///
    /// Neither heavy probe needs the target to be frontmost: AX addresses an app
    /// by pid, and the screenshot is window-scoped by owning application plus
    /// title/frame. So the work can start after Pop has activated itself, which
    /// is exactly what the hotkey path must not wait for. Bounded at 2 s.
    static func observeHeavy(target: Observation) -> Observation {
        var observation = target
        let start = Date()

        let queue = DispatchQueue(label: "com.pop.observe.heavy", attributes: .concurrent)
        let group = DispatchGroup()
        let box = AXBox()

        queue.async(group: group) {
            let excerpt = axExcerpt(bundleID: target.bundleID)
            box.axLines = excerpt.lines
            box.axState = excerpt.state
        }
        queue.async(group: group) {
            let shot = screenshot(bundleID: target.bundleID, windowTitleHint: target.windowTitle)
            box.shot = shot.shot
            box.screenshotDenied = shot.denied
            box.screenshotFellBack = shot.fellBack
        }
        _ = group.wait(timeout: .now() + 2.0)

        observation.axExcerpt = box.axLines
        observation.axState = box.axState
        observation.screenshot = box.shot
        observation.screenshotDenied = box.screenshotDenied
        observation.screenshotFellBackToDisplay = box.screenshotFellBack
        observation.wallMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        return observation
    }

    /// Quick + heavy, as one snapshot. Kept for the observe/context probes and
    /// the send-time fallback; the summon path uses the split instead.
    static func observeAll() -> Observation {
        let start = Date()
        var observation = observeHeavy(target: observeQuick())
        // Total wall time for the merged work, not just the heavy half.
        observation.wallMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        return observation
    }

    private final class AXBox: @unchecked Sendable {
        var title: String?
        var url: String?
        var selection: String?
        var axLines: [String] = []
        var axState: Observation.AXState = .empty
        var shot: Observation.Screenshot?
        var screenshotDenied = false
        var screenshotFellBack = false
    }

    // MARK: - AX plumbing

    private static func axApplication(bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// One attribute read with a copy. Never throws; a refused read is nil.
    ///
    /// Typed variants rather than `AnyObject?` at every call site: AX hands back
    /// an untyped CFTypeRef, and casting it once here keeps the callers honest.
    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String, as: T.Type) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error.rawValue == 0 /* kAXErrorSuccess */, let value else { return nil }
        return value as? T
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute, as: String.self)
    }

    private static func copyStrings(_ element: AXUIElement, _ attribute: String) -> [String]? {
        copyAttribute(element, attribute, as: [String].self)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        copyAttribute(element, attribute, as: AXUIElement.self)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        copyAttribute(element, attribute, as: [AXUIElement].self)
    }

    private static func firstElementMatching(
        of element: AXUIElement,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue = [element]
        var visited = 0
        while !queue.isEmpty, visited < 60 {
            let current = queue.removeFirst()
            visited += 1
            if current != element, predicate(current) { return current }
            if let children = copyElements(current, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(12))
            }
        }
        return nil
    }
}

// MARK: - Context assembly

extension Observe {
    /// Hard ceiling for the always-injected context block. It rides on EVERY
    /// turn, so it is bounded by construction: a screen/AX/screenshot dump is
    /// what derailed the small on-device model (measured: an AX tree prompt of
    /// ~40,000 chars). 300 is enough for an app name, a window title and a short
    /// selection, and small enough that the model's attention stays on the
    /// question. Anything more detailed is requested via a tool.
    static let contextCharCap = 300

    /// Compact structured block prepended to the user's message when context mode
    /// is on. Deliberately terse: it is prepended to every turn, so every extra
    /// line is paid for on every request. Only the frontmost app, the window
    /// title and the current selection are included — never the AX tree and
    /// never a screenshot.
    static func makeContextPrefix(_ obs: Observation) -> String {
        var lines: [String] = ["[screen context]"]
        lines.append("app: \(obs.appName) (\(obs.bundleID))")
        if obs.windowTitle != "nil" { lines.append("window: \(obs.windowTitle)") }
        if let selection = obs.selection {
            let trimmed = selection.count > 200
                ? String(selection.prefix(200)) + "..."
                : selection
            lines.append("selection: \(trimmed)")
        }
        // PRIVACY + RECOVERY: capture is WINDOW-SCOPED or it does not happen, so
        // a clean capture that found NO window is a typed, model-recoverable
        // condition — never a whole-display grab. Gated on Screen Recording
        // actually being granted so the line never misattributes a permission
        // gap as a missing window; the model can then raise the app
        // (`app_manage activate`) and retry.
        if obs.screenshot == nil, !obs.screenshotDenied,
           Permissions.screenRecording() == .granted {
            let who = obs.appName.isEmpty ? obs.bundleID : obs.appName
            lines.append(
                "screen: no window found for \(who.isEmpty ? "the front app" : who) — "
                + "locate or raise the app's window first (it may be minimized or on "
                + "another Space), then activate it and retry."
            )
        }
        var text = lines.joined(separator: "\n")
        if text.count > contextCharCap {
            text = String(text.prefix(contextCharCap)) + "..."
        }
        return text
    }
}

// MARK: - Permissions

enum PermissionState: String {
    case granted
    case denied

    var label: String { rawValue }
}

enum Permissions {
    /// Checked WITHOUT prompting: a probe must never put a modal on screen.
    static func accessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func screenRecording() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// The prompting variants are only ever called from the settings UI.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}