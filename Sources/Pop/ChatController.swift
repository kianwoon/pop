import AppKit
import CoreGraphics
import Foundation
import ImageIO

extension Notification.Name {
    /// Mascot agent-state changes driven by a real conversation.
    /// `object` is the `MascotState` raw value: thinking | speaking | happy | listening | idle.
    static let popMascotState = Notification.Name("popMascotState")

    /// Posted by `PanelController.hide()` — the ONE funnel every
    /// "collapse-to-mascot" dismissal shares (robot click, Esc, ⌥Space). The
    /// mic's owner listens so a live mic never outlives the surface it was
    /// started from.
    static let popPanelDismissed = Notification.Name("popPanelDismissed")
}

/// TEST SEAMS for M9. Production NEVER writes these; only probes do. They exist
/// so the fallback path can be measured deterministically without an env var
/// that could change what the app does for a real user.
final class ProviderTestSeams: @unchecked Sendable {
    static let shared = ProviderTestSeams()
    private let lock = NSLock()
    private var _availability: OnDeviceAvailability?
    private var _fallbackEnabled = true
    private var _legacyFlattenedPrompt =
        ProcessInfo.processInfo.environment["POP_FM_LEGACY_PROMPT"] == "1"
    private var _forceEcho = ProcessInfo.processInfo.environment["POP_FM_FORCE_ECHO"] == "1"
    private var _logPrompt = ProcessInfo.processInfo.environment["POP_FM_LOG_PROMPT"] == "1"
    private var _lastPrompt = ""
    private var _lastWebMarker = ""
    private var _lastInferredNotInQuery: [String] = []
    private var _lastDeclaredSlots: [String] = []
    private var _lastMissingSlots: [String] = []
    private var _lastSlotCandidates: [String] = []
    private var _lastAskFired = false
    private var _lastModelTextBeforeAsk = ""
    private var _webLookupCount = 0
    private var _fmPrewarmFinished = false
    private var _fmInitCalls = 0
    private var _fmInitCallsBeforePrewarm = -1
    private var _fmFirstRealCallInitMs: Int?
    private var _fmFirstRealCallAt: Date?

    // MARK: - Stream-timeout probe seams

    /// Provider injected by `--test-stream-timeout` / `--test-fallback-carry`.
    /// `resolveProvider` prefers these over the real decision, so a probe can
    /// drive the EXACT `handleChatSend` path with a scripted brain.
    private var _primaryProviderOverride: ModelProvider?
    private var _fallbackProviderOverride: ModelProvider?

    /// The clock the stream watchdog/timeout read. `Date()` in production; a
    /// probe swaps in a fast-forwarding clock so a 60s/180s idle policy can be
    /// measured in sub-second wall time instead of a real sleep.
    private var _streamClock: @Sendable () -> Date = { Date() }

    var primaryProviderOverride: ModelProvider? {
        get { lock.lock(); defer { lock.unlock() }; return _primaryProviderOverride }
        set { lock.lock(); _primaryProviderOverride = newValue; lock.unlock() }
    }

    var fallbackProviderOverride: ModelProvider? {
        get { lock.lock(); defer { lock.unlock() }; return _fallbackProviderOverride }
        set { lock.lock(); _fallbackProviderOverride = newValue; lock.unlock() }
    }

    var streamClock: @Sendable () -> Date {
        get { lock.lock(); defer { lock.unlock() }; return _streamClock }
        set { lock.lock(); _streamClock = newValue; lock.unlock() }
    }

    /// `nil` means "ask the framework". A probe forces e.g.
    /// `.unavailable(.appleIntelligenceNotEnabled)`.
    var availability: OnDeviceAvailability? {
        get { lock.lock(); defer { lock.unlock() }; return _availability }
        set { lock.lock(); _availability = newValue; lock.unlock() }
    }

    /// Set false by the negative-control probe so an unavailable on-device
    /// brain has nowhere to go and must surface a visible error.
    var fallbackEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fallbackEnabled }
        set { lock.lock(); _fallbackEnabled = newValue; lock.unlock() }
    }

    /// PROBE SEAM: force the turn's jev route choice (including a forced nil).
    /// `nil` = unset, so the loop asks jev for real. Set ONLY by
    /// `--test-routing-fallback`; production never writes it.
    private var _forcedRouteChoice: ForcedRouteChoice?
    var forcedRouteChoice: ForcedRouteChoice? {
        get { lock.lock(); defer { lock.unlock() }; return _forcedRouteChoice }
        set { lock.lock(); _forcedRouteChoice = newValue; lock.unlock() }
    }

    /// NEGATIVE-CONTROL seam: select the pre-fix prompt construction (the whole
    /// conversation flattened into one `"Role: text"` string). Production is
    /// false; only `POP_FM_LEGACY_PROMPT=1` turns it on, so the regression that
    /// echoed the user's question can be reproduced on demand.
    var legacyFlattenedPrompt: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _legacyFlattenedPrompt }
        set { lock.lock(); _legacyFlattenedPrompt = newValue; lock.unlock() }
    }

    /// NEGATIVE-CONTROL seam (`POP_FM_FORCE_ECHO=1`): the provider answers with
    /// the exact prompt it received. Deterministically proves the echo gate can
    /// fail — a gate that cannot fail is worthless (SPEC §10 rule 4).
    var forceEcho: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _forceEcho }
        set { lock.lock(); _forceEcho = newValue; lock.unlock() }
    }

    /// Observability: the exact prompt string the last on-device stream sent.
    /// The echo-detection probe reads it to compare reply against prompt.
    var logPrompt: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _logPrompt }
        set { lock.lock(); _logPrompt = newValue; lock.unlock() }
    }

    var lastPrompt: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastPrompt }
        set { lock.lock(); _lastPrompt = newValue; lock.unlock() }
    }

    /// The most recent `web_lookup` marker — the panel/action-log line. Read by
    /// the probes to prove the marker was produced; never used for behaviour.
    var lastWebMarker: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastWebMarker }
        set { lock.lock(); _lastWebMarker = newValue; lock.unlock() }
    }

    /// The ASK-RULE values from the most recent `web_lookup` — retained as
    /// LOW-CONFIDENCE metadata for the action log only. `finish` does NOT read
    /// this, so a scraped page token can never become a user-facing ask.
    var lastInferredNotInQuery: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _lastInferredNotInQuery }
        set { lock.lock(); _lastInferredNotInQuery = newValue; lock.unlock() }
    }

    /// The CALLER-DECLARED required parameter names from the most recent
    /// `web_lookup`. `finish` composes the ask from the missing subset only.
    var lastDeclaredSlots: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _lastDeclaredSlots }
        set { lock.lock(); _lastDeclaredSlots = newValue; lock.unlock() }
    }

    /// Declared slots the query did not supply. Non-empty is the ONLY condition
    /// that makes Pop ask.
    var lastMissingSlots: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _lastMissingSlots }
        set { lock.lock(); _lastMissingSlots = newValue; lock.unlock() }
    }

    /// Page values offered as suggestions for a missing declared slot.
    var lastSlotCandidates: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _lastSlotCandidates }
        set { lock.lock(); _lastSlotCandidates = newValue; lock.unlock() }
    }

    /// Observability: whether Pop composed a deterministic ask on the last turn.
    var lastAskFired: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _lastAskFired }
        set { lock.lock(); _lastAskFired = newValue; lock.unlock() }
    }

    /// OBSERVABILITY: the model's OWN trimmed turn text, captured before the
    /// deterministic ask replaces it. Lets the ask-honesty probe show what the
    /// model authored alongside the tool's list, so a paraphrased or invented
    /// value is visible rather than hidden behind the override.
    var lastModelTextBeforeAsk: String {
        get { lock.lock(); defer { lock.unlock() }; return _lastModelTextBeforeAsk }
        set { lock.lock(); _lastModelTextBeforeAsk = newValue; lock.unlock() }
    }

    /// How many `web_lookup` runs this process has performed. A turn that makes
    /// no network call leaves this at zero — the evidence for the zero-network
    /// gate.
    var webLookupCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _webLookupCount }
        set { lock.lock(); _webLookupCount = newValue; lock.unlock() }
    }

    // MARK: - Transcript-render seams

    /// Lines `pushToolLine` rendered to the transcript, and lines it SUPPRESSED
    /// as debug-only. Recorded so a probe can prove a provider-plumbing notice
    /// (the fallback line) reached the log but NOT the transcript, without
    /// reading its own stdout.
    private var _renderedLines: [String] = []
    private var _suppressedLines: [String] = []

    var renderedLines: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _renderedLines }
        set { lock.lock(); _renderedLines = newValue; lock.unlock() }
    }

    var suppressedLines: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _suppressedLines }
        set { lock.lock(); _suppressedLines = newValue; lock.unlock() }
    }

    func noteRenderedLine(_ line: String) {
        lock.lock()
        _renderedLines.append(line)
        if _renderedLines.count > 256 { _renderedLines.removeFirst(_renderedLines.count - 256) }
        lock.unlock()
    }

    func noteSuppressedLine(_ line: String) {
        lock.lock()
        _suppressedLines.append(line)
        if _suppressedLines.count > 256 { _suppressedLines.removeFirst(_suppressedLines.count - 256) }
        lock.unlock()
    }

    // MARK: - Launch pre-warm (model init)

    /// Every `LanguageModelSession` this process has built, and the FIRST one's
    /// cost. The pre-warm's value is entirely in this number: if the first real
    /// turn's session is built for free because the pre-warm already paid for
    /// init, then the model warm happened.
    func noteFMInit(at date: Date = Date()) {
        lock.lock()
        if _fmInitCalls == 0 {
            _fmFirstRealCallAt = _fmFirstRealCallAt ?? date
        }
        _fmInitCalls += 1
        lock.unlock()
    }

    /// The pre-warm's own generation finished, so any session built after this
    /// point is one the framework no longer had to initialise from cold.
    func noteFMPrewarmFinished() {
        lock.lock()
        _fmPrewarmFinished = true
        _fmInitCallsBeforePrewarm = _fmInitCalls
        lock.unlock()
    }

    /// Measured, not asserted from the log: a pre-warm ran, AND the real first
    /// call built its session with init already behind it.
    var fmPrewarmEffective: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fmPrewarmFinished && _fmInitCalls > _fmInitCallsBeforePrewarm
    }

    /// `PREWARM` / `NO_PREWARM`, so the live launch log says which happened.
    var fmPrewarmFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fmPrewarmFinished
    }
}

/// The provider decision for one send: which brain answers first, what (if
/// anything) it falls back to, and the honest reason.
struct ProviderChoice {
    /// Tried first. An unhealthy on-device provider throws immediately.
    var primary: ModelProvider
    /// Built LAZILY, only when the primary is unavailable or throws. A closure
    /// (not a provider) so a healthy on-device turn never reads the Keychain.
    var fallbackFactory: (@Sendable () -> ModelProvider)?
    /// `on-device` | `remote` | `remote-fallback` | `on-device-unavailable`.
    var decision: String
    /// Human reason when the on-device brain cannot answer.
    var reason: String
    /// A visible one-liner to render when the fallback path is taken.
    var notice: String?
}

/// PROBE-ONLY (M9 routing fallback): a forced jev route choice. The double
/// optional is deliberate — a bare `String?` cannot tell "force NO route" apart
/// from "no override", and the disabled/no-route case must be expressible.
/// Production never writes one; only `--test-routing-fallback` does.
struct ForcedRouteChoice: Sendable {
    let value: String?
}

/// Where a turn came from, and therefore whether its reply may be spoken.
///
/// The invariant: whether a reply is spoken is a property of the TURN'S ORIGIN,
/// not a global setting. A `chatSend` whose body carries `source: "voice"` (the
/// mic path) speaks; every typed send is silent. Threaded from the bridge,
/// through `handleChatSend`, into the stream completion closure, so approvals
/// and tool results that re-enter a turn keep the origin.
enum SendSource: Sendable {
    case text
    case voice
}

/// Owns one streaming conversation: bridge message in, provider deltas out to
/// both the web UI and the mascot, transcript persisted on disk.
///
/// Main-actor isolated because every step touches the WKWebView. The heavy work
/// (the provider stream) runs in a detached task so a slow model never blocks
/// the run loop; cancellation is the stop button.
@MainActor
final class ChatController {
    /// Most recent entries sent to the provider. The transcript itself is
    /// unbounded on disk; only the request context is capped.
    static let maxHistoryMessages = 8

    private let webViewProvider: () -> FocusableWebView?
    private var transcript: TranscriptStore
    private let sessions: SessionStore
    private var configProvider: () -> PopConfig

    /// The conversation this controller is writing to. Created LAZILY on the
    /// first turn, not at launch: a launch that is never used must leave no
    /// trace on disk, and the user asked to start fresh every launch anyway —
    /// an old session is resumed only by picking it from the `+` menu.
    private(set) var currentSessionId: String?

    /// The ONLY source of model context. Session-scoped on purpose.
    private var sessionHistory: [ChatMessage] = []

    /// Context pieces the user has removed with a chip's ×, e.g. {"app","selection",
    /// "screenshot"}. Reset by `newChat()` with the rest of the session.
    private var excludedContextKeys: Set<String> = []

    private var streamTask: Task<Void, Never>?
    /// Warns ONCE if a stream goes 60s without a token. Diagnostic only.
    private var streamWatchdog: Task<Void, Never>?
    /// Aborts the stream after `streamIdleCapSeconds()` of TOKEN SILENCE so a
    /// genuinely wedged one cannot block later sends. NOT a cap on total turn
    /// time: the idle timer restarts on every token.
    private var streamTimeout: Task<Void, Never>?
    private var mascotHappyReset: Task<Void, Never>?

    /// True while THIS listen owns a voice-only surface. Gates the panel
    /// restores so a cancel/send never collapses or expands the panel behind the
    /// user's back. Every listen start sets it (a listen is always voice-only).
    private var voiceOnlyActive = false

    /// Speaks assistant replies for voice-originated turns only. INVARIANT:
    /// replies are spoken exactly when the turn was voice-initiated; typed
    /// replies are always silent; the duck (`isListening`) still suppresses
    /// speech. Long-lived (like the stores) so its weak-delegate synthesizer
    /// always has an owner; created once here rather than per turn.
    private let speech = SpeechSynth()

    /// The microphone. Long-lived so the audio engine, tap and recognition task
    /// survive between clicks and can be torn down from any stop path.
    private let speechListener = SpeechListener()

    /// The time of the most recent token (or stream start). Read against the
    /// injectable `streamClock` so the idle policy is probe-measurable.
    private var lastTokenAt = Date()

    /// One tool round the CURRENT turn already executed, captured so a mid-turn
    /// fallback can hand its result to the cloud brain instead of dropping it.
    /// Reset at the start of every send.
    private struct FallbackToolRound {
        var id: String?
        var name: String
        var arguments: String
        var result: String?
    }

    private var fallbackToolRounds: [FallbackToolRound] = []

    /// Results that arrived BEFORE their call was seen (the two arrive on
    /// different MainActor hops), parked until the call shows up.
    private var fallbackPendingResults: [(name: String, result: String)] = []

    /// The last error text handed to the page. Probes read this to prove the
    /// rendered payload is human, never a raw debug string.
    private(set) var lastErrorText = ""

    /// Set by the probes to count delta pushes.
    private(set) var deltaCount = 0
    /// Probe-only: zero the delta counter between chained sends in one process.
    func probeResetDeltaCount() { deltaCount = 0 }

    /// Probe-visible count of mic auto-stops triggered by panel dismissal. The
    /// mic cannot run headless (needs TCC), so a probe proves the WIRING by
    /// reading this after it collapses the panel.
    private(set) var voiceAutostopCount = 0
    private(set) var lastMascotState = "idle"

    /// OBSERVABILITY: which brain actually produced the most recent turn. Set
    /// when a provider starts answering, so it reflects a real fallback rather
    /// than the pre-send intention. The M9 probes read it.
    private(set) var lastAnsweredBy = ""

    /// OBSERVABILITY: the exact final text the model streamed, before any DOM
    /// round-trip. The echo probes compare THIS against the prompt — the
    /// rendered `innerText` drops newlines, so a multi-line echo would not
    /// compare equal and the assertion would be vacuous.
    private(set) var lastAnswerFull = ""

    /// Set by the probes to observe the rendered approval-resolution line
    /// without a live page. `nil` in the app.
    var approvalObserver: ((String) -> Void)?

    /// Set by the probes to observe the human error text without a live page.
    var errorObserver: ((String) -> Void)?

    /// True while a turn is in flight. Probes poll this to know a send settled.
    var probeIsStreaming: Bool { streamTask != nil }

    init(
        webViewProvider: @escaping () -> FocusableWebView?,
        transcript: TranscriptStore = TranscriptStore(),
        sessions: SessionStore = SessionStore(),
        configProvider: @escaping () -> PopConfig
    ) {
        self.webViewProvider = webViewProvider
        self.transcript = transcript
        self.sessions = sessions
        self.configProvider = configProvider
        // The gate is a singleton (a tool call parks inside it, from whichever
        // provider's task), so the page sink is installed once by the single
        // owner of a web view rather than threaded through every call site.
        let controller = self
        ApprovalGate.shared.sink = { json in
            await MainActor.run { controller.pushApprovalCard(json) }
        }
        ApprovalGate.shared.resolution = { tool, marker in
            await MainActor.run { controller.pushApprovalOutcome(tool: tool, marker: marker) }
        }
        // The browser's HUMAN-VISIBLE one-liners land in the transcript through
        // the existing tool-line path. No new bridge message: the model already
        // receives the full result as its tool message, and a browser action the
        // user cannot see is exactly the failure this prevents.
        BrowserController.shared.onVisible = { line in
            MainActor.assumeIsolated { controller.pushToolLine(line) }
        }
        BrowserController.shared.onStateChange = { state in
            MainActor.assumeIsolated { controller.pushBrowserState(state) }
        }
        // A CONFIGURED-but-DEAD advisory service announces itself ONCE per run.
        // Without this, jev-enabled Pop silently falls back to rule-based
        // defaults (no routing hint, no card labels, no run labels) and the user
        // never learns why — that silence is what let a fabricated answer go
        // unnoticed for two rounds. ONE notice, not per-call: per-call notices
        // would spam every approval card while the service stays down.
        JevBridge.onFirstFailure = { [weak self] reason in
            // `advisory` runs off-main; hop to the main actor to touch the page.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.noteJevDegraded(reason: reason) }
            }
        }
        // The microphone talks to the page and the mascot through the same
        // controller the turn pipeline uses, so listening is a first-class
        // state and not a side channel.
        speechListener.onPartial = { [weak self] text in self?.pushVoicePartial(text) }
        speechListener.onFinal = { [weak self] text in self?.finishVoiceInput(text) }
        speechListener.onError = { [weak self] message in self?.failVoiceInput(message) }
        speechListener.onNotice = { [weak self] message in self?.pushVoiceNotice(message) }
        speechListener.onListeningChanged = { [weak self] active in self?.pushVoiceState(active) }

        // The hover toolbar (MascotView) drives the same two composer actions
        // WITHOUT the bridge: a mic click and a History click.
        //
        // Mic: the very same `toggleVoice()` the bridge uses.
        NotificationCenter.default.addObserver(
            forName: .popMicToggle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleVoice() }
        }
        // History: the bar must be VISIBLE FIRST. The toolbar posts
        // `.popSummonBar` before this; re-assert it anyway (idempotent —
        // `summonBar()` no-ops unless the panel is resting in `mascot`), let
        // that transition land, THEN TOGGLE the `+` menu. A toggle, not an open:
        // a press on the History pill while the popover is already up closes it,
        // so the surface can never latch open (invisible or not).
        NotificationCenter.default.addObserver(
            forName: .popOpenHistory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .popSummonBar, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                    MainActor.assumeIsolated { self?.callAPI("toggleMenu", argumentsJSON: "") }
                }
            }
        }

        // THE FORGOTTEN-MIC SAFETY NET. `PanelController.hide()` is the single
        // funnel every dismissal (robot click, Esc, ⌥Space) shares; when the
        // listening surface leaves the screen, consent to listen goes with it.
        // Stopping HERE — not at each call site — is what makes that guarantee
        // structural: no future dismissal path can forget the mic.
        NotificationCenter.default.addObserver(
            forName: .popPanelDismissed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                print("VOICE_MIC_AUTOSTOP listening=\(self.speechListener.isListening)")
                fflush(stdout)
                // `stop()` is idempotent-safe (it guards on isListening), so a
                // dismissal while NOT listening no-ops cleanly.
                if self.speechListener.isListening { self.speechListener.stop() }
                // The surface is gone whoever owned it, so a later Send must not
                // try to re-collapse an already-collapsed panel.
                self.voiceOnlyActive = false
                self.voiceAutostopCount += 1
            }
        }
    }

    /// Makes sure a session exists, and returns its id. Lazy on purpose: see
    /// `currentSessionId`.
    @discardableResult
    private func ensureSession() -> String {
        if let currentSessionId { return currentSessionId }
        let session = sessions.startSession()
        currentSessionId = session.id
        return session.id
    }

    /// The single append path for a turn: the session file AND the in-memory
    /// model context. Every turn in the app goes through here, including the
    /// probes, so persistence can never drift from what the user saw.
    func recordTurn(role: ChatMessage.Role, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = TranscriptStore.Entry(
            ts: Date().timeIntervalSince1970,
            role: role.rawValue,
            text: trimmed
        )
        sessions.append(entry, to: ensureSession())
        sessionHistory.append(ChatMessage(role: role, text: trimmed))
    }

    /// Called when the panel is summoned: if the user has text selected in the
    /// frontmost app, drop it into the input as a quoted prefill. It is NOT sent
    /// automatically — the user still has to hit Enter.
    func offerSelectionPrefill() {
        let observation = Observe.observeAll()
        guard let selection = observation.selection, !selection.isEmpty else { return }
        let quoted = "> " + selection.replacingOccurrences(of: "\n", with: "\n> ")
        callAPI("prefill", argumentsJSON: jsonString(quoted))
    }

    /// The CURRENT conversation, pushed into the transcript view on explicit
    /// request. It is the session's own turns, not the legacy
    /// `transcript.jsonl` archive: the archive is every conversation ever
    /// had, concatenated, and rendering it would splice unrelated chats into
    /// one transcript.
    ///
    /// NOT called at launch, by design: the transcript must never make the
    /// panel expand at default. The user's requirement is absolute — by
    /// default the panel shows the launcher only, so a conversation appears
    /// when it is SENT or when it is OPENED from the menu.
    func handleHistoryRequest() {
        guard let currentSessionId else {
            callAPI("history", argumentsJSON: "[]")
            return
        }
        let entries = sessions.turns(for: currentSessionId).map { ["role": $0.role, "text": $0.text] }
        callAPI("history", argumentsJSON: jsonArray(entries))
    }

    /// True while no message has been sent this session. `PanelController` uses
    /// it to refuse page-driven expansion into `full`: at launch the session is
    /// empty, so any `uiHeight: full` the page asks for is the archive talking,
    /// not a conversation.
    var sessionIsEmpty: Bool { sessionHistory.isEmpty }

    /// Asks the page to focus the composer. Called by the ⌥Space hotkey, which
    /// never changes the panel state — only the caret moves.
    func focusInput() {
        callAPI("focusInput", argumentsJSON: "")
    }

    /// Starts a fresh conversation: model context is dropped and the visible
    /// transcript is cleared. The CURRENT session is finalized first — its
    /// title and turn count — so "new chat" never costs the user a
    /// conversation. The archive file is untouched.
    func newChat() {
        stop()
        if let currentSessionId {
            sessions.updateTitleTurnCount(currentSessionId)
        }
        currentSessionId = nil
        sessionHistory.removeAll()
        excludedContextKeys.removeAll()
        callAPI("newChat", argumentsJSON: "")
        pushSessionList()
        // A fresh conversation returns the launcher to its resting bar.
        NotificationCenter.default.post(
            name: Notification.Name("popPanelHeightRequest"),
            object: PanelState.bar.rawValue
        )
    }

    /// Reopens a past conversation: any in-flight generation is abandoned, the
    /// session becomes current, its turns become the model context (capped at
    /// send time, never on disk), the page is handed the FULL transcript, and
    /// the panel grows so the user can actually see it.
    ///
    /// Returns the number of turns loaded, so a caller can prove the restore.
    @discardableResult
    func openSession(_ id: String) -> Int {
        stop()
        currentSessionId = id
        let turns = sessions.turns(for: id)
        sessionHistory = turns.map { ChatMessage(role: $0.role == ChatMessage.Role.user.rawValue ? .user : .assistant, text: $0.text) }
        excludedContextKeys.removeAll()
        let entries = turns.map { ["role": $0.role, "text": $0.text] }
        callAPI("history", argumentsJSON: jsonArray(entries))
        pushSessionList()
        // A restored conversation is a conversation: it must be visible, and
        // `full` is refused by `PanelController` only while the session is
        // empty — loading turns is what makes it non-empty.
        NotificationCenter.default.post(
            name: Notification.Name("popPanelHeightRequest"),
            object: PanelState.full.rawValue
        )
        return turns.count
    }

    /// Session records for the `+` menu: newest first, preformatted so the
    /// page does no date parsing.
    func pushSessionList() {
        let list = sessions.sessions().map { session in
            [
                "id": session.id,
                "title": session.title,
                "time": session.stamp,
                "turns": String(session.turnCount)
            ]
        }
        callAPI("sessions", argumentsJSON: jsonArray(list))
    }

    /// Chip × button: drop one context piece from the next request.
    func excludeContextKey(_ key: String) {
        excludedContextKeys.insert(key)
    }

    /// `+` menu checkmark: include a context piece again (or drop it). Removal is
    /// a set, so restoring means taking the key back out of it.
    func toggleContextKey(_ key: String, on: Bool) {
        if on {
            excludedContextKeys.remove(key)
        } else {
            excludedContextKeys.insert(key)
        }
        // Re-push so the native view of the snapshot matches the new toggles.
        pushContextUI()
    }

    // MARK: - Context chips

    /// Chip descriptors for the current snapshot. Unlike the M0 chip row, a
    /// removed piece is STILL listed — the `+` menu shows it unchecked so the
    /// user can switch it back on — so each chip carries an `on` flag.
    private func contextChips(for obs: Observation) -> [[String: String]] {
        var chips: [[String: String]] = []

        func add(_ key: String, _ label: String, _ kind: String) {
            chips.append([
                "key": key,
                "label": label,
                "kind": kind,
                "on": excludedContextKeys.contains(key) ? "false" : "true"
            ])
        }

        // Short label: app name plus the first clause of the window title.
        var label = obs.appName
        let shortTitle = obs.windowTitle.components(separatedBy: " — ").first ?? obs.windowTitle
        if shortTitle != "nil", !shortTitle.isEmpty {
            label += " · " + (shortTitle.count > 28 ? String(shortTitle.prefix(28)) + "…" : shortTitle)
        }
        add("app", label, "app")
        if let url = obs.url, !url.isEmpty {
            add("url", url.count > 48 ? String(url.prefix(48)) + "…" : url, "url")
        }

        if let selection = obs.selection, !selection.isEmpty {
            let flat = selection.replacingOccurrences(of: "\n", with: " ")
            add("selection", flat.count > 40 ? String(flat.prefix(40)) + "…" : flat, "selection")
        }

        if obs.screenshot != nil {
            add("screenshot", "screenshot", "shot")
        }

        return chips
    }

    /// Pushes the chip row, the thumbnail and the privacy pill. Called whenever
    /// the panel is summoned, so the composer describes the user's screen
    /// before they type.
    func pushContextUI() {
        let observation = Observe.summonSnapshot
        guard let observation else { return }
        callAPI("contextChips", argumentsJSON: jsonArray(contextChips(for: observation)))

        if !excludedContextKeys.contains("screenshot"),
           let dataURL = Self.thumbnailDataURL(from: observation.screenshot?.data) {
            callAPI("contextShot", argumentsJSON: jsonString(dataURL))
        }

        let config = configProvider()
        let onDevice = config.provider != "openai-compat"
        callAPI("providerStatus", argumentsJSON: jsonDictionary([
            "label": onDevice ? "On-device" : "Cloud",
            "cloud": String(!onDevice)
        ]))
    }

    /// Downscales the screenshot to ≤320px wide for the chip thumbnail. Returns
    /// nil rather than sending a multi-megabyte data URL into a web view.
    private static func thumbnailDataURL(from png: Data?) -> String? {
        guard let png, !png.isEmpty else { return nil }
        let maxWidth = 320
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
        )
        guard let image = thumbnail,
              let encoded = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64," + encoded.base64EncodedString()
    }

    /// Stops any in-flight generation. Safe to call when nothing is running.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        cancelStreamWatchdog()
        cancelStreamTimeout()
        mascotHappyReset?.cancel()
        mascotHappyReset = nil
        // A new turn must never overlap the previous reply still being read
        // aloud: kill it first. The completion is dropped, so the old turn
        // cannot announce a mascot state into this one — this path must settle
        // the face itself if it actually cut an utterance short.
        //
        // Key off the ANNOUNCED state, not AVFoundation's instantaneous flag: a
        // didFinish may already have flipped `isSpeaking` false while its
        // MainActor finish Task is still queued, in which case `speech.stop()`
        // retires the utterance and rejects that callback — so an isSpeaking
        // predicate would announce nothing and leave the face stuck.
        let wasSpeaking = lastMascotState == "speaking"
        speech.stop()
        if wasSpeaking { announceMascot("idle") }
        // A turn start closes the mic too: Pop must never listen while it works.
        speechListener.stop()
        callAPI("chatDone", argumentsJSON: "")
    }

    /// THE PERSON PRESSED STOP. Deliberately NOT `stop()`: that path is the
    /// generic teardown and settles the page with `chatDone`, which leaves an
    /// empty assistant block and no explanation — the silent-discard symptom.
    /// This one pushes `chatStopped`, so the turn keeps whatever arrived and
    /// gains a `stopped by you` receipt, and the status line reads `stopped`.
    ///
    /// A stop with nothing in flight is a no-op rather than a fabricated
    /// receipt: the page only offers the control while it is streaming, so this
    /// is the guard against a stale click inventing a turn that never existed.
    func stopByUser() {
        guard streamTask != nil else {
            print("STOP_NOOP nothing-streaming")
            fflush(stdout)
            return
        }
        streamTask?.cancel()
        streamTask = nil
        cancelStreamWatchdog()
        cancelStreamTimeout()
        mascotHappyReset?.cancel()
        mascotHappyReset = nil
        // An aborted turn takes its speech with it; the `idle` below is the
        // final word, so the synth must not fire a completion afterwards.
        speech.stop()
        // Stop also closes the mic: an aborted turn must not keep listening.
        speechListener.stop()
        print("STOP_BY_USER")
        fflush(stdout)
        callAPI("chatStopped", argumentsJSON: "")
        announceMascot("idle")
    }

    /// Replaces the transcript store (used by probes that isolate a run).
    func setTranscript(_ store: TranscriptStore) {
        transcript = store
    }

    private func handleChatSend(text: String, source: SendSource = .text) {
        guard streamTask == nil else {
            // A wedged stream used to swallow this send with no trace at all,
            // which is why "nothing happens" repeated forever. Say it twice —
            // once for the log, once for the person.
            print("SEND_REJECTED busy")
            fflush(stdout)
            pushChatError("Still generating — press ■ to stop first")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sendEntered = Date()

        // A new send pre-empts any reply still being spoken: the previous turn's
        // voice must not talk over this one. It also closes the mic, so a voice
        // final that started this turn cannot leave the mic open under it.
        speech.stop()
        speechListener.stop()

        // Turn-scoped: clear last turn's declared slots so a web_lookup THIS
        // turn is the only thing that can make Pop compose an ask below.
        ProviderTestSeams.shared.lastDeclaredSlots = []
        ProviderTestSeams.shared.lastMissingSlots = []
        ProviderTestSeams.shared.lastSlotCandidates = []
        ProviderTestSeams.shared.lastInferredNotInQuery = []
        ProviderTestSeams.shared.lastAskFired = false
        ProviderTestSeams.shared.lastModelTextBeforeAsk = ""
        // Turn-scoped: no tool result from a PREVIOUS turn may be carried.
        fallbackToolRounds = []
        fallbackPendingResults = []
        lastErrorText = ""

        // A plan belongs to the request that made it: a stale plan from the
        // previous turn would render as this turn's progress. Cleared here
        // rather than at the end of a turn so a cancelled or failed turn cannot
        // leave one behind.
        PlanTraceStore.shared.reset()
        callAPI("planUpdate", argumentsJSON: "[]")

        transcript.append(role: .user, text: trimmed)
        // TIMED FROM THE SEND, so `TURN_MS` is what the user actually waits.
        // Off-screen: `TurnMetrics` prints to stdout and never to the page.
        TurnMetrics.shared.beginTurn()
        announceMascot("thinking")

        // The first send of a session is what grows the launcher bar into the
        // transcript panel; `newChat` puts it back.
        //
        // ORDER IS THE FIX: this must come AFTER the append. Requesting the
        // height first meant the panel asked "is this session empty?" about the
        // very send that was creating the first turn, got `true`, and refused
        // to expand — so `PANEL_STATE=full` never happened and the answer
        // rendered into a 0-height bubble ("i send hi but i can't see the
        // respond"). The append makes the session non-empty first, so the
        // request is judged as what it actually is: a real conversation
        // starting.
        NotificationCenter.default.post(
            name: Notification.Name("popPanelHeightRequestSend"),
            object: PanelState.full.rawValue
        )

        let config = configProvider()
        // The send critical path does NO multi-second work: context observation
        // and prefix assembly are handed to the background turn task below, so
        // the panel expands immediately while the warm-up runs unseen. Only
        // CHEAP, main-thread-owned state is read here.
        let contextMode = config.contextMode
        let excluded = excludedContextKeys
        let initialSnapshot = Observe.summonSnapshot

        // Session-scoped context. MEASURED: history drawn from transcript.jsonl
        // was saturated with exact-reply test turns, and the small on-device
        // model anchored on them and answered "POP_ALIVE" to unrelated
        // questions. The transcript stays an archive for display; only this
        // in-memory array is ever sent to a model.
        //
        // ONE append path: the current session's file AND the model context,
        // so a resumed conversation and the one on screen cannot disagree.
        recordTurn(role: .user, text: trimmed)

        // Prompt layout is fixed and load-bearing for caching:
        //   [ system instructions ][ tool schemas ][ observation + clock ]
        //   [ recent turns ][ new message ]
        // Everything before the per-turn block is byte-identical turn over
        // turn, which is the whole point of `PREFIX_STABLE`: a warm cache needs
        // the head to stop moving.
        // Once per turn, because it is a property of the CONFIG: printed per
        // tool it would bury the line that explains a rejected path.
        print("PATH_SCOPE=\(ToolRegistry.pathScope.rawValue)")
        fflush(stdout)
        let toolSchemas = ToolRegistry.schemas()
        print("PREFIX_STABLE tools=\(toolSchemas.count) hash=\(Self.stablePrefixHash())")
        fflush(stdout)

        var messages = sessionHistory

        // Context hygiene: cap what is SENT. Bounds tokens within a session.
        if messages.count > Self.maxHistoryMessages {
            messages = Array(messages.suffix(Self.maxHistoryMessages))
        }
        print("HISTORY_SENT=\(messages.count)")
        fflush(stdout)

        // The observation prefix rides on the final (current) turn, and the
        // screenshot with it, because that is the only message the providers
        // treat as "the prompt". The user text is NOT labelled "User: ": the
        // on-device brain now carries prior turns in the session transcript, and
        // an embedded role label made the current prompt read as a one-line
        // transcript the model continued — it echoed the user's own words.
        // Splice + prompt capture now happen in the background turn task.

        // Captured for the non-answer check below: the user's own words, and the
        // exact prompt string the provider is handed.
        let userText = trimmed

        deltaCount = 0
        let options = GenerationOptions(temperature: config.temperature)

        // Captured STRONGLY and by a local constant: the controller lives for the
        // app's lifetime, and a `[weak self]` capture makes every `MainActor.run`
        // hop a "captured var in concurrently-executing code" warning.
        let controller = self
        streamTask = Task.detached {
            // THE SEND CRITICAL PATH DOES NO MULTI-SECOND WORK. Context
            // observation and prefix assembly run HERE, in the background turn
            // task, hidden from the user, while the panel expands immediately.
            // This print proves the main-thread send path returned first.
            print("SEND_OFFMAIN_MS=\(Int(Date().timeIntervalSince(sendEntered) * 1000))")
            fflush(stdout)
            var turnMessages = messages
            var providerPrompt = userText
            // Context mode (v0 default on): the observation block rides THIS turn
            // only, so it is never persisted as if the user had typed it. The block
            // is a BOUNDED summary (app/window/selection, hard-capped): no AX tree
            // and no screenshot are ever handed to the model.
            var contextPrefix = ""
            if contextMode {
                // Summon-time snapshot preferred: at send time the user is in Pop's
                // panel, so a fresh observation would describe Pop, not their work.
                // Falls back only if nothing was captured (e.g. a programmatic send
                // with no summon). Kept, not consumed, so later turns about the same
                // screen still work; the next summon overwrites it.
                var observation = initialSnapshot ?? Observe.observeAll()
                // A quick-only snapshot means the user sent before the off-path heavy
                // pass finished. Fill it in here rather than dropping the screenshot
                // and AX excerpt from this turn. Mirrors PanelController.show()'s
                // heavy path.
                if observation.axExcerpt.isEmpty && observation.screenshot == nil {
                    let filled = Observe.observeHeavy(target: observation)
                    observation = filled
                    await MainActor.run { Observe.summonSnapshot = filled }
                }
                // Chip removals are applied to the snapshot BEFORE the prefix is
                // built, so a removed piece cannot leak back in through it.
                if excluded.contains("app") {
                    observation.windowTitle = "nil"
                    observation.url = nil
                    observation.bundleID = ""
                    observation.appName = ""
                    observation.axExcerpt = []
                    observation.axState = .empty
                }
                if excluded.contains("selection") { observation.selection = nil }
                if excluded.contains("screenshot") { observation.screenshot = nil }
                print("CONTEXT_APP=\(observation.bundleID)")
                fflush(stdout)
                contextPrefix = Observe.makeContextPrefix(observation)
            } else {
                print("CONTEXT_APP=none")
                fflush(stdout)
            }
            // The clock rides in the VOLATILE tail of the prompt, after every
            // stable prefix line: "what is today's date & time?" is then answered
            // from the request itself, with no tool call and no extra latency.
            // This runs UNCONDITIONALLY: clock + splice are turn-invariant prompt
            // assembly, independent of contextMode (contextMode off still sends a
            // clock line, exactly as before the move). `withClock` is main-actor
            // state, so this lone hop is where the codebase already hops.
            let rawContextPrefix = contextPrefix
            contextPrefix = await MainActor.run { Self.withClock(rawContextPrefix) }
            print("CONTEXT_ATTACHED=\(contextPrefix.count)")
            fflush(stdout)
            // The observation prefix rides on the final (current) turn, and the
            // screenshot with it, because that is the only message the providers
            // treat as "the prompt".
            if !turnMessages.isEmpty {
                var finalMessage = turnMessages[turnMessages.index(before: turnMessages.endIndex)]
                finalMessage.text = contextPrefix.isEmpty
                    ? finalMessage.text
                    : "\(contextPrefix)\n\n\(finalMessage.text)"
                turnMessages[turnMessages.index(before: turnMessages.endIndex)] = finalMessage
                providerPrompt = finalMessage.text
            }
            fflush(stdout)
            // THE TURN'S JEV ROUTE, resolved ONCE here at turn start — before any
            // provider exists. The choice is passed INTO `resolveProvider`, which
            // returns the (possibly promoted) provider for this turn. It used to
            // be resolved inside `AgentLoop.stream`, i.e. AFTER the provider was
            // already chosen, where a hands-on route could only be injected as a
            // hint line and never acted on. See `resolveProvider`'s promotion.
            let routeChoice = await Self.turnRouteChoice(config: config, messages: turnMessages)
            let resolved = Self.resolveProvider(config, route: routeChoice)
            // PRE-FLIGHT BUDGET CHECK. The on-device model can blow its context
            // window MID-TURN — the stack grows with prefix + schemas +
            // observation + history + tool results — which the user feels as a
            // long stall before the mid-turn fallback. Estimate the prompt here
            // and, when it arithmetically cannot fit, divert to the cloud
            // BEFORE any on-device call. Keyed on the AppleFM TYPE so probe
            // ScriptedProviders are never diverted (byte-identical).
            //
            // Rough estimate: chars/4 is the usual English chars-per-token
            // heuristic (±20%). Message text + ~16 chars/msg role framing, the
            // FM system prompt (it rides every on-device turn), plus the tool
            // schemas (name + description + a flat 400/tool allowance for
            // parameters). The 400/tool is MEASURED: the registry is ≈4,779
            // tokens pruned (≈400/tool with params). Over-estimating is the SAFE
            // direction — it diverts earlier; under-estimating is the failure
            // mode this gate exists to stop.
            let messageChars = turnMessages.reduce(0) { $0 + $1.text.count + 16 }
            let systemChars = AppleFMProvider.systemPrompt.count
            let schemaChars = toolSchemas.reduce(0) {
                $0 + $1.name.count + $1.description.count + 400
            }
            let estTokens = (messageChars + schemaChars + systemChars) / 4
            let window = AppleFMProvider.contextWindowSize()
            var preflightDecision = "on-device"
            // Built as a `var` then frozen into `choice` (a `let`), so the
            // concurrently-executing closures below capture an immutable value.
            var diverted = resolved
            // 85% headroom: a prompt at the full window leaves no budget to emit
            // the answer itself.
            if resolved.primary is AppleFMProvider,
               let factory = resolved.fallbackFactory,
               estTokens > window * 85 / 100 {
                diverted.primary = factory()
                // A cloud primary has no cloud failure mode to rescue, so drop
                // the same-builder fallback: keeping it would print the wrong
                // "On-device did not answer" and spawn a phantom second cloud
                // provider on an empty carry.
                diverted.fallbackFactory = nil
                // Reuse the remote-routing decision so the EXISTING notice site
                // below renders it — same plumbing as a promoted route.
                diverted.decision = "remote-routing"
                diverted.notice = "Turn too large for the on-device brain "
                    + "(est \(estTokens) of \(window) tokens) \u{2014} using the cloud"
                preflightDecision = "cloud"
            }
            print("FM_PREFLIGHT est=\(estTokens) budget=\(window) decision=\(preflightDecision)")
            fflush(stdout)
            let choice = diverted
            // Ready to answer if the primary is healthy OR a fallback exists to
            // catch it. An unhealthy primary with NO fallback is a dead end, and a
            // dead end must say so — visibly, not as an empty panel.
            guard choice.primary.isHealthy || choice.fallbackFactory != nil else {
                let reason = choice.reason.isEmpty ? "provider unavailable" : choice.reason
                print("PROVIDER_DEAD_END reason=\(reason)")
                fflush(stdout)
                await MainActor.run {
                    controller.pushChatError(reason)
                    controller.announceMascot("idle")
                    controller.streamTask = nil
                }
                return
            }
            // A promoted hands-on route resolves to the REMOTE primary, which IS
            // healthy — so the existing unhealthy-primary notice never fires.
            // Surface this turn's routing notice (and move the pill to Cloud)
            // here, through the SAME visible-notice plumbing the M9 fallback uses.
            if choice.decision == "remote-routing", let notice = choice.notice {
                await MainActor.run { controller.pushBrainNotice(notice) }
            }
            // STREAM OBSERVABILITY. The user reported "hi pop" with no reply and
            // no visible cause: the stream had started but produced nothing, which
            // is indistinguishable from an app that ignored the input. These two
            // markers make the silence legible in a log without changing behaviour.
            print("STREAM_START provider=\(type(of: choice.primary)) decision=\(choice.decision)")
            fflush(stdout)
            // The idle clock is anchored here; it advances only on a token.
            await MainActor.run {
                controller.lastTokenAt = controller.streamNow()
                controller.startStreamWatchdog()
                controller.startStreamTimeout()
            }
            var announcedSpeaking = false
            // One provider's turn, start to finish. Factored out so the fallback
            // path runs the EXACT same loop with the other brain.
            func run(_ p: ModelProvider, extraMessages: [ChatMessage] = []) async throws -> String {
                var full = ""
                let label = String(describing: type(of: p))
                // The FIRST provider call of the turn: separated from the
                // generation itself so model init shows up as its own number.
                TurnMetrics.shared.markFirstProviderCall()
                await MainActor.run { controller.lastAnsweredBy = label }
                let loop = AgentLoop.stream(
                    provider: p,
                    messages: extraMessages.isEmpty ? turnMessages : turnMessages + extraMessages,
                    options: options,
                    tools: toolSchemas,
                    route: AgentLoop.RouteResolution(choice: routeChoice),
                    onUI: { event in
                        await MainActor.run {
                            controller.handleTurnUI(event)
                        }
                    }
                ) { outcome in
                    await MainActor.run {
                        controller.pushToolActivity(outcome)
                    }
                }
                for try await event in loop {
                    if Task.isCancelled { break }
                    switch event {
                    case .delta(let piece):
                        if !announcedSpeaking {
                            announcedSpeaking = true
                            await MainActor.run { controller.announceMascot("speaking") }
                        }
                        full += piece
                        await MainActor.run { controller.handleDelta(piece) }
                    case .done(let text):
                        full = text
                    case .toolCall(let id, let name, let arguments):
                        // Captured so a mid-turn fallback can carry this round's
                        // arguments (and its result, recorded from `activity`) to
                        // the cloud brain instead of dropping them.
                        await MainActor.run {
                            controller.noteFallbackToolCall(
                                name: name,
                                arguments: arguments.stableString(),
                                id: id
                            )
                            controller.announceMascot("thinking")
                        }
                    }
                }
                return full
            }

            // The mid-turn fallback: hand the cloud brain the tool results the
            // on-device attempt already collected, so it resumes instead of
            // re-running (or losing) the work. The CLOUD's tool choices are
            // unchanged — only the context it starts from gains the results.
            func runFallback(_ factory: @Sendable () -> ModelProvider) async throws -> String {
                let carry = await MainActor.run { controller.fallbackCarryMessages() }
                let count = carry.count / 2
                if count > 0 {
                    print("FALLBACK_TOOLS_CARRIED=\(count)")
                    fflush(stdout)
                }
                return try await run(factory(), extraMessages: carry)
            }

            do {
                var full: String
                if !choice.primary.isHealthy, let factory = choice.fallbackFactory {
                    // Unavailable BEFORE any token: go straight to the fallback
                    // and say why, once.
                    await MainActor.run {
                        controller.pushBrainNotice(
                            choice.notice ?? "On-device unavailable \u{2014} using the cloud brain"
                        )
                    }
                    full = try await runFallback(factory)
                } else {
                    do {
                        full = try await run(choice.primary)
                        // THE USER'S RULE: on-device first, but a NON-ANSWER is
                        // handed to the remote brain rather than shown. A reply
                        // that is empty, a verbatim echo of the user's own words,
                        // or a short explicit refusal is not an answer — and
                        // presenting the user's question back is exactly the
                        // reported defect.
                        if let factory = choice.fallbackFactory,
                           !Task.isCancelled,
                           !Self.isUsableReply(
                               full,
                               userText: userText,
                               providerPrompt: providerPrompt
                           ) {
                            await MainActor.run {
                                controller.pushBrainNotice(
                                    "On-device did not answer \u{2014} using the cloud brain"
                                )
                                controller.resetLiveTurnForFallback()
                            }
                            full = try await runFallback(factory)
                        }
                    } catch {
                        // The on-device call threw: fall back if we can.
                        guard let factory = choice.fallbackFactory, !Task.isCancelled else {
                            throw error
                        }
                        await MainActor.run {
                            controller.pushBrainNotice(
                                "On-device did not answer \u{2014} falling back to the cloud brain"
                            )
                        }
                        full = try await runFallback(factory)
                    }
                }

                guard !Task.isCancelled else { return }
                let final = full
                await MainActor.run { controller.finish(full: final, source: source) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { controller.fail(error) }
            }
        }
    }

    /// One compact `TOOL name -> ok|error` line per call. It goes to Pop's own
    /// debug log ONLY — see `isDebugOnlyLine`. A failed call is still fully
    /// diagnosable from stdout; it just no longer appears in the transcript the
    /// user reads.
    /// Records a tool call this turn made, for fallback carry. The matching
    /// result arrives later through `pushToolActivity` (the framework runs the
    /// tool after emitting the call), so pairing is by name + pending result.
    fileprivate func noteFallbackToolCall(name: String, arguments: String, id: String?) {
        fallbackToolRounds.append(FallbackToolRound(
            id: id,
            name: name,
            arguments: arguments,
            result: nil
        ))
        // A result that arrived first (see `noteFallbackToolResult`) is claimed
        // by the call it belongs to.
        let index = fallbackToolRounds.count - 1
        if let pending = fallbackPendingResults.firstIndex(where: { $0.name == name }) {
            fallbackToolRounds[index].result = fallbackPendingResults[pending].result
            fallbackPendingResults.remove(at: pending)
        }
    }

    /// Attaches a tool result to the earliest still-open call of that name; if
    /// the call has not been seen yet, the result is parked until it is.
    fileprivate func noteFallbackToolResult(name: String, result: String) {
        if let index = fallbackToolRounds.lastIndex(where: {
            $0.name == name && $0.result == nil
        }) {
            fallbackToolRounds[index].result = result
        } else {
            fallbackPendingResults.append((name: name, result: result))
        }
    }

    /// The already-collected tool results, as OpenAI-shaped assistant/tool
    /// message pairs. A `.tool` message must be introduced by an assistant
    /// `tool_calls` entry with a matching id or an OpenAI-compatible server
    /// rejects it, so both halves are built here; a native call with no id gets
    /// a synthetic one.
    fileprivate func fallbackCarryMessages() -> [ChatMessage] {
        var out: [ChatMessage] = []
        var synthetic = 0
        for round in fallbackToolRounds {
            guard let result = round.result else { continue }
            let id = round.id ?? "call_fb_\(synthetic)"
            synthetic += 1
            out.append(ChatMessage(
                role: .assistant,
                text: "",
                toolCalls: [ChatMessage.ToolCall(
                    id: id,
                    name: round.name,
                    arguments: round.arguments
                )]
            ))
            out.append(ChatMessage(role: .tool, text: result, toolCallId: id))
        }
        return out
    }

    fileprivate func pushToolActivity(_ outcome: ToolRoundOutcome) {
        // A PLAN UPDATE IS PRODUCT UI, NOT PLUMBING. It goes to the page as its
        // own block (so an update REPLACES it rather than appending a new copy)
        // and it deliberately does NOT go through `pushToolLine`: that path
        // renders `TOOL <name> → ok`, which the user banned and which says
        // nothing about progress.
        if outcome.name == "plan_update" {
            if outcome.ok {
                pushPlanBlock()
            } else {
                // A refused update is the model being told why. It stays
                // off-screen (a mistake by Pop is not progress the user asked
                // to watch) but stays in the debug log.
                print("PLAN_UPDATE_REFUSED \(outcome.detail.prefix(200))")
                fflush(stdout)
            }
            return
        }
        // Captured for fallback carry: if the on-device brain fails later in
        // this turn, the cloud brain must see what the tool already returned.
        noteFallbackToolResult(name: outcome.name, result: outcome.detail)
        let head = "TOOL \(outcome.name) \u{2192} \(outcome.ok ? "ok" : "error")"
        let detail = outcome.ok ? "" : " \u{2014} \(outcome.detail.prefix(200))"
        pushToolLine(head + detail)
    }

    /// TURN-LEVEL product UI from the loop.
    ///
    /// `.working` is the "instant send feedback" fix: the loop emits it BEFORE
    /// its first provider call, so the panel's status line reads "working…"
    /// during the otherwise-silent first model round. `.ready` is deliberately
    /// a no-op here — the page's own `chatDone`/`chatError`/`chatStopped`
    /// already own the terminal label, and re-pushing `ready` could overwrite
    /// an `error`/`stopped` state with a lie. `.confirmation` is rendered as
    /// the turn's final text (the loop yields it as `.done`), so there is
    /// nothing to push.
    fileprivate func handleTurnUI(_ event: TurnUIEvent) {
        switch event {
        case .working:
            callAPI(
                "turnStatus",
                argumentsJSON: "\"working\", \(jsonString("working… 0.0s"))"
            )
        case .ready, .confirmation:
            break
        case .notice(let line):
            // A between-rounds notice (the jev run-state label) rides the same
            // one-liner sink as every other tool line. It changes nothing about
            // the turn — labeling is never a gate.
            pushToolLine(line)
        }
    }

    /// Pushes the CURRENT plan to the page as ONE block, keyed by
    /// `PlanTrace.blockID`. Re-pushing the same key is what makes a status
    /// change an in-place update: the page rewrites the block it already has
    /// instead of stacking another one under it, so watching a plan run does
    /// not scroll the conversation.
    fileprivate func pushPlanBlock() {
        callAPI(
            "planUpdate",
            argumentsJSON: jsonArray([[
                "id": PlanTrace.blockID,
                "lines": PlanTraceStore.shared.renderedLines.joined(separator: "\n")
            ]])
        )
    }

    /// One transcript line for something the browser did. The existing
    /// tool-line rendering, so a browser action is styled and scrolled exactly
    /// like a tool outcome.
    fileprivate func pushToolLine(_ line: String) {
        // THE USER DECIDED NOT TO SEE THESE. The transcript showed its own
        // plumbing — `web: google.com/search — 278 chars` and
        // `TOOL web_lookup → ok` — which is debugging, not an answer. Those
        // prefixes are now DIAGNOSTIC ONLY: they still print to stdout (and the
        // web marker also lands in `ACTION_LOG`), so every one of them remains
        // available off-screen; they just no longer reach the transcript.
        //
        // Filtered HERE, at the single sink both line kinds share, rather than
        // in the page: Swift is the authority on what the user is shown, and a
        // page-side filter could be undone by any other render path. Nothing
        // else about the round trip changes — the tools still run, the web path's
        // state machine, excerpting and provenance are untouched, and every
        // OTHER tool line (brain notices, browser actions) still renders.
        if Self.isDebugOnlyLine(line) {
            ProviderTestSeams.shared.noteSuppressedLine(line)
            print("TRANSCRIPT_DEBUG_LINE \(line)")
            fflush(stdout)
            return
        }
        ProviderTestSeams.shared.noteRenderedLine(line)
        callAPI("toolActivity", argumentsJSON: jsonString(line))
    }

    /// `web:` web markers, `TOOL <name> → …` tool outcomes, and the PROVIDER
    /// PLUMBING notices (which brain answered / fell back): all visible in the
    /// debug log, hidden from the transcript. Matching is on the leading prefix
    /// so an ANSWER that merely mentions any of these words is never suppressed.
    static func isDebugOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "web:",
            "TOOL ",
            // Provider-decision plumbing: the user never sees which brain
            // answered or that a fallback happened. It stays in the stdout log
            // (`BRAIN_NOTICE`) and the privacy pill, never in the transcript.
            "On-device did not answer",
            "On-device unavailable",
            "On-device needs macOS"
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    /// ONE visible-notice sink shared by every cloud promotion. The notice is
    /// logged to stdout (`BRAIN_NOTICE`) and the privacy pill moves to "Cloud"
    /// (which brain is answering is a privacy fact worth surfacing). Whether the
    /// text ALSO reaches the transcript is decided by `isDebugOnlyLine`: the M9
    /// availability/fallback plumbing lines are suppressed (they are noise), while
    /// the ROUTING promotion notice intentionally RENDERS — a turn promoted to
    /// the cloud for tools must be visible in the same turn, never a silent
    /// cloud promotion.
    fileprivate func pushBrainNotice(_ line: String) {
        print("BRAIN_NOTICE \(line)")
        fflush(stdout)
        pushToolLine(line)
        callAPI("providerStatus", argumentsJSON: jsonDictionary([
            "label": "Cloud",
            "cloud": "true"
        ]))
    }

    /// The ONE visible notice for a configured-but-unreachable jev. Maps the
    /// bridge's already-sanitized reason to plain language and reuses the
    /// tool-line sink; the text carries no token material (only the reason) and
    /// matches no `isDebugOnlyLine` prefix, so it RENDERS in the transcript.
    fileprivate func noteJevDegraded(reason: String) {
        let detail = reason == "missing-token"
            ? "no token configured"
            : (reason.isEmpty ? "unreachable" : reason)
        pushToolLine(
            "jev advisory is on but unreachable (\(detail)) — routing, card labels, "
                + "and run labels are off this session."
        )
    }

    // MARK: - Voice input (microphone)

    /// The ONE place listening is flipped. Reached by the bridge's
    /// `voiceToggle` (the composer mic and the dialog's mic) AND by the hover
    /// toolbar's `.popMicToggle` notification, so both surfaces share the exact
    /// same path — including the diagnostic prints.
    fileprivate func toggleVoice() {
        // VOICE_ prints are diagnostic: `open`-launched apps hide stdout, so
        // the mic path is traced to a `--stdout` file.
        print("VOICE_TOGGLE received")
        fflush(stdout)
        // STARTING (not stopping): the voice dialog (`#voiceDlg`) lives in the
        // web view, which is HIDDEN in `mascot`. Raise the composer so the bubble
        // has a visible surface. `.popSummonBar` is the panel's own summon path
        // (the same one the robot click uses) and is IDEMPOTENT — `summonBar()`
        // no-ops unless the panel is resting in `mascot`, so it is a no-op in
        // `bar`/`full` where the web view is already up. Reached without a
        // direct `PanelController` reference, matching the existing pattern.
        let starting = !speechListener.isListening
        if starting {
            // ENTRY POINT SIZES ITS OWN SURFACE: a listen ALWAYS shows only the
            // transcript bubble, sized to the dialog — never the prior session's
            // height. `voiceOnly(true)` hides the composer/transcript AND resets
            // the transcript to blank (a fresh listen starts clean).
            voiceOnlyActive = true
            callAPI("voiceOnly", argumentsJSON: "true")
            // Switch to the voice-only surface from ANY state (mascot/bar/full):
            // reveal the web view and go to `bar` NON-animated, so the dialog-
            // sized shrink that follows is not overridden by a window animation.
            NotificationCenter.default.post(
                name: Notification.Name("popPanelVoiceSurface"),
                object: nil
            )
        }
        speechListener.toggle()
        print("VOICE_TOGGLE toggled")
        fflush(stdout)
    }

    /// Live words from the mic, written into the VOICE DIALOG so the user sees
    /// them as they speak. Escaped by `jsonString`.
    fileprivate func pushVoicePartial(_ text: String) {
        callAPI("voicePartial", argumentsJSON: jsonString(text))
    }

    /// The finished utterance, handed to the page's DIALOG (via `voiceFinal`).
    /// The page never sends it: the user presses Send, and only then does it
    /// enter the pipeline, tagged `source: "voice"`. Barge-in: talking to Pop
    /// also silences any reply still being read aloud.
    fileprivate func finishVoiceInput(_ text: String) {
        speech.stop()
        callAPI("voiceFinal", argumentsJSON: jsonString(text))
    }

    /// A recognition failure or the 55s cap. Surface the copy and settle back to
    /// rest; never an alert.
    fileprivate func failVoiceInput(_ message: String) {
        pushVoiceNotice(message)
        announceMascot("idle")
    }

    /// A non-fatal voice notice, through the same transcript-notice mechanism as
    /// the other one-liners (and the stdout log, for probes).
    fileprivate func pushVoiceNotice(_ message: String) {
        print("VOICE_NOTICE \(message)")
        fflush(stdout)
        pushToolLine(message)
    }

    /// The one state push the mic button and the mascot face both read: page
    /// event `voiceState` toggles the button, and the mascot enters `listening`.
    /// Starting also silences any in-flight spoken reply (barge-in), enforcing
    /// the invariant "Pop never outputs speech while its mic is open".
    ///
    /// RULE: the mic only BORROWS the face while no turn is live. With a live
    /// turn the face stays on the turn's phase, and closing the mic re-announces
    /// that phase (the turn machinery owns the mascot during a turn), so
    /// listening can never outlive the mic and never stomps "thinking".
    fileprivate func pushVoiceState(_ active: Bool) {
        callAPI("voiceState", argumentsJSON: active ? "true" : "false")
        if active {
            speech.stop()
            if streamTask == nil { announceMascot("listening") }
        } else if streamTask != nil {
            // Restore the turn's CURRENT phase — the same thinking/speaking the
            // turn announces; `lastMascotState` tracks it and is never set to
            // "listening" mid-turn under the rule above.
            announceMascot(lastMascotState == "listening" ? "thinking" : lastMascotState)
        } else {
            announceMascot("idle")
        }
    }

    /// Swift -> page: the browser pane's chrome state. The page needs this to
    /// decide whether to reserve the pane's band and collapse the transcript.
    fileprivate func pushBrowserState(_ state: BrowserState) {
        var json: [String: Any] = [
            "active": state.active,
            "url": state.url,
            "title": state.title,
            "status": state.status
        ]
        // THE BAND, FROM THE SIDE THAT PAINTS IT. The browser pane is a native
        // view over the top of the web view, so the page cannot measure it and
        // used to GUESS (a hardcoded 300px whenever `active`). Guessing is how
        // the two drifted: `full` painted the pane with `active` false, and the
        // page reserved nothing. Swift owns this number; the page only obeys it.
        // Zero in any state but `full`, because in `bar` the web region is 64pt
        // and a reserved band would push the composer out of the window.
        json["panePx"] = (panelState == PanelState.full.rawValue && state.active)
            ? BrowserController.paneHeight
            : 0
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else { return }
        callAPI("browserState", argumentsJSON: text)
    }

    /// Swift -> page: a mutating tool is waiting on a click. `json` already
    /// carries `{id, tool, preview, risk, arguments}`.
    fileprivate func pushApprovalCard(_ json: String) {
        callAPI("approvalCard", argumentsJSON: json)
    }

    /// Page -> Swift: the user answered a card. This is the ONLY writer of
    /// `ApprovalGate`, so a verdict cannot be forged from any other path.
    func submitApprovalVerdict(id: String, decision: String, arguments: Any?) {
        // Absent stays absent: "run" sends no arguments at all, and turning that
        // into an empty object would run the tool with nothing.
        var parsed: JSONValue?
        if let data = arguments.flatMap({ value -> Data? in
            guard JSONSerialization.isValidJSONObject(value) else { return nil }
            return try? JSONSerialization.data(withJSONObject: value)
        }) ?? arguments.flatMap({ ($0 as? String)?.data(using: .utf8) }),
           let value = try? JSONValue.decode(data) {
            parsed = value
        }
        let accepted = ApprovalGate.shared.submit(id: id, decision: decision, arguments: parsed)
        guard accepted else {
            // A double-tap or a stale card must not read as an approval.
            print("APPROVAL_STALE id=\(id) decision=\(decision)")
            fflush(stdout)
            return
        }
    }

    /// `TOOL <name> -> approved | denied | edited | timed out`, rendered next to
    /// the card it resolves. Driven by the GATE, not by the page message, so a
    /// timeout — which has no page message — still leaves the transcript closed.
    fileprivate func pushApprovalOutcome(tool: String, marker: String) {
        let line = "TOOL \(tool) \u{2192} \(marker)"
        // Through the SAME sink as every other tool line, so the "no `TOOL `
        // lines in the transcript" decision cannot be bypassed by this one path.
        // Safe to hide: the page closes the card when the verdict is SENT (see
        // `resolveApproval`), not when this line arrives — the line was only ever
        // the receipt. `approvalObserver` still fires, so the approval probes
        // keep asserting it.
        pushToolLine(line)
        approvalObserver?(line)
    }

    /// Deterministic 8-char digest of the FIXED prompt head (instructions plus
    /// tool schemas). FNV-1a rather than `Hasher`: `Hasher` is seeded per
    /// process, so it would report a different prefix on every launch and turn
    /// this marker into noise.
    static func stablePrefixHash(
        system: String = AppleFMProvider.systemPrompt,
        tools: [ToolSchema] = ToolRegistry.schemas()
    ) -> String {
        let head = ([system] + tools.map { schema in
            "\(schema.name)|\(schema.description)|\(schema.parameters.stableString())"
        }).joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in head.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", hash & 0xffff_ffff)
    }

    fileprivate func handleDelta(_ piece: String) {
        deltaCount += 1
        // A token just arrived: this is what the timeout policy measures, so the
        // idle clock restarts here. A turn with intermittent tokens never times
        // out, however long it runs in total.
        lastTokenAt = streamNow()
        // First token proves the model is alive; the watchdog has done its job.
        cancelStreamWatchdog()
        callAPI("chatDelta", argumentsJSON: jsonString(piece))
    }

    /// Called before the remote fallback answers, after the on-device brain
    /// produced a non-answer. Whatever it already streamed is discarded so the
    /// user's own words are never left standing as the answer.
    fileprivate func resetLiveTurnForFallback() {
        deltaCount = 0
        callAPI("chatReset", argumentsJSON: "")
    }

    /// How long with NO token before the log says so. Calibration only.
    static let streamWarnSeconds = 60

    /// The hard cap is IDLE-TIME, not turn time: after this many seconds with no
    /// token at all the stream is declared wedged and aborted. A turn that keeps
    /// emitting tokens runs as long as it needs — the old 45s TOTAL cap killed
    /// healthy multi-round on-device turns whose ~10k tool payloads leave long
    /// token gaps. Probes override via `POP_STREAM_TIMEOUT_SECS`.
    nonisolated static func streamIdleCapSeconds() -> Int {
        if let raw = ProcessInfo.processInfo.environment["POP_STREAM_TIMEOUT_SECS"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 180
    }

    /// The clock the stream policy reads. `Date()` in production; a probe swaps
    /// in a fast-forwarding clock so 60s/180s of idle can be measured without a
    /// real 60s sleep.
    private func streamNow() -> Date { ProviderTestSeams.shared.streamClock() }

    /// Diagnostic-only watchdog: if NO token has arrived 60s after the stream
    /// opened, say so ONCE.
    ///
    /// It deliberately does NOT cancel. A cold on-device model can legitimately
    /// take a minute to produce its first token, and the user's complaint was
    /// silence, not failure — killing the stream would turn a slow answer into
    /// no answer at all. This only tells the log (and a human) why the UI looks
    /// idle.
    private func startStreamWatchdog() {
        cancelStreamWatchdog()
        streamWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self, self.streamTask != nil else { return }
                if self.deltaCount > 0 { return }
                let idle = self.streamNow().timeIntervalSince(self.lastTokenAt)
                if idle >= Double(Self.streamWarnSeconds) {
                    print("STREAM_STALL waiting=\(Self.streamWarnSeconds)s")
                    fflush(stdout)
                    return
                }
            }
        }
    }

    private func cancelStreamWatchdog() {
        streamWatchdog?.cancel()
        streamWatchdog = nil
    }

    /// ENFORCEMENT, where the watchdog above is only diagnosis: after
    /// `streamIdleCapSeconds()` with NO token the stream is aborted.
    ///
    /// The live log showed a stream that started and then produced no token, no
    /// completion and no error — and because `streamTask` stayed non-nil, every
    /// later send was rejected as "busy" behind a wedge. Bounding the IDLE makes
    /// the failure self-healing: the task is cancelled, `fail()` runs the normal
    /// error path (so the person sees why), and the next send works.
    private func startStreamTimeout() {
        cancelStreamTimeout()
        let cap = Self.streamIdleCapSeconds()
        streamTimeout = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self, self.streamTask != nil else { return }
                let idle = self.streamNow().timeIntervalSince(self.lastTokenAt)
                if idle >= Double(cap) {
                    print("STREAM_TIMEOUT idle=\(Int(idle))s cap=\(cap)s")
                    fflush(stdout)
                    self.streamTask?.cancel()
                    self.streamTask = nil
                    self.cancelStreamWatchdog()
                    self.fail(TimeoutError())
                    return
                }
            }
        }
    }

    private func cancelStreamTimeout() {
        streamTimeout?.cancel()
        streamTimeout = nil
    }

    /// A named error beats a bare string. `fail()` renders its
    /// `localizedDescription`; a raw `TimeoutError()` debug string must never
    /// reach the transcript.
    private struct TimeoutError: LocalizedError {
        var errorDescription: String? {
            "the on-device brain ran out of time on this turn \u{2014} please try again"
        }
    }

    fileprivate func finish(full: String, source: SendSource) {
        streamTask = nil
        cancelStreamWatchdog()
        cancelStreamTimeout()
        var text = full.trimmingCharacters(in: .whitespacesAndNewlines)
        // THE ASK, COMPOSED BY POP. When this turn's `web_lookup` reported a
        // CALLER-DECLARED slot the query never supplied, the model must not
        // author the parameter question — it paraphrased the tool's list and
        // invented an extra city into it (measured). Pop renders the ask itself,
        // from the declared slot names verbatim (page candidates only as
        // suggestions), and that deterministic text is what the user sees:
        // `chatDone` overwrites the streamed block, and this same text is what is
        // recorded to the session. PRECISION: the generic page-entity detector is
        // deliberately NOT consulted, so a scraped `HNMS`/`Afternoon` cannot
        // trigger a question.
        let missingSlots = ProviderTestSeams.shared.lastMissingSlots
        // `askText` refuses to render without a named slot (returns nil), so the
        // ask can never reach the user with an empty slot name.
        if let composedAsk = WebLookupResult.askText(
            for: missingSlots,
            candidates: ProviderTestSeams.shared.lastSlotCandidates
        ) {
            ProviderTestSeams.shared.lastModelTextBeforeAsk = text
            text = composedAsk
            ProviderTestSeams.shared.lastAskFired = true
        } else {
            ProviderTestSeams.shared.lastAskFired = false
        }
        lastAnswerFull = text
        if !text.isEmpty {
            transcript.append(role: .assistant, text: text)
            recordTurn(role: .assistant, text: text)
        }
        TurnMetrics.shared.reportTurnEnded()
        callAPI("chatDone", argumentsJSON: jsonString(text))

        // VOICE: a VOICE-originated turn HOLDS "speaking" for as long as the
        // reply is read aloud, then resumes the normal settle from the
        // utterance's completion. This guarded section is the ONLY difference:
        // skipped for a typed turn or an empty answer, the flow below is
        // exactly the pre-voice behaviour.
        //
        // INVARIANT: replies are spoken exactly when the turn was
        // voice-initiated (`source == .voice`); typed replies are always
        // silent. And Pop never outputs speech while its mic is open — enforced
        // at BOTH ends, here (the trigger) and at mic start (`pushVoiceState`),
        // so a missed guard in either site alone cannot produce self-hearing.
        if source == .voice && !text.isEmpty && !speechListener.isListening {
            announceMascot("speaking")
            speech.speak(text) { [weak self] in
                self?.settleAfterTurn()
            }
            return
        }

        settleAfterTurn()
    }

    /// The shared end-of-turn mascot flow: a happy beat, then idle. Reached
    /// directly when there is no voice, or from the speech completion when the
    /// reply is being read — so both paths settle identically.
    private func settleAfterTurn() {
        announceMascot("happy")

        mascotHappyReset?.cancel()
        mascotHappyReset = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.announceMascot("idle")
        }
    }

    fileprivate func fail(_ error: Error) {
        streamTask = nil
        cancelStreamWatchdog()
        cancelStreamTimeout()
        // The LOG may keep the raw error (it is diagnostic); the TRANSCRIPT must
        // never. A raw Swift debug string (`TimeoutError()`) is what the user saw
        // and is not a sentence.
        print("CHAT_ERROR raw=\(String(describing: error))")
        fflush(stdout)
        // A turn that failed still waited: its latency is the complaint.
        TurnMetrics.shared.reportTurnEnded()
        pushChatError(Self.humanErrorText(error))
        announceMascot("idle")
    }

    /// The ONE sink for an error the user can see. Every error route funnels
    /// here so no path can push a raw debug string into the transcript.
    fileprivate func pushChatError(_ text: String) {
        let safe = Self.sanitizeErrorText(text)
        lastErrorText = safe
        errorObserver?(safe)
        callAPI("chatError", argumentsJSON: jsonString(safe))
    }

    /// A human sentence for `error`, by construction free of Swift's raw
    /// `XxxError()` debug shape.
    nonisolated static func humanErrorText(_ error: Error) -> String {
        if let timeout = error as? TimeoutError, let line = timeout.errorDescription {
            return line
        }
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.isEmpty, !looksLikeRawErrorDebug(localized) {
            return localized
        }
        let described = error.localizedDescription
        if !described.isEmpty,
           !looksLikeRawErrorDebug(described),
           !isUninformativeLocalized(described) {
            return described
        }
        return "the on-device brain ran into a problem on this turn \u{2014} please try again"
    }

    /// A raw Swift error debug string: `TimeoutError()`, `ProviderError()`, …
    nonisolated static func looksLikeRawErrorDebug(_ text: String) -> Bool {
        text.range(of: "^\\w+Error\\(", options: .regularExpression) != nil
    }

    /// Foundation/Cocoa's placeholder for an error with no usable description.
    nonisolated static func isUninformativeLocalized(_ text: String) -> Bool {
        text.contains("couldn\u{2019}t be completed")
            || text.contains("couldn't be completed")
            || text.contains("The operation")
    }

    /// Assert-by-construction: strips any residual raw debug shape from a string
    /// before it can reach the transcript.
    nonisolated static func sanitizeErrorText(_ text: String) -> String {
        if looksLikeRawErrorDebug(text) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "the on-device brain ran into a problem on this turn \u{2014} please try again"
        }
        return text
    }

    fileprivate func announceMascot(_ state: String) {
        lastMascotState = state
        NotificationCenter.default.post(name: .popMascotState, object: state)
    }

    /// Bridge entry point: every UI→Swift message lands here.
    func handleBridgeMessage(type: String, body: [String: Any]) {
        switch type {
        case "chatSend":
            let source: SendSource = (body["source"] as? String) == "voice" ? .voice : .text
            handleChatSend(text: body["text"] as? String ?? "", source: source)
        case "chatStop":
            stop()
        case "voiceToggle":
            // The mic button's only job: flip listening. All state flows back
            // out through `onListeningChanged` → `pushVoiceState`.
            toggleVoice()
        case "voiceClosed":
            // The voice surface dismissed (×, or an empty stop): restore the
            // page, and if WE owned the voice-only surface, collapse to mascot.
            callAPI("voiceOnly", argumentsJSON: "false")
            if voiceOnlyActive {
                voiceOnlyActive = false
                NotificationCenter.default.post(name: Notification.Name("popPanelHeightRequest"), object: "mascot")
            }
        case "voiceSent":
            // A VOICE TURN NEVER SURFACES THE COMPOSER. Restore the page, then
            // collapse to the mascot — the same request path `voiceClosed` uses.
            // The turn runs on in the hidden web view (the mascot shows thinking
            // → speaking → happy → idle), and the user reads the exchange later
            // by clicking the robot.
            callAPI("voiceOnly", argumentsJSON: "false")
            voiceOnlyActive = false
            NotificationCenter.default.post(name: Notification.Name("popPanelHeightRequest"), object: "mascot")
        case "stopRequested":
            // "The person pressed stop", not "tear this down". Kept apart from
            // `chatStop` so the page can show a `stopped by you` receipt instead
            // of an empty assistant block.
            stopByUser()
        case "uiReady":
            markPageReady()
            // The page needs the CURRENT state, not just the queued calls: bar
            // state hides the chat, so a page that loaded while the launcher was
            // resting would otherwise flash the transcript.
            pushPanelState(panelState)
            // NO archive push here, deliberately. The transcript archive renders
            // old turns into the messages area at launch, which both makes chat
            // visible by default and pushes `uiHeight: full`. The user's
            // requirement is absolute: by default the panel shows the launcher
            // (robot + composer) and nothing else. The archive stays on disk.
            // The session LIST is safe to push, though: it only fills the `+`
            // menu, and that menu is closed until the user opens it.
            pushSessionList()
        case "configChanged":
            // Reserved: settings writes config directly in M2, so the UI only
            // needs to re-pull history once the model changes.
            handleHistoryRequest()
        case "newChat":
            newChat()
        case "openSession":
            // A row in the `+` menu's Conversations section.
            if let id = body["id"] as? String {
                openSession(id)
            }
        case "uiHeight":
            // The page asks; Swift decides and animates.
            NotificationCenter.default.post(
                name: Notification.Name("popPanelHeightRequest"),
                object: body["state"] as? String
            )
        case "uiContentHeight":
            // The page's MEASURED pixel height for the status line + composer.
            // Swift still decides (only `bar` is adaptive); this is a number,
            // not a state name.
            NotificationCenter.default.post(
                name: Notification.Name("popPanelContentHeight"),
                object: (body["height"] as? NSNumber) ?? NSNumber(value: 0)
            )
        case "barDragBegin":
            // The composer's inert background started a drag. The web view
            // swallows the mouse-down AppKit needs, so `PanelController` tracks
            // the cursor with local monitors instead.
            NotificationCenter.default.post(name: Notification.Name("popBarDragBegin"), object: nil)
        case "transcriptVisibility":
            // The page reporting on its own display invariant after a finished
            // turn. Printed, not acted on: the fix lives in the page, and this is
            // the only way a page-side invariant becomes visible in the log.
            print("TRANSCRIPT_VISIBILITY=\(body["state"] as? String ?? "unknown")")
            fflush(stdout)
        case "contextToggle":
            toggleContextKey(body["key"] as? String ?? "", on: body["on"] as? Bool ?? true)
        case "contextRemove":
            if let key = body["key"] as? String { excludeContextKey(key) }
        case "approvalVerdict":
            submitApprovalVerdict(
                id: body["id"] as? String ?? "",
                decision: body["decision"] as? String ?? "deny",
                arguments: body["arguments"]
            )
        default:
            break
        }
    }

    /// The first summon after launch happens before the page finishes loading, so
    /// `window.popAPI` is still undefined and every push is silently dropped. Queue
    /// those calls (capped, oldest dropped) and replay them once the page says hello.
    private static let pendingCallLimit = 16

    private var pageReady = false
    private var pendingCalls: [(name: String, json: String)] = []

    /// Last panel state Swift pushed to the page. Tracked so `uiReady` can hand
    /// the page the state it missed while the DOM was still loading.
    private var panelState: String = "bar"

    /// Bar state means LAUNCHER ONLY: robot plus composer, no chat. The page
    /// keys its visibility off this, because the transcript container is never
    /// empty (the archived history lands in it at `uiReady`), so a CSS
    /// `:empty` check alone cannot suppress the chat backdrop.
    func pushPanelState(_ state: String) {
        panelState = state
        callAPI("panelState", argumentsJSON: jsonString(state))
        // The browser band is only reserved in `full`, so a state change has to
        // re-publish it. Without this the page would keep a band sized for the
        // previous panel state.
        BrowserController.shared.republishState()
    }

    /// Marks the page loadable and replays everything queued before it existed.
    fileprivate func markPageReady() {
        pageReady = true
        // A browser tool may well have navigated before the chat page finished
        // loading; without this the pane would open with no chrome at all.
        BrowserController.shared.republishState()
        let queued = pendingCalls
        pendingCalls.removeAll()
        for call in queued {
            webViewProvider()?.evaluateJavaScript(
                "window.popAPI && window.popAPI.\(call.name)(\(call.json));"
            )
        }
    }

    fileprivate func callAPI(_ name: String, argumentsJSON: String) {
        guard pageReady else {
            pendingCalls.append((name: name, json: argumentsJSON))
            if pendingCalls.count > Self.pendingCallLimit {
                pendingCalls.removeFirst(pendingCalls.count - Self.pendingCallLimit)
            }
            return
        }
        let js = "window.popAPI && window.popAPI.\(name)(\(argumentsJSON));"
        // DIAGNOSTIC: only the voice channel, so a silent bubble can be traced to
        // (or cleared of) the JS-delivery stage.
        if name.hasPrefix("voice") {
            print("VOICE_API=\(name) bytes=\(argumentsJSON.count)")
            fflush(stdout)
        }
        webViewProvider()?.evaluateJavaScript(js)
    }

    /// Resolve THIS turn's jev route choice, ONCE, before the provider is chosen.
    /// `nil` when jev is disabled/unavailable/below-floor — the pre-existing
    /// behavior, byte-identical. A probe may force the choice
    /// (`ProviderTestSeams.forcedRouteChoice`); otherwise the real advisory runs.
    /// Nonisolated on purpose: it is awaited on the turn task, NOT the MainActor,
    /// so the bounded Keychain + HTTP advisory can never block the UI.
    nonisolated static func turnRouteChoice(
        config: PopConfig,
        messages: [ChatMessage]
    ) async -> String? {
        if let forced = ProviderTestSeams.shared.forcedRouteChoice {
            print("JEV_ROUTE skipped=probe-forced"
                + " choice=\(forced.value.map(JevBridge.sanitize) ?? "-")")
            fflush(stdout)
            return forced.value
        }
        let goal = AgentLoop.turnGoal(from: messages)
        guard let route = await AgentLoop.routeChoice(
            enabled: config.jevEnabled,
            goal: goal,
            threshold: config.jevThreshold
        ) else {
            return nil
        }
        // T3 PREMISE GATE: when routing resolves a class, the premise noul runs
        // FIRST. A route is usable only when the request's premise is true and
        // actionable; a measured `false` skips the route this turn (no hat, no
        // playbook, no promotion — existing behavior). Fail-open: an unmeasurable
        // premise (`nil`) is assumed true, so the route stands exactly as before.
        if await JevBridge.premiseCheck(goal: goal) == false {
            print("JEV_PREMISE_ROUTE_SKIPPED route=\(JevBridge.sanitize(route))")
            fflush(stdout)
            return nil
        }
        return route
    }

    /// THE BRAIN DECISION, in one place so the app and the probes cannot drift.
    ///
    /// User decision (2026-10-07): **on-device first**; the configured
    /// OpenAI-compatible provider is the FALLBACK, used when the on-device model
    /// is unavailable OR its call throws. `openai-compat` in the config keeps
    /// the pre-M9 behaviour exactly — that provider is primary, with no
    /// on-device attempt.
    ///
    /// `route` is THIS turn's jev capability class (`nil` = disabled/unavailable/
    /// below-floor). It exists so a route that NAMES a hands-on class can be
    /// served by a brain that HAS those tools — see the promotion below.
    ///
    /// `nonisolated`: the warmup and the key-status probe build providers from a
    /// background/headless context, and this touches no instance state or UI.
    nonisolated static func resolveProvider(_ config: PopConfig, route: String? = nil) -> ProviderChoice {
        // PROBE SEAM: a scripted provider wins when a probe injected one, so the
        // timeout/fallback/friendly-error paths can be driven deterministically
        // through the real `handleChatSend`. Production never sets this.
        let probeSeams = ProviderTestSeams.shared
        if let override = probeSeams.primaryProviderOverride {
            let fallback = probeSeams.fallbackProviderOverride
            return ProviderChoice(
                primary: override,
                fallbackFactory: fallback.map { provider in
                    { @Sendable () -> ModelProvider in provider }
                },
                decision: "probe",
                reason: "",
                notice: nil
            )
        }
        // Explicit remote choice: unchanged from before M9.
        if config.provider == "openai-compat" {
            print("PROVIDER_DECISION=remote reason=configured openai-compat")
            fflush(stdout)
            return ProviderChoice(
                primary: OpenAICompatProvider.fromConfig(config),
                fallbackFactory: nil,
                decision: "remote",
                reason: "",
                notice: nil
            )
        }

        // On-device first.
        guard #available(macOS 26.0, *) else {
            let reason = "on-device requires macOS 26"
            print("PROVIDER_DECISION=remote reason=\(reason)")
            fflush(stdout)
            return ProviderChoice(
                primary: OpenAICompatProvider.fromConfig(config),
                fallbackFactory: nil,
                decision: "remote",
                reason: reason,
                notice: "On-device needs macOS 26 \u{2014} using the cloud brain"
            )
        }

        let seams = ProviderTestSeams.shared
        let onDevice = AppleFMProvider(
            pcc: config.pcc,
            availabilityOverride: seams.availability,
            toolsEnabled: true,
            readOnlyOnly: true
        )
        // LAZY: never built unless the on-device brain is unavailable or throws,
        // so a healthy on-device turn never touches the Keychain.
        let fallback: (@Sendable () -> ModelProvider)?
        if seams.fallbackEnabled {
            fallback = { OpenAICompatProvider.remoteFallback(config) }
        } else {
            fallback = nil
        }

        // ROUTE-AWARE PROMOTION. WHY: the on-device brain is wired TOOL-LESS for
        // mutating capabilities — every such tool is refused with
        // `FM_TOOL_SKIP ... not-on-device-eligible`. A route that NAMES a hands-on
        // class (`JevRoute.handsOnClasses`: computer-use / browser) therefore
        // cannot be served by it: the model has no tool to act with and
        // improvises. MEASURED: a real "summarize MY LinkedIn notifications in
        // Brave" turn, routed to browser, was served by the on-device brain with
        // all mutating tools hidden and fabricated user-specific content via
        // web_lookup. INVARIANT: a turn is served by a brain that HAS the tools
        // its routed capability needs — so promote the turn to the REMOTE brain
        // and its full tool loop before it starts. Only when the remote is
        // actually usable AND fallback is enabled (the SAME seam the M9 fallback
        // honors); otherwise stay on-device and let the existing "no API key"
        // path own genuine remote failures.
        let routeNeedsTools = route.map { JevRoute.handsOnClasses.contains($0) } ?? false
        if routeNeedsTools, onDevice.isHealthy, seams.fallbackEnabled {
            // A probe-injected remote (the SAME provider the M9 fallback uses) is
            // honoured so this path can be measured without real credentials.
            let remote: ModelProvider?
            if let injected = seams.fallbackProviderOverride {
                remote = injected
            } else {
                let configured = OpenAICompatProvider.remoteFallback(config)
                remote = configured.isHealthy ? configured : nil
            }
            if let remote {
                print("PROVIDER_FALLBACK reason=routing-needs-tools"
                    + " route=\(JevBridge.sanitize(route ?? ""))")
                fflush(stdout)
                return ProviderChoice(
                    primary: remote,
                    fallbackFactory: nil,
                    decision: "remote-routing",
                    reason: "routing-needs-tools",
                    notice: "This task needs to act on screen \u{2014} "
                        + "using the cloud brain for its tools"
                )
            }
            print("PROVIDER_FALLBACK skipped=no-remote"
                + " route=\(JevBridge.sanitize(route ?? ""))")
            fflush(stdout)
        }

        if onDevice.isHealthy {
            print("PROVIDER_DECISION=on-device reason=available")
            fflush(stdout)
            return ProviderChoice(
                primary: onDevice,
                fallbackFactory: fallback,
                decision: "on-device",
                reason: "",
                notice: nil
            )
        }

        let reason = onDevice.unhealthyReason
        if let fallback {
            print("PROVIDER_DECISION=remote-fallback reason=\(reason)")
            fflush(stdout)
            return ProviderChoice(
                primary: onDevice,
                fallbackFactory: fallback,
                decision: "remote-fallback",
                reason: reason,
                notice: "On-device unavailable \u{2014} using the cloud brain (\(reason))"
            )
        }
        print("PROVIDER_DECISION=on-device-unavailable reason=\(reason)")
        fflush(stdout)
        return ProviderChoice(
            primary: onDevice,
            fallbackFactory: nil,
            decision: "on-device-unavailable",
            reason: reason,
            notice: reason
        )
    }

    /// Provider selection for a ONE-SHOT caller (warmup, key-status probe):
    /// the primary brain only. `handleChatSend` calls `resolveProvider` directly
    /// so it also gets the fallback.
    nonisolated static func makeProvider(_ config: PopConfig) -> ModelProvider {
        resolveProvider(config).primary
    }

    /// A one-line description of the decision, WITHOUT constructing the remote
    /// provider: used for the startup marker so a fresh launch never reads the
    /// Keychain just to report what it would do.
    nonisolated static func providerDecisionSummary(_ config: PopConfig) -> String {
        if config.provider == "openai-compat" {
            return "remote reason=configured openai-compat"
        }
        guard #available(macOS 26.0, *) else {
            return "remote reason=on-device requires macOS 26"
        }
        let onDevice = AppleFMProvider(
            pcc: config.pcc,
            availabilityOverride: ProviderTestSeams.shared.availability,
            toolsEnabled: false
        )
        if onDevice.isHealthy { return "on-device reason=available" }
        return "remote-fallback reason=\(onDevice.unhealthyReason)"
    }

    /// Normalises text for ECHO comparison: case-folded, whitespace-collapsed,
    /// with one leading role label and surrounding quotes stripped. Deliberately
    /// conservative — it only equates strings that ARE the same words.
    nonisolated static func normalizedForEcho(_ text: String) -> String {
        var t = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["user:", "assistant:", "pop:"] where t.hasPrefix(label) {
            t = String(t.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}"))
    }

    /// True when `reply` is a VERBATIM copy of `prompt` — the exact defect the
    /// user reported. Equality on normalised text, so punctuation/case/leading
    /// role label do not hide an echo, but a paraphrase does not count.
    nonisolated static func isEcho(_ reply: String, of prompt: String) -> Bool {
        let r = normalizedForEcho(reply)
        let p = normalizedForEcho(prompt)
        return !r.isEmpty && !p.isEmpty && r == p
    }

    /// A SHORT, explicit statement that the model cannot answer. Bounded to a
    /// short reply so an informational answer that merely contains "I can't"
    /// (e.g. "I can't predict tomorrow, but the forecast is rain") is NOT caught.
    /// This is what routes a weather question — live data the on-device model
    /// cannot have — to the remote brain, per the user's rule.
    nonisolated static func isRefusal(_ reply: String) -> Bool {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, t.count <= 200 else { return false }
        let phrases = [
            "i cannot", "i can't", "i can not", "i am unable", "i'm unable",
            "i am not able", "i'm not able", "i don't have", "i do not have",
            "unable to provide", "cannot provide", "can't provide",
            "cannot help", "can't help", "don't have access",
            "do not have access", "no access to", "as an ai"
        ]
        return phrases.contains { t.contains($0) }
    }

    /// The user's rule for this brain: on-device first, but a NON-ANSWER must be
    /// handed to the remote provider rather than shown. A reply is unusable when
    /// it is empty, a verbatim echo of the user's own words (their question, or
    /// the exact prompt the model was given), or a short explicit refusal. A
    /// short real answer ("4", "yes", "red") is usable: it is not the same words
    /// as the question and it is not a refusal.
    nonisolated static func isUsableReply(
        _ reply: String,
        userText: String,
        providerPrompt: String
    ) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if isEcho(trimmed, of: userText) { return false }
        if isEcho(trimmed, of: providerPrompt) { return false }
        if isRefusal(trimmed) { return false }
        return true
    }

    // MARK: - JSON helpers

    /// One line, the local wall clock at send time, LED with today in words:
    /// `Today is Wednesday, 2026-10-07. Current local time: 21:15:33.`
    /// The weekday and the date come from the SAME fixed-width, en_US_POSIX,
    /// timezone-`.current` formatter and are refreshed on EVERY send — a cached
    /// timestamp would answer a later question wrongly, and leading with "Today
    /// is" is what makes the model APPLY the date instead of reading it.
    static func clockLine(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "EEEE"
        let weekday = f.string(from: date)
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        f.dateFormat = "HH:mm:ss"
        let time = f.string(from: date)
        return "Today is \(weekday), \(day). Current local time: \(time)."
    }

    /// Appends the clock to an already-assembled context block. Appended LAST
    /// so it lands in the volatile tail and never invalidates a stable prefix.
    static func withClock(_ prefix: String) -> String {
        let line = clockLine()
        return prefix.isEmpty ? line : prefix + "\n" + line
    }

    fileprivate func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        guard let array = data,
              let text = String(data: array, encoding: .utf8),
              text.count >= 2
        else {
            return "\"\""
        }
        return String(text.dropFirst().dropLast())
    }

    /// JSON object helper. Values are pre-stringified booleans because the
    /// evaluated JavaScript has no JSON literal for typed values.
    private func jsonDictionary(_ values: [String: String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func jsonArray(_ values: [[String: String]]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}