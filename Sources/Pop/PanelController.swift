import AppKit

/// Borderless panels do not accept keyboard input by default; `canBecomeKey`
/// must be overridden for the embedded WKWebView text input to work.
final class PopPanel: NSPanel {
    /// Forwarded first responder once the panel owns key focus.
    var keyFocusView: NSView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        // A hidden subtree has no usable field editor, and touching its
            // responder state while hidden is how focus silently ends up
            // nowhere. In `mascot` state the composer is hidden, so there is
            // nothing to forward to.
        if let view = keyFocusView, !view.isHidden {
            _ = view.becomeFirstResponder()
        }
    }
}

/// The launcher panel has two shapes: a single composer bar (`bar`, the resting
/// state) and a transcript panel that grows upward from the same bottom edge
/// (`full`, once a conversation starts or a menu needs room).
///
/// Both shapes are the SAME window as the robot: `headroom + web region`, with
/// the robot drawn in the top strip. One window means there is nothing to dock
/// and nothing to desynchronise.
enum PanelState: String {
    /// The launch default: the robot alone, web view hidden.
    case mascot
    case bar
    case full

    /// Height of the web view region only; `PanelHeadroom` is added on top.
    var webHeight: CGFloat {
        switch self {
        case .mascot: return 0
        case .bar: return 64
        case .full: return 520
        }
    }

    /// `mascot` is the only shape narrower than the composer, because it IS the
    /// robot: `hoverWidth` wide, headroom on every side, plus the reserved pill
    /// band BELOW the robot's feet.
    var size: NSSize {
        switch self {
        case .mascot:
            NSSize(
                width: PanelHeadroom.hoverWidth,
                height: PanelHeadroom.height + PanelHeadroom.pillBandHeight
            )
        case .bar, .full:
            NSSize(width: PanelHeadroom.width, height: PanelHeadroom.height + webHeight)
        }
    }
}

@MainActor
final class PanelController {
    /// The full window size in the resting `bar` state, robot headroom included.
    static let panelSize = PanelState.bar.size
    private static let edgeInset: CGFloat = 18

    /// The launcher's remembered origin. Written on every drag.
    nonisolated static let frameDefaultsKey = "PopPanelFrame"

    /// The ROBOT's remembered absolute position, and what we really restore.
    ///
    /// The window origin is STATE-DEPENDENT — the robot sits flush with the
    /// window's left in `mascot` and centred 265pt inside it in `bar`/`full` —
    /// so a frame persisted while the bar was up restores the window one inset
    /// LEFT of where the user actually put the robot. Persisting the robot keeps
    /// the thing the user is looking at pinned, whatever state was up at the time.
    nonisolated static let anchorDefaultsKey = "PopRobotAnchor"

    /// Whether this launch restored (or migrated) an anchor rather than taking
    /// the first-launch default. Probes read it to tell a fresh run from a
    /// restore; production code uses it to avoid re-seeding the anchor.
    let anchorWasRestored: Bool

    let panel: PopPanel
    let appWebView: AppWebView

    /// Set by `main` so every state change reaches the page. Bar state means
    /// LAUNCHER ONLY, so the page has to know the moment it changes.
    var onPanelStateChange: ((String) -> Void)?

    /// Set by `main`: the hotkey asks the page to focus the composer. Routed
    /// through `ChatController` so the call queues until the page is ready.
    var onFocusInput: (() -> Void)?

    /// Set by `main`: whether this session has any conversation yet. The panel
    /// consults it before letting the PAGE expand it into `full`.
    var isSessionEmpty: (() -> Bool)?

    /// Where the robot anchor / panel frame are persisted. Probes inject an
    /// ISOLATED suite so a measurement can never overwrite the user's real
    /// position; production passes the standard defaults.
    private let defaults: UserDefaults

    private(set) var isVisible = false
    private(set) var state: PanelState = .mascot

    /// THE ADAPTIVE BAR HEIGHT. In `bar` the page's status line sits above the
    /// composer in normal flow, so a shown status needs more web region than the
    /// 64pt baseline — otherwise the composer is clipped at the bottom. The page
    /// measures the real stack and asks for the height; this is that height.
    /// It starts at the recorded baseline and is never allowed below it, so an
    /// idle Pop keeps the byte-identical 214pt window and the robot anchor.
    private var barWebHeight: CGFloat = PanelState.bar.webHeight

    /// The robot's state source, owned here now that the robot lives in this
    /// window. `ChatController` posts `popMascotState` and it lands here.
    let mascotModel = MascotModel()

    /// Retained: the hosting view is owned by the container, but Swift needs a
    /// strong handle for nothing else — kept for the `MASCOT_SHOWN` contract.
    private var robotHostingView: MascotHostingView?

    /// Retained so the monitor stays alive for the process lifetime.
    private var focusMonitor: Any?

    /// TEMPORARY DIAGNOSTIC (pill dead-click): retained so the global monitor
    /// stays alive for the process lifetime.
    private var globalClickMonitor: Any?

    /// Retained for the mascot's toggle notification.
    private var mascotToggleObserver: NSObjectProtocol?

    /// Retained so dragging the bar carries the docked mascot with it.
    private var panelMoveObserver: NSObjectProtocol?

    /// Retained so the composer bar's inert background can drag the panel.
    private var barDragObserver: NSObjectProtocol?

    /// Retained so a robot drag re-derives the anchor (the robot's own drag
    /// moves the window with no controller involvement).
    private var robotDragObserver: NSObjectProtocol?

    /// Live local monitors for a bar drag. Held only for the duration of the
    /// gesture and removed on mouse-up; a leaked `.leftMouseDragged` monitor
    /// would move the window forever.
    private var barDragMonitor: Any?
    private var barDragEndMonitor: Any?
    private var barDragStartMouse: CGPoint?
    private var barDragStartOrigin: NSPoint?

    /// Retained for the page's `uiHeight` height requests.
    private var heightObserver: NSObjectProtocol?
    /// The send-driven sibling of `heightObserver`; see `handleHeightRequest`.
    private var sendHeightObserver: NSObjectProtocol?
    /// The page's measured content height; see `handleContentHeight`.
    private var contentHeightObserver: NSObjectProtocol?
    /// A voice listen starting; see `enterVoiceSurface`.
    private var voiceSurfaceObserver: NSObjectProtocol?
    /// A browser open/close; see `BrowserController.activityChanged`.
    private var browserActivityObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Resolved FIRST so the flag is available before any `self` use below.
        let restoredAnchor = Self.restoreRobotAnchor(defaults: defaults)
        anchorWasRestored = restoredAnchor != nil

        let webView = AppWebView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: Self.panelSize.width,
                height: PanelState.bar.webHeight
            )
        )
        appWebView = webView

        panel = PopPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            // `.nonactivatingPanel` is REQUIRED: ordering the panel front must
            // never activate Pop, so the hotkey summon cannot steal focus from
            // the frontmost app. Key status is instead granted on the click
            // path via `FocusableWebView.needsPanelToBecomeKey`.
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window content carries its own consolidated shadow; the
        // system-derived alpha shadow on a clear borderless panel renders
        // jagged at 1x backing scale.
        panel.hasShadow = false
        panel.contentView = makeContainerView(webView: webView)
        panel.keyFocusView = webView.webView

        // The bottom-center anchor is a FIRST-LAUNCH default only. What comes
        // back on any later launch is the ROBOT's position, never the window's
        // origin: the window is DERIVED from the robot (see `setPanelState`), so
        // restoring a raw frame would place the launcher one inset to the left of
        // where the user actually put it.
        if let restoredAnchor {
            robotAnchorX = restoredAnchor.x
            robotAnchorY = restoredAnchor.y
        }
        // Launch state is always `mascot`, whose inset is 0 and whose height is
        // the robot's height — so the mascot window origin IS the anchor. This is
        // the same derivation `setPanelState` runs, spelled out for the launch.
        panel.setFrameOrigin(restoredAnchor ?? Self.defaultOrigin())

        // Seed the anchor from where the robot ACTUALLY ended up, so a default
        // position is honoured rather than being overridden. A restored or
        // migrated anchor wins: re-seeding here would silently discard it and
        // reintroduce the drift this persistence exists to prevent.
        if !anchorWasRestored {
            captureRobotAnchor()
        }

        installFocusMonitor()
        installGlobalClickMonitor()
        installMascotToggleObserver()
        installDockObservers()
installBarDragObserver()
        installRobotDragObserver()
        establishAmbientPresence()
    }

    /// The page hands us a `barDragBegin` from the composer's inert background.
    ///
    /// A WKWebView consumes the mouse-down that AppKit's
    /// `isMovableByWindowBackground` needs, so the web view cannot move its own
    /// window. Instead the page reports the gesture and LOCAL monitors track the
    /// cursor for its duration — AppKit keeps delivering mouse events to this
    /// process regardless of which view is under the pointer, so the drag stays
    /// smooth even once the cursor leaves the composer.
    /// The robot's drag moves the window straight from `MascotHostingView`, so
    /// the controller only learns about it at drag END — which is the only moment
    /// the anchor should move (same rule as the bar drag).
    private func installRobotDragObserver() {
        robotDragObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popRobotDragEnd"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureRobotAnchor()
                self.persistFrame()
            }
        }
    }

    private func installBarDragObserver() {
        barDragObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popBarDragBegin"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginBarDrag() }
        }
    }

    private func beginBarDrag() {
        // A second drag starting mid-gesture would double-install the monitors.
        guard barDragMonitor == nil else { return }
        barDragStartMouse = NSEvent.mouseLocation
        barDragStartOrigin = panel.frame.origin

        barDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            // The work is a Void main-actor hop and the handler swallows the
            // event, so nothing non-Sendable crosses the isolation boundary.
            MainActor.assumeIsolated { self?.trackBarDrag() }
            // Swallow: the web view must not also process this drag.
            return nil
        }

        barDragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.endBarDrag() }
            // Swallow: a drag must never register as a click on the composer.
            return nil
        }
    }

    /// Moves the panel by the drag delta. Split out of the monitor closure so the
    /// main-actor hop carries no `NSEvent` (which has no Sendable conformance).
    private func trackBarDrag() {
        guard let startMouse = barDragStartMouse,
              let startOrigin = barDragStartOrigin
        else { return }
        let mouse = NSEvent.mouseLocation
        let target = NSPoint(
            x: startOrigin.x + (mouse.x - startMouse.x),
            y: startOrigin.y + (mouse.y - startMouse.y)
        )
        panel.setFrameOrigin(
            WindowDrag.clampedOrigin(
                target,
                windowSize: panel.frame.size,
                near: startOrigin
            )
        )
    }

    private func endBarDrag() {
        if let barDragMonitor { NSEvent.removeMonitor(barDragMonitor) }
        if let barDragEndMonitor { NSEvent.removeMonitor(barDragEndMonitor) }
        barDragMonitor = nil
        barDragEndMonitor = nil
        barDragStartMouse = nil
        barDragStartOrigin = nil
        // A USER drag is the one thing allowed to move the robot. Re-derive the
        // anchor here, at drag end, rather than on every `didMove`: a
        // programmatic state transition also moves the window, and capturing
        // mid-transition would let the anchor drift a little on every toggle.
        captureRobotAnchor()
        // `didMove` already persisted every intermediate frame; this makes the
        // final resting position durable regardless. It runs AFTER the re-derive
        // so the anchor it writes is the robot's true resting position, not the
        // mid-gesture one.
        persistFrame()
    }

    /// First launch shows the robot alone, resting in `mascot`.
    ///
    /// `orderFrontRegardless` is the ACCESSORY path: it puts the launcher on
    /// screen without activating Pop, so the user's frontmost app is untouched at
    /// launch and ⌥Space can expand the chat on demand. This is what makes the
    /// window ambient — after this point nothing hides it but the orb menu.
    private func establishAmbientPresence() {
        panel.orderFrontRegardless()
        isVisible = true
        // Explicit `.mascot`: the launch state is never inferred. The page is told
        // too, so the composer is not painted behind a robot-only window.
        setPanelState(.mascot, animated: false)
    }

    /// The panel's content: the robot in the top strip, the web view filling
    /// everything below it.
    ///
    /// Both children are bottom-anchored to the web view's frame in AppKit
    /// coordinates (origin bottom-left), so the robot's feet sit directly on the
    /// composer's top edge with no invisible band between them.
    private func makeContainerView(webView: AppWebView) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))

        let robot = MascotHostingView(rootView: MascotView(
            model: mascotModel,
            onTogglePanel: {}
        ))
        robotHostingView = robot
        // The robot must know whether it is currently ALONE, so a single click
        // can summon the composer instead of toggling it shut again.
        robot.isMascotOnly = { [weak self] in self?.state == .mascot }
        container.addSubview(robot)
        mascotModel.startObservingConversationStates()

        container.addSubview(webView)
        // The browser pane goes in ABOVE the chat web view (added last = front)
        // and only occupies the top band of the `full` web region. The window
        // sizes and the robot anchor are untouched: the page collapses its
        // transcript to a one-line strip to make room, so the browser is
        // visible while it acts AND the conversation stays readable.
        container.addSubview(BrowserController.shared.paneView)
        layoutContent(for: state)

        print("MASCOT_SHOWN")
        fflush(stdout)
        return container
    }

    /// The web region height for a state. `bar` is the only adaptive shape: its
    /// height is whatever the page last measured (never below the baseline).
    private func webHeight(for next: PanelState) -> CGFloat {
        next == .bar ? barWebHeight : next.webHeight
    }

    /// The full window size for a state, headroom included. Identical to
    /// `PanelState.size` except that `bar` uses the measured height.
    private func size(for next: PanelState) -> NSSize {
        next == .mascot
            ? next.size
            : NSSize(
                width: PanelHeadroom.width,
                height: PanelHeadroom.height + webHeight(for: next)
            )
    }

    /// Stacks the two regions in AppKit coordinates (origin bottom-left): the web
    /// view occupies the bottom band and the robot sits directly on top of it.
    ///
    /// Called on every state change, so the robot always rides the composer's top
    /// edge — the dock relationship is now structural rather than computed.
    private func layoutContent(for next: PanelState) {
        guard let container = panel.contentView else { return }
        let width = container.bounds.width
        let height = webHeight(for: next)
        // In `mascot` the web region has zero height AND is hidden, so the robot
        // is genuinely alone. It is unhidden again by the very next
        // `layoutContent` for `bar`, which always runs before `focusInput`.
        appWebView.isHidden = (next == .mascot)
        appWebView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Browser pane: `full` AND a live page. It used to be `full` ALONE, which
        // meant an empty 300pt black box was painted over the top of the web
        // region on every `full` panel — including the user's restored session,
        // which opens straight into `full` without ever having navigated. The
        // page reserves the matching band only when the browser is active, so a
        // pane shown without that reservation covered the transcript outright:
        // an empty rounded rectangle where the answer should be. Visibility and
        // the reserved band now come from ONE source (`isPaneVisible`).
        let pane = BrowserController.shared.paneView
        pane.isHidden = (next != .full) || !BrowserController.shared.isPaneVisible
        pane.frame = NSRect(
            x: 0,
            y: height - BrowserController.paneHeight,
            width: width,
            height: BrowserController.paneHeight
        )
        // The robot hosting view is the robot strip PLUS the hover-toolbar band,
        // TOP-ALIGNED in the window: strip = top `PanelHeadroom.height`, pills =
        // bottom `PanelHeadroom.pillBandHeight`. Top-aligning is what keeps the
        // robot's screen Y identical across states — only the window's HEIGHT
        // changes, so mascot -> bar grows the window downward and the robot never
        // moves. In `bar`/`full` the band overlaps the web's top by
        // `pillBandHeight`; the web view is in FRONT, so it keeps those clicks.
        let hostWidth = PanelHeadroom.hoverWidth
        let hostHeight = PanelHeadroom.height + PanelHeadroom.pillBandHeight
        let windowHeight = height + (next == .mascot ? hostHeight : PanelHeadroom.height)
        robotHostingView?.frame = NSRect(
            x: (width - hostWidth) / 2,
            y: windowHeight - hostHeight,
            width: hostWidth,
            height: hostHeight
        )
    }

    /// The robot's hosting view, so a probe can measure the ROBOT's absolute
    /// position rather than inferring it from the window.
    var robotViewForTesting: NSView? { robotHostingView }

    /// The robot's absolute screen top-left — THE invariant.
    ///
    /// The user's directive: the robot is the anchor and the composer is centred
    /// beneath it. The robot's inset inside the window therefore changes with
    /// state (0 in `mascot`, 265 in `bar`/`full`), so the WINDOW must move to
    /// compensate. Tracking the robot directly is what keeps the thing the user
    /// is looking at nailed down while everything else reflows around it.
    private var robotAnchorX: CGFloat = 0
    private var robotAnchorY: CGFloat = 0

    /// Robot width/height: one constant, so the geometry below and the view
    /// layout cannot drift apart.
    private static let robotSize = PanelHeadroom.height

    /// The robot's horizontal inset for a given window width: centred in
    /// `bar`/`full`, flush in `mascot` (where it IS the window).
    /// The robot's horizontal inset for a given window width: centred in
    /// `bar`/`full`, flush in `mascot` (where it IS the window).
    private func robotInset(forWidth width: CGFloat) -> CGFloat {
        max(0, (width - Self.robotSize) / 2)
    }

    /// Re-derives the anchor from where the robot actually is on screen.
    ///
    /// This MUST be the exact inverse of `setPanelState`'s derivation
    /// (`anchor.x = window.minX + inset`, `anchor.y = window.maxY - robotHeight`).
    /// Any other formula lets the anchor drift by the inset on every drag.
    private func captureRobotAnchor() {
        let inset = robotInset(forWidth: panel.frame.width)
        robotAnchorX = panel.frame.origin.x + inset
        robotAnchorY = panel.frame.maxY - Self.robotSize
    }

    /// Writes the robot's position AND the window origin, so the next launch
    /// restores this position and no legacy reader loses data.
    private func persistFrame() {
        defaults.set(
            NSStringFromPoint(panel.frame.origin),
            forKey: Self.frameDefaultsKey
        )
        defaults.set(
            NSStringFromPoint(NSPoint(x: robotAnchorX, y: robotAnchorY)),
            forKey: Self.anchorDefaultsKey
        )
    }

    /// Remembers where the user left the panel, and lets the page ask for height.
    private func installDockObservers() {
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Remember where the user left the bar: `show()` must NOT
                // re-assert the default anchor, or every summon teleports it.
                self.persistFrame()
            }
        }

        heightObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popPanelHeightRequest"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleHeightRequest(note, fromSend: false) }
        }

        // A BROWSER OPEN/CLOSE CHANGES WHAT IS PAINTED, so the panel re-lays-out
        // on it. Without this the pane's visibility would only be recomputed on
        // a panel-state change, and opening a page while already in `full` would
        // leave the page reserving a band the native side was not painting (or,
        // in the reverse direction, a band with no page behind it).
        browserActivityObserver = NotificationCenter.default.addObserver(
            forName: BrowserController.activityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutContent(for: self?.state ?? .mascot) }
        }

        // The SEND-driven request is a different animal: it arrives because the
        // user just typed, so by definition a conversation is starting. It must
        // not be judged by the empty-session guard — that guard exists to stop
        // the transcript ARCHIVE from flashing chat at launch, which is not
        // what this notification is.
        sendHeightObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popPanelHeightRequestSend"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleHeightRequest(note, fromSend: true) }
        }

        // The page's MEASURED content height. Separate from `uiHeight`: that one
        // names a state, this one carries the real pixel height the status line +
        // composer need so the `bar` can grow to fit.
        contentHeightObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popPanelContentHeight"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleContentHeight(note) }
        }

        // A voice listen starting: switch to the voice-only surface without the
        // animation that would otherwise override its compact shrink.
        voiceSurfaceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popPanelVoiceSurface"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterVoiceSurface() }
        }
    }

    /// Applies a page-measured content height to the adaptive `bar`.
    ///
    /// Only `bar` is adaptive: `full` already has headroom and `mascot` has no
    /// web region. The baseline is a hard floor, so an idle bar (status hidden)
    /// keeps its 214pt window; and the value is capped so a pathological
    /// measurement cannot grow the window without bound. A settled value (no
    /// change) does nothing, so the page's per-tick `Thinking…` updates cannot
    /// oscillate the height.
    private func handleContentHeight(_ note: Notification) {
        guard state == .bar else { return }
        let measured = CGFloat((note.object as? NSNumber)?.doubleValue ?? 0)
        let target = min(300, max(PanelState.bar.webHeight, measured.rounded(.up)))
        guard abs(target - barWebHeight) >= 1 else { return }
        barWebHeight = target
        setPanelState(.bar, animated: false)
    }

    /// The VOICE-ONLY surface: reveal the web view and switch to `bar`
    /// IMMEDIATELY (non-animated). Non-animated is the point: the ordinary
    /// `uiHeight` path animates the window, and a mid-flight animation later
    /// overrides the dialog-sized SHRINK that follows — leaving the very tall,
    /// mostly empty panel the user reported. A voice listen owns this
    /// transition, from any prior state.
    func enterVoiceSurface() {
        guard isVisible else {
            show()
            return
        }
        setPanelState(.bar, animated: false)
    }

    /// Applies one height request. `fromSend` marks it as user-initiated, which
    /// exempts it from the empty-session backstop.
    private func handleHeightRequest(_ note: Notification, fromSend: Bool) {
        let raw = note.object as? String
        guard let raw, let next = PanelState(rawValue: raw) else { return }
        // Escape in the composer means "put the composer away", which is
        // the same as ⌥Space from `bar`: collapse to the mascot alone.
        if next == .mascot {
            hide()
            return
        }
        // A page-driven bar request may only SIZE a visible bar, never SUMMON
        // one. A page message can race a dismissal (the page's state push is
        // still in flight when it posts — e.g. hideVoiceDlg's restore while a
        // robot click just collapsed the panel); without this guard that stale
        // message resurrects the panel the user just dismissed. Summoning is
        // user intent: robot click, mic, or hotkey — never the page. The voice
        // dialog is one instance of the shape, not a special case: any page
        // restore that races a collapse (newChat, or an empty-input post
        // resolving just after an Esc to mascot) hits the same guard.
        if next == .bar, state == .mascot {
            return
        }
        // BY DEFAULT, DO NOT SHOW CHAT. The panel may only expand into
        // `full` once this session has a real conversation: a page-driven
        // `uiHeight: full` while the session is empty is the transcript
        // archive asking to be displayed, not a conversation. Launch state
        // is always `bar`. A send-driven request is exempt — see above.
        if next == .full, !fromSend, isSessionEmpty?() == true {
            print("STATE_FLIP_IGNORED empty-session")
            fflush(stdout)
            return
        }
        setPanelState(next)
    }

    /// The mascot's toolbar button and a double-click on the character both post
    /// this notification; the panel is the only thing that reacts to it, so the
    /// mascot needs no reference to the chat panel at all.
    private func installMascotToggleObserver() {
        mascotToggleObserver = NotificationCenter.default.addObserver(
            forName: .popTogglePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    /// A `.nonactivatingPanel` never becomes key on click, and calling
    /// `makeKey()` synchronously inside `mouseDown` — or on the *immediate*
    /// next main-queue turn — raced AppKit's own click/activation handling:
    /// the immediate `async` block ran before AppKit finished the event turn,
    /// so the activation was swallowed. Deferring past the event turn
    /// (`asyncAfter`) lets AppKit complete the click first.
    ///
    /// Installed exactly once: `init`/`installFocusMonitor` may both run, and a
    /// second registration produced duplicate `FOCUS_CLICK_ACTIVATED` logs.
    private func installFocusMonitor() {
        if focusMonitor != nil {
            assert(false, "focus monitor installed more than once")
            return
        }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let loc = event.locationInWindow
            let mouse = NSEvent.mouseLocation
            print("FOCUS_CLICK_ACTIVATED winLoc=(\(loc.x),\(loc.y)) mouse=(\(mouse.x),\(mouse.y))")
            fflush(stdout)
            let panel = self.panel
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                NSApp.activate()
                panel.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let fm = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                    print("FOCUS_RESULT active=\(NSApp.isActive) key=\(panel.isKeyWindow) frontmost=\(fm)")
                    fflush(stdout)
                }
            }
            return event
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `.main` queue is not statically main-actor; the notification is
            // always delivered on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Reissue key once activation has completed: the click-turn
                // activation can finish before AppKit grants key to the panel.
                if self.isVisible && !self.panel.isKeyWindow {
                    self.panel.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    /// TEMPORARY DIAGNOSTIC (pill dead-click): global monitor logging which
    /// window every leftMouseDown lands on. Remove after the routing culprit
    /// is found.
    ///
    /// A global monitor does NOT fire for this app's OWN windows — that is
    /// exactly why the local `focusMonitor` above is ALSO kept. If `GLOBAL_MD`
    /// fires for a click on Pop's visible pills, macOS attributed the click to
    /// a DIFFERENT window, and this log gives that window's identity + frame.
    private func installGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let w = event.window
            print("GLOBAL_MD win=\(w.map { String(describing: type(of: $0)) } ?? "nil")"
                + " popPanel=\(event.window === self?.panel)"
                + " frame=\(w.map { "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)),\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil")"
                + " at=(\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)))")
            fflush(stdout)
        }
    }

    /// ⌥Space cycles mascot -> bar -> mascot, and collapses a `full` chat back
    /// to the mascot.
    ///
    /// THE MASCOT NEVER HIDES (user's absolute rule): the hotkey moves only the
    /// bar/chat. There is no orderOut on this path — the panel always stays on
    /// screen with the robot on it, and only Quit removes the window.
    func toggle() {
        guard isVisible else {
            show()
            return
        }
        switch state {
        case .mascot:
            setPanelState(.bar, animated: false)
            focusInputNow()
            // Same activation the summon path gets; without it the panel never
            // becomes key and keystrokes stay with the frontmost app.
            activatePanelDeferred()
            checkBarFocus()
        case .bar, .full:
            // The chat/composer leaves; the robot stays.
            hide()
        }
    }

    /// Measure focus where the caret actually is, on EVERY bar entry.
    ///
    /// The user reported focus being LOST on a re-toggle, and nothing in the app
    /// was watching for it: `makeKeyAndOrderFront` returning is not a promise,
    /// and `document.activeElement` in JS is only half the story. 600ms is past
    /// both the 250ms activation and the 250ms focus retry, so this reads the
    /// settled state rather than a mid-flight one.
    private func checkBarFocus() {
        let webView = appWebView.webView
        let panel = self.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
            webView.evaluateJavaScript(
                "(function () { var a = document.activeElement;"
                + " if (!a) { return 'none'; }"
                + " return (a.id || a.getAttribute('data-role') || a.tagName || 'none').toLowerCase(); })()"
            ) { value, _ in
                // BOTH halves, because each one alone has lied: the JS read is
                // WebKit-internal and the native read is what actually receives
                // keystrokes. A field editor on the WKWebView is the real
                // "typing will land" signal; the bare container view means no
                // field editor is installed.
                let native = panel.firstResponder
                let nativeName = native.map { String(describing: type(of: $0)) } ?? "nil"
                print("FOCUS_CHECK bar native=\(nativeName) activeElement=\(value ?? "none")")
                fflush(stdout)
            }
        }
    }

    /// Request composer focus TWICE: once now, and once 250ms later.
    ///
    /// The first call can land while the bar is still being laid out, and
    /// `focus()` on a not-yet-visible input is a no-op — which is exactly why
    /// the cursor did not appear. The deferred repeat is the same pattern that
    /// made activation reliable (see `show()`), so belt and braces: the early
    /// call covers the already-visible case, the retry covers the fresh one.
    private func focusInputNow() {
        onFocusInput?()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            self.onFocusInput?()
        }
    }

    /// Single-click on the robot while it is alone: reveal the composer without
    /// going through the hotkey, then focus it.
    func summonBar() {
        guard isVisible, state == .mascot else { return }
        setPanelState(.bar, animated: false)
        focusInputNow()
        activatePanelDeferred()
        checkBarFocus()
    }

    /// Single-click on the robot TOGGLES the composer: reveal it when the robot
    /// is alone, COLLAPSE everything back to `mascot` when it is already up.
    ///
    /// The user's report: a click opened the composer but nothing closed it. This
    /// is the missing symmetry — the robot both opens and closes its own surface.
    /// `.popSummonBar` (the capsule's Composer button) deliberately stays
    /// summon-only; this path is the one that can collapse.
    func toggleComposer() {
        guard isVisible else {
            show()
            return
        }
        if state == .mascot {
            summonBar()
        } else {
            // `bar`/`full` → the launcher: everything leaves, the robot stays.
            // THE DISMISSAL FUNNEL, same as Esc/⌥Space: a robot-click collapse is a
            // dismissal — the listening surface leaves the screen, so consent to
            // listen goes with it (`hide()` posts `.popPanelDismissed`, which is
            // what stops the mic).
            hide()
        }
    }

    func show() {
        // Capture the screen BEFORE Pop activates. Once `NSApp.activate()` runs
        // below, the frontmost app is Pop itself, so anything observed after
        // that point describes Pop's own window (the M3 context-target fix).
        //
        // MEASURED ROOT CAUSE of multi-second summons: `observeAll()` also walked
        // the AX tree and enumerated every on-screen window through
        // ScreenCaptureKit, so it blocked the hotkey path. Only the cheap half
        // runs here; the heavy half runs afterwards against the app this pass
        // recorded, which needs no frontmost status.
        let snap = Observe.observeQuick()
        Observe.summonSnapshot = snap
        print("SUMMON_QUICK_MS=\(snap.wallMilliseconds)")
        fflush(stdout)

        // A fresh summon always starts from the resting bar.
        setPanelState(.bar, animated: false)

        // orderFrontRegardless keeps the panel an accessory window: it appears
        // without pulling activation away from the frontmost application.
        panel.orderFrontRegardless()
        isVisible = true
        // Mascot and bar are ONE widget, so the summon shows them assembled:
        // the mascot has no position of its own and is always derived from the
        print("PANEL_SHOWN")
        fflush(stdout)
        // Hotkey summon takes key focus Spotlight-style (type immediately).
        activatePanelDeferred()
        NotificationCenter.default.post(name: Notification.Name("popPanelSummoned"), object: nil)
        print("FOCUS_SUMMON")
        fflush(stdout)

        // The AX tree and the screenshot land a beat later and refresh the chips
        // and thumbnail. `pushContextUI` tolerates a screenshot-less snapshot, and
        // the page's own ready-queue buffers whatever arrives before the web view
        // is listening, so nothing here is lost — it is only later.
        let target = snap
        DispatchQueue.global(qos: .userInitiated).async {
            let merged = Observe.observeHeavy(target: target)
            DispatchQueue.main.async {
                Observe.summonSnapshot = merged
                print("SUMMON_HEAVY_MS=\(merged.wallMilliseconds)")
                fflush(stdout)
                NotificationCenter.default.post(
                    name: Notification.Name("popPanelHeavyContextReady"),
                    object: nil
                )
            }
        }
    }

    /// THE M0-proven key-focus recipe: activate the app and make the panel key
    /// 250ms from now, then focus the composer once more.
    ///
    /// The deferral mirrors the click path: AppKit must finish the current turn
    /// before activation is honoured (measured: 50ms is too early at startup,
    /// 250ms is reliably key — see M0 verification). `.nonactivatingPanel` stays
    /// in the styleMask so clicking another app still drops focus naturally.
    ///
    /// Every path that puts the composer on screen goes through here. The panel
    /// is non-activating BY DESIGN, so without this the web view can hold
    /// `document.activeElement` (what the probe reads) while real keystrokes
    /// still route to whichever app is frontmost — the "no cursor" report.
    private func activatePanelDeferred() {
        let panel = self.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            // Key is NOT first responder. Hiding the composer region (mascot
            // state) resets the window's first responder away from the web
            // view, and `makeKeyAndOrderFront` does not put it back — which is
            // why the first summon typed fine and every re-toggle did not, even
            // with `activeElement=input` and `key=true` both self-reporting
            // true. Restore it explicitly, on every bar entry.
            //
            // The target MUST be `appWebView.webView`, not `appWebView`:
            // AppWebView is a plain container NSView that merely HOSTS the
            // WKWebView as a subview, so making the container the responder
            // installs no field editor and keystrokes go nowhere — while
            // `document.activeElement` (WebKit-internal) and `isKeyWindow`
            // (window-level) keep reporting green and hide the failure.
            panel.makeFirstResponder(self.appWebView.webView)
            print("PANEL_KEY")
            fflush(stdout)
            self.onFocusInput?()
        }

        // Verify instead of assuming. `makeKeyAndOrderFront` returning is not a
        // promise that key status stuck — another app can win it back within a
        // few hundred ms, and that re-loss was never measured. One line, read
        // half a second after the ask.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) {
            print("SUMMON_FOCUS active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
            fflush(stdout)
        }
    }

    /// Collapse to the mascot state: the composer and any chat go away, the
    /// robot stays. This is the same target as ⌥Space from `bar`/`full`, and it
    /// never orders the window out — Quit is the only path that does that.
    func hide() {
        guard isVisible else {
            // Nothing on screen: there is nothing to collapse, so summon the bar
            // instead of leaving the hotkey dead.
            show()
            return
        }
        setPanelState(.mascot, animated: false)
        // The adaptive bar's remembered height is only valid while the surface
        // that measured it is intact. A voice dialog can have inflated it; the
        // page's own re-measure can't shrink it back (a tall window measures
        // tall), so every dismissal re-baselines and the next summon re-grows
        // from the page's live measurement. The voice dialog is one instance of
        // the same shape, not a special case: any expander that inflates the
        // measured bar and then collapses (a `+` menu opened and dismissed with
        // Esc, an inline sheet that closes) leaves the same stale height, and it
        // is re-baselined here too.
        barWebHeight = PanelState.bar.webHeight
        // THE DISMISSAL FUNNEL. Robot click, Esc, and ⌥Space all collapse the
        // bar HERE and only here, so this is the single place that can guarantee
        // a live mic never outlives its visible surface. The mic's owner
        // (ChatController) listens for this and stops listening.
        NotificationCenter.default.post(name: .popPanelDismissed, object: nil)
        print("PANEL_HIDDEN")
        fflush(stdout)
    }

    // MARK: - Launcher states

    /// Resizes the panel from its CURRENT frame — never from the default anchor.
    ///
    /// The bottom edge (`origin.y`, Cocoa bottom-left origin) and the horizontal
    /// center are held fixed, so the transcript grows UPWARD out of the bar
    /// instead of dragging the launcher down to the bottom of the screen. The
    /// result is clamped to the visible frame of the screen the panel is on, so
    /// a tall panel near the top edge shifts down just enough to stay on-screen.
    func setPanelState(_ next: PanelState, animated: Bool = true) {
        let size = size(for: next)
        let current = panel.frame

        // First-ever show: there is no meaningful current frame, so start from
        // the default anchor. Every later transition anchors on `current`.
        let anchor = current.width > 1 && current.height > 1
            ? current
            : NSRect(origin: Self.defaultOrigin(), size: Self.panelSize)

        // THE ROBOT IS THE ANCHOR; THE WINDOW FOLLOWS IT.
        //
        // The robot's inset inside the window changes with state (0 in `mascot`,
        // 265 in `bar`/`full`), so the window's origin is DERIVED from the
        // robot's fixed absolute anchor rather than from the window's own
        // previous frame. The robot does not move; the composer grows around it.
        let inset = robotInset(forWidth: size.width)
        var origin = NSPoint(
            x: robotAnchorX - inset,
            y: robotAnchorY + Self.robotSize - size.height
        )

        if let visible = NSScreen.screens
            .first(where: { $0.visibleFrame.intersects(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        {
            // Minimal shift to fit. Only an unavoidably large window moves.
            if origin.y + size.height > visible.maxY {
                origin.y = visible.maxY - size.height
            }
            origin.y = max(origin.y, visible.minY)
            if origin.x + size.width > visible.maxX {
                origin.x = visible.maxX - size.width
            }
            origin.x = max(origin.x, visible.minX)
        }

        let target = NSRect(origin: origin, size: size)
        // Re-derive from the FINAL frame so a clamp is a one-time settle: the
        // anchor becomes what the robot now actually is, and the next toggle
        // starts from there instead of dragging it back.
        robotAnchorX = target.minX + inset
        robotAnchorY = target.maxY - Self.robotSize
        // Persist HERE, not only on a drag: a clamp is a one-time settle that
        // moves the robot without the user touching it, so a drag-only write
        // would leave that settled position unpersisted.
        persistFrame()
        state = next
        // The page suppresses the transcript in bar state, so every state change
        // must reach it. `ChatController` buffers it until the page is ready.
        onPanelStateChange?(next.rawValue)

        func settle() {
            // Report against `target`, not `panel.frame`: the animation's
            // completion handler can fire before the model layer has committed
            // the new size, which would report the pre-resize height. The robot
            // rides the composer's top edge structurally, so the layout call is
            // enough — there is no dock math left to recompute.
            layoutContent(for: next)
            // Entering `bar` or `full` KEEPS the composer visible, and a visible
            // composer should own the caret after any state change —
            // unhiding a view does not restore it as first responder. `mascot`
            // hides the web view, so there is nothing to restore there.
            if next != .mascot {
                panel.makeFirstResponder(appWebView.webView)
            }
            print("PANEL_STATE=\(next.rawValue) frame=\(Int(target.origin.x)),\(Int(target.origin.y)),\(Int(target.width)),\(Int(target.height))")
            fflush(stdout)

            // The send-expand is the one transition that happens WHILE the
            // answer is streaming into the bubble, so the responder is worth
            // re-checking rather than assuming: a resize and an animation
            // completion can each drop it. Ask once more a beat later.
            if next == .full {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) {
                    guard self.panel.firstResponder !== self.appWebView.webView else { return }
                    let native = self.panel.firstResponder
                    let name = native.map { String(describing: type(of: $0)) } ?? "nil"
                    print("FOCUS_RETRY full=\(name)")
                    fflush(stdout)
                    self.panel.makeFirstResponder(self.appWebView.webView)
                }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }, completionHandler: { @Sendable in
                // AppKit delivers this on the main thread; it is typed as
                // non-isolated @Sendable, so the hop is explicit.
                MainActor.assumeIsolated { settle() }
            })
            panel.animator().setFrame(target, display: true)
        } else {
            panel.setFrame(target, display: true)
            settle()
        }
    }

    /// The page may request a height (the `+` menu needs room, a send needs the
    /// transcript); Swift still owns the decision and animates the change.
    func requestPanelState(_ next: PanelState) {
        guard isVisible, next != state else { return }
        setPanelState(next)
    }

    // MARK: - Mascot docking

    

    /// The stored robot position, migrating the legacy window frame if needed.
    ///
    /// The legacy key persisted the WINDOW origin, which under centring is only
    /// meaningful together with the width it was stored at. Converting it back
    /// into a robot anchor for that width recovers the position the user
    /// intended, and the new key is written immediately so the migration is
    /// once-ever rather than on every launch.
    private static func restoreRobotAnchor(defaults: UserDefaults) -> NSPoint? {
        if let stored = defaults.string(forKey: anchorDefaultsKey) {
            return NSPointFromString(stored)
        }
        guard let legacy = defaults.string(forKey: frameDefaultsKey) else {
            return nil
        }
        let stored = NSRect(origin: NSPointFromString(legacy), size: PanelState.bar.size)
        let anchor = NSPoint(
            x: stored.minX + (stored.width - robotSize) / 2,
            y: stored.maxY - robotSize
        )
        defaults.set(NSStringFromPoint(anchor), forKey: anchorDefaultsKey)
        print("ANCHOR_MIGRATED from-legacy-window-origin")
        fflush(stdout)
        return anchor
    }

    /// Bottom-center of the main screen: the launcher sits where a dock is.
    /// Used ONLY when nothing has been persisted (first-ever launch).
    private static func defaultOrigin() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bar = PanelState.bar.size
        return NSPoint(
            x: visible.midX - (bar.width / 2),
            y: visible.minY + edgeInset
        )
    }
}