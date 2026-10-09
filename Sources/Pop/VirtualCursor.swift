import AppKit
import CoreGraphics
import SwiftUI

/// GHOST CURSOR: when Pop works the mouse, the user must SEE where it acts,
/// and the user's OWN cursor must not be the thing that moves.
///
/// The problem this solves is a trust one. `BrowserActions.click` posts a real
/// mouseMoved+down+up burst at the target, which physically drags the user's
/// pointer across the screen for the tens of ms the posts take and leaves it
/// there. Even after the click path restores the pointer, the pointer's own
/// travel is a disorienting side effect the user never asked for. This overlay
/// is the visible stand-in: a Pop-blue arrow that moves to the target and
/// ripples on the click, so the act is legible WITHOUT hijacking the real
/// cursor.
///
/// RULES THIS TYPE KEEPS:
///  * NOTHING HERE INTERACTS. The panel is `ignoresMouseEvents = true`, so a
///    click or hover passes straight through to whatever is underneath — the
///    overlay can never steal an input or answer a hit test. It is pixels only.
///  * PROBES STAY ISOLATED. Disabled by default in any `--test-*`/`--user-*`
///    run unless that run asks for it, so a probe never warps the developer's
///    real cursor; `POP_GHOST_CURSOR=0/1` overrides outright, matching the
///    `LaunchPrewarm.isEnabled` idiom.
///  * EVERY CALL IS SAFE TO REPEAT. All entry points are `@MainActor` and
///    no-op when disabled, so the click path can call them unconditionally.
enum VirtualCursor {
    /// True when this process may draw the ghost cursor. Same shape as
    /// `LaunchPrewarm.isEnabled`: explicit env wins, else off in probe runs.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["POP_GHOST_CURSOR"] == "0" { return false }
        if ProcessInfo.processInfo.environment["POP_GHOST_CURSOR"] == "1" { return true }
        let isProbe = CommandLine.arguments.contains {
            $0.hasPrefix("--test-") || $0.hasPrefix("--user-")
        }
        return !isProbe
    }

    /// The overlay is square; the ~44pt arrow's tip sits at its centre, so the
    /// window origin is `target - side/2` and the arrow (44pt down-right) and
    /// ripple both fit inside the half without clipping.
    @MainActor private static let side: CGFloat = 112

    @MainActor private static var panel: NSPanel?
    @MainActor private static var model: GhostCursorModel?
    @MainActor private static var hideTask: Task<Void, Never>?

    /// Move the ghost to a Quartz global point and show it. Animates the window
    /// over ~200 ms; the panel LANDS exactly on the target frame, so the final
    /// position is frame-accurate even though the travel is interpolated.
    @MainActor
    static func move(to quartzPoint: CGPoint) {
        guard isEnabled else { return }
        cancelPendingHide()
        let target = appKitPoint(forQuartz: quartzPoint)
        let panel = panelInstance()
        panel.orderFrontRegardless()
        let frame = NSRect(
            x: target.x - side / 2,
            y: target.y - side / 2,
            width: side,
            height: side
        )
        // Animate the WINDOW origin, not a SwiftUI offset: the animator lands on
        // the exact frame, and a second move mid-flight retargets from wherever
        // the panel currently is.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// One expanding+fading ripple centred on a Quartz global point. The panel
    /// is placed at the point instantly first, so the ripple is centred even if
    /// `move` had not run.
    @MainActor
    static func clickPulse(at quartzPoint: CGPoint) {
        guard isEnabled else { return }
        cancelPendingHide()
        let target = appKitPoint(forQuartz: quartzPoint)
        let panel = panelInstance()
        panel.setFrame(
            NSRect(x: target.x - side / 2, y: target.y - side / 2, width: side, height: side),
            display: true
        )
        panel.orderFrontRegardless()
        // Bumping the id recreates the ripple subtree, replaying its onAppear
        // animation. A second click back-to-back simply relights it.
        model?.rippleID &+= 1
    }

    /// Schedule the hide ~0.9 s out. A newer act cancels the pending hide, so
    /// two acts in quick succession leave the ghost up for the second one.
    @MainActor
    static func end() {
        guard isEnabled else { return }
        cancelPendingHide()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            panel?.orderOut(nil)
        }
    }

    // MARK: - Internals

    @MainActor
    private static func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// The one lazily-created panel. Configured once; every act reuses it.
    @MainActor
    private static func panelInstance() -> NSPanel {
        if let panel { return panel }
        let model = GhostCursorModel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // THE non-interference guarantee: the overlay ignores every mouse event,
        // so a click or hover passes through to the app underneath and the ghost
        // can never steal an input or answer a hit test.
        panel.ignoresMouseEvents = true
        // Belt and braces: even if a future styleMask change re-enables
        // key-ability, key is only taken when a control actually needs it.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: GhostCursorView(model: model, side: side))
        Self.panel = panel
        Self.model = model
        return panel
    }

    /// Quartz global (origin top-left of the primary display, y down) to AppKit
    /// global (origin bottom-left of the primary display, y up). The two share
    /// x and differ only by a flip about the PRIMARY display's top edge — Cocoa's
    /// global origin is the primary's bottom-left, so that top is the flip line
    /// regardless of any display sitting above it; the result lands on whichever
    /// display contains the point.
    @MainActor
    private static func appKitPoint(forQuartz point: CGPoint) -> CGPoint {
        let flipY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: flipY - point.y)
    }
}

/// Observable state shared with the hosting view: `rippleID` is the click
/// pulse's replay trigger. `@MainActor` because every writer is the MainActor
/// API above.
@MainActor
final class GhostCursorModel: ObservableObject {
    @Published var rippleID = 0
}

/// Pop's ghost-cursor azure: macOS system blue (#0A84FF — 10/255, 132/255,
/// 255/255). Shared by the arrow and the ripple so pulse and pointer read as one
/// actor.
private let ghostAzure = Color(red: 0.04, green: 0.52, blue: 1.0)

/// The overlay's pixels: the arrow plus the click ripple. The arrow is filled
/// AZURE with a WHITE outline — the exact inverse of the system cursor's
/// white-fill/black-outline, so it can never be mistaken for the real pointer.
private struct GhostCursorView: View {
    @ObservedObject var model: GhostCursorModel
    let side: CGFloat

    /// The arrow frame is the path's drawn bounds (tip at its own top-left), so
    /// placing the frame's top-left at the panel centre lands the TIP on the
    /// target point — the load-bearing hotspot alignment.
    private let arrowWidth: CGFloat = 26
    private let arrowHeight: CGFloat = 44

    var body: some View {
        ZStack {
            RippleCircle().id(model.rippleID)
            CursorArrowShape()
                .fill(ghostAzure)
                .overlay(CursorArrowShape().stroke(Color.white, lineWidth: 2.5))
                // Soft shadow so the azure+white arrow reads on light AND dark
                // backgrounds, not just on the desktop wallpaper.
                .shadow(color: .black.opacity(0.35), radius: 6, x: 2, y: 2)
                .frame(width: arrowWidth, height: arrowHeight)
                // Tip (frame top-left) at panel centre: the centred frame's
                // origin is (side-w)/2, so add w/2 to reach side/2.
                .offset(x: arrowWidth / 2, y: arrowHeight / 2)
        }
        .frame(width: side, height: side)
    }
}

/// One expanding, fading ring, replayed by identity on each click. Azure, so the
/// pulse is visibly the same actor as the arrow.
private struct RippleCircle: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(ghostAzure.opacity(0.7), lineWidth: 2.5)
            .frame(width: 12, height: 12)
            .scaleEffect(expanded ? 4 : 0.4)
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { expanded = true }
            }
    }
}

/// A cursor arrow whose tip is the path's origin (top-left), body extending
/// down-right, ~44pt tall. Filled azure and stroked in white so it is the
/// inverse of the real cursor rather than a near-match for it.
private struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 37))
        path.addLine(to: CGPoint(x: 9, y: 29))
        path.addLine(to: CGPoint(x: 15, y: 44))
        path.addLine(to: CGPoint(x: 22, y: 41))
        path.addLine(to: CGPoint(x: 15, y: 26))
        path.addLine(to: CGPoint(x: 26, y: 26))
        path.closeSubpath()
        return path
    }
}
