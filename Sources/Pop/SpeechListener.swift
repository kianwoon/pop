import AVFoundation
// `SFSpeechRecognizer` predates Sendable annotations; its types cross the
// authorization/recognition callbacks we hop back to the main actor.
@preconcurrency import Speech

/// Turns the microphone into text for the composer, entirely on-device when the
/// system can.
///
/// WHY a single long-lived object rather than per-click setup: the audio engine,
/// the recognition task and the permission handshakes all outlive one call, and
/// the stop path must be able to tear every one of them down. One owner keeps
/// the tap, the request and the task in lockstep.
///
/// The surface is turn-shaped and callback-driven: `start`/`stop`/`toggle`, and
/// four callbacks the controller routes into the page and the mascot. No timer
/// drives state — only real recognition events and the two explicit permission
/// answers.
@MainActor
final class SpeechListener: NSObject {
    /// Words as they are recognised, so the composer can show them live.
    var onPartial: ((String) -> Void)?
    /// The finished utterance; the controller hands it to the turn pipeline.
    var onFinal: ((String) -> Void)?
    /// A failure or a limit, as human copy for the user.
    var onError: ((String) -> Void)?
    /// Listening started (`true`) or ended (`false`).
    var onListeningChanged: ((Bool) -> Void)?
    /// A non-fatal notice (permission denied, remote fallback, 55s cap).
    var onNotice: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var capTask: Task<Void, Never>?
    /// Last-resort: if the permission handshake never answers, clear
    /// `isStarting` so the mic cannot wedge dead for the whole session.
    private var handshakeWatchdog: Task<Void, Never>?
    /// One-time remote-fallback warning: the user is told once, not per click.
    private var warnedRemote = false
    /// TRUE while a permission handshake is in flight, before `begin`. It makes
    /// start/toggle re-entrant-safe: a second click cannot launch a second
    /// handshake (and so a second engine that overwrites the first).
    private var isStarting = false
    /// Bumped on every start AND every stop; an in-flight permission callback
    /// whose captured generation no longer matches is ignored, which is how a
    /// stop during the pending phase cancels the handshake.
    private var startGeneration = 0

    private(set) var isListening = false

    func toggle() {
        // VOICE_ prints are diagnostic: `open`-launched apps hide stdout, so the
        // mic path is traced to a `--stdout` file.
        print("VOICE_TOGGLE isListening=\(isListening) isStarting=\(isStarting)")
        fflush(stdout)
        if isListening { stop() } else { start() }
    }

    /// Requests speech then microphone permission IN SEQUENCE, then begins. A
    /// denial is a notice, never an alert: the composer stays usable for typing.
    ///
    /// INVARIANT: tccd aborts unbundled binaries even when they embed usage
    /// strings, so voice requests happen ONLY from a real `.app` bundle carrying
    /// the strings; every other context degrades to a notice.
    func start() {
        guard !isListening, !isStarting else { return }
        // BOTH conditions are required. (1) A REAL bundle: tccd refuses privacy
        // requests from an unbundled binary and aborts the process, so an
        // embedded-but-unbundled plist is not enough — a bare binary's
        // bundleURL is the executable path, whose extension is not "app".
        // (2) The usage strings readable in that bundle. Either failing means
        // capability-unavailable: NEVER request. This one guard covers BOTH
        // request paths below (speech auth and mic auth).
        let info = Bundle.main
        let isBundled = info.bundleURL.pathExtension == "app"
        let hasSpeech = info.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        let hasMic = info.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        print("VOICE_START bundled=\(isBundled) hasSpeech=\(hasSpeech) hasMic=\(hasMic)")
        fflush(stdout)
        guard isBundled, hasSpeech, hasMic else {
            print("VOICE_BLOCKED context")
            fflush(stdout)
            onNotice?("Voice needs the bundled Pop app \u{2014} run Scripts/bundle_app.sh")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            print("VOICE_RECOGNIZER available=false")
            fflush(stdout)
            onNotice?("Speech recognition is unavailable on this Mac.")
            return
        }
        print("VOICE_RECOGNIZER available=\(recognizer.isAvailable)")
        fflush(stdout)
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        armHandshakeWatchdog()
        print("VOICE_REQ_SPEECH sent")
        fflush(stdout)
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor [weak self] in
                guard let self, generation == self.startGeneration else { return }
                print("VOICE_SPEECH_STATUS=\(status.rawValue)")
                fflush(stdout)
                guard status == .authorized else {
                    self.isStarting = false
                    self.cancelHandshakeWatchdog()
                    self.onNotice?("Speech recognition permission is needed for voice input.")
                    return
                }
                // Mic permission is AVAudioApplication (macOS 14.0+, per Apple
                // docs), NOT AVCaptureDevice: AVCaptureDevice is for device
                // access (e.g. the engine's input device), never for permission.
                //
                // INVARIANT: the mic prompt fires on first CAPTURE, not on the
                // permission request — so `undetermined` always proceeds to
                // engine start (begin() opens the input, which is what raises the
                // prompt); only an explicit denial blocks.
                let micPerm = AVAudioApplication.shared.recordPermission
                print("VOICE_MIC_PERM=\(micPerm.rawValue)")
                fflush(stdout)
                switch micPerm {
                case .denied:
                    self.isStarting = false
                    self.cancelHandshakeWatchdog()
                    self.onNotice?("Microphone permission is needed for voice input.")
                    return
                case .granted:
                    self.begin(recognizer)
                    return
                default:
                    // `.undetermined`: request, then proceed REGARDLESS of the
                    // returned value — the real prompt appears when begin()
                    // starts capture.
                    print("VOICE_REQ_MIC sent")
                    fflush(stdout)
                    AVAudioApplication.requestRecordPermission { granted in
                        Task { @MainActor [weak self] in
                            guard let self, generation == self.startGeneration else { return }
                            print("VOICE_MIC_GRANTED=\(granted)")
                            fflush(stdout)
                            self.begin(recognizer)
                        }
                    }
                }
            }
        }
    }

    /// Arms the handshake watchdog; every exit path (begin, denial, stop) cancels
    /// it, and its own `isStarting` guard makes a late fire a no-op.
    private func armHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.isStarting else { return }
            print("VOICE_HANDSHAKE_TIMEOUT")
            fflush(stdout)
            self.isStarting = false
            // Invalidate the in-flight handshake so a late answer is ignored.
            self.startGeneration += 1
            self.onNotice?("Voice input could not start \u{2014} no response from the permission system.")
        }
    }

    private func cancelHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
    }

    /// Stops listening and releases the engine, tap, request and task. Safe to
    /// call when idle, and during the pending permission phase: that phase is
    /// cancelled by invalidating the generation its callbacks captured.
    func stop() {
        if isStarting {
            isStarting = false
            startGeneration += 1
            cancelHandshakeWatchdog()
        }
        guard isListening || engine != nil else { return }
        // Mark stopped FIRST so the task's cancellation error is not reported as
        // a real failure (we caused it).
        isListening = false
        capTask?.cancel()
        capTask = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        // The ONLY isListening true->false transition: restore the speaker state
        // borrowed at begin(). Covers user toggle-off, final/error, the 55s cap,
        // and stopByUser/handleChatSend (all of which funnel through stop()).
        AudioOutputMute.restore()
        print("VOICE_LISTENING=false")
        fflush(stdout)
        onListeningChanged?(false)
    }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        // Committed: the handshake is over, so a stop no longer needs to cancel
        // it — it now tears down the live engine below.
        isStarting = false
        cancelHandshakeWatchdog()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if !warnedRemote {
            warnedRemote = true
            onNotice?("On-device speech is unavailable \u{2014} using Apple speech servers.")
        }
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // DIAGNOSTIC + PITFALL: on macOS `outputFormat(forBus: 0)` can report
        // 0Hz/0ch while the HARDWARE `inputFormat(forBus: 0)` is valid, and a tap
        // installed with the 0Hz format silently delivers NO buffers. Log both
        // and fall back to the hardware format when the output one is unusable.
        var format = input.outputFormat(forBus: 0)
        print("VOICE_INPUT_FORMAT sr=\(format.sampleRate) ch=\(format.channelCount)")
        fflush(stdout)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            let hw = input.inputFormat(forBus: 0)
            print("VOICE_HW_FORMAT sr=\(hw.sampleRate) ch=\(hw.channelCount)")
            fflush(stdout)
            if hw.sampleRate > 0 && hw.channelCount > 0 {
                format = hw
            }
        }
        print("VOICE_TAP_FORMAT sr=\(format.sampleRate) ch=\(format.channelCount)")
        fflush(stdout)
        let counter = TapBufferCounter()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            // Only the audio tap thread touches `counter` — single writer/reader,
            // so the plain Int is safe here (a diagnostic, not shared state).
            counter.count += 1
            if counter.count == 1 || counter.count % 100 == 0 {
                print("VOICE_TAP_BUFFERS=\(counter.count) frames=\(buffer.frameLength)")
                fflush(stdout)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            print("VOICE_ENGINE_ERR=\(error)")
            fflush(stdout)
            // Defensive: `mute()` is only called after a successful start, so
            // this is a no-op, but every listening-end path restores.
            AudioOutputMute.restore()
            // Opening the input is what raises the mic prompt; a failure here is
            // usually the grant being withheld, otherwise it is a real error.
            let ns = error as NSError
            if error.localizedDescription.lowercased().contains("permission")
                || ns.domain == NSOSStatusErrorDomain {
                onNotice?("Microphone access is needed for voice input.")
            } else {
                onError?("Could not start the microphone: \(error.localizedDescription)")
            }
            return
        }
        self.engine = engine
        // The mute is scoped to listening: acquired here (the one place
        // `isListening` becomes true) and restored at the one place it becomes
        // false, so every listening exit restores the pre-listen state.
        AudioOutputMute.mute()
        isListening = true
        print("VOICE_LISTENING=true")
        fflush(stdout)
        onListeningChanged?(true)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error)
            }
        }

        // THE 1-MINUTE LIMIT: a single SFSpeechRecognitionTask is capped by the
        // system at ~60s. Restarting the task would drop the words already
        // spoken, so the SIMPLER CORRECT option is chosen: stop cleanly at 55s
        // with a notice, and let the user tap the mic again.
        capTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(55))
            guard !Task.isCancelled, let self, self.isListening else { return }
            self.onNotice?("Voice input stopped after 55 seconds.")
            self.stop()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        // A cancellation we initiated lands here as an error; ignore it once the
        // listener is no longer live.
        guard isListening else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            print("VOICE_REC_RESULT len=\(text.count) final=\(result.isFinal)")
            fflush(stdout)
            if result.isFinal {
                stop()
                onFinal?(text)
            } else {
                onPartial?(text)
            }
            return
        }
        if let error {
            print("VOICE_REC_ERR=\(error.localizedDescription)")
            fflush(stdout)
            stop()
            onError?("Voice input stopped: \(error.localizedDescription)")
        }
    }
}

/// TEMPORARY DIAGNOSTIC: counts audio-tap buffers. Deliberately a plain,
/// non-isolated Int touched ONLY by the audio tap thread (single writer/reader),
/// so it needs no lock and must NOT be promoted to shared/actor state.
private final class TapBufferCounter {
    var count = 0
}
