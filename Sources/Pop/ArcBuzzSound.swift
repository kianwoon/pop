import AVFoundation

/// The electric-arc buzz that plays while the pointer hovers the robot.
///
/// WHY synthesized, not a bundled asset: the app ships no audio file (only the
/// app icon lives in `Resources/`), and one short loop is not worth a new binary
/// resource plus its loading/format failure modes. The buffer is built ONCE at
/// init into a WAV `Data` — no disc, no bundle, nothing to go missing at runtime.
///
/// Lifecycle is a pure function of hover: `start()` while already playing and
/// `stop()` while already stopped are both no-ops, so the SINGLE hover observer
/// can call them unconditionally and any extra notification of the same state
/// cannot double-play or double-fade.
///
/// INVARIANT: one player, one looping voice. Every edge into "hovering" turns
/// the same voice on and every edge out of it turns the same voice off, so the
/// audio can never desync from `model.isHovered` no matter which code path
/// flipped it.
@MainActor
final class ArcBuzzSound {
    /// One process-wide voice: hover is a global UI fact, not a per-view one.
    static let shared = ArcBuzzSound()

    /// `AVAudioPlayer` over an in-memory WAV: for a single looping buffer this is
    /// strictly fewer moving parts than an `AVAudioEngine` + node graph (no
    /// engine start/stop, no node attach, no render-thread scheduling).
    private var player: AVAudioPlayer?

    /// Our own truth, independent of `player.isPlaying`: it survives the gap
    /// while a stop-fade is still draining, which is exactly the window a rapid
    /// re-entry can land in.
    private var playing = false

    /// Bumped on every start/stop. A pending stop-fade captures this and only
    /// pauses if it is still the current generation — so a start that lands
    /// mid-fade is never silenced by the stale fade's completion.
    private var fadeGeneration = 0

    /// Whether the user has opted into the hover buzz. OFF means `start()` is a
    /// silent no-op — the single choke point every caller inherits, so no caller
    /// needs to know the policy. Refreshed from persisted config at init and by
    /// Settings after a save.
    private(set) var isEnabled = false

    /// Master gain applied on every start, from persisted config, clamped to
    /// 0...1 (`buzzVolume` is a user-facing multiplier over the quiet buffer).
    private var configuredVolume: Double = 1.0

    /// ~100 ms is long enough to remove the click but short enough that leaving
    /// the robot feels instant.
    private static let fadeOutSeconds: TimeInterval = 0.1

    private init() {
        // Build the loop once. A failed player (nil) degrades to silence, never
        // a crash: audio is feedback, not load-bearing.
        guard let data = Self.makeWAV() else { return }
        player = try? AVAudioPlayer(data: data)
        // -1 = loop forever; the seam is authored to be inaudible (below), so a
        // sample-accurate loop is all we need.
        player?.numberOfLoops = -1
        player?.prepareToPlay()
        // Adopt the persisted policy LAST, so `isEnabled`/`configuredVolume` are
        // set before any hover can reach `start()`.
        refreshFromConfig()
    }

    /// Re-reads the persisted buzz policy and applies it live. Called once at
    /// init, and by Settings' `save()` after a successful write, so a toggle
    /// takes effect without a relaunch — including STOPPING a buzz already
    /// playing when the user switches it off mid-hover.
    func refreshFromConfig() {
        guard let config = try? PopConfig.load() else { return }
        isEnabled = config.buzzEnabled
        configuredVolume = min(1.0, max(0.0, config.buzzVolume))
        player?.volume = Float(configuredVolume)
        if !isEnabled && playing { stop() }
        // DIAGNOSTIC: the buzz has no other trace, so its adopted policy is
        // printed where every launch/Save lands in the stdout capture.
        print("BUZZ_CONFIG enabled=\(isEnabled) vol=\(configuredVolume)")
        fflush(stdout)
    }

    /// Idempotent: a second `start()` while playing changes nothing.
    func start() {
        // THE CHOKE POINT: while the feature is switched off this is a silent
        // no-op, so every caller — the hover observer included — inherits the
        // user's policy without knowing about it.
        guard isEnabled else { return }
        guard !playing else { return }
        playing = true
        // Invalidate any stop-fade still draining: it must not pause this voice.
        fadeGeneration &+= 1
        guard let player else { return }
        // Restart from the head and (re)apply the user's gain in case a previous
        // stop left the player faded. `fadeDuration: 0` so the re-entry is immediate.
        player.currentTime = 0
        player.volume = Float(configuredVolume)
        player.play()
        print("BUZZ_PLAY vol=\(configuredVolume)")
        fflush(stdout)
    }

    /// Idempotent: a second `stop()` while stopped changes nothing. Fades first
    /// so the cut never clicks, then pauses/resets once the fade has drained.
    func stop() {
        guard playing else { return }
        playing = false
        fadeGeneration &+= 1
        guard let player else { return }
        // A 100 ms volume ramp removes the discontinuity; pausing only after it
        // finishes avoids truncating the waveform mid-cycle.
        player.setVolume(0, fadeDuration: Self.fadeOutSeconds)
        let generation = fadeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutSeconds))
            guard let self, generation == self.fadeGeneration, !self.playing else { return }
            player.pause()
            player.currentTime = 0
            // Reset to the user's gain (not a hardcoded 1) so the next start is
            // not louder than configured.
            player.volume = Float(self.configuredVolume)
        }
    }

    // MARK: - Synthesis

    /// Sample rate of the synthesized loop. 44.1 kHz mono is CD-rate and needs no
    /// resampling for the default output.
    private static let sampleRate = 44_100.0
    /// The buzz period is an INTEGER number of samples, so the fundamental and
    /// every odd harmonic complete a whole number of cycles per loop — the
    /// dominant source of a loop seam is eliminated by construction. 368 samples
    /// ≈ 119.8 Hz, right in the requested ~120 Hz pocket.
    private static let periodSamples = 368
    /// 120 whole periods ≈ 1.001 s: a touch over a second, short enough to build
    /// at launch cost nothing, long enough that the ear stops hearing a period.
    private static let periods = 120

    /// Renders the buzz as an in-memory 16-bit PCM WAV. Returns nil only if the
    /// byte container cannot be built (never in practice).
    private static func makeWAV() -> Data? {
        let total = periodSamples * periods
        var buf = [Double](repeating: 0, count: total)

        // Odd harmonics of the fundamental give the arc its "buzzy" timbre; even
        // harmonics would sound like a musical tone, not a discharge.
        let harmonics: [(multiple: Double, amplitude: Double)] = [
            (1, 0.55), (3, 0.28), (5, 0.16), (7, 0.09), (9, 0.05)
        ]
        for i in 0..<total {
            // phase in [0,1) advances one full turn per period; every harmonic
            // therefore also completes an integer number of turns per loop.
            let phase = Double(i % periodSamples) / Double(periodSamples)
            var sample = 0.0
            for h in harmonics {
                sample += h.amplitude * sin(2 * .pi * h.multiple * phase)
            }
            buf[i] = sample
        }

        // Band-limited noise: white noise low-passed by a CIRCULAR moving average.
        // Circular (index wraps) keeps the noise exactly periodic over the buffer,
        // so it adds texture without re-introducing a seam.
        let noiseWindow = 12
        var white = [Double](repeating: 0, count: total)
        for i in 0..<total { white[i] = Double.random(in: -1...1) }
        for i in 0..<total {
            var acc = 0.0
            for k in -noiseWindow...noiseWindow {
                acc += white[(i + k + total) % total]
            }
            buf[i] += acc / Double(2 * noiseWindow + 1) * 0.6
        }

        // Crackle: short decaying impulses at uniformly random offsets. Density is
        // uniform across the buffer, so the loop point carries no audible event
        // cluster — one instance of the statistical-uniformity requirement.
        let crackleCount = 220
        for _ in 0..<crackleCount {
            let start = Int.random(in: 0..<total)
            let length = Int.random(in: 20...90)          // ~0.5–2 ms sputter
            let gain = Double.random(in: 0.15...0.5)
            for j in 0..<length {
                let idx = (start + j) % total             // wrap: no clipped tail
                let envelope = exp(-Double(j) / Double(length) * 4)
                buf[idx] += Double.random(in: -1...1) * gain * envelope
            }
        }

        // Slight amplitude jitter — a slow, circular random envelope — so the loop
        // does not sound like a pure machine tone. The jitter buffer is itself
        // passed through the circular smoother to stay periodic and gentle.
        let jitterWindow = 200
        var jitterRaw = [Double](repeating: 0, count: total)
        for i in 0..<total { jitterRaw[i] = Double.random(in: -1...1) }
        for i in 0..<total {
            var acc = 0.0
            for k in -jitterWindow...jitterWindow {
                acc += jitterRaw[(i + k + total) % total]
            }
            buf[i] *= 1.0 + 0.12 * (acc / Double(2 * jitterWindow + 1))
        }

        // Loop seam, belt-and-braces: crossfade the last ~5 ms into the first
        // ~5 ms so any crackle caught on the boundary eases out instead of
        // stepping. (The tonal layers are already seam-free by construction.)
        let crossfade = Int(0.005 * sampleRate) // ~220 samples
        for i in 0..<crossfade {
            let w = Double(i) / Double(crossfade)
            let tail = total - crossfade + i
            buf[tail] = buf[tail] * (1 - w) + buf[i] * w
        }

        // Normalize to a modest peak: a subtle menacing hum, not a stun gun.
        let peakTarget = 0.25
        var peak = 0.0
        for s in buf { peak = max(peak, abs(s)) }
        let scale = peak > 0 ? peakTarget / peak : 0

        // Encode as 16-bit little-endian PCM and wrap in a minimal RIFF/WAVE
        // container — the format `AVAudioPlayer(data:)` accepts directly.
        var pcm = Data(capacity: total * 2)
        for s in buf {
            let clamped = max(-1.0, min(1.0, s * scale))
            let v = Int16(clamped * 32_767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return wavContainer(pcm: pcm, sampleRate: UInt32(sampleRate))
    }

    /// Minimal mono 16-bit PCM RIFF/WAVE header in front of `pcm`.
    private static func wavContainer(pcm: Data, sampleRate: UInt32) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var out = Data()
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        out.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + dataSize)          // chunk size = header remainder + data
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)                     // PCM fmt chunk size
        appendU16(1)                      // audio format = PCM
        appendU16(channels)
        appendU32(sampleRate)
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        out.append(contentsOf: Array("data".utf8))
        appendU32(dataSize)
        out.append(pcm)
        return out
    }
}
