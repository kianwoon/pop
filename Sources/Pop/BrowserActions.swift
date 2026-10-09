import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import ApplicationServices

/// A failed `ui_observe` ref lookup: a message the model reads and acts on.
struct ObservedRefError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// APPROVAL-GATED ACTING ON THE USER'S SCREEN.
///
/// Pop can now PERCEIVE (multi-window `screen_read`) and PLAN (`plan_update`).
/// This is the ACTING layer that closes the loop, and it is the most dangerous
/// surface in the app: a click and a keystroke are real input delivered to
/// whatever window happens to be under the cursor.
///
/// The guards, all in code, none model-dependent:
///
///  * CLICKS AND NAVIGATION ARE AUTONOMOUS (the user's trust model):
///    `ui_click`/`browser_focus_tab`/`browser_open_url` are navigation-class
///    and run with no approval card, but every action is logged. Only `ui_type`
///    is gated, because typed text can send a message to a real person.
///  * ACCESSIBILITY IS CHECKED FIRST, and its absence is an honest failure with
///    the place to fix it. Posting events without the TCC grant silently
///    does nothing, and "I clicked" would then be a lie.
///  * `ui_click` AND `ui_scroll` MAY ONLY LAND ON A VISIBLE APP WINDOW. This is
///    computer-use: act on the apps on screen the way a human would, so the
///    bounds cover EVERY on-screen app window except Pop's own panel — System
///    Settings included, which is the human path for macOS settings changes. The
///    bounds come from the SAME ScreenCaptureKit enumeration `screen_read` uses,
///    so a browser click lands where the model was told it could see. A point
///    outside every such window is refused without an event. Pop's own panel is
///    therefore not a valid target by construction, not by a special case.
///  * ONLY WHAT THE MODEL CHOSE IS TYPED. `ui_type` sends the exact string it
///    was given and nothing else; there is no keylogging, no capture, no
///    global hook.
///
/// No task knowledge lives here: no app names, no site names, no "click the
/// search box". The browser allowlist is `ScreenOCR`'s, a session detail.
enum BrowserActions {
    // MARK: - Seams

    /// The seam the probe replaces so `browser_open_url` can be checked
    /// WITHOUT opening anything on the user's machine. `nil` in production:
    /// the real `open` runs.
    static var launcherOverride: (@Sendable ([String]) async -> Void)?

    /// TEST-ONLY bounds source. `nil` in production, where the bounds always
    /// come from `allowlistedWindowBounds()` (the live ScreenCaptureKit
    /// enumeration). The probe stands up its OWN window to exercise the real
    /// CGEvent path, and its window is not a browser — so it supplies its
    /// frame here. The shipped guard is unchanged; this only lets the probe
    /// drive it.
    static var boundsOverride: (@Sendable () async -> [CGRect])?

    /// TEST-ONLY Accessibility answer. `nil` in production: the real
    /// `AXIsProcessTrusted()` is read.
    static var accessibilityOverride: Bool?

    /// TEST-ONLY event sink, so the guard arm can prove NO event was posted
    /// without depending on the user's TCC state. `nil` in production: events
    /// go to `.cghidEventTap`.
    static var eventSinkOverride: (@Sendable (CGEvent) -> Void)?

    /// Whether this act should drive the ghost cursor and restore the user's
    /// pointer: off the probe sink (a probe must not warp the developer's REAL
    /// cursor; the real-CGEvent arm clears the sink, so `VirtualCursor.isEnabled`
    /// is the second gate) and only when the ghost is enabled. One seam, so a
    /// future mouse act reusing this funnel cannot silently skip ghost+restore.
    fileprivate static var shouldGhost: Bool {
        eventSinkOverride == nil && VirtualCursor.isEnabled
    }

    /// What to do with an already-open browser tab before opening a URL.
    ///
    /// WHY: the `open` command ALWAYS opens a new tab, so asking Pop to show a
    /// page the user already had open spawned a duplicate — the retest bug. The
    /// DECISION is pure (and probed); only the AppleScript leg below touches a
    /// real browser.
    enum ReusePlan: Equatable, Sendable {
        /// A tab already IS the target (same host + path): raise it, no new tab.
        /// The locators are the stable `windowIndex`/`tabIndex` from `openTabs`,
        /// so activation needs no re-walk.
        case focusExisting(windowIndex: Int, tabIndex: Int)
        /// Same host, different path: navigate that tab in place.
        case navigateInPlace(windowIndex: Int, tabIndex: Int)
        /// No usable match, or a non-http(s) scheme: the current `open` behavior.
        case openNew
    }

    /// A reuse plan plus the PREFERENCE that produced it, so the
    /// `BROWSER_TAB_REUSE` trace can name why a tab won.
    struct ReuseDecision: Equatable, Sendable {
        let plan: ReusePlan
        /// `"active"` (active tab of the front window), `"closest-path"`
        /// (longest common path prefix among host matches), `"first-match"`
        /// (the lone/earliest host match), or `"open-new"` (no host match /
        /// non-http(s) scheme).
        let picked: String
    }

    /// Picks the reuse plan for `targetURL` given the browser's open tabs.
    ///
    /// THE INVARIANT: tab reuse targets the tab the USER means. Selection among
    /// host-matching candidates is, in order:
    ///   (a) the ACTIVE tab of the ACTIVE (front) window, if it matches the host;
    ///   (b) the candidate with the closest PATH — longest common leading path
    ///       segments; ties → earliest — as `navigateInPlace`, or `focusExisting`
    ///       when a candidate's path IS the target path;
    ///   (c) the first host match (the old behavior) when only one matches.
    ///
    /// WHY: with two linkedin.com tabs open, matching the FIRST host match
    /// navigates whichever Brave happens to enumerate first — "it didn't find MY
    /// tab". Preferring the active front tab (then path closeness) targets what
    /// the user is actually looking at. Host match is EXACT (case-insensitive);
    /// path match ignores a trailing slash and the fragment; the query string is
    /// deliberately not part of the match. Anything not http(s) — a `mailto:`,
    /// an unknown scheme — opens new.
    static func reuseDecision(
        targetURL: URL,
        openTabs: [TabFocus.OpenTab]
    ) -> ReuseDecision {
        guard let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let targetHost = targetURL.host?.lowercased(),
              !targetHost.isEmpty else {
            return ReuseDecision(plan: .openNew, picked: "open-new")
        }
        let targetPath = normalizedPath(targetURL)

        // Host-matching candidates, in enumeration order. An unreadable URL is
        // no host match, exactly as before.
        var candidates: [Int] = []
        for (index, tab) in openTabs.enumerated() {
            guard let raw = tab.url,
                  let url = URL(string: raw),
                  let host = url.host?.lowercased(),
                  host == targetHost else { continue }
            candidates.append(index)
        }
        guard !candidates.isEmpty else {
            return ReuseDecision(plan: .openNew, picked: "open-new")
        }

        // (a) The ACTIVE tab of the ACTIVE (front) window, if it matches.
        if let index = candidates.first(where: {
            openTabs[$0].active && openTabs[$0].isActiveWindow
        }) {
            return reuseDecision(for: index, targetPath: targetPath, tabs: openTabs, picked: "active")
        }

        // (c) A lone host match is the first-match fallback (the old behavior).
        if candidates.count == 1 {
            return reuseDecision(
                for: candidates[0], targetPath: targetPath, tabs: openTabs, picked: "first-match"
            )
        }

        // (b) Closest PATH: longest common leading path segments, ties → earliest.
        var best = candidates[0]
        var bestScore = commonPathPrefixLength(path(of: openTabs[best]), targetPath)
        for index in candidates.dropFirst() {
            let score = commonPathPrefixLength(path(of: openTabs[index]), targetPath)
            if score > bestScore {
                best = index
                bestScore = score
            }
        }
        return reuseDecision(for: best, targetPath: targetPath, tabs: openTabs, picked: "closest-path")
    }

    /// The plan for one chosen candidate: `focusExisting` when its path IS the
    /// target path, else `navigateInPlace`, carrying the tab's stable locators.
    private static func reuseDecision(
        for index: Int,
        targetPath: String,
        tabs: [TabFocus.OpenTab],
        picked: String
    ) -> ReuseDecision {
        let tab = tabs[index]
        let plan: ReusePlan
        if let raw = tab.url, let url = URL(string: raw), normalizedPath(url) == targetPath {
            plan = .focusExisting(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
        } else {
            plan = .navigateInPlace(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
        }
        return ReuseDecision(plan: plan, picked: picked)
    }

    /// A tab's normalized path, or "" when its URL is unreadable.
    private static func path(of tab: TabFocus.OpenTab) -> String {
        guard let raw = tab.url, let url = URL(string: raw) else { return "" }
        return normalizedPath(url)
    }

    /// Number of leading path SEGMENTS two paths share (`/jobs/view/1` vs
    /// `/jobs` → 1). The path-closeness metric for preference (b).
    static func commonPathPrefixLength(_ a: String, _ b: String) -> Int {
        let left = a.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let right = b.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var shared = 0
        while shared < left.count, shared < right.count, left[shared] == right[shared] {
            shared += 1
        }
        return shared
    }

    /// Path with the fragment dropped and a single trailing slash removed
    /// ("/notifications/" == "/notifications"); an empty path normalises to "/".
    static func normalizedPath(_ url: URL) -> String {
        var path = url.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// The `plan=` token for the `BROWSER_TAB_REUSE` log line.
    static func planName(_ plan: ReusePlan) -> String {
        switch plan {
        case .focusExisting: return "focusExisting"
        case .navigateInPlace: return "navigateInPlace"
        case .openNew: return "openNew"
        }
    }

    /// Builds the argv `browser_open_url` would run. Separated from running it
    /// so the construction is testable without a side effect.
    static func openCommand(for rawURL: String) throws -> [String] {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolFailure(message: "`url` is empty.")
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme),
              url.host?.isEmpty == false || scheme == "file"
        else {
            throw ToolFailure(message: """
                "\(trimmed)" is not an http, https or file URL Pop will open.
                """)
        }
        // `--` so a URL that begins with a dash cannot become a `open` flag.
        return ["/usr/bin/open", "--", trimmed]
    }

    // MARK: - browser_open_url

    /// Brings the URL forward in the user's default browser.
    ///
    /// The honest limit: `open` reports only whether the LAUNCH SUCCEEDED. It
    /// cannot tell Pop whether it activated an existing tab or opened a new
    /// one, so the result says exactly that and no more. Anything stronger
    /// would be a guess about a window Pop has not read.
    static func openURL(_ rawURL: String) async -> String {
        let argv: [String]
        do {
            argv = try openCommand(for: rawURL)
        } catch let failure as ToolFailure {
            return "ERROR: \(failure.message)"
        } catch {
            return "ERROR: could not open that URL: \(error.localizedDescription)"
        }

        print("UI_ACTION open \(argv.last ?? "")")
        fflush(stdout)

        if let launcherOverride {
            await launcherOverride(argv)
            return "open: sent to the system opener (test seam); the URL is \(argv.last ?? "")."
        }

        // TAB REUSE: the `open` command ALWAYS spawns a new tab, so a URL the
        // user already has open would duplicate it (the retest bug). Ask the
        // default browser's own AppleScript which tabs exist, then raise or
        // navigate the matching one. A non-allowlisted browser, a denied
        // Automation grant, or no match falls straight through to `open`.
        if let targetURL = URL(string: argv.last ?? ""),
           let bundleID = TabFocus.defaultBrowserBundleID(),
           ScreenOCR.browserBundleIDs.contains(bundleID),
           // A `tell application id` to a CLOSED browser would LAUNCH it; when
           // it is not running there are no tabs to reuse, so fall to `open`.
           TabFocus.isRunning(bundleID) {
            let decision = reuseDecision(
                targetURL: targetURL,
                openTabs: await TabFocus.openTabs(bundleID: bundleID)
            )
            print("BROWSER_TAB_REUSE plan=\(Self.planName(decision.plan)) picked=\(decision.picked) host=\(targetURL.host ?? "")")
            fflush(stdout)
            switch decision.plan {
            case .focusExisting(let windowIndex, let tabIndex):
                if await TabFocus.activateTab(
                    bundleID: bundleID, windowIndex: windowIndex, tabIndex: tabIndex, navigateTo: nil
                ) {
                    return """
                        open: raised the existing tab for \(argv.last ?? ""). \
                        Use `screen_read` to verify it is now visible.
                        """
                }
            case .navigateInPlace(let windowIndex, let tabIndex):
                if await TabFocus.activateTab(
                    bundleID: bundleID, windowIndex: windowIndex, tabIndex: tabIndex, navigateTo: argv.last
                ) {
                    return """
                        open: navigated the existing \(targetURL.host ?? "") tab to \
                        \(argv.last ?? ""). Use `screen_read` to verify it is now visible.
                        """
                }
            case .openNew:
                break
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "ERROR: could not run the opener: \(error.localizedDescription)"
        }
        let status = process.terminationStatus
        guard status == 0 else {
            return "ERROR: the opener exited with status \(status)."
        }
        // Exactly what is known. Not "the tab is now open".
        return """
            open: the system opener accepted \(argv.last ?? ""). \
            Use `screen_read` to see whether the page is now visible.
            """
    }

    // MARK: - Guards

    /// The honest Accessibility failure, shared by every event-posting tool.
    fileprivate static func requireAccessibility() -> String? {
        let trusted = accessibilityOverride ?? AXIsProcessTrusted()
        guard trusted else {
            return """
                Accessibility permission is not granted, so no click or \
                keystroke can be delivered — the event would be dropped \
                silently. Grant it in System Settings → Privacy & Security → \
                Accessibility (Pop's Settings window has the row), then ask again.
                """
        }
        return nil
    }

    /// The allowlisted browsers' on-screen window bounds, from the SAME
    /// enumeration `screen_read` uses. This is the BROWSER-specific surface —
    /// the read surface and browser navigation — not the computer-use act
    /// surface; see `visibleWindowBounds()`.
    static func allowlistedWindowBounds() async -> [CGRect] {
        if let boundsOverride { return await boundsOverride() }
        guard CGPreflightScreenCaptureAccess() else { return [] }
        guard let content = try? await SCShareableContentRetainer.content() else { return [] }
        return ScreenOCR.allowedWindowFrames(in: content)
    }

    /// EVERY on-screen app window's bounds except Pop's own panel — the
    /// computer-use act surface.
    ///
    /// WHY: computer-use means acting on the apps on screen the way a human
    /// would. The click/scroll guard used to be bounded to the allowlisted
    /// BROWSER windows only, which made the human path structurally impossible:
    /// a measured "change the desktop wallpaper to black" turn had no way to
    /// reach System Settings → Wallpaper, so it degraded into seven gated shell
    /// attempts. The READ surface (`screen_read`) stays browser-only; only the
    /// ACT surface widens. Pop's own panel is never in this set.
    static func visibleWindowBounds() async -> [CGRect] {
        if let boundsOverride { return await boundsOverride() }
        guard CGPreflightScreenCaptureAccess() else { return [] }
        guard let content = try? await SCShareableContentRetainer.content() else { return [] }
        return ScreenOCR.visibleWindowFrames(in: content)
    }

    /// Whether the point lies inside at least one visible app window. Pop's own
    /// panel is not in that set, so it cannot be a target.
    static func pointIsAllowed(_ point: CGPoint, in bounds: [CGRect]) -> Bool {
        bounds.contains { $0.insetBy(dx: 0, dy: 0).contains(point) }
    }

    // MARK: - ui_click

    /// One left click at absolute screen coordinates.
    ///
    /// Coordinates arrive in the SAME space `screen_read` reports bounds in:
    /// Quartz global screen coordinates, origin top-left. A model that read
    /// the bounds can compute a target; this is what makes that arithmetic
    /// actionable rather than decorative.
    static func click(x: Int, y: Int) async -> String {
        if let denied = requireAccessibility() { return "ERROR: \(denied)" }

        let point = CGPoint(x: x, y: y)
        let bounds = await visibleWindowBounds()
        guard !bounds.isEmpty else {
            return """
                ERROR: no visible app window bounds are known right now, so the \
                click at (\(x), \(y)) was refused rather than posted blind. Read \
                the screen first.
                """
        }
        guard pointIsAllowed(point, in: bounds) else {
            return """
                ERROR: (\(x), \(y)) is outside every on-screen app window, \
                so nothing was clicked. Click inside a visible app window — \
                Pop will not click its own panel or the desktop.
                """
        }

        // PID-FIRST CLICK. The zero-interference path: post the click straight
        // into the target process (CGEventPostToPid), so it reaches
        // NSWindow.sendEvent() with NO cursor movement and NO focus change. The
        // HID+ghost path below stays intact as the FALLBACK — one code path, one
        // funnel. Probes (including the real-CGEvent arm that clears the sink)
        // never pid-post, so probe bytes stay identical.
        let isProbeRun = CommandLine.arguments.contains {
            $0.hasPrefix("--test-") || $0.hasPrefix("--user-")
        }
        if eventSinkOverride == nil, !isProbeRun,
           ProcessInfo.processInfo.environment["POP_PID_CLICK"] != "0" {
            if let target = clickTargetWindow(at: point) {
                // The ghost is Pop's visible cursor regardless of mechanism.
                if shouldGhost { await MainActor.run { VirtualCursor.move(to: point) } }
                if postClickToWindow(
                    pid: target.pid, windowNumber: target.windowNumber,
                    at: point, windowBounds: target.bounds
                ) {
                    if shouldGhost {
                        await MainActor.run { VirtualCursor.clickPulse(at: point) }
                        await MainActor.run { VirtualCursor.end() }
                    }
                    print("UI_ACTION click pid \(target.pid) window \(target.windowNumber) \(x),\(y)")
                    fflush(stdout)
                    return """
                        click: posted one cursorless left click at (\(x), \(y)) — the \
                        user's pointer did not move. Note: some apps (notably \
                        Chromium-based ones in the background) ignore or drop \
                        process-targeted events, so if the effect did not land, \
                        retry with POP_PID_CLICK=0 or verify first with screen_read.
                        """
                }
                print("PID_CLICK_FALLBACK reason=post-failed")
                fflush(stdout)
            } else {
                print("PID_CLICK_FALLBACK reason=no-window")
                fflush(stdout)
            }
        }

        // Ghost cursor: announce the act, then return the user's pointer.
        // `shouldGhost` holds the probe gate (see its comment).
        var savedCursor: CGPoint?
        if shouldGhost {
            // Quartz top-left, the same space as x/y; nil skips the restore.
            savedCursor = CGEvent(source: nil)?.location
            // Lead the act: the ghost arrives before the burst does.
            await MainActor.run { VirtualCursor.move(to: point) }
        }

        // Move, press, release. A click with no preceding mouseMoved lands on
        // whatever the pointer was already over on some system paths.
        let source = CGEventSource(stateID: .combinedSessionState)
        let events = [
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left),
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                    mouseCursorPosition: point, mouseButton: .left),
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                    mouseCursorPosition: point, mouseButton: .left)
        ]
        post(events.compactMap { $0 })

        if shouldGhost {
            await MainActor.run { VirtualCursor.clickPulse(at: point) }

            // Return the user's pointer. The warp ALONE races: CGEventPost
            // delivery is async, so it can execute before the HID system drains
            // the burst — whose mouseMoved then lands LAST and leaves the cursor
            // at the target. Events posted to the SAME tap are delivered IN
            // ORDER, so queue a restore mouseMoved through the same funnel; it
            // lands after the burst and wins regardless of delivery latency. The
            // warp is kept as the immediate-path correction for the case the
            // burst already drained — every interleaving of (queued burst,
            // queued restore, warp) ends with the cursor at the saved position.
            // The restore re-asserts the pre-act hover (the pointer was already
            // there), so it disturbs nothing.
            if let savedCursor {
                if let restore = CGEvent(
                    mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: savedCursor, mouseButton: .left
                ) {
                    post([restore])
                }
                CGWarpMouseCursorPosition(savedCursor)
                CGAssociateMouseAndMouseCursorPosition(1)
                print("GHOST_CURSOR saved=\(savedCursor.x),\(savedCursor.y)")
                fflush(stdout)
            }
            await MainActor.run { VirtualCursor.end() }
        }

        print("UI_ACTION click \(x),\(y)")
        fflush(stdout)
        return """
            click: posted one left click at (\(x), \(y)). Use `screen_read` to \
            verify what it landed on.
            """
    }

    /// Posts events through the real HID tap, or through the probe's sink.
    /// One funnel, so the guard arm's "no event was posted" is the SAME code
    /// path production uses.
    fileprivate static func post(_ events: [CGEvent]) {
        if let eventSinkOverride {
            for event in events { eventSinkOverride(event) }
            return
        }
        for event in events { event.post(tap: .cghidEventTap) }
    }

    /// The routable target for a pid-first click: which process, which window,
    /// and that window's Quartz-global bounds (top-left origin).
    fileprivate struct PidClickTarget {
        let pid: pid_t
        let windowNumber: Int
        let bounds: CGRect
    }

    /// The topmost on-screen window whose bounds contain `point`, EXCLUDING
    /// Pop's own process — the same spirit as `visibleWindowBounds`, which never
    /// returns Pop's panel. Quartz list order is front-to-back, so the first
    /// match is the topmost. `nil` means nothing routable (desktop, Pop's own
    /// panel, locked-down window) and the caller falls back to HID+ghost.
    fileprivate static func clickTargetWindow(at point: CGPoint) -> PidClickTarget? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ownPid,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  // Normal windows only (layer 0): the desktop, menu bar, and
                  // other chrome are not click targets.
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0,
                  let boundsRaw = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsRaw as CFDictionary),
                  bounds.contains(point)
            else { continue }
            return PidClickTarget(pid: owner, windowNumber: number, bounds: bounds)
        }
        return nil
    }

    /// Best-effort handle to the PRIVATE `CGEventSetWindowLocation` that
    /// ghostpoke loads via `dlsym` (CoreGraphics does not export it in a header).
    /// `nil` when the symbol is absent — then the window-local point is simply
    /// not set, exactly ghostpoke's own best-effort behavior.
    private static let windowLocationSetter: (@convention(c) (UnsafeMutableRawPointer?, CGPoint) -> Void)? = {
        let paths = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            if let symbol = dlsym(handle, "CGEventSetWindowLocation") {
                return unsafeBitCast(
                    symbol,
                    to: (@convention(c) (UnsafeMutableRawPointer?, CGPoint) -> Void).self
                )
            }
        }
        return nil
    }()

    /// Link-bearing browser bundle-id prefixes (hasPrefix match, the same idiom
    /// as `Observe.isChromium`). These get a CLEAN click — never the background
    /// Command mask, which in a link UI IS cmd+click = open-in-new-tab.
    private static let browserBundleIDPrefixes = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.chromium.Chromium",
        "org.mozilla.firefox",
        "com.apple.Safari"
    ]

    /// Post a left down+up straight into `pid`'s queue via `CGEventPostToPid`,
    /// bound to `windowNumber`. FAITHFUL PORT of `ghostpoke_probe.py`'s click
    /// path (`_post_click` + `_apply_fields`) — the field set is LOAD-BEARING,
    /// measured, not decorative: posting only fields 91/92 + the global location
    /// POSTED OK but was DROPPED (two clicks on Brave window 3396 left
    /// `screen_read` unchanged, 4933→4935 bytes). The full recipe writes FOUR
    /// integer fields (button 3, subtype 7, window 91/92), the global location,
    /// AND the window-local location.
    ///
    /// The event never passes through the shared cursor, so the user's pointer
    /// does not move. Returns true once both events are constructed and posted.
    static func postClickToWindow(
        pid: pid_t, windowNumber: Int, at point: CGPoint, windowBounds: CGRect
    ) -> Bool {
        // WHAT THE PYTHON DOES: it derives the window-local point as
        // `screen - windowOrigin` (Quartz top-left space, NO y-flip) and feeds
        // that to NSEvent.mouseEvent — mirrored exactly here, even though
        // AppKit's documented contract calls for window-BASE (bottom-left)
        // coords. Both the global and the local point are set because the
        // receiver's hit-test reads the local point while routing reads the
        // global one.
        let local = CGPoint(
            x: point.x - windowBounds.minX,
            y: point.y - windowBounds.minY
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        let seed = Int(timestamp * 1_000_000) & 0x7FFF_FFFF
        func make(_ type: NSEvent.EventType, eventNumber: Int) -> CGEvent? {
            NSEvent.mouseEvent(
                with: type, location: local, modifierFlags: [], timestamp: timestamp,
                windowNumber: windowNumber, context: nil, eventNumber: eventNumber,
                clickCount: 1, pressure: 1.0
            )?.cgEvent
        }
        guard let down = make(.leftMouseDown, eventNumber: seed),
              let up = make(.leftMouseUp, eventNumber: seed + 1) else { return false }
        // ghostpoke sets kCGEventFlagMaskCommand when the target is not the
        // active app — the trick that makes background apps accept the event at
        // all. But in a link-bearing UI that flag IS cmd+click: it opens a new
        // tab instead of clicking. So browsers always get a CLEAN click — a
        // dropped event is caught by the brain's screen_read verify and retried,
        // whereas a wrong-tab open is not. Resolve the bundle id ONCE.
        let target = NSRunningApplication(processIdentifier: pid)
        let targetIsActive = target?.isActive ?? false
        let targetBundleID = target?.bundleIdentifier ?? ""
        let isLinkBearingBrowser = browserBundleIDPrefixes.contains {
            targetBundleID.hasPrefix($0)
        }
        let shouldMask = !targetIsActive && !isLinkBearingBrowser
        // A missing private setter must not degrade SILENTLY (still best-effort).
        if windowLocationSetter == nil {
            print("PID_CLICK_NO_SETTER=1")
            fflush(stdout)
        }
        for event in [down, up] {
            // Field 3 = kCGMouseEventButtonNumber (0 = left).
            event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            // Field 7 = kCGMouseEventSubtype (ghostpoke's default 3).
            event.setIntegerValueField(.mouseEventSubtype, value: 3)
            // Fields 91/92 = the window-routing pointers.
            event.setIntegerValueField(
                .mouseEventWindowUnderMousePointer, value: Int64(windowNumber)
            )
            event.setIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber)
            )
            // Global location (CGEventSetLocation) AND the private window-local
            // setter — the Python sets both.
            event.location = point
            if shouldMask { event.flags = .maskCommand }
            if let setter = windowLocationSetter {
                setter(Unmanaged.passUnretained(event).toOpaque(), local)
            }
            event.postToPid(pid)
        }
        return true
    }

    // MARK: - ui_type

    /// Types the given text at the current focus, one character at a time.
    ///
    /// A newline in the text is a Return keypress — the one special key this
    /// piece supports. Anything else the caller wants to press is a different
    /// tool, not a secret code path in this one.
    static func type(_ text: String) async -> String {
        if let denied = requireAccessibility() { return "ERROR: \(denied)" }
        guard !text.isEmpty else {
            return "ERROR: `text` is empty, so nothing was typed."
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        var returns = 0
        for character in text {
            if character == "\n" {
                let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
                post([down, up].compactMap { $0 })
                returns += 1
                continue
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return "ERROR: could not build a keyboard event; nothing more was typed."
            }
            // The string rides on BOTH events, which is what makes the keypress
            // a keypress rather than a bare modifier tap.
            down.keyboardSetUnicodeString(stringLength: character.utf16.count,
                                         unicodeString: Array(String(character).utf16))
            up.keyboardSetUnicodeString(stringLength: character.utf16.count,
                                       unicodeString: Array(String(character).utf16))
            post([down, up])
        }

        // The LENGTH only, never the content: this line is a log, and a log
        // that printed what the model typed into the user's window would be a
        // transcript of the user's own data.
        print("UI_ACTION type \(text.count) chars")
        fflush(stdout)
        return """
            type: sent \(text.count) character(s)\
            \(returns > 0 ? " (including \(returns) Return)" : "") to the current \
            focus. Use `screen_read` to verify what was typed.
            """
    }

    /// THE VERIFY-AFTER-ACT RULE. One generic rule, in the same place as the
    /// other honesty rules: a delivered action is not a delivered outcome.
    /// A click that landed on the wrong control, or keystrokes that went
    /// nowhere, look identical from here unless the screen is read again.
    static let verifyAfterActRule = """
        AFTER ANY MUTATING ACTION (`ui_click`, `ui_type`, `ui_key`, \
        `ui_scroll`, `ui_ax`, `app_manage`, `browser_open_url`), verify with \
        `screen_read` (or the action's own `verified:` line) before the next \
        action or the final answer — never assume an action worked.
        """
}

/// THE COMPUTER-USE ACT LAYER (SPEC §4.5): keyboard synthesis, scroll, AX
/// actions and app control.
///
/// Every one of these is MUTATING, so `PopTool.requiresApproval` sends it
/// through `ApprovalGate` before a single event is posted — the act list is
/// approval-gated by construction, the same predicate the gate and the
/// classification probe share. Where a point is involved (`ui_scroll`) the
/// SAME allowlisted-window bounds guard `ui_click` uses applies, and every
/// event goes through `BrowserActions.post`, the one funnel production and the
/// probes share. No task knowledge lives here: no app names, no key shortcuts
/// tied to a site.
///
/// POST-ACTION VERIFICATION (SPEC: verify ⇒ retry once ⇒ report): each action
/// performs its own post-read and ends its result with a `verified:` segment,
/// so the model sees the observed state rather than a claim.
enum UIAct {
    /// Named keys plus ANSI letters/digits, as macOS virtual key codes. A flat
    /// table, so `keyPlan` is data rather than a chain of string comparisons.
    static let keyCodes: [String: Int] = {
        var table: [String: Int] = [
            "return": 36, "enter": 36,
            "tab": 48,
            "escape": 53, "esc": 53,
            "delete": 51, "backspace": 51,
            "space": 49,
            "up": 126, "down": 125, "left": 123, "right": 124
        ]
        let letters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5),
            ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12),
            ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31),
            ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40),
            ("n", 45), ("m", 46)
        ]
        let digits: [(String, Int)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25)
        ]
        for (name, code) in letters + digits { table[name] = code }
        return table
    }()

    /// Modifier tokens, as raw `CGEventFlags` bits. Named keys carry none.
    static let modifierFlags: [String: UInt64] = [
        "cmd": CGEventFlags.maskCommand.rawValue,
        "command": CGEventFlags.maskCommand.rawValue,
        "shift": CGEventFlags.maskShift.rawValue,
        "alt": CGEventFlags.maskAlternate.rawValue,
        "option": CGEventFlags.maskAlternate.rawValue,
        "ctrl": CGEventFlags.maskControl.rawValue,
        "control": CGEventFlags.maskControl.rawValue
    ]

    /// PURE, table-driven key plan: `"cmd+shift+t"` → (vt 17, mods cmd|shift).
    /// Returns nil for any unknown key or modifier — the caller turns that into
    /// a precise failure, never a silent no-op. No event is posted here.
    static func keyPlan(_ raw: String) -> (vt: Int, mods: UInt64)? {
        let parts = raw
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let final = parts.last, !final.isEmpty else { return nil }
        var mods: UInt64 = 0
        for token in parts.dropLast() {
            guard let flag = modifierFlags[token] else { return nil }
            mods |= flag
        }
        guard let vt = keyCodes[final] else { return nil }
        return (vt, mods)
    }

    /// PURE validation for `app_manage`. Returns the normalized action, or nil
    /// for anything else, so an unknown verb is rejected before any app work.
    static func appActionPlan(_ raw: String) -> String? {
        let action = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["activate", "quit", "open"].contains(action) ? action : nil
    }

    // MARK: - ui_key

    /// Presses one named key or a modifier combo at the current focus.
    ///
    /// Verifies by reading the new frontmost app, its focused window title and
    /// the first AX lines: a `cmd+w` closing a tab is visible there.
    static func pressKey(_ raw: String) async -> String {
        if let denied = BrowserActions.requireAccessibility() { return "ERROR: \(denied)" }
        guard let plan = keyPlan(raw) else {
            return """
                ERROR: '\(raw)' is not a key Pop can press. Use a named key \
                (return, tab, escape, delete, space, up, down, left, right) or a \
                modifier combo such as cmd+w, cmd+shift+t or alt+left.
                """
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(plan.vt), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(plan.vt), keyDown: false)
        else {
            return "ERROR: could not build a keyboard event; nothing was pressed."
        }
        let flags = CGEventFlags(rawValue: plan.mods)
        down.flags = flags
        up.flags = flags
        BrowserActions.post([down, up])

        print("UI_ACTION key \(raw)")
        fflush(stdout)

        let front = Observe.frontmostApp()
        let title = Observe.windowTitle(bundleID: front.bundleID)
        let ax = Observe.axExcerpt(bundleID: front.bundleID).lines.prefix(3)
        return """
            key: pressed \(raw) (vt \(plan.vt), mods \(plan.mods)). \
            verified: frontmost \(front.name) [\(front.bundleID)], window \
            "\(title)"; AX now: \(ax.joined(separator: " | "))
            """
    }

    // MARK: - ui_scroll

    /// Posts scroll-wheel events at a point inside a visible app window.
    static func scroll(direction: String, amount: Int, x: Int?, y: Int?) async -> String {
        if let denied = BrowserActions.requireAccessibility() { return "ERROR: \(denied)" }
        let dir = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["up", "down", "left", "right"].contains(dir) else {
            return "ERROR: unknown direction '\(direction)'; use up, down, left or right."
        }

        let bounds = await BrowserActions.visibleWindowBounds()
        guard !bounds.isEmpty else {
            return """
                ERROR: no visible app window bounds are known right now, so nothing \
                was scrolled. Read the screen first.
                """
        }
        let target: CGPoint
        if let x, let y {
            target = CGPoint(x: x, y: y)
        } else {
            // Default: the centre of the visible app windows. The union centre
            // is used when it lands inside a window; otherwise the first
            // window's own centre, which is inside by construction.
            let union = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
            let center = CGPoint(x: union.midX, y: union.midY)
            let first = bounds[0]
            target = BrowserActions.pointIsAllowed(center, in: bounds)
                ? center
                : CGPoint(x: first.midX, y: first.midY)
        }
        guard BrowserActions.pointIsAllowed(target, in: bounds) else {
            return """
                ERROR: (\(Int(target.x)), \(Int(target.y))) is outside every \
                on-screen app window, so nothing was scrolled.
                """
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let ticks = Int32(max(1, amount))
        let vertical = (dir == "up" || dir == "down")
        let signed = (dir == "up" || dir == "right") ? ticks : -ticks
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: vertical ? 1 : 2,
            wheel1: vertical ? signed : 0,
            wheel2: vertical ? 0 : signed,
            wheel3: 0
        ) else {
            return "ERROR: could not build a scroll event; nothing was scrolled."
        }
        event.location = target
        BrowserActions.post([event])

        print("UI_ACTION scroll \(dir) \(amount) at \(Int(target.x)),\(Int(target.y))")
        fflush(stdout)

        let front = Observe.frontmostApp()
        let ax = Observe.axExcerpt(bundleID: front.bundleID).lines.prefix(4)
        return """
            scroll: posted \(amount) \(dir) tick(s) at (\(Int(target.x)), \
            \(Int(target.y))). verified: frontmost \(front.name); AX now: \
            \(ax.joined(separator: " | "))
            """
    }

    // MARK: - ui_observe (ref-based perception)

    /// One element from a `ui_observe` snapshot: a stable `[n]` ref plus what the
    /// act path needs to reach it WITHOUT a guessed title. `element` is the live
    /// AX element; it is nil only for a probe-injected row, which carries
    /// `press`/`setValue` closures standing in for the AX call instead.
    struct ObservedElement {
        let ref: Int
        let role: String
        let title: String
        let value: String
        let position: CGPoint?
        let element: AXUIElement?
        let press: (@Sendable () -> AXError)?
        let setValue: (@Sendable (String) -> AXError)?
    }

    /// The last `ui_observe` snapshot, keyed by the app it was taken from. A ref
    /// resolves only while the SAME app is frontmost; an app switch makes the
    /// whole snapshot stale by construction.
    static var lastObservation: (bundleID: String, elements: [ObservedElement])?

    /// TEST-ONLY snapshot source: a probe installs rows without a live AX walk.
    /// `nil` in production, where `observe()` walks the real tree.
    static var observeElementsOverride: [ObservedElement]?

    /// Lists the frontmost app's actionable AX elements and installs them as the
    /// current ref snapshot. READ-ONLY: it reads the tree and changes nothing.
    ///
    /// WHY: native apps need the same ref-based eyes the browser tools already
    /// have (`browser_read`/`browser_click [n]`) — guessed accessibility titles
    /// measurably thrash on panes whose controls are named differently than the
    /// model expects. A ref is an identity the app published, not a guess.
    static func observe() async -> String {
        if let denied = BrowserActions.requireAccessibility() { return "ERROR: \(denied)" }
        let app = Observe.frontmostApp()
        let elements: [ObservedElement]
        if let observeElementsOverride {
            elements = observeElementsOverride
        } else {
            let rows = Observe.actionableElements(bundleID: app.bundleID, limit: 30)
            elements = rows.enumerated().map { index, row in
                ObservedElement(
                    ref: index + 1,
                    role: row.role,
                    title: row.title,
                    value: row.value,
                    position: row.position,
                    element: row.element,
                    press: nil,
                    setValue: nil
                )
            }
        }
        lastObservation = (app.bundleID, elements)
        guard !elements.isEmpty else {
            return """
                \(app.name): no actionable accessibility elements were exposed. \
                Try screen_read, or app_manage to focus the app first.
                """
        }
        var lines = ["\(app.name) — \(elements.count) actionable element(s); act by ref with ui_ax/ui_click:"]
        for element in elements {
            var line = "[\(element.ref)] \(element.role) '\(element.title)'"
            if !element.value.isEmpty { line += " (\(element.value))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Resolves a `[n]` ref against the CURRENT snapshot. A ref from a snapshot
    /// taken in a different app is stale — the app may have changed under it —
    /// so it is refused with a precise reason rather than acted on blind.
    static func resolveObserved(ref: Int) -> Result<ObservedElement, ObservedRefError> {
        guard let observation = lastObservation else {
            return .failure(ObservedRefError("no ui_observe snapshot yet; call ui_observe first"))
        }
        let front = Observe.frontmostApp().bundleID
        guard observation.bundleID == front else {
            return .failure(ObservedRefError("observations are stale; call ui_observe again"))
        }
        guard let element = observation.elements.first(where: { $0.ref == ref }) else {
            return .failure(ObservedRefError(
                "no element with ref \(ref) in the last ui_observe; call ui_observe again"
            ))
        }
        return .success(element)
    }

    /// Presses an observed element: the probe seam when present, else the AX
    /// action on the live element.
    static func pressObserved(_ element: ObservedElement) -> AXError {
        if let press = element.press { return press() }
        guard let ax = element.element else { return .invalidUIElement }
        return AXUIElementPerformAction(ax, kAXPressAction as CFString)
    }

    /// Writes a value into an observed element: the probe seam when present,
    /// else the AX `setValue` on the live element.
    static func setValueObserved(_ element: ObservedElement, _ value: String) -> AXError {
        if let setValue = element.setValue { return setValue(value) }
        guard let ax = element.element else { return .invalidUIElement }
        return AXUIElementSetAttributeValue(ax, kAXValueAttribute as CFString, value as CFTypeRef)
    }

    /// Clicks an observed element at its own position — the ref path for a
    /// control that exposes no press action.
    static func clickObserved(ref: Int) async -> String {
        if let denied = BrowserActions.requireAccessibility() { return "ERROR: \(denied)" }
        switch resolveObserved(ref: ref) {
        case .failure(let message):
            return "ERROR: \(message)"
        case .success(let element):
            guard let position = element.position else {
                return """
                    ERROR: ref [\(ref)] \(element.role) '\(element.title)' exposes \
                    no position; use ui_ax by ref instead.
                    """
            }
            return await BrowserActions.click(x: Int(position.x), y: Int(position.y))
        }
    }

    // MARK: - ui_ax

    /// AX action on a named element in the frontmost app: the coordinate-free path.
    ///
    /// Two ways to name the element: a `title` substring (the original path), or
    /// a `ref` from `ui_observe` (the identity path — no guessing, and a stale
    /// ref is refused). On a title miss it re-finds the element once after
    /// 300 ms (a slow dialog can race the action) and retries; a second failure
    /// is reported plainly.
    static func axAction(action: String, title: String?, value: String?, ref: Int?) async -> String {
        if let denied = BrowserActions.requireAccessibility() { return "ERROR: \(denied)" }
        let verb = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["press", "setvalue", "setselected"].contains(verb) else {
            return "ERROR: unknown action '\(action)'; use press, setValue or setSelected."
        }
        if verb == "setvalue", value == nil {
            return "ERROR: action 'setValue' needs a 'value' argument."
        }

        let past = verb == "press" ? "pressed" : (verb == "setvalue" ? "set the value of" : "selected")

        // REF PATH: no title matching, no guessed names.
        if let ref {
            switch resolveObserved(ref: ref) {
            case .failure(let message):
                return "ERROR: \(message)"
            case .success(let element):
                let error: AXError
                switch verb {
                case "press":
                    error = pressObserved(element)
                case "setvalue":
                    error = setValueObserved(element, value ?? "")
                default: // setselected
                    guard let ax = element.element else {
                        return "ERROR: action 'setSelected' by ref needs a live element; call ui_observe again."
                    }
                    error = AXUIElementSetAttributeValue(
                        ax, kAXSelectedAttribute as CFString, kCFBooleanTrue
                    )
                }
                guard error == .success else {
                    return """
                        ERROR: action '\(verb)' on ref [\(ref)] \(element.role) \
                        '\(element.title)' failed (AX error \(error.rawValue)).
                        """
                }
                print("UI_ACTION ax \(verb) ref=\(ref) \(element.role) \(element.title)")
                fflush(stdout)
                return """
                    \(verb): \(past) [\(ref)] \(element.role) '\(element.title)' \
                    in \(Observe.frontmostApp().name). verified: acted by ref \(ref).
                    """
            }
        }

        // TITLE PATH (existing behavior, unchanged).
        let needle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return "ERROR: ui_ax needs a 'title' to find by name, or a 'ref' from ui_observe."
        }

        func perform(_ element: AXUIElement) -> AXError {
            switch verb {
            case "press":
                return AXUIElementPerformAction(element, kAXPressAction as CFString)
            case "setvalue":
                return AXUIElementSetAttributeValue(
                    element,
                    kAXValueAttribute as CFString,
                    (value ?? "") as CFTypeRef
                )
            default: // setselected
                return AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedAttribute as CFString,
                    kCFBooleanTrue
                )
            }
        }

        // Enable Chromium's page-content tree on the FRONTMOST app at ACT time:
        // ui_ax can run before any excerpt, so the title path must not rely on
        // axExcerpt having enabled it.
        Observe.enableManualAXIfChromium(bundleID: Observe.frontmostApp().bundleID)

        // A freshly enabled Chromium tree materializes ASYNCHRONOUSLY — one
        // immediate find is not a verdict. Poll up to 5 attempts over ~2s (the
        // materialization window) before giving up.
        func findWithMaterialization(_ needle: String)
            async -> (role: String, title: String, element: AXUIElement)? {
            for attempt in 0..<5 {
                if let found = findFrontElement(title: needle) { return found }
                if attempt < 4 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
            return nil
        }

        guard let found = await findWithMaterialization(needle) else {
            return """
                ERROR: no accessibility element whose title or description \
                contains '\(needle)' in the frontmost app \
                (\(Observe.frontmostApp().name)).
                """
        }
        var match = found
        var result = perform(match.element)
        if result != .success {
            // ONE bounded retry: a dialog that was still appearing can expose
            // the element a moment later; a real absence fails again here.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let again = findFrontElement(title: needle) {
                match = again
                result = perform(again.element)
            }
        }
        guard result == .success else {
            return """
                ERROR: action '\(verb)' on \(match.role) '\(match.title)' failed \
                (AX error \(result.rawValue)) after one retry.
                """
        }

        print("UI_ACTION ax \(verb) \(match.role) \(match.title)")
        fflush(stdout)
        let front = Observe.frontmostApp()
        let ax = Observe.axExcerpt(bundleID: front.bundleID).lines.prefix(3)
        return """
            \(verb): \(past) \(match.role) '\(match.title)' in \
            \(front.name). verified: matched role=\(match.role) \
            title='\(match.title)'; AX now: \(ax.joined(separator: " | "))
            """
    }

    /// Finds the element the frontmost app exposes for `title`. Returns its
    /// role and display title alongside the element.
    static func findFrontElement(title: String) -> (role: String, title: String, element: AXUIElement)? {
        let bundle = Observe.frontmostApp().bundleID
        return Observe.findElement(bundleID: bundle, matching: title)
    }

    // MARK: - app_manage

    /// Resolves an app NAME (not a bundle id) to its bundle URL by checking the
    /// standard application directories. Used only for `open` when the app is
    /// not already running; a bundle id goes through `urlForApplication`.
    private static func installedAppURL(named name: String) -> URL? {
        let directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        let file = name.hasSuffix(".app") ? name : name + ".app"
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Activate, gracefully quit, or open an application by bundle id or name.
    static func manageApp(action: String, app target: String) async -> String {
        guard let verb = appActionPlan(action) else {
            return "ERROR: unknown action '\(action)'; use activate, quit or open."
        }
        let query = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "ERROR: `app` is empty." }

        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications
        let match = running.first { $0.bundleIdentifier == query }
            ?? running.first { ($0.localizedName ?? "").caseInsensitiveCompare(query) == .orderedSame }

        switch verb {
        case "activate":
            guard let app = match else {
                return "ERROR: no running app matches '\(query)' — nothing to activate."
            }
            _ = app.activate(options: [])
            print("UI_ACTION app activate \(query)")
            fflush(stdout)
            let front = Observe.frontmostApp()
            let became = front.bundleID == app.bundleIdentifier
            return """
                activate: requested \(app.localizedName ?? query). verified: \
                frontmost is now \(front.name) [\(front.bundleID)]; \
                became-frontmost=\(became)
                """
        case "quit":
            guard let app = match else {
                return "ERROR: '\(query)' is not running, so there is nothing to quit."
            }
            _ = app.terminate()
            print("UI_ACTION app quit \(query)")
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let stillRunning = workspace.runningApplications
                .contains { $0.bundleIdentifier == app.bundleIdentifier }
            return """
                quit: asked \(app.localizedName ?? query) to quit gracefully. \
                verified: still-running=\(stillRunning)
                """
        default: // open
            let url = workspace.urlForApplication(withBundleIdentifier: query)
                ?? (match?.bundleURL)
                ?? installedAppURL(named: query)
            guard let url else {
                return "ERROR: no installed application matches '\(query)' to open."
            }
            let opened: NSRunningApplication? = await withCheckedContinuation { continuation in
                workspace.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { app, _ in
                    continuation.resume(returning: app)
                }
            }
            let front = Observe.frontmostApp()
            let openedID = opened?.bundleIdentifier ?? "nil"
            let became = front.bundleID == openedID
            return """
                open: launched \(url.lastPathComponent). verified: frontmost is \
                now \(front.name) [\(front.bundleID)]; opened=\(openedID); \
                became-frontmost=\(became)
                """
        }
    }
}

/// `SCShareableContent` is not `Sendable`-safe to hand around; this reads it
/// once and hands back only the geometry the guard needs.
enum SCShareableContentRetainer {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }
}