import Foundation

/// LAUNCH PRE-WARM: pay the two fixed costs the user's FIRST message used to
/// pay, at launch, in the background.
///
/// The complaint was "the first message is slower than the rest", and it was
/// right for two separate reasons that were both paid INSIDE the first turn:
///  1. the on-device model's framework/session init, and
///  2. the web session warm — a root-page visit plus its settle delay.
///
/// Both are now warmed here, once per process, off the critical path. Every
/// number goes to STDOUT; nothing is rendered, per the user's decision that
/// diagnostics stay off-screen.
///
/// RULES THIS TYPE KEEPS:
///  * NOTHING BLOCKS LAUNCH. Each warm is its own detached task; a failure is
///    logged and dropped, never fatal, never retried in a loop.
///  * THE EXISTING WARM IS REUSED, not replaced. `WebLookup.warmSession` is
///    called directly, so the per-process `sessionWarmDone` gating still holds:
///    the first lookup finds the session already formed and skips its own root
///    visit. A second warm mechanism would race that flag and warm twice.
///  * PROBES STAY ISOLATED. The pre-warm is skipped in any `--test-*`/`--user-*`
///    run unless that run asks for it, so a probe measures the COLD first turn
///    it claims to and the real support root is never touched from a probe.
///    `POP_PREWARM=0` disables it outright.
enum LaunchPrewarm {
    /// True when this process is allowed to pre-warm at launch.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["POP_PREWARM"] == "0" { return false }
        if ProcessInfo.processInfo.environment["POP_PREWARM"] == "1" { return true }
        let isProbe = CommandLine.arguments.contains {
            $0.hasPrefix("--test-") || $0.hasPrefix("--user-")
        }
        return !isProbe
    }

    /// Fired once at launch. Returns immediately; both warms run detached.
    static func start(pcc: Bool) {
        guard isEnabled else {
            print("PREWARM_SKIPPED reason=probe-or-disabled")
            fflush(stdout)
            return
        }
        // Detached, and each warm independent: a browser warm that fails (no
        // network, no WebKit yet) must not stop the model warm.
        Task.detached(priority: .utility) { await warmModel(pcc: pcc) }
        Task.detached(priority: .utility) { await warmWeb() }
    }

    /// One minimal generation through the EXISTING provider path. It is a real
    /// call on purpose — a no-op that skipped `stream` would not touch the
    /// framework's init, which is the entire cost being pre-paid.
    static func warmModel(pcc: Bool) async {
        let started = Date()
        print("PREWARM_MODEL_STARTED pcc=\(pcc)")
        fflush(stdout)
        do {
            let provider = AppleFMProvider(pcc: pcc)
            guard provider.isHealthy else {
                print("PREWARM_MODEL_SKIPPED reason=unhealthy")
                fflush(stdout)
                return
            }
            let messages = [ChatMessage(role: .user, text: "ping")]
            _ = try await provider.collectText(
                messages: messages,
                options: GenerationOptions(temperature: 0)
            )
            // The seam records that init had ALREADY happened by the time the
            // user's first real call arrives — that, not this call succeeding,
            // is what `FM_PREWARM` asserts.
            ProviderTestSeams.shared.noteFMPrewarmFinished()
            print("PREWARM_MODEL_MS=\(Int(Date().timeIntervalSince(started) * 1000))")
            print("PREWARM_MODEL_DONE=true")
        } catch {
            print("PREWARM_MODEL_FAILED \(error)")
        }
        fflush(stdout)
    }

    /// The SAME warm the first lookup would have done, done at launch instead.
    ///
    /// `WebLookup.warmSession` is called as-is: the per-process flag inside it
    /// is the gate, so this either forms the session once or is a no-op — never
    /// a second root visit, and never a lookup that skips warming because of it.
    static func warmWeb() async {
        let started = Date()
        let host = ProcessInfo.processInfo.environment["POP_WARM_HOST"] ?? "www.google.com"
        print("PREWARM_WEB_STARTED host=\(host)")
        fflush(stdout)
        await WebLookup.warmSession(host: host)
        print("PREWARM_WEB_MS=\(Int(Date().timeIntervalSince(started) * 1000))")
        print("PREWARM_WEB_DONE=true")
        fflush(stdout)
    }
}