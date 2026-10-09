import AVFoundation

/// Reads an assistant reply aloud, once, through the system speech synthesiser.
///
/// WHY a wrapper instead of touching `AVSpeechSynthesizer` at the call site:
/// `AVSpeechSynthesizer.delegate` is a WEAK reference, so a synthesizer whose
/// only strong owner is a local goes silent the instant the calling function
/// returns — the classic deallocated-delegate bug. This object IS the delegate
/// and owns the synthesizer strongly, so a caller holds one long-lived object
/// and the completion callback is guaranteed to fire.
///
/// The surface is deliberately small and turn-shaped: `speak` (one reply, one
/// completion) and `stop` (abort). Speech is driven by the turn lifecycle, not
/// polling; the one watchdog is a last-resort so a hung engine cannot leave the
/// mascot stuck in "speaking".
@MainActor
final class SpeechSynth: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    /// The utterance that currently owns `completion`. Delegate callbacks are
    /// delivered LATER on the main actor, so identity — not a nil-out — is what
    /// decides whether a callback counts: a superseded utterance's didCancel is
    /// ignored outright, and only the active one may fire its completion.
    private var activeUtterance: AVSpeechUtterance?
    /// Pending end-of-utterance callback, owned by `activeUtterance`.
    private var completion: (() -> Void)?
    /// Last-resort: if the active utterance never reports finish/cancel, fire
    /// the completion once so the turn cannot hang in "speaking".
    private var speakWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speaks `text` and invokes `completion` when the utterance finishes (or is
    /// cancelled by the system). A re-entrant call SUPERSEDES the old utterance:
    /// the old completion is dropped and the old didCancel is ignored by the
    /// identity check, so two replies can never both resume one turn.
    func speak(_ text: String, completion: @escaping () -> Void) {
        // Read PROSE, not markup: a fence or a run of `**` read aloud is noise,
        // so strip first and bail if nothing readable remains.
        let prose = Self.prose(from: text)
        guard !prose.isEmpty else {
            completion()
            return
        }
        if synthesizer.isSpeaking {
            // Drop the old completion and stop; the old utterance's delayed
            // didCancel will be rejected by `utterance === activeUtterance`.
            self.completion = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        self.completion = completion

        let utterance = AVSpeechUtterance(string: prose)
        utterance.voice = Self.preferredVoice()
        // A touch below the default so a long answer is easier to follow.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        activeUtterance = utterance
        synthesizer.speak(utterance)
        armWatchdog()
    }

    /// Aborts any in-flight speech. DROPS the completion (the stop/turn paths
    /// own the mascot state, and a stale completion announcing "happy" would
    /// fight the "idle" they set) and retires the utterance so its pending
    /// didCancel cannot fire. Safe when idle (pure no-op).
    func stop() {
        self.completion = nil
        speakWatchdog?.cancel()
        speakWatchdog = nil
        // Retire identity BEFORE the interrupt so the didCancel it triggers is
        // ignored rather than treated as the active utterance completing.
        activeUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Exactly one completion per utterance. Non-active utterances (superseded
    /// or already retired) are ignored entirely.
    private func finishUtterance(_ utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
        speakWatchdog?.cancel()
        speakWatchdog = nil
        let block = completion
        completion = nil
        block?()
    }

    private func armWatchdog() {
        speakWatchdog?.cancel()
        speakWatchdog = Task { @MainActor [weak self] in
            // A long-but-healthy reply at rate*0.95 routinely exceeds 30s, so a
            // bare elapsed time is NOT evidence of a hang. Only force-finish on
            // POSITIVE evidence (still active but the engine stopped speaking);
            // otherwise re-arm and keep waiting.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                guard let active = self.activeUtterance else { return }
                if self.synthesizer.isSpeaking { continue }
                // The engine hung: force the completion once, then retire.
                self.finishUtterance(active)
                return
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finishUtterance(utterance) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finishUtterance(utterance) }
    }

    /// First `en-US` voice, preferring an enhanced/premium install when the user
    /// has downloaded one. Falls back to whatever the system exposes.
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        if let premium = english.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = english.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Turns a markdown reply into the prose a person would read aloud. Code is
    /// dropped (fences AND inline spans), link syntax keeps only its label, and
    /// emphasis/heading markers are removed. Whitespace collapses LAST so the
    /// utterance is a clean sentence stream, not a line-by-line recital.
    static func prose(from markdown: String) -> String {
        var s = markdown
        // Fenced code blocks, ``` or ~~~, non-greedy across newlines.
        s = s.replacingOccurrences(of: "(?s)```.*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)~~~.*?~~~", with: " ", options: .regularExpression)
        // Inline code spans.
        s = s.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        // [label](url) → label.
        s = s.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        // Emphasis markers and heading hashes.
        s = s.replacingOccurrences(of: "[*_#>]+", with: " ", options: .regularExpression)
        // Collapse runs of whitespace, then trim the edges.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
