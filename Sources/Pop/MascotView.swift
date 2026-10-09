import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by a double-click on the robot; `PanelController` observes it and
    /// toggles the chat panel.
    static let popTogglePanel = Notification.Name("PopTogglePanel")

    /// Posted by a single click on the robot while it is alone; `main` turns it
    /// into the same summon ⌥Space performs (bar + focused composer).
    static let popSummonBar = Notification.Name("popSummonBar")

    /// Posted by a plain click on the robot. `main` routes it to
    /// `PanelController.toggleComposer()` — reveal the composer when alone,
    /// COLLAPSE it when already up. The symmetry the single-click needs: the
    /// robot both opens and closes its surface. Distinct from `.popSummonBar`,
    /// which the capsule's Composer button still uses and which NEVER collapses.
    static let popToggleComposer = Notification.Name("popToggleComposer")

    /// Posted when a ROBOT drag ends. The robot's own drag moves the window
    /// directly, so `PanelController` never sees the gesture; without this the
    /// remembered robot anchor stays at the PREVIOUS position and the next state
    /// change snaps the robot back.
    static let popRobotDragEnd = Notification.Name("popRobotDragEnd")

    /// Posted by the hover toolbar's History pill, AFTER `.popSummonBar`:
    /// summon the composer, then ask the page to open its sessions menu.
    /// Consumer (workstream C): wire this to `openMenu()` in
    /// `Resources/index.html` — this workstream cannot edit the page.
    static let popOpenHistory = Notification.Name("popOpenHistory")

    /// Posted by the hover toolbar's Mic pill. Consumer (workstream C):
    /// `ChatController` routes it to `speechListener.toggle()`.
    static let popMicToggle = Notification.Name("popMicToggle")
}

/// The hover toolbar's three affordances.
///
/// Each is a REAL SwiftUI `Button` whose action is a thin notification post —
/// the view owns no action state. The hosting view forwards presses inside the
/// row to `super` (see `MascotHostingView.isInToolbarRow`) so the buttons fire
/// natively; every other press still drives the window drag.
enum MascotToolbarButton: CaseIterable {
    /// Summon the composer, then ask the page to open its sessions menu.
    case history
    /// Summon the composer.
    case composer
    /// Toggle the microphone.
    case mic

    /// SF Symbols, not emoji: the pills tile the robot's blue with WHITE glyphs,
    /// and an emoji cannot be tinted. ICON ONLY — a pill carries no text, so the
    /// three fit the 150pt mascot host (see `MascotToolbar`). `clock.clockwise`
    /// is NOT a real SF Symbol and renders blank; the history glyph is
    /// `clock.arrow.circlepath`.
    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .composer: return "square.and.pencil"
        case .mic: return "mic"
        }
    }

    /// Full name: the tooltip AND the accessibility label for the icon-only pill.
    var title: String {
        switch self {
        case .history: return "History"
        case .composer: return "Composer"
        case .mic: return "Mic"
        }
    }
}

/// Geometry of the hover toolbar. The row is REAL SwiftUI `Button`s: they own
/// their own hit-testing, so these constants only size the drawn row (and feed
/// `assertFitsNarrowestHost`). `MascotHostingView` uses the row's reported rect
/// purely as a routing hint to decide whether to forward a press to SwiftUI.
/// Values are measured from the hosting view's TOP-LEFT.
///
/// The row lives in the host's BOTTOM `bandHeight` band, under the robot's feet,
/// in its own reserved space — never overlapping the cloud crown or the electric
/// arc above the head. The host is `PanelHeadroom.hoverWidth` (340pt) wide in
/// every state, so the row is centred with ample margin.
enum MascotToolbar {
    static let height: CGFloat = 28
    /// Icons-only pills. Sized to the NARROWEST host so a drawn pill can never
    /// sit outside the window the hit test measures against.
    static let buttonWidth: CGFloat = 40
    static let spacing: CGFloat = 8
    /// The narrowest host: the mascot window's width. The toolbar must fit this
    /// because the mascot window is its primary host.
    static let hostWidth: CGFloat = PanelHeadroom.hoverWidth
    /// The reserved band the pills are drawn into: the host's BOTTOM band.
    static let bandHeight: CGFloat = PanelHeadroom.pillBandHeight

    static var totalWidth: CGFloat {
        CGFloat(MascotToolbarButton.allCases.count) * buttonWidth
            + CGFloat(MascotToolbarButton.allCases.count - 1) * spacing
    }

    /// BUILD/RUN GUARD: the row must fit the narrowest host. A future fourth pill
    /// that would overflow fails loudly in debug instead of silently clipping and
    /// desyncing the drawn row from the hit row.
    static func assertFitsNarrowestHost() {
        assert(
            totalWidth <= hostWidth,
            "MascotToolbar is \(totalWidth)pt but the narrowest host is \(hostWidth)pt"
        )
    }
}

/// The robot lives INSIDE the panel window's headroom, so its drag handle moves
/// the panel itself.
///
/// This view is the window's drag handle, and it does the move ITSELF:
/// `mouseDownCanMoveWindow` is overridden to `false` so `mouseDown` …
/// `mouseUp` are actually delivered here — both for the manual drag (through
/// `WindowDrag.clampedOrigin`) and so a press inside the toolbar row can be
/// FORWARDED to SwiftUI's real buttons. One window, so a drag on the robot IS a
/// drag on the panel; the old cross-window `performDrag` approach is gone with
/// the separate mascot window.
///
/// Because the view consumes its own events, AppKit's click count is not
/// available, so double-click is counted here: two down-events within 300 ms
/// toggle the panel.
final class MascotHostingView: NSHostingView<MascotView> {
    private var lastDown: Date?
    private var dragStartMouse: CGPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var dragActive = false

    /// AppKit side of hover: the area whose enter/exit drive `model.isHovered`.
    private var hoverTrackingArea: NSTrackingArea?

    /// True while a press began inside the toolbar row. The ROW is owned by real
    /// SwiftUI `Button`s, so the whole gesture is handed to `super` (SwiftUI's
    /// event sink) instead of the manual drag/click path. Cleared on mouse-up.
    private var forwardingToSwiftUI = false

    /// Set by `PanelController`: true while the robot is alone in its window. A
    /// single click then SUMMONS the composer instead of toggling, so the
    /// double-click gesture cannot flip straight back to `mascot`.
    var isMascotOnly: (() -> Bool)?

    /// `mouseDown`/`mouseUp`: the toolbar row is real SwiftUI `Button`s, so a
    /// press there is forwarded to `super` instead of being handled here.
    /// Returning `false` delivers the press here first, where the manual drag
    /// path (and the forward-to-SwiftUI branch) owns it.
    override var mouseDownCanMoveWindow: Bool { false }

    /// CRITICAL — why a pill's FIRST click was still dead. The panel is
    /// `.nonactivatingPanel` (`canBecomeKey` hard-false), so a click landing on a
    /// window that is not yet key is treated as a window-ORDERING click and
    /// discarded unless the hit view claims it. `NSHostingView`'s default does
    /// not guarantee that, so `mouseDown` never ran for the pill (hover still
    /// cycled because tracking areas fire without a press). Claiming first mouse
    /// delivers the press to this view — the click-summon and the toolbar
    /// forwarding both depend on it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// CRITICAL — why the press was still lost after `acceptsFirstMouse`. Even a
    /// claimed click is hit-tested: `NSHostingView`'s internal content view is
    /// the deepest hit view, so AppKit delivered `mouseDown` to SwiftUI's event
    /// sink. `mouseDown` here must therefore run first to decide whether to
    /// forward the press back to that sink (the toolbar row) or drag the window.
    /// The whole headroom is APP-managed, so route every point inside this view
    /// back to it.
    ///
    /// Scope: this view hosts ONLY the robot headroom. The composer webview and
    /// the browser pane are SIBLING subviews of the panel container
    /// (`PanelController.makeContainerView`, added at lines 347/350/356), never
    /// children here — so claiming self cannot swallow web input.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    // MARK: - Hover tracking

    /// Rebuilt whenever AppKit asks, because the window resizes between states.
    /// `.activeAlways` is required: the panel is `.nonactivatingPanel` and never
    /// becomes key, so `.activeInKeyWindow` would never fire.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea, trackingAreas.contains(hoverTrackingArea) {
            removeTrackingArea(hoverTrackingArea)
        }
        // `.inVisibleRect` keeps the area pinned to `bounds` as it changes.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Bridges AppKit tracking into SwiftUI. Suppressed while `dragActive`: a
    /// drag owns the pointer, and letting hover flip mid-drag would pop the
    /// toolbar back under the cursor the user is dragging.
    private func setHovered(_ hovered: Bool) {
        guard !dragActive else { return }
        if rootView.model.isHovered != hovered {
            rootView.model.isHovered = hovered
            print("PILL_HOVER=\(hovered)")
            fflush(stdout)
        }
    }

    /// Re-derives hover from the pointer after a gesture ends: `.mouseExited`
    /// does not re-fire when the pointer never left the bounds mid-press.
    private func refreshHover(for event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if rootView.model.isHovered != inside {
            rootView.model.isHovered = inside
        }
    }

    /// Whether a press point (HOSTING-VIEW coords) falls inside the toolbar row.
    /// The row's rect is a ROUTING HINT only — the buttons own their own hit
    /// regions; this just tells us to forward the gesture to SwiftUI.
    private func isInToolbarRow(_ point: NSPoint) -> Bool {
        let windowHeight = window?.frame.height ?? bounds.height
        let inWindow = convert(point, to: nil)
        let p = CGPoint(x: inWindow.x, y: windowHeight - inWindow.y)
        let row = rootView.model.toolbarRowFrame
        return row.width > 0 && row.height > 0
            && p.x >= row.minX && p.x <= row.maxX
            && p.y >= row.minY && p.y <= row.maxY
    }

    override func mouseDown(with event: NSEvent) {
        // Moment of truth: if this line never prints on a click, the press dies
        // ABOVE this view (window ordering / hit-test), before any pill logic.
        let point = convert(event.locationInWindow, from: nil)
        print("PILL_MD point=(\(Int(point.x)),\(Int(point.y))) hovered=\(rootView.model.isHovered)")
        fflush(stdout)
        // REAL SwiftUI buttons own their hit regions. If the press is inside the
        // toolbar row, hand the whole gesture to `super` (SwiftUI's event sink)
        // so the Button activates natively — NO drag, NO custom post.
        if isInToolbarRow(point) {
            forwardingToSwiftUI = true
            super.mouseDown(with: event)
            return
        }
        let now = Date()
        // While the robot is alone, a double-click must NOT toggle back: the
        // first click already summoned the bar, and a second one would collapse
        // it again. In that state every press is a plain click or a drag.
        let doubleClickAllowed = isMascotOnly?() != true
        if doubleClickAllowed, let lastDown, now.timeIntervalSince(lastDown) < 0.3 {
            self.lastDown = nil
            NotificationCenter.default.post(name: Notification.Name("PopTogglePanel"), object: nil)
            return
        }
        lastDown = doubleClickAllowed ? now : nil
        guard let window else { return }
        // `NSEvent.mouseLocation` is global Cocoa (bottom-left), the same space as
        // window frame origins, so the delta applies without a coordinate flip.
        dragStartMouse = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        dragActive = true
        // Deliberately NOT calling super: this view is the window's drag handle.
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragActive,
              let startMouse = dragStartMouse,
              let startOrigin = dragStartWindowOrigin,
              let window
        else { return }
        // A drag owns the pointer: hide the toolbar so it cannot hover back
        // under the cursor mid-gesture (setHovered is suppressed while dragging).
        if rootView.model.isHovered { rootView.model.isHovered = false }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(
            WindowDrag.clampedOrigin(
                NSPoint(
                    x: startOrigin.x + (mouse.x - startMouse.x),
                    y: startOrigin.y + (mouse.y - startMouse.y)
                ),
                windowSize: window.frame.size,
                near: startOrigin
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        // The gesture began on the toolbar: finish it in SwiftUI so the Button
        // sees its own mouse-up. No summon, no drag bookkeeping.
        if forwardingToSwiftUI {
            forwardingToSwiftUI = false
            super.mouseUp(with: event)
            refreshHover(for: event)
            return
        }
        // A press that never moved the window is a CLICK, not a drag: the robot
        // click TOGGLES its composer surface (open when alone, close when up).
        // Posted in EVERY state — in `bar`/`full` the robot is still on screen,
        // and that is exactly the click the user needs to dismiss the composer.
        let wasDrag = dragStartMouse.map { start in
            hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) > 3
        } ?? false
        dragActive = false
        dragStartMouse = nil
        dragStartWindowOrigin = nil
        if wasDrag {
            // The window already moved during `mouseDragged`; tell the controller
            // so it re-derives the robot anchor from where the robot ENDED UP.
            NotificationCenter.default.post(name: .popRobotDragEnd, object: nil)
        } else {
            NotificationCenter.default.post(name: .popToggleComposer, object: nil)
        }
        refreshHover(for: event)
    }
}

/// Shared by both drag paths (robot headroom and composer bar): keep the window
/// on screen while it follows the cursor.
enum WindowDrag {
    @MainActor
    static func clampedOrigin(_ target: NSPoint, windowSize: NSSize, near origin: NSPoint) -> NSPoint {
        guard let visible = NSScreen.screens
            .first(where: { $0.visibleFrame.contains(origin) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        else { return target }
        return NSPoint(
            x: min(max(target.x, visible.minX), visible.maxX - windowSize.width),
            y: min(max(target.y, visible.minY), visible.maxY - windowSize.height)
        )
    }
}

/// Presentational states for the mascot. This spike is art only: nothing here
/// talks to an agent or a model.
enum MascotState: String, CaseIterable {
    case idle
    case thinking
    case speaking
    case happy
    /// The mic is open and Pop is hearing you out — before any work starts.
    case listening
}

/// Owns the character's current state and the `--mascot-cycle` driver, so both
/// the app and the art-review cycle can mutate one source of truth.
@MainActor
final class MascotModel: ObservableObject {
    @Published var state: MascotState = .idle

    /// True while the pointer is inside the robot's hosting strip. The hover
    /// toolbar is a pure function of this — it owns no lifecycle of its own and
    /// disappears the instant the pointer leaves.
    @Published var isHovered = false

    /// TEMPORARY DIAGNOSTIC for the arc-visibility investigation: the electric
    /// arc's frame in GLOBAL (screen) coordinates, reported by a GeometryReader
    /// attached to `electricArc`. `--test-mascot-arc` reads it to prove whether
    /// the arc lies inside the mascot window without any clicking or eyeballs.
    /// Plain `var` on purpose: it is a measurement sink, not view state, so it
    /// must NOT re-render the tree on every layout pass.
    var arcFrame: CGRect = .zero

    /// TEMPORARY DIAGNOSTIC for `--test-hover-pill`: the number of REAL buttons
    /// the toolbar row drew. The probe asserts it is 3 (the row is built from
    /// `MascotToolbarButton.allCases`, so this catches an empty/failed row).
    /// Plain `var`: a measurement sink, never view state.
    var toolbarButtonCount = 0

    /// The toolbar ROW's drawn rect, in WINDOW coordinates from the TOP-LEFT,
    /// reported by `MascotView`'s GeometryReader. This is a ROUTING HINT for
    /// `MascotHostingView` (decide whether to forward the press to SwiftUI); the
    /// buttons own their own hit regions. Plain `var`: a measurement sink.
    var toolbarRowFrame: CGRect = .zero

    private var cycleTimer: Timer?
    private var stateObserver: NSObjectProtocol?

    /// True while `--mascot-cycle` drives the art, in which case real
    /// conversation states must NOT overwrite the cycle.
    private var isCycling = false

    /// `--mascot-cycle`: walk every state on a fixed cadence so the art can be
    /// reviewed without waiting for real work to happen.
    func startCycling(interval: TimeInterval = 3) {
        isCycling = true
        cycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let all = MascotState.allCases
                let index = all.firstIndex(of: self.state) ?? 0
                self.state = all[(index + 1) % all.count]
            }
        }
    }

    /// Applies an agent state pushed by a real conversation. The cycle mode wins
    /// when it is on, so art review is never interrupted by background work.
    func applyConversationState(_ raw: String) {
        guard !isCycling, let state = MascotState(rawValue: raw) else { return }
        self.state = state
    }

    /// One-shot subscription: the model outlives the view, so the observer is
    /// installed here rather than in the view's `onAppear`.
    func startObservingConversationStates() {
        guard stateObserver == nil else { return }
        stateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("popMascotState"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let raw = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, let raw else { return }
                self.applyConversationState(raw)
            }
        }
    }
}

/// Blue gradient shared by head and body so the character reads as one piece.
private enum MascotPalette {
    static let headTop = Color(red: 0x5B / 255, green: 0x9B / 255, blue: 0xFF / 255)
    static let headBottom = Color(red: 0x3D / 255, green: 0x6F / 255, blue: 0xE8 / 255)
    static let bodyTop = Color(red: 0x4C / 255, green: 0x88 / 255, blue: 0xF2 / 255)
    static let bodyBottom = Color(red: 0x2F / 255, green: 0x5C / 255, blue: 0xCE / 255)
    static let screen = Color(red: 0x14 / 255, green: 0x21 / 255, blue: 0x3F / 255)

    /// Antennae tip colours. Rest is a dim borrow of the head blue so the
    /// antennae read as inert hardware; hot is near-white cyan so "energized"
    /// is unmistakable against the blue cloud, and glow is the halo it casts.
    static let antennaRest = Color(red: 0x8F / 255, green: 0xB4 / 255, blue: 0xF0 / 255)
    static let antennaHot = Color(red: 0xEA / 255, green: 0xF7 / 255, blue: 0xFF / 255)
    static let antennaGlow = Color(red: 0x8F / 255, green: 0xE6 / 255, blue: 0xFF / 255)
}

/// The robot's region inside the panel window: a transparent strip above the web
/// view whose drag handle moves the whole panel.
///
/// The panel is ONE window now, so this is a layout constant rather than a
/// separate window's frame — which is exactly why the old dock/detach geometry
/// class of bug is gone.
enum PanelHeadroom {
    /// The robot strip: the TOP band of every panel state. The robot's feet sit
    /// on its bottom edge.
    static let height: CGFloat = 150
    /// Composer / web width in `bar` and `full`.
    static let width: CGFloat = 640

    /// Mascot-state WINDOW width. The mascot window hosts hover affordances; a
    /// 150pt-wide host left the 136pt pill row only 7pt margins and real clicks
    /// drifted outside it (measured), so the window is sized for comfortable
    /// pill targets.
    static let hoverWidth: CGFloat = 340

    /// A reserved band BELOW the robot's feet for the hover toolbar, so the
    /// pills never overlap the character or its antenna / electric-arc space.
    /// The mascot window is therefore `hoverWidth × (height + pillBandHeight)`.
    static let pillBandHeight: CGFloat = 40
}

/// Art geometry, shared so the drawing and the headroom height cannot drift.
///
/// The bounds are TIGHT: head + torso only, with the feet on the bottom edge of
/// the artwork, so the robot sits flush on top of the composer with no invisible
/// padding reading as a gap.
enum MascotArt {
    /// Head height, including the cloud lobes that overhang the face.
    static let headHeight: CGFloat = 68
    /// Torso height; the two shapes overlap by 2pt.
    static let bodyHeight: CGFloat = 22
    /// Total artwork height.
    static let height: CGFloat = headHeight + bodyHeight - 2
}

/// The mascot character.
///
/// The mascot never takes key focus: this view is hosted in a
/// `.nonactivatingPanel` whose `canBecomeKey` is hard-false, so every control
/// here is a plain `.plain` button that acts on mouse-up alone.
struct MascotView: View {
    @ObservedObject var model: MascotModel

    /// The one action shared by the pill toolbar's live button and a double-click
    /// on the character: toggle the chat panel. The pill itself is gone — the
    /// composer's `+` menu owns New chat — but the double-click stays.
    let onTogglePanel: () -> Void

    // Idle: bobbing and blinking.
    @State private var bobbed = false
    @State private var blinkScale: CGFloat = 1
    @State private var blinkCountdown: TimeInterval = 6

    // Thinking: one dot lit at a time.
    @State private var activeDot = 0

    // Speaking: mouth equalizer.
    @State private var mouthOpen = false

    // Happy: bounce + sparkles.
    @State private var bounceOffset: CGFloat = 0
    @State private var sparkleProgress: CGFloat = 0

    // Antennae: pulse phase while the robot is energized (working).
    @State private var antennaPulse = false

    /// Whether the antennae are energized. A `switch` over every case — rather
    /// than `state == .thinking || state == .speaking` — is deliberate: a future
    /// `MascotState` case cannot be added without making an explicit rest-vs-
    /// energized decision here, so energy stays a pure function of the state
    /// and of whether the user is directly attending to the robot.
    private var isEnergized: Bool {
        switch model.state {
        case .thinking, .speaking: return true
        // The arc shows whenever Pop is working (thinking/speaking) OR the user
        // is directly attending to the robot (hover) — attention is feedback,
        // same as work. The exhaustive switch keeps that a deliberate decision
        // rather than an omission.
        case .idle, .happy, .listening: return model.isHovered
        }
    }

    var body: some View {
        // ONE container, TWO stacked bands: the robot strip on TOP and the pill
        // band BELOW it (the robot's feet band). A plain VStack — not a ZStack
        // with a pin — so the band's position is structural and nothing can
        // silently move it. The pill ROW then reports its own drawn rect, which
        // is the ONE geometry source the hit test reads.
        VStack(spacing: 0) {
            // Robot strip: the TOP `PanelHeadroom.height`, feet on its bottom
            // edge (flush with the composer's top in `bar`).
            mascot.offset(y: bobbed ? -3 : 3)
                .offset(y: bounceOffset)
                .frame(
                    width: PanelHeadroom.hoverWidth,
                    height: PanelHeadroom.height,
                    alignment: .bottom
                )
            // Pill band: the BOTTOM `PanelHeadroom.pillBandHeight`, under the
            // feet. In `bar`/`full` the web view sits in FRONT of this band, so
            // the pills are effectively a `mascot`-state affordance.
            hoverToolbar
                .frame(
                    width: PanelHeadroom.hoverWidth,
                    height: PanelHeadroom.pillBandHeight
                )
        }
        .frame(
            width: PanelHeadroom.hoverWidth,
            height: PanelHeadroom.height + PanelHeadroom.pillBandHeight
        )
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: bobbed)
        .animation(.easeInOut(duration: 0.12), value: blinkScale)
        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: mouthOpen)
        .animation(.easeOut(duration: 0.15), value: model.isHovered)
        .onAppear {
            bobbed = true
            antennaPulse = isEnergized
            scheduleBlink()
            scheduleDotRotation()
        }
        .onChange(of: model.state) { _, newState in
            switch newState {
            case .idle, .thinking, .speaking, .listening:
                bounceOffset = 0
                sparkleProgress = 0
            case .happy:
                runHappySequence()
            }
            // Re-arm the pulse from the new state so it starts on thinking and
            // stops cleanly the moment the robot is no longer working.
            antennaPulse = isEnergized
        }
        .onChange(of: model.isHovered) { _, hovered in
            // Re-arm the pulse on hover too: entering hover energizes the arc,
            // leaving hover disarms it (the arc fades via the one-shot ease).
            antennaPulse = isEnergized
            // ONE observation site for the buzz. Every writer of `isHovered`
            // (tracking enter/exit, post-gesture refresh, drag-clear) lands here,
            // so the audio's lifecycle is a pure function of the single published
            // state rather than of any particular gesture path.
            if hovered {
                ArcBuzzSound.shared.start()
            } else {
                ArcBuzzSound.shared.stop()
            }
        }
    }

    // MARK: - Hover toolbar

    /// TEMPORARY DIAGNOSTIC (but the layout contract): records the toolbar
    /// ROW's true drawn rect, in WINDOW coordinates from the TOP-LEFT. The
    /// hosting view uses it only as a ROUTING HINT (forward the press to SwiftUI
    /// or not) — the real buttons own their own hit regions.
    private func reportRowFrame(_ g: GeometryProxy) {
        let frame = g.frame(in: .global)
        if model.toolbarRowFrame != frame {
            model.toolbarRowFrame = frame
            print("PILL_ROW_FRAME=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))")
            fflush(stdout)
        }
    }

    /// The button row in the reserved band UNDER the robot's feet: REAL SwiftUI
    /// `Button`s in ONE translucent capsule. It exists ONLY while
    /// `model.isHovered`. SwiftUI owns the hit-testing; `MascotHostingView`
    /// forwards presses inside the row to `super` so the buttons activate
    /// natively.
    @ViewBuilder
    private var hoverToolbar: some View {
        if model.isHovered {
            // Guards the fit contract every time the row is about to be drawn.
            let _ = MascotToolbar.assertFitsNarrowestHost()
            HStack(spacing: 0) {
                toolbarButton(.history)
                toolbarButton(.composer)
                toolbarButton(.mic)
            }
            .padding(.horizontal, 6)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
            // Slides UP into place from below the band.
            .transition(.opacity.combined(with: .offset(y: 4)))
            // ROUTING HINT + the probe's button count, captured when the row lays
            // out. NOT a hit table — the buttons hit-test themselves.
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear {
                            reportRowFrame(g)
                            model.toolbarButtonCount = MascotToolbarButton.allCases.count
                        }
                        .onChange(of: g.frame(in: .global)) { _, _ in reportRowFrame(g) }
                }
            )
        }
    }

    /// One REAL button: a single SF glyph, white, with a generous ≥40×28 hit
    /// area. `.contentShape(Rectangle())` makes the whole padded rect clickable
    /// (not just the glyph), so the platform owns the hit-testing.
    private func toolbarButton(_ button: MascotToolbarButton) -> some View {
        Button {
            notify(button)
        } label: {
            Image(systemName: button.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: MascotToolbar.buttonWidth, height: MascotToolbar.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(button.title)
        .accessibilityLabel(button.title)
    }

    /// Posts the button's action. History is deliberately TWO posts: summon the
    /// composer, then ask the page to open its sessions menu (`.popOpenHistory`,
    /// wired to the page's `openMenu()` by workstream C).
    private func notify(_ button: MascotToolbarButton) {
        switch button {
        case .history:
            NotificationCenter.default.post(name: .popSummonBar, object: nil)
            NotificationCenter.default.post(name: .popOpenHistory, object: nil)
        case .composer:
            NotificationCenter.default.post(name: .popSummonBar, object: nil)
        case .mic:
            NotificationCenter.default.post(name: .popMicToggle, object: nil)
        }
    }

    // MARK: - Character

    private var mascot: some View {
        ZStack {
            sparkles
            torso
            head
        }
        .frame(height: MascotArt.height)
        .contentShape(Rectangle())
        // One soft shadow for the whole character; per-part shadows stack into
        // a hard rim at 1x backing scale, and radius >= 8pt keeps the falloff
        // smooth when 1 pt = 1 px.
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
    }

    private var head: some View {
        ZStack {
            // Antennae first, so `cloudSilhouette` covers their stem bases and
            // they read as rooted in the cloud instead of floating above it.
            antennae
            cloudSilhouette
            face
        }
        .frame(width: 92, height: MascotArt.headHeight)
        .rotationEffect(.degrees(model.state == .thinking ? (activeDot % 2 == 0 ? 4 : -4) : 0))
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: activeDot)
        .offset(y: -MascotArt.bodyHeight / 2 + 1)
    }

    /// Bumpy cloud silhouette: a large centre circle with smaller lobes
    /// overlapping it. Circles only — no rounded rectangle — so the outline reads
    /// as cloud lobes instead of a squircle.
    private var cloudSilhouette: some View {
        ZStack {
            // Lobes first, centre lobe last so its edge stays crisp on top.
            Circle()
                .frame(width: 30, height: 30)
                .offset(x: -30, y: -8)
            Circle()
                .frame(width: 32, height: 32)
                .offset(x: 28, y: -10)
            Circle()
                .frame(width: 34, height: 34)
                .offset(x: -8, y: -24)
            Circle()
                .frame(width: 52, height: 52)
                .offset(x: 0, y: -6)
            Circle()
                .frame(width: 46, height: 46)
                .offset(x: -2, y: 14)
        }
        .foregroundStyle(
            LinearGradient(
                colors: [MascotPalette.headTop, MascotPalette.headBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Two symmetric antennae rising from the cloud crown: a short stem whose
    /// base is tucked behind the silhouette, capped by a ball tip that clears the
    /// lobes. The pulse rides `antennaPulse`, so the glow only repeats while
    /// `isEnergized`; returning to rest swaps in a one-shot ease so the tips
    /// settle dim instead of pulsing forever.
    private var antennae: some View {
        ZStack {
            antenna(x: -28)
            antenna(x: 28)
            // Arc last so it renders above the stems and ball tips it bridges.
            electricArc
        }
        .animation(
            isEnergized
                ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.35),
            value: antennaPulse
        )
    }

    /// One antenna: a stem long enough to bury its base behind the cloud, plus
    /// the ball tip that carries the glow. `x` mirrors the pair.
    private func antenna(x: CGFloat) -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    isEnergized
                        ? MascotPalette.antennaGlow.opacity(0.9)
                        : MascotPalette.antennaRest.opacity(0.7)
                )
                .frame(width: 3, height: 24)
                .offset(y: -28)

            Circle()
                .fill(isEnergized ? MascotPalette.antennaHot : MascotPalette.antennaRest)
                .frame(width: 8, height: 8)
                .shadow(
                    color: MascotPalette.antennaGlow.opacity(isEnergized ? 1 : 0),
                    radius: antennaPulse ? 6 : 2
                )
                .opacity(antennaPulse ? 1 : 0.55)
                .offset(y: -41)
        }
        .offset(x: x)
    }

    /// Electric arc bridging the two ball tips while energized. It shares the
    /// single `antennaPulse` / `isEnergized` source of truth with the tips, so it
    /// cannot desynchronize: no arc and no repeating animation at rest, a fast
    /// flickering spark while working. Rendered last inside `antennae` so it sits
    /// above the hardware it jumps between.
    private var electricArc: some View {
        ElectricArc()
            .stroke(
                MascotPalette.antennaHot,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 64, height: 48)
            .shadow(color: MascotPalette.antennaGlow.opacity(0.9), radius: 4)
            .offset(y: -41)
            .opacity(isEnergized ? (antennaPulse ? 1 : 0.6) : 0)
            .animation(
                // Same lifecycle as the tip glow: repeat only while energized,
                // otherwise a one-shot settle so the arc dies out at rest.
                isEnergized
                    ? .easeInOut(duration: 0.18).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.3),
                value: antennaPulse
            )
            .allowsHitTesting(false)
            // TEMPORARY DIAGNOSTIC: report the arc's GLOBAL frame into the model
            // so `--test-mascot-arc` can measure it headlessly. Runs even at
            // opacity 0 (the view still lays out), which is the point: we want
            // its geometry regardless of the energized gate.
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { model.arcFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, new in
                            model.arcFrame = new
                        }
                }
            )
    }

    /// A deterministic 4-segment lightning bolt. Coordinates live in a 64×48 box
    /// centred on the pair of ball tips, so its endpoints (4,24) and (60,24) land
    /// exactly on the tip centres (x ±28, y −41 in `antennae` space). The zigzag
    /// is fixed — the live-spark feel comes from the arc's opacity flicker — so
    /// the shape stays cheap and never needs random state.
    private struct ElectricArc: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 4, y: 24))
            path.addLine(to: CGPoint(x: 18, y: 7))
            path.addLine(to: CGPoint(x: 27, y: 39))
            path.addLine(to: CGPoint(x: 38, y: 8))
            path.addLine(to: CGPoint(x: 47, y: 41))
            path.addLine(to: CGPoint(x: 60, y: 24))
            return path
        }
    }

    private var face: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MascotPalette.screen)
                .frame(width: 58, height: 38)

            switch model.state {
            case .idle:
                chevronEyes
                smallMouth

            case .thinking:
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .opacity(activeDot == index ? 1 : 0.25)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: activeDot)

            case .listening:
                chevronEyes
                // A SINGLE soft dot where the mouth sits, breathing while the
                // mic is open — deliberately not thinking's three-dot chase.
                // It lives inside this branch, so its animation exists only
                // while the state does: no separate lifecycle to start/stop.
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                    .offset(y: 12)
                    .phaseAnimator([1.0, 0.3]) { dot, phase in
                        dot.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }

            case .speaking, .happy:
                chevronEyes
                smallMouth
                    .scaleEffect(x: 1, y: model.state == .speaking && mouthOpen ? 3.0 : 1)
            }
        }
        .offset(y: 2)
    }

    /// The reference's `>_<` squint: two white chevron strokes, not dots. A blink
    /// squashes them vertically rather than swapping shapes, which keeps the
    /// character's identity across states.
    private var chevronEyes: some View {
        HStack(spacing: 15) {
            chevronEye(pointingRight: true)
            chevronEye(pointingRight: false)
        }
        .scaleEffect(x: 1, y: blinkScale)
    }

    private func chevronEye(pointingRight: Bool) -> some View {
        Path { path in
            let w: CGFloat = 7
            let h: CGFloat = 6
            if pointingRight {
                path.move(to: CGPoint(x: -w / 2, y: -h / 2))
                path.addLine(to: CGPoint(x: w / 2, y: 0))
                path.addLine(to: CGPoint(x: -w / 2, y: h / 2))
            } else {
                path.move(to: CGPoint(x: w / 2, y: -h / 2))
                path.addLine(to: CGPoint(x: -w / 2, y: 0))
                path.addLine(to: CGPoint(x: w / 2, y: h / 2))
            }
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .frame(width: 7, height: 6)
    }

    private var smallMouth: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(.white)
            .frame(width: 10, height: 2.5)
            .offset(y: 12)
    }

    private var torso: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(MascotPalette.bodyBottom)
                .frame(width: 7, height: 16)
                .offset(x: -20, y: 4)

            Capsule(style: .continuous)
                .fill(MascotPalette.bodyBottom)
                .frame(width: 7, height: 16)
                .offset(x: 20, y: 4)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MascotPalette.bodyTop, MascotPalette.bodyBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 32, height: MascotArt.bodyHeight)
        }
        .offset(y: -MascotArt.bodyHeight / 2)
    }

    private var sparkles: some View {
        ZStack {
            sparkleSymbol
                .offset(x: -38, y: -34)
                .scaleEffect(sparkleProgress)
                .opacity(1 - sparkleProgress)
            sparkleSymbol
                .offset(x: 36, y: -24)
                .scaleEffect(sparkleProgress * 0.8)
                .opacity((1 - sparkleProgress) * 0.9)
        }
        .allowsHitTesting(false)
    }

    private var sparkleSymbol: some View {
        Circle()
            .fill(.white)
            .frame(width: 7, height: 7)
            .blur(radius: 0.5)
    }

    // MARK: - Drivers

    /// Blink every 4–8s: the eyes squash to a slit for 120ms.
    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + blinkCountdown) {
            blinkScale = 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                blinkScale = 1
                blinkCountdown = Double.random(in: 4...8)
                scheduleBlink()
            }
        }
    }

    /// One-second tick that walks the thinking dots through their sequence.
    private func scheduleDotRotation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            activeDot = (activeDot + 1) % 3
            scheduleDotRotation()
        }
    }

    /// Two bounces with sparkle bursts on either side of the character.
    private func runHappySequence() {
        Task { @MainActor in
            sparkleProgress = 0
            withAnimation(.easeOut(duration: 0.5)) { sparkleProgress = 1 }
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.16)) { bounceOffset = -8 }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.easeIn(duration: 0.16)) { bounceOffset = 0 }
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
    }
}