import Foundation

/// Per-turn latency, measured END-TO-END and printed to STDOUT ONLY.
///
/// The user asked for these numbers OFF-SCREEN: a turn must not grow a debug
/// line in the transcript, so nothing here ever reaches the page — this type
/// cannot call the bridge at all. It exists because "the first message is slow"
/// had no numbers behind it: without them, pre-warming is a guess.
///
/// Three stages are timed, because they are the three things that can be slow
/// and only one of them is the model:
///  * `TURN_MS` — send to the answer being complete, the number the user feels;
///  * `FM_FIRST_MS` — send to the FIRST provider call, so model/framework
///    initialisation is separable from generation;
///  * `LOOKUP_MS` / `WARM_MS` — the web turn's own total and the session-warm
///    inside it, which is the part that moves when the warm is pre-paid at
///    launch.
///
/// A single writer per field on the main actor, guarded by a lock because
/// `WebLookup` and the provider both report from detached tasks.
final class TurnMetrics: @unchecked Sendable {
    static let shared = TurnMetrics()

    private let lock = NSLock()
    private var turnStart: Date?
    private var firstProviderCallMs: Int?
    private var lookupMs: Int?
    private var warmMs: Int?

    /// Called when the user sends. Resets every stage so a later turn cannot
    /// report the previous turn's numbers.
    func beginTurn(at date: Date = Date()) {
        lock.lock()
        turnStart = date
        firstProviderCallMs = nil
        lookupMs = nil
        warmMs = nil
        lock.unlock()
    }

    /// The first provider call of this turn. Recorded ONCE: a fallback to the
    /// second brain must not overwrite the first call's latency with its own.
    func markFirstProviderCall(at date: Date = Date()) {
        lock.lock()
        if firstProviderCallMs == nil, let start = turnStart {
            firstProviderCallMs = Int(date.timeIntervalSince(start) * 1000)
        }
        lock.unlock()
    }

    /// One `web_lookup` of this turn: its own total and how much of it was the
    /// session warm. `warm` is nil when the warm was skipped (already formed),
    /// which is the pre-warm working.
    func recordLookup(totalMs: Int, warmMs warm: Int?) {
        lock.lock()
        lookupMs = (lookupMs ?? 0) + totalMs
        if let warm { warmMs = (warmMs ?? 0) + warm }
        lock.unlock()
    }

    /// Printed from `finish`/`fail`, so a turn that never completes still
    /// reports what it got to. `nil` stages are omitted rather than guessed.
    func reportTurnEnded(prefix: String = "TURN") {
        lock.lock()
        let start = turnStart
        let fm = firstProviderCallMs
        let lookup = lookupMs
        let warm = warmMs
        turnStart = nil
        firstProviderCallMs = nil
        lookupMs = nil
        warmMs = nil
        lock.unlock()

        guard let start else { return }
        var line = "\(prefix)_MS=\(Int(Date().timeIntervalSince(start) * 1000))"
        if let fm { line += " FM_FIRST_MS=\(fm)" }
        if let lookup { line += " LOOKUP_MS=\(lookup)" }
        if let warm { line += " WARM_MS=\(warm)" }
        print(line)
        fflush(stdout)
    }
}