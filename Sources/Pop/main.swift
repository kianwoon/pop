import AppKit
import AVFoundation
import CoreGraphics
import FoundationModels
import Network
import ScreenCaptureKit
import Speech
import WebKit

// Unbuffered stdout: the M0 verification reads /tmp/pop-m0.log while the app is
// still alive, so buffered prints would be lost on SIGTERM.
setvbuf(stdout, nil, _IONBF, 0)

/// Top-level global initializers are nonisolated, so the wiring happens inside
/// an explicitly main-actor-isolated entry point instead.
@MainActor
func bootstrap() {
    if CommandLine.arguments.contains("--test-settings-roundtrip") {
        runSettingsRoundtripProbe()
        return
    }

    // The settings CLI runs before ANY UI exists, for the same reason the
    // probes do: it is a headless configuration tool, and a window would be
    // both unwanted and unobservable in a terminal.
    if let pairs = singleValueProbeArgument("--set-config") {
        runSetConfig(pairs: pairs)
        return
    }

    if let secret = singleValueProbeArgument("--set-key") {
        runSetKey(secret: secret)
        return
    }

    // `--test-chat` is checked before ANY UI is created: the model probe must not
    // open a window, register a hotkey, or disturb the user's frontmost app.
    if CommandLine.arguments.contains("--test-observe") {
        runObserveProbe()
        return
    }

    if let prompt = singleValueProbeArgument("--test-context") {
        runContextProbe(prompt: prompt)
        return
    }

    if let secret = singleValueProbeArgument("--test-keychain") {
        runKeychainProbe(secret: secret)
        return
    }

    // PROBES NEVER TOUCH PRODUCTION STORAGE. Any `--test-*` run gets a throwaway
    // session root, not just the session probes: a live-path run records real
    // turns, and those must land in a temp directory rather than in the user's
    // own conversation list. Set BEFORE any ChatController exists, since that
    // is where `SessionStore.rootURL` is first read.
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-") }) {
        setenv(
            "POP_SESSIONS_PATH",
            NSTemporaryDirectory() + "pop-sessions-\(UUID().uuidString)",
            1
        )
        // The same invariant for the transcript log. A probe that sends a real
        // message appends turns, and an append is a write into the user's own
        // conversation history — `--test-real-state-gate` proved that by doing
        // it. Both stores are redirected or neither is.
        setenv(
            "POP_TRANSCRIPT_PATH",
            NSTemporaryDirectory() + "pop-transcript-\(UUID().uuidString).jsonl",
            1
        )
    }

    // M9 — the brain decision, at startup. On a fresh launch the default
    // provider is the on-device model; the configured remote provider is the
    // fallback. `providerDecisionSummary` constructs no remote provider, so this
    // never reads the Keychain just to log.
    let startupConfig = (try? PopConfig.load()) ?? .defaults
    print("PROVIDER_STARTUP_DECISION=\(ChatController.providerDecisionSummary(startupConfig))")
    print("PROVIDER_DEFAULT_DECISION=\(ChatController.providerDecisionSummary(.defaults))")
    // The stream policy, stated once so a live log proves WHAT was enforced:
    // idle-time, not turn-time. `warn` is a log-only calibration marker.
    print("STREAM_TIMEOUT_POLICY idle=\(ChatController.streamIdleCapSeconds())s warn=\(ChatController.streamWarnSeconds)s")
    fflush(stdout)

    // Stream-timeout policy probes. Scripted providers + a virtual clock drive
    // the REAL `handleChatSend` path, so the 60s/180s idle policy is measured
    // deterministically without any real sleep.
    if CommandLine.arguments.contains("--test-stream-timeout") {
        runStreamTimeoutProbe()
        return
    }
    if CommandLine.arguments.contains("--test-error-render") {
        runErrorRenderProbe()
        return
    }
    if CommandLine.arguments.contains("--test-fallback-carry") {
        runFallbackCarryProbe()
        return
    }
    if CommandLine.arguments.contains("--test-context-splice") {
        runContextSpliceProbe()
        return
    }

    if CommandLine.arguments.contains("--test-key-status") {
        runKeyStatusProbe()
        return
    }

    if CommandLine.arguments.contains("--test-tool-sandbox") {
        runToolSandboxProbe()
        return
    }

    if CommandLine.arguments.contains("--test-tools-schema") {
        runToolsSchemaProbe()
        return
    }

    // `--test-thinking-param`: the cloud `thinking` field is config-driven
    // DATA, never a hardcoded request constant. Pure payload-builder
    // assertions, no network call. Gate: `THINKING_PROBE=ok`.
    if CommandLine.arguments.contains("--test-thinking-param") {
        runThinkingParamProbe()
        return
    }

    if CommandLine.arguments.contains("--test-approval-approve") {
        runApprovalProbe(decision: "run", gateName: "DENIED_APPROVE_GATE")
        return
    }

    if CommandLine.arguments.contains("--test-approval-deny") {
        runApprovalProbe(decision: "deny", gateName: "DENIED_DENY_GATE")
        return
    }

    if CommandLine.arguments.contains("--test-bash-gated") {
        runBashGatedProbe()
        return
    }

    if CommandLine.arguments.contains("--test-tool-classification") {
        runToolClassificationProbe()
        return
    }

    // `--test-ui-tools`: the computer-use ACT registry. Asserts the four new
    // act tools are present and approval-gated, that `ui_key`'s pure table maps
    // named keys and combos to (vt, mods) with an unknown key nil, and that
    // `app_manage` rejects an unknown action before any app work. No event is
    // posted and no UI is shown.
    if CommandLine.arguments.contains("--test-ui-tools") {
        runUIToolsProbe()
        return
    }

    // `--test-hats`: the route→hat truth table. Pure; no provider, no loop.
    if CommandLine.arguments.contains("--test-hats") {
        runHatsProbe()
        return
    }

    // `--test-ui-observe`: the ref-based native perception path. Seam-injected
    // snapshot + frontmost seam, no live AX walk. Gate: `UI_OBSERVE_PROBE=ok`.
    if CommandLine.arguments.contains("--test-ui-observe") {
        runUIObserveProbe()
        return
    }

    // `--test-automation-playbook`: the route-conditional hat/playbook injection
    // AND the gated-timeout nudge, through the REAL loop with scripted
    // providers. Gate: `AUTOMATION_PLAYBOOK_PROBE=ok`.
    if CommandLine.arguments.contains("--test-automation-playbook") {
        runAutomationPlaybookProbe()
        return
    }

    // `--test-brain-md`: the brain's thinking as DATA. The bundled `brain.md`
    // loads the hats/playbook/policies; a missing file falls back to today's
    // strings. Gate: `BRAIN_MD_PROBE=ok`.
    if CommandLine.arguments.contains("--test-brain-md") {
        runBrainMDProbe()
        return
    }

    // `--test-premise-noul`: the PURE noul parser truth table for the premise
    // gate (0.9 → true, 0.3 → false, non-numeric → nil/fail-open). Gate:
    // `PREMISE_NOUL_PROBE=ok`.
    if CommandLine.arguments.contains("--test-premise-noul") {
        runPremiseNoulProbe()
        return
    }

    // `--test-micro-assist`: the T2 on-device micro-assist, seam-driven. A
    // confident match retries; unavailable or low-confidence fails open. Gate:
    // `MICRO_ASSIST_PROBE=ok`.
    if CommandLine.arguments.contains("--test-micro-assist") {
        runMicroAssistProbe()
        return
    }

    // `--test-screenshot-scope`: the PRIVACY invariant that capture is
    // window-scoped or it does not happen. Asserts the ownership/size rule
    // rejects a bundle that owns no window, the no-window path logs one
    // sanitized line and returns a typed nil (not denied), and the public entry
    // point never falls back to a display capture. No window server required.
    if CommandLine.arguments.contains("--test-screenshot-scope") {
        runScreenshotScopeProbe()
        return
    }

    // `--test-walkthrough-tab-read`: the END-TO-END journey (raise a buried tab,
    // click a read line, re-read, answer) plus the honest-failure journey
    // (fixture missing -> named-step failure, no web call) and the component
    // arms (coordinate hygiene, click autonomy, the one typed-text gate, the
    // click guard). Every seam is a test seam; no real browser or network.
    if CommandLine.arguments.contains("--test-walkthrough-tab-read") {
        runWalkthroughTabReadProbe()
        return
    }

    // `--test-focus-tab`: the AppleScript tab-raise driver, with the script
    // result channel and the running check SEAMED — no real browser is touched.
    // Registered before the generic `--test-browser-` prefix match (which would
    // not match this name, but the ordering keeps the probes together).
    if CommandLine.arguments.contains("--test-focus-tab") {
        runFocusTabProbe()
        return
    }

    // `--test-focus-preference`: the PURE tab-selection preference shared by
    // focus (active tab of the front window first, then the earliest match).
    // No browser, no script, no run loop.
    if CommandLine.arguments.contains("--test-focus-preference") {
        runFocusPreferenceProbe()
        return
    }

    // `--test-focus-query`: the QUERY LOGIC of the raise step, end to end on
    // seams — the front read finds nothing relevant, the scripted model raises
    // the tab the USER named (taken from the shipped guidance example, never a
    // hardcoded site), and then either answers the miss honestly or proceeds to
    // read the raised tab. No real browser.
    if CommandLine.arguments.contains("--test-focus-query") {
        runFocusQueryProbe()
        return
    }

    // `--test-browser-actions`: the approval-gated acting layer, driven
    // against a window the probe owns. Registered BEFORE the generic
    // `--test-browser-` prefix match below, which would otherwise swallow it.
    if CommandLine.arguments.contains("--test-browser-actions") {
        runBrowserActionsProbe()
        return
    }

    // `--test-pid-click`: the cursorless pid-click construction, asserted by the
    // button's ACTION firing, not by the post returning.
    if CommandLine.arguments.contains("--test-pid-click") {
        runPidClickProbe()
        return
    }

    // The browser probes share one fixture root and a live WKWebView, so they
    // run on the app path (a run loop is required) but never touch the network:
    // every URL is a `file://`-backed fixture opened through a loopback-safe
    // path, and the blocked-scheme probe proves `file://` is refused outright.
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-browser-") }) {
        runBrowserProbe()
        return
    }

    // `--test-embedded-serp <url>`: a MEASUREMENT probe over the same in-panel
    // `WKWebView` the browser tools drive. It needs a run loop but no fixture
    // server and no model.
    if let serpURL = singleValueProbeArgument("--test-embedded-serp") {
        runEmbeddedSERPProbe(url: serpURL)
        return
    }

    // `--test-relation-morphology`: the relation test's inflection rule, measured
    // against fixture text with the REAL extraction script.
    if CommandLine.arguments.contains("--test-relation-morphology") {
        runRelationMorphologyProbe()
        return
    }

    // `--test-session-warm`: forms the session the way a first visit forms it
    // and prints the cookie names/count the store accumulated (and, on the
    // second launch of the pair, that they persisted).
    if CommandLine.arguments.contains("--test-session-warm") {
        runSessionWarmProbe()
        return
    }

    // `--test-web-lookup <query>`: drives the REAL `web_lookup` capability
    // directly — never through the model — and prints its raw values, so the
    // capability is measured, not assumed.
    if let lookupQuery = singleValueProbeArgument("--test-web-lookup") {
        let rawSlots = ProcessInfo.processInfo.environment["POP_LOOKUP_SLOTS"]
            ?? singleValueProbeArgument("--slots")
        let slots = rawSlots.map { splitProbeList($0) } ?? []
        runWebLookupProbe(query: lookupQuery, slots: slots)
        return
    }

    // `--test-excerpt-quality`: the fragment gate. Six real queries, each
    // asserted for a word-boundary start and a sentence/punctuation end, plus a
    // stale-date measurement and the empty-slot ask guard.
    if CommandLine.arguments.contains("--test-excerpt-quality") {
        runExcerptQualityProbe()
        return
    }

    // `--test-no-junk-ask`: the permanent regression guard for the junk-ask
    // bug. Six plain questions are driven through the real product path with NO
    // caller-declared slots; each must ANSWER, and the removed page-scraped ask
    // template must be unreachable from any user-facing text.
    if CommandLine.arguments.contains("--test-no-junk-ask") {
        runNoJunkAskProbe()
        return
    }

    if CommandLine.arguments.contains("--test-tool-loop") {
        // The tool loop probe needs a real model, so it runs on the real app
        // path with an isolated config and session root, exactly like the UI
        // probes below.
    }

    if CommandLine.arguments.contains("--test-sessions") {
        runSessionsProbe()
        return
    }

    if CommandLine.arguments.contains("--test-clock") {
        runClockProbe()
        return
    }

    if let prompt = chatProbePrompt() {
        runChatProbe(prompt: prompt)
        return
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // The menu goes in before ANY window exists: an `.accessory` app without a
    // main menu has no Edit menu, and without that ⌘V/⌘C/⌘X/⌘A are dispatched
    // nowhere — typing worked in a text field while paste silently did not.
    // Every probe path above has already returned, so no probe builds this.
    MainMenu.install()

    // `--test-summon` must seed its non-default frame BEFORE the panel reads
    // its restore key, so this has to happen ahead of construction.
    // PROBES NEVER TOUCH PRODUCTION STORAGE. A measurement run that persists a
    // robot position would overwrite the user's real one, so every position probe
    // gets its own suite and injects it into `PanelController`.
    let positionProbeFlags = ["--test-robot-anchor", "--test-persistence", "--test-robot-drag", "--test-bar-fit", "--user-bar-fit"]
    let runsPositionProbe = positionProbeFlags.contains {
        CommandLine.arguments.contains($0)
    }
    let probeDefaults = runsPositionProbe
        ? UserDefaults(suiteName: "com.pop.app.probe") ?? .standard
        : UserDefaults.standard
    // A stale anchor from a PREVIOUS probe run would be restored as if it were
    // this run's first-launch default, so a probe would measure the previous
    // probe's leftovers. Start every position probe clean — except
    // `--test-persistence`, whose gate is precisely that run 2 restores what
    // run 1 wrote.
    if runsPositionProbe, !CommandLine.arguments.contains("--test-persistence") {
        for key in [PanelController.anchorDefaultsKey, PanelController.frameDefaultsKey] {
            probeDefaults.removeObject(forKey: key)
        }
        // Seed the robot MID-SCREEN rather than letting it fall to the
        // bottom-center first-launch default: from the bottom edge the
        // `full` window cannot fit below the robot, and the deliberate clamp
        // would move the robot and read as instability — a position artefact of
        // where the probe put the robot, not of the anchor.
        if let visible = NSScreen.main?.visibleFrame {
            probeDefaults.set(
                NSStringFromPoint(NSPoint(x: visible.midX - 265, y: visible.midY)),
                forKey: PanelController.anchorDefaultsKey
            )
        }
    }

    let summonProbeSeed: NSPoint? = CommandLine.arguments.contains("--test-summon")
        ? NSPoint(x: 2000, y: 1000)
        : nil
    if let summonProbeSeed {
        UserDefaults.standard.set(
            NSStringFromPoint(summonProbeSeed),
            forKey: PanelController.frameDefaultsKey
        )
    }

    let panelController = PanelController(defaults: probeDefaults)

    // The robot is mounted INSIDE the panel window (see `PanelController`), so
    // there is no separate mascot window to construct or wire up.

    let chatController = ChatController(
        webViewProvider: { [weak panelController] in panelController?.appWebView.webView },
        configProvider: { (try? PopConfig.load()) ?? .defaults }
    )
    panelController.appWebView.onBridgeMessage = { [chatController] type, body in
        MainActor.assumeIsolated { chatController.handleBridgeMessage(type: type, body: body) }
    }
    // Bar state is LAUNCHER ONLY (robot + composer, no chat), so every state
    // change is pushed to the page; ChatController buffers it until uiReady.
    panelController.onPanelStateChange = { [weak chatController] state in
        MainActor.assumeIsolated { chatController?.pushPanelState(state) }
    }
    // The hotkey focuses the composer; the call queues until the page is ready.
    panelController.onFocusInput = { [weak chatController] in
        MainActor.assumeIsolated { chatController?.focusInput() }
    }
    // BY DEFAULT, DO NOT SHOW CHAT: the page may not expand the panel into
    // `full` until this session actually has a conversation.
    panelController.isSessionEmpty = { [weak chatController] in
        MainActor.assumeIsolated { chatController?.sessionIsEmpty ?? true }
    }
    // A single click on the robot summons the composer, exactly like ⌥Space.
    NotificationCenter.default.addObserver(
        forName: .popSummonBar,
        object: nil,
        queue: .main
    ) { _ in
        MainActor.assumeIsolated { panelController.summonBar() }
    }
    // A plain click on the robot TOGGLES its composer surface: open when alone,
    // collapse when up. The symmetry a single click needs; `.popSummonBar` above
    // stays summon-only (the capsule's Composer button uses it).
    NotificationCenter.default.addObserver(
        forName: .popToggleComposer,
        object: nil,
        queue: .main
    ) { _ in
        MainActor.assumeIsolated { panelController.toggleComposer() }
    }
    // The mascot's pencil button resets the conversation before opening.
    NotificationCenter.default.addObserver(
        forName: Notification.Name("PopNewChat"),
        object: nil,
        queue: .main
    ) { [chatController] _ in
        MainActor.assumeIsolated { chatController.newChat() }
    }
    // Summoning the panel with text selected offers it as a prefill.
    NotificationCenter.default.addObserver(
        forName: Notification.Name("popPanelSummoned"),
        object: nil,
        queue: .main
    ) { [chatController] _ in
        MainActor.assumeIsolated {
            // Chips first, then the selection prefill: the chip row should be
            // in place before anything lands in the input.
            chatController.pushContextUI()
            chatController.offerSelectionPrefill()
        }
    }
    // The heavy half of the summon capture (AX tree + window screenshot) is done
    // off the hotkey path; refresh the chips and thumbnail when it lands. Chips
    // may briefly show app-only until this fires.
    NotificationCenter.default.addObserver(
        forName: Notification.Name("popPanelHeavyContextReady"),
        object: nil,
        queue: .main
    ) { [chatController] _ in
        MainActor.assumeIsolated { chatController.pushContextUI() }
    }
    // ScreenCaptureKit's first window enumeration costs seconds per launch, so it
    // is warmed in the background at startup rather than on the first summon.
    Observe.warmShareableContentCache()
    // The same reasoning for the two costs the FIRST MESSAGE used to pay: the
    // on-device model's session init, and the web session warm (a root visit
    // plus its settle). Both are detached and non-blocking, and both print
    // off-screen only. Skipped inside probes, so a probe still measures a cold
    // first turn.
    LaunchPrewarm.start(pcc: startupConfig.pcc)

    let orb = StatusBarOrb(
        onShow: { panelController.show() },
        onHide: { panelController.hide() },
        onSettings: { SettingsWindowController.shared.show() },
        onQuit: { NSApplication.shared.terminate(nil) }
    )

    let hotkeyCenter = HotkeyCenter { panelController.toggle() }

    orb.install()
    hotkeyCenter.register()

    if CommandLine.arguments.contains("--mascot-cycle") {
        panelController.mascotModel.startCycling()
    }

    if CommandLine.arguments.contains("--show-on-launch") {
        panelController.show()
    }

    // `--test-settings-reopen`: the user signed in, closed Settings, and could
    // never reopen it. The gate is the WHOLE round trip — show, close, show —
    // because a probe that only showed the window would pass against the very
    // bug it exists to catch.
    // `--test-settings-row-refresh`: the account row must follow the store
    // while the window stays OPEN — no re-show in between.
    // `--test-scroll-cue`: the transcript must carry NO scroll cue at all.
    // `--test-screen-ocr`: can Pop read the text in a window, and does it say
    // so honestly when it cannot?
    if CommandLine.arguments.contains("--test-screen-ocr") {
        runScreenOCRProbe()
        return
    }

    // `--test-front-order [query]`: LIVE evidence for the "stale front window"
    // defect — the true z-order (`CGWindowListCopyWindowInfo`, front to back)
    // against `SCShareableContent`'s enumeration order, then (with a query) the
    // exact raise → read chain re-read at settle delays. Real screen, no model.
    if CommandLine.arguments.contains("--test-front-order") {
        runFrontOrderProbe(query: singleValueProbeArgument("--test-front-order"))
        return
    }

    // `--test-first-turn-latency`: does pre-paying the two launch costs
    // actually make the first turn cheaper? Numbers only.
    if CommandLine.arguments.contains("--test-first-turn-latency") {
        runFirstTurnLatencyProbe()
        return
    }

    if CommandLine.arguments.contains("--test-scroll-cue") {
        runScrollCueProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-settings-row-refresh") {
        runSettingsRowRefreshProbe()
        return
    }

    if CommandLine.arguments.contains("--test-settings-reopen") {
        runSettingsReopenProbe()
        return
    }

    if CommandLine.arguments.contains("--test-google-signin") {
        runGoogleSignInProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-focus") {
        runFocusProbe(panelController)
        return
    }

    if CommandLine.arguments.contains("--test-hotkey") {
        runHotkeyProbe(panelController)
        return
    }

    if let prompt = singleValueProbeArgument("--test-ui-chat") {
        runUIChatProbe(prompt: prompt, panelController: panelController, chatController: chatController)
        return
    }

    if CommandLine.arguments.contains("--test-ui-sessions") {
        runUISessionsProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-voice-dialog") {
        runVoiceDialogProbe(panelController: panelController, chatController: chatController)
        return
    }

    // `--test-voice-dismiss`: ANY dismissal of the voice bar must stop the mic.
    // Headless (the mic needs TCC), so it asserts the WIRING: the collapse
    // funnel posts `popPanelDismissed` and the mic's owner reacts to it.
    if CommandLine.arguments.contains("--test-voice-dismiss") {
        runVoiceDismissProbe(panelController: panelController, chatController: chatController)
        return
    }

    // `--test-update-check`: the live GitHub check plus the `isNewer` truth
    // table. No install side effects.
    if CommandLine.arguments.contains("--test-update-check") {
        runUpdateCheckProbe()
        return
    }

    // `--test-update-download`: fetch + unpack the real release into a TEMP dir
    // and prove the binary inside. Never touches the running bundle.
    if CommandLine.arguments.contains("--test-update-download") {
        runUpdateDownloadProbe()
        return
    }

    // `--test-jev-bridge`: the advisory parser, the disabled fast-path, and the
    // fail-open unreachable path. No server required.
    if CommandLine.arguments.contains("--test-jev-bridge") {
        runJevBridgeProbe()
        return
    }

    // `--test-autonomy`: the STANDING APPROVAL for reversible screen acts plus
    // the browser tab-reuse decision. No event is posted, no browser opens, no
    // network. Gate: `AUTONOMY_PROBE=ok`. Registered here (not with the headless
    // probes) because it drives `ApprovalGate` on the main run loop.
    if CommandLine.arguments.contains("--test-autonomy") {
        runAutonomyProbe()
        return
    }

    // `--test-jev-runlabel`: the jev run-STATE labeler (SPEC §4.4 use (c)) —
    // its pure choice-to-notice and fire-condition tables, the disabled no-op,
    // and the fail-open unreachable path. No server, no loop, no control change.
    if CommandLine.arguments.contains("--test-jev-runlabel") {
        runJevRunLabelProbe()
        return
    }

    // `--test-jev-route`: the jev SKILL ROUTER (SPEC §4.4 use (a)) — its pure
    // choice-to-hint truth table, the disabled no-op (byte-identical messages),
    // and the fail-open unreachable path. No server, no control change.
    if CommandLine.arguments.contains("--test-jev-route") {
        runJevRouteProbe()
        return
    }

    // `--test-routing-fallback`: a turn ROUTED to a hands-on class must be served
    // by a brain that HAS those tools. On the tool-less on-device brain it is
    // promoted to the remote provider, visibly; a non-hands-on route is
    // byte-identical (stays on-device). Gates: the four ROUTE_FALLBACK_* markers
    // plus `ROUTE_FALLBACK_PROBE=ok`; exit 0/1.
    if CommandLine.arguments.contains("--test-routing-fallback") {
        runRoutingFallbackProbe()
        return
    }

    if CommandLine.arguments.contains("--test-surfaces") {
        runSurfacesProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-page-version") {
        runPageVersionProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-bar-fit") {
        runBarFitProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-visible-reply") {
        runVisibleReplyProbe(
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--test-rendered-visibility") {
        runRenderedVisibilityProbe(
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--test-real-state-diagnose") {
        runRealStateProbe(
            gate: false,
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    // THE USER'S LAUNCH. Deliberately NOT `--test-`-prefixed: that prefix
    // rewrites `POP_SESSIONS_PATH` to a temp dir, which is exactly the lie
    // that hid this bug for three rounds. This flag runs the REAL app against
    // the REAL support root, so the restored session loads as it does for the
    // user, and it READS the user's sessions — it never writes one.
    if CommandLine.arguments.contains("--user-frame-audit") {
        runUserFrameAudit(
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--user-bar-fit") {
        runUserBarFitProbe(
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--test-real-state-gate") {
        runRealStateProbe(
            gate: true,
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    // The never-navigated half of `--test-real-state-gate`, run as its OWN
    // process. The shared `BrowserController` can go active but never inactive
    // (`setState(active:false)` has no caller), so the discriminating state —
    // panel `full` with no page ever opened — cannot be reached in a process
    // that has already navigated. The gate spawns this executable again with
    // this flag so the state is measured for real, not simulated.
    if CommandLine.arguments.contains("--test-real-state-nonav") {
        runNonNavigatedProbe(
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--test-stop-receipt") {
        runStopReceiptProbe(panelController: panelController)
        return
    }

    // THE RETURN-KEY REFLEX. The user's own words must be in the transcript
    // and out of the composer at the instant return is pressed — before any
    // provider/model work. Drives the REAL page with a scripted provider held
    // shut until the submit-time DOM has been read.
    if CommandLine.arguments.contains("--test-instant-send") {
        runInstantSendProbe(panelController: panelController, chatController: chatController)
        return
    }

    // M9 probes: on-device turn, forced-unavailable fallback, and the
    // fallback-disabled negative control.
    if CommandLine.arguments.contains("--test-on-device-turn") {
        runOnDeviceTurnProbe(panelController: panelController, chatController: chatController)
        return
    }

    if CommandLine.arguments.contains("--test-on-device-fallback") {
        runOnDeviceFallbackProbe(panelController: panelController, chatController: chatController)
        return
    }

    if CommandLine.arguments.contains("--test-on-device-nofallback") {
        runOnDeviceNoFallbackProbe(panelController: panelController, chatController: chatController)
        return
    }

    // The on-device brain answers a LIVE weather question via `web_lookup`, and
    // the answer is checked against the live page re-fetched in the same run.
    if CommandLine.arguments.contains("--test-on-device-weather") {
        runOnDeviceWeatherProbe(panelController: panelController, chatController: chatController)
        return
    }

    // The flight query through the REAL on-device turn: prints the ask text the
    // user actually sees AND the tool's own `inferredNotInQuery` from the same
    // run, then gates that every parameter-like token in the ask is a verbatim
    // member of the tool's list. Closes the observability gap that let the model
    // invent an extra city unseen.
    // `--test-plan-trace`: does Pop DECOMPOSE a multi-step request visibly?
    // Scripted provider, so the measurement is Pop's plumbing and never the
    // live model's mood.
    if CommandLine.arguments.contains("--test-plan-trace") {
        runPlanTraceProbe()
        return
    }

    // `--test-plan-checkpoint`: a `see: true` step STOPS the batched run and
    // hands the accumulated evidence back to the model; an unmarked plan still
    // runs in ONE burst. Scripted provider, so the measurement is Pop's
    // plumbing and never a model.
    if CommandLine.arguments.contains("--test-plan-checkpoint") {
        runPlanCheckpointProbe()
        return
    }

    // `--test-plan-nudge`: a multi-step turn that runs tool rounds WITHOUT
    // `plan_update` gets ONE injected nudge; a turn that plans gets none.
    // Scripted provider, so the measurement is Pop's loop and never a model.
    if CommandLine.arguments.contains("--test-plan-nudge") {
        runPlanNudgeProbe()
        return
    }


if CommandLine.arguments.contains("--test-ask-honesty") {
        runAskHonestyProbe(panelController: panelController, chatController: chatController)
        return
    }

    // REPRODUCTION / ECHO GATE: send an ARBITRARY prompt through the real
    // provider path and report whether the reply is the prompt verbatim.
    if let prompt = singleValueProbeArgument("--test-on-device-prompt") {
        runOnDevicePromptProbe(
            prompt: prompt,
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--test-no-stray-cancel") {
        runNoStrayCancelProbe(panelController: panelController)
        return
    }

    if CommandLine.arguments.contains("--test-tool-loop") {
        runToolLoopProbe(chatController: chatController)
        return
    }

    // `--test-fm-capability`: a headless capability battery for the ON-DEVICE
    // brain — six scenarios, each reported honestly. The exit gate proves the
    // harness ran (provider available, scenarios produced output), never that
    // the model performed well.
    if CommandLine.arguments.contains("--test-fm-capability") {
        runFMCapabilityProbe()
        return
    }

    if CommandLine.arguments.contains("--test-collapse-regression") {
        runCollapseRegressionProbe(
            panelController: panelController,
            chatController: chatController
        )
        return
    }

    if CommandLine.arguments.contains("--test-summon") {
        runSummonProbe(panelController, seeded: summonProbeSeed)
        return
    }

    if CommandLine.arguments.contains("--test-live-path") {
        runLivePathProbe(panelController: panelController, chatController: chatController)
        return
    }

    if CommandLine.arguments.contains("--test-error-recovery") {
        runErrorRecoveryProbe(panelController: panelController, chatController: chatController)
        return
    }

    if CommandLine.arguments.contains("--test-robot-anchor") {
        runRobotAnchorProbe(panelController)
        return
    }

    if CommandLine.arguments.contains("--test-speech") {
        runSpeechProbe()
        return
    }

    // `--test-mascot-arc`: MEASURE the electric arc's frame against the mascot
    // window, headlessly. The visible-arc regression is converted into numbers
    // (inside/outside the window) instead of an argument about the code.
    if CommandLine.arguments.contains("--test-mascot-arc") {
        runMascotArcProbe(panelController)
        return
    }

    // `--test-hover-pill`: synthesize a real click at each pill's drawn center
    // and assert the app's OWN handler resolved it — the pill path proven
    // without a human or the CUA driver.
    if CommandLine.arguments.contains("--test-hover-pill") {
        runHoverPillProbe(panelController)
        return
    }

    // `--test-composer-toggle`: the robot click must TOGGLE its composer surface
    // (open when alone, collapse when up) — the symmetry the user reported
    // missing. Headless: drives `toggleComposer()` directly and reads the state.
    if CommandLine.arguments.contains("--test-composer-toggle") {
        runComposerToggleProbe(panelController)
        return
    }

    if CommandLine.arguments.contains("--test-persistence") {
        runPersistenceProbe(panelController)
        return
    }

    if CommandLine.arguments.contains("--test-robot-drag") {
        runRobotDragProbe(panelController)
        return
    }

    // Only a real launch gets the warmup: the probe modes above all returned.
    runModelWarmup()

    // AUTO UPDATE CHECK. The user asked: on a real launch, wait ~60 s, check
    // once, and prompt ONLY if a newer release exists. Every `--test-*` probe
    // returned before this line, so this can never fire inside a headless test.
    // Fire-and-forget: a failed check is never load-bearing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        Task { await UpdateChecker.promptAndInstallIfAvailable() }
    }

    application.run()
}

/// `--test-plan-trace`: THE VISIBLE PLAN LAYER, measured against a SCRIPTED
/// provider so the numbers are Pop's plumbing and not the live model's mood.
///
/// The script is the shape the user asked for, in the order the model must be
/// able to produce it:
///   round 1  `plan_update` — set three steps
///   round 2  a real read-only tool round (`screen_read`)
///   round 3  `plan_update` — 1 done, 2 done, 3 blocked
///   round 4  the final answer, which ACKNOWLEDGES the blocked step
///
/// THE GATES, each one a different property:
///  * `PLAN_STEPS_RENDERED` — the transcript shows three steps carrying live
///    status, which is what "visibly" has to mean.
///  * `PLAN_REPLACES_NOT_APPENDS` — after TWO updates there is exactly ONE plan
///    block. Appending would scroll a second copy past the user.
///  * `LOOP_CONTINUED` — a `plan_update` did not end the turn: the tool round
///    and the second `plan_update` both ran, and an answer came after them.
///  * `VERIFY_RULE_PRESENT` — the rule text is in the guidance the model is
///    given, AND the scripted final answer over a blocked step acknowledges it.
///    The first half is Pop's promise, the second half is the shape Pop demands;
///    asserting only the text would prove nothing about the behaviour.
///  * `ROUND_CAP_HELD` — a second turn whose provider calls a tool EVERY round
///    still stops at `AgentLoop.maxRounds`. A plan that cannot end is worse than
///    no plan.
@MainActor
private func runPlanTraceProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let collector = PlanProbeCollector()

    func turn(prompt: String, provider: ModelProvider) async -> String {
        var full = ""
        do {
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: prompt)],
                options: GenerationOptions(),
                tools: ToolRegistry.schemas()
            ) { outcome in
                await MainActor.run {
                    // EXACTLY the app's render path for a plan update: read the
                    // CURRENT plan and push it as one block. Nothing here
                    // reconstructs what the page would show.
                    if outcome.name == "plan_update", outcome.ok {
                        collector.pushPlanBlock(
                            id: PlanTrace.blockID,
                            lines: PlanTraceStore.shared.renderedLines
                        )
                    }
                    collector.record(outcome)
                    print("PLAN_TOOL name=\(outcome.name) ok=\(outcome.ok)")
                    fflush(stdout)
                }
            }
            for try await event in events {
                switch event {
                case .delta(let piece): full += piece
                case .done(let text): full = text
                case .toolCall(_, let name, _):
                    print("PLAN_TOOL_CALL name=\(name)")
                    fflush(stdout)
                }
            }
        } catch {
            print("PLAN_TURN_ERROR \(error)")
            fflush(stdout)
        }
        return full
    }

    Task { @MainActor in
        // A turn-scoped clear first, exactly as `handleChatSend` does.
        PlanTraceStore.shared.reset()

        // --- ROUND 1-4: the scripted plan, through the REAL loop.
        let answer = await turn(
            prompt: "find out what PATRICK_7 messaged me",
            provider: ScriptedPlanProvider()
        )

        let lines = collector.lastPlanLines
        for (index, line) in lines.enumerated() {
            print("PLAN_LINE[\(index)] \(line)")
        }
        fflush(stdout)

        // --- PLAN_STEPS_RENDERED: three steps, each carrying its status.
        let rendered = collector.lastPlanLines.count == 3
            && lines.contains { $0.contains("[x]") }
            && lines.contains { $0.contains("[!]") }
        print("PLAN_STEPS_RENDERED=\(rendered)")

        // --- PLAN_REPLACES_NOT_APPENDS: TWO `plan_update` calls, ONE block.
        let planCalls = collector.planUpdateCalls
        print("PLAN_UPDATE_CALLS=\(planCalls)")
        let replaces = planCalls == 2 && collector.pushCount == 2
            && collector.pushedBlockIDs == [PlanTrace.blockID]
            && lines.count == 3
        print("PLAN_REPLACES_NOT_APPENDS=\(replaces)")

        // --- LOOP_CONTINUED: the round AFTER the first plan update ran a real
        // tool, and an answer came after the plan updates.
        let toolNames = collector.toolNames
        print("PLAN_TOOLS_RAN=\(toolNames.joined(separator: ","))")
        let continued = toolNames.contains("screen_read")
            && toolNames.lastIndex(of: "plan_update") ?? -1
                > toolNames.firstIndex(of: "plan_update") ?? Int.max
            && !answer.isEmpty
        print("LOOP_CONTINUED=\(continued)")

        // --- VERIFY_RULE_PRESENT: the rule is in the guidance Pop sends, and
        // the answer over a blocked step says what is blocked.
        let guidance = AppleFMProvider.systemPrompt
        print("PLAN_GUIDANCE_HAS_RULE=\(guidance.contains(PlanTrace.verifyRule))")
        print("PLAN_GUIDANCE_HAS_WHEN=\(guidance.contains("plan_update"))")
        let acknowledged = answer.lowercased().contains("blocked")
            && answer.lowercased().contains("patrick_7")
        print("PLAN_ANSWER=\(answer.replacingOccurrences(of: "\n", with: " "))")
        print("PLAN_ANSWER_ACK_BLOCKED=\(acknowledged)")
        let verifyRulePresent = guidance.contains(PlanTrace.verifyRule) && acknowledged
        print("VERIFY_RULE_PRESENT=\(verifyRulePresent)")

        // --- ROUND_CAP_HELD: a provider that asks for a tool EVERY round must
        // still be cut off, and the turn must still finish.
        PlanTraceStore.shared.reset()
        // The marker splits the two phases' tool names, so the cap count can
        // never borrow calls from the scripted plan turn above.
        collector.markRoundCapPhase()
        let capTool = ScriptedPlanProvider(everyRound: true)
        let capped = await turn(prompt: "loop forever", provider: capTool)
        let capCalls = collector.toolNamesAfterMarker.count
        print("ROUND_CAP_TOOL_CALLS=\(capCalls)")
        print("ROUND_CAP_LIMIT=\(AgentLoop.maxRounds)")
        let capHeld = capCalls == AgentLoop.maxRounds
        print("ROUND_CAP_HELD=\(capHeld)")
        // --- ROUND_LIMIT_RAISED: pin the regression. The cap must track the
        // measured round cost of the richest supported workflow (a 5-step plan
        // at ~2 rounds/step), not the old planned-chat value of 6.
        let roundLimitRaised = AgentLoop.maxRounds == 15
        print("ROUND_LIMIT_RAISED=\(roundLimitRaised)")
        // --- ROUND_BUDGET_DYNAMIC: the budget is PLAN-AWARE, not a magic
        // constant. No plan keeps the chat floor (15); a declared plan scales
        // at 4 rounds/step + 8, floored at 15 and hard-ceilinged at 60. A
        // 12-field job-application form thus gets 56 rounds; a 30-step plan
        // still hard-stops at 60.
        let budgetDynamic = AgentLoop.roundBudget(planSteps: nil) == 15
            && AgentLoop.roundBudget(planSteps: 5) == 28
            && AgentLoop.roundBudget(planSteps: 12) == 56
            && AgentLoop.roundBudget(planSteps: 30) == 60
        print("ROUND_BUDGET_DYNAMIC=\(budgetDynamic)")
        // Informational, not gated: the capped turn ends on whatever text the
        // cap interrupted, and a model that only ever asked for tools has no
        // answer to give. What matters is that the TURN ENDED.
        print("ROUND_CAP_FINAL_TEXT=\(capped.isEmpty ? "(none)" : capped.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)

        let gate = rendered && replaces && continued && verifyRulePresent && capHeld && roundLimitRaised && budgetDynamic
        print("PLAN_TRACE_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("PLAN_TRACE_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-plan-checkpoint`: PER-STEP PLAN CHECKPOINTS, through the REAL loop
/// with a SCRIPTED provider — never a live model.
///
/// A `see: true` step means "I must SEE this step's result before the rest
/// makes sense". Two scripted turns:
///  * checkpoint — a 3-step `run` with `see` on step 2. Steps 1-2 execute, the
///    executor STOPS (step 3 does NOT run in the burst), and the model's
///    continuation receives steps 1-2's results through the ordinary post-run
///    handback. The consult is an ordinary FM round, counted by the loop.
///  * no-see — the identical plan with no flags anywhere runs all 3 steps in
///    ONE burst: unchanged behavior.
/// Every screen call rides `ScreenOCR.readOverride`, so the read is
/// deterministic and touches no real window.
private func runPlanCheckpointProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    // A DISTINCT, distinguishable reading per call: the handback proof is that
    // the model received BOTH executed results, not merely a marker.
    let reads = ReadCounter()
    ScreenOCR.readOverride = { _ in
        let n = reads.next()
        var window = ScreenOCR.WindowReading()
        window.order = 0
        window.appName = "Fixture"
        window.windowTitle = "Fixture tab"
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window.text = "CHECKPOINT_READ_\(n)"
        var reading = ScreenOCR.Reading()
        reading.windows = [window]
        reading.scopeName = "front"
        return reading
    }
    defer { ScreenOCR.readOverride = nil }

    let capture = CheckpointCapture()

    func runTurn(_ provider: ModelProvider, prompt: String) async -> String {
        var full = ""
        do {
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: prompt)],
                options: GenerationOptions(),
                tools: ToolRegistry.schemas()
            ) { outcome in
                await MainActor.run { capture.record(outcome) }
            }
            for try await event in events {
                switch event {
                case .delta(let piece): full += piece
                case .done(let text): full = text
                case .toolCall: break
                }
            }
        } catch {
            print("CHECKPOINT_TURN_ERROR \(error)")
            fflush(stdout)
        }
        return full
    }

    Task { @MainActor in
        // === CHECKPOINT ARM: `see` on step 2 ==============================
        PlanTraceStore.shared.reset()
        capture.reset()
        AgentLoop.metrics.reset(at: Date())
        let cpAnswer = await runTurn(
            ScriptedCheckpointProvider(
                run: """
                    [{"label":"read one","tool":"screen_read","arguments":{}},\
                    {"label":"read two","tool":"screen_read","arguments":{},"see":true},\
                    {"label":"read three","tool":"screen_read","arguments":{}}]
                    """,
                capture: capture
            ),
            prompt: "checkpoint the read"
        )
        let executed = capture.screenReadCount
        let fmCalls = AgentLoop.metrics.fmCalls
        let flushed = capture.sawCheckpointMarker && executed == 2
        let handback = capture.sawRead1 && capture.sawRead2
        print("CHECKPOINT_EXECUTED=\(executed)")
        print("CHECKPOINT_FM_CALLS=\(fmCalls)")
        print("CHECKPOINT_FLUSHED=\(flushed)")
        print("CHECKPOINT_RESULTS_HANDBACK=\(handback)")
        print("CHECKPOINT_ANSWER=\(cpAnswer.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)

        // === NO-SEE ARM: no flags anywhere = one burst ====================
        PlanTraceStore.shared.reset()
        capture.reset()
        AgentLoop.metrics.reset(at: Date())
        let noSeeAnswer = await runTurn(
            ScriptedCheckpointProvider(
                run: """
                    [{"label":"read one","tool":"screen_read","arguments":{}},\
                    {"label":"read two","tool":"screen_read","arguments":{}},\
                    {"label":"read three","tool":"screen_read","arguments":{}}]
                    """,
                capture: capture
            ),
            prompt: "run the whole plan"
        )
        let noSeeExecuted = capture.screenReadCount
        let oneBurst = noSeeExecuted == 3
        print("CHECKPOINT_NOSEE_EXECUTED=\(noSeeExecuted)")
        print("CHECKPOINT_NOSEE_ANSWER=\(noSeeAnswer.replacingOccurrences(of: "\n", with: " "))")
        print("CHECKPOINT_NOSEE_ONE_BURST=\(oneBurst)")
        fflush(stdout)

        // === ERROR ARM: an error escalates despite a `see` flag ===========
        // Step 1 is `see:true` AND fails (a file that does not exist): the run
        // must BLOCK — never checkpoint — and step 2 must not run.
        PlanTraceStore.shared.reset()
        capture.reset()
        AgentLoop.metrics.reset(at: Date())
        let errAnswer = await runTurn(
            ScriptedCheckpointProvider(
                run: """
                    [{"label":"read a missing file","tool":"read_file",\
                    "arguments":{"path":"/nonexistent-pop-checkpoint-xyz"},"see":true},\
                    {"label":"read the screen","tool":"screen_read","arguments":{}}]
                    """,
                capture: capture
            ),
            prompt: "read the missing file"
        )
        let errEscalates = capture.sawBlockedMarker
            && !capture.sawCheckpointMarker
            && capture.screenReadCount == 0
        print("CHECKPOINT_ERROR_ESCALATES=\(errEscalates)")
        print("CHECKPOINT_ERROR_ANSWER=\(errAnswer.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)

        // === LAST-STEP ARM: `see` on the LAST step = normal handback ======
        // There is no "rest" to stop before, so the run reaches its normal end:
        // PLAN_EXEC_DONE, one consult, no checkpoint.
        PlanTraceStore.shared.reset()
        capture.reset()
        AgentLoop.metrics.reset(at: Date())
        _ = await runTurn(
            ScriptedCheckpointProvider(
                run: """
                    [{"label":"read one","tool":"screen_read","arguments":{}},\
                    {"label":"read two","tool":"screen_read","arguments":{},"see":true}]
                    """,
                capture: capture
            ),
            prompt: "read the last step"
        )
        let lastStepNormal = capture.screenReadCount == 2
            && capture.sawDoneMarker
            && !capture.sawCheckpointMarker
        print("CHECKPOINT_LAST_STEP_NORMAL=\(lastStepNormal)")
        fflush(stdout)

        // The continuation is an ordinary FM round: plan round + consult round.
        let gate = flushed && handback && oneBurst && errEscalates && lastStepNormal
            && !cpAnswer.isEmpty && fmCalls == 2
        print("CHECKPOINT_PROBE=\(gate ? "ok" : "fail")")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("CHECKPOINT_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// A per-call counter for the checkpoint probe's screen reads, so each read
/// yields distinct text without depending on a real screen.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// What the checkpoint probe observes: how many screen reads the executor ran,
/// how many provider calls the turn took, and what the model's continuation
/// actually received in its tool-role messages.
final class CheckpointCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var screenReads = 0
    private var calls = 0
    private var checkpointMarker = false
    private var blockedMarker = false
    private var doneMarker = false
    private var read1 = false
    private var read2 = false

    func record(_ outcome: ToolRoundOutcome) {
        lock.lock(); defer { lock.unlock() }
        if outcome.name == "screen_read", outcome.ok { screenReads += 1 }
    }

    func noteCall() {
        lock.lock(); defer { lock.unlock() }
        calls += 1
    }

    /// Scans the tool-role results the loop handed the model on a continuation:
    /// the checkpoint prefix AND the executed results must both be present.
    func observe(messages: [ChatMessage]) {
        lock.lock(); defer { lock.unlock() }
        for message in messages where message.role == .tool {
            if message.text.contains("PLAN_EXEC_CHECKPOINT") { checkpointMarker = true }
            if message.text.contains("PLAN_EXEC_BLOCKED") { blockedMarker = true }
            if message.text.contains("PLAN_EXEC_DONE") { doneMarker = true }
            if message.text.contains("CHECKPOINT_READ_1") { read1 = true }
            if message.text.contains("CHECKPOINT_READ_2") { read2 = true }
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        screenReads = 0; calls = 0
        checkpointMarker = false; blockedMarker = false; doneMarker = false
        read1 = false; read2 = false
    }

    var screenReadCount: Int { lock.lock(); defer { lock.unlock() }; return screenReads }
    var providerCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var sawCheckpointMarker: Bool { lock.lock(); defer { lock.unlock() }; return checkpointMarker }
    var sawBlockedMarker: Bool { lock.lock(); defer { lock.unlock() }; return blockedMarker }
    var sawDoneMarker: Bool { lock.lock(); defer { lock.unlock() }; return doneMarker }
    var sawRead1: Bool { lock.lock(); defer { lock.unlock() }; return read1 }
    var sawRead2: Bool { lock.lock(); defer { lock.unlock() }; return read2 }
}

/// A SCRIPTED provider for the checkpoint probe: round 1 emits the whole plan
/// `run` it was constructed with; round 2 is the continuation after the
/// executor's handback, which records what the model received and answers.
struct ScriptedCheckpointProvider: ModelProvider {
    var isHealthy: Bool { true }
    var unhealthyReason: String { "" }
    /// FALSE on purpose: the loop must execute these tools itself.
    var executesToolsNatively: Bool { false }

    let run: String
    let capture: CheckpointCapture

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
    private let round = Counter()

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let index = round.next()
                capture.noteCall()
                if index == 1 {
                    continuation.yield(.toolCall(
                        id: "checkpoint_plan_1",
                        name: "plan_update",
                        arguments: .object(["run": .string(run)])
                    ))
                    continuation.finish()
                    return
                }
                // The continuation: record what the executor handed back.
                capture.observe(messages: messages)
                continuation.yield(.done("continuation complete from the checkpoint handback"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `--test-plan-nudge`: THE DETERMINISTIC PLAN NUDGE, measured through the REAL
/// loop with a SCRIPTED provider — never a live model's mood.
///
/// Two turns, each a different property:
///  * no-plan: three tool rounds, no `plan_update` anywhere. After the second
///    tool round the loop injects `AgentLoop.planNudge` exactly ONCE, and the
///    later rounds' requests carry exactly one copy of it.
///  * plan-first: `plan_update` on round one, then tool rounds. The nudge must
///    NEVER appear: a request that planned is not nudged.
@MainActor
private func runPlanNudgeProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    func turn(provider: ModelProvider) async {
        do {
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: "do several things and report")],
                options: GenerationOptions(),
                tools: ToolRegistry.schemas()
            ) { _ in }
            for try await _ in events {}
        } catch {
            print("PLAN_NUDGE_TURN_ERROR \(error)")
            fflush(stdout)
        }
    }

    Task { @MainActor in
        // --- NO-PLAN TURN: 3 tool rounds, zero `plan_update`.
        let noPlanCollector = PlanNudgeCollector()
        await turn(provider: ScriptedNudgeProvider(planFirst: false, collector: noPlanCollector))
        print("PLAN_NUDGE_REQUESTS=\(noPlanCollector.requestCount)")
        print("PLAN_NUDGE_MAX_IN_ONE_REQUEST=\(noPlanCollector.maxNudgeMessages)")
        let once = noPlanCollector.maxNudgeMessages == 1
            && noPlanCollector.copiesOverOne == 0
        print("PLAN_NUDGE_ONCE=\(once)")

        // --- PLAN-FIRST TURN: plans on round one, then tool rounds.
        let plannedCollector = PlanNudgeCollector()
        await turn(provider: ScriptedNudgeProvider(planFirst: true, collector: plannedCollector))
        print("PLAN_NUDGE_SKIPPED_REQUESTS=\(plannedCollector.requestCount)")
        let skipped = plannedCollector.maxNudgeMessages == 0
        print("PLAN_NUDGE_SKIPPED=\(skipped)")

        let gate = once && skipped
        print("PLAN_NUDGE_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("PLAN_NUDGE_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// What the nudge probe OBSERVED in the messages the loop handed the provider:
/// the nudge count in EVERY request, so "exactly once" is measured and not
/// asserted from a reconstruction. Lock-guarded because `stream` runs off-main.
final class PlanNudgeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ nudgeMessages: Int) {
        lock.lock(); defer { lock.unlock() }
        counts.append(nudgeMessages)
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.count
    }

    /// The most copies of the nudge ANY single request carried.
    var maxNudgeMessages: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.max() ?? 0
    }

    /// How many requests carried MORE than one copy — must be zero.
    var copiesOverOne: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.filter { $0 > 1 }.count
    }
}

/// A SCRIPTED provider for `--test-plan-nudge`. It never runs a model; it asks
/// for `list_tools` (read-only, no network, no filesystem) on each tool round
/// and answers at the end. `planFirst` makes round one a `plan_update` instead.
struct ScriptedNudgeProvider: ModelProvider {
    var isHealthy: Bool { true }
    var unhealthyReason: String { "" }
    var executesToolsNatively: Bool { false }

    let planFirst: Bool
    let collector: PlanNudgeCollector

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private let round = Counter()

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // How many nudge copies THIS request carries — the measurement.
                collector.record(messages.filter {
                    $0.role == .system && $0.text == AgentLoop.planNudge
                }.count)
                let index = round.next()
                if planFirst && index == 1 {
                    continuation.yield(.toolCall(
                        id: "call_nudge_plan_1",
                        name: "plan_update",
                        arguments: .object([
                            "steps": .string("first step | second step | third step")
                        ])
                    ))
                    continuation.finish()
                    return
                }
                // The no-plan turn gets three tool rounds; the plan-first turn
                // gets three AFTER its plan, so both reach the nudge threshold.
                if index <= 3 {
                    continuation.yield(.toolCall(
                        id: "call_nudge_tool_\(index)",
                        name: "list_tools",
                        arguments: .object([:])
                    ))
                    continuation.finish()
                    return
                }
                continuation.yield(.done("done after the tool rounds"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `--test-browser-actions`: THE ACTING LAYER, against a window the probe owns.
///
/// The probe stands up its OWN small window (a text field) and drives the REAL
/// `BrowserActions` code: a real CGEvent click at the field, then real
/// keystrokes, then it READS THE FIELD BACK. Nothing here re-implements the
/// click or assumes it landed — the assertion is the text in the widget.
///
/// If Accessibility is not granted the click and type arms cannot run; the
/// probe then reports `PERMISSION=prompt-pending` and gates on the arms that
/// CAN run (the guard and the deny path), rather than faking a delivery it
/// never made.
@MainActor
private func runBrowserActionsProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)

    print("PERMISSION=\(AXIsProcessTrusted() ? "granted" : "prompt-pending")")
    fflush(stdout)

    let marker = "pop_action_probe_4173"

    // The probe's own window. `boundsOverride` hands the guard this frame so
    // the click is allowed to land here; production never sets it and uses the
    // live browser-window enumeration instead.
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = "Pop actions probe"
    let field = NSTextField(frame: NSRect(x: 40, y: 40, width: 420, height: 30))
    field.placeholderString = "probe field"
    window.contentView = NSView(frame: window.contentLayoutRect)
    window.contentView?.addSubview(field)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()

    // The field's centre in QUARTZ global coordinates (origin top-left) — the
    // space `ui_click` takes and the space `SCWindow.frame`/`screen_read`
    // reports. AppKit screen coords have the origin bottom-left, so the
    // vertical axis is flipped against the primary display's height.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let fieldInWindow = field.convert(field.bounds, to: nil)
    let fieldOnScreen = window.convertToScreen(fieldInWindow)
    let clickPoint = CGPoint(
        x: fieldOnScreen.midX,
        y: primaryHeight - fieldOnScreen.midY
    )
    let appKitFrame = window.frame
    let probeFrame = CGRect(
        x: appKitFrame.minX,
        y: primaryHeight - appKitFrame.maxY,
        width: appKitFrame.width,
        height: appKitFrame.height
    )
    print("PROBE_FIELD_SCREEN=\(Int(clickPoint.x)),\(Int(clickPoint.y))")
    fflush(stdout)

    let events = BrowserEventRecorder()
    BrowserActions.eventSinkOverride = { event in events.record(event) }
    BrowserActions.boundsOverride = { [probeFrame] }
    let realClickPossible = AXIsProcessTrusted()

    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))

        var clickDelivered = false
        var typedMatched = false

        if realClickPossible {
            // --- THE REAL CGEvent ARM. Focus the field by CLICKING it, then
            // type. The probe reads the widget, not its own intent.
            BrowserActions.eventSinkOverride = nil
            _ = await BrowserActions.click(
                x: Int(clickPoint.x), y: Int(clickPoint.y)
            )
            try? await Task.sleep(for: .milliseconds(400))
            let focused = window.firstResponder === field
                || (window.firstResponder as? NSTextView)?.delegate === field
            print("CLICK_FOCUSED_FIELD=\(focused)")

            _ = await BrowserActions.type(marker)
            try? await Task.sleep(for: .milliseconds(400))
            let received = field.stringValue
            print("TYPED_TEXT_RECEIVED=\(received)")
            clickDelivered = focused
            typedMatched = received == marker
            print("CLICK_DELIVERED=\(clickDelivered)")
            print("TYPED_TEXT_MATCHED=\(typedMatched)")
        } else {
            print("CLICK_FOCUSED_FIELD=skipped")
            print("TYPED_TEXT_RECEIVED=skipped")
            print("CLICK_DELIVERED=skipped(no-accessibility)")
            print("TYPED_TEXT_MATCHED=skipped(no-accessibility)")
        }
        fflush(stdout)

        // --- THE GUARD ARM: a point outside every allowed window is refused
        // and NO event is posted. Asserted from the RECORDER, so a guard that
        // "rejected" while still posting would fail.
        events.reset()
        BrowserActions.eventSinkOverride = { event in events.record(event) }
        let outside = await BrowserActions.click(x: -9000, y: -9000)
        let rejected = outside.contains("outside every on-screen app window")
            && events.count == 0
        print("CLICK_GUARD_REJECTED=\(rejected)")
        print("CLICK_GUARD_EVENTS_POSTED=\(events.count)")
        fflush(stdout)

        // --- browser_open_url: SEAM ONLY. The launcher is replaced, so no
        // browser opens; the command construction is what is checked.
        let launched = ArgvBox()
        BrowserActions.launcherOverride = { argv in launched.set(argv) }
        let openResult = await BrowserActions.openURL("https://example.com/path?q=1")
        let seamCorrect = launched.value == ["/usr/bin/open", "--", "https://example.com/path?q=1"]
            && openResult.hasPrefix("open:")
        // A bad scheme must not build a command at all.
        let bad = await BrowserActions.openURL("javascript:alert(1)")
        let rejectedScheme = bad.hasPrefix("ERROR:")
        BrowserActions.launcherOverride = nil
        print("OPEN_URL_SEAM=\(seamCorrect)")
        print("OPEN_URL_REJECTS_BAD_SCHEME=\(rejectedScheme)")
        fflush(stdout)

        // --- THE SEND IS AUTONOMOUS. The user removed the send gate: `ui_type`
        // with a newline types and presses Return with no approval card, through
        // the SAME seam the other probes use. There is no deny path to test.
        let sendEvents = BrowserEventRecorder()
        BrowserActions.eventSinkOverride = { event in sendEvents.record(event) }
        BrowserActions.boundsOverride = { [probeFrame] }
        BrowserActions.accessibilityOverride = true
        let sent = await ToolRegistry.execute((
            "ui_type",
            .object(["text": .string("sent-without-a-card\n")])
        ))
        BrowserActions.accessibilityOverride = nil
        BrowserActions.eventSinkOverride = nil
        let sendAutonomous = !sent.hasPrefix("ERROR:")
            && sendEvents.returnCount >= 1
        print("ACTION_SEND_AUTONOMOUS=\(sendAutonomous)")
        print("ACTION_SEND_EVENTS_POSTED=\(sendEvents.count)")
        print("ACTION_SEND_RETURNS=\(sendEvents.returnCount)")
        fflush(stdout)

        // --- THE CLASSIFICATION OF THESE TOOLS, asserted here too so the
        // acting surface is checked where it is exercised. Navigation tools are
        // autonomous (no card), `ui_type` included — there is no send gate.
        let navAutonomous = [
            "browser_open_url", "ui_click", "browser_focus_tab", "ui_type"
        ].allSatisfy {
            ToolRegistry.tool(named: $0)?.access == .localNav
                && !PopTool.requiresApproval(ToolRegistry.tool(named: $0)!.access)
        }
        let typeAutonomous = ToolRegistry.tool(named: "ui_type").map { tool in
            tool.access == .localNav && !PopTool.requiresApproval(tool.access)
        } ?? false
        print("ACTION_TOOLS_NAV_AUTONOMOUS=\(navAutonomous)")
        print("ACTION_TOOLS_TYPE_AUTONOMOUS=\(typeAutonomous)")

        // --- VERIFY-AFTER-ACT GUIDANCE is present where the other rules live.
        print("VERIFY_AFTER_ACT_PRESENT=\(AppleFMProvider.systemPrompt.contains(BrowserActions.verifyAfterActRule))")

        // THE GATE: the primary arms when Accessibility allows them, the guard
        // and autonomy arms always. A skipped primary arm cannot pass by default.
        let primaryOK = realClickPossible ? (clickDelivered && typedMatched) : true
        let gate = primaryOK && rejected && seamCorrect && rejectedScheme
            && sendAutonomous && navAutonomous && typeAutonomous
            && AppleFMProvider.systemPrompt.contains(BrowserActions.verifyAfterActRule)
        print("ACTIONS_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("ACTIONS_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// The pid-click probe's button target: bumping a counter is the whole action.
/// A real `@objc` action, so the probe asserts the EFFECT (the action fired),
/// never that an event was merely posted.
@MainActor
private final class PidClickCounter: NSObject {
    var value = 0
    @objc func bump(_ sender: Any?) { value += 1 }
}

/// `--test-pid-click`: THE CURSORLESS CLICK, asserted by EFFECT.
///
/// The probe stands up its OWN borderless window with a button whose action
/// bumps a counter, resolves that window through `CGWindowList` (the same lookup
/// shape as `clickTargetWindow`, but INCLUDING own pid — `postClickToWindow` is
/// called directly, bypassing `click`'s own-process exclusion), pid-clicks the
/// button's centre, pumps the run loop, and asserts the counter incremented.
/// A posted-but-dropped event (the Brave double-miss) FAILS here, because the
/// assertion is the action, not the post.
@MainActor
private func runPidClickProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)

    let counter = PidClickCounter()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let button = NSButton(frame: NSRect(x: 100, y: 60, width: 120, height: 40))
    button.title = "poke"
    button.bezelStyle = .rounded
    button.target = counter
    button.action = #selector(PidClickCounter.bump(_:))
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    window.contentView?.addSubview(button)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()

    Task { @MainActor in
        // Let AppKit realize the window and assign its CGWindowID.
        try? await Task.sleep(for: .milliseconds(300))

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonOnScreen = window.convertToScreen(buttonInWindow)
        let quartzPoint = CGPoint(
            x: buttonOnScreen.midX,
            y: primaryHeight - buttonOnScreen.midY
        )

        // Resolve our OWN window through CGWindowList — same shape as
        // `clickTargetWindow`, but including our pid.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var resolved: (pid: pid_t, windowNumber: Int, bounds: CGRect)?
        if let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for info in list {
                guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      owner == ownPid,
                      let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                      let boundsRaw = info[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: boundsRaw as CFDictionary),
                      bounds.contains(quartzPoint)
                else { continue }
                resolved = (owner, number, bounds)
                break
            }
        }
        guard let target = resolved else {
            print("PID_CLICK_GATE=false reason=no-window")
            fflush(stdout)
            exit(1)
        }

        let posted = BrowserActions.postClickToWindow(
            pid: target.pid, windowNumber: target.windowNumber,
            at: quartzPoint, windowBounds: target.bounds
        )

        // Pump ~1s for delivery + the button action to fire.
        try? await Task.sleep(for: .seconds(1))

        let gate = counter.value == 1
        print("PID_CLICK_GATE=\(gate)")
        print("PID_CLICK_POSTED=\(posted) count=\(counter.value)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        print("PID_CLICK_GATE=false reason=timeout")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// A mutable box for the launcher seam's argv, written from a `@Sendable`
/// closure, so the probe does not mutate a captured `var` across actors.
final class ArgvBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var value: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ argv: [String]) { lock.lock(); storage = argv; lock.unlock() }
}

/// Counts posted events so a guard/deny arm can prove NOTHING was delivered.
/// Locked rather than main-actor isolated: it is written from the event sink,
/// which is not on the main actor.
final class BrowserEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var returns = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    /// How many RETURN keypresses (keycode 36) were posted — the transmit that
    /// only an approved send may produce.
    var returnCount: Int { lock.lock(); defer { lock.unlock() }; return returns }
    func record(_ event: CGEvent) {
        lock.lock()
        value += 1
        if event.getIntegerValueField(.keyboardEventKeycode) == 36 { returns += 1 }
        lock.unlock()
    }
    func reset() { lock.lock(); value = 0; returns = 0; lock.unlock() }
}

/// What the probe OBSERVED, never what it decided. Every field is written by
/// the app's own render path so a gate cannot pass against a reconstruction
/// that happens to agree with itself.
@MainActor
final class PlanProbeCollector {
    private(set) var planUpdateCalls = 0
    /// How many times a plan block was pushed.
    private(set) var pushCount = 0
    /// The DISTINCT block keys pushed: what the user actually ends up with on
    /// screen, since the page rewrites a block it already has.
    private(set) var pushedBlockIDs: Set<String> = []
    private(set) var lastPlanLines: [String] = []
    private(set) var toolNames: [String] = []
    /// Everything after the cap-probe marker, so the second turn's tool calls
    /// cannot be confused with the first turn's.
    private(set) var toolNamesAfterMarker: [String] = []
    private var markerIndex: Int?

    func record(_ outcome: ToolRoundOutcome) {
        toolNames.append(outcome.name)
        if markerIndex != nil { toolNamesAfterMarker.append(outcome.name) }
        if outcome.name == "plan_update" { planUpdateCalls += 1 }
    }

    /// ONE call per update, recording the block's KEY — not just that a push
    /// happened. `pushedBlockIDs` is what the user ends up with on screen: the
    /// page keys each block by `id` and rewrites the one it already has, so two
    /// updates of the SAME id are one visible block, while two ids would be two
    /// blocks stacked under each other. Counting pushes instead would prove
    /// nothing about what the transcript shows.
    func pushPlanBlock(id: String, lines: [String]) {
        pushedBlockIDs.insert(id)
        pushCount += 1
        lastPlanLines = lines
    }

    func markRoundCapPhase() {
        markerIndex = toolNames.count
        toolNamesAfterMarker = []
    }
}

/// A SCRIPTED provider: deterministic, no model, no network.
///
/// `ScriptedPlanProvider()` plays the four-round plan script. `everyRound: true`
/// plays the loop-forever script the round-cap arm needs. Emits `.toolCall` and
/// does NOT execute tools itself, so `AgentLoop` runs them — the same path the
/// OpenAI-shaped transport takes.
struct ScriptedPlanProvider: ModelProvider {
    var isHealthy: Bool { true }
    var unhealthyReason: String { "" }
    /// FALSE on purpose: the loop must execute these tools, exactly as it does
    /// for the OpenAI-shaped path.
    var executesToolsNatively: Bool { false }

    let everyRound: Bool

    init(everyRound: Bool = false) {
        self.everyRound = everyRound
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// ONE counter PER PROVIDER, not per stream: `AgentLoop` calls `stream`
    /// again for the next round, and a per-call counter restarted the script
    /// at round 1 every time — which would have "passed" a loop that never
    /// advanced at all.
    private let round = Counter()

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                let index = round.next()
                if everyRound {
                    // Never stops asking. The round cap is the only thing that
                    // can end this turn, so the probe measures the cap.
                    continuation.yield(.toolCall(
                        id: "call_loop_\(index)",
                        name: "plan_update",
                        arguments: .object([
                            "status": .string("\(index) running: looping")
                        ])
                    ))
                    continuation.finish()
                    return
                }
                switch index {
                case 1:
                    continuation.yield(.toolCall(
                        id: "call_plan_1",
                        name: "plan_update",
                        arguments: .object([
                            "steps": .string(
                                "find the window with the message | read it | report what it says"
                            )
                        ])
                    ))
                    continuation.finish()
                case 2:
                    continuation.yield(.toolCall(
                        id: "call_read_2",
                        name: "screen_read",
                        arguments: .object([:])
                    ))
                    continuation.finish()
                case 3:
                    continuation.yield(.toolCall(
                        id: "call_plan_3",
                        name: "plan_update",
                        arguments: .object([
                            "status": .string(
                                "1 done, 2 done, 3 blocked: the tab with the message is not in front"
                            ),
                            "ready": .string("true")
                        ])
                    ))
                    continuation.finish()
                default:
                    // THE ANSWER OVER A BLOCKED STEP. It says what is done,
                    // what is blocked and why — the shape `PlanTrace.verifyRule`
                    // demands. Asserted mechanically by the probe, so the gate
                    // cannot be satisfied by the rule text alone.
                    continuation.yield(.done("""
                        Steps 1 and 2 are done: I found the windows and read what \
                        is visible in them. Step 3 is blocked: the tab with the \
                        message from PATRICK_7 is not the one in front, so I \
                        cannot see what they wrote. Bring that tab forward and \
                        ask again.
                        """))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `ScriptedWalkthroughProvider` plays the end-to-end tab-read journey: raise a
/// buried tab, click a read line, re-read, answer. `mode: .blocked` plays the
/// honest-failure journey: the tab cannot be raised, so the turn must say which
/// step is blocked and must NOT reach for the web. `mode: .planExec` plays the
/// whole-plan send journey: ONE `plan_update` carries raise/click/type+send/read
/// and the executor runs them with no model round between steps, then composes.
/// `mode: .planExecFail` blocks a step (an out-of-bounds click) so exactly one
/// adaptation round follows.
struct ScriptedWalkthroughProvider: ModelProvider {
    enum Mode { case journey, blocked, planExec, planExecFail }

    var isHealthy: Bool { true }
    var unhealthyReason: String { "" }
    /// FALSE on purpose: the loop executes these tools, exactly as the
    /// OpenAI-shaped path does.
    var executesToolsNatively: Bool { false }

    let mode: Mode

    /// Ordered record of provider calls, so a probe can prove the working
    /// indicator fired BEFORE the first call and that a verified action ended
    /// with NO second call. `nil` in every arm that does not measure ordering.
    var timeline: ProbeTimeline? = nil

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
    private let round = Counter()

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let index = round.next()
                timeline?.note("provider_call \(mode) \(index)")
                switch (mode, index) {
                case (.journey, 1):
                    continuation.yield(.toolCall(
                        id: "wt_raise_1",
                        name: "browser_focus_tab",
                        arguments: .object(["query": .string("fixture")])
                    ))
                    continuation.finish()
                case (.journey, 2):
                    continuation.yield(.toolCall(
                        id: "wt_click_2",
                        name: "ui_click",
                        arguments: .object(["x": .number(350), "y": .number(230)])
                    ))
                    continuation.finish()
                case (.journey, 3):
                    continuation.yield(.toolCall(
                        id: "wt_read_3",
                        name: "screen_read",
                        arguments: .object([:])
                    ))
                    continuation.finish()
                case (.journey, _):
                    continuation.yield(.done("The fixture tab says: Fixture line text."))
                    continuation.finish()
                case (.blocked, 1):
                    continuation.yield(.toolCall(
                        id: "wt_raise_b1",
                        name: "browser_focus_tab",
                        arguments: .object(["query": .string("fixture")])
                    ))
                    continuation.finish()
                case (.blocked, _):
                    continuation.yield(.done("""
                        Step 1 is blocked: no tab matching the fixture is open, so \
                        I could not raise or read it. I did not answer from the web.
                        """))
                    continuation.finish()
                case (.planExec, 1):
                    // THE WHOLE PLAN IN ONE CALL: ordered steps with complete
                    // arguments. The executor runs them with no model round in
                    // between; there is no send card.
                    continuation.yield(.toolCall(
                        id: "wt_plan_exec_1",
                        name: "plan_update",
                        arguments: .object([
                            "steps": .string(
                                "raise the fixture tab | click the compose box | type and send | verify"
                            ),
                            "run": .string("""
                            [{"label":"raise the fixture tab","tool":"browser_focus_tab","arguments":{"query":"fixture"}},
                             {"label":"click the compose box","tool":"ui_click","arguments":{"x":350,"y":230}},
                             {"label":"type and send","tool":"ui_type","arguments":{"text":"hi\\n"}},
                             {"label":"verify","tool":"screen_read","arguments":{}}]
                            """)
                        ])
                    ))
                    continuation.finish()
                case (.planExec, _):
                    continuation.yield(.done("Sent: hi"))
                    continuation.finish()
                case (.planExecFail, 1):
                    // Step 2 is an out-of-bounds click: the window-bounds guard
                    // refuses it, so the executor stops and the model is asked
                    // ONCE to explain the blocked step.
                    continuation.yield(.toolCall(
                        id: "wt_plan_fail_1",
                        name: "plan_update",
                        arguments: .object([
                            "steps": .string(
                                "raise the fixture tab | click the compose box"
                            ),
                            "run": .string("""
                            [{"label":"raise the fixture tab","tool":"browser_focus_tab","arguments":{"query":"fixture"}},
                             {"label":"click the compose box","tool":"ui_click","arguments":{"x":9000,"y":9000}}]
                            """)
                        ])
                    ))
                    continuation.finish()
                case (.planExecFail, _):
                    continuation.yield(.done("""
                        Step 2 is blocked: the click landed outside the browser \
                        window, so I stopped and nothing was sent.
                        """))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pay the model's cold-load cost before the user ever types.
///
/// The complaint this fixes is "hi pop, then nothing": the very first stream
/// opens while the on-device model is still loading, so the composer sits empty
/// with no error and no sign of life. One throwaway generation 8s after launch
/// absorbs that cost.
///
/// The result is DISCARDED at every level — no transcript append, no session
/// history, no UI push, no mascot announcement — because this is not a message,
/// it is a preheat. Nothing here reaches the user.
private func runModelWarmup() {
    Task.detached(priority: .utility) {
        do {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }

            let config = (try? PopConfig.load()) ?? .defaults
            let provider = ChatController.makeProvider(config)
            let messages = [ChatMessage(role: .user, text: "Reply with exactly: ok")]
            let options = GenerationOptions(temperature: config.temperature)

            // No tools on a warmup: it is a preheat, not a turn, and a tool
            // schema in the request would make the measured cold cost depend on
            // the tool set.
            for try await _ in provider.stream(
                messages: messages,
                options: options,
                tools: [],
                activity: nil
            ) {
                // Any token at all means the model is loaded. The text is
                // dropped on the floor.
            }
            print("MODEL_WARMUP=done")
            fflush(stdout)
        } catch {
            // One line, no stack, no user-facing surface: a failed warmup is
            // not fatal, the next real request just pays the cold load itself.
            print("MODEL_WARMUP=failed \(error)")
            fflush(stdout)
        }
    }
}

/// Extracts the `--test-chat "<prompt>"` payload, or nil when the flag is absent.
///
/// Written by hand rather than via a parser dependency: the project invariant is
/// zero third-party packages.
private func chatProbePrompt() -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--test-chat") else { return nil }
    let next = CommandLine.arguments.index(after: index)
    guard next < CommandLine.arguments.endIndex else { return "" }
    return CommandLine.arguments[next]
}

/// Headless end-to-end model probe: config -> provider -> streamed tokens ->
/// transcript on disk -> transcript reloaded.
///
/// Prints `CHAT_DELTA` per token and `CHAT_DONE <length>` at the end; the length
/// (not the text) is the gate, because the text is model output, not Pop's
/// correctness.
@MainActor
private func runChatProbe(prompt: String) {
    print("PROBE_HEADLESS")
    fflush(stdout)

    let config: PopConfig
    do {
        config = try PopConfig.load()
    } catch {
        print("CONFIG_ERROR \(error)")
        fflush(stdout)
        exit(1)
    }
    print("CONFIG provider=\(config.provider) model=\(config.model) temperature=\(config.temperature) pcc=\(config.pcc)")
    fflush(stdout)

    let provider: ModelProvider
    switch config.provider {
    case "apple-fm":
        if #available(macOS 26.0, *) {
            provider = AppleFMProvider(pcc: config.pcc)
        } else {
            print("FM_UNAVAILABLE requires-macOS-26")
            fflush(stdout)
            exit(2)
        }
    case "openai-compat":
        provider = OpenAICompatProvider.fromConfig(config)
    default:
        print("CONFIG_UNKNOWN_PROVIDER provider=\(config.provider)")
        fflush(stdout)
        exit(1)
    }

    let transcript = TranscriptStore()
    transcript.append(role: .user, text: prompt)

    let messages = [ChatMessage(role: .user, text: prompt)]
    let options = GenerationOptions(temperature: config.temperature)

    // Nothing keeps the process alive here (no `NSApp.run()`), so the main
    // thread parks on a semaphore until the task's `exit(...)` tears the process
    // down. The work runs DETACHED on purpose: a main-actor-inheriting task
    // could never run while the main thread is parked, so it would deadlock.
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        defer { finished.signal() }
        do {
            let (full, events) = try await provider.collectText(messages: messages, options: options)
            let deltas = events.filter { if case .delta = $0 { return true } else { return false } }
            for delta in deltas {
                guard case .delta(let text) = delta else { continue }
                print("CHAT_DELTA \(text)")
                fflush(stdout)
            }
            print("CHAT_DONE \(full.count)")
            fflush(stdout)

            transcript.append(role: .assistant, text: full)
            let reloaded = transcript.loadAll()
            print("TRANSCRIPT_RELOAD count=\(reloaded.count)")
            fflush(stdout)
            exit(0)
        } catch {
            print("CHAT_ERROR \(error)")
            fflush(stdout)
            // The user turn is already on disk; the assistant turn is not,
            // which is exactly what the transcript should show for a failure.
            let reloaded = transcript.loadAll()
            print("TRANSCRIPT_RELOAD count=\(reloaded.count)")
            fflush(stdout)
            exit(1)
        }
    }
    finished.wait()
}

/// `--test-observe`: one measurement pass of every probe, no UI at all.
@MainActor
private func runObserveProbe() {
    // ScreenCaptureKit asserts (CGS_REQUIRE_INIT) if no window-server session
    // exists yet. The real app always has NSApplication before any observation;
    // the probe must stand one up too. No `run()`: only initialisation.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    print("PROBE_HEADLESS")
    fflush(stdout)
    print("PERM_ACCESSIBILITY=\(Permissions.accessibility().rawValue)")
    print("PERM_SCREEN_RECORDING=\(Permissions.screenRecording().rawValue)")
    fflush(stdout)

    Observe.enableManualAXIfChromium(bundleID: Observe.frontmostApp().bundleID)
    let observation = Observe.observeAll()
    print("OBS_APP=\(observation.bundleID) name=\(observation.appName) title=\(observation.windowTitle)")
    print("OBS_URL=\(observation.url ?? "nil")")
    print("OBS_SELECTION=\(observation.selection.map { String($0.count) } ?? "nil")")
    let axSummary: String = observation.axState == .ok
        ? String(observation.axExcerpt.count)
        : observation.axState.rawValue
    print("OBS_AX=\(axSummary)")
    if let shot = observation.screenshot {
        print("OBS_SCREENSHOT=\(shot.width) x \(shot.height) bytes=\(shot.data.count)")
        let frame = shot.windowFrame
            .map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
            ?? "display"
        print("OBS_SCREENSHOT_META windowFrame=\(frame) pixels=\(shot.width) x \(shot.height) scale=\(String(format: "%.2f", shot.scale))")
    } else {
        print("OBS_SCREENSHOT=\(observation.screenshotDenied ? "denied" : "none")")
    }
    if observation.screenshotFellBackToDisplay {
        print("OBS_SCREENSHOT_FALLBACK=display")
    }
    if observation.axState == .ok {
        print("OBS_AX_SAMPLE=\(observation.axExcerpt.prefix(3).joined(separator: " | "))")
    } else {
        print("OBS_AX_SAMPLE=\(observation.axState.rawValue)")
    }
    print("OBS_TIME=\(observation.wallMilliseconds)")
    fflush(stdout)
    exit(0)
}

/// `--test-context <prompt>`: observe -> context block -> the configured model.
@MainActor
private func runContextProbe(prompt: String) {
    // Same reason as --test-observe: observation needs a window-server session.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    print("PROBE_HEADLESS")
    fflush(stdout)

    let observation = Observe.observeAll()
    print("OBS_TIME=\(observation.wallMilliseconds)")
    fflush(stdout)

    let context = Observe.makeContextPrefix(observation)
    print("CONTEXT_CHARS=\(context.count)")
    fflush(stdout)

    let config = (try? PopConfig.load()) ?? .defaults
    var messages = [ChatMessage(role: .user, text: "\(context)\n\nUser: \(prompt)")]
    if let data = observation.screenshot?.data, config.provider != "openai-compat" {
        messages[messages.startIndex].imageData = data
    }

    let finished = DispatchSemaphore(value: 0)
    let provider = ChatController.makeProvider(config)
    Task.detached {
        defer { finished.signal() }
        do {
            let (full, _) = try await provider.collectText(
                messages: messages,
                options: GenerationOptions(temperature: config.temperature)
            )
            print("CHAT_DONE \(full.count)")
            fflush(stdout)
            exit(0)
        } catch {
            print("CHAT_ERROR \(error)")
            fflush(stdout)
            exit(1)
        }
    }
    finished.wait()
}

/// `--test-keychain <secret>`: proves the Keychain write path works for this
/// (possibly unsigned, non-sandboxed) app. Writes, reads back, deletes.
@MainActor
private func runKeychainProbe(secret: String) {
    print("PROBE_HEADLESS")
    fflush(stdout)

    let account = "test-account"
    switch KeychainStore.setAPIKey(secret, for: account) {
    case .failure(let error):
        print("KEYCHAIN_DENIED \(error)")
        fflush(stdout)
        exit(1)
    case .success:
        break
    }

    // `apiKey` uses the UI-suppressed read path with a 10s deadline, so this
    // doubles as the timeout check.
    let readBack = KeychainStore.apiKey(for: account)
    if readBack == secret {
        print("KEYCHAIN_ROUNDTRIP=ok")
    } else {
        print("KEYCHAIN_ROUNDTRIP=mismatch")
    }
    fflush(stdout)

    _ = KeychainStore.deleteAPIKey(for: account)
    print("KEYCHAIN_DELETED \(KeychainStore.apiKey(for: account) == nil)")
    fflush(stdout)
    exit(0)
}

/// `--test-summon`: proves the summon path honors the PERSISTED launcher
/// position, then that dismissing the CHAT leaves the launcher on screen.
///
/// The probe seeds a deliberately non-default frame into the very key
/// `PanelController` restores from, summons through the same `show()` the hotkey
/// uses, reports where the panel landed, then toggles chat-expand and
/// chat-collapse. `TOGGLE_RESULT` is the ambient-visibility gate: the window must
/// still be visible and resting in `bar` after the chat is dismissed.
@MainActor
private func runSummonProbe(
    _ panelController: PanelController,
    seeded: NSPoint?
) {
    // The frame was already seeded before `PanelController` was constructed (see
    // the call site); anything else would restore too late to prove anything.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        // LAUNCH DEFAULT: the robot alone, 110x110, no composer.
        let launch = panelController.panel.frame
        print("SUMMON_PANEL_FRAME=\(Int(launch.origin.x)),\(Int(launch.origin.y)),\(Int(launch.width)),\(Int(launch.height))")
        fflush(stdout)
        if let seeded {
            print("SUMMON_SEEDED=\(Int(seeded.x)),\(Int(seeded.y))")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            panelController.toggle()
            let bar = panelController.panel.frame
            print("SUMMON_BAR_FRAME=\(Int(bar.origin.x)),\(Int(bar.origin.y)),\(Int(bar.width)),\(Int(bar.height))")
            fflush(stdout)

            // THE FOCUS GATE: with the bar up, the caret must be IN the
            // composer. `none` (or a body/div id) means the cursor is not
            // there and typing would go nowhere.
            panelController.appWebView.webView.evaluateJavaScript(
                "(function () { var a = document.activeElement;"
                + " if (!a) { return 'none'; }"
                + " return (a.id || a.getAttribute('data-role') || a.tagName || 'none').toLowerCase(); })()"
            ) { value, _ in
                print("UI_FOCUS=\(value ?? "none")")
                fflush(stdout)
            }

            // `activeElement` only proves the PAGE focused; this asks the OS
            // whether the document actually has window focus.
            panelController.appWebView.webView.evaluateJavaScript(
                "String(!!document.hasFocus())"
            ) { value, _ in
                print("UI_DOCFOCUS=\(value ?? "false")")
                fflush(stdout)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // ⌥Space from `bar` takes the WHOLE window off: bar AND mascot.
                panelController.toggle()
                let back = panelController.panel.frame
                print("SUMMON_MASCOT_FRAME=\(Int(back.origin.x)),\(Int(back.origin.y)),\(Int(back.width)),\(Int(back.height))")
                fflush(stdout)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print(
                        "TOGGLE_RESULT visible=\(panelController.isVisible) state=\(panelController.isVisible ? panelController.state.rawValue : "hidden")"
                    )
                    fflush(stdout)
                    exit(0)
                }
            }
        }
    }

    NSApp.run()
}

/// `--test-visible-reply`: is the reply not merely IN THE DOM but actually shown?
///
/// Every chat probe so far read the DOM, and the DOM is where this bug lived:
/// the user sent a message, the request completed, `UI_CHAT_VALUE` was non-empty
/// from JavaScript — and the panel was blank, because `#bubble` was
/// `display: none`. `getComputedStyle`, `offsetHeight` and `offsetParent` are the
/// questions DOM reads never asked.
///
/// Gates: `VISIBLE_DISPLAY != none`, `VISIBLE_HAS_BOX=true`, `VISIBLE_IN_TREE=true`,
/// `VISIBLE_TURNS >= 2`, `VISIBLE_LAST_TEXT` non-empty, `VISIBLE_LAST_ON_SCREEN=true`,
/// and `VISIBLE_MASKOT_HIDDEN=true` — the launcher requirement, which must survive
/// the fix: mascot state means robot and composer ONLY.
@MainActor
private func runVisibleReplyProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    // ⌘Space: the bar, exactly as the user summons it.
    panelController.show()
    let webView = panelController.appWebView.webView

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        webView.evaluateJavaScript("window.__POP_COMPOSER_V ?? null") { value, _ in
            let version = value as? String ?? ""
            if version.isEmpty {
                print("PAGE_VERSION_MISSING")
            } else {
                print("PAGE_VERSION=\(version)")
            }
            fflush(stdout)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        let js = "document.getElementById('input').value = "
            + jsString("what is today's date?") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("VISIBLE_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        func poll() {
            let streaming = "document.getElementById('stop')"
                + " && !document.getElementById('stop').hidden"
            webView.evaluateJavaScript(streaming) { value, _ in
                let stillStreaming = (value as? Bool) == true
                if !stillStreaming, chatController.deltaCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        measureVisibleReply(panelController: panelController, webView: webView)
                    }
                    return
                }
                if Date() >= deadline {
                    print("VISIBLE_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 110) {
        print("VISIBLE_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// Reads COMPUTED visibility, then hides the panel and reads it again — the
/// launcher requirement in the same run.
@MainActor
private func measureVisibleReply(panelController: PanelController, webView: WKWebView) {
    let measure = "(function () {"
        + "var b = document.getElementById('bubble');"
        + "if (!b) { return 'none|false|false|0||false'; }"
        + "var style = getComputedStyle(b);"
        + "var turns = document.querySelectorAll('#bubble .turn');"
        + "var last = turns.length ? turns[turns.length - 1] : null;"
        + "var text = last ? (last.innerText || '').replace(/\\s+/g, ' ').trim() : '';"
        + "var onScreen = false;"
        + "if (last && b.offsetHeight > 0) {"
        + "  var br = b.getBoundingClientRect();"
        + "  var lr = last.getBoundingClientRect();"
        + "  onScreen = lr.height > 0 && lr.top >= br.top - 1 && lr.bottom <= br.bottom + 1;"
        + "}"
        + "return style.display + '|' + (b.offsetHeight > 0) + '|'"
        + "  + (b.offsetParent !== null) + '|' + turns.length + '|'"
        + "  + text.slice(0, 40) + '|' + onScreen; })()"

    webView.evaluateJavaScript(measure) { value, _ in
        let parts = (value as? String ?? "").split(separator: "|", maxSplits: 5).map(String.init)
        let display = parts.count > 0 ? parts[0] : "none"
        let hasBox = parts.count > 1 ? parts[1] == "true" : false
        let inTree = parts.count > 2 ? parts[2] == "true" : false
        let turns = Int(parts.count > 3 ? parts[3] : "0") ?? 0
        let text = parts.count > 4 ? parts[4] : ""
        let onScreen = parts.count > 5 ? parts[5] == "true" : false
        print("VISIBLE_DISPLAY=\(display)")
        print("VISIBLE_HAS_BOX=\(hasBox)")
        print("VISIBLE_IN_TREE=\(inTree)")
        print("VISIBLE_TURNS=\(turns)")
        print("VISIBLE_LAST_TEXT=\(text)")
        print("VISIBLE_LAST_ON_SCREEN=\(onScreen)")
        fflush(stdout)

        // THE LAUNCHER REQUIREMENT, MEASURED: mascot state must hide the
        // transcript outright. A fix that reveals the chat unconditionally would
        // pass the first six gates and break this product rule.
        panelController.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // The stylesheet itself is measured too: a rule the parser silently
            // dropped cannot be diagnosed from class names alone, and a dropped
            // `body.launcher #bubble` is how a panel ends up blank in one state
            // and not the other.
            let rules = """
            (function () {
              var sheet = document.styleSheets[0];
              if (!sheet) { return 'rules=-1,launcher=missing'; }
              var found = 'no', strong = 'no';
              for (var i = 0; i < sheet.cssRules.length; i++) {
                var rule = sheet.cssRules[i];
                var text = rule.selectorText || '';
                if (text.indexOf('body.launcher') === -1) { continue; }
                found = 'yes';
                if ((rule.cssText || '').indexOf('important') !== -1) { strong = 'yes'; }
              }
              return 'rules=' + sheet.cssRules.length + ',launcher=' + found
                + ',important=' + strong;
            })()
            """
            let hidden = "getComputedStyle(document.getElementById('bubble')).display"
                + " + '|' + document.body.className + '|' + " + rules
            webView.evaluateJavaScript(hidden) { mascotValue, _ in
                let mascotParts = (mascotValue as? String ?? "")
                    .split(separator: "|", maxSplits: 2).map(String.init)
                let mascotHidden = (mascotParts.first ?? "") == "none"
                print("VISIBLE_MASKOT_HIDDEN=\(mascotHidden)")
                // Evidence: which state classes the body actually carries, so a
                // failure names the layer that got it wrong.
                print("VISIBLE_MASKOT_BODY_CLASS=\(mascotParts.count > 1 ? mascotParts[1] : "")")
                print("VISIBLE_STYLESHEET=\(mascotParts.count > 2 ? mascotParts[2] : "")")
                fflush(stdout)
                let gate = display != "none" && hasBox && inTree && turns >= 2
                    && !text.isEmpty && onScreen && mascotHidden
                print("VISIBLE_GATE=\(gate)")
                fflush(stdout)
                exit(gate ? 0 : 1)
            }
        }
    }
}

/// `--test-rendered-visibility`: is the newest answer actually ON SCREEN?
///
/// Every other chat probe reads the DOM, and the DOM is where this bug lived: a
/// finished reply was rendered into a 44pt/128pt slot under the browser pane,
/// every DOM read came back green, and the user saw nothing. Presence in the
/// document is not presence on the screen, so this probe measures RENDERED
/// GEOMETRY \u2014 `getBoundingClientRect` of the last turn against the transcript's
/// own visible box \u2014 with the browser pane genuinely open, opened through the
/// real tool path against a loopback fixture so `body.browser-open` is set by the
/// same code the app uses.
///
/// Gates: `RENDERED_LAST_TURN_VISIBLE=true`, `RENDERED_CLIPPED_PX=0`,
/// `RENDERED_SCROLL_AT_BOTTOM=true`.
@MainActor
private func runRenderedVisibilityProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    panelController.show()
    let webView = panelController.appWebView.webView

    // A loopback fixture, in a temp dir: the browser refuses `file://` by
    // design, and nothing here may reach the public network.
    let root = NSTemporaryDirectory() + "pop-rendered-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )
    _ = try? BrowserFixtures.write(into: URL(fileURLWithPath: root, isDirectory: true))
    let server = FixtureServer(directory: URL(fileURLWithPath: root, isDirectory: true))
    guard let base = server.start() else {
        print("RENDERED_FIXTURE_SERVER_FAILED")
        fflush(stdout)
        exit(1)
    }
    print("RENDERED_FIXTURE_ORIGIN=\(base)")

    // The marker, read from the RUNNING page in the same run.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        webView.evaluateJavaScript("window.__POP_COMPOSER_V ?? null") { value, _ in
            let version = value as? String ?? ""
            if version.isEmpty {
                print("PAGE_VERSION_MISSING")
            } else {
                print("PAGE_VERSION=\(version)")
            }
            fflush(stdout)
        }
    }

    // THE PANE OPENS FIRST, THEN THE QUESTION. That is the user's order (open a
    // page, then ask about it) and it is also what makes the gate mean what it
    // says: the answer is the NEWEST thing in the transcript, so "scrolled to the
    // bottom" and "the newest turn is fully on screen" are the same claim.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        Task { @MainActor in
            let opened = await ToolRegistry.execute(("browser_navigate", .object([
                "url": .string(base + "/form.html")
            ])))
            let browserOK = !opened.hasPrefix("ERROR")
            print("RENDERED_BROWSER_NAVIGATED=\(browserOK)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                sendThenMeasure(
                    webView: webView,
                    chatController: chatController
                )
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 110) {
        print("RENDERED_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// The send half of the probe, then the measurement. Split out because the pane
/// has to be open before the question is asked.
@MainActor
private func sendThenMeasure(webView: WKWebView, chatController: ChatController) {
    // Scheduled rather than run inline: `poll` is a LOCAL function, and only
    // inside a `@Sendable` closure is handing one to another `@Sendable`
    // closure legal. Running the body inline warns on that capture.
    DispatchQueue.main.async {
    // A SHORT answer on purpose: the gate is "the newest turn is fully inside
        // the visible box", which a reply taller than the box could never satisfy.
        // A short answer is exactly what used to vanish into the 44pt slot.
        let js = "document.getElementById('input').value = "
            + jsString("what is today's date?") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("RENDERED_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        func poll() {
            let streaming = "document.getElementById('stop')"
                + " && !document.getElementById('stop').hidden"
            webView.evaluateJavaScript(streaming) { value, _ in
                let stillStreaming = (value as? Bool) == true
                if !stillStreaming, chatController.deltaCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        measureRenderedTranscript(webView: webView)
                    }
                    return
                }
                if Date() >= deadline {
                    print("RENDERED_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }
}

/// Measures the transcript's RENDERED geometry: the last turn's rect against the
/// container's own visible box, plus the scroll numbers that produced it.
///
/// The measured element is the last ASSISTANT turn — the answer — because
/// that is what the user is trying to read.
@MainActor
private func measureRenderedTranscript(webView: WKWebView) {
    // The page's layout settles a frame or two after `chatDone`.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let check = "(function () {"
            + "var b = document.getElementById('bubble');"
            + "var turns = document.querySelectorAll('#bubble .turn.assistant');"
            + "if (!b || !turns.length) { return 'missing|missing|missing'; }"
            + "var last = turns[turns.length - 1];"
            + "var br = b.getBoundingClientRect();"
            + "var lr = last.getBoundingClientRect();"
            + "var above = Math.max(0, Math.round(br.top - lr.top));"
            + "var below = Math.max(0, Math.round(lr.bottom - br.bottom));"
            + "var clipped = above + below;"
            + "var atBottom = Math.abs(b.scrollHeight - b.clientHeight - b.scrollTop) <= 2;"
            + "var open = document.body.className.indexOf('browser-open') !== -1;"
            + "return (clipped === 0) + '|' + clipped + '|' + atBottom + '|' + open"
            + "  + '|' + Math.round(br.height) + '|' + Math.round(lr.height)"
            + "  + '|' + Math.round(br.top) + ',' + Math.round(br.bottom)"
            + "  + '|' + Math.round(lr.top) + ',' + Math.round(lr.bottom)"
            + "  + '|' + b.clientHeight + ',' + b.scrollHeight + ',' + b.scrollTop; })()"
        webView.evaluateJavaScript(check) { value, _ in
            let parts = (value as? String ?? "").split(separator: "|").map(String.init)
            guard parts.count >= 4 else {
                print("RENDERED_MEASURE_FAILED")
                fflush(stdout)
                exit(1)
            }
            let visible = parts[0] == "true"
            let clipped = Int(parts[1]) ?? -1
            let atBottom = parts[2] == "true"
            let browserOpen = parts[3] == "true"
            print("RENDERED_LAST_TURN_VISIBLE=\(visible)")
            print("RENDERED_CLIPPED_PX=\(clipped)")
            print("RENDERED_SCROLL_AT_BOTTOM=\(atBottom)")
            // Evidence, not gate: proves the pane really was open (the class the
            // app sets) and shows the box the answer had to fit inside.
            print("RENDERED_BROWSER_OPEN=\(browserOpen)")
            print("RENDERED_BOX_PX=\(parts.count > 4 ? parts[4] : "?")")
            print("RENDERED_LAST_TURN_PX=\(parts.count > 5 ? parts[5] : "?")")
            print("RENDERED_BOX_RECT=\(parts.count > 6 ? parts[6] : "?")")
            print("RENDERED_TURN_RECT=\(parts.count > 7 ? parts[7] : "?")")
            print("RENDERED_SCROLL_NUMBERS=\(parts.count > 8 ? parts[8] : "?")")
            fflush(stdout)
            exit(visible && clipped == 0 && atBottom ? 0 : 1)
        }
    }
}

// MARK: - Spike T: the USER'S REAL STATE
//
// Every earlier chat probe measured a DIFFERENT APP from the one the user
// runs. They all launched with no browser pane, so `body.browser-open` was
// never set, so the transcript layout under the browser band was never
// exercised — and two whole rounds of "green" fixes shipped against a
// configuration the user never sees. The user's live session has a restored
// browser pane, the panel in `full`, and the panel showed an EMPTY rounded
// rectangle: no question, no answer, while the log said
// `TRANSCRIPT_VISIBILITY=visible`.
//
// So this probe reproduces the REAL state and nothing else:
//   1. an isolated temp session root (set by the `--test-` prefix above),
//   2. ONE seeded session RESTORED through `ChatController.openSession`, so
//      the restore path runs exactly as it does for the user,
//   3. a REAL browser open through `ToolRegistry`'s `browser_navigate` against
//      a loopback fixture — the app sets `body.browser-open`, never this probe,
//   4. the panel driven to `full` the way Swift does it,
//   5. ONE real send, and then GEOMETRY: where every turn actually is.
///
/// The measurement half is the whole point. `ensureTranscriptVisible` only
/// asked whether `#bubble` was `display: none`, which is why a page could
/// report `visible` while the user looked at an empty box.

/// `--test-real-state-diagnose` / `--test-real-state-gate`: the user's state.
@MainActor
private func runRealStateProbe(
    gate: Bool,
    panelController: PanelController,
    chatController: ChatController
) {
    let tag = gate ? "GATE" : "DIAG"
    panelController.show()
    let webView = panelController.appWebView.webView

    // An isolated fixture root for the browser, and the loopback server the
    // browser probes use. Nothing here can reach the network.
    let root = NSTemporaryDirectory() + "pop-realstate-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )
    _ = try? BrowserFixtures.write(into: URL(fileURLWithPath: root, isDirectory: true))
    let server = FixtureServer(directory: URL(fileURLWithPath: root, isDirectory: true))
    guard let base = server.start() else {
        print("\(tag)_FIXTURE_SERVER_FAILED")
        fflush(stdout)
        exit(1)
    }

    // SEED ONE RESTORED SESSION. Written into the SAME isolated root
    // `SessionStore` reads (the `--test-` prefix set `POP_SESSIONS_PATH`
    // before any store existed), then opened through `openSession` — the real
    // restore path, not a hand-built DOM.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let store = SessionStore()
        let session = store.startSession()
        store.append(
            TranscriptStore.Entry(
                ts: Date().timeIntervalSince1970 - 120,
                role: ChatMessage.Role.user.rawValue,
                text: "earlier question from a previous session"
            ),
            to: session.id
        )
        store.append(
            TranscriptStore.Entry(
                ts: Date().timeIntervalSince1970 - 60,
                role: ChatMessage.Role.assistant.rawValue,
                text: "earlier answer, restored from the session file"
            ),
            to: session.id
        )
        let restored = chatController.openSession(session.id)
        print("\(tag)_RESTORED_TURNS=\(restored)")
        fflush(stdout)
    }

    // THE PANE OPENS THROUGH THE REAL TOOL, exactly as it does for the user.
    // `body.browser-open` is set by the APP (ChatController pushes the browser
    // state to the page), never by this probe — if the class does not appear,
    // that is the finding, not something to paper over.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        Task { @MainActor in
            let opened = await ToolRegistry.execute(("browser_navigate", .object([
                "url": .string(base + "/form.html")
            ])))
            print("\(tag)_BROWSER_NAVIGATED=\(!opened.hasPrefix("ERROR"))")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                realStateSendThenMeasure(
                    tag: tag,
                    gate: gate,
                    panelController: panelController,
                    chatController: chatController,
                    webView: webView,
                    // In gate mode the browser-active measurement is only HALF
                    // the verdict: the never-navigated state is measured by a
                    // fresh process once this one has finished.
                    onGateResult: gate
                        ? { activePass in runNonNavigatedPhase(activePass: activePass) }
                        : nil
                )
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
        print("\(tag)_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// Sends ONE real message through the composer, waits for the stream to end,
/// then measures the rendered geometry.
@MainActor
private func realStateSendThenMeasure(
    tag: String,
    gate: Bool,
    panelController: PanelController,
    chatController: ChatController,
    webView: WKWebView,
    onGateResult: ((Bool) -> Void)? = nil
) {
    // The user does not tap anything here. The only thing that has happened is
    // a browser open and a send.
    print("\(tag)_PANEL_STATE=\(panelController.state.rawValue)")
    fflush(stdout)

    DispatchQueue.main.async {
        let js = "document.getElementById('input').value = "
            + jsString("what is today's date?") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("\(tag)_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        func poll() {
            let streaming = "document.getElementById('stop')"
                + " && !document.getElementById('stop').hidden"
            webView.evaluateJavaScript(streaming) { value, _ in
                let stillStreaming = (value as? Bool) == true
                if !stillStreaming, chatController.deltaCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        measureRealState(
                            tag: tag,
                            gate: gate,
                            panelController: panelController,
                            webView: webView,
                            onGateResult: onGateResult
                        )
                    }
                    return
                }
                if Date() >= deadline {
                    print("\(tag)_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }
}

/// The measurement. One `evaluateJavaScript`, one JSON blob back, every number
/// the diagnosis needs printed on its own line.
///
/// What each question is FOR:
/// - `BUBBLE_DISPLAY` is the check that lied for three rounds.
/// - `BUBBLE_IN_VIEWPORT` asks whether the transcript box is inside the panel's
///   frame at all.
/// - `TURNS_VISIBLE` counts turns that intersect the bubble's own visible clip
///   AND lie inside the panel rect — presence in the DOM is not presence on
///   screen, and this is the difference.
/// - `LAST_ON_SCREEN` is the answer the user is trying to read.
/// - `ELEMENT_FROM_POINT` distinguishes "the element is there" from "something
///   is painted on top of it".
@MainActor
private func measureRealState(
    tag: String,
    gate: Bool,
    panelController: PanelController,
    webView: WKWebView,
    onGateResult: ((Bool) -> Void)? = nil
) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let check = #"""
        (function () {
          var bubble = document.getElementById('bubble');
          var spacer = document.getElementById('browserSpacer');
          var strip = document.getElementById('browserStrip');
          var panel = document.documentElement.getBoundingClientRect();
          function rect(el) {
            if (!el) { return null; }
            var r = el.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
          }
          function fmt(r) { return r ? (r.x + ',' + r.y + ',' + r.w + ',' + r.h) : 'none'; }
          var out = {};
          out.bodyClass = document.body.className;
          out.browserOpen = document.body.classList.contains('browser-open');
          out.panelH = Math.round(panel.height);
          out.bubbleDisplay = bubble ? getComputedStyle(bubble).display : 'missing';
          var br = rect(bubble);
          out.bubbleRect = fmt(br);
          out.bubbleInViewport = !!(br && br.h > 0 && br.y >= -1
            && br.y + br.h <= panel.height + 1);
          out.stripDisplay = strip ? getComputedStyle(strip).display : 'missing';
          out.stripRect = fmt(rect(strip));
          out.spacerRect = fmt(rect(spacer));

          var turns = [].slice.call(document.querySelectorAll('#bubble .turn'));
          out.turns = turns.length;
          // VISIBLE = the turn's rect intersects the bubble's visible clip and
          // lies inside the panel. A turn rendered into a slot it does not
          // occupy is in the DOM and nowhere else.
          var clip = null;
          if (br) { clip = { top: Math.max(br.y, 0), bottom: Math.min(br.y + br.h, panel.height) }; }
          var visible = 0;
          var last = null;
          for (var i = 0; i < turns.length; i++) {
            var t = turns[i].getBoundingClientRect();
            if (clip) {
              var top = Math.max(t.top, clip.top);
              var bottom = Math.min(t.bottom, clip.bottom);
              if (bottom - top > 0 && t.height > 0) { visible++; }
            }
            last = turns[i];
          }
          out.turnsVisible = visible;
          out.lastText = last ? ((last.innerText || '').replace(/\s+/g, ' ').trim()).slice(0, 40) : '';
          // What the page's OWN visibility check concluded. Recorded by
          // `ensureTranscriptVisible`, so the gate compares the page's verdict
          // against the geometry instead of trusting it.
          out.lastVisibility = window.__popLastVisibility || '';
          var lr = rect(last);
          out.lastRect = fmt(lr);
          out.lastOnScreen = !!(lr && clip && lr.h > 0
            && lr.y >= clip.top - 1 && lr.y + lr.h <= clip.bottom + 1
            && lr.y >= -1 && lr.y + lr.h <= panel.height + 1);
          // Is the last turn actually the thing painted where it claims to be?
          out.elementFromPoint = 'none';
          if (lr && lr.w > 0 && lr.h > 0) {
            var cx = lr.x + Math.round(lr.w / 2);
            var cy = lr.y + Math.round(lr.h / 2);
            if (cx >= 0 && cx < panel.width && cy >= 0 && cy < panel.height) {
              var el = document.elementFromPoint(cx, cy);
              if (el) {
                out.elementFromPoint = (el.id ? '#' + el.id : '.')
                  + (el.className ? '.' + String(el.className).replace(/\s+/g, '.') : '');
              }
            } else { out.elementFromPoint = 'offscreen'; }
          }
          return JSON.stringify(out);
        })()
        """#

        webView.evaluateJavaScript(check) { value, error in
            if let error {
                print("\(tag)_MEASURE_ERROR \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("\(tag)_MEASURE_FAILED raw=\(String(describing: value))")
                fflush(stdout)
                exit(1)
            }

            func str(_ key: String) -> String {
                (dict[key] as? String) ?? "?"
            }
            func bool(_ key: String) -> Bool { (dict[key] as? Bool) == true }
            func num(_ key: String) -> Int { (dict[key] as? Int) ?? -1 }

            let browserOpen = bool("browserOpen")
            let turns = num("turns")
            let turnsVisible = num("turnsVisible")
            let lastOnScreen = bool("lastOnScreen")
            let lastText = str("lastText")
            let bubbleInViewport = bool("bubbleInViewport")
            let pageSays = str("lastVisibility")

            print("\(tag)_BODY_CLASS=\(str("bodyClass"))")
            print("\(tag)_BROWSER_OPEN=\(browserOpen)")
            print("\(tag)_PANEL_H=\(num("panelH"))")
            print("\(tag)_BUBBLE_DISPLAY=\(str("bubbleDisplay"))")
            print("\(tag)_BUBBLE_RECT=\(str("bubbleRect"))")
            print("\(tag)_BUBBLE_IN_VIEWPORT=\(bubbleInViewport)")
            print("\(tag)_STRIP_DISPLAY=\(str("stripDisplay"))")
            print("\(tag)_STRIP_RECT=\(str("stripRect"))")
            print("\(tag)_SPACER_RECT=\(str("spacerRect"))")
            print("\(tag)_TURNS=\(turns)")
            print("\(tag)_TURNS_VISIBLE=\(turnsVisible)")
            print("\(tag)_LAST_TEXT=\(lastText)")
            print("\(tag)_LAST_RECT=\(str("lastRect"))")
            print("\(tag)_LAST_ON_SCREEN=\(lastOnScreen)")
            print("\(tag)_ELEMENT_FROM_POINT=\(str("elementFromPoint"))")
            print("\(tag)_PAGE_SAYS=\(pageSays)")
            print("\(tag)_PANEL_STATE=\(panelController.state.rawValue)")
            // NATIVE GEOMETRY. The browser pane is a real NSView stacked OVER
            // the top of the web view, so the page cannot see it: no rect, no
            // `elementFromPoint`, nothing. Every page-side probe so far has
            // therefore measured a box the pane may be sitting on top of.
            // Swift is the only side that can be asked.
            let pane = BrowserController.shared.paneView
            let web = panelController.appWebView
            let paneHidden = pane.isHidden || pane.window == nil
            // Page coordinates: the web view's top edge is page y = 0, and the
            // pane is pinned to the top of the web region.
            let paneBandBottom = paneHidden ? 0 : BrowserController.paneHeight
            print("\(tag)_PANE_VISIBLE=\(!paneHidden)")
            print("\(tag)_PANE_BAND_BOTTOM=\(Int(paneBandBottom))")
            print("\(tag)_WEB_HEIGHT=\(Int(web.frame.height))")
            // The share of the panel the transcript actually gets, and whether
            // any of it lands UNDER the pane.
            // The rect is printed as x,y,w,h — the bubble's TOP is the second field.
            let rectParts = str("bubbleRect").split(separator: ",").map(String.init)
            let bubbleTop = rectParts.count > 1 ? (Double(rectParts[1]) ?? -1) : -1
            let bubbleH = rectParts.count > 3 ? (Double(rectParts[3]) ?? 0) : 0
            let occluded = !paneHidden && bubbleTop < paneBandBottom
            print("\(tag)_BUBBLE_UNDER_PANE=\(occluded)")
            let sharePct = web.frame.height > 0
                ? Int((bubbleH / web.frame.height) * 100)
                : -1
            print("\(tag)_TRANSCRIPT_SHARE_PCT=\(sharePct)")
            fflush(stdout)

            if !gate {
                // The diagnose probe REPORTS; it does not gate. It has to be
                // runnable against a broken page, which is the whole point.
                let reproduced = turns >= 2 && turnsVisible >= 2
                    && lastOnScreen && browserOpen
                print("\(tag)_GATE_PASS=\(reproduced)")
                fflush(stdout)
                exit(0)
            }

            // The honesty gate: a page that says `visible` while nothing is on
            // screen is the defect that hid this bug for three rounds.
            let honest = pageSays == "visible" && lastOnScreen
            print("\(tag)_TRANSCRIPT_VISIBILITY_HONEST=\(honest)")
            let pass = browserOpen && turnsVisible >= 2 && lastOnScreen
                && honest && !lastText.isEmpty
            print("\(tag)_ACTUALLY_ON_SCREEN=\(lastOnScreen)")
            print("\(tag)_PASS=\(pass)")
            fflush(stdout)
            if let onGateResult {
                onGateResult(pass)
            } else {
                exit(pass ? 0 : 1)
            }
        }
    }
}

/// THE SECOND HALF OF `--test-real-state-gate`: the state that actually broke.
///
/// The browser-active measurement has just finished. This spawns a FRESH copy
/// of this executable with `--test-real-state-nonav`, because the shared
/// `BrowserController` can only ever go active — nothing calls
/// `setState(active:false)` — so a process that has navigated can never
/// reproduce "panel `full` with the browser never opened". Both halves must
/// pass; if the child cannot be run, the gate FAILS rather than passing on the
/// half it happened to measure.
@MainActor
private func runNonNavigatedPhase(activePass: Bool) {
    func finish(_ nonNavPass: Bool) {
        print("GATE_ACTIVE_PASS=\(activePass)")
        print("GATE_NONAV_CHILD_PASS=\(nonNavPass)")
        let pass = activePass && nonNavPass
        print("GATE_COMBINED_PASS=\(pass)")
        fflush(stdout)
        exit(pass ? 0 : 1)
    }
    guard let exe = Bundle.main.executablePath else {
        print("GATE_NONAV_CHILD_FAILED=no-executable")
        fflush(stdout)
        finish(false)
        return
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = ["--test-real-state-nonav"]
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError = FileHandle.standardError
    print("GATE_NONAV_CHILD_START exe=\(exe)")
    fflush(stdout)
    do {
        try proc.run()
        proc.waitUntilExit()
        finish(proc.terminationStatus == 0)
    } catch {
        print("GATE_NONAV_CHILD_FAILED=\(error.localizedDescription)")
        fflush(stdout)
        finish(false)
    }
}

/// `--test-real-state-nonav` (child of the gate): restore a session, take the
/// panel to `full`, send ONE real message — and NEVER navigate. This is the
/// discriminating state; see the gate's doc comment.
@MainActor
private func runNonNavigatedProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    panelController.show()
    let webView = panelController.appWebView.webView

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let store = SessionStore()
        let session = store.startSession()
        store.append(
            TranscriptStore.Entry(
                ts: Date().timeIntervalSince1970 - 120,
                role: ChatMessage.Role.user.rawValue,
                text: "earlier question from a previous session"
            ),
            to: session.id
        )
        store.append(
            TranscriptStore.Entry(
                ts: Date().timeIntervalSince1970 - 60,
                role: ChatMessage.Role.assistant.rawValue,
                text: "earlier answer, restored from the session file"
            ),
            to: session.id
        )
        let restored = chatController.openSession(session.id)
        print("GATE_NONAV_RESTORED_TURNS=\(restored)")
        fflush(stdout)
        // FULL, RESTORED, NEVER NAVIGATED. `openSession` already asked for
        // `full`; this makes it deterministic and still touches no browser.
        panelController.setPanelState(.full, animated: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            nonNavSendThenMeasure(
                panelController: panelController,
                chatController: chatController,
                webView: webView
            )
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
        print("GATE_NONAV_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// Sends one real message from the never-navigated state and waits for the
/// stream to end, then measures.
@MainActor
private func nonNavSendThenMeasure(
    panelController: PanelController,
    chatController: ChatController,
    webView: WKWebView
) {
    DispatchQueue.main.async {
        let js = "document.getElementById('input').value = "
            + jsString("what is today's date?") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("GATE_NONAV_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        func poll() {
            let streaming = "document.getElementById('stop')"
                + " && !document.getElementById('stop').hidden"
            webView.evaluateJavaScript(streaming) { value, _ in
                let stillStreaming = (value as? Bool) == true
                if !stillStreaming, chatController.deltaCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        measureNonNav(panelController: panelController, webView: webView)
                    }
                    return
                }
                if Date() >= deadline {
                    print("GATE_NONAV_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }
}

/// The never-navigated measurement. The native pane's visibility can only be
/// asked of Swift (it is an NSView over the web view, invisible to the page),
/// so this prints BOTH sides and makes the page's `visible` claim earn its
/// keep: it must be on screen, hit-testable, and NOT under the pane.
@MainActor
private func measureNonNav(
    panelController: PanelController,
    webView: WKWebView
) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let check = #"""
        (function () {
          var bubble = document.getElementById('bubble');
          var panel = document.documentElement.getBoundingClientRect();
          function rect(el) {
            if (!el) { return null; }
            var r = el.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
          }
          function fmt(r) { return r ? (r.x + ',' + r.y + ',' + r.w + ',' + r.h) : 'none'; }
          var out = {};
          out.browserOpen = document.body.classList.contains('browser-open');
          out.bubbleDisplay = bubble ? getComputedStyle(bubble).display : 'missing';
          out.bubbleRect = fmt(rect(bubble));
          var turns = [].slice.call(document.querySelectorAll('#bubble .turn'));
          out.turns = turns.length;
          var last = turns.length > 0 ? turns[turns.length - 1] : null;
          var lr = rect(last);
          out.lastRect = fmt(lr);
          out.lastText = last ? ((last.innerText || '').replace(/\s+/g, ' ').trim()).slice(0, 40) : '';
          out.lastOnScreen = !!(lr && lr.h > 0 && lr.y >= -1 && lr.y + lr.h <= panel.height + 1);
          out.hitIsTurn = false;
          out.elementFromPoint = 'none';
          if (lr && lr.w > 0 && lr.h > 0) {
            var cx = lr.x + Math.round(lr.w / 2);
            var cy = lr.y + Math.round(lr.h / 2);
            if (cx >= 0 && cx < panel.width && cy >= 0 && cy < panel.height) {
              var el = document.elementFromPoint(cx, cy);
              if (el) {
                out.elementFromPoint = (el.id ? '#' + el.id : '.')
                  + (el.className ? String(el.className).replace(/\s+/g, '.') : '');
                out.hitIsTurn = !!(el === last || last.contains(el) || el.contains(last));
              }
            } else { out.elementFromPoint = 'offscreen'; }
          }
          out.pageSays = window.__popLastVisibility || '';
          return JSON.stringify(out);
        })()
        """#

        webView.evaluateJavaScript(check) { value, error in
            if let error {
                print("GATE_NONAV_MEASURE_ERROR \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("GATE_NONAV_MEASURE_FAILED raw=\(String(describing: value))")
                fflush(stdout)
                exit(1)
            }
            func s(_ k: String) -> String { (d[k] as? String) ?? "?" }
            func b(_ k: String) -> Bool { (d[k] as? Bool) == true }
            func n(_ k: String) -> Int { (d[k] as? Int) ?? -1 }

            // NATIVE SIDE. The pane is over the web view; the page cannot see
            // it. `GATE_NONAV_PANE_VISIBLE` must be `false` here.
            let pane = BrowserController.shared.paneView
            let paneVisible = !pane.isHidden && pane.window != nil
            let paneBandBottom = paneVisible ? BrowserController.paneHeight : 0
            let pageSays = s("pageSays")
            let lastOnScreen = b("lastOnScreen")
            let hitIsTurn = b("hitIsTurn")
            let lastText = s("lastText")

            let lastParts = s("lastRect").split(separator: ",").map(String.init)
            let lastTop = lastParts.count > 1 ? (Double(lastParts[1]) ?? -1) : -1
            let occluded = paneVisible && lastTop >= 0 && lastTop < paneBandBottom

            // Page honesty: `visible` is only honest if the last turn is
            // really on screen, really hit-testable, and not hidden under the
            // native pane it cannot measure.
            let honest = pageSays == "visible" && lastOnScreen && hitIsTurn && !occluded

            print("GATE_NONAV_BROWSER_OPEN=\(b("browserOpen"))")
            print("GATE_NONAV_BROWSER_STATE_ACTIVE=\(BrowserController.shared.state.active)")
            print("GATE_NONAV_PANE_VISIBLE=\(paneVisible)")
            print("GATE_NONAV_PANE_BAND_BOTTOM=\(Int(paneBandBottom))")
            print("GATE_NONAV_BUBBLE_DISPLAY=\(s("bubbleDisplay"))")
            print("GATE_NONAV_BUBBLE_RECT=\(s("bubbleRect"))")
            print("GATE_NONAV_TURNS=\(n("turns"))")
            print("GATE_NONAV_LAST_RECT=\(s("lastRect"))")
            print("GATE_NONAV_LAST_ON_SCREEN=\(lastOnScreen)")
            print("GATE_NONAV_HIT_IS_TURN=\(hitIsTurn)")
            print("GATE_NONAV_ELEMENT_FROM_POINT=\(s("elementFromPoint"))")
            print("GATE_NONAV_LAST_TEXT=\(lastText)")
            print("GATE_NONAV_PAGE_SAYS=\(pageSays)")
            print("GATE_NONAV_LAST_OCCLUDED_BY_PANE=\(occluded)")
            print("GATE_NONAV_HONEST=\(honest)")
            print("GATE_NONAV_PANEL_STATE=\(panelController.state.rawValue)")
            fflush(stdout)

            let pass = !paneVisible && paneBandBottom == 0 && lastOnScreen
                && hitIsTurn && !lastText.isEmpty && honest
            print("GATE_NONAV_PASS=\(pass)")
            fflush(stdout)
            exit(pass ? 0 : 1)
        }
    }
}

/// `--user-frame-audit`: the USER'S app, the USER'S state, and what is PAINTED.
///
/// Three earlier rounds failed because every probe forced the browser open for
/// real, which set `state.active = true`, which made the page reserve a
/// 300px band and lay the transcript out BELOW the pane — a layout that works.
/// The user's launch has a restored session and the panel in `full` while the
/// browser has never navigated, so `state.active` is FALSE: the page reserves
/// nothing and paints the transcript at the top of the web region, while
/// `layoutContent` shows the 300pt pane over exactly that band. The transcript
/// is in the DOM, `display: block`, and completely covered.
///
/// So this audit reproduces THAT: restore a session, go `full`, and measure
/// without navigating the browser. Read-only on the user's storage — it opens
/// an existing session rather than creating one, and sends a message that lands
/// in that same session the user already has.
@MainActor
private func runUserFrameAudit(
    panelController: PanelController,
    chatController: ChatController
) {
    panelController.show()
    let webView = panelController.appWebView.webView

    // RESTORE, do not seed. The user's real session list is what makes their
    // panel open into `full` at all.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        let sessions = SessionStore().sessions()
        print("AUDIT_SESSIONS=\(sessions.count)")
        if let newest = sessions.first {
            let turns = chatController.openSession(newest.id)
            print("AUDIT_RESTORED_SESSION=\(newest.id) turns=\(turns)")
        } else {
            print("AUDIT_RESTORED_SESSION=none")
        }
        fflush(stdout)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // One real send through the real UI, no browser navigation — the
            // user's exact sequence.
            let js = "document.getElementById('input').value = "
                + jsString("what is today's date ?") + ";"
                + "document.getElementById('composer').dispatchEvent("
                + "new Event('submit', {cancelable: true}));"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("AUDIT_SEND_ERROR \(error.localizedDescription)")
                    fflush(stdout)
                }
            }

            let deadline = Date().addingTimeInterval(90)
            func poll() {
                let streaming = "document.getElementById('stop')"
                    + " && !document.getElementById('stop').hidden"
                webView.evaluateJavaScript(streaming) { value, _ in
                    let stillStreaming = (value as? Bool) == true
                    if !stillStreaming, chatController.deltaCount > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            measureUserFrame(
                                panelController: panelController,
                                webView: webView
                            )
                        }
                        return
                    }
                    if Date() >= deadline {
                        print("AUDIT_TIMEOUT deltas=\(chatController.deltaCount)")
                        fflush(stdout)
                        measureUserFrame(
                            panelController: panelController,
                            webView: webView
                        )
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
        print("AUDIT_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// Prints what is actually painted, and decides `USER_SCREEN_RESULT` from the
/// measurement rather than from any page-side self-report.
@MainActor
private func measureUserFrame(
    panelController: PanelController,
    webView: WKWebView
) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let check = #"""
        (function () {
          var bubble = document.getElementById('bubble');
          var spacer = document.getElementById('browserSpacer');
          var strip = document.getElementById('browserStrip');
          var panel = document.documentElement.getBoundingClientRect();
          function rect(el) {
            if (!el) { return null; }
            var r = el.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
          }
          function fmt(r) { return r ? (r.x + ',' + r.y + ',' + r.w + ',' + r.h) : 'none'; }
          var out = {};
          out.bodyClass = document.body.className;
          out.browserOpen = document.body.classList.contains('browser-open');
          out.panel = fmt(rect(document.documentElement));
          out.bubbleDisplay = bubble ? getComputedStyle(bubble).display : 'missing';
          out.bubbleVisibility = bubble ? getComputedStyle(bubble).visibility : 'missing';
          out.bubbleOpacity = bubble ? getComputedStyle(bubble).opacity : 'missing';
          out.bubbleRect = fmt(rect(bubble));
          out.spacerRect = fmt(rect(spacer));
          out.stripRect = fmt(rect(strip));
          var turns = [].slice.call(document.querySelectorAll('#bubble .turn'));
          out.turnCount = turns.length;
          var last = null;
          var lines = [];
          var insideCount = 0;
          for (var i = 0; i < turns.length; i++) {
            var t = turns[i];
            var r = t.getBoundingClientRect();
            var inside = r.height > 0 && r.top >= -1 && r.bottom <= panel.height + 1;
            if (inside) { insideCount++; }
            var cls = (t.className || '').replace(/\s+/g, '.');
            lines.push(cls + '@' + fmt(rect(t)) + ' inside=' + inside
              + ' text="' + ((t.innerText || '').replace(/\s+/g, ' ').trim()).slice(0, 28) + '"');
            last = t;
          }
          out.turns = lines.join(' ;; ');
          out.turnsInsidePanel = insideCount;
          var lr = rect(last);
          out.lastRect = fmt(lr);
          out.lastDisplay = last ? getComputedStyle(last).display : 'none';
          out.lastText = last ? ((last.innerText || '').replace(/\s+/g, ' ').trim()).slice(0, 40) : '';
          out.lastInFrame = !!(lr && lr.h > 0 && lr.y >= -1 && lr.y + lr.h <= panel.height + 1);
          out.elementFromPoint = 'none';
          if (lr && lr.w > 0 && lr.h > 0) {
            var cx = lr.x + Math.round(lr.w / 2);
            var cy = lr.y + Math.round(lr.h / 2);
            if (cx >= 0 && cx < panel.width && cy >= 0 && cy < panel.height) {
              var el = document.elementFromPoint(cx, cy);
              if (el) {
                out.elementFromPoint = (el.id ? '#' + el.id : '')
                  + (el.className ? '.' + String(el.className).replace(/\s+/g, '.') : '');
                // Is the turn itself the thing on top at its own centre?
                out.hitIsTurn = !!(el === last || last.contains(el) || el.contains(last));
              }
            } else { out.elementFromPoint = 'offscreen'; }
          }
          out.pageSays = window.__popLastVisibility || '';
          return JSON.stringify(out);
        })()
        """#

        webView.evaluateJavaScript(check) { value, error in
            if let error {
                print("AUDIT_MEASURE_ERROR \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("AUDIT_MEASURE_FAILED")
                fflush(stdout)
                exit(1)
            }
            func s(_ k: String) -> String { (d[k] as? String) ?? "?" }
            func b(_ k: String) -> Bool { (d[k] as? Bool) == true }
            func n(_ k: String) -> Int { (d[k] as? Int) ?? -1 }

            print("AUDIT_BODY_CLASS=\(s("bodyClass"))")
            print("AUDIT_BROWSER_OPEN=\(b("browserOpen"))")
            print("AUDIT_PANEL_RECT=\(s("panel"))")
            print("AUDIT_BUBBLE_DISPLAY=\(s("bubbleDisplay"))")
            print("AUDIT_BUBBLE_VISIBILITY=\(s("bubbleVisibility"))")
            print("AUDIT_BUBBLE_OPACITY=\(s("bubbleOpacity"))")
            print("AUDIT_BUBBLE_RECT=\(s("bubbleRect"))")
            print("AUDIT_SPACER_RECT=\(s("spacerRect"))")
            print("AUDIT_STRIP_RECT=\(s("stripRect"))")
            print("AUDIT_TURN_COUNT=\(n("turnCount"))")
            print("AUDIT_TURNS=\(s("turns"))")
            print("AUDIT_TURNS_INSIDE_PANEL=\(n("turnsInsidePanel"))")
            print("AUDIT_LAST_RECT=\(s("lastRect"))")
            print("AUDIT_LAST_DISPLAY=\(s("lastDisplay"))")
            print("AUDIT_LAST_TEXT=\(s("lastText"))")
            print("AUDIT_LAST_IN_FRAME=\(b("lastInFrame"))")
            print("AUDIT_ELEMENT_FROM_POINT=\(s("elementFromPoint"))")
            print("AUDIT_HIT_IS_TURN=\(b("hitIsTurn"))")
            print("AUDIT_PAGE_SAYS=\(s("pageSays"))")
            print("AUDIT_PANEL_STATE=\(panelController.state.rawValue)")

            // NATIVE SIDE. The pane is an NSView over the web view, so the page
            // cannot see it; Swift is the only side that can be asked.
            let pane = BrowserController.shared.paneView
            let paneVisible = !pane.isHidden && pane.window != nil
            print("AUDIT_PANE_VISIBLE=\(paneVisible)")
            print("AUDIT_BROWSER_STATE_ACTIVE=\(BrowserController.shared.state.active)")

            // OCCLUSION, measured natively. The pane is pinned to the TOP of the
            // web region (`y = webHeight - paneHeight`, bottom-left origin), so
            // in PAGE coordinates it covers y 0..300. `elementFromPoint` cannot
            // see it — it is not in the DOM — which is precisely why a page that
            // says `visible` can be a blank panel.
            let paneBandBottom = paneVisible ? BrowserController.paneHeight : 0
            print("AUDIT_PANE_BAND_BOTTOM=\(Int(paneBandBottom))")
            let lastParts = s("lastRect").split(separator: ",").map(String.init)
            let lastTop = lastParts.count > 1 ? (Double(lastParts[1]) ?? -1) : -1
            let occluded = paneVisible && lastTop >= 0 && lastTop < paneBandBottom
            print("AUDIT_LAST_OCCLUDED_BY_PANE=\(occluded)")

            // THE VERDICT, from the measurement: the last turn's rect is inside
            // the panel, is NOT under the native pane, and the thing painted at
            // its centre is the turn itself.
            let visible = b("lastInFrame") && b("hitIsTurn")
                && !occluded && !s("lastText").isEmpty
            print("USER_SCREEN_RESULT=\(visible ? "visible" : "blank")")
            fflush(stdout)
            exit(0)
        }
    }
}

@MainActor
private func runUIChatProbe(
    prompt: String,
    panelController: PanelController,
    chatController: ChatController
) {
    panelController.show()

    var completed = false
    // The probe needs to know when generation finished; the controller is the
    // only place that knows, so completion is observed through the page's own
    // state (stop button visible again) plus a generous hard deadline.
    let deadline = Date().addingTimeInterval(60)

    // Bar state must show NO chat. Measured BEFORE the send, while the panel is
    // still resting, by asking the DOM what the transcript's computed display
    // actually is \u2014 not whether it has children (the archive makes it non-empty).
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        let js = "(() => { const el = document.getElementById('bubble');"
            + " if (!el) { return 'false'; }"
            + " return getComputedStyle(el).display === 'none' ? 'true' : 'false'; })()"
        panelController.appWebView.webView.evaluateJavaScript(js) { value, _ in
            print("UI_BAR_HIDDEN=\(value as? String ?? "unknown")")
            fflush(stdout)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        let js = "document.getElementById('input').value = \(jsString(prompt));"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        panelController.appWebView.webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("UI_CHAT_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        // Proves the RUNNING page carries the current composer, not a cached one.
        panelController.appWebView.webView.evaluateJavaScript("window.__POP_COMPOSER_V ?? null") { value, _ in
            print("UI_COMPOSER_V=\(value as? String ?? "missing")")
            fflush(stdout)
        }

        // Chip/pill readback does not depend on the model replying, so sample it
        // on the same schedule as the early composer check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            reportUIChips(panelController: panelController) {}
        }

        func poll() {
            let check = "document.getElementById('stop') && document.getElementById('stop').hidden"
            panelController.appWebView.webView.evaluateJavaScript(check) { value, _ in
                let streaming = (value as? Bool) == false
                if !streaming && chatController.deltaCount > 0 {
                    completed = true
                    reportUIChat(panelController: panelController, chatController: chatController)
                    return
                }
                if Date() >= deadline {
                    print("UI_CHAT_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    reportUIChat(panelController: panelController, chatController: chatController)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 65) {
        if !completed {
            print("UI_CHAT_TIMEOUT deltas=\(chatController.deltaCount)")
            fflush(stdout)
            reportUIChat(panelController: panelController, chatController: chatController)
        }
    }

    NSApp.run()
}

@MainActor
private func reportUIChat(panelController: PanelController, chatController: ChatController) {
    // The answer lives in the robot's speech bubble, not a chat box: read the
// bubble's `.answer` text, which is the only answer surface that exists.
    let js = "(function () {"
        + "var el = document.querySelector('#bubble .answer');"
        + "return el ? el.textContent : 'NO_BUBBLE';"
        + "})()"
    panelController.appWebView.webView.evaluateJavaScript(js) { value, _ in
        print("UI_CHAT_DELTAS=\(chatController.deltaCount)")
        print("UI_CHAT_VALUE=\(value as? String ?? "NO_BUBBLE")")
        print("UI_CHAT_STATE=\(chatController.lastMascotState)")
        fflush(stdout)
        reportUIChips(panelController: panelController) { exit(0) }
    }
}

/// `--test-page-version`: is the RUNNING page the composer this build ships?
///
/// One line, no network, no model. The composer marker sat unchanged for three
/// milestones, so a cached page was invisible: every symptom it caused looked
/// like a logic bug instead of a stale bundle. Gate: the live value is
/// `spike-s`.
@MainActor
private func runPageVersionProbe(panelController: PanelController) {
    panelController.show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        panelController.appWebView.webView.evaluateJavaScript(
            "window.__POP_COMPOSER_V ?? null"
        ) { value, _ in
            let version = value as? String ?? ""
            if version.isEmpty {
                print("PAGE_VERSION_MISSING")
            } else {
                print("PAGE_VERSION=\(version)")
            }
            fflush(stdout)
            // Tracks the CURRENT marker: this probe's whole claim is "the page
            // running right now is the page this build ships", so its expected
            // value moves with the marker and nothing else.
            exit(version == "spike-u" ? 0 : 1)
        }
    }
    NSApp.run()
}

/// `--test-bar-fit`: THE COMPOSER MUST NEVER BE CLIPPED BY THE WEB REGION.
///
/// The defect: `#streamStatus` sits ABOVE `#composer` in normal flow, so once it
/// holds text in `bar` state the stack is taller than the 64pt web region and
/// the composer's lower half is cut off. This probe measures the composer's
/// real rect against the region in three configurations and requires zero
/// clipped pixels in all of them:
///   * idle bar  — status hidden (must stay the byte-identical 214pt window),
///   * statused bar — the page's own `setStreamStatus` drove text into the line,
///   * full — the 520pt region with the same status text.
/// The robot anchor Y is required to be identical across the idle and statused
/// bar: growing the bar must move the bottom edge, never the robot.
///
/// Gates: `BARFIT_IDLE_CLIPPED_PX=0`, `BARFIT_CLIPPED_PX=0`,
/// `FULL_COMPOSER_CLIPPED_PX=0`, `IDLE_BAR_WINDOW_H=214`, and the robot anchor
/// Y unchanged.
@MainActor
private func runBarFitProbe(panelController: PanelController) {
    panelController.show()
    let webView = panelController.appWebView.webView

    // innerHeight | status display | status l,t,r,b | composer l,t,r,b
    let measureJS = "(function () {"
        + "function rect(el){var r=el.getBoundingClientRect();"
        + "return r.left+','+r.top+','+r.right+','+r.bottom;}"
        + "var s=document.getElementById('streamStatus');"
        + "var w=document.getElementById('composer');"
        + "var disp=s?getComputedStyle(s).display:'none';"
        + "return window.innerHeight+'|'+disp+'|'+(s?rect(s):'')+'|'+(w?rect(w):'');"
        + "})()"

    func robotAnchorY() -> CGFloat {
        guard let robot = panelController.robotViewForTesting else { return -1 }
        let inWindow = robot.convert(robot.bounds, to: nil)
        return panelController.panel.frame.origin.y + inWindow.origin.y
    }

    var idleClipped = -1
    var statusClipped = -1
    var fullClipped = -1
    var idleWindowH = -1
    var idleAnchorY: CGFloat = -999
    var statusAnchorY: CGFloat = -999

    // Parses one measurement and prints the labelled block for its state.
    func measure(_ phase: String, finish: @escaping (Double, CGFloat) -> Void) {
        webView.evaluateJavaScript(measureJS) { value, _ in
            let parts = (value as? String ?? "")
                .split(separator: "|", maxSplits: 3).map(String.init)
            let webH = Double(parts.count > 0 ? parts[0] : "0") ?? 0
            let statusDisplay = parts.count > 1 ? parts[1] : "none"
            let statusRect = parts.count > 2 ? parts[2] : ""
            let composerRect = parts.count > 3 ? parts[3] : ""
            let cp = composerRect.split(separator: ",").map(String.init)
            let cTop = cp.count > 1 ? (Double(cp[1]) ?? 0) : 0
            let cBottom = cp.count > 3 ? (Double(cp[3]) ?? 0) : 0
            // Clipped if any part of the composer falls outside the region.
            let clipped = max(0, cBottom - webH) + max(0, -cTop)
            let windowH = Double(panelController.panel.frame.height)
            finish(clipped, webH)

            print("BARFIT_\(phase)_WEB_H=\(Int(webH))")
            print("BARFIT_\(phase)_WINDOW_H=\(Int(windowH))")
            print("BARFIT_\(phase)_STATUS_DISPLAY=\(statusDisplay)")
            print("BARFIT_\(phase)_STATUS_RECT=\(statusRect)")
            print("BARFIT_\(phase)_COMPOSER_RECT=\(composerRect)")
            print("BARFIT_\(phase)_COMPOSER_TOP=\(Int(cTop))")
            print("BARFIT_\(phase)_COMPOSER_BOTTOM=\(Int(cBottom))")
            print("BARFIT_\(phase)_CLIPPED_PX=\(Int(clipped))")
            fflush(stdout)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        idleWindowH = Int(panelController.panel.frame.height)
        idleAnchorY = robotAnchorY()
        print("IDLE_BAR_WINDOW_H=\(idleWindowH)")
        print("IDLE_ROBOT_ANCHOR_Y=\(Int(idleAnchorY))")
        fflush(stdout)

        // Measure the IDLE bar first, and only continue from inside its result:
        // `evaluateJavaScript` is asynchronous, and starting the status drive or
        // the `full` transition before the idle read lands would measure a
        // different state than the one being labelled.
        measure("IDLE") { clipped, _ in
            idleClipped = Int(clipped)

            // Show the status line through the page's OWN setter, then let
            // Swift grow the bar from the page's measurement and settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let drive = "window.popAPI && window.popAPI.__setStreamStatusForProbe"
                    + " ? (window.popAPI.__setStreamStatusForProbe('ready','ready'),'ok')"
                    + " : 'missing'"
                webView.evaluateJavaScript(drive) { result, _ in
                    print("BARFIT_STATUS_DRIVE=\(result as? String ?? "missing")")
                    fflush(stdout)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                statusAnchorY = robotAnchorY()
                print("BARFIT_STATUS_ROBOT_ANCHOR_Y=\(Int(statusAnchorY))")
                fflush(stdout)
                measure("STATUS") { clipped, webH in
                    statusClipped = Int(clipped)
                    // The generic keys the gate names, for the statused bar.
                    print("BARFIT_WEB_H=\(Int(webH))")
                    print("BARFIT_CLIPPED_PX=\(Int(clipped))")
                    fflush(stdout)

                    // `full`: the same status is up, and the composer must
                    // still sit entirely inside the 520pt region. Run from
                    // inside the statused-bar result so nothing races.
                    panelController.setPanelState(.full, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        webView.evaluateJavaScript(measureJS) { value, _ in
                            let parts = (value as? String ?? "")
                                .split(separator: "|", maxSplits: 3).map(String.init)
                            let webH = Double(parts.count > 0 ? parts[0] : "0") ?? 0
                            let composerRect = parts.count > 3 ? parts[3] : ""
                            let cp = composerRect.split(separator: ",").map(String.init)
                            let cTop = cp.count > 1 ? (Double(cp[1]) ?? 0) : 0
                            let cBottom = cp.count > 3 ? (Double(cp[3]) ?? 0) : 0
                            let clipped = max(0, cBottom - webH) + max(0, -cTop)
                            fullClipped = Int(clipped)
                            print("FULL_COMPOSER_RECT=\(composerRect)")
                            print("FULL_COMPOSER_CLIPPED_PX=\(Int(clipped))")
                            fflush(stdout)

                            let idleOK = idleClipped == 0
                            let barOK = statusClipped == 0
                            let fullOK = fullClipped == 0
                            let windowOK = idleWindowH == 214
                            let anchorOK = Int(idleAnchorY) == Int(statusAnchorY)
                            let pass = idleOK && barOK && fullOK && windowOK && anchorOK
                            print(
                                "BARFIT_GATE idle=\(idleOK) bar=\(barOK) full=\(fullOK)"
                                    + " window214=\(windowOK) anchorStable=\(anchorOK)"
                            )
                            fflush(stdout)
                            exit(pass ? 0 : 1)
                        }
                    }
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("BARFIT_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--user-bar-fit`: THE USER'S PATH — a real process, a real send.
///
/// Isolated stores via `POP_TRANSCRIPT_PATH`/`POP_SESSIONS_PATH` (the launcher
/// is run with those set), so this reads the real provider config but writes
/// nothing into `~/Library/Application Support/Pop/`. It enters the bar (the
/// same entry ⌥Space drives), sends ONE real message through the composer, waits
/// for the stream to end, then reports the state the user is left in and whether
/// the composer is inside the web region there.
///
/// Gates: `USER_BAR_RESULT=ok` (composer rect entirely inside the region) —
/// reported only when the measurement supports it.
@MainActor
private func runUserBarFitProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    panelController.show()
    let webView = panelController.appWebView.webView

    // innerHeight | composer top | composer bottom | bubble display | turns |
    // last text | body class list
    let measureJS = "(function () {"
        + "function rr(el){var r=el.getBoundingClientRect();"
        + "return [r.left,r.top,r.right,r.bottom];}"
        + "var w=document.getElementById('composer');"
        + "var b=document.getElementById('bubble');"
        + "var turns=document.querySelectorAll('#bubble .turn');"
        + "var last=turns.length?turns[turns.length-1]:null;"
        + "var text=last?((last.innerText||'').replace(/\\s+/g,' ').trim()).slice(0,40):'';"
        + "var c=w?rr(w):[0,0,0,0];"
        + "return window.innerHeight+'|'+(w?Math.round(c[1]):0)+'|'+(w?Math.round(c[3]):0)"
        + "  +'|'+(b?getComputedStyle(b).display:'missing')+'|'+turns.length+'|'+text"
        + "  +'|'+document.body.className;})()"

    func report() {
        webView.evaluateJavaScript(measureJS) { value, _ in
            let parts = (value as? String ?? "")
                .split(separator: "|", maxSplits: 6).map(String.init)
            let webH = Double(parts.count > 0 ? parts[0] : "0") ?? 0
            let cTop = Double(parts.count > 1 ? parts[1] : "0") ?? 0
            let cBottom = Double(parts.count > 2 ? parts[2] : "0") ?? 0
            let bubbleDisplay = parts.count > 3 ? parts[3] : "missing"
            let turns = Int(parts.count > 4 ? parts[4] : "0") ?? 0
            let text = parts.count > 5 ? parts[5] : ""
            let bodyClass = parts.count > 6 ? parts[6] : ""
            let clipped = max(0, cBottom - webH) + max(0, -cTop)
            let state = panelController.state.rawValue
            let ok = clipped == 0
            print("FINAL_STATE=\(state)")
            print("FINAL_BODY_CLASS=\(bodyClass)")
            print("FINAL_BUBBLE_DISPLAY=\(bubbleDisplay)")
            print("FINAL_TURNS=\(turns)")
            print("USER_BAR_RESULT=\(ok ? "ok" : "clipped")")
            print("USER_FINAL_STATE=\(state)")
            print("USER_BUBBLE_DISPLAY=\(bubbleDisplay)")
            print("USER_LAST_TEXT=\(text)")
            // A finished reply ending in `bar` means the transcript is hidden
            // while answer text exists. Report it as a finding, not a silent
            // pass.
            if turns > 0, bubbleDisplay == "none" {
                print("USER_TRANSCRIPT_HIDDEN_WITH_ANSWER=true")
            }
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        let js = "document.getElementById('input').value = "
            + jsString("what is today's date?") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("USER_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        func poll() {
            let streaming = "document.getElementById('stop')"
                + " && !document.getElementById('stop').hidden"
            webView.evaluateJavaScript(streaming) { value, _ in
                let stillStreaming = (value as? Bool) == true
                if !stillStreaming, chatController.deltaCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { report() }
                    return
                }
                if Date() >= deadline {
                    print("USER_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("USER_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-stop-receipt`: pressing STOP must leave a receipt, not a hole.
///
/// The defect: the send control doubled as the stop control, so a second click
/// cancelled an in-flight request through the generic teardown — no transcript
/// line, no status, an empty assistant block the user could only read as "Pop
/// dropped my question". This drives a REAL send, presses the real stop control
/// mid-stream, and asserts the page says what happened.
///
/// Gates: `STOP_RECEIPT` (a `stopped by you` line is on screen), `STOP_STATUS`
/// (the status line reads `stopped`), `STOP_FINAL_EMPTY` (no dangling empty
/// assistant turn).
@MainActor
private func runStopReceiptProbe(panelController: PanelController) {
    panelController.show()
    let webView = panelController.appWebView.webView

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        // A long question so the stop lands mid-stream rather than after the
        // answer, which is the only situation the defect existed in.
        let js = "document.getElementById('input').value = "
            + jsString("Count from 1 to 200, one number per line.") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("STOP_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        // The stop control itself, clicked as a person would — and only while it
        // is actually VISIBLE, because that is the only time a person can reach
        // it. If the request had already failed on its own, there is nothing to
        // stop; the probe re-sends once rather than reporting a defect that was
        // the provider's, not the stop path's.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let press = "(function () { var s = document.getElementById('stop');"
                + "if (!s || s.hidden) { return 'not-streaming'; }"
                + "s.click(); return 'stopped'; })()"
            webView.evaluateJavaScript(press) { value, _ in
                let pressed = (value as? String ?? "") == "stopped"
                print("STOP_PRESS=\(value as? String ?? "unknown")")
                fflush(stdout)
                if pressed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        reportStopReceipt(webView)
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print("STOP_PRECONDITION=stream-ended-before-stop")
                    fflush(stdout)
                    exit(1)
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 88) {
        print("STOP_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

@MainActor
private func reportStopReceipt(_ webView: WKWebView) {
    let check = "(function () {"
        + "var notes = document.querySelectorAll('#bubble .stopped-note');"
        + "var receipt = false;"
        + "for (var i = 0; i < notes.length; i++) {"
        + "  if ((notes[i].textContent || '').indexOf('stopped by you') !== -1) {"
        + "    receipt = true; } }"
        + "var statusEl = document.getElementById('streamStatus');"
        + "var statusText = statusEl ? (statusEl.textContent || '').trim() : '';"
        + "var answers = document.querySelectorAll('#bubble .turn.assistant .answer');"
        + "var last = answers.length ? answers[answers.length - 1] : null;"
        + "var empty = !last || (last.textContent || '').trim().length === 0;"
        + "return receipt + '|' + statusText + '|' + empty; })()"
    webView.evaluateJavaScript(check) { value, _ in
        let parts = (value as? String ?? "false||true").split(
            separator: "|", maxSplits: 2
        ).map(String.init)
        let receipt = parts.first ?? "false"
        let statusText = parts.count > 1 ? parts[1] : ""
        let empty = parts.count > 2 ? parts[2] : "true"
        let receiptOK = receipt == "true"
        let statusOK = statusText.contains("stopped")
        let noEmpty = empty != "true"
        print("STOP_RECEIPT=\(receiptOK)")
        print("STOP_STATUS=\(statusText)")
        print("STOP_FINAL_EMPTY=\(!noEmpty)")
        fflush(stdout)
        exit(receiptOK && statusOK && noEmpty ? 0 : 1)
    }
}

/// `--test-no-stray-cancel`: a click that is NOT the stop control must do
/// nothing at all while a reply is coming in.
///
/// Two things used to happen on any composer-background click while streaming:
/// the bar drag started (`barDragBegin`), and the send control doubled as stop —
/// so a reply could be discarded by a misclick. This drives a real send, then
/// fires a background `barDragBegin` and a synthetic background click WITHOUT
/// touching the stop control, and asserts the stream is still running and no
/// `stopped` receipt appeared.
///
/// Gates: `STRAY_STREAM_ALIVE=true`, `STRAY_STOP_RECEIPT=false`.
@MainActor
private func runNoStrayCancelProbe(panelController: PanelController) {
    panelController.show()
    let webView = panelController.appWebView.webView

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        let js = "document.getElementById('input').value = "
            + jsString("Count from 1 to 200, one number per line.") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("STRAY_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // The stray clicks are only meaningful WHILE the page is streaming:
            // then a passing, then a failure, is the answer. If the request had
            // already ended on its own, the probe says so instead of blaming the
            // click path for the provider's timing.
            let precondition = "(function () { var s = document.getElementById('stop');"
                + "return !!s && !s.hidden; })()"
            webView.evaluateJavaScript(precondition) { value, _ in
                guard (value as? Bool) == true else {
                    print("STRAY_PRECONDITION=not-streaming")
                    fflush(stdout)
                    exit(1)
                }
                // The composer's own inert background: a real MouseEvent, so the
                // page's listener sees exactly what a person's click produces.
                let stray = "(function () {"
                    + "var bar = document.getElementById('composer');"
                    + "bar.dispatchEvent(new MouseEvent('mousedown',"
                    + "  { bubbles: true, cancelable: true, button: 0 }));"
                    + "bar.dispatchEvent(new MouseEvent('mousedown',"
                    + "  { bubbles: true, cancelable: true, button: 0 }));"
                    + "bar.dispatchEvent(new MouseEvent('click',"
                    + "  { bubbles: true, cancelable: true, button: 0 }));"
                    + "bar.dispatchEvent(new MouseEvent('click',"
                    + "  { bubbles: true, cancelable: true, button: 0 }));"
                    + "return 'sent'; })()"
                webView.evaluateJavaScript(stray) { _, error in
                    if let error {
                        print("STRAY_CLICK_ERROR \(error.localizedDescription)")
                        fflush(stdout)
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // `stop` visible == the page still believes it is streaming.
                    let check = "(function () {"
                        + "var stopEl = document.getElementById('stop');"
                        + "var alive = !!stopEl && !stopEl.hidden;"
                        + "var receipt = document.querySelectorAll('#bubble .stopped-note')"
                        + ".length > 0;"
                        + "return alive + '|' + receipt; })()"
                    webView.evaluateJavaScript(check) { value, _ in
                        let parts = (value as? String ?? "false|true").split(
                            separator: "|", maxSplits: 1
                        ).map(String.init)
                        let alive = parts.first == "true"
                        let receipt = parts.count > 1 ? parts[1] == "true" : true
                        print("STRAY_STREAM_ALIVE=\(alive)")
                        print("STRAY_STOP_RECEIPT=\(receipt)")
                        fflush(stdout)
                        exit(alive && !receipt ? 0 : 1)
                    }
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 88) {
        print("STRAY_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// Reads the rendered chip count and privacy pill, proving the pre-load context
/// pushes were replayed rather than dropped.
@MainActor
private func reportUIChips(panelController: PanelController, then: @escaping () -> Void) {
    let js = "(document.getElementById('chips') ? document.getElementById('chips').children.length : -1)"
        + " + '|' + (document.getElementById('privacyLabel')"
        + " ? document.getElementById('privacyLabel').textContent.trim() : '')"
    panelController.appWebView.webView.evaluateJavaScript(js) { value, _ in
        let parts = (value as? String ?? "").split(separator: "|", maxSplits: 1).map(String.init)
        print("UI_CHIPS=\(parts.first ?? "")")
        print("UI_PILL=\(parts.count > 1 ? parts[1] : "")")
        fflush(stdout)
        then()
    }
}

/// `--test-live-path`: the harness gap that let a real bug ship.
///
/// Every earlier probe entered `bar` through `show()`. The user's actual path is
/// ⌥Space on an ambient mascot — `toggle()` — and the send that follows has to
/// grow the panel to `full` and render the answer into the bubble. So this
/// probe does exactly that and nothing else, then reports what the DOM and the
/// window actually ended up holding.
@MainActor
private func runLivePathProbe(panelController: PanelController, chatController: ChatController) {
    var seenStates: [String] = []
    // Chain onto the live wiring rather than replacing it, so the page still
    // receives its state pushes.
    let existingPush = panelController.onPanelStateChange
    panelController.onPanelStateChange = { raw in
        if seenStates.last != raw { seenStates.append(raw) }
        existingPush?(raw)
    }

    let webView = panelController.appWebView.webView

    // 1. The ambient mascot is the launch default; assert it before touching
    // anything, because "was it really the mascot?" is half of what went wrong.
    print("LIVE_START state=\(panelController.state.rawValue)")
    fflush(stdout)

    // 2. The REAL entry: the hotkey, not `show()`.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        panelController.toggle()
        print("LIVE_AFTER_TOGGLE state=\(panelController.state.rawValue)")
        fflush(stdout)

        // 3. Send through the REAL UI: set the input and submit the composer,
        //    exactly as pressing return does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let js = "document.getElementById('input').value = "
                + jsString("Reply with exactly: LIVE_PATH") + ";"
                + "document.getElementById('composer').dispatchEvent("
                + "new Event('submit', {cancelable: true}));"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("LIVE_SEND_ERROR \(error.localizedDescription)")
                    fflush(stdout)
                }
            }

            let deadline = Date().addingTimeInterval(75)
            func poll() {
                // The page's own stop button is the streaming flag, read exactly as
                // `--test-ui-chat` reads it: `hidden` again means generation is
                // over. Nothing native is invented for this.
                let streaming = "document.getElementById('stop')"
                    + " && !document.getElementById('stop').hidden"
                webView.evaluateJavaScript(streaming) { value, _ in
                    let stillStreaming = (value as? Bool) == true
                    if !stillStreaming, chatController.deltaCount > 0 {
                        reportLivePath(panelController, seenStates: seenStates, then: { exit(0) })
                        return
                    }
                    if Date() >= deadline {
                        print("LIVE_TIMEOUT deltas=\(chatController.deltaCount)")
                        fflush(stdout)
                        reportLivePath(panelController, seenStates: seenStates, then: { exit(0) })
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 95) {
        reportLivePath(panelController, seenStates: seenStates, then: { exit(0) })
    }

    NSApp.run()
}

@MainActor
private func reportLivePath(
    _ panelController: PanelController,
    seenStates: [String],
    then: @escaping () -> Void
) {
    // The bubble must have TEXT, not merely exist: a 0-height bubble is exactly
    // what the user saw, and it looks identical to a working one in the DOM.
    let js = "(function () {"
        + "var el = document.querySelector('#bubble .answer');"
        + "if (!el) { return 'EMPTY'; }"
        + "var t = (el.textContent || '').trim();"
        + "return t === '' ? 'EMPTY' : t;"
        + "})()"
    panelController.appWebView.webView.evaluateJavaScript(js) { value, _ in
        let native = panelController.panel.firstResponder
        let nativeName = native.map { String(describing: type(of: $0)) } ?? "nil"
        print("LIVE_PANEL_STATES=\(seenStates.joined(separator: ">"))")
        print("LIVE_BUBBLE=\(value as? String ?? "EMPTY")")
        print("LIVE_FIRST_RESPONDER=\(nativeName)")
        print("LIVE_DELTAS=\(panelController.appWebView.webView.isLoading ? "loading" : "ready")")
        fflush(stdout)
        then()
    }
}

/// `--test-sessions`: proves a conversation can be resumed.
///
/// Three sessions, two turns each, created through the REAL append path (no
/// hand-written files — a probe that fabricates its input proves nothing about
/// the code under test). Then the OLDEST is reopened and the restored turn
/// count is printed. Storage is the temp root `bootstrap` pointed at, so the
/// user's real history is untouched.
@MainActor
private func runSessionsProbe() {
    let store = SessionStore()
    let chat = ChatController(
        webViewProvider: { nil },
        sessions: store,
        configProvider: { .defaults }
    )

    for index in 1...3 {
        if index > 1 { chat.newChat() }
        chat.recordTurn(role: .user, text: "sessions probe question \(index)")
        chat.recordTurn(role: .assistant, text: "sessions probe answer \(index)")
    }

    let all = store.sessions()
    print("SESSIONS_COUNT=\(all.count)")
    print("SESSIONS_ORDER=\(all.map(\.title).joined(separator: " > "))")
    print("SESSIONS_TURNS=\(all.map { "\($0.turnCount)" }.joined(separator: ","))")

    let oldest = all.last
    let restored = oldest.map { chat.openSession($0.id) } ?? -1
    print("SESSIONS_RESTORED=\(restored)")
    print("SESSIONS_TITLE=\(oldest?.title ?? "none")")
    fflush(stdout)

    try? FileManager.default.removeItem(at: SessionStore.rootURL)
    exit(0)
}

/// `--test-clock`: the context block carries the wall clock.
///
/// No provider call — the question "what is today's date and time?" must be
/// answerable from the request itself, which is exactly the property worth
/// measuring: the string is assembled, and it names the CURRENT year.
@MainActor
private func runClockProbe() {
    let context = ChatController.withClock("[screen context]\napp: Pop")
    let year = Calendar.current.component(.year, from: Date())
    let present = context.contains("Today is") && context.contains("\(year)")
    let line = ChatController.clockLine()
    print("CLOCK_PRESENT=\(present)")
    print("CLOCK_LINE=\(line)")
    print("CLOCK_YEAR=\(year)")
    // The line must LEAD with today in words, then the fixed-width date, then
    // the time — a bare timestamp the model can skip is the bug this fixes.
    let todayFormat = line.range(
        of: #"^Today is [A-Z][a-z]+, \d{4}-\d{2}-\d{2}\. Current local time: \d{2}:\d{2}:\d{2}\.$"#,
        options: .regularExpression
    ) != nil
    print("CLOCK_LINE_TODAY_FORMAT=\(todayFormat)")
    // The date-anchoring invariant must reach the model through the shipped
    // system prompt, not merely exist as a constant.
    let anchorPresent = AppleFMProvider.systemPrompt.contains(ScreenOCR.todayAnchorClause)
    print("TODAY_ANCHOR_PRESENT=\(anchorPresent)")
    fflush(stdout)
    exit((present && todayFormat && anchorPresent) ? 0 : 1)
}

/// `--test-ui-sessions`: drives the REAL page through `popAPI.history` and
/// counts what it actually rendered. The count is read from the DOM, so a
/// page that renders one bubble and drops the rest cannot pass.
@MainActor
private func runUISessionsProbe(panelController: PanelController) {
    panelController.show()
    print("UI_SESSIONS_START")
    fflush(stdout)

    let entries = [
        ["role": "user", "text": "first question"],
        ["role": "assistant", "text": "first answer"],
        ["role": "user", "text": "second question"],
        ["role": "assistant", "text": "second answer"]
    ]
    let json = (try? String(data: JSONSerialization.data(withJSONObject: entries), encoding: .utf8))
        ?? "[]"

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        // The exception text is reported, not swallowed: a page handler that
        // throws mid-render leaves a PARTIAL transcript, which is exactly what
        // the DOM count below catches — but only if the fault is legible.
        let js = "(function(){ try {"
            + "if (!window.popAPI || !window.popAPI.history) { return 'NO_API'; }"
            + "window.popAPI.history(\(json)); return 'sent';"
            + "} catch (e) { return 'ERR ' + (e && e.message ? e.message : String(e))"
            + " + ' @ ' + (e && e.stack ? String(e.stack).slice(0, 200) : '?'); } })()"
        panelController.appWebView.webView.evaluateJavaScript(js) { value, error in
            if let error {
                print("UI_SESSIONS_PUSH_ERROR \(error.localizedDescription)")
                fflush(stdout)
            } else {
                print("UI_SESSIONS_PUSH=\(value as? String ?? "unknown")")
                fflush(stdout)
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
        let js = "(function () {"
            + "var all = document.querySelectorAll('#bubble .turn').length;"
            + "var users = document.querySelectorAll('#bubble .turn.user').length;"
            + "var asst = document.querySelectorAll('#bubble .turn.assistant').length;"
            + "return all + '|' + users + '|' + asst;"
            + "})()"
        panelController.appWebView.webView.evaluateJavaScript(js) { value, _ in
            let parts = (value as? String ?? "").split(separator: "|").map(String.init)
            print("UI_TURNS=\(parts.first ?? "")")
            print("UI_TURNS_USER=\(parts.count > 1 ? parts[1] : "")")
            print("UI_TURNS_ASSISTANT=\(parts.count > 2 ? parts[2] : "")")
            print("PANEL_STATE=\(panelController.state.rawValue)")
            fflush(stdout)
            exit(0)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("UI_TURNS_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-voice-dialog`: THE VOICE BUBBLE MUST BE VISIBLE IN THE RENDERED DOM.
///
/// The established failure: audio→recognition→Swift→page delivery all worked
/// (`VOICE_API=voicePartial` fired six times) yet the user saw no transcript.
/// "The JS handler ran" is not evidence of visibility, so this probe drives the
/// REAL page path (`popAPI.voiceState` + `popAPI.voicePartial`) in `.bar` state
/// and asserts the dialog's RENDERED rect: not hidden, non-zero, and INTERSECTING
/// the viewport with positive area.
///
/// Gates: `VOICE_DLG_VISIBLE=true` and `VOICE_TEXT_CONTENT` non-empty.
@MainActor
private func runVoiceDialogProbe(panelController: PanelController, chatController: ChatController) {
    panelController.show()
    // The bubble is a `.bar`-state surface: the composer is on screen there, and
    // that is the state the live trace reported.
    panelController.setPanelState(.bar, animated: false)
    let webView = panelController.appWebView.webView
    print("VOICE_DLG_PROBE_START")
    fflush(stdout)

    let measureJS = "(function(){"
        + "var d=document.getElementById('voiceDlg');"
        + "var t=document.getElementById('voiceText');"
        + "var c=document.getElementById('composer');"
        + "if(!d||!c){return JSON.stringify({error:'missing'});}"
        + "var cs=getComputedStyle(d);var r=d.getBoundingClientRect();"
        + "var vw=window.innerWidth,vh=window.innerHeight;"
        + "var ix=Math.max(0,Math.min(r.right,vw)-Math.max(r.left,0));"
        + "var iy=Math.max(0,Math.min(r.bottom,vh)-Math.max(r.top,0));"
        + "var vis=(!d.hidden)&&cs.display!=='none'&&cs.visibility!=='hidden'"
        + "&&parseFloat(cs.opacity||'1')>0&&ix>0&&iy>0;"
        + "return JSON.stringify({hidden:d.hidden,display:cs.display,"
        + "visibility:cs.visibility,opacity:cs.opacity,zIndex:cs.zIndex,"
        + "rect:[Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)],"
        + "text:t?t.textContent:'',viewport:[vw,vh],visible:vis,"
        + "composerDisplay:getComputedStyle(c).display});"
        + "})()"

    /// Read the rendered state once; the caller prints whatever it needs.
    func measure(_ done: @escaping ([String: Any]) -> Void) {
        webView.evaluateJavaScript(measureJS) { value, _ in
            let json = (value as? String) ?? "{}"
            print("VOICE_DLG_JSON=\(json)")
            let obj = (json.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                ?? [:]
            done(obj)
        }
    }

    /// Voice-only ON: composer hidden, dialog visible with the partial. Then
    /// voice-only OFF: composer restored. Exits nonzero unless all hold.
    func assertVoiceOnly() {
        measure { obj in
            let visible = (obj["visible"] as? Bool) ?? false
            let text = (obj["text"] as? String) ?? ""
            let composerDisplay = (obj["composerDisplay"] as? String) ?? "?"
            print("VOICE_DLG_VISIBLE=\(visible)")
            print("VOICE_TEXT_CONTENT=\(text)")
            print("VOICE_ONLY_COMPOSER_DISPLAY=\(composerDisplay)")
            print("VOICE_ONLY_DLG_VISIBLE=\(visible)")
            fflush(stdout)
            // SIMULATE THE SEND PATH at the bridge level (no real turn): this is
            // exactly what `popAPI.sendVoice` posts, so the Swift handler runs.
            chatController.handleBridgeMessage(type: "voiceSent", body: [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let sentState = panelController.state.rawValue
                let surfaced = panelController.state != .mascot
                print("VOICE_SENT_PANEL_STATE=\(sentState)")
                print("VOICE_SENT_COMPOSER_SURFACED=\(surfaced)")
                fflush(stdout)
                measure { obj2 in
                    let restoredDisplay = (obj2["composerDisplay"] as? String) ?? "?"
                    let restored = restoredDisplay != "none"
                    print("VOICE_ONLY_COMPOSER_RESTORED=\(restored)")
                    fflush(stdout)
                    exit(visible && !text.isEmpty
                        && composerDisplay == "none"
                        && sentState == "mascot" && !surfaced && restored ? 0 : 1)
                }
            }
        }
    }

    // Page readiness: the REAL `popAPI` must be installed before the drive.
    let readyJS = "!!(window.popAPI && window.popAPI.voiceState"
        + " && window.popAPI.voicePartial && window.popAPI.voiceOnly)"
    func waitReady(_ attempt: Int) {
        webView.evaluateJavaScript(readyJS) { value, _ in
            if (value as? Bool) == true {
                let driveJS = "(function(){try{"
                    + "window.popAPI.voiceState(true);"
                    + "window.popAPI.voiceOnly(true);"
                    + "window.popAPI.voicePartial('hello from probe');"
                    + "return 'driven';}catch(e){return 'ERR '+e;}})()"
                webView.evaluateJavaScript(driveJS) { v, _ in
                    print("VOICE_DLG_DRIVE=\(v as? String ?? "nil")")
                    fflush(stdout)
                    // Let the height request land and the bar grow before the
                    // rect is read: a clipped read would blame the CSS for a
                    // resize that simply had not settled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { assertVoiceOnly() }
                }
            } else if attempt > 60 {
                print("VOICE_DLG_PROBE_TIMEOUT no-popAPI")
                fflush(stdout)
                exit(1)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitReady(attempt + 1) }
            }
        }
    }
    waitReady(0)

    DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
        print("VOICE_DLG_PROBE_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-voice-dismiss`: a live mic must never outlive its visible surface.
///
/// The microphone cannot run headless (it needs TCC), so this asserts the
/// WIRING instead of audio: enter the voice-only surface EXACTLY as the app
/// does, collapse the panel through the SHARED dismissal funnel
/// (`popPanelHeightRequest` "mascot" → `hide()`), and prove (a) the panel
/// reached `mascot` and (b) the mic's owner received `popPanelDismissed` and
/// ran its auto-stop/reset. Gate: `VOICE_DISMISS_PROBE=ok`; exit 0/1.
@MainActor
private func runVoiceDismissProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    panelController.show()
    panelController.setPanelState(.bar, animated: false)
    let webView = panelController.appWebView.webView
    // The count only ever grows on a real dismissal; reading its BEFORE value
    // makes the assertion a true edge, not a lingering previous state.
    let before = chatController.voiceAutostopCount

    // Page readiness: the REAL `popAPI` must be installed before the drive.
    let readyJS = "!!(window.popAPI && window.popAPI.voiceState && window.popAPI.voiceOnly)"
    func waitReady(_ attempt: Int) {
        webView.evaluateJavaScript(readyJS) { value, _ in
            if (value as? Bool) == true {
                // Enter voice-only exactly as `toggleVoice()` does: reveal the
                // voice surface, then light the mic state.
                webView.evaluateJavaScript(
                    "window.popAPI.voiceOnly(true);window.popAPI.voiceState(true)"
                ) { _, _ in
                    after(0.5) {
                        // Collapse through the REAL funnel (Esc / ⌥Space / robot
                        // click all resolve to this same request).
                        NotificationCenter.default.post(
                            name: Notification.Name("popPanelHeightRequest"),
                            object: "mascot"
                        )
                        after(0.8) {
                            let state = panelController.state.rawValue
                            let reached = chatController.voiceAutostopCount > before
                            let ok = (state == "mascot") && reached
                            print("VOICE_DISMISS_PANEL_STATE=\(state)")
                            print("VOICE_DISMISS_NOTIFICATION_REACHED=\(reached)")
                            print("VOICE_DISMISS_PROBE=\(ok ? "ok" : "fail")")
                            fflush(stdout)
                            exit(ok ? 0 : 1)
                        }
                    }
                }
            } else if attempt > 60 {
                print("VOICE_DISMISS_PROBE=fail (timeout no-popAPI)")
                fflush(stdout)
                exit(1)
            } else {
                after(0.25) { waitReady(attempt + 1) }
            }
        }
    }
    waitReady(0)

    after(40) {
        print("VOICE_DISMISS_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-update-check`: the LIVE GitHub latest-release check plus the
/// version-compare truth table, with NO install side effects.
///
/// Gates: every `UPDATE_NEWER` row matches its expected value (numeric, not
/// lexicographic; a non-numeric component never reads as newer), the real tag
/// parses, and its first `.zip` asset URL resolves — then `UPDATE_PROBE=ok`.
@MainActor
private func runUpdateCheckProbe() {
    // Pure truth table FIRST (no network): the comparison must be numeric and
    // must never prompt on garbage.
    let cases: [(candidate: String, current: String, expected: Bool)] = [
        ("1.0", "1.0", false),
        ("1.0", "0.9", true),
        ("1.10", "1.9", true),
        ("1.0.x", "1.0", false)
    ]
    var tableOK = true
    for c in cases {
        let got = UpdateChecker.isNewer(c.candidate, than: c.current)
        if got != c.expected { tableOK = false }
        print("UPDATE_NEWER candidate=\(c.candidate) current=\(c.current) got=\(got) expected=\(c.expected)")
    }

    Task { @MainActor in
        var fetchOK = false
        var tagOK = false
        var zipOK = false
        do {
            let release = try await UpdateChecker.latestRelease()
            print("UPDATE_LATEST tag=\(release.tag) version=\(release.version)")
            print("UPDATE_ASSET=\(release.zipURL.lastPathComponent)")
            fetchOK = true
            tagOK = !release.tag.isEmpty && !release.version.hasPrefix("v")
            zipOK = release.zipURL.lastPathComponent.hasSuffix(".zip")
        } catch {
            print("UPDATE_FETCH_FAILED \(error)")
        }
        let ok = tableOK && fetchOK && tagOK && zipOK
        print("UPDATE_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("UPDATE_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-update-download`: downloads the REAL release zip into a TEMP dir,
/// unpacks it, and asserts the shipped `Pop.app/Contents/MacOS/Pop` exists.
///
/// It must NEVER touch the running bundle and NEVER call `downloadAndRelaunch`;
/// it proves only that the download→unzip→verify half of the pipeline works
/// against live data. Gate: `UPDATE_DOWNLOAD_PROBE=ok`; exit 0/1.
@MainActor
private func runUpdateDownloadProbe() {
    Task { @MainActor in
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("pop-update-probe-\(UUID().uuidString)")
        var ok = false
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let release = try await UpdateChecker.latestRelease()
            let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateChecker.UpdateError.http(http.statusCode)
            }
            let zip = work.appendingPathComponent("release.zip")
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: downloaded, to: zip)
            let extract = work.appendingPathComponent("extract")
            try fm.createDirectory(at: extract, withIntermediateDirectories: true)
            let status = try UpdateChecker.runTool(
                "/usr/bin/ditto", ["-x", "-k", zip.path, extract.path]
            )
            let binary = extract.appendingPathComponent("Pop.app/Contents/MacOS/Pop")
            let exists = status == 0 && fm.isExecutableFile(atPath: binary.path)
            print("UPDATE_DOWNLOAD_ASSET=\(release.zipURL.lastPathComponent)")
            print("UPDATE_DOWNLOAD_BINARY_EXISTS=\(exists)")
            ok = exists
        } catch {
            print("UPDATE_DOWNLOAD_FAILED \(error)")
        }
        // Never leave the temp tree behind (this path does not exit-through).
        try? FileManager.default.removeItem(at: work)
        print("UPDATE_DOWNLOAD_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("UPDATE_DOWNLOAD_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-jev-bridge`: proves jev is a FAIL-OPEN advisory.
///
/// (a) the pure parser (valid / missing choice / non-numeric probabilities /
/// garbage HTML), (b) the disabled gate returns nil FAST with no network, and
/// (c) an enabled-but-unreachable endpoint returns nil within the 3 s bound and
/// logs `JEV_UNAVAILABLE`. Gate: `JEV_PROBE=ok`; exit 0/1.
/// Thread-safe counter for probes whose callbacks may fire OFF-main (the
/// advisory runs on the caller's executor, not the main actor).
private final class JevProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

@MainActor
private func runJevBridgeProbe() {
    Task { @MainActor in
        var ok = true

        // (a) Parser truth table — URLSession-free. jev.md §2 wire dialect: the
        // envelope echoes a non-empty `model` and `answers` is a record keyed by
        // question id ("q").
        @MainActor func checkParse(_ name: String, _ json: String, expectNil: Bool) {
            let parsed = JevBridge.parseAdvisory(Data(json.utf8))
            let gotNil = parsed == nil
            if gotNil != expectNil { ok = false }
            print("JEV_PARSE \(name)=\(gotNil ? "nil" : "parsed")"
                + " choice=\(parsed?.choice ?? "-")")
        }
        // (a) REAL envelope -> parsed choice + probabilities.
        checkParse(
            "valid",
            #"{"model":"jev-1.13.0","answers":{"q":{"type":"choice","choice":"run","probabilities":{"run":0.83,"deny":0.1}}}}"#,
            expectNil: false
        )
        // (b) EMPTY envelope model -> nil (jev.md §2 fail-open rule: an envelope
        // without a non-empty `model` is not a decision response).
        checkParse(
            "empty-model",
            #"{"model":"","answers":{"q":{"type":"choice","choice":"run","probabilities":{"run":0.83}}}}"#,
            expectNil: true
        )
        // (c) MISSING answers -> nil.
        checkParse("missing-answers", #"{"model":"jev-1.13.0"}"#, expectNil: true)
        // (d) probabilities with non-numeric values -> nil.
        checkParse(
            "probabilities-not-numbers",
            #"{"model":"jev-1.13.0","answers":{"q":{"type":"choice","choice":"run","probabilities":{"run":"high"}}}}"#,
            expectNil: true
        )
        checkParse("html", "<html>not json</html>", expectNil: true)

        // A valid parse must yield the CHOICE and the PROBABILITIES, not merely a
        // non-nil: a parser that ignored the key could otherwise pass on the nil
        // check alone.
        let keyed = JevBridge.parseAdvisory(Data(
            #"{"model":"jev-1.13.0","answers":{"q":{"type":"choice","choice":"run","probabilities":{"run":0.83,"deny":0.1}}}}"#.utf8
        ))
        let keyedOK = keyed?.choice == "run"
            && keyed?.probabilities["run"] == 0.83
            && keyed?.probabilities["deny"] == 0.1
        if !keyedOK { ok = false }
        print("JEV_PARSE_KEYED_VALUES=\(keyedOK)")

        // (a1) WIRE MODEL (jev.md §2): the wire id is BARE — `typesafe/` is a
        // transport prefix and is stripped; empty config falls back to
        // `jev-latest`. This is the field whose omission was the live HTTP 400.
        let modelOK = JevBridge.wireModel(from: "") == "jev-latest"
            && JevBridge.wireModel(from: "typesafe/jev-latest") == "jev-latest"
            && JevBridge.wireModel(from: "jev-1.13.0") == "jev-1.13.0"
        if !modelOK { ok = false }
        print("JEV_MODEL_STRIP=\(modelOK)")

        // (a2) BYTE-IDENTITY: a card built WITHOUT the jev argument must carry no
        // `"jev"` key at all — the disabled path is indistinguishable from the
        // pre-jev card. `cardJSON` is pure, so this needs no gate or server.
        let plainCard = ApprovalGate.cardJSON(
            id: "probe",
            tool: "write_file",
            preview: "p",
            arguments: .object([:])
        )
        let byteIdentity = !plainCard.contains("\"jev\"")
        if !byteIdentity { ok = false }
        print("JEV_BYTE_IDENTITY=\(byteIdentity)")

        // (b) DISABLED gate: a config without jev keys -> fast nil, no network.
        let offPath = NSTemporaryDirectory() + "pop-jev-off-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", offPath, 1)
        try? FileManager.default.removeItem(atPath: offPath)
        let keychainBefore = KeychainStore.readCount
        let offStart = Date()
        let offAdvisory = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"])
        let offElapsed = Date().timeIntervalSince(offStart)
        let disabledFast = offAdvisory == nil && offElapsed < 1.0
        if !disabledFast { ok = false }
        // Disabled jev must not even READ the Keychain: no credentials touched.
        let keychainUntouched = KeychainStore.readCount == keychainBefore
        if !keychainUntouched { ok = false }
        print("JEV_DISABLED nil=\(offAdvisory == nil) elapsed=\(String(format: "%.3f", offElapsed))")
        print("JEV_KEYCHAIN_UNTOUCHED=\(keychainUntouched)")

        // (b2) THRESHOLD truth table on the extracted pure decision (0.82/0.99
        // drops, 0.82/0.7 shows, 0/0.5 drops).
        let thresholdOK = JevBridge.belowThreshold(strength: 0.82, floor: 0.99)
            && !JevBridge.belowThreshold(strength: 0.82, floor: 0.70)
            && JevBridge.belowThreshold(strength: 0, floor: 0.5)
        if !thresholdOK { ok = false }
        print("JEV_THRESHOLD_OK=\(thresholdOK)")

        // (c) FAIL-OPEN live: enabled, closed port (127.0.0.1:9), token absent.
        let onPath = NSTemporaryDirectory() + "pop-jev-on-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", onPath, 1)
        var onConfig = PopConfig.defaults
        onConfig.jevEnabled = true
        onConfig.jevEndpoint = "http://127.0.0.1:9"
        try? onConfig.write()
        let onStart = Date()
        let onAdvisory = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"])
        let onElapsed = Date().timeIntervalSince(onStart)
        // The bound must include the WORST-CASE Keychain read (10 s) plus the
        // request timeout (3 s): a cold/slow Keychain makes the advisory's own
        // 3 s bound unreachable, and that combination — not jev itself — is what
        // flaked this assertion. 1 s margin for scheduling.
        let bounded = onAdvisory == nil
            && onElapsed <= KeychainStore.timeout + JevBridge.timeout + 1
        if !bounded { ok = false }
        print("JEV_UNREACHABLE nil=\(onAdvisory == nil) elapsed=\(String(format: "%.3f", onElapsed))")

        // (d) KEYCHAIN MEMOIZATION: with a token present, two consecutive
        // advisory calls must add AT MOST ONE Keychain read — a successful read
        // is cached, so a slow Keychain is paid once, not per advisory. This is
        // what keeps the elapsed bound above from ever flaking again. The prior
        // token (a leftover test credential, if any) is SAVED and RESTORED so a
        // probe never clobbers real state.
        let memoPath = NSTemporaryDirectory() + "pop-jev-memo-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", memoPath, 1)
        var memoConfig = PopConfig.defaults
        memoConfig.jevEnabled = true
        memoConfig.jevEndpoint = "http://127.0.0.1:9"
        try? memoConfig.write()
        let priorToken = KeychainStore.apiKey(for: JevBridge.tokenAccount)
        _ = KeychainStore.setAPIKey("probe-jev-token", for: JevBridge.tokenAccount)
        let readBefore = KeychainStore.readCount
        let first = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"])
        let second = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"])
        let readDelta = KeychainStore.readCount - readBefore
        let memoized = readDelta <= 1 && first == nil && second == nil
        if !memoized { ok = false }
        print("JEV_KEYCHAIN_MEMOIZED=\(memoized) reads=\(readDelta)")
        if let priorToken, !priorToken.isEmpty {
            _ = KeychainStore.setAPIKey(priorToken, for: JevBridge.tokenAccount)
        } else {
            _ = KeychainStore.deleteAPIKey(for: JevBridge.tokenAccount)
        }

        // (e) ONE-SHOT DEGRADATION NOTICE: an enabled-but-unreachable jev fires
        // the `onFirstFailure` seam exactly once (not per call), and a success
        // re-arms it. The closed-port endpoint can never actually answer, so
        // `noteSuccess` stands in for a real recovery (the sanctioned seam).
        let noticePath = NSTemporaryDirectory() + "pop-jev-notice-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", noticePath, 1)
        var noticeConfig = PopConfig.defaults
        noticeConfig.jevEnabled = true
        noticeConfig.jevEndpoint = "http://127.0.0.1:9"
        try? noticeConfig.write()
        let counter = JevProbeCounter()
        JevBridge.onFirstFailure = { _ in counter.bump() }
        // Arm the latch: earlier sections already failed on this run without a
        // callback, so a recovery must precede the first observed failure.
        JevBridge.noteSuccess()
        _ = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"]) // 1st: fires
        _ = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"]) // 2nd: silent
        let firstOnce = counter.count == 1
        JevBridge.noteSuccess()                                                       // recovered
        _ = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"]) // 3rd: re-armed
        let rearmed = counter.count == 2
        if !firstOnce { ok = false }
        if !rearmed { ok = false }
        print("JEV_FIRST_FAILURE_ONCE=\(firstOnce)")
        print("JEV_FAILURE_REARM=\(rearmed)")

        // (e2) DEFAULT CONFIG (jev disabled) must NEVER fire the seam — the
        // callback is a tool of the ENABLED path only.
        let off2Path = NSTemporaryDirectory() + "pop-jev-off2-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", off2Path, 1)
        try? FileManager.default.removeItem(atPath: off2Path)
        JevBridge.noteSuccess() // armed, so a firing here would be a real bug
        let off2Counter = JevProbeCounter()
        JevBridge.onFirstFailure = { _ in off2Counter.bump() }
        _ = await JevBridge.advisory(goal: "g", question: "q", options: ["a": "b"])
        let disabledSilent = off2Counter.count == 0
        if !disabledSilent { ok = false }
        print("JEV_DISABLED_NO_NOTICE=\(disabledSilent)")

        // Restore the seam to nil so later probes stay silent, then clean up.
        JevBridge.onFirstFailure = nil
        try? FileManager.default.removeItem(atPath: noticePath)

        try? FileManager.default.removeItem(atPath: offPath)
        try? FileManager.default.removeItem(atPath: onPath)
        try? FileManager.default.removeItem(atPath: memoPath)
        try? FileManager.default.removeItem(atPath: off2Path)

        print("JEV_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("JEV_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-jev-runlabel`: the SPEC §4.4 use (c) run-state labeler.
///
/// Proves the labeling is READ-ONLY on the loop: (a) with jev disabled the path
/// is a no-op (`advisory` fast-nils — no network, no Keychain read — and the
/// loop's fire condition is false); (b) enabled + unreachable returns nil, the
/// label logs `skipped=unavailable`, no notice is pushed, and a simulated round
/// counter is untouched — `JEV_RUNLABEL_UNAVAILABLE_HANDLED=true`; (c) the pure
/// decision and fire-condition tables. Gate: `JEV_RUNLABEL_PROBE=ok`; exit 0/1.
@MainActor
private func runJevRunLabelProbe() {
    Task { @MainActor in
        var ok = true

        // (c) PURE choice-to-notice truth table.
        let decideCases: [(choice: String, strength: Double, floor: Double, notice: Bool)] = [
            ("stall", 0.87, 0.7, true),
            ("thriving", 0.9, 0.7, false),
            ("stall", 0.5, 0.7, false),
            ("drift", 0.95, 0.7, true)
        ]
        for c in decideCases {
            let decision = JevRunLabel.shouldNotice(
                choice: c.choice,
                strength: c.strength,
                floor: c.floor
            )
            let pass = decision.notice == c.notice
            if !pass { ok = false }
            print("JEV_RUNLABEL_DECIDE \(c.choice)/\(c.strength)/\(c.floor)"
                + " notice=\(decision.notice) label=\(decision.label) ok=\(pass)")
        }

        // (c2) Fire-condition table: disabled never labels; a reads-only turn
        // (zero mutating rounds) never labels; only a multiple of 6 does.
        let fireOK = !JevRunLabel.shouldLabel(enabled: false, mutatingRounds: 6)
            && !JevRunLabel.shouldLabel(enabled: true, mutatingRounds: 0)
            && JevRunLabel.shouldLabel(enabled: true, mutatingRounds: 6)
            && !JevRunLabel.shouldLabel(enabled: true, mutatingRounds: 11)
        if !fireOK { ok = false }
        print("JEV_RUNLABEL_FIRE_OK=\(fireOK)")

        // (a) DISABLED config: the label path is a no-op. The fire condition is
        // false, and the underlying advisory fast-nils with NO Keychain read and
        // no network.
        let offPath = NSTemporaryDirectory() + "pop-jev-runlabel-off-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", offPath, 1)
        try? FileManager.default.removeItem(atPath: offPath)
        let keychainBefore = KeychainStore.readCount
        nonisolated(unsafe) var noticedOff = false
        let offStart = Date()
        let offToken = await AgentLoop.runStateLabel(
            goal: "disabled probe",
            threshold: 0.7,
            round: 6
        ) { _ in noticedOff = true }
        let offElapsed = Date().timeIntervalSince(offStart)
        let disabledNoOp = !noticedOff
            && !JevRunLabel.shouldLabel(enabled: false, mutatingRounds: 6)
            && KeychainStore.readCount == keychainBefore
            && offElapsed < 1.0
        if !disabledNoOp { ok = false }
        print("JEV_RUNLABEL_DISABLED noop=\(disabledNoOp) token=\(offToken)"
            + " elapsed=\(String(format: "%.3f", offElapsed))")

        // (b) FAIL-OPEN: enabled + unreachable endpoint -> advisory nil -> the
        // label reports unavailable, pushes nothing, and leaves loop state alone.
        let onPath = NSTemporaryDirectory() + "pop-jev-runlabel-on-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", onPath, 1)
        var onConfig = PopConfig.defaults
        onConfig.jevEnabled = true
        onConfig.jevEndpoint = "http://127.0.0.1:9"
        try? onConfig.write()
        nonisolated(unsafe) var noticedOn = false
        let roundCounter = 6
        let onToken = await AgentLoop.runStateLabel(
            goal: "unreachable probe",
            threshold: 0.7,
            round: roundCounter
        ) { _ in noticedOn = true }
        let failOpen = onToken == "skipped=unavailable" && !noticedOn && roundCounter == 6
        if !failOpen { ok = false }
        print("JEV_RUNLABEL_UNAVAILABLE_HANDLED=\(failOpen) token=\(onToken)")

        try? FileManager.default.removeItem(atPath: offPath)
        try? FileManager.default.removeItem(atPath: onPath)

        print("JEV_RUNLABEL_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("JEV_RUNLABEL_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-jev-route`: the SPEC §4.4 use (a) skill router.
///
/// Proves routing is READ-ONLY on the loop: (a) the pure choice-to-hint truth
/// table — a real class above the floor hints, below the floor drops, and a
/// class that does NOT exist drops even at certainty; (b) with jev disabled the
/// path is a no-op (`advisory` fast-nils — no network, no Keychain read — and the
/// turn's messages are BYTE-IDENTICAL); (c) enabled + unreachable returns nil and
/// the loop injects nothing — `JEV_ROUTE_UNAVAILABLE_HANDLED=true`. Gate:
/// `JEV_ROUTE_PROBE=ok`; exit 0/1.
@MainActor
private func runJevRouteProbe() {
    Task { @MainActor in
        var ok = true

        // (a) PURE choice-to-hint truth table, URLSession-free. The Advisory is
        // built directly; no server or config is involved.
        @MainActor func checkHint(
            _ name: String,
            choice: String,
            strength: Double,
            floor: Double,
            expectNil: Bool
        ) {
            let advisory = JevBridge.Advisory(
                choice: choice,
                probabilities: [choice: strength]
            )
            let hint = JevRoute.hint(from: advisory, floor: floor)
            let pass = (hint == nil) == expectNil
            if !pass { ok = false }
            print("JEV_ROUTE_HINT \(name)=\(hint ?? "nil") ok=\(pass)")
        }
        checkHint("browser-strong", choice: "browser", strength: 0.81, floor: 0.7, expectNil: false)
        checkHint("browser-weak", choice: "browser", strength: 0.5, floor: 0.7, expectNil: true)
        checkHint("unknown-class", choice: "nonexistent-class", strength: 0.95, floor: 0.7, expectNil: true)

        // (a2) Fire-condition table: disabled never routes.
        let fireOK = !JevRoute.shouldRoute(enabled: false)
            && JevRoute.shouldRoute(enabled: true)
        if !fireOK { ok = false }
        print("JEV_ROUTE_FIRE_OK=\(fireOK)")

        // (a3) HANDS-ON CONSISTENCY: every class the promotion gate treats as
        // hands-on must be a REAL option. Renaming an option key must be caught
        // HERE rather than silently stop promoting that capability.
        let handsOnConsistent = JevRoute.handsOnClasses.allSatisfy {
            JevRoute.options[$0] != nil
        }
        if !handsOnConsistent { ok = false }
        print("JEV_ROUTE_HANDSON_CONSISTENT=\(handsOnConsistent)")

        // (b) DISABLED: no-op. The pure gate is false, the underlying advisory
        // fast-nils with NO Keychain read and no network, and a real message
        // array is BYTE-IDENTICAL — nothing is injected.
        let offPath = NSTemporaryDirectory() + "pop-jev-route-off-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", offPath, 1)
        try? FileManager.default.removeItem(atPath: offPath)
        let seed: [ChatMessage] = [
            ChatMessage(role: .user, text: "hello"),
            ChatMessage(role: .assistant, text: "hi"),
            ChatMessage(role: .user, text: "do a thing")
        ]
        let keychainBefore = KeychainStore.readCount
        let offStart = Date()
        let offHint = await AgentLoop.routeHint(enabled: false, goal: "do a thing", threshold: 0.7)
        let offElapsed = Date().timeIntervalSince(offStart)
        let offMessages = offHint.map { AgentLoop.injectRouteHint($0, into: seed) } ?? seed
        let disabledNoOp = offHint == nil
            && offMessages == seed
            && KeychainStore.readCount == keychainBefore
            && offElapsed < 1.0
            && !JevRoute.shouldRoute(enabled: false)
        if !disabledNoOp { ok = false }
        print("JEV_ROUTE_DISABLED noop=\(disabledNoOp) elapsed=\(String(format: "%.3f", offElapsed))")
        print("JEV_ROUTE_BYTE_IDENTICAL=\(offMessages == seed)")

        // (c) FAIL-OPEN: enabled + unreachable endpoint -> advisory nil -> the
        // router injects nothing and leaves the messages alone.
        let onPath = NSTemporaryDirectory() + "pop-jev-route-on-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", onPath, 1)
        var onConfig = PopConfig.defaults
        onConfig.jevEnabled = true
        onConfig.jevEndpoint = "http://127.0.0.1:9"
        try? onConfig.write()
        let onHint = await AgentLoop.routeHint(enabled: true, goal: "unreachable probe", threshold: 0.7)
        let onMessages = onHint.map { AgentLoop.injectRouteHint($0, into: seed) } ?? seed
        let failOpen = onHint == nil && onMessages == seed
        if !failOpen { ok = false }
        print("JEV_ROUTE_UNAVAILABLE_HANDLED=\(failOpen)")

        try? FileManager.default.removeItem(atPath: offPath)
        try? FileManager.default.removeItem(atPath: onPath)

        print("JEV_ROUTE_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("JEV_ROUTE_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-routing-fallback`: THE ROUTE-AWARE PROVIDER PROMOTION.
///
/// THE INVARIANT: a turn is served by a brain that HAS the tools its routed
/// capability needs. The on-device brain is tool-less for mutating capabilities
/// (every such tool is refused with `FM_TOOL_SKIP ... not-on-device-eligible`),
/// so a route that names computer-use or browser must be served by the REMOTE
/// brain — visibly, and only when a remote is actually configured. MEASURED
/// instance: a real "summarize MY LinkedIn notifications in Brave" turn was
/// served by the on-device brain, which improvised via web_lookup and fabricated
/// user-specific content.
///
/// UNSEEN INPUTS this pins: route=files -> unchanged on-device; jev disabled ->
/// unchanged; no remote configured -> stays on-device (no crash); the user
/// already on `openai-compat` never reaches this path (remote is primary); the
/// fallback seam disabled -> no promotion.
///
/// Gates: `ROUTE_FALLBACK_REMOTE=true`, `ROUTE_FALLBACK_COMPUTER_USE=true`,
/// `ROUTE_FALLBACK_UNCHANGED=true`, `ROUTE_FALLBACK_DISABLED_NOOP=true`,
/// `ROUTE_FALLBACK_NO_REMOTE=true`, `ROUTE_FALLBACK_COMPAT_UNCHANGED=true`,
/// `ROUTE_FALLBACK_NOTICE_RENDERED=true`, plus `ROUTE_FALLBACK_PROBE=ok`; exit 0/1.
@MainActor
private func runRoutingFallbackProbe() {
    _ = NSApplication.shared

    let path = NSTemporaryDirectory() + "pop-routing-fallback-\(UUID().uuidString).json"
    setenv("POP_CONFIG_PATH", path, 1)

    func seedConfig(
        baseURL: String,
        jevEnabled: Bool,
        provider: String = "apple-fm"
    ) -> PopConfig {
        var config = PopConfig.defaults
        config.provider = provider
        config.contextMode = false
        config.baseURL = baseURL
        config.jevEnabled = jevEnabled
        try? config.write()
        return (try? PopConfig.load()) ?? config
    }

    let seams = ProviderTestSeams.shared
    seams.availability = .available
    seams.fallbackEnabled = true
    seams.primaryProviderOverride = nil
    // A healthy injected remote: the SAME provider the M9 fallback would use, so
    // the promotion can be measured without real credentials. It answers, so the
    // notice-render case can prove the turn was actually served by the remote.
    let remote = ScriptedProvider(nativelyExecutesTools: false, box: ScriptedProviderBox()) {
        _, _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("cloud answer"))
            continuation.yield(.done("cloud answer"))
            continuation.finish()
        }
    }
    seams.fallbackProviderOverride = remote

    let messages = [ChatMessage(
        role: .user,
        text: "summarize my LinkedIn notifications in Brave"
    )]

    Task { @MainActor in
        var ok = true
        defer {
            try? FileManager.default.removeItem(atPath: path)
            print("ROUTE_FALLBACK_PROBE=\(ok ? "ok" : "fail")")
            fflush(stdout)
            exit(ok ? 0 : 1)
        }

        // (a) route=browser + on-device available + remote configured
        //     -> REMOTE, with the routing marker and a visible notice.
        seams.forcedRouteChoice = ForcedRouteChoice(value: "browser")
        let configA = seedConfig(baseURL: "https://example.invalid/v1", jevEnabled: true)
        let routeA = await ChatController.turnRouteChoice(config: configA, messages: messages)
        let choiceA = ChatController.resolveProvider(configA, route: routeA)
        let promoted = routeA == "browser"
            && choiceA.decision == "remote-routing"
            && choiceA.reason == "routing-needs-tools"
            && choiceA.notice?.contains("cloud brain") == true
            && choiceA.primary.isHealthy
            && choiceA.fallbackFactory == nil
        if !promoted { ok = false }
        print("ROUTE_FALLBACK_REMOTE=\(promoted) decision=\(choiceA.decision)")
        print("ROUTE_FALLBACK_NOTICE=\(choiceA.notice ?? "-")")

        // (a0) route=computer-use -> also promoted (the same hands-on set).
        seams.forcedRouteChoice = ForcedRouteChoice(value: "computer-use")
        let configA0 = seedConfig(baseURL: "https://example.invalid/v1", jevEnabled: true)
        let routeA0 = await ChatController.turnRouteChoice(config: configA0, messages: messages)
        let choiceA0 = ChatController.resolveProvider(configA0, route: routeA0)
        let computerUse = routeA0 == "computer-use" && choiceA0.decision == "remote-routing"
        if !computerUse { ok = false }
        print("ROUTE_FALLBACK_COMPUTER_USE=\(computerUse) decision=\(choiceA0.decision)")

        // (b) route=files -> on-device, unchanged (byte-identical behavior).
        seams.forcedRouteChoice = ForcedRouteChoice(value: "files")
        let routeB = await ChatController.turnRouteChoice(config: configA, messages: messages)
        let choiceB = ChatController.resolveProvider(configA, route: routeB)
        let unchanged = routeB == "files" && choiceB.decision == "on-device"
        if !unchanged { ok = false }
        print("ROUTE_FALLBACK_UNCHANGED=\(unchanged) decision=\(choiceB.decision)")

        // (c) jev disabled -> no route, unchanged.
        seams.forcedRouteChoice = nil
        let configC = seedConfig(baseURL: "https://example.invalid/v1", jevEnabled: false)
        let routeC = await ChatController.turnRouteChoice(config: configC, messages: messages)
        let choiceC = ChatController.resolveProvider(configC, route: routeC)
        let disabledNoop = routeC == nil && choiceC.decision == "on-device"
        if !disabledNoop { ok = false }
        print("ROUTE_FALLBACK_DISABLED_NOOP=\(disabledNoop) route=\(routeC ?? "-")")

        // (d) route=browser but NO remote configured -> stays on-device, no crash.
        seams.forcedRouteChoice = ForcedRouteChoice(value: "browser")
        seams.fallbackProviderOverride = nil
        let configD = seedConfig(baseURL: "", jevEnabled: true)
        let routeD = await ChatController.turnRouteChoice(config: configD, messages: messages)
        let choiceD = ChatController.resolveProvider(configD, route: routeD)
        let noRemote = routeD == "browser" && choiceD.decision == "on-device"
        if !noRemote { ok = false }
        print("ROUTE_FALLBACK_NO_REMOTE=\(noRemote) decision=\(choiceD.decision)")

        // (f) an `openai-compat` primary user: the remote is primary regardless of
        // route, so the promotion branch is never entered and the decision is
        // unchanged.
        seams.forcedRouteChoice = ForcedRouteChoice(value: "browser")
        let configF = seedConfig(
            baseURL: "https://example.invalid/v1",
            jevEnabled: true,
            provider: "openai-compat"
        )
        let routeF = await ChatController.turnRouteChoice(config: configF, messages: messages)
        let choiceF = ChatController.resolveProvider(configF, route: routeF)
        let compatUnchanged = choiceF.decision == "remote"
            && choiceF.reason != "routing-needs-tools"
        if !compatUnchanged { ok = false }
        print("ROUTE_FALLBACK_COMPAT_UNCHANGED=\(compatUnchanged) decision=\(choiceF.decision)")

        // (e) THE VISIBILITY GATE. A promoted turn driven through the REAL
        // `handleChatSend` must RENDER its notice in the transcript — delete the
        // `pushBrainNotice` call in `handleChatSend` and THIS fails. Measured from
        // the same render sink the M9 fallback notice test uses, never from the
        // wording alone.
        seams.fallbackProviderOverride = remote
        seams.forcedRouteChoice = ForcedRouteChoice(value: "browser")
        _ = seedConfig(baseURL: "https://example.invalid/v1", jevEnabled: true)
        ProviderTestSeams.shared.renderedLines = []
        ProviderTestSeams.shared.suppressedLines = []
        let noticeController = makeProbeChatController()
        noticeController.handleBridgeMessage(
            type: "chatSend",
            body: ["text": "summarize my LinkedIn notifications in Brave"]
        )
        await waitForTurnToSettle(noticeController, seconds: 10)
        let noticeFragment = "using the cloud brain for its tools"
        let noticeRendered = ProviderTestSeams.shared.renderedLines.contains {
            $0.contains(noticeFragment)
        }
        let servedRemote = noticeController.lastAnsweredBy.contains("ScriptedProvider")
            && noticeController.lastAnswerFull == "cloud answer"
        let noticeOK = noticeRendered && servedRemote
        if !noticeOK { ok = false }
        print("ROUTE_FALLBACK_NOTICE_RENDERED=\(noticeOK)"
            + " rendered=\(noticeRendered) provider=\(noticeController.lastAnsweredBy)")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("ROUTE_FALLBACK_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-surfaces`: ONE audit that drives and asserts EVERY panel surface.
///
/// WHY one command: these surfaces are SIBLINGS of a shared container (the
/// launcher body). A change to one — pinning the composer to the bottom, moving
/// the voice dialog out of the form — can silently push a sibling off-screen.
/// That is exactly how the `+` sessions menu AND the voice dialog both went
/// invisible. "The JS handler ran" is not evidence of visibility, so every
/// surface is asserted from its RENDERED DOM rect (and the native pill band from
/// its frame); the probe fails if ANY is off-screen. Run it after ANY
/// panel-layout change.
///
/// Gates: a `SURFACE <name> visible=true rect=...` line per surface plus
/// `SURFACES_OK=true`; exit non-zero otherwise.
@MainActor
private func runSurfacesProbe(panelController: PanelController) {
    panelController.show()
    panelController.setPanelState(.bar, animated: false)
    let webView = panelController.appWebView.webView
    var ok = true

    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }

    /// Rendered-DOM assertion for one element id. `requireInside` tightens
    /// "visible" to "fully inside the viewport" (popovers must not clip).
    func measure(_ id: String, _ label: String, requireInside: Bool, _ done: @escaping () -> Void) {
        let js = "(function(){"
            + "var d=document.getElementById(\(jsString(id)));"
            + "if(!d){return JSON.stringify({visible:false,inside:false,rect:[0,0,0,0]});}"
            + "var cs=getComputedStyle(d);var r=d.getBoundingClientRect();"
            + "var vw=window.innerWidth,vh=window.innerHeight;"
            + "var ix=Math.max(0,Math.min(r.right,vw)-Math.max(r.left,0));"
            + "var iy=Math.max(0,Math.min(r.bottom,vh)-Math.max(r.top,0));"
            + "var vis=(!d.hidden)&&cs.display!=='none'&&cs.visibility!=='hidden'"
            + "&&parseFloat(cs.opacity||'1')>0&&ix>0&&iy>0;"
            + "var inside=r.top>=-0.5&&r.left>=-0.5&&r.right<=vw+0.5&&r.bottom<=vh+0.5;"
            + "return JSON.stringify({visible:vis,inside:inside,body:document.body.className,"
            + "vp:[vw,vh],display:cs.display,"
            + "rows:document.querySelectorAll('#sessions .session-row').length,"
            + "rect:[Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)]});"
            + "})()"
        webView.evaluateJavaScript(js) { value, _ in
            let obj = ((value as? String ?? "{}").data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            let visible = (obj["visible"] as? Bool) ?? false
            let inside = (obj["inside"] as? Bool) ?? false
            let body = (obj["body"] as? String) ?? "?"
            let rows = (obj["rows"] as? NSNumber)?.intValue ?? 0
            let vp = ((obj["vp"] as? [NSNumber]) ?? []).map { $0.intValue }
            let rect = ((obj["rect"] as? [NSNumber]) ?? []).map { $0.intValue }
            let r = rect.count == 4 ? rect : [0, 0, 0, 0]
            // The menu audit runs under WORST-CASE load: ≥15 session rows, so a
            // missing/failed seed also fails the gate rather than passing empty.
            let pass = (requireInside ? (visible && inside) : visible)
                && !(label == "menu" && rows < 15)
            if !pass { ok = false }
            print("SURFACE \(label) visible=\(visible)"
                + (requireInside ? " inside=\(inside)" : "")
                + " rect=(\(r[0]),\(r[1]),\(r[2]),\(r[3]))"
                + " vp=(\(vp.count == 2 ? vp[0] : 0),\(vp.count == 2 ? vp[1] : 0))"
                + (label == "menu" ? " rows=\(rows)" : "")
                + " body=\(body)")
            fflush(stdout)
            done()
        }
    }

    /// SESSION-LOADED layout assertion. Measures the transcript, status and
    /// composer rects and derives the two dead-band numbers:
    ///   GAP_STATUS_COMPOSER = composer.top - status.bottom (the space the user
    ///     sees between the "ready" line and the bar),
    ///   DEAD_BAND = space between the transcript's bottom and the composer's
    ///     top, EXCLUDING the status line's own height.
    /// Both must be <= 12 or `SURFACES_OK` is false. The numbers print either way.
    func measureSessionLoaded(_ done: @escaping () -> Void) {
        let js = "(function(){"
            + "function rr(id){var e=document.getElementById(id);if(!e)return null;"
            + "var x=e.getBoundingClientRect();"
            + "return {l:x.left,t:x.top,r:x.right,b:x.bottom,w:x.width,h:x.height};}"
            + "var b=rr('bubble'),s=rr('streamStatus'),c=rr('composer');"
            + "if(!b||!c){return JSON.stringify({error:'missing'});}"
            + "var sDisp=getComputedStyle(document.getElementById('streamStatus')).display;"
            + "var sVis=s&&sDisp!=='none'&&s.h>0;"
            + "var gap=Math.round(c.t-(sVis?s.b:b.b));"
            + "var dead=Math.round(c.t-b.b-(sVis?s.h:0));"
            + "var vw=window.innerWidth,vh=window.innerHeight;"
            + "var ix=Math.max(0,Math.min(b.r,vw)-Math.max(b.l,0));"
            + "var iy=Math.max(0,Math.min(b.b,vh)-Math.max(b.t,0));"
            + "return JSON.stringify({visible:ix>0&&iy>0,gap:gap,dead:dead,statusVisible:sVis,"
            + "t:[Math.round(b.l),Math.round(b.t),Math.round(b.w),Math.round(b.h)],"
            + "s:[Math.round(s.l),Math.round(s.t),Math.round(s.w),Math.round(s.h)],"
            + "c:[Math.round(c.l),Math.round(c.t),Math.round(c.w),Math.round(c.h)],"
            + "vp:[vw,vh]});})()"
        webView.evaluateJavaScript(js) { value, _ in
            let obj = ((value as? String ?? "{}").data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            let visible = (obj["visible"] as? Bool) ?? false
            let gap = (obj["gap"] as? NSNumber)?.intValue ?? 999
            let dead = (obj["dead"] as? NSNumber)?.intValue ?? 999
            let statusVisible = (obj["statusVisible"] as? Bool) ?? false
            let t = ((obj["t"] as? [NSNumber]) ?? []).map { $0.intValue }
            let s = ((obj["s"] as? [NSNumber]) ?? []).map { $0.intValue }
            let c = ((obj["c"] as? [NSNumber]) ?? []).map { $0.intValue }
            func f(_ a: [Int]) -> String { a.count == 4 ? "(\(a[0]),\(a[1]),\(a[2]),\(a[3]))" : "(0,0,0,0)" }
            let pass = visible && gap <= 12 && dead <= 12
            if !pass { ok = false }
            print("SURFACE transcript visible=\(visible) rect=\(f(t))")
            print("TRANSCRIPT_RECT=\(f(t))")
            print("STATUS_RECT=\(f(s)) statusVisible=\(statusVisible)")
            print("COMPOSER_RECT=\(f(c))")
            print("GAP_STATUS_COMPOSER=\(gap)")
            print("DEAD_BAND=\(dead)")
            fflush(stdout)
            done()
        }
    }

    func run() {
        // 1. composer — bar state, nothing else open.
        measure("composer", "composer", requireInside: false) {
            // 2. sessions menu under WORST-CASE load: ≥15 rows. The popover must
            //    CAP and scroll — a long list must never push its top off-screen.
            let rows = (1...18).map { i in
                "{\"id\":\"audit-\(i)\",\"title\":\"Audit session \(i)\",\"time\":\"10:\(i)\",\"turns\":\(i)}"
            }.joined(separator: ",")
            let seedOpen = "window.popAPI.sessions([\(rows)]);window.popAPI.openMenu()"
            webView.evaluateJavaScript(seedOpen) { _, _ in
                after(1.4) {
                    measure("menu", "menu", requireInside: true) {
                        webView.evaluateJavaScript("window.popAPI.closeMenu()") { _, _ in
                            after(0.5) {
                                // 3. transcript — seed a turn, then `full`.
                                let entries = "[{\"role\":\"user\",\"text\":\"audit question\"},"
                                    + "{\"role\":\"assistant\",\"text\":\"audit answer\"}]"
                                webView.evaluateJavaScript("window.popAPI.history(\(entries))") { _, _ in
                                    panelController.setPanelState(.full, animated: false)
                                    // Show the "ready" status line, as in the user's
                                    // screenshot, so the gap is measured on the real layout.
                                    webView.evaluateJavaScript(
                                        "window.popAPI.__setStreamStatusForProbe('ready','ready')"
                                    ) { _, _ in }
                                    after(1.4) {
                                        measureSessionLoaded {
                                            // 4. voice-only from a LOADED session: the panel
                                            //    must SHRINK to the dialog and the draft must
                                            //    PERSIST across the re-listen. Seed STALE first:
                                            //    the draft is user-owned, so re-entry APPENDS
                                            //    rather than clearing it (only Send/× clear).
                                            webView.evaluateJavaScript(
                                                "window.popAPI.voiceState(true);"
                                                    + "window.popAPI.voicePartial('STALE')"
                                            ) { _, _ in
                                                after(0.3) {
                                                    // Fresh entry: exactly what `toggleVoice` does.
                                                    webView.evaluateJavaScript(
                                                        "window.popAPI.voiceOnly(true);"
                                                            + "window.popAPI.voiceState(true)"
                                                    ) { _, _ in
                                                        NotificationCenter.default.post(
                                                            name: Notification.Name("popPanelVoiceSurface"),
                                                            object: nil
                                                        )
                                                        after(2.6) {
                                                            let js = "(function(){"
                                                                + "var d=document.getElementById('voiceDlg');"
                                                                + "var t=document.getElementById('voiceText');"
                                                                + "if(!d){return JSON.stringify({error:'no dlg'});}"
                                                                + "var cs=getComputedStyle(d);var r=d.getBoundingClientRect();"
                                                                + "var vw=window.innerWidth,vh=window.innerHeight;"
                                                                + "var ix=Math.max(0,Math.min(r.right,vw)-Math.max(r.left,0));"
                                                                + "var iy=Math.max(0,Math.min(r.bottom,vh)-Math.max(r.top,0));"
                                                                + "var vis=(!d.hidden)&&cs.display!=='none'&&ix>0&&iy>0;"
                                                                + "return JSON.stringify({visible:vis,dead:Math.round(r.top),"
                                                                + "text:(t?t.textContent:''),"
                                                                + "pos:cs.position,bottom:cs.bottom,"
                                                                + "bodyH:document.body.clientHeight,vh:window.innerHeight,"
                                                                + "cls:document.body.className,"
                                                                + "rect:[Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)]});"
                                                                + "})()"
                                                            webView.evaluateJavaScript(js) { value, _ in
                                                                let obj = ((value as? String ?? "{}").data(using: .utf8)
                                                                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
                                                                let vis = (obj["visible"] as? Bool) ?? false
                                                                let dead = (obj["dead"] as? NSNumber)?.intValue ?? 999
                                                                let text = (obj["text"] as? String) ?? ""
                                                                let rect = ((obj["rect"] as? [NSNumber]) ?? []).map { $0.intValue }
                                                                let r = rect.count == 4 ? rect : [0, 0, 0, 0]
                                                                let panelH = Int(panelController.panel.frame.height)
                                                                // Draft persistence: the seeded "STALE"
                                                                // must SURVIVE the re-listen (append
                                                                // semantics) — Send/× are what clear it.
                                                                let preserved = (text == "STALE")
                                                                if !vis || dead > 12 || !preserved { ok = false }
                                                                print("SURFACE voiceDlg visible=\(vis) rect=(\(r[0]),\(r[1]),\(r[2]),\(r[3]))")
                                                                print("VOICE_ONLY_DLG_VISIBLE=\(vis)")
                                                                print("VOICE_ONLY_PANEL_H=\(panelH)")
                                                                print("VOICE_ONLY_DEAD_BAND=\(dead)")
                                                                print("VOICE_DRAFT_PRESERVED=\(preserved)")
                                                                fflush(stdout)
                                                                // 4b. SESSION BOUNDARY. The recognizer
                                                                //     starts a NEW utterance with NO mic
                                                                //     toggle — the live trace shows the
                                                                //     cumulative length DROP (13->10,
                                                                //     11->3) after a pause. Drive it
                                                                //     headlessly: a non-prefix partial is
                                                                //     a new utterance, so the prior session
                                                                //     must COMMIT (never be replaced).
                                                                let sessionJS = "(function(){"
                                                                    + "window.popAPI.__resetVoiceForProbe();"
                                                                    + "window.popAPI.voiceState(true);"
                                                                    + "window.popAPI.voicePartial('hello world now');"
                                                                    + "window.popAPI.voicePartial('second one here');"
                                                                    + "var t=document.getElementById('voiceText').textContent;"
                                                                    + "window.popAPI.voicePartial('second one here');"
                                                                    + "var t2=document.getElementById('voiceText').textContent;"
                                                                    + "return JSON.stringify({"
                                                                    + "appended:(t==='hello world now second one here'),"
                                                                    + "stable:(t2===t)});"
                                                                    + "})()"
                                                                webView.evaluateJavaScript(sessionJS) { value, _ in
                                                                    let o = ((value as? String ?? "{}").data(using: .utf8)
                                                                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
                                                                    let appended = (o["appended"] as? Bool) ?? false
                                                                    // Identical re-delivery is a prefix
                                                                    // revision, not a reset: no duplication.
                                                                    let stable = (o["stable"] as? Bool) ?? false
                                                                    if !appended || !stable { ok = false }
                                                                    print("VOICE_SESSION_APPEND=\(appended)")
                                                                    print("VOICE_REVISION_STABLE=\(stable)")
                                                                    fflush(stdout)
                                                                }
                                                                webView.evaluateJavaScript("window.popAPI.voiceOnly(false)") { _, _ in
                                                                    // 5. mascot pill band — NATIVE frame.
                                                                    panelController.setPanelState(.mascot, animated: false)
                                                                    panelController.mascotModel.isHovered = true
                                                                    after(0.6) {
                                                                        let window = panelController.panel.frame
                                                                        let row = panelController.mascotModel.toolbarRowFrame
                                                                        let bottomStart = window.height - PanelHeadroom.pillBandHeight
                                                                        let inBottom = row.minY >= bottomStart - 1
                                                                            && row.maxY <= window.height + 1
                                                                        if !inBottom { ok = false }
                                                                        print("SURFACE mascotBand visible=\(inBottom)"
                                                                            + " rect=(\(Int(row.minX)),\(Int(row.minY)),"
                                                                            + "\(Int(row.width)),\(Int(row.height)))"
                                                                            + " windowH=\(Int(window.height))")
                                                                        fflush(stdout)
                                                                        print("SURFACES_OK=\(ok)")
                                                                        fflush(stdout)
                                                                        exit(ok ? 0 : 1)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Page readiness: every `popAPI` the audit drives must be installed first.
    let readyJS = "!!(window.popAPI && window.popAPI.openMenu && window.popAPI.closeMenu"
        + " && window.popAPI.voiceState && window.popAPI.voiceOnly && window.popAPI.history)"
    func waitReady(_ attempt: Int) {
        webView.evaluateJavaScript(readyJS) { value, _ in
            if (value as? Bool) == true {
                run()
            } else if attempt > 60 {
                print("SURFACES_TIMEOUT no-popAPI")
                fflush(stdout)
                exit(1)
            } else {
                after(0.25) { waitReady(attempt + 1) }
            }
        }
    }
    waitReady(0)

    after(45) {
        print("SURFACES_OK=false")
        print("SURFACES_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-collapse-regression`: a COMPLETED reply must stay on screen.
///
/// The user-visible failure was "i send hi, i don't see respond": the answer
/// rendered, and then the panel collapsed from `full` to `bar` over it. The
/// cause was a page-side emptiness check that inspected the live streaming
/// handle — which `chatDone` has already cleared by the time it asks — so the
/// check was unconditionally "empty" and every answer was hidden.
///
/// The gate is deliberately the pair: `COLLAPSE_STATE=full` (the panel did not
/// collapse) AND `COLLAPSE_TURNS>=2` (the question and the answer are both
/// rendered). Either alone would pass on a broken UI.
@MainActor
private func runCollapseRegressionProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    panelController.show()
    let webView = panelController.appWebView.webView

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        let js = "document.getElementById('input').value = "
            + jsString("Reply with exactly: COLLAPSE_OK") + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("COLLAPSE_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(70)
        func poll() {
            let streaming = "document.getElementById('stop')"
                + " && !document.getElementById('stop').hidden"
            webView.evaluateJavaScript(streaming) { value, _ in
                let stillStreaming = (value as? Bool) == true
                if !stillStreaming, chatController.deltaCount > 0 {
                    // Let the panel finish animating before the state is read:
                    // a collapse fires a height request that lands a frame or
                    // two after `chatDone`.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        reportCollapse(panelController)
                    }
                    return
                }
                if Date() >= deadline {
                    print("COLLAPSE_TIMEOUT deltas=\(chatController.deltaCount)")
                    fflush(stdout)
                    reportCollapse(panelController)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 88) {
        reportCollapse(panelController)
    }

    NSApp.run()
}

@MainActor
private func reportCollapse(_ panelController: PanelController) {
    // `.turn` is what the transcript renders per turn, user and assistant
    // alike \u2014 the same selector `--test-ui-sessions` counts.
    let js = "document.querySelectorAll('#bubble .turn').length"
    panelController.appWebView.webView.evaluateJavaScript(js) { value, _ in
        let turns = (value as? Int) ?? -1
        let state = panelController.state.rawValue
        print("COLLAPSE_TURNS=\(turns)")
        print("COLLAPSE_STATE=\(state)")
        print("COLLAPSE_GATE=\(state == "full" && turns >= 2)")
        fflush(stdout)
        exit(state == "full" && turns >= 2 ? 0 : 1)
    }
}


// MARK: - M4b tool calling


/// `--test-key-status`: is the stored key READABLE by THIS binary?
///
/// Existence only. Nothing is written to the Keychain, and no part of the key
/// is ever printed or measured beyond "is it there" — the probe's whole point
/// is the presence question the user could not otherwise answer, because an
/// ad-hoc rebuild invalidates the item's ACL silently.
///
/// Gate: a missing key must make the provider UNHEALTHY with a reason that
/// tells the user to re-paste it. A provider that reports a bare 401 (or worse,
/// reports itself healthy and sends nothing) is exactly the bug this fires on.
@MainActor
private func runKeyStatusProbe() {
    let config = (try? PopConfig.load()) ?? .defaults
    let account = config.provider
    let stored = KeychainStore.apiKey(for: account)
    let present = (stored?.isEmpty == false)
    print("KEYSTATUS=\(present ? "present" : "missing")")

    // The provider built the way the app builds it: real config, real read.
    let provider = ChatController.makeProvider(config)
    let healthy = provider.isHealthy
    let reason = String(provider.unhealthyReason.prefix(60))
    print("HEALTHY=\(healthy)")
    print("HEALTH_REASON=\(reason)")

    var gate: Bool
    if present {
        // With a key in hand, nothing may claim the reason is a missing one.
        gate = healthy && !reason.contains("re-paste")
    } else {
        gate = !healthy && reason.contains("re-paste")
    }
    print("KEYSTATUS_GATE=\(gate)")
    fflush(stdout)
    exit(gate ? 0 : 1)
}

/// `--test-tool-sandbox`: the three escapes that must never work.
///
/// Each assertion is on the REJECTION, not on an exception: a tool failure is
/// returned as text, so a sandbox breach that merely threw would still be a
/// breach the model could not distinguish from an I/O error.
@MainActor
private func runToolSandboxProbe() {
    // This probe runs BEFORE any UI exists (like the other headless probes),
    // but it needs a run loop for the async work below, so the application
    // object is created here — accessory policy, no window.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let root = NSTemporaryDirectory() + "pop-toolroot-\(UUID().uuidString)"
    setenv("POP_TOOL_ROOT", root, 1)
    // This probe measures the RESTRICTED scope, and the shipped default is
    // "anywhere" (the user asked for it). Forcing the scope here is what makes
    // the probe deterministic instead of dependent on a settings toggle.
    setenv("POP_ALLOW_EXTERNAL_PATHS", "0", 1)
    // Printed AFTER the override, so the root in the log is the one the tools
    // actually used.
    print("SANDBOX_ROOT=\(ToolRegistry.allowedRoot.path)")
    fflush(stdout)
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )

    // A tool failure is returned as TEXT, so rejection is asserted on the
    // error the registry throws, not on a crash and not on a string: a
    // sandbox breach that merely looked like an I/O error would still be a
    // breach the model could not act on.
    func run(_ tool: String, _ args: [String: String]) async -> Result<String, ToolFailure> {
        guard let entry = ToolRegistry.tool(named: tool) else {
            return .failure(ToolFailure(message: "unknown tool \(tool)"))
        }
        do {
            let result = try await entry.run(args.mapValues { JSONValue.string($0) })
            if result.hasPrefix("ERROR:") {
                return .failure(ToolFailure(message: String(result.dropFirst(6))))
            }
            return .success(result)
        } catch let failure as ToolFailure {
            return .failure(failure)
        } catch {
            return .failure(ToolFailure(message: "\(error)"))
        }
    }

    Task { @MainActor in
        let escape = await run("read_file", ["path": "../../etc/passwd"])
        let curl = await run("shell_readonly", ["command": "curl http://x"])
        let pipe = await run("shell_readonly", ["command": "ls | sh"])
        for (label, outcome) in [
            ("ESCAPE", escape), ("CURL", curl), ("PIPE", pipe)
        ] {
            switch outcome {
            case .failure(let failure):
                print("SANDBOX_REJECTED case=\(label) reason=\(failure.message.prefix(90))")
            case .success(let value):
                print("SANDBOX_LEAK case=\(label) result=\(value.prefix(90))")
            }
        }
        let ok = !escape.isSuccess && !curl.isSuccess && !pipe.isSuccess
        print("SANDBOX_ESCAPE=\(!escape.isSuccess)")
        print("SANDBOX_CURL=\(!curl.isSuccess)")
        print("SANDBOX_PIPE=\(!pipe.isSuccess)")
        print("SANDBOX_GATE=\(ok)")
        fflush(stdout)
        try? FileManager.default.removeItem(atPath: root)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        print("SANDBOX_TIMEOUT")
        exit(1)
    }

    NSApp.run()
}

extension Result where Failure == ToolFailure {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// `--test-tools-schema`: the tool surface is fixed, alphabetical, valid JSON.
///
/// Also proves the cache rule: the stable-prefix hash must be IDENTICAL across
/// two consecutive assemblies with the same tool set, because a hash that
/// moves between turns is a prompt cache that never hits.
@MainActor
private func runToolsSchemaProbe() {
    let schemas = ToolRegistry.schemas()
    print("TOOLS_COUNT=\(schemas.count)")
    print("TOOLS_ORDER=\(schemas.map(\.name).joined(separator: ","))")

    var validJSON = true
    var wellFormed = true
    for schema in schemas {
        // Valid JSON: the exact bytes a provider request would carry.
        let text = schema.parameters.stableString()
        guard (try? JSONValue.decode(Data(text.utf8))) != nil else {
            validJSON = false
            print("TOOLS_SCHEMA_INVALID name=\(schema.name)")
            continue
        }
        let object = schema.parameters.objectValue
        if object["type"] == nil || object["properties"] == nil { wellFormed = false }
        if schema.description.isEmpty { wellFormed = false }
    }
    print("TOOLS_JSON_VALID=\(validJSON)")
    print("TOOLS_SCHEMA_SHAPE=\(wellFormed)")

    let sorted = schemas.map(\.name) == schemas.map(\.name).sorted()
    print("TOOLS_SORTED=\(sorted)")

    // Two consecutive turns, same tool set.
    let first = ChatController.stablePrefixHash()
    let second = ChatController.stablePrefixHash()
    print("PREFIX_STABLE tools=\(schemas.count) hash=\(first)")
    print("PREFIX_STABLE tools=\(schemas.count) hash=\(second)")
    let stable = first == second && first.count == 8
    print("PREFIX_STABLE_MATCH=\(stable)")

    // --- SURFACE DOCS: every browser-family tool states WHICH surface it acts
    // on, so a routed task cannot pick a tool whose surface it isn't using (the
    // measured Brave-extract failure). Panel-webview tools say "Pop's browser
    // pane only"; the external-browser tools name `screen_read`.
    let panelBrowser = [
        "browser_back", "browser_click", "browser_extract", "browser_navigate",
        "browser_read", "browser_select_option", "browser_submit", "browser_type_field"
    ]
    let externalBrowser = ["browser_focus_tab", "browser_open_url"]
    let panelDocs = panelBrowser.allSatisfy {
        ToolRegistry.tool(named: $0)?.description.contains("Pop's browser pane only") == true
    } && externalBrowser.allSatisfy {
        ToolRegistry.tool(named: $0)?.description.contains("screen_read") == true
    }
    // `fields` is OPTIONAL and its description names the omit behavior.
    let extractSchema = ToolRegistry.tool(named: "browser_extract")?.schema.parameters.objectValue
    let fieldsProp = extractSchema?["properties"]?.objectValue["fields"]?.objectValue
    var requiredNames: [String] = []
    if case .array(let values)? = extractSchema?["required"] {
        requiredNames = values.compactMap(ToolRegistry.stringValue)
    }
    let fieldsDescription = fieldsProp?["description"].flatMap(ToolRegistry.stringValue) ?? ""
    let fieldsOptional = fieldsProp != nil
        && !requiredNames.contains("fields")
        && fieldsDescription.contains("Omit")
    let surfaceDocs = panelDocs && fieldsOptional
    print("SURFACE_PANEL_DOCS=\(panelDocs)")
    print("SURFACE_FIELDS_OPTIONAL=\(fieldsOptional)")
    print("SURFACE_DOCS_GATE=\(surfaceDocs)")

    // --- HUMAN-PATH DOCS: computer-use is the UI-FIRST way to change macOS
    // settings; shell is the explicit LAST RESORT. The ui_* act tools and
    // app_manage must say "System Settings", and `bash` must say "Last resort",
    // so the routed task that reached for seven gated shell commands instead
    // sees the human path WHERE IT CHOOSES TOOLS.
    let uiSystemSettings = ["ui_click", "ui_scroll", "ui_ax", "app_manage"].allSatisfy {
        ToolRegistry.tool(named: $0)?.description.contains("System Settings") == true
    }
    let bashLastResort = ToolRegistry.tool(named: "bash")?.description.contains("Last resort") == true
    let humanPathDocs = uiSystemSettings && bashLastResort
    print("HUMAN_PATH_UI_DOCS=\(uiSystemSettings)")
    print("HUMAN_PATH_BASH_LAST_RESORT=\(bashLastResort)")
    print("HUMAN_PATH_DOCS=\(humanPathDocs)")

    let gate = schemas.count == ToolRegistry.tools.count && sorted && validJSON && wellFormed && stable && surfaceDocs && humanPathDocs
    print("TOOLS_GATE=\(gate)")
    fflush(stdout)
    exit(gate ? 0 : 1)
}

/// `--test-thinking-param`: the cloud `thinking` field is CONFIG-DRIVEN DATA,
/// not a hardcoded request constant.
///
/// Pure payload-builder assertions — no network call and no provider
/// construction (which would touch the Keychain). `"disabled"` (the speed
/// default) and `"enabled"` send the field; `"default"` omits it for maximum
/// endpoint compatibility; an unknown value degrades to the speed default.
/// Gate: `THINKING_PROBE=ok`.
@MainActor
private func runThinkingParamProbe() {
    func payload(_ cloudThinking: String, _ cloudReasoningEffort: String) -> [String: Any] {
        let configuration = OpenAICompatProvider.Configuration(
            baseURL: "https://api.z.ai/api/paas/v4",
            model: "glm-4.6",
            apiKey: "",
            temperature: 0.7,
            cloudThinking: cloudThinking,
            cloudReasoningEffort: cloudReasoningEffort,
            headers: [:]
        )
        return OpenAICompatProvider.requestBody(
            configuration: configuration,
            messages: [],
            options: GenerationOptions(temperature: 0.7),
            tools: []
        )
    }

    /// The exact bytes a request body would carry, for substring assertions.
    func bodyJSON(_ cloudThinking: String, _ cloudReasoningEffort: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: payload(cloudThinking, cloudReasoningEffort)
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    let disabled = payload("disabled", "low")["thinking"] as? [String: Any]
    let enabled = payload("enabled", "low")["thinking"] as? [String: Any]
    let omitted = payload("default", "low")["thinking"]
    let unknown = payload("bogus", "low")["thinking"] as? [String: Any]

    let disabledOK = disabled?["type"] as? String == "disabled"
    let enabledOK = enabled?["type"] as? String == "enabled"
    let omittedOK = omitted == nil
    let unknownOK = unknown?["type"] as? String == "disabled"

    print("THINKING_DISABLED_SENT=\(disabledOK)")
    print("THINKING_ENABLED_SENT=\(enabledOK)")
    print("THINKING_DEFAULT_OMITTED=\(omittedOK)")
    print("THINKING_UNKNOWN_DEGRADES=\(unknownOK)")

    // The separate top-level `reasoning_effort` field, config-driven.
    let lowBody = bodyJSON("default", "low")
    let highBody = bodyJSON("default", "high")
    let reasoningDefaultBody = bodyJSON("default", "default")
    let reasoningUnknownBody = bodyJSON("default", "turbo")
    let lowSentOK = lowBody.contains("\"reasoning_effort\":\"low\"")
    let highSentOK = highBody.contains("\"reasoning_effort\":\"high\"")
    let reasoningDefaultOmittedOK = !reasoningDefaultBody.contains("reasoning_effort")
    let reasoningUnknownOmittedOK = !reasoningUnknownBody.contains("reasoning_effort")

    print("REASONING_LOW_SENT=\(lowSentOK)")
    print("REASONING_HIGH_SENT=\(highSentOK)")
    print("REASONING_DEFAULT_OMITTED=\(reasoningDefaultOmittedOK)")
    print("REASONING_UNKNOWN_DEGRADES=\(reasoningUnknownOmittedOK)")

    let gate = disabledOK && enabledOK && omittedOK && unknownOK
        && lowSentOK && highSentOK
        && reasoningDefaultOmittedOK && reasoningUnknownOmittedOK
    print("THINKING_PROBE=\(gate ? "ok" : "FAIL")")
    fflush(stdout)
    exit(gate ? 0 : 1)
}

/// `--test-approval-approve` / `--test-approval-deny`: the one-click gate.
///
/// The verdict is issued THROUGH THE BRIDGE — `handleBridgeMessage(type:
/// "approvalVerdict")`, which is exactly what the page's Run/Deny button
/// reaches — rather than by calling `ApprovalGate.submit` directly, so the
/// probe proves the whole path a real click travels, JSON parsing included.
///
/// No model and no page: a card nobody can see is still a card, and the gate
/// must resolve either way (here, immediately).
@MainActor
private func runApprovalProbe(decision: String, gateName: String) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let root = NSTemporaryDirectory() + "pop-approval-\(decision)-\(UUID().uuidString)"
    setenv("POP_TOOL_ROOT", root, 1)
    setenv("POP_ALLOW_EXTERNAL_PATHS", "1", 1)
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )

    let target = root + "/approval-probe.txt"
    let controller = ChatController(webViewProvider: { nil }, configProvider: { .defaults })
    var rendered: [String] = []
    controller.approvalObserver = { line in rendered.append(line) }

    // Wrap the controller's own sink so the verdict travels back the way the
    // button's does: card -> page -> bridge message -> gate.
    let nativeSink = ApprovalGate.shared.sink
    ApprovalGate.shared.sink = { json in
        await nativeSink?(json)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String
        else { return }
        await MainActor.run {
            controller.handleBridgeMessage(
                type: "approvalVerdict",
                body: ["id": id, "decision": decision]
            )
        }
    }

    let arguments = JSONValue.object([
        "path": .string(target),
        "content": .string("approval probe content")
    ])

    Task { @MainActor in
        let result = await ToolRegistry.execute(("write_file", arguments))
        let exists = FileManager.default.fileExists(atPath: target)
        print("APPROVAL_TOOL_RESULT=\(result.prefix(160))")
        let approved = decision == "run"
        print("APPROVE_FILE_EXISTS=\(exists)")
        print("APPROVAL_RENDERED=\(rendered.joined(separator: " | "))")
        let expectedLine = "TOOL write_file \u{2192} \(approved ? "approved" : "denied")"
        let lineShown = rendered.contains(expectedLine)
        print("APPROVAL_LINE_SHOWN=\(lineShown)")
        let fedBack = result.contains("DENIED by user") || result.contains("wrote")
        print("APPROVAL_FEEDBACK_OK=\(fedBack)")
        let gate = exists == approved
            && lineShown
            && fedBack
            && (approved ? !result.contains("DENIED") : !exists && result.contains("DENIED"))
        print("\(gateName)=\(gate)")
        fflush(stdout)
        try? FileManager.default.removeItem(atPath: root)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("APPROVAL_TIMEOUT")
        exit(1)
    }

    NSApp.run()
}

/// `--test-bash-gated`: the strongest thing in the toolset behind a click, and
/// nobody clicks.
///
/// The approval window is shortened through the probe-only
/// `POP_APPROVAL_TIMEOUT` override so the timeout branch is proven in seconds.
/// The shipped default is untouched, and the command is `echo hello`, so even a
/// gate failure could not damage anything.
@MainActor
private func runBashGatedProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let root = NSTemporaryDirectory() + "pop-bashgate-\(UUID().uuidString)"
    setenv("POP_TOOL_ROOT", root, 1)
    setenv("POP_ALLOW_EXTERNAL_PATHS", "1", 1)
    setenv("POP_APPROVAL_TIMEOUT", "3", 1)
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )
    print("BASH_APPROVAL_WINDOW=\(Int(ApprovalGate.effectiveTimeout))s")

    Task { @MainActor in
        let result = await ToolRegistry.execute(
            ("bash", .object(["command": .string("echo hello")]))
        )
        print("BASH_RESULT=\(result.prefix(160))")
        let blocked = result.contains("DENIED by user")
        let outputSeen = result.contains("hello")
        print("BASH_BLOCKED=\(blocked)")
        print("BASH_OUTPUT_SEEN=\(outputSeen)")
        let gate = blocked && !outputSeen
        print("BASH_GATE=\(gate)")
        fflush(stdout)
        try? FileManager.default.removeItem(atPath: root)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("BASH_PROBE_TIMEOUT")
        exit(1)
    }

    NSApp.run()
}

/// `--test-focus-preference`: the PURE tab-selection preference shared by focus
/// (and, in shape, `browser_open_url`'s reuse). No browser, no script, no run
/// loop — a truth table over `TabFocus.FocusPreference.pick`.
///
/// (a) the ACTIVE tab of the FRONT window wins even when an earlier match is
/// enumerated first; (b) with no active match the EARLIEST match is picked;
/// (c) no match is nil (a precise not-found). Gate: `FOCUS_PREF_PROBE=ok`;
/// exit 0/1.
private func runFocusPreferenceProbe() {
    var ok = true

    func tab(
        _ title: String, _ url: String,
        w: Int, t: Int, active: Bool, front: Bool
    ) -> TabFocus.OpenTab {
        TabFocus.OpenTab(
            title: title, url: url,
            windowIndex: w, tabIndex: t, active: active, isActiveWindow: front
        )
    }

    // (a) ACTIVE tab of the FRONT window wins over an earlier enumeration match.
    let activeMatches = [
        tab("Feed | LinkedIn", "https://www.linkedin.com/feed", w: 1, t: 1, active: false, front: true),
        tab("Notifications | LinkedIn", "https://www.linkedin.com/notifications", w: 1, t: 2, active: true, front: true)
    ]
    let activePick = TabFocus.FocusPreference.pick(activeMatches)
    let prefActive = activePick?.tabIndex == 2 && activePick?.active == true
    if !prefActive { ok = false }
    print("FOCUS_PREF_ACTIVE=\(prefActive)")

    // (b) No active match -> the EARLIEST match (first-fallback).
    let noActiveMatches = [
        tab("Feed | LinkedIn", "https://www.linkedin.com/feed", w: 1, t: 1, active: false, front: true),
        tab("Notifications | LinkedIn", "https://www.linkedin.com/notifications", w: 2, t: 1, active: false, front: false)
    ]
    let fallbackPick = TabFocus.FocusPreference.pick(noActiveMatches)
    let prefFirst = fallbackPick?.windowIndex == 1 && fallbackPick?.tabIndex == 1
    if !prefFirst { ok = false }
    print("FOCUS_PREF_FIRST_FALLBACK=\(prefFirst)")

    // (c) No match -> nil (precise not-found).
    let prefNoMatch = TabFocus.FocusPreference.pick([]) == nil
    if !prefNoMatch { ok = false }
    print("FOCUS_PREF_NOMATCH=\(prefNoMatch)")

    print("FOCUS_PREF_PROBE=\(ok ? "ok" : "fail")")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

/// `--test-focus-tab`: THE APPLE-SCRIPT TAB DRIVER, with both the script result
/// channel and the running check SEAMED, so no real browser is ever driven.
///
/// Each arm is a different property: the canned output is PARSED by the real
/// parser; a miss and a stopped browser are HONEST (no success claim); the
/// query is ESCAPED into the script; an oversized query is refused; and a DENY
/// means the script is never even built.
@MainActor
private func runFocusTabProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let brave = "com.brave.Browser"

    func runFocus() async -> String {
        await TabFocus.focus(query: "example.com", browser: brave)
    }

    Task { @MainActor in
        // --- FOUND: canned ENUMERATION output, read by the REAL parser; the
        // activation script then answers OK. One enumeration + one activate.
        TabFocus.runningCheckerOverride = { _ in true }
        TabFocus.scriptRunnerOverride = { script in
            if script.contains("set out to") {
                return .output("Example Domain\thttps://example.com/\t1\t2\t1\t1\n")
            }
            return .output("OK")
        }
        let found = await runFocus()
        let foundParse = found.contains("raised window 1, tab 2")
            && found.contains("Example Domain")
        print("FOCUS_TAB_FOUND_PARSE=\(foundParse)")
        print("FOCUS_TAB_FOUND_RESULT=\(found.replacingOccurrences(of: "\n", with: " "))")

        // --- HONEST MISS: an EMPTY enumeration, nothing raised.
        TabFocus.scriptRunnerOverride = { _ in .output("") }
        let miss = await runFocus()
        let honestMiss = miss.contains("no tab matching") && !miss.contains("raised")
        print("FOCUS_TAB_HONEST_MISS=\(honestMiss)")
        print("FOCUS_TAB_MISS_RESULT=\(miss)")

        // --- NOT RUNNING: the script runner must NEVER be called.
        let notRunningRunner = RunnerRecorder()
        TabFocus.runningCheckerOverride = { _ in false }
        TabFocus.scriptRunnerOverride = { script in
            notRunningRunner.record(script)
            return .output("")
        }
        let notRunning = await runFocus()
        let notRunningHonest = notRunning.contains("is not running")
            && notRunningRunner.count == 0
        print("FOCUS_TAB_NOT_RUNNING=\(notRunningHonest)")
        print("FOCUS_TAB_NOT_RUNNING_RESULT=\(notRunning)")

        // --- ESCAPING: quote and backslash are escaped for an AppleScript
        // literal (the activator's in-place `set URL` still interpolates text).
        let tricky = "a\"b\\c"
        let escapeSafe = TabFocus.escapeForAppleScript(tricky) == "a\\\"b\\\\c"
        print("FOCUS_TAB_ESCAPE_SAFE=\(escapeSafe)")

        // --- LENGTH: an oversized query is refused before any script runs.
        let longQuery = String(repeating: "x", count: TabFocus.maxQueryLength + 1)
        TabFocus.scriptRunnerOverride = { _ in .output("") }
        let longResult = await TabFocus.focus(query: longQuery, browser: brave)
        let longRefused = longResult.contains("longer than")
        print("FOCUS_TAB_LENGTH_REFUSED=\(longRefused)")

        // --- AUTONOMY: `browser_focus_tab` is navigation-class now, so it runs
        // with NO approval card. The runner must have run (enumeration +
        // activation), and no approval asked.
        let focusRunner = RunnerRecorder()
        TabFocus.runningCheckerOverride = { _ in true }
        TabFocus.scriptRunnerOverride = { script in
            focusRunner.record(script)
            if script.contains("set out to") {
                return .output("Example Domain\thttps://example.com/\t1\t1\t1\t1\n")
            }
            return .output("OK")
        }

        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
            func set() { lock.lock(); value = true; lock.unlock() }
        }
        let approvalAsked = Flag()
        let nativeSink = ApprovalGate.shared.sink
        ApprovalGate.shared.sink = { json in
            approvalAsked.set()
            await nativeSink?(json)
        }
        let focused = await ToolRegistry.execute((
            "browser_focus_tab",
            .object([
                "query": .string("example.com"),
                "browser": .string(brave)
            ])
        ))
        ApprovalGate.shared.sink = nativeSink
        let autonomous = focusRunner.count == 2 && !approvalAsked.isSet
        print("FOCUS_TAB_AUTONOMOUS=\(autonomous)")
        print("FOCUS_TAB_APPROVAL_ASKED=\(approvalAsked.isSet)")
        print("FOCUS_TAB_RESULT=\(focused.prefix(120))")

        // --- CLASSIFICATION, asserted where the tool is exercised.
        let tool = ToolRegistry.tool(named: "browser_focus_tab")
        let classified = tool?.access == .localNav
            && !PopTool.requiresApproval(tool?.access ?? .mutating)
            && PopTool.onDeviceEligible(tool?.access ?? .mutating)
        print("FOCUS_TAB_LOCAL_NAV_AUTONOMOUS=\(classified)")

        // --- The one principle names the focus step where the other rules live.
        print("FOCUS_TAB_ROUTE_RULE_PRESENT=\(AppleFMProvider.systemPrompt.contains(ScreenOCR.routingPrinciple))")

        let gate = foundParse && honestMiss && notRunningHonest && escapeSafe
            && longRefused && autonomous && classified
        print("FOCUS_TAB_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("FOCUS_TAB_TIMEOUT")
        exit(1)
    }
    NSApp.run()
}

/// The verdict a seamed focus runner returns, settable per probe arm.
final class FocusScriptOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "NOMATCH\n"
    var current: String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: String) { lock.lock(); value = next; lock.unlock() }
}

/// Records the focus scripts, the query arguments a scripted model yielded, and
/// the tool result it read back, so "what was actually called" is measured
/// rather than assumed.
final class FocusQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedScripts: [String] = []
    private var storedQueries: [String] = []
    private var storedResults: [String] = []
    func recordScript(_ script: String) { lock.lock(); storedScripts.append(script); lock.unlock() }
    func recordQuery(_ query: String) { lock.lock(); storedQueries.append(query); lock.unlock() }
    func recordResult(_ result: String) { lock.lock(); storedResults.append(result); lock.unlock() }
    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return storedScripts }
    var queries: [String] { lock.lock(); defer { lock.unlock() }; return storedQueries }
    var results: [String] { lock.lock(); defer { lock.unlock() }; return storedResults }
}

/// `ScriptedFocusQueryProvider` plays the USER-NAMED-QUERY journey: read the
/// front window, find nothing relevant, raise the tab the USER named, then
/// either answer the miss honestly (`.none`) or proceed to read the raised tab
/// (`.found`). It is the compliant-model stand-in, and its query is the word the
/// shipped guidance maps the user's message to — so the probe measures the
/// guidance, not a hardcoded site.
struct ScriptedFocusQueryProvider: ModelProvider {
    enum Mode { case none, found }

    var isHealthy: Bool { true }
    var unhealthyReason: String { "" }
    /// FALSE on purpose: the loop executes these tools, as the OpenAI-shaped
    /// path does.
    var executesToolsNatively: Bool { false }

    let mode: Mode
    let userWord: String
    let recorder: FocusQueryRecorder

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
    private let round = Counter()

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let index = round.next()
                switch (mode, index) {
                case (.none, 1), (.found, 1):
                    continuation.yield(.toolCall(
                        id: "fq_read_1", name: "screen_read", arguments: .object([:])
                    ))
                    continuation.finish()
                case (.none, 2), (.found, 2):
                    recorder.recordQuery(userWord)
                    continuation.yield(.toolCall(
                        id: "fq_raise_2",
                        name: "browser_focus_tab",
                        arguments: .object(["query": .string(userWord)])
                    ))
                    continuation.finish()
                case (.found, 3):
                    continuation.yield(.toolCall(
                        id: "fq_read_3", name: "screen_read", arguments: .object([:])
                    ))
                    continuation.finish()
                case (.none, _):
                    // The answer is composed FROM the real tool result the loop
                    // fed back, so the miss's precision is Pop's, not fiat.
                    let result = messages.last(where: { $0.role == .tool })?.text ?? ""
                    recorder.recordResult(result)
                    continuation.yield(.done(
                        "\(result) There is nothing from \(userWord) to read yet; "
                            + "open \(userWord) in your browser and ask me again."
                    ))
                    continuation.finish()
                case (.found, _):
                    continuation.yield(.done("The raised tab says: Fixture line text."))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `--test-focus-query`: the QUERY LOGIC of the raise step, end to end on seams.
///
///   QUERY_FROM_USER_WORDS — with the front window unrelated, the model raises
///     the tab named by the USER'S message (the word the shipped guidance maps
///     it to) — never the front window's own title. The user word is parsed FROM
///     `ScreenOCR.raiserPreferenceClause`, so no site is hardcoded in the probe.
///   HONEST_NONE_NOT_VAGUE — a NOMATCH ends with the exact fact (no tab matching
///     that query is open) and what to open, with no "check other tabs or apps"
///     vagueness, in the answer AND in the shipped guidance.
///   FOUNDED_TAB_PROCEEDS — a raise is followed by reading the raised tab.
@MainActor
private func runFocusQueryProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let frontTitle = "Unrelated Front Page"

    guard let example = ScreenOCR.focusQueryExample() else {
        print("FOCUS_QUERY_EXAMPLE_ABSENT=true")
        print("QUERY_FROM_USER_WORDS=false")
        print("HONEST_NONE_NOT_VAGUE=false")
        print("FOUNDED_TAB_PROCEEDS=false")
        print("FOCUS_QUERY_GATE=false")
        fflush(stdout)
        exit(1)
    }
    let userWord = example.userWord
    let prompt = "in my browser someone messaged me on \(userWord), what did they say?"

    // SEAMS: the front window reads with nothing relevant in it; the browser is
    // running; the focus script's verdict is chosen per arm. No real browser.
    ScreenOCR.readOverride = { _ in
        var window = ScreenOCR.WindowReading()
        window.order = 0
        window.appName = "Fixture"
        window.windowTitle = frontTitle
        let line = ScreenOCR.RecognizedLine(
            text: "Unrelated front content",
            rect: CGRect(x: 120, y: 140, width: 320, height: 20)
        )
        window.lines = [line]
        window.text = line.rendered
        var reading = ScreenOCR.Reading()
        reading.windows = [window]
        reading.scopeName = "front"
        return reading
    }
    let output = FocusScriptOutput()
    let recorder = FocusQueryRecorder()
    TabFocus.runningCheckerOverride = { _ in true }
    TabFocus.scriptRunnerOverride = { script in
        recorder.recordScript(script)
        return .output(output.current)
    }
    defer {
        ScreenOCR.readOverride = nil
        TabFocus.runningCheckerOverride = nil
        TabFocus.scriptRunnerOverride = nil
    }

    let log = WalkthroughLog()

    func runTurn(_ provider: ModelProvider) async -> String {
        var full = ""
        do {
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: prompt)],
                options: GenerationOptions(),
                tools: ToolRegistry.schemas()
            ) { outcome in
                await MainActor.run { log.record(outcome) }
            }
            for try await event in events {
                switch event {
                case .delta(let piece): full += piece
                case .done(let text): full = text
                case .toolCall: break
                }
            }
        } catch {
            print("FOCUS_QUERY_TURN_ERROR \(error)")
        }
        return full
    }

    Task { @MainActor in
        // === ARM 1: front read unrelated, raise the USER-named site, MISS ====
        log.reset()
        output.set("NOMATCH\n")
        let noneAnswer = await runTurn(ScriptedFocusQueryProvider(
            mode: .none, userWord: userWord, recorder: recorder
        ))
        let focusDetail = recorder.results.last ?? ""
        let focusScript = recorder.scripts.last ?? ""
        let queryFromUserWords =
            AppleFMProvider.systemPrompt.contains(ScreenOCR.raiserPreferenceClause)
            && example.userWord == example.query
            && recorder.queries.last == userWord
            && focusScript.contains("\"\(userWord)\"")
            && !focusScript.contains(frontTitle)
            && userWord != frontTitle
        print("QUERY_FROM_USER_WORDS=\(queryFromUserWords)")
        print("FOCUS_QUERY_ARG=\(recorder.queries.last ?? "nil")")

        let vague = ["check other tabs", "other tabs or apps", "or apps", "might need"]
        let answerLower = noneAnswer.lowercased()
        let clauseLower = ScreenOCR.raiserPreferenceClause.lowercased()
        let honestNoneNotVague =
            answerLower.contains("no tab matching")
            && answerLower.contains(userWord.lowercased())
            && !vague.contains { answerLower.contains($0) }
            && !vague.contains { clauseLower.contains($0) }
            && clauseLower.contains("no such tab is open")
            && focusDetail.contains("no tab matching")
        print("HONEST_NONE_NOT_VAGUE=\(honestNoneNotVague)")
        print("FOCUS_NONE_ANSWER=\(noneAnswer.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)

        // === ARM 2: raise the USER-named site and FOUND -> proceed to read ===
        log.reset()
        output.set("FOUND\t1\t2\t\(userWord) tab\n")
        let foundAnswer = await runTurn(ScriptedFocusQueryProvider(
            mode: .found, userWord: userWord, recorder: recorder
        ))
        let names = log.outcomes.map(\.name)
        let focusIndex = names.firstIndex(of: "browser_focus_tab")
        let readAfterFocus = focusIndex.map { idx in
            names[(idx + 1)...].contains("screen_read")
        } ?? false
        let foundedTabProceeds = focusIndex != nil
            && readAfterFocus
            && !foundAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        print("FOUNDED_TAB_PROCEEDS=\(foundedTabProceeds)")
        print("FOCUS_FOUNDED_TOOLS=\(names.joined(separator: ","))")
        print("FOCUS_FOUNDED_ANSWER=\(foundAnswer.replacingOccurrences(of: "\n", with: " "))")
        fflush(stdout)

        let gate = queryFromUserWords && honestNoneNotVague && foundedTabProceeds
        print("FOCUS_QUERY_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("FOCUS_QUERY_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// Records the scripts a seamed runner was handed, so "nothing ran" is measured
/// rather than assumed. Lock-guarded: the runner fires off the main actor.
final class RunnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    func record(_ script: String) {
        lock.lock(); defer { lock.unlock() }
        scripts.append(script)
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return scripts.count
    }
}

/// `--test-tool-classification`: read-only runs silently, mutating does not,
/// and the cache prefix is still stable.
///
/// The tool SET changed in M4c, so the old hash `3b2d0ff9` is expected to move;
/// what must NOT move is the hash BETWEEN two consecutive turns.
@MainActor
private func runToolClassificationProbe() {
    let readOnly = ToolRegistry.tools.filter { $0.access == .readOnly }
    // GATED BY CLASS: only the remote file/shell class. `ui_type` — including
    // the newline send — is navigation-class and autonomous; there is no
    // typed-text class and no separate send gate.
    let gated = ToolRegistry.tools.filter { PopTool.requiresApproval($0.access) }
    let localNav = ToolRegistry.tools.filter { $0.access == .localNav }
    let remoteMutating = ToolRegistry.tools.filter { $0.access == .mutating }
    let names = ToolRegistry.names
    print("TOOLS_TOTAL=\(names.count)")
    print("TOOLS_READONLY=\(readOnly.count)")
    print("TOOLS_MUTATING=\(gated.count)")
    print("TOOLS_REMOTE_MUTATING=\(remoteMutating.count)")
    print("TOOLS_LOCAL_NAV=\(localNav.count)")
    print("TOOLS_NAMES=\(names.joined(separator: ","))")
    let sorted = names == names.sorted()
    print("TOOLS_SORTED=\(sorted)")

    let first = ChatController.stablePrefixHash()
    let second = ChatController.stablePrefixHash()
    print("PREFIX_STABLE tools=\(names.count) hash=\(first)")
    print("PREFIX_STABLE tools=\(names.count) hash=\(second)")
    let stable = first == second
    print("PREFIX_STABLE_MATCH=\(stable)")

    // Every gated tool must be one the gate knows how to present, every
    // read-only tool must be silent, and every navigation tool must be
    // autonomous: a mislabelled tool is a silent hole. `gated` is by construction
    // `requiresApproval`, the SAME predicate `ToolRegistry.execute` gates on.
    let classified = readOnly.count + gated.count + localNav.count == names.count
    print("TOOLS_CLASSIFIED=\(classified)")

    // THE CLASSES, asserted BY NAME and by POLICY. Navigation tools are
    // autonomous (no card) yet offered to the on-device brain; `ui_type` —
    // including the newline send — is navigation-class too, with no send gate.
    // The remote mutating class is gated and NOT on-device. Asserting the names
    // means a tool cannot drift classes silently.
    let navNames: Set<String> = [
        "browser_open_url", "ui_click", "browser_focus_tab", "ui_type"
    ]
    let navCorrect = navNames.allSatisfy { name in
        guard let tool = ToolRegistry.tool(named: name) else { return false }
        return tool.access == .localNav
            && !PopTool.requiresApproval(tool.access)
            && PopTool.onDeviceEligible(tool.access)
    }
    // NO TYPED-TEXT CLASS: `ui_type` is navigation-class for EVERY argument,
    // the newline send included — there is no gate to bypass.
    let typedAutonomous = ToolRegistry.tool(named: "ui_type").map { tool in
        tool.access == .localNav
            && !PopTool.requiresApproval(tool.access)
            && PopTool.onDeviceEligible(tool.access)
    } ?? false
    // The class split must be exhaustive: no access value may be missing from
    // readOnly/gated/localNav, and there is no fourth class.
    let hasNoTypedTextClass = ToolRegistry.tools.allSatisfy { tool in
        tool.access == .readOnly || tool.access == .localNav
            || PopTool.requiresApproval(tool.access)
    }
    let remoteNotOnDevice = remoteMutating.allSatisfy {
        !PopTool.onDeviceEligible($0.access)
    }
    print("LOCAL_NAV_TOOLS=\(localNav.map(\.name).sorted().joined(separator: ","))")
    print("LOCAL_NAV_AUTONOMOUS=\(navCorrect)")
    print("NO_TYPED_TEXT_CLASS=\(typedAutonomous && hasNoTypedTextClass)")
    print("REMOTE_MUTATING_NOT_ON_DEVICE=\(remoteNotOnDevice)")

    // The browser split, asserted by NAME rather than by a total: reading,
    // extracting and navigating change nothing on the page, while clicking,
    // typing, selecting and submitting do — and the four of those MUST be the
    // ones the approval card stands in front of.
    let mutatingBrowser: Set<String> = [
        "browser_click", "browser_type_field", "browser_select_option", "browser_submit"
    ]
    let readOnlyBrowser: Set<String> = [
        "browser_navigate", "browser_read", "browser_extract", "browser_back"
    ]
    let browserNames = (mutatingBrowser.union(readOnlyBrowser)).sorted()
    let browserPresent = browserNames.allSatisfy { names.contains($0) }
    let splitCorrect = mutatingBrowser.allSatisfy {
        ToolRegistry.tool(named: $0)?.access == .mutating
    } && readOnlyBrowser.allSatisfy {
        ToolRegistry.tool(named: $0)?.access == .readOnly
    }
    print("BROWSER_TOOLS_PRESENT=\(browserPresent)")
    print("BROWSER_SPLIT_CORRECT=\(splitCorrect)")

    // THE DECLARED COUNTS, asserted exactly. A tool added or reclassified
    // without updating this line fails here rather than shipping silently.
    // `ui_type` (including the send) is `localNav`, so localNav is 4; the gated
    // class is 12 — the file/shell tools plus the four computer-use acts
    // (`ui_key`, `ui_scroll`, `ui_ax`, `app_manage`) — and there is no separate
    // send gate.
    let countsCorrect = names.count == 30
        && readOnly.count == 14
        && gated.count == 12
        && localNav.count == 4
        && remoteMutating.count == 12
    print("TOOL_COUNTS_CORRECT=\(countsCorrect)")

    let gate = classified && sorted && stable && browserPresent && splitCorrect
        && navCorrect && typedAutonomous && hasNoTypedTextClass
        && remoteNotOnDevice && countsCorrect
    print("CLASSIFICATION_GATE=\(gate)")
    fflush(stdout)
    exit(gate ? 0 : 1)
}

/// `--test-screenshot-scope`: the PRIVACY invariant that screen capture is
/// window-scoped or it does not happen.
///
///   (a) the ownership/size rule rejects a bundle that owns no window (and
///       accepts a matching, large-enough one; rejects a sub-40px one),
///   (b) the no-window path emits ONE sanitized `OBS_SCREENSHOT_NO_WINDOW` line
///       and returns a typed nil shot that is NOT denied,
///   (c) the public `screenshot` entry point with a bogus bundle returns nil,
///       not denied, and `fellBack == false` — never a display capture.
/// Gate: `SCREENSHOT_SCOPE_PROBE=ok`; exit 0/1.
private func runScreenshotScopeProbe() {
    var ok = true
    let bogus = "com.pop.probe.nonexistent"

    // (a) Ownership + size rule.
    let bogusOwnsNothing = !Observe.isOwnedWindow(
        bundleID: bogus,
        ownerBundleID: "com.apple.Safari",
        width: 800,
        height: 600
    )
    let matchOwns = Observe.isOwnedWindow(
        bundleID: "com.apple.Safari",
        ownerBundleID: "com.apple.Safari",
        width: 800,
        height: 600
    )
    let tinyRejected = !Observe.isOwnedWindow(
        bundleID: "com.apple.Safari",
        ownerBundleID: "com.apple.Safari",
        width: 30,
        height: 30
    )
    let ownershipOK = bogusOwnsNothing && matchOwns && tinyRejected
    if !ownershipOK { ok = false }
    print("SCREENSHOT_OWNERSHIP_FILTER bogus=\(bogusOwnsNothing)"
        + " match=\(matchOwns) tiny=\(tinyRejected)")

    // (b) The typed no-window outcome: one sanitized log line, nil shot, clean.
    let logLine = Observe.noWindowLogLine(bundleID: bogus, titleHint: "a\nb\tc")
    let sanitized = !logLine.contains("\n") && !logLine.contains("\t")
        && logLine == "OBS_SCREENSHOT_NO_WINDOW bundle=\(bogus) hint=a b c"
    let prefix = "OBS_SCREENSHOT_NO_WINDOW bundle=b hint="
    let capped = Observe.noWindowLogLine(
        bundleID: "b",
        titleHint: String(repeating: "x", count: 200)
    ).count <= prefix.count + 80
    if !(sanitized && capped) { ok = false }
    print("SCREENSHOT_LOG_LINE sanitized=\(sanitized) capped=\(capped)")

    let noWindow = Observe.noWindowResult(bundleID: bogus, titleHint: "probe")
    let typedNil = noWindow.shot == nil && noWindow.denied == false
    if !typedNil { ok = false }
    print("SCREENSHOT_NO_WINDOW shot_nil=\(noWindow.shot == nil) denied=\(noWindow.denied)")

    // (c) The public entry point never widens to the display.
    let direct = Observe.screenshot(bundleID: bogus, windowTitleHint: "")
    let entryScoped = direct.shot == nil && direct.denied == false && direct.fellBack == false
    if !entryScoped { ok = false }
    print("SCREENSHOT_ENTRY shot_nil=\(direct.shot == nil)"
        + " denied=\(direct.denied) fellBack=\(direct.fellBack)")

    print("SCREENSHOT_SCOPE_PROBE=\(ok ? "ok" : "fail")")
    fflush(stdout)
    exit(ok ? 0 : 1)
}


/// event posted and no UI shown:
/// `--test-ui-tools`: the computer-use act registry (SPEC §4.5). Proves, with no
/// event posted and no UI shown:
///   (a) the `list_tools` output includes the four new names,
///   (b) every new act tool is approval-gated (`PopTool.requiresApproval`),
///   (c) `UIAct.keyPlan` is table-driven and correct (named keys + combos, and
///       nil for an unknown key — never a silent no-op),
///   (d) `app_manage` rejects an unknown action at its validate level.
/// Gate: `UI_TOOLS_PROBE=ok` and exit 0; exit 1 otherwise.
private func runUIToolsProbe() {
    var ok = true
    let newTools = ["app_manage", "ui_ax", "ui_key", "ui_scroll"]

    // (b) Each new act tool is approval-gated. `requiresApproval` is the ONE
    // predicate the gate and this probe share, so a drifted class fails here.
    for name in newTools {
        let tool = ToolRegistry.tool(named: name)
        let gated = tool.map { PopTool.requiresApproval($0.access) } ?? false
        print("UI_TOOLS_GATED \(name)=\(gated) access=\(tool?.access.rawValue ?? "missing")")
        if !gated { ok = false }
    }

    // (c) The pure, table-driven key plan.
    let keyTable: [(key: String, vt: Int, mods: UInt64)] = [
        ("return", 36, 0),
        ("escape", 53, 0),
        ("cmd+w", 13, 0x100000),
        ("cmd+shift+t", 17, 0x120000),
        ("up", 126, 0),
        ("space", 49, 0)
    ]
    for row in keyTable {
        let plan = UIAct.keyPlan(row.key)
        let matches = plan?.vt == row.vt && plan?.mods == row.mods
        print("UI_KEY_PLAN \(row.key)=vt\(plan?.vt.description ?? "nil")"
            + "+\(plan?.mods.description ?? "nil") expected=vt\(row.vt)+\(row.mods) ok=\(matches)")
        if !matches { ok = false }
    }
    let unknownKeyNil = UIAct.keyPlan("definitely-not-a-key") == nil
    print("UI_KEY_PLAN unknown_key_nil=\(unknownKeyNil)")
    if !unknownKeyNil { ok = false }

    // (d) app_manage validates its action before any app work.
    let unknownRejected = UIAct.appActionPlan("nonsense") == nil
    let knownAccepted = UIAct.appActionPlan("quit") == "quit"
    print("APP_MANAGE_UNKNOWN_REJECTED=\(unknownRejected)")
    print("APP_MANAGE_KNOWN_ACCEPTED=\(knownAccepted)")
    if !unknownRejected || !knownAccepted { ok = false }

    // (a) The REAL `list_tools` body, run through `execute` exactly as a model
    // turn would (it is read-only, so no approval card). `execute` is not
    // main-actor-bound and the list body suspends nothing, so a detached task
    // completes while this thread waits on the semaphore.
    nonisolated(unsafe) var listing = ""
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        listing = await ToolRegistry.execute((name: "list_tools", arguments: .object([:])))
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 20)
    for name in newTools {
        let present = listing.contains(name)
        print("UI_TOOLS_LIST \(name)=\(present)")
        if !present { ok = false }
    }

    print("UI_TOOLS_PROBE=\(ok ? "ok" : "fail")")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

/// `--test-hats`: the route→hat truth table. PURE — no provider, no loop, no
/// network. Each routed class yields a non-empty hat with its distinctive
/// prefix; nil/chat/unknown yield the empty string, so nothing is injected.
/// Gate: `HATS_PROBE=ok`; exit 0/1.
private func runHatsProbe() {
    var ok = true
    let cases: [(route: String, prefix: String)] = [
        ("computer-use", "You are a macOS expert"),
        ("browser", "You are an expert web research assistant"),
        ("files", "You are a precise file-system assistant"),
        ("web", "You are an expert research analyst")
    ]
    for entry in cases {
        let hat = AgentLoop.hat(for: entry.route)
        let matches = !hat.isEmpty && hat.hasPrefix(entry.prefix)
        print("HAT_ROUTE \(entry.route)=\(matches)")
        if !matches { ok = false }
    }
    let emptyChat = AgentLoop.hat(for: "chat").isEmpty
    let emptyNil = AgentLoop.hat(for: nil).isEmpty
    let emptyUnknown = AgentLoop.hat(for: "a-new-class").isEmpty
    print("HAT_EMPTY chat=\(emptyChat) nil=\(emptyNil) unknown=\(emptyUnknown)")
    if !emptyChat || !emptyNil || !emptyUnknown { ok = false }

    print("HATS_PROBE=\(ok ? "ok" : "fail")")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

/// `--test-ui-observe`: the ref-based native perception path, driven through the
/// REAL tool registry with every seam supplied (no live AX walk, no card). The
/// snapshot is injected; `ui_observe` returns the ref list; `ui_ax` by `ref`
/// resolves and acts with NO title; an app switch makes the ref stale. Gate:
/// `UI_OBSERVE_PROBE=ok`; exit 0/1.
@MainActor
private func runUIObserveProbe() {
    _ = NSApplication.shared
    let configPath = NSTemporaryDirectory() + "pop-uiobserve-\(UUID().uuidString).json"
    setenv("POP_CONFIG_PATH", configPath, 1)
    var config = PopConfig.defaults
    // A ref act is a reversible screen act: the standing approval lets it run
    // without a card, so the probe measures the ref path, not the gate.
    config.autoRunScreenActions = true
    try? config.write()

    BrowserActions.accessibilityOverride = true
    Observe.frontmostOverride = (bundleID: "com.probe.app", name: "ProbeApp")
    UIAct.observeElementsOverride = [
        UIAct.ObservedElement(
            ref: 1, role: "AXButton", title: "First", value: "",
            position: CGPoint(x: 10, y: 10), element: nil,
            press: { .success }, setValue: nil
        ),
        UIAct.ObservedElement(
            ref: 2, role: "AXButton", title: "Second", value: "",
            position: CGPoint(x: 20, y: 20), element: nil,
            press: { .success }, setValue: nil
        ),
        UIAct.ObservedElement(
            ref: 3, role: "AXTextField", title: "Name", value: "",
            position: CGPoint(x: 30, y: 30), element: nil,
            press: nil, setValue: { _ in .success }
        )
    ]

    Task { @MainActor in
        defer {
            BrowserActions.accessibilityOverride = nil
            Observe.frontmostOverride = nil
            UIAct.observeElementsOverride = nil
            UIAct.lastObservation = nil
            try? FileManager.default.removeItem(atPath: configPath)
        }
        var ok = true

        let observed = await ToolRegistry.execute(("ui_observe", .object([:])))
        let refsListed = observed.contains("[1]") && observed.contains("[2]")
            && observed.contains("[3]") && observed.contains("ProbeApp")
        print("UI_OBSERVE_REFS=\(refsListed)")
        print("UI_OBSERVE_TEXT=\(observed.replacingOccurrences(of: "\n", with: " | "))")
        if !refsListed { ok = false }

        // Ref act with NO title — the whole point of the ref path.
        let acted = await ToolRegistry.execute((
            "ui_ax",
            .object(["ref": .number(2), "action": .string("press")])
        ))
        let byRef = acted.contains("pressed") && acted.contains("[2]") && !acted.hasPrefix("ERROR:")
        print("UI_AX_BY_REF=\(byRef)")
        print("UI_AX_BY_REF_TEXT=\(acted.replacingOccurrences(of: "\n", with: " | "))")
        if !byRef { ok = false }

        // App switch -> the ref is stale and refused with a precise reason.
        Observe.frontmostOverride = (bundleID: "com.other.app", name: "OtherApp")
        let stale = await ToolRegistry.execute((
            "ui_ax",
            .object(["ref": .number(2), "action": .string("press")])
        ))
        let staleHandled = stale.contains("stale")
        print("UI_OBSERVE_STALE_HANDLED=\(staleHandled)")
        print("UI_OBSERVE_STALE_TEXT=\(stale.replacingOccurrences(of: "\n", with: " | "))")
        if !staleHandled { ok = false }

        print("UI_OBSERVE_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("UI_OBSERVE_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// A round counter a scripted provider closure can share across the loop's
/// repeated `stream` calls.
final class PlaybookRoundBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// `--test-automation-playbook`: the route-conditional hat/playbook injection
/// AND the gated-timeout nudge, through the REAL loop with scripted providers.
///   (a) route=computer-use -> the hat line AND the playbook appear in the round
///       context the provider is handed (`HAT_INJECTED`).
///   (b) route=nil -> nothing injected and the bytes equal a second no-route
///       turn (`HAT_ABSENT_WHEN_DISABLED`).
///   (c) a gated `.timeout` -> the nudge fires exactly once per turn
///       (`TIMEOUT_NUDGE_ONCE`).
/// Gate: `AUTOMATION_PLAYBOOK_PROBE=ok`; exit 0/1.
private func runAutomationPlaybookProbe() {
    _ = NSApplication.shared

    func drive(provider: ModelProvider, route: AgentLoop.RouteResolution?) async -> [ChatMessage] {
        do {
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: "a routed native task")],
                options: GenerationOptions(),
                tools: ToolRegistry.schemas(),
                route: route
            ) { _ in }
            for try await _ in events {}
        } catch {
            print("AUTOMATION_PLAYBOOK_TURN_ERROR \(error)")
            fflush(stdout)
        }
        return []
    }

    Task { @MainActor in
        var ok = true

        // (a) route=computer-use -> hat + playbook in the context.
        let routedBox = ScriptedProviderBox()
        let routedProvider = ScriptedProvider(nativelyExecutesTools: false, box: routedBox) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.done("done"))
                continuation.finish()
            }
        }
        await drive(
            provider: routedProvider,
            route: AgentLoop.RouteResolution(choice: "computer-use")
        )
        let routedText = routedBox.requests.first?.map(\.text).joined(separator: "\n") ?? ""
        let hatInjected = routedText.contains("You are a macOS expert")
            && routedText.contains("automation playbook")
        print("HAT_INJECTED=\(hatInjected)")
        if !hatInjected { ok = false }

        // (b) route=nil -> nothing injected; two runs are byte-identical.
        func noRouteText() async -> String {
            let box = ScriptedProviderBox()
            let provider = ScriptedProvider(nativelyExecutesTools: false, box: box) { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.done("done"))
                    continuation.finish()
                }
            }
            await drive(provider: provider, route: nil)
            return box.requests.first?.map(\.text).joined(separator: "\n") ?? ""
        }
        let noRouteFirst = await noRouteText()
        let noRouteSecond = await noRouteText()
        let absent = !noRouteFirst.contains("You are a macOS expert")
            && !noRouteFirst.contains("automation playbook")
            && noRouteFirst == noRouteSecond
        print("HAT_ABSENT_WHEN_DISABLED=\(absent)")
        if !absent { ok = false }

        // (c) gated .timeout -> the nudge fires once per turn.
        let configPath = NSTemporaryDirectory() + "pop-playbook-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", configPath, 1)
        var config = PopConfig.defaults
        config.autoRunScreenActions = false
        try? config.write()
        setenv("POP_APPROVAL_TIMEOUT", "1", 1)

        let timeoutBox = ScriptedProviderBox()
        let rounds = PlaybookRoundBox()
        let timeoutProvider = ScriptedProvider(nativelyExecutesTools: false, box: timeoutBox) { _, _ in
            AsyncThrowingStream { continuation in
                let index = rounds.next()
                if index <= 2 {
                    continuation.yield(.toolCall(
                        id: "call_gated_\(index)",
                        name: "write_file",
                        arguments: .object([
                            "path": .string(NSTemporaryDirectory() + "pop-never-\(index).txt"),
                            "content": .string("blocked")
                        ])
                    ))
                } else {
                    continuation.yield(.done("stopped"))
                }
                continuation.finish()
            }
        }
        await drive(provider: timeoutProvider, route: nil)
        let finalTexts = timeoutBox.requests.last?.map(\.text) ?? []
        let nudgeCount = finalTexts.filter { $0 == AgentLoop.gatedTimeoutNudge }.count
        let nudgeOnce = nudgeCount == 1
        print("TIMEOUT_NUDGE_ONCE=\(nudgeOnce) count=\(nudgeCount) requests=\(timeoutBox.requests.count)")
        if !nudgeOnce { ok = false }

        try? FileManager.default.removeItem(atPath: configPath)
        print("AUTOMATION_PLAYBOOK_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("AUTOMATION_PLAYBOOK_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-brain-md`: THE BRAIN'S THINKING AS DATA. The bundled `brain.md`
/// loads the per-route hats, the playbook and the policies; a missing/
/// unparseable file falls back to today's strings. Asserts the macOS-expert hat
/// for computer-use, a non-empty playbook, at least two policy lines, and — the
/// single-source-of-truth invariant — that the SHIPPED file's thinking is
/// byte-identical to the fallback. Gate: `BRAIN_MD_PROBE=ok`; exit 0/1.
private func runBrainMDProbe() {
    var ok = true

    let hat = BrainLoader.hat(for: "computer-use")
    let hatOK = hat.hasPrefix("You are a macOS expert")
    print("BRAIN_MD_HAT=\(hatOK)")
    if !hatOK { ok = false }

    let playbookOK = !BrainLoader.playbook.isEmpty
        && BrainLoader.playbook.contains("automation playbook")
    print("BRAIN_MD_PLAYBOOK=\(playbookOK)")
    if !playbookOK { ok = false }

    let policiesOK = BrainLoader.policies.count >= 2
    print("BRAIN_MD_POLICIES=\(policiesOK) count=\(BrainLoader.policies.count)")
    if !policiesOK { ok = false }

    // The single source of truth: the file present in the repo/bundle must
    // produce EXACTLY the fallback thinking, so missing-file behavior is
    // byte-identical to shipped behavior.
    let identical = BrainLoader.loaded == BrainLoader.fallback
    print("BRAIN_MD_DEFAULT_EQUALS_FALLBACK=\(identical)")
    if !identical { ok = false }

    // Missing file: the loader reports nil and the fallback is today's strings.
    let missingNil = BrainLoader.load(from: nil) == nil
        && BrainLoader.load(from: URL(fileURLWithPath: "/nonexistent/brain.md")) == nil
    let fallbackHat = BrainLoader.fallback.hats["computer-use"] ?? ""
    let fallbackOK = missingNil
        && fallbackHat.hasPrefix("You are a macOS expert")
        && BrainLoader.fallback.playbook.contains("automation playbook")
    print("BRAIN_MD_FALLBACK=\(fallbackOK)")
    if !fallbackOK { ok = false }

    print("BRAIN_MD_PROBE=\(ok ? "ok" : "fail")")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

/// `--test-premise-noul`: the PURE noul parser + verdict truth table for the T3
/// premise gate. A noul is a NUMBER (0..1): 0.9 → true, 0.3 → false, a
/// non-numeric or boolean value → nil (fail-open). Gate: `PREMISE_NOUL_PROBE=ok`;
/// exit 0/1.
private func runPremiseNoulProbe() {
    var ok = true

    func check(_ name: String, _ json: String, expect: Double?) {
        let got = JevBridge.parseNoul(Data(json.utf8))
        let match: Bool
        if let expect, let got {
            match = abs(got - expect) < 1e-9
        } else {
            match = (got == nil && expect == nil)
        }
        print("PREMISE_NOUL \(name)=\(match) got=\(got.map { String($0) } ?? "-")")
        if !match { ok = false }
    }

    check("high", #"{"model":"jev-1.13.0","answers":{"p":{"type":"noul","noul":0.9}}}"#, expect: 0.9)
    check("low", #"{"model":"jev-1.13.0","answers":{"p":{"type":"noul","noul":0.3}}}"#, expect: 0.3)
    check("non-numeric", #"{"model":"jev-1.13.0","answers":{"p":{"type":"noul","noul":"high"}}}"#, expect: nil)
    check("boolean", #"{"model":"jev-1.13.0","answers":{"p":{"type":"noul","noul":true}}}"#, expect: nil)
    check("missing-model", #"{"answers":{"p":{"noul":0.9}}}"#, expect: nil)
    check("out-of-range", #"{"model":"jev-1.13.0","answers":{"p":{"noul":5}}}"#, expect: nil)
    check("flattened", #"{"model":"jev-1.13.0","p":{"type":"noul","noul":0.42}}"#, expect: 0.42)

    let holdsHigh = JevBridge.premiseHolds(noul: 0.9)
    let holdsLow = JevBridge.premiseHolds(noul: 0.3)
    print("PREMISE_NOUL_VERDICT high=\(holdsHigh) low=\(holdsLow)")
    if !holdsHigh || holdsLow { ok = false }

    print("PREMISE_NOUL_PROBE=\(ok ? "ok" : "fail")")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

/// `--test-micro-assist`: the T2 on-device micro-assist, seam-driven.
///   (a) available + a confident match → the candidate title is picked.
///   (b) unavailable → nil, and the step proceeds on the existing error.
///   (c) available but below threshold → no retry (nil).
/// Gate: `MICRO_ASSIST_PROBE=ok`; exit 0/1.
@available(macOS 26.0, *)
private func runMicroAssistProbe() {
    _ = NSApplication.shared
    Task {
        var ok = true

        // (a) available + scripted confident match -> the candidate is picked.
        ProviderTestSeams.shared.availability = .available
        AppleFMMicro.sessionOverride = { _ in
            #"{"choice": "Second", "confidence": 0.9}"#
        }
        let hit = await AppleFMMicro.assistedPick(
            intent: "press the second button",
            candidates: ["First", "Second"],
            threshold: 0.7
        )
        let hitOK = hit == "Second"
        print("MICRO_ASSIST_HIT=\(hitOK)")
        if !hitOK { ok = false }

        // (b) on-device absent -> nil, fail-open.
        AppleFMMicro.sessionOverride = nil
        ProviderTestSeams.shared.availability = .unavailable(.appleIntelligenceNotEnabled)
        let unavailable = await AppleFMMicro.assistedPick(
            intent: "press the second button",
            candidates: ["First", "Second"],
            threshold: 0.7
        )
        let failOpen = unavailable == nil
        print("MICRO_ASSIST_FAIL_OPEN=\(failOpen)")
        if !failOpen { ok = false }

        // (c) available but below threshold -> no retry.
        ProviderTestSeams.shared.availability = .available
        AppleFMMicro.sessionOverride = { _ in
            #"{"choice": "Second", "confidence": 0.2}"#
        }
        let low = await AppleFMMicro.assistedPick(
            intent: "press the second button",
            candidates: ["First", "Second"],
            threshold: 0.7
        )
        let lowOK = low == nil
        print("MICRO_ASSIST_LOW_CONF=\(lowOK)")
        if !lowOK { ok = false }

        AppleFMMicro.resetSeams()
        ProviderTestSeams.shared.availability = nil
        print("MICRO_ASSIST_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("MICRO_ASSIST_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-autonomy`: the STANDING APPROVAL for reversible screen acts, plus the
/// browser tab-reuse decision. Proves, with NO event posted and NO browser open:
///   (a) the pure tab-reuse decision (same host+path → focusExisting; same host
///       different path → navigateInPlace; different host / mailto → openNew),
///   (b) the pure auto-run classification (the four screen acts are covered;
///       bash/write/edit/apply_patch/ui_type and app_manage-quit are not),
///   (c) with the flag ON, an in-bounds point auto-approves WITHOUT a card and
///       an out-of-bounds point still pushes one; ui_type still pushes one,
///   (d) with the flag OFF, the same call pushes a card as today.
/// Gate: `AUTONOMY_PROBE=ok` and exit 0; exit 1 otherwise.
@MainActor
private func runAutonomyProbe() {
    Task { @MainActor in
        var ok = true

        // (a) Tab-reuse DECISION truth table. The AppleScript leg is not
        // headlessly testable; the DECISION is pure.
        func checkReuse(
            _ name: String,
            target: String,
            tabs: [TabFocus.OpenTab],
            expect: BrowserActions.ReusePlan,
            picked: String? = nil
        ) -> Bool {
            guard let url = URL(string: target) else { ok = false; return false }
            let got = BrowserActions.reuseDecision(targetURL: url, openTabs: tabs)
            let match = got.plan == expect && (picked == nil || got.picked == picked)
            if !match { ok = false }
            print("TAB_REUSE \(name)=\(match) got=\(BrowserActions.planName(got.plan)) picked=\(got.picked)")
            return match
        }
        var selectOK = true
        let tabs: [TabFocus.OpenTab] = [
            TabFocus.OpenTab(
                title: "Notifications",
                url: "https://www.linkedin.com/notifications/",
                windowIndex: 1, tabIndex: 1, active: true, isActiveWindow: true
            )
        ]
        selectOK = checkReuse(
            "same-host-path",
            target: "https://www.linkedin.com/notifications#top",
            tabs: tabs,
            expect: .focusExisting(windowIndex: 1, tabIndex: 1)
        ) && selectOK
        selectOK = checkReuse(
            "same-host-different-path",
            target: "https://www.linkedin.com/feed",
            tabs: tabs,
            expect: .navigateInPlace(windowIndex: 1, tabIndex: 1)
        ) && selectOK
        selectOK = checkReuse(
            "different-host",
            target: "https://example.com/notifications",
            tabs: tabs,
            expect: .openNew
        ) && selectOK
        selectOK = checkReuse("mailto", target: "mailto:x@example.com", tabs: tabs, expect: .openNew)
            && selectOK

        // (a1) PREFERENCE — active wins over EARLIER enumeration order: the
        // second LinkedIn tab is active in the front window, so it is chosen
        // even though the first host match appears first.
        let activeWinsTabs: [TabFocus.OpenTab] = [
            TabFocus.OpenTab(
                title: "LinkedIn feed",
                url: "https://www.linkedin.com/feed",
                windowIndex: 1, tabIndex: 1, active: false, isActiveWindow: true
            ),
            TabFocus.OpenTab(
                title: "LinkedIn jobs",
                url: "https://www.linkedin.com/jobs",
                windowIndex: 1, tabIndex: 2, active: true, isActiveWindow: true
            )
        ]
        selectOK = checkReuse(
            "active-front",
            target: "https://www.linkedin.com/jobs/view/1",
            tabs: activeWinsTabs,
            expect: .navigateInPlace(windowIndex: 1, tabIndex: 2),
            picked: "active"
        ) && selectOK

        // (a2) No active match, TWO same-host matches -> closest PATH wins
        // (the /jobs/view/1 tab over the /feed tab).
        let closestTabs: [TabFocus.OpenTab] = [
            TabFocus.OpenTab(
                title: "feed",
                url: "https://www.linkedin.com/feed",
                windowIndex: 1, tabIndex: 1, active: false, isActiveWindow: true
            ),
            TabFocus.OpenTab(
                title: "jobs",
                url: "https://www.linkedin.com/jobs/view/1",
                windowIndex: 2, tabIndex: 1, active: false, isActiveWindow: false
            )
        ]
        selectOK = checkReuse(
            "closest-path",
            target: "https://www.linkedin.com/jobs/view/1",
            tabs: closestTabs,
            expect: .focusExisting(windowIndex: 2, tabIndex: 1),
            picked: "closest-path"
        ) && selectOK

        // (a3) No active match, ONE match -> first-match fallback (old behavior).
        let singleTabs: [TabFocus.OpenTab] = [
            TabFocus.OpenTab(
                title: "jobs",
                url: "https://www.linkedin.com/jobs",
                windowIndex: 2, tabIndex: 3, active: false, isActiveWindow: false
            )
        ]
        selectOK = checkReuse(
            "first-match",
            target: "https://www.linkedin.com/jobs/view/1",
            tabs: singleTabs,
            expect: .navigateInPlace(windowIndex: 2, tabIndex: 3),
            picked: "first-match"
        ) && selectOK

        // THE RETEST CASE: a tab already matching host+path is REUSED, so no new
        // tab is opened (the trailing slash is ignored).
        let reuseNeverNew = BrowserActions.reuseDecision(
            targetURL: URL(string: "https://www.linkedin.com/notifications")!,
            openTabs: tabs
        ).plan == .focusExisting(windowIndex: 1, tabIndex: 1)
        if !reuseNeverNew { ok = false }
        print("TAB_REUSE_NEVER_NEW=\(reuseNeverNew)")

        if !selectOK { ok = false }
        print("TAB_SELECT_PROBE=\(selectOK ? "ok" : "fail")")

        // (b) Auto-run classification, pure and static.
        let autoTrue = ["ui_click", "ui_scroll", "ui_key", "ui_ax"]
            .allSatisfy { ApprovalGate.autoRunnable(tool: $0) }
        let appActivate = ApprovalGate.autoRunnable(tool: "app_manage", action: "activate")
        let appOpen = ApprovalGate.autoRunnable(tool: "app_manage", action: "open")
        let appQuit = ApprovalGate.autoRunnable(tool: "app_manage", action: "quit")
        let alwaysGated = ["bash", "write_file", "edit_file", "apply_patch", "ui_type"]
            .allSatisfy { !ApprovalGate.autoRunnable(tool: $0) }
        let classified = autoTrue && appActivate && appOpen && !appQuit && alwaysGated
        if !classified { ok = false }
        print("AUTONOMY_AUTORUN_SET=\(autoTrue) app=\(appActivate)/\(appOpen)"
            + " quit=\(appQuit) alwaysGated=\(alwaysGated)")

        // (c)/(d) The GATE, driven directly with seamed bounds. The sink would
        // FAIL the probe if a card were pushed while the flag is ON, so a
        // pushed card is answered (deny) to keep the call from waiting.
        setenv("POP_APPROVAL_TIMEOUT", "3", 1)
        let onPath = NSTemporaryDirectory() + "pop-autonomy-on-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", onPath, 1)
        var onConfig = PopConfig.defaults
        onConfig.autoRunScreenActions = true
        try? onConfig.write()
        BrowserActions.boundsOverride = { [CGRect(x: 0, y: 0, width: 2000, height: 2000)] }

        let cards = JevProbeCounter()
        ApprovalGate.shared.sink = { json in
            cards.bump()
            if let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = object["id"] as? String {
                _ = ApprovalGate.shared.submit(id: id, decision: "deny", arguments: nil)
            }
        }

        // In-bounds ui_click → auto-approves, NO card.
        cards.reset()
        let inVerdict = await ApprovalGate.shared.requestApproval(
            tool: "ui_click",
            arguments: .object(["x": .number(10), "y": .number(10)])
        )
        let autoInBounds = inVerdict.isApproved && cards.count == 0
        // Out-of-bounds ui_click → a normal card (the point guard holds).
        let outVerdict = await ApprovalGate.shared.requestApproval(
            tool: "ui_click",
            arguments: .object(["x": .number(99999), "y": .number(99999)])
        )
        let outGated = cards.count == 1 && !outVerdict.isApproved
        // ui_type is NEVER auto-run: a card even with the flag ON.
        cards.reset()
        let typeVerdict = await ApprovalGate.shared.requestApproval(
            tool: "ui_type",
            arguments: .object(["text": .string("hi")])
        )
        let typeGated = cards.count == 1 && !typeVerdict.isApproved
        if !autoInBounds || !outGated || !typeGated { ok = false }
        print("AUTONOMY_INBOUNDS_AUTORUN=\(autoInBounds)")
        print("AUTONOMY_OUTOFBOUNDS_GATED=\(outGated)")
        print("AUTONOMY_UI_TYPE_GATED=\(typeGated)")

        // (d) Flag OFF → the same in-bounds call pushes a card, as today.
        let offPath = NSTemporaryDirectory() + "pop-autonomy-off-\(UUID().uuidString).json"
        setenv("POP_CONFIG_PATH", offPath, 1)
        var offConfig = PopConfig.defaults
        offConfig.autoRunScreenActions = false
        try? offConfig.write()
        cards.reset()
        let offVerdict = await ApprovalGate.shared.requestApproval(
            tool: "ui_click",
            arguments: .object(["x": .number(10), "y": .number(10)])
        )
        let offGated = cards.count == 1 && !offVerdict.isApproved
        if !offGated { ok = false }
        print("AUTONOMY_FLAG_OFF_GATED=\(offGated)")

        ApprovalGate.shared.sink = nil
        BrowserActions.boundsOverride = nil
        try? FileManager.default.removeItem(atPath: onPath)
        try? FileManager.default.removeItem(atPath: offPath)

        // (e) THE WIDENED ACT SURFACE. Computer-use acts on the apps the user
        // can see, the way a human would: UI first, shell last. Driven through
        // the SAME boundsOverride seam the gate arms use — a NON-browser window
        // frame must be accepted by the real ui_click act path, while Pop's own
        // panel is never a target (a pure predicate, so no live panel needed).
        let nonBrowserFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        BrowserActions.accessibilityOverride = true
        BrowserActions.eventSinkOverride = { _ in }
        BrowserActions.boundsOverride = { [nonBrowserFrame] }
        let widenedBounds = await BrowserActions.visibleWindowBounds()
        let actResult = await BrowserActions.click(
            x: Int(nonBrowserFrame.midX), y: Int(nonBrowserFrame.midY)
        )
        BrowserActions.boundsOverride = nil
        BrowserActions.eventSinkOverride = nil
        BrowserActions.accessibilityOverride = nil
        let nonBrowserAllowed = !actResult.hasPrefix("ERROR:")
            && widenedBounds.contains(nonBrowserFrame)
            && BrowserActions.pointIsAllowed(
                CGPoint(x: nonBrowserFrame.midX, y: nonBrowserFrame.midY), in: widenedBounds
            )
        let panelExcluded = !ScreenOCR.isActTarget(
            ownerBundleID: ScreenOCR.ownBundleID, frame: nonBrowserFrame,
            excluding: [ScreenOCR.ownBundleID]
        )
        let unattributedExcluded = !ScreenOCR.isActTarget(
            ownerBundleID: nil, frame: nonBrowserFrame,
            excluding: [ScreenOCR.ownBundleID]
        )
        print("ACT_SURFACE_NONBROWSER_ALLOWED=\(nonBrowserAllowed)")
        print("PANEL_STILL_EXCLUDED=\(panelExcluded && unattributedExcluded)")
        if !nonBrowserAllowed || !panelExcluded || !unattributedExcluded { ok = false }

        print("AUTONOMY_PROBE=\(ok ? "ok" : "fail")")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("AUTONOMY_PROBE=fail (timeout)")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// Records, per walking turn, the tools that ran and how many were web calls —
/// so the honest-failure arm can prove no domain crossing. It also snapshots
/// the LIVE plan block on every `plan_update` outcome, which is exactly what
/// the page would render, so a probe can assert the executor visibly marked
/// steps `running`/`done` rather than only changing a hidden counter.
@MainActor
final class WalkthroughLog {
    private(set) var outcomes: [(name: String, ok: Bool)] = []
    private(set) var webCalls = 0
    private(set) var planSnapshots: [[String]] = []
    func record(_ outcome: ToolRoundOutcome) {
        outcomes.append((outcome.name, outcome.ok))
        if outcome.name == "web_lookup" { webCalls += 1 }
        if outcome.name == "plan_update", outcome.ok {
            planSnapshots.append(PlanTraceStore.shared.renderedLines)
        }
    }
    func reset() { outcomes = []; webCalls = 0; planSnapshots = [] }
}

/// An ORDERED, thread-safe record of the two streams a live-feedback gate must
/// interleave: `provider_call …` (the model) and `ui …` (the panel's turn-UI
/// events). Written from the scripted provider and the loop's `onUI` channel;
/// read after a turn to prove the working indicator fired AT T0 and the
/// confirmation landed before any final model call.
final class ProbeTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func note(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func reset() { lock.lock(); events = []; lock.unlock() }
}

/// A thread-safe record of approval-card JSON, captured from the gate's sink.
final class CardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []
    var cards: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        lock.lock(); storage.append(object); lock.unlock()
    }
}

/// A settable flag the gate sink can raise without touching actor state.
final class ApprovalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// `--test-walkthrough-tab-read`: THE WHOLE JOURNEY, not the parts.
///
/// Every browser and screen call rides a TEST SEAM, so the walk is
/// deterministic and touches no real window, browser or network:
///   STEP1_RAISED  — `browser_focus_tab` raises the buried tab (seamed runner).
///   STEP2_CLICKED — `ui_click` lands on a fixture line's centre (seamed bounds
///                   + event sink), with NO approval card (autonomy).
///   STEP3_READ    — `screen_read` re-reads the fixture (seamed reading).
///   STEP4_ANSWERED— the turn ends with a real answer.
/// The honest-failure arm makes the tab unfindable; the turn must name the
/// blocked step and must NOT cross to the web (no domain crossing). The
/// plan-exec arm emits the WHOLE plan as ONE `plan_update` call carrying a
/// `run` payload and proves the executor runs raise/click/type+send/read with
/// ZERO model rounds between the steps, marking the live plan as it goes; the
/// step-failure arm proves exactly ONE adaptation round follows a blocked step.
/// The component arms measure coordinate hygiene, click/send autonomy, and the
/// window-bounds guard.
@MainActor
private func runWalkthroughTabReadProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let fixtureFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    let fixtureLine = ScreenOCR.RecognizedLine(
        text: "Fixture line text",
        rect: CGRect(x: 200, y: 220, width: 300, height: 20)
    )
    let clickPoint = CGPoint(x: fixtureLine.rect.midX, y: fixtureLine.rect.midY)

    // --- SEAMS -------------------------------------------------------------
    // A canned screen reading stands in for the fixture window.
    ScreenOCR.readOverride = { _ in
        var window = ScreenOCR.WindowReading()
        window.order = 0
        window.appName = "Fixture"
        window.windowTitle = "Fixture tab"
        window.frame = fixtureFrame
        window.lines = [fixtureLine]
        window.text = fixtureLine.rendered
        var reading = ScreenOCR.Reading()
        reading.windows = [window]
        reading.scopeName = "front"
        return reading
    }
    // The focus script reports a raised tab unless the blocked arm swaps it.
    TabFocus.runningCheckerOverride = { _ in true }
    TabFocus.scriptRunnerOverride = { _ in .output("FOUND\t1\t2\tFixture tab") }
    // The click may land inside the fixture frame; events are counted, never
    // delivered (Accessibility is seamed granted).
    let clickEvents = BrowserEventRecorder()
    BrowserActions.accessibilityOverride = true
    BrowserActions.boundsOverride = { [fixtureFrame] }
    BrowserActions.eventSinkOverride = { event in clickEvents.record(event) }
    defer {
        ScreenOCR.readOverride = nil
        TabFocus.runningCheckerOverride = nil
        TabFocus.scriptRunnerOverride = nil
        BrowserActions.accessibilityOverride = nil
        BrowserActions.boundsOverride = nil
        BrowserActions.eventSinkOverride = nil
    }

    let log = WalkthroughLog()

    func runTurn(
        _ provider: ModelProvider,
        prompt: String,
        timeline: ProbeTimeline? = nil
    ) async -> String {
        var full = ""
        do {
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: prompt)],
                options: GenerationOptions(),
                tools: ToolRegistry.schemas(),
                onUI: timeline.map { record -> (@Sendable (TurnUIEvent) async -> Void) in
                    { @Sendable event in
                        switch event {
                        case .working: record.note("ui working")
                        case .ready: record.note("ui ready")
                        case .confirmation(let line):
                            record.note("ui confirmation \(line)")
                        case .notice(let line):
                            record.note("ui notice \(line)")
                        }
                    }
                }
            ) { outcome in
                await MainActor.run { log.record(outcome) }
            }
            for try await event in events {
                switch event {
                case .delta(let piece): full += piece
                case .done(let text): full = text
                case .toolCall: break
                }
            }
        } catch {
            print("WALKTHROUGH_TURN_ERROR \(error)")
        }
        return full
    }

    Task { @MainActor in
        // ONE sink for the WHOLE journey. The send gate is gone, so NO local
        // action anywhere in this probe may raise a card; recording every card
        // for the full duration is what makes ANY_LOCAL_APPROVAL_CARDS
        // meaningful rather than per-arm.
        let nativeSink = ApprovalGate.shared.sink
        let allCards = CardRecorder()
        let approvalAsked = ApprovalFlag()
        ApprovalGate.shared.sink = { json in
            allCards.record(json)
            approvalAsked.set()
        }

        // === STEP 1-4: the journey =========================================
        log.reset()
        clickEvents.reset()
        let journeyAnswer = await runTurn(
            ScriptedWalkthroughProvider(mode: .journey),
            prompt: "read the fixture tab"
        )
        let step1 = log.outcomes.first { $0.name == "browser_focus_tab" }?.ok ?? false
        let step2 = (log.outcomes.first { $0.name == "ui_click" }?.ok ?? false)
            && clickEvents.count >= 3
        let step3 = log.outcomes.first { $0.name == "screen_read" }?.ok ?? false
        let step4 = !journeyAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        print("STEP1_RAISED=\(step1)")
        print("STEP2_CLICKED=\(step2)")
        print("STEP3_READ=\(step3)")
        print("STEP4_ANSWERED=\(step4)")
        print("WALKTHROUGH_TOOLS=\(log.outcomes.map(\.name).joined(separator: ","))")
        print("WALKTHROUGH_ANSWER=\(journeyAnswer.replacingOccurrences(of: "\n", with: " "))")
        let walkthroughComplete = step1 && step2 && step3 && step4
        print("WALKTHROUGH_COMPLETE=\(walkthroughComplete)")
        fflush(stdout)

        // === HONEST-FAILURE JOURNEY ========================================
        // The tab cannot be found: the turn must name the blocked step and must
        // not reach for the web.
        log.reset()
        TabFocus.scriptRunnerOverride = { _ in .output("NOMATCH\n") }
        let blockedAnswer = await runTurn(
            ScriptedWalkthroughProvider(mode: .blocked),
            prompt: "read the fixture tab"
        )
        let namesBlockedStep = blockedAnswer.lowercased().contains("step 1")
            && blockedAnswer.lowercased().contains("blocked")
        let noDomainCross = log.webCalls == 0
            && !log.outcomes.contains { $0.name == "web_lookup" }
        let honestFail = namesBlockedStep && noDomainCross
        print("WALKTHROUGH_HONEST_FAIL=\(honestFail)")
        print("WALKTHROUGH_FAIL_NAMES_STEP=\(namesBlockedStep)")
        print("WALKTHROUGH_FAIL_ANSWER=\(blockedAnswer.replacingOccurrences(of: "\n", with: " "))")
        print("NO_DOMAIN_CROSS=\(noDomainCross)")
        fflush(stdout)

        // === COMPONENT ARM: click autonomy =================================
        clickEvents.reset()
        let autoClick = await ToolRegistry.execute((
            "ui_click",
            .object([
                "x": .number(Double(clickPoint.x)),
                "y": .number(Double(clickPoint.y))
            ])
        ))
        let clickAutonomous = !autoClick.hasPrefix("ERROR:")
            && clickEvents.count >= 3 && !approvalAsked.isSet
        print("CLICK_AUTONOMOUS=\(clickAutonomous)")
        print("CLICK_APPROVAL_ASKED=\(approvalAsked.isSet)")
        fflush(stdout)

        // === COMPONENT ARM: the window-bounds guard stays INTACT ===========
        // A positive point OUTSIDE the fixture frame: the coordinate parser
        // accepts it, so the refusal must come from the bounds guard itself.
        clickEvents.reset()
        let guarded = await ToolRegistry.execute((
            "ui_click",
            .object(["x": .number(9000), "y": .number(9000)])
        ))
        let guardIntact = guarded.contains("outside every on-screen app window")
            && clickEvents.count == 0
        print("GUARD_INTACT=\(guardIntact)")
        print("GUARD_EVENTS_POSTED=\(clickEvents.count)")
        fflush(stdout)

        // === TYPE AUTONOMY: no card for typing OR the newline send ==========
        clickEvents.reset()
        let typed = await ToolRegistry.execute((
            "ui_type", .object(["text": .string("hi")])
        ))
        let typeAutonomousNoCard = !typed.hasPrefix("ERROR:")
            && allCards.cards.isEmpty
            && clickEvents.count >= 2
        let typedReturn = await ToolRegistry.execute((
            "ui_type", .object(["text": .string("hi\n")])
        ))
        let sendAutonomousNoCard = !typedReturn.hasPrefix("ERROR:")
            && allCards.cards.isEmpty
            && clickEvents.returnCount >= 1
        print("TYPE_AUTONOMOUS_NO_CARD=\(typeAutonomousNoCard)")
        print("TYPE_AUTONOMOUS_EVENTS=\(clickEvents.count)")
        print("SEND_AUTONOMOUS_NO_CARD=\(sendAutonomousNoCard)")
        print("SEND_AUTONOMOUS_RETURNS=\(clickEvents.returnCount)")
        fflush(stdout)

        // === PLAN-EXEC SEND JOURNEY =========================================
        // ONE `plan_update` call carries the WHOLE plan; the executor runs
        // raise -> click -> type+Enter -> read with NO model round between the
        // steps, then COMPOSES THE RECEIPT ITSELF with no final model call.
        // There is no send card. The timeline interleaves the provider calls
        // and the loop's turn-UI events so the ORDER is measured, not assumed.
        TabFocus.scriptRunnerOverride = { _ in .output("FOUND\t1\t2\tFixture tab") }
        log.reset()
        clickEvents.reset()
        let timeline = ProbeTimeline()
        AgentLoop.metrics.reset(at: Date())
        let planAnswer = await runTurn(
            ScriptedWalkthroughProvider(mode: .planExec, timeline: timeline),
            prompt: "send hi on the fixture tab",
            timeline: timeline
        )
        let planNames = log.outcomes.map(\.name)
        let lastType = planNames.lastIndex(of: "ui_type")
        let readAfterSend = lastType.map { planNames[($0 + 1)...].contains("screen_read") } ?? false
        let sentEndToEnd = clickEvents.returnCount >= 1
            && readAfterSend
            && !planAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let planMarksSteps = log.planSnapshots.contains { $0.contains { $0.contains("[~]") } }
            && log.planSnapshots.contains { $0.contains { $0.contains("[x]") } }

        // WORKING_INDICATOR_AT_T0: the FIRST turn-UI event is `working`, and it
        // precedes the first provider call — the panel is not silent while the
        // first model round runs.
        let events = timeline.all
        let firstWorking = events.firstIndex(of: "ui working")
        let firstCall = events.firstIndex { $0.hasPrefix("provider_call") }
        let workingAtT0 = firstWorking != nil && firstCall != nil
            && firstWorking! < firstCall!

        // STEP_MARKS_LIVE: every step of the plan is marked `[~]` and later
        // `[x]` in a snapshot — i.e. the marks land at EXECUTION time, per step.
        let snapshots = log.planSnapshots
        let stepCount = snapshots.last?.count ?? 0
        func stepMarkedLive(_ number: Int) -> Bool {
            let running = snapshots.firstIndex { $0.contains { $0.contains("\(number). [~]") } }
            let done = snapshots.firstIndex { $0.contains { $0.contains("\(number). [x]") } }
            guard let r = running, let d = done else { return false }
            return r < d
        }
        let stepMarksLive = stepCount > 0 && (1...stepCount).allSatisfy(stepMarkedLive)

        // CONFIRMATION_BEFORE_FINAL_MODEL_CALL: the executor-composed receipt
        // renders, and NO provider call follows it. ACTION_TASK_MODEL_CALLS
        // must be 1 (the single planning round) — if a second call happened it
        // would mean the model, not the executor, authored the confirmation.
        let confirmationEvent = events.first { $0.hasPrefix("ui confirmation ") }
        let confirmLine = confirmationEvent
            .map { String($0.dropFirst("ui confirmation ".count)) } ?? ""
        let confirmationPresent = confirmLine.contains("✓ Sent")
        let callsAfterConfirmation = confirmationEvent
            .map { event in
                guard let index = events.firstIndex(of: event) else { return true }
                return events[(index + 1)...].contains { $0.hasPrefix("provider_call") }
            } ?? true
        let confirmationBeforeFinalCall = confirmationPresent && !callsAfterConfirmation
        let actionTaskModelCalls = events.filter { $0.hasPrefix("provider_call") }.count

        print("SENT_END_TO_END=\(sentEndToEnd)")
        print("PLAN_UI_MARKS_STEPS=\(planMarksSteps)")
        print("WORKING_INDICATOR_AT_T0=\(workingAtT0)")
        print("STEP_MARKS_LIVE=\(stepMarksLive)")
        print("CONFIRMATION_BEFORE_FINAL_MODEL_CALL=\(confirmationBeforeFinalCall)")
        print("CONFIRMATION_LINE=\(confirmLine)")
        print("ACTION_TASK_MODEL_CALLS=\(actionTaskModelCalls)")
        print("PLAN_EXEC_TOOLS=\(planNames.joined(separator: ","))")
        print("PLAN_EXEC_ANSWER=\(planAnswer.replacingOccurrences(of: "\n", with: " "))")
        print("EXECUTOR_ROUNDS_BETWEEN_STEPS=\(ToolRegistry.executorModelRoundsBetweenSteps)")
        print("PLAN_EXEC_FM_CALLS=\(AgentLoop.metrics.fmCalls)")
        fflush(stdout)

        // === STEP-FAILURE ARM: a blocked step -> EXACTLY ONE adapt round =====
        // Step 2 is an out-of-bounds click, which the window-bounds guard
        // refuses, so the executor stops there and the model is consulted once.
        log.reset()
        clickEvents.reset()
        AgentLoop.metrics.reset(at: Date())
        let failAnswer = await runTurn(
            ScriptedWalkthroughProvider(mode: .planExecFail),
            prompt: "send hi on the fixture tab"
        )
        let failLower = failAnswer.lowercased()
        let namesBlockedPlanStep = failLower.contains("step 2")
            && failLower.contains("blocked")
        let adaptRounds = AgentLoop.metrics.adaptRounds
        let noEndlessRetry = AgentLoop.metrics.noEndlessRetry
        let failGuardHeld = log.outcomes.contains { $0.name == "ui_click" && !$0.ok }
            && clickEvents.count == 0
        print("PLAN_EXEC_FAIL_NAMES_STEP=\(namesBlockedPlanStep)")
        print("PLAN_EXEC_FAIL_ANSWER=\(failAnswer.replacingOccurrences(of: "\n", with: " "))")
        print("ADAPT_ROUNDS=\(adaptRounds)")
        print("NO_ENDLESS_RETRY=\(noEndlessRetry)")
        print("PLAN_EXEC_FAIL_GUARD_HELD=\(failGuardHeld)")
        fflush(stdout)

        // === COMPONENT ARM: coordinate hygiene =============================
        var commaRejected = false
        do {
            _ = try ToolRegistry.integerArgument(["x": .string("413,349")], "x")
        } catch let failure as ToolFailure {
            commaRejected = failure.message.contains("x=<int> y=<int>")
        } catch {}
        print("COMMA_PAIR_REJECTED=\(commaRejected)")
        let cleanIntsAccepted =
            (try? ToolRegistry.integerArgument(["x": .string("413")], "x")) == 413
            && (try? ToolRegistry.integerArgument(["y": .string("y=349")], "y")) == 349
            && (try? ToolRegistry.integerArgument(["x": .number(413)], "x")) == 413
        print("CLEAN_INTS_ACCEPTED=\(cleanIntsAccepted)")
        let coordLabeled = fixtureLine.rendered.range(
            of: #"x=\d+ y=\d+ w=\d+ h=\d+"#, options: .regularExpression
        ) != nil
        print("COORD_FORMAT_LABELED=\(coordLabeled)")
        fflush(stdout)

        // === COMPONENT ARM: the domain wall is in the shipped guidance =====
        let domainPresent = AppleFMProvider.systemPrompt.contains(ScreenOCR.domainBoundaryClause)
            && AppleFMProvider.systemPrompt.contains(ScreenOCR.raiserPreferenceClause)
        print("DOMAIN_BOUNDARY_PRESENT=\(domainPresent)")
        fflush(stdout)

        // No local action anywhere in this probe may raise a card.
        let anyLocalApprovalCards = !allCards.cards.isEmpty
        ApprovalGate.shared.sink = nativeSink
        print("ANY_LOCAL_APPROVAL_CARDS=\(anyLocalApprovalCards)")

        let gate = walkthroughComplete && honestFail && noDomainCross
            && clickAutonomous && guardIntact
            && typeAutonomousNoCard && sendAutonomousNoCard
            && sentEndToEnd && planMarksSteps
            && workingAtT0 && stepMarksLive
            && confirmationBeforeFinalCall && actionTaskModelCalls == 1
            && adaptRounds == 1 && noEndlessRetry && failGuardHeld
            && !anyLocalApprovalCards
            && commaRejected && cleanIntsAccepted && coordLabeled && domainPresent
        print("WALKTHROUGH_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("WALKTHROUGH_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// Fixtures for the browser probes. Built in a temp dir at probe time, so no
/// probe depends on a checked-in page and nothing is written outside temp.
enum BrowserFixtures {
    static let form = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Checkout</title></head>
    <body>
      <h1>Checkout</h1>
      <p>Pop test checkout form.</p>
      <form id="checkout" onsubmit="return false;">
        <label>Name <input id="name" type="text" name="name" placeholder="Full name"></label>
        <label>Email <input id="email" type="email" name="email" placeholder="you@example.com"></label>
        <label>Plan
          <select id="plan" name="plan">
            <option value="basic">Basic</option>
            <option value="pro">Pro</option>
          </select>
        </label>
        <button type="submit" id="go">Pay now</button>
      </form>
      <p id="result"></p>
      <script>
        document.getElementById('checkout').addEventListener('submit', function (event) {
          event.preventDefault();
          document.getElementById('result').textContent =
            'ORDER CONFIRMED for ' + document.getElementById('email').value;
        });
      </script>
    </body></html>
    """

    static let shop = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>Shop</title></head>
    <body>
      <h1>Products</h1>
      <table>
        <tr><th>name</th><th>price</th><th>rating</th></tr>
        <tr><td>Anvil 5kg</td><td>$49.00</td><td>4.6</td></tr>
        <tr><td>Rocket Skates</td><td>$129.50</td><td>4.8</td></tr>
        <tr><td>Quiet Drill</td><td>$79.99</td><td>4.2</td></tr>
        <tr><td>Loud Kettle</td><td>$34.10</td><td>3.9</td></tr>
        <tr><td>Glass Mouse</td><td>$19.99</td><td>4.4</td></tr>
        <tr><td>Steel Mug</td><td>$12.00</td><td>4.7</td></tr>
      </table>
    </body></html>
    """

    /// Writes both fixtures and returns their URLs. `file://` is what the
    /// BROWSER refuses, so the fixtures are served over loopback instead: a
    /// tiny local HTTP server on 127.0.0.1, bound to a random port, torn down
    /// with the process. No public network is reachable from a probe.
    static func write(into directory: URL) throws -> (form: URL, shop: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formURL = directory.appendingPathComponent("form.html")
        let shopURL = directory.appendingPathComponent("shop.html")
        try form.write(to: formURL, atomically: true, encoding: .utf8)
        try shop.write(to: shopURL, atomically: true, encoding: .utf8)
        return (formURL, shopURL)
    }
}

/// `--test-browser-*`: one probe, one flag, five gates.
///
/// The browser is a real WKWebView driven through `ToolRegistry.execute`, so
/// the mutating calls pass the SAME `ApprovalGate` they would in the app, and
/// the approval is issued by posting the bridge message the Run/Deny button
/// posts.
@MainActor
private func runBrowserProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let root = NSTemporaryDirectory() + "pop-browser-\(UUID().uuidString)"
    setenv("POP_TOOL_ROOT", root, 1)
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )

    let which = CommandLine.arguments
        .first { $0.hasPrefix("--test-browser-") }?
        .replacingOccurrences(of: "--test-browser-", with: "")
    print("BROWSER_PROBE=\(which ?? "unknown")")

    // A loopback HTTP origin: `file://` is refused BY DESIGN (that is the
    // `--test-browser-blocked` gate), so a fixture needs a real scheme. Binding
    // to 127.0.0.1 on a random port means a probe cannot egress.
    let server = FixtureServer(directory: URL(fileURLWithPath: root, isDirectory: true))
    guard let base = server.start() else {
        print("BROWSER_FIXTURE_SERVER_FAILED")
        fflush(stdout)
        exit(1)
    }
    print("BROWSER_FIXTURE_ORIGIN=\(base)")

    Task { @MainActor in
        switch which {
        case "blocked": await runBrowserBlockedProbe()
        case "read": await runBrowserReadProbe(base: base)
        case "form": await runBrowserFormProbe(base: base, decision: "run")
        case "deny": await runBrowserFormProbe(base: base, decision: "deny")
        case "extract": await runBrowserExtractProbe(base: base)
        case "headers": await runBrowserHeadersProbe(base: base)
        case "setcookie": await runBrowserSetCookieProbe(base: base)
        case "cookiecheck": await runBrowserCookieCheckProbe(base: base)
        default:
            print("BROWSER_PROBE_UNKNOWN")
            exit(1)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
        print("BROWSER_PROBE_TIMEOUT probe=\(which ?? "?")")
        exit(1)
    }

    NSApp.run()
}

/// `--test-screen-ocr` — the screen-read pipeline, measured on a REAL window.
///
/// MEASURED CONSTRAINT, STATED UP FRONT: the requested marker-window arm CANNOT
/// pass on this platform, and the probe reports that rather than faking it.
/// ScreenCaptureKit does not enumerate the CAPTURING app's own windows — the
/// probe's own 900x432 panel reported `visible=true` yet was absent from
/// `SCShareableContent`'s window list — and the one API that can photograph an
/// arbitrary window id, `CGWindowListCreateImage`, is HARD-UNAVAILABLE on this
/// SDK ("Please use ScreenCaptureKit instead"), so it will not even compile.
/// A window Pop owns therefore cannot be its own OCR subject.
///
/// So the marker arm is printed as evidence and left FALSE, and the gate is
/// built on what is honestly measurable: the SHIPPED path — window-scoped
/// capture of the frontmost allowlisted browser, Vision recognition, and an
/// honest failure when no such window exists. Both are real measurements against
/// the user's real screen.
@MainActor
private func runScreenOCRProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    /// The literal the marker arm looks for. A literal, never a generated
    /// expectation: a probe that invented its own string could agree with itself
    /// while OCR returned nothing.
    let marker = "PopOCR_GATE_MARKER_9173"

    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    panel.title = "Pop OCR probe window"
    let label = NSTextField(labelWithString: marker)
    label.font = .monospacedSystemFont(ofSize: 48, weight: .bold)
    label.textColor = .black
    label.backgroundColor = .white
    label.frame = NSRect(x: 40, y: 160, width: 820, height: 80)
    label.isBezeled = false
    panel.contentView = NSView(frame: panel.contentLayoutRect)
    panel.contentView?.addSubview(label)
    panel.center()
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        Task { @MainActor in
            // --- THE MARKER ARM: scoped to this process's own window. Reported,
            // never gated — see the note above on why it cannot succeed.
            let own = await ScreenOCR.read(
                bundleIDs: [Bundle.main.bundleIdentifier ?? "com.pop.app"],
                titleHint: panel.title
            )
            let ownText = own.windows.map(\.text).joined(separator: "\n")
            print("SCREEN_OCR_OWN_WINDOW_VISIBLE=\(panel.isVisible)")
            print("SCREEN_OCR_OWN_WINDOW_FOUND=\(own.succeeded)")
            print("SCREEN_OCR_TEXT_FOUND=\(own.succeeded && ownText.contains(marker))")
            fflush(stdout)

            // --- THE SHIPPED PATH, ALL WINDOWS: every on-screen allowlisted
            // browser window, front to back. The measured defect this covers:
            // the user's content was in a background window of the same browser
            // and Pop read only the frontmost one. `scope:"all"` is still that
            // capability; it is no longer the DEFAULT.
            let started = Date()
            let reading = await ScreenOCR.read(scope: .all)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print("SCREEN_OCR_MS=\(elapsed)")
            print("SCREEN_OCR_WINDOWS_RETURNED=\(reading.windows.count)")
            print("SCREEN_OCR_WINDOWS_SKIPPED=\(reading.skippedEmpty)")
            print("SCREEN_OCR_TRUNCATED_AT_CAP=\(reading.truncatedAtCap)")
            for window in reading.windows {
                print("SCREEN_OCR_WINDOW[\(window.order)] app=\(window.appName) title=\(window.windowTitle) chars=\(window.text.count)")
            }
            // Front-to-back is asserted as MONOTONIC ORDER over the returned
            // list, which is the order `SCShareableContent` enumerated the
            // windows in. Nothing here re-sorts by area or by title.
            let orders = reading.windows.map(\.order)
            let orderFrontToBack = orders == orders.sorted() && orders.count == Set(orders).count
            print("SCREEN_OCR_ORDER_FRONT_TO_BACK=\(orderFrontToBack)")
            print("SCREEN_OCR_TOTAL_TEXT_CHARS=\(reading.windows.reduce(0) { $0 + $1.text.count })")
            print("SCREEN_OCR_CAPPED_AT=\(ScreenOCR.textCap)")
            print("SCREEN_OCR_TOTAL_CAPPED_AT=\(ScreenOCR.totalTextCap)")
            print("SCREEN_OCR_FAILURE=\(reading.failure.isEmpty ? "none" : reading.failure)")

            // --- THE PAYLOAD DIET, front vs all, on the SAME screen. The default
            // scope must cost strictly less than the full read, or the diet is
            // not a diet. Measured from the model-facing payload, not the raw
            // OCR.
            let frontReading = await ScreenOCR.read(scope: .front)
            let frontPayload = ScreenOCR.modelFacingText(frontReading)
            let allPayload = ScreenOCR.modelFacingText(reading)
            let frontBytes = frontPayload.utf8.count
            let allBytes = allPayload.utf8.count
            print("PAYLOAD_FRONT_BYTES=\(frontBytes)")
            print("PAYLOAD_ALL_BYTES=\(allBytes)")
            print("FRONT_OTHER_WINDOWS=\(frontReading.otherWindows.count)")
            let payloadStrictlySmaller = frontBytes < allBytes
            print("PAYLOAD_FRONT_SMALLER=\(payloadStrictlySmaller)")
            // Window-scoped is asserted from the SELECTION, not from a flag: the
            // capture filter is that window alone, so every app it named must be
            // an allowlisted browser, every title must be non-empty, and every
            // window must have produced text.
            let pipelineOK = reading.succeeded
                && reading.windows.count >= 1
                && reading.windows.allSatisfy { $0.text.count > 0 && !$0.windowTitle.isEmpty }
                && orderFrontToBack
            print("SCREEN_OCR_WINDOW_SCOPED=\(reading.windowScoped)")
            fflush(stdout)

            // --- LINE COORDINATES: every recognized line must carry the LABELED
            // `@ x=… y=… w=… h=…` geometry and that rectangle must sit INSIDE its
            // window's frame, or a click computed from it would land somewhere
            // else. Sampled over the real shipped read, not a fixture.
            var samples: [String] = []
            var coordsInside = true
            for window in reading.windows {
                for line in window.lines {
                    let centre = CGPoint(x: line.rect.midX, y: line.rect.midY)
                    let inside = window.frame.insetBy(dx: -1, dy: -1).contains(centre)
                    if !inside { coordsInside = false }
                    if samples.count < 3 {
                        samples.append(
                            "line=\"\(line.text.prefix(28))\" coords="
                                + "x=\(Int(line.rect.origin.x)) y=\(Int(line.rect.origin.y)) "
                                + "w=\(Int(line.rect.width)) h=\(Int(line.rect.height)) "
                                + "frame=\(window.boundsText) inside=\(inside)"
                        )
                    }
                }
            }
            let totalLines = reading.windows.reduce(0) { $0 + $1.lines.count }
            // The shipped payload must match `x=<int> y=<int> w=<int> h=<int>` on
            // every line, and must contain NO comma-joined number pair.
            let coordRegex = try! NSRegularExpression(
                pattern: #"x=\d+ y=\d+ w=\d+ h=\d+"#
            )
            func hasLabeledCoords(_ text: String) -> Bool {
                let range = NSRange(text.startIndex..., in: text)
                return coordRegex.firstMatch(in: text, range: range) != nil
            }
            let coordFormatLabeled = totalLines > 0
                && reading.windows.contains { window in
                    window.lines.allSatisfy { hasLabeledCoords($0.rendered) }
                }
            let lineCoordsPresent = totalLines > 0
                && reading.windows.allSatisfy { window in
                    window.lines.allSatisfy {
                        window.text.contains("@ x=\(Int($0.rect.origin.x)) y=\(Int($0.rect.origin.y)) ")
                    }
                }
            for (index, sample) in samples.enumerated() {
                print("SCREEN_OCR_SAMPLE[\(index)] \(sample)")
            }
            print("SCREEN_OCR_TOTAL_LINES=\(totalLines)")
            print("COORD_FORMAT_LABELED=\(coordFormatLabeled)")
            print("LINE_COORDS_PRESENT=\(lineCoordsPresent)")
            print("COORDS_INSIDE_WINDOW=\(coordsInside && !samples.isEmpty)")
            fflush(stdout)

            // --- THE HONEST FAILURE: same pipeline, impossible window owner.
            let denied = await ScreenOCR.read(
                bundleIDs: ["com.pop.ocr-probe.no-such-app"],
                titleHint: "no-such-window-title-9173"
            )
            // The load-bearing part is that no window came back: a failure that
            // carried windows with text would be a fabricated answer about the
            // user's screen.
            let honestFail = !denied.succeeded && denied.windows.isEmpty
                && denied.failure.contains("no browser window is on screen")
            print("SCREEN_OCR_HONEST_FAIL=\(honestFail)")
            print("SCREEN_OCR_HONEST_FAIL_REASON=\(denied.failure)")
            // The model-facing wrapper must not launder a failure into prose that
            // reads like an answer.
            let payload = ScreenOCR.modelFacingText(denied)
            let typed = payload.hasPrefix("SCREEN READ FAILED")
            print("SCREEN_OCR_FAILURE_PAYLOAD_IS_TYPED=\(typed)")

            // --- THE FAILURE REASON: an empty read must carry WHY in the
            // payload itself, not only in a side channel. The counts name the
            // total windows seen, the allowlisted-browser windows, and the
            // skipped empty OCR, so the next empty read is diagnosable.
            let reasonLogged = denied.failure.contains("total_windows=")
                && denied.failure.contains("allowlisted_browser_windows=")
                && denied.failure.contains("candidate_windows=")
                && denied.failure.contains("skipped_empty_ocr=")
            print("SCREEN_FAIL_REASON_LOGGED=\(reasonLogged)")
            print("SCREEN_FAIL_REASON_LINE=\(denied.failure.replacingOccurrences(of: "\n", with: " "))")

            // --- THE DIET: dropped and collapsed, measured. The live OCR may
            // not contain a repeated line, so the dedupe arm drives the shipped
            // diet function through a canned line list — the seam.
            let canned: [ScreenOCR.RecognizedLine] = [
                ScreenOCR.RecognizedLine(text: "Inbox", rect: CGRect(x: 10, y: 10, width: 40, height: 12)),
                ScreenOCR.RecognizedLine(text: "Inbox", rect: CGRect(x: 10, y: 30, width: 40, height: 12)),
                ScreenOCR.RecognizedLine(text: "", rect: CGRect(x: 10, y: 50, width: 1, height: 1)),
                ScreenOCR.RecognizedLine(text: "< >", rect: CGRect(x: 10, y: 60, width: 10, height: 8)),
                ScreenOCR.RecognizedLine(text: "Body", rect: CGRect(x: 10, y: 80, width: 40, height: 12))
            ]
            let dieted = ScreenOCR.diet(canned)
            let dedupeCollapsed = dieted.collapsed == 1
                && dieted.dropped == 2
                && dieted.kept.count == 2
                && dieted.kept[0].text == "Inbox"
                && dieted.kept[0].rect.origin.y == 30
                && dieted.kept[1].text == "Body"
            print("DEDUPE_COLLAPSED=\(dedupeCollapsed)")
            print("DIET_KEPT=\(dieted.kept.map(\.text).joined(separator: "|")) DROPPED=\(dieted.dropped) COLLAPSED=\(dieted.collapsed)")
            print("LIVE_DROPPED=\(reading.droppedLines) LIVE_COLLAPSED=\(reading.collapsedLines)")
            fflush(stdout)

            // --- THE TITLES-ONLY HEADER: the ≤300-byte header lists other
            // window titles and nothing else. Measured through the shipped
            // renderer on a canned window list, so it does not depend on how
            // many browser windows happen to be open.
            let cannedOthers = [
                ScreenOCR.OtherWindow(order: 1, appName: "Brave", windowTitle: "Inbox — Mail"),
                ScreenOCR.OtherWindow(order: 2, appName: "Safari", windowTitle: "Docs")
            ]
            let header = ScreenOCR.otherWindowsHeader(cannedOthers) ?? ""
            let headerPresent = header.contains("Inbox — Mail")
                && header.contains("Docs")
                && header.utf8.count <= 300
            print("OTHER_TITLES_HEADER_PRESENT=\(headerPresent)")
            print("OTHER_TITLES_HEADER_BYTES=\(header.utf8.count)")
            print("OTHER_TITLES_HEADER=\(header)")
            fflush(stdout)

            // --- THE REGION ARM: a rect fully inside the front window returns
            // only lines inside it; a rect outside -> honest failure.
            var regionFiltered = false
            var regionOutsideHonestFail = false
            if let front = reading.frontmost {
                let inner = front.frame.insetBy(dx: 2, dy: 2)
                let regionReading = await ScreenOCR.read(scope: .region(inner))
                let allInside = regionReading.windows.allSatisfy { window in
                    window.lines.allSatisfy {
                        inner.insetBy(dx: -1, dy: -1).contains(
                            CGPoint(x: $0.rect.midX, y: $0.rect.midY)
                        )
                    }
                }
                regionFiltered = regionReading.succeeded && !regionReading.windows.isEmpty && allInside
                print("REGION_LINES=\(regionReading.windows.reduce(0) { $0 + $1.lines.count })")
                let outside = CGRect(
                    x: front.frame.maxX + 5000,
                    y: front.frame.maxY + 5000,
                    width: 100,
                    height: 100
                )
                let outsideReading = await ScreenOCR.read(scope: .region(outside))
                regionOutsideHonestFail = !outsideReading.succeeded
                    && outsideReading.windows.isEmpty
                print("REGION_OUTSIDE_HONEST_FAIL=\(regionOutsideHonestFail)")
            }
            print("REGION_FILTERED=\(regionFiltered)")
            fflush(stdout)

            // --- THE ONE PRINCIPLE: asserted from the system prompt text Pop
            // actually sends, the same seam the honesty rules use. Both
            // transports share `AppleFMProvider.systemPrompt`. The old
            // screen-first and failure-stop phrasings are gone; the principle
            // replaced them, so their absence is asserted too. The DOMAIN WALL is
            // its own clause/arm.
            let guidance = AppleFMProvider.systemPrompt
            print("ROUTE_RULE_PRESENT=\(guidance.contains(ScreenOCR.routingPrinciple))")
            print("FAILURE_STOP_RULE_ABSENT=\(!guidance.contains("FAILURE-STOP"))")
            print("ACT_ON_VISIBLE_RULE_PRESENT=\(guidance.contains(ScreenOCR.actOnVisibleRule))")
            let domainBoundaryPresent = guidance.contains(ScreenOCR.domainBoundaryClause)
                && guidance.contains(ScreenOCR.raiserPreferenceClause)
            print("DOMAIN_BOUNDARY_PRESENT=\(domainBoundaryPresent)")
            fflush(stdout)

            let gate = pipelineOK && honestFail && typed
                && coordFormatLabeled && lineCoordsPresent && coordsInside
                && payloadStrictlySmaller && dedupeCollapsed && headerPresent
                && regionFiltered && regionOutsideHonestFail
                && domainBoundaryPresent
            print("SCREEN_OCR_GATE=\(gate)")
            fflush(stdout)
            exit(gate ? 0 : 1)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        print("SCREEN_OCR_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-front-order [query]` — LIVE evidence for the "stale front window"
/// defect, on the real screen, no model.
///
/// MEASUREMENT 1 compares the TRUE z-order (`CGWindowListCopyWindowInfo`, which
/// the window server returns front to back) against the order
/// `SCShareableContent` enumerates windows in. The shipped `screen_read` picks
/// `candidates[0]` and calls it "frontmost", so if the first browser candidate is
/// NOT the z-order frontmost browser window, every read can return a window that
/// is merely first by enumeration — exactly the stale read seen after a raise.
///
/// MEASUREMENT 2 (when a query is given) runs the live chain: raise a NON-matching
/// browser window, raise the query's window, then re-read `front` at 0/500/1000/
/// 2000 ms and print which delay first sees the raised window. It measures the
/// fix; it never assumes it.
@MainActor
private func runFrontOrderProbe(query: String?) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    func cgFrontToBack() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            let number = entry[kCGWindowNumber as String] as? Int ?? 0
            return number == 0 ? nil : CGWindowID(number)
        }
    }

    func browserCandidates(_ content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            ScreenOCR.browserBundleIDs.contains($0.owningApplication?.bundleIdentifier ?? "")
                && $0.frame.width > 40 && $0.frame.height > 40
        }
    }

    func focusTitle(_ result: String) -> String {
        guard let open = result.range(of: "— \""),
              let close = result[open.upperBound...].range(of: "\" in ")
        else { return "" }
        return String(result[open.upperBound..<close.lowerBound])
    }

    Task { @MainActor in
        // === MEASUREMENT 1: enumeration order vs true z-order ==============
        let enumStart = Date()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else {
            print("FRONT_ORDER_ENUM_FAILED")
            fflush(stdout)
            exit(1)
        }
        let enumMS = Int(Date().timeIntervalSince(enumStart) * 1000)
        let cands = browserCandidates(content)
        let ids = Set(cands.map(\.windowID))
        let cg = cgFrontToBack()
        let cgFrontBrowser = cg.first { ids.contains($0) }
        print("FRONT_ORDER_ENUM_MS=\(enumMS)")
        print("FRONT_ORDER_TOTAL_WINDOWS=\(content.windows.count)")
        print("FRONT_ORDER_BROWSER_CANDIDATES=\(cands.count)")
        for (index, window) in cands.enumerated() {
            print("FRONT_ORDER_SC[\(index)] id=\(window.windowID) title=\(window.title ?? "")")
        }
        print("FRONT_ORDER_CG_ORDER_COUNT=\(cg.count)")
        print("FRONT_ORDER_SC_FIRST=\(cands.first?.windowID ?? 0)")
        print("FRONT_ORDER_CG_FIRST_BROWSER=\(cgFrontBrowser ?? 0)")
        print("FRONT_ORDER_FIRST_MATCHES_CG=\(cands.first.map { $0.windowID == cgFrontBrowser } ?? false)")
        fflush(stdout)

        guard let query, !query.isEmpty, !cands.isEmpty else {
            print("FRONT_ORDER_CHAIN=skipped-no-query")
            fflush(stdout)
            exit(0)
        }

        // === MEASUREMENT 2: the live raise -> read chain ==================
        // Raise a NON-matching browser window first, so the front is stale the
        // way the user's log shows (a different window of the same browser). The
        // match fragment drops the display ellipsis: `focus` matches the tab's
        // real title, which does not contain "…".
        let lowered = query.lowercased()
        let other = cands.first {
            !($0.title ?? "").lowercased().contains(lowered) && !($0.title ?? "").isEmpty
        }
        if let other, let rawTitle = other.title,
           let bundle = other.owningApplication?.bundleIdentifier {
            let fragment = rawTitle.components(separatedBy: "…").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? rawTitle
            let raisedOther = await TabFocus.focus(query: fragment, browser: bundle)
            print("FRONT_ORDER_RAISED_OTHER=\(raisedOther.replacingOccurrences(of: "\n", with: " "))")
            try? await Task.sleep(for: .milliseconds(400))
            let check = await ScreenOCR.read(scope: .front)
            let title = check.windows.first?.windowTitle ?? "none"
            print("FRONT_ORDER_AFTER_OTHER title=\(title) "
                + "isTarget=\(title.lowercased().contains(lowered))")
        } else {
            print("FRONT_ORDER_RAISED_OTHER=no-non-matching-window")
        }

        // Raise the TARGET window and read immediately, then after settles.
        let target = await TabFocus.focus(query: query, browser: other?.owningApplication?.bundleIdentifier)
        let targetTitle = focusTitle(target)
        print("FRONT_ORDER_FOCUS_RESULT=\(target.replacingOccurrences(of: "\n", with: " "))")
        print("FRONT_ORDER_TARGET_TITLE=\(targetTitle)")
        fflush(stdout)

        func seesTarget(_ title: String) -> Bool {
            let lower = title.lowercased()
            if lower.contains(lowered) { return true }
            if !targetTitle.isEmpty {
                return lower.contains(targetTitle.lowercased())
                    || targetTitle.lowercased().contains(lower)
            }
            return false
        }

        var firstSeen: Int?
        var previous = 0
        for delay in [0, 500, 1000, 2000] {
            if delay > previous {
                try? await Task.sleep(for: .milliseconds(delay - previous))
                previous = delay
            }
            let read = await ScreenOCR.read(scope: .front)
            let title = read.windows.first?.windowTitle ?? "none"
            let ok = seesTarget(title)
            if ok, firstSeen == nil { firstSeen = delay }
            print("FRONT_ORDER_READ delay=\(delay)ms title=\(title) seesTarget=\(ok)")
            if ok {
                for line in read.windows.first?.lines.prefix(3) ?? [] {
                    print("FRONT_ORDER_SAMPLE=\("\(line.text.prefix(48))")")
                }
            }
            fflush(stdout)
        }
        print("FRONT_ORDER_FIRST_SEES_TARGET_MS=\(firstSeen.map(String.init) ?? "never")")
        print("FRONT_ORDER_STALE_FRONT_FIXED=\(firstSeen != nil)")
        fflush(stdout)
        exit(0)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("FRONT_ORDER_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-first-turn-latency` — the user's "the first message is slower"
/// complaint, in numbers.
///
/// THE MEASUREMENT IS A PAIR, IN ONE PROCESS, AGAINST THE SAME STORE:
///  * the FIRST `WebLookup.run` of the process is the cold turn — it pays the
///    session warm inside itself (`WARM_MS` proves it did);
///  * the launch pre-warm entry point (`LaunchPrewarm.warmWeb`, the very call
///    `LaunchPrewarm.start` makes) is then invoked, and the NEXT lookup is the
///    warmed turn. Its warm is skipped by the existing per-process gate, which
///    is what `WARM_INSIDE_LOOKUP_SKIPPED` asserts — measured from
///    `WebLookup.warmRunCount`, not from the log's wording.
///
/// No threshold is invented: the gate is strictly `warmed < cold` AND the warm
/// was skipped. If the store is already warm before this probe starts (a
/// returning user), the pair cannot show a difference and the gate says so
/// rather than passing on a coincidence.
///
/// `FM_PREWARM` is measured through the provider seam: the pre-warm's own
/// generation runs, then a REAL provider call, and the seam asserts the real
/// call built its session with init already behind it.
///
/// Probes never reach the real support root (`--test-*` already redirects the
/// session/transcript paths) and the pre-warm is disabled for probes at launch,
/// so nothing here pre-warms behind the measurement's back.
@MainActor
private func runFirstTurnLatencyProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    // Explicit: this run must measure what it says it measures, so nothing may
    // pre-warm it behind the numbers.
    setenv("POP_PREWARM", "0", 1)

    let query = ProcessInfo.processInfo.environment["POP_LATENCY_QUERY"] ?? "weather tomorrow"

    Task { @MainActor in
        // --- COLD: the first lookup of this process pays the warm itself.
        let warmRunsBefore = WebLookup.warmRunCount
        let coldStarted = Date()
        let cold = await WebLookup.run(query: query)
        let coldMs = Int(Date().timeIntervalSince(coldStarted) * 1000)
        let warmRanInside = WebLookup.warmRunCount > warmRunsBefore
        print("COLD_FIRST_TURN_MS=\(coldMs)")
        print("COLD_WARM_RAN_INSIDE_LOOKUP=\(warmRanInside)")
        print("COLD_WARM_RUNS=\(WebLookup.warmRunCount)")
        print("COLD_ANSWER_CHARS=\(cold.answerExcerpt.count)")
        fflush(stdout)

        // --- THE LAUNCH PRE-WARM PATH, invoked exactly as launch invokes it.
        await LaunchPrewarm.warmWeb()
        let runsAfterPrewarm = WebLookup.warmRunCount
        print("WARM_RUNS_AFTER_PREWARM=\(runsAfterPrewarm)")
        fflush(stdout)

        // --- WARMED: the next lookup must NOT warm again.
        let warmStarted = Date()
        let warmed = await WebLookup.run(query: query)
        let warmedMs = Int(Date().timeIntervalSince(warmStarted) * 1000)
        let warmSkipped = WebLookup.warmRunCount == runsAfterPrewarm
        print("WARMED_FIRST_TURN_MS=\(warmedMs)")
        print("WARM_INSIDE_LOOKUP_SKIPPED=\(warmSkipped)")
        print("WARMED_WARM_RUNS=\(WebLookup.warmRunCount)")
        print("WARMED_ANSWER_CHARS=\(warmed.answerExcerpt.count)")
        fflush(stdout)
        let prewarmEffective = warmedMs < coldMs && warmSkipped
        print("PREWARM_EFFECTIVE=\(prewarmEffective)")
        fflush(stdout)

        // --- FM: the model half, measured through the provider seam.
        await LaunchPrewarm.warmModel(pcc: false)
        do {
            let provider = AppleFMProvider(pcc: false)
            if provider.isHealthy {
                _ = try await provider.collectText(
                    messages: [ChatMessage(role: .user, text: "hi")],
                    options: GenerationOptions(temperature: 0)
                )
            }
        } catch {
            print("FM_PREWARM_CALL_FAILED \(error)")
        }
        let fmPrewarm = ProviderTestSeams.shared.fmPrewarmEffective
        print("FM_PREWARM=\(fmPrewarm)")
        fflush(stdout)

        let gate = prewarmEffective && fmPrewarm
        print("LATENCY_GATE=\(gate)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
        print("LATENCY_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-scroll-cue` — the "scroll for more" bar is GONE, by user decision.
///
/// Checked three ways, because each alone is defeatable: the element must not
/// EXIST (`getElementById`), the rendered text must not CONTAIN the phrase or a
/// literal `\\u2193` (the old bug: `index.html` is not a Swift string, so the
/// escape was never decoded and the backslashes showed on screen), and the
/// NO RENDERED ELEMENT may contain the escape either — a text-only scan of
/// `document.body` would pass even with the cue present but `display:none`.
/// Scanned over rendered elements, not over the serialised HTML: `script` and
/// `style` are excluded because this file's own COMMENT about the removed cue
/// legitimately mentions the escape, and that text is source, not display.
@MainActor
private func runScrollCueProbe(panelController: PanelController) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    panelController.show()

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        let js = "(function(){"
            + "var cue=document.getElementById('scrollCue');"
            + "var t=document.body?document.body.innerText:'';"
            + "var html=document.documentElement?document.documentElement.outerHTML:'';"
            + "return [cue?'present':'absent',"
            + "t.indexOf('scroll for more')!==-1?'yes':'no',"
            + "t.indexOf('\\\\u2193')!==-1?'yes':'no',"
            + "Array.prototype.some.call(document.querySelectorAll('body *'),"
            + "function(e){if(e.tagName==='SCRIPT'||e.tagName==='STYLE'){return false;}"
            + "return (e.innerText||'').indexOf('\\\\u2193')!==-1;})?'yes':'no',"
            + "t.indexOf('\\\\u21E3')!==-1?'yes':'no'"
            + "].join('|');})()"
        panelController.appWebView.webView.evaluateJavaScript(js) { value, error in
            if let error {
                print("SCROLL_CUE_JS_ERROR=\(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            let parts = ((value as? String) ?? "")
                .split(separator: "|", maxSplits: 4).map(String.init)
            func flag(_ index: Int) -> String { index < parts.count ? parts[index] : "unknown" }
            let elementAbsent = flag(0) == "absent"
            let textClean = flag(1) == "no" && flag(2) == "no"
            let htmlClean = flag(3) == "no" && flag(4) == "no"
            print("SCROLL_CUE_ELEMENT=\(flag(0))")
            print("SCROLL_CUE_TEXT_PRESENT=\(flag(1))")
            print("SCROLL_CUE_LITERAL_ESCAPE_IN_TEXT=\(flag(2))")
            print("SCROLL_CUE_LITERAL_ESCAPE_IN_ANY_ELEMENT=\(flag(3))")
            print("SCROLL_CUE_UP_ARROW_ESCAPE_IN_TEXT=\(flag(4))")
            let removed = elementAbsent && textClean && htmlClean
            print("SCROLL_CUE_REMOVED=\(removed)")
            fflush(stdout)
            exit(removed ? 0 : 1)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("SCROLL_CUE_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-settings-row-refresh` — the row the user saw stuck on "Sign in…"
/// after signing in successfully.
///
/// The failure was a stale SWIFTUI state, not a stale store: the store held the
/// session cookies and the row still said signed-out, because the only thing
/// that re-read the form was `SettingsWindowController.show()` and the user
/// never closed and reopened Settings. Closing the sign-in window is the moment
/// the state can have changed, so that is where the form is now re-read.
///
/// Therefore `show()` is called ONCE, here, and never again: the gate is
/// whether the row of a STILL-VISIBLE window flips on its own.
///
/// Cookies are planted by NAME only — no value is read, logged or asserted, and
/// the value written is a literal placeholder. The surface itself is pointed at
/// this run's own loopback fixture, so no test ever loads an account page.
@MainActor
private func runSettingsRowRefreshProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let root = NSTemporaryDirectory() + "pop-row-refresh-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )
    let server = FixtureServer(directory: URL(fileURLWithPath: root, isDirectory: true))
    guard let base = server.start() else {
        print("ROW_FIXTURE_SERVER_FAILED")
        fflush(stdout)
        exit(1)
    }
    print("ROW_FIXTURE_ORIGIN=\(base)")
    fflush(stdout)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        Task { @MainActor in
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .seconds(2))
            let before = accessibilityLabels(of: SettingsWindowController.shared.windowForProbe)
            let signedOutBefore = before.contains("Sign in\u{2026}")
            print("ROW_LABELS_BEFORE=\(before.joined(separator: " | "))")
            print("ROW_SIGNED_OUT_BEFORE=\(signedOutBefore)")
            fflush(stdout)

            // The session, as a cookie NAME on the account domain in the shared
            // store — the very store the sign-in window's view runs on. Names
            // from `GoogleSignIn.sessionCookieNames`, so the probe cannot pass by
            // planting something the real check ignores.
            let cookieStore = BrowserController.shared.webView
                .configuration.websiteDataStore.httpCookieStore
            for name in GoogleSignIn.sessionCookieNames.sorted() {
                if let cookie = HTTPCookie(properties: [
                    .domain: ".google.com",
                    .path: "/",
                    .name: name,
                    .value: "probe-not-a-credential"
                ]) {
                    await cookieStore.setCookie(cookie)
                }
            }
            let stateAfterPlant = await GoogleSignIn.state()
            print("ROW_STORE_AFTER_PLANT=\(stateAfterPlant)")
            fflush(stdout)

            // Open the REAL surface on the loopback fixture and then close it,
            // which is the user path and the trigger under test.
            setenv("POP_SIGNIN_URL", base + "/echo-headers", 1)
            await GoogleSignInWindowController.shared.signIn()
            try? await Task.sleep(for: .seconds(2))
            GoogleSignInWindowController.shared.closeSignInSurface()
            try? await Task.sleep(for: .seconds(3))

            // NO `show()` HERE. The window has to be the one already open.
            let settings = SettingsWindowController.shared.windowForProbe
            let stillVisible = settings?.isVisible == true
            let after = accessibilityLabels(of: settings)
            let flipped = after.contains("Sign out")
            print("ROW_SETTINGS_STILL_VISIBLE=\(stillVisible)")
            print("ROW_LABELS_AFTER=\(after.joined(separator: " | "))")
            print("ROW_FLIPPED_WITHOUT_RESHOW=\(flipped)")
            fflush(stdout)
            let liveRefresh = signedOutBefore && stillVisible && flipped
                && stateAfterPlant == "signed-in"
            print("SETTINGS_ROW_LIVE_REFRESH=\(liveRefresh)")
            fflush(stdout)

            // And back the other way, again with no re-show: `signOut()` clears
            // the account's cookies and bumps the generation itself.
            await GoogleSignInWindowController.shared.signOut()
            try? await Task.sleep(for: .seconds(3))
            let stateAfterSignOut = await GoogleSignIn.state()
            let signedOutAgain = accessibilityLabels(
                of: SettingsWindowController.shared.windowForProbe
            ).contains("Sign in\u{2026}")
            print("ROW_STORE_AFTER_SIGNOUT=\(stateAfterSignOut)")
            print("ROW_SIGNED_OUT_AGAIN=\(signedOutAgain)")
            let signoutRefresh = liveRefresh && signedOutAgain
                && stateAfterSignOut == "signed-out"
            print("SETTINGS_ROW_SIGNOUT_REFRESH=\(signoutRefresh)")
            fflush(stdout)
            let gate = liveRefresh && signoutRefresh
            print("ROW_REFRESH_GATE=\(gate)")
            fflush(stdout)
            exit(gate ? 0 : 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("ROW_REFRESH_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-settings-reopen` — the "I closed Settings and can never reopen it"
/// bug, measured on the LIVE window object.
///
/// Root cause it guards: `makeWindow()` left `isReleasedWhenClosed` at the
/// AppKit default of `true`, so the close button released the window while
/// `SettingsWindowController.shared.window` still cached it. Every later
/// `show()` handed that dead window back and `makeKeyAndOrderFront` did
/// nothing. A probe that only SHOWED the window would pass against exactly
/// that bug, so this one drives the full round trip and then asks the window
/// object whether it is still alive.
///
/// `weak` is the load-bearing part: a released window is a dangling pointer
/// whose `isVisible` can read anything. Only the weak reference surviving the
/// close proves the object was not freed. Closing must remain "hide, then
/// reuse" — the probe never changes app termination.
@MainActor
private func runSettingsReopenProbe() {
    let application = NSApplication.shared
    // `.regular`, not `.accessory`: only a regular app is allowed to become
    // the KEY app in a session, and `isKeyWindow` is part of this gate — the
    // settings form is the one window that must be key (it hosts SecureFields).
    application.setActivationPolicy(.regular)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        Task { @MainActor in
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .milliseconds(800))
            guard let first = SettingsWindowController.shared.windowForProbe else {
                print("SETTINGS_WINDOW_MISSING")
                fflush(stdout)
                exit(1)
            }
            weak let weakWindow = first
            let shownFirst = first.isVisible
            // Read the flag off the LIVE object, not off what we believe the
            // constructor was told.
            let notReleased = !first.isReleasedWhenClosed
            print("RELEASED_WHEN_CLOSED=\(first.isReleasedWhenClosed)")
            print("SETTINGS_FIRST_SHOW_VISIBLE=\(shownFirst)")
            fflush(stdout)

            first.performClose(nil)
            try? await Task.sleep(for: .milliseconds(600))
            let hidden = !first.isVisible
            // The object must have survived the close. Reading `first` again is
            // safe either way for our own use; the liveness proof is `weakWindow`.
            let alive = weakWindow != nil
            print("SETTINGS_AFTER_CLOSE_VISIBLE=\(first.isVisible)")
            print("SETTINGS_SURVIVED_CLOSE=\(alive)")
            fflush(stdout)

            application.activate(ignoringOtherApps: true)
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .seconds(2))
            let reopened = SettingsWindowController.shared.windowForProbe
            let sameObject = reopened === first
            let labels = accessibilityLabels(of: reopened)
            // The rows must be REAL: an empty window that merely orders front
            // would satisfy every visibility check above. The gate is the
            // CONTROL-bearing rows — SwiftUI does not publish its static
            // headings (e.g. the "Provider" text) through `accessibilityLabel`,
            // so the account control plus the header controls are what can be
            // measured. The full label list is printed above so a drift is
            // visible rather than silent.
            let hasAccountRow = labels.contains("Sign in\u{2026}") || labels.contains("Sign out")
            let hasHeaderControls = labels.contains("Save") && labels.contains("Grant\u{2026}")
            print("SETTINGS_HAS_PROVIDER_HEADING=\(labels.contains("Provider"))")
            print("SETTINGS_SAME_WINDOW_AFTER_REOPEN=\(sameObject)")
            print("SETTINGS_REOPEN_LABELS=\(labels.joined(separator: " | "))")
            fflush(stdout)

            // The flag is part of the gate, not just a printout: with it left
            // at the AppKit default the round trip still LOOKS fine in-process
            // (the controller's strong reference keeps the object alive) while
            // the released window no longer orders front for the user. Measured
            // without the fix: RELEASED_WHEN_CLOSED=true and this probe fails.
            let gate = notReleased && shownFirst && hidden && alive && sameObject
                && reopened?.isVisible == true && reopened?.isKeyWindow == true
                && hasAccountRow && hasHeaderControls && labels.count >= 4
            print("NSAPP_IS_ACTIVE=\(application.isActive)")
            print("SETTINGS_REOPEN_VISIBLE=\(reopened?.isVisible == true)")
            print("SETTINGS_REOPEN_KEY=\(reopened?.isKeyWindow == true)")
            print("SETTINGS_REOPEN=\(gate)")
            fflush(stdout)
            exit(gate ? 0 : 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        print("SETTINGS_REOPEN_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

@MainActor
private func finishBrowserProbe(_ name: String, _ gate: Bool, extra: () -> Void = {}) {
    extra()
    print("BROWSER_GATE=\(gate)")
    fflush(stdout)
    exit(gate ? 0 : 1)
}

/// `--test-google-signin`: the SETTINGS account control, the surface it opens,
/// and the STORE the session lands in.
///
/// Everything is measured and no credential is involved:
///  1. `SETTINGS_SIGNIN_PRESENT` — the settings row exists, and a fresh temp
///     store reads `GOOGLE_SIGNIN_STATE=signed-out`.
///  2. `SIGNIN_SURFACE_VISIBLE` — clicking it opens a REAL window that is
///     visible, key and loaded at the account URL (`POP_SIGNIN_URL` points it at
///     loopback so no test ever loads a real account page).
///  3. `STORE_SHARED` — a cookie planted through the SURFACE path is echoed
///     by the server on the LOOKUP path's own request. Same store object.
///  4. `SIGNOUT_CLEARS_GOOGLE_ONLY` — account cookies gone, others intact.
///
/// The signed-in EFFECT itself is not fabricatable without a real credential,
/// so what is proven is the mechanism that carries it.
@MainActor
private func runGoogleSignInProbe(panelController: PanelController) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    panelController.show()

    let root = NSTemporaryDirectory() + "pop-signin-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root, isDirectory: true),
        withIntermediateDirectories: true
    )
    let server = FixtureServer(directory: URL(fileURLWithPath: root, isDirectory: true))
    guard let base = server.start() else {
        print("SIGNIN_FIXTURE_SERVER_FAILED")
        fflush(stdout)
        exit(1)
    }
    print("SIGNIN_FIXTURE_ORIGIN=\(base)")
    print("SIGNIN_STORE_ID=\(BrowserController.dataStoreIdentifier.uuidString)")
    fflush(stdout)

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        Task { @MainActor in
            // (1) The settings row, and the state of a fresh store. The row is
            // found by walking the settings window's OWN accessibility tree, so
            // this is a measurement of what is on screen rather than a
            // declaration that a row was added.
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .milliseconds(900))
            let settingsLabels = accessibilityLabels(of: SettingsWindowController.shared.windowForProbe)
            // The account row's CONTROL is what the accessibility tree publishes
            // (SwiftUI's static headings/state text are not), and which control
            // is present IS the row's state: `Sign in…` while signed out,
            // `Sign out` once a session cookie exists.
            let hasRow = settingsLabels.contains("Sign in\u{2026}") || settingsLabels.contains("Sign out")
            print("SETTINGS_SIGNIN_LABELS=\(settingsLabels.joined(separator: " | "))")
            print("SETTINGS_SIGNIN_PRESENT=\(hasRow)")
            let freshState = await GoogleSignIn.state()
            print("GOOGLE_SIGNIN_STATE_FRESH=\(freshState)")
            fflush(stdout)

            // The surface must load something REAL, so it is pointed at this
            // run's own loopback fixture rather than at an account origin: no
            // test ever contacts a real account page.
            setenv("POP_SIGNIN_URL", base + "/echo-headers", 1)

            let browser = BrowserController.shared

            // (2) The surface. This is what the old menu item failed to do.
            await GoogleSignInWindowController.shared.signIn()
            try? await Task.sleep(for: .seconds(3))
            let visible = GoogleSignInWindowController.shared.isSignInSurfaceVisible
            let surfaceURL = GoogleSignInWindowController.shared.currentURL
            let sameStore = GoogleSignInWindowController.shared.signInStoreIsLookupStore
            print("SIGNIN_SURFACE_VISIBLE=\(visible)")
            // The surface must not merely EXIST: it must have actually
            // navigated to the account URL. `POP_SIGNIN_URL` points at this
            // run's own loopback fixture, so the assertion is that the live view
            // really loaded the URL it was opened with.
            let navigated = surfaceURL.contains("127.0.0.1")
            print("SIGNIN_SURFACE_LOADED_URL=\(surfaceURL)")
            print("SIGNIN_SURFACE_NAVIGATED=\(navigated)")
            print("SIGNIN_STORE_SAME_AS_LOOKUP=\(sameStore)")
            fflush(stdout)

            // (3) A cookie set through the SURFACE path, echoed by the server on
            // the LOOKUP path's request. On the wire, not from Pop's own store.
            _ = await browser.navigate(base + "/set-cookie", activatingPane: false)
            try? await Task.sleep(for: .seconds(1))
            let lookupNames = await browser.cookieNames(for: "127.0.0.1")
            _ = await browser.navigate(base + "/echo-headers", activatingPane: false)
            let body = await browser.pageText()
            var headers = ""
            if let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                headers = object["allHeaders"] ?? ""
            }
            let cookieHeader = headers
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.lowercased().hasPrefix("cookie:") } ?? ""
            let storeShared = sameStore && lookupNames.contains("pop_session_probe")
                && cookieHeader.contains("pop_session_probe")
            print("LOOKUP_COOKIE_HEADER=\(cookieHeader)")
            print("STORE_SHARED=\(storeShared)")
            fflush(stdout)

            // (4) Sign-out removes ONLY the account's cookies.
            let cookieStore = browser.webView.configuration.websiteDataStore.httpCookieStore
            if let provider = HTTPCookie(properties: [
                .domain: ".google.com", .path: "/", .name: "SID", .value: "probe-not-a-credential"
            ]) {
                await cookieStore.setCookie(provider)
            }
            if let other = HTTPCookie(properties: [
                .domain: ".example.org", .path: "/", .name: "unrelated_site", .value: "keep-me"
            ]) {
                await cookieStore.setCookie(other)
            }
            let signedInState = await GoogleSignIn.state()
            print("GOOGLE_SIGNIN_STATE_PLANTED=\(signedInState)")
            // The row must FOLLOW the store: with a session cookie present the
            // settings control is the sign-out one, not the sign-in one.
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .milliseconds(700))
            let signedInLabels = accessibilityLabels(
                of: SettingsWindowController.shared.windowForProbe
            )
            let rowFlipped = signedInLabels.contains("Sign out")
            print("SETTINGS_SIGNIN_LABELS_SIGNED_IN=\(signedInLabels.joined(separator: " | "))")
            print("SETTINGS_ROW_FLIPPED_TO_SIGNOUT=\(rowFlipped)")
            await GoogleSignInWindowController.shared.signOut()
            let accountLeft = await browser.cookieNames(for: "google.com")
            let otherAfter = await browser.cookieNames(for: "example.org")
            let loopbackAfter = await browser.cookieNames(for: "127.0.0.1")
            // Each survivor is read from ITS OWN host: `pop_session_probe` is
            // loopback's and `unrelated_site` is example.org's, so one filter
            // could only ever see one of them.
            let accountGone = accountLeft.isEmpty
            let otherIntact = otherAfter.contains("unrelated_site")
                && loopbackAfter.contains("pop_session_probe")
            let afterState = await GoogleSignIn.state()
            print("ACCOUNT_COOKIES_LEFT=\(accountLeft.joined(separator: " | "))")
            print("OTHER_COOKIES_AFTER=\(otherAfter.joined(separator: " | "))")
            print("SIGNOUT_CLEARS_GOOGLE_ONLY=\(accountGone && otherIntact)")
            print("GOOGLE_SIGNIN_STATE_AFTER_SIGNOUT=\(afterState)")
            fflush(stdout)

            let gate = visible && navigated && storeShared && accountGone && otherIntact
                && freshState == "signed-out" && hasRow && rowFlipped
            print("SIGNIN_GATE=\(gate)")
            fflush(stdout)
            GoogleSignInWindowController.shared.closeSignInSurface()
            exit(gate ? 0 : 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        print("SIGNIN_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-embedded-serp <url>` — a MEASUREMENT, not a feature.
///
/// Question: can Pop's embedded in-panel `WKWebView` (the M5 browser — a SECOND
/// view with its own `.nonPersistent()` data store) load a JS-heavy results
/// page and expose the answer TEXT in the DOM, where a plain `URLSession` fetch
/// only gets Google's JS wall? It navigates the SAME `BrowserController.shared`
/// view the browser tools drive, waits for the load PLUS a script-settle delay
/// (a SERP paints its answer well after `didFinish`), then reads the rendered
/// DOM. Every value printed is raw; nothing here ships a capability.
@MainActor
private func runEmbeddedSERPProbe(url rawURL: String) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    print("SERP_URL=\(rawURL)")
    fflush(stdout)

    Task { @MainActor in
        let browser = BrowserController.shared
        let nav = await browser.navigate(rawURL)
        print("SERP_NAV=\(nav)")
        fflush(stdout)

        // A SERP answers via script long after the load event, so the delegate's
        // `didFinish` alone would measure an empty DOM. This is the settle.
        try? await Task.sleep(for: .seconds(7))

        let script = #"""
        (function () {
          var t = (document.body && document.body.innerText) ? document.body.innerText : "";
          var lower = t.toLowerCase();
          var walls = ["before you continue", "consent", "unusual traffic",
                       "enable javascript", "if you are not redirected", "are you a robot"];
          var blocked = false;
          var wall = "";
          for (var i = 0; i < walls.length; i++) {
            var j = lower.indexOf(walls[i]);
            if (j !== -1) {
              blocked = true;
              wall = t.substring(Math.max(0, j - 40), j + 260).replace(/\s+/g, " ").trim();
              break;
            }
          }
          var signals = ["\u00b0c", "weather", "forecast", "high of"];
          var idx = -1;
          for (var k = 0; k < signals.length; k++) {
            var m = lower.indexOf(signals[k]);
            if (m !== -1 && (idx === -1 || m < idx)) { idx = m; }
          }
          var hasAnswer = idx !== -1;
          var excerpt = hasAnswer
            ? t.substring(Math.max(0, idx - 40), Math.max(0, idx - 40) + 300).replace(/\s+/g, " ").trim()
            : "";
          // Session evidence: an account avatar means signed IN; a "Sign in"
          // affordance means signed OUT.
          var avatar = !!document.querySelector(
            '[aria-label*="Google Account" i], [aria-label*="Account" i], a[href*="SignOutOptions"]'
          );
          var signIn = !!document.querySelector(
            'a[href*="ServiceLogin"], a[href*="accounts.google.com/SignIn"]'
          ) || lower.indexOf("sign in") !== -1;
          var signedIn = avatar && !signIn;
          // --- generic flight/price signals (no hardcoded widget selectors) ---
          var flightWords = ["flight", "nonstop", "non-stop", "airline", "depart",
                             "round trip", "one way", "where from"];
          var flightHit = -1;
          for (var f = 0; f < flightWords.length; f++) {
            var fi = lower.indexOf(flightWords[f]);
            if (fi !== -1 && (flightHit === -1 || fi < flightHit)) { flightHit = fi; }
          }
          var codeM = t.match(/\b(SIN|PVG|SHA|PEK|CAN|HKG)\b/);
          var priceRe = /(?:S?\$|SGD|USD)\s?[0-9][0-9,]{1,7}/gi;
          var priceMatches = t.match(priceRe) || [];
          var priceSet = {};
          for (var p = 0; p < priceMatches.length; p++) {
            priceSet[priceMatches[p].replace(/\s+/g, "").toUpperCase()] = true;
          }
          var priceCount = Object.keys(priceSet).length;
          var hasFlight = flightHit !== -1 || !!codeM || priceCount > 0;
          var fromM = t.match(/\bfrom\s+([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)?)/);
          var originCue = fromM ? fromM[0] : "";
          var originInput = document.querySelector(
            'input[placeholder*="from" i], input[aria-label*="from" i], input[name*="origin" i]'
          );
          var whereFrom = lower.indexOf("where from") !== -1;
          var assumedOrigin = originCue
            || (whereFrom ? "Where from?"
              : (originInput
                  ? "origin input: " + (originInput.getAttribute("aria-label")
                      || originInput.getAttribute("placeholder") || "")
                  : "none"));
          var firstPrice = t.search(priceRe);
          var ai = flightHit;
          if (ai === -1 || (firstPrice !== -1 && firstPrice < ai)) { ai = firstPrice; }
          if (ai === -1 && codeM) { ai = t.indexOf(codeM[0]); }
          var flightExcerpt = ai !== -1
            ? t.substring(Math.max(0, ai - 60), Math.max(0, ai - 60) + 400)
                .replace(/\s+/g, " ").trim()
            : "";
          var dateInput = !!document.querySelector(
            'input[type="date"], [aria-label*="Depart" i], [aria-label*="Date" i]'
          );
          var out = {
            blocked: blocked,
            wall: wall,
            domChars: t.length,
            hasAnswer: hasAnswer,
            excerpt: excerpt,
            avatar: avatar,
            signIn: signIn,
            signedIn: signedIn,
            cookieChars: (document.cookie || "").length,
            title: document.title || "",
            hasFlight: hasFlight,
            priceCount: priceCount,
            assumedOrigin: assumedOrigin,
            flightExcerpt: flightExcerpt,
            airportCode: codeM ? codeM[0] : "",
            dateInput: dateInput
          };
          return JSON.stringify(out);
        })()
        """#

        let json = await evaluateSERPJSON(browser.webView, script)
        guard let data = json.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("SERP_EVAL_FAILED raw=\(json.prefix(200))")
            fflush(stdout)
            exit(1)
        }
        func s(_ k: String) -> String { (d[k] as? String) ?? "" }
        func b(_ k: String) -> Bool { (d[k] as? Bool) == true }
        func n(_ k: String) -> Int { (d[k] as? Int) ?? -1 }

        let blocked = b("blocked")
        let hasAnswer = b("hasAnswer")
        let excerpt = s("excerpt")
        let signedIn = b("signedIn")
        let verdict: String
        if blocked {
            verdict = "EMBEDDED_SERP_BLOCKED"
        } else if hasAnswer {
            verdict = "EMBEDDED_SERP_READABLE"
        } else {
            verdict = "EMBEDDED_SERP_RENDERED_NO_ANSWER"
        }

        print("SERP_TITLE=\(s("title"))")
        print("SERP_BLOCKED=\(blocked)")
        print("SERP_DOM_CHARS=\(n("domChars"))")
        print("SERP_HAS_ANSWER=\(hasAnswer)")
        print("SERP_ANSWER_EXCERPT=\(excerpt)")
        print("SERP_ANSWER_CHARS=\(excerpt.count)")
        print("SERP_SIGNED_IN=\(signedIn)")
        print("SERP_COOKIE_CHARS=\(n("cookieChars"))")
        print("SESSION_STATE=\(signedIn ? "signed_in" : "signed_out")")
        print("SESSION_EVIDENCE avatar=\(b("avatar")) sign_in_link=\(b("signIn"))")
        if blocked { print("SERP_WALL_TEXT=\(s("wall"))") }
        print("EMBEDDED_SERP_VERDICT=\(verdict)")

        // --- flight/price measurement (raw) ---
        let hasFlight = b("hasFlight")
        let priceCount = n("priceCount")
        let assumedOrigin = s("assumedOrigin")
        let flightExcerpt = s("flightExcerpt")
        let flightVerdict: String
        if blocked {
            flightVerdict = "FLIGHT_BLOCKED"
        } else if hasFlight && priceCount > 0 {
            flightVerdict = "FLIGHT_PRICES_FOUND"
        } else if hasFlight {
            flightVerdict = "FLIGHT_CONTENT_NO_PRICE"
        } else if assumedOrigin != "none" {
            flightVerdict = "FLIGHT_NEEDS_ORIGIN"
        } else {
            flightVerdict = "FLIGHT_RENDERED_NOTHING"
        }
        print("FLIGHT_URL=\(rawURL)")
        print("FLIGHT_BLOCKED=\(blocked)")
        print("FLIGHT_DOM_CHARS=\(n("domChars"))")
        print("FLIGHT_HAS_FLIGHT_CONTENT=\(hasFlight)")
        print("FLIGHT_PRICE_TOKENS=\(priceCount)")
        print("FLIGHT_ASSUMED_ORIGIN=\(assumedOrigin)")
        print("FLIGHT_AIRPORT_CODE=\(s("airportCode"))")
        print("FLIGHT_DATE_INPUT=\(b("dateInput"))")
        print("FLIGHT_EXCERPT=\(flightExcerpt)")
        print("FLIGHT_PAYLOAD_CHARS=\(flightExcerpt.count)")
        print("FLIGHT_VERDICT=\(flightVerdict)")

        // JS-rendered vs a plain `URLSession` fetch of the SAME URL, in this run.
        let naive = await naiveFetch(rawURL)
        print("FLIGHT_NAIVE_FETCH_CHARS=\(naive.chars)")
        print("FLIGHT_NAIVE_VISIBLE_CHARS=\(naive.visibleChars)")
        print("FLIGHT_NAIVE_HAS_FLIGHT=\(naive.hasFlight)")
        print("FLIGHT_NAIVE_BLOCKED=\(naive.blocked)")
        // The rendered DOM carries real result text while the plain fetch's
        // VISIBLE text is a stub: that is the webview doing the JS work.
        print("FLIGHT_IS_JS_RENDERED=\(hasFlight && naive.visibleChars < 800)")

        fflush(stdout)
        exit(0)
    }

    // A navigation is bounded at 20s; this is the outer guard for the settle +
    // an eval that never answers.
    DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
        print("EMBEDDED_SERP_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// Reads the SERP probe's JSON blob out of one `evaluateJavaScript`, off the
/// main run loop without blocking it.
@MainActor
private func evaluateSERPJSON(_ webView: WKWebView, _ script: String) async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                continuation.resume(returning: "EVAL_ERROR: \(error.localizedDescription)")
            } else {
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }
}

/// `--test-relation-morphology`: the relation test's INFLECTION rule, measured.
///
/// Four fixtures, each a loopback page whose text carries one inflected word.
/// The query's content term is the STEM; the verdict is whether the shipped
/// extractor accepts the inflected form. The rule must be exactly "real English
/// inflections of the stem":
///   * `match` → `matches` is TRUE  (a page answers "matches" for "match")
///   * `won`   → `wonder`   is FALSE (a different word, not an inflection)
///   * `match` → `unmatched` is FALSE (the leading `\b` anchors the stem)
///   * `sunrise` → `sunrises` is TRUE
///
/// Each verdict is read from the REAL extraction script run over a real page —
/// the probe does not re-implement the pattern, so it cannot drift from it.
/// Loopback fixtures only; nothing external is contacted.
@MainActor
private func runRelationMorphologyProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // (label, query, page body, expected verdict). Every content term in the
    // query is present in the page, so a FALSE verdict is the MORPHOLOGY and not
    // a missing word: the only difference between a TRUE and a FALSE case is
    // whether the stem the query asked about actually appears there as an
    // inflection.
    // The fixture sentences deliberately open with a long word: a run of short
    // bare words at the head of a region is the extractor's generic menu-chrome
    // stripper, and a fixture that read like a nav bar would be stripped before
    // the relation rule ever saw it (measured: "the matches listed below ..."
    // lost its answer to the chrome stripper, not to the morphology test).
    let cases: [(String, String, String, Bool)] = [
        ("match_to_matches", "match listed",
         "Registry officials confirmed that the matches listed below were published "
            + "this morning by the office. Nothing else changed in the schedule.",
         true),
        ("won_to_wonder", "won today",
         "Spectators wondered whether anyone would claim the trophy today, because "
            + "the season had been unusually quiet across every division.",
         false),
        ("match_to_unmatched", "match table",
         "Importers reported that the unmatched table rows were left over from an "
            + "earlier migration and should be archived before the next run.",
         false),
        ("sunrise_to_sunrises", "sunrise time",
         "Astronomers explained that the sunrises time varies by season and by how "
            + "far north the observing site happens to sit.",
         true)
    ]
    print("MORPH_CASES=\(cases.count)")
    fflush(stdout)

    Task { @MainActor in
        let root = NSTemporaryDirectory() + "pop-morph-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            withIntermediateDirectories: true
        )
        for (index, testCase) in cases.enumerated() {
            let (label, _, body, _) = testCase
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                + "<title>\(label)</title></head><body><p>\(body)</p></body></html>"
            try? html.write(
                toFile: root + "/case\(index).html",
                atomically: true,
                encoding: .utf8
            )
        }
        guard let server = FixtureServer(
            directory: URL(fileURLWithPath: root, isDirectory: true)
        ).start() else {
            print("MORPH_FIXTURE_SERVER_FAILED")
            fflush(stdout)
            exit(1)
        }
        var allApplied = true
        var allAsExpected = true
        for (index, testCase) in cases.enumerated() {
            let (label, query, _, expected) = testCase
            _ = await BrowserController.shared.navigate(
                server + "/case\(index).html",
                activatingPane: false
            )
            try? await Task.sleep(for: .seconds(1))
            let verdict = await WebLookup.relationVerdict(
                query: query,
                on: BrowserController.shared.webView
            )
            allApplied = allApplied && verdict.applied
            let ok = verdict.passed == expected
            allAsExpected = allAsExpected && ok
            print("MORPH_CASE=\(label) EXPECTED=\(expected)"
                + " RELATION_APPLIED=\(verdict.applied)"
                + " RELATION_PASSED=\(verdict.passed)"
                + " EXPECTED_MATCH=\(ok)"
                + " ANSWER_CHARS=\(verdict.answer.count)")
            fflush(stdout)
        }
        print("MORPH_APPLIED_ALL=\(allApplied)")
        print("MORPH_GATE=\(allApplied && allAsExpected)")
        fflush(stdout)
        exit(allApplied && allAsExpected ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        print("MORPH_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-session-warm`: SESSION FORMATION, measured end to end.
///
/// Warms the session exactly the way a first visit does — the site ROOT with no
/// query, then the one consent click a person would make — and prints the
/// cookie NAMES and COUNT the persistent store accumulated. Cookie VALUES are
/// never printed: a value is a credential.
///
/// Run it a second time against the SAME `POP_WEBKIT_STORE_PATH` and it prints
/// `PERSIST_COOKIE_*` instead: whatever is in the jar on the second launch was
/// put there by the first, which is the only proof that the store is persistent
/// rather than rebuilt per process.
///
/// The store is probe-owned: `POP_WEBKIT_STORE_PATH` redirects Pop's own store
/// destination, and the probe runs under an executable name whose WebKit scope
/// is its own. The user's real browser, their profile and Pop's own production
/// store are never touched.
@MainActor
private func runSessionWarmProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // The site whose session is under test. Default is the lookup engine's
    // origin; a probe can point the measurement elsewhere with this override.
    let host = ProcessInfo.processInfo.environment["POP_WARM_HOST"] ?? "www.google.com"
    // The second launch of the pair: it must NOT warm again (that would
    // re-form the session it is trying to prove persisted), only read.
    let persistOnly = ProcessInfo.processInfo.environment["POP_SESSION_PERSIST_ONLY"] == "1"

    Task { @MainActor in
        if persistOnly {
            let names = await BrowserController.shared.cookieNames(for: host)
            print("PERSIST_COOKIE_NAMES=\(names.joined(separator: " | "))")
            print("PERSIST_COOKIE_COUNT=\(names.count)")
            fflush(stdout)
            exit(names.isEmpty ? 1 : 0)
        }
        let names = await WebLookup.warmSession(host: host)
        let total = await BrowserController.shared.cookieCount()
        print("WARM_COOKIE_TOTAL_ALL_HOSTS=\(total)")
        print("WARM_SESSION_GATE=\(!names.isEmpty)")
        fflush(stdout)
        exit(names.isEmpty ? 1 : 0)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("WARM_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-web-lookup "<query>" [--slots "origin,date"]` — the real `web_lookup`
/// capability, driven directly. It prints raw values (no model, no UI) so the
/// extraction, the never-ask rule, and the walls are all observable. `--slots`
/// is now INERT: a web lookup declares no slots and never asks before searching
/// (the declared-slot machinery is retained for non-web callers).
@MainActor
private func runWebLookupProbe(query: String, slots: [String]) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    print("LOOKUP_QUERY=\(query)")
    print("LOOKUP_DECLARED_SLOTS_IN=\(slots.joined(separator: " | "))")
    fflush(stdout)

    Task { @MainActor in
        let result = await WebLookup.run(query: query)
        print("LOOKUP_WALL=\(result.wall)")
        print("LOOKUP_DOM_CHARS=\(result.domChars)")
        print("LOOKUP_PAYLOAD_CHARS=\(result.payloadChars)")
        // PROOF, not a declaration: the relation test is only "active" if the
        // extractor actually applied a content-term test to the chosen region
        // and reported the verdict. A synthetic query whose terms are absent from
        // the page must therefore yield an empty payload.
        print("RELATION_TEST_ACTIVE=\(result.relationApplied)")
        print("RELATION_TEST_PASSED=\(result.relationPassed)")
        print("LOOKUP_ANSWER_EXCERPT=\(result.answerExcerpt)")
        print("LOOKUP_ANSWER_CHARS=\(result.answerExcerpt.count)")
        print("LOOKUP_ANSWER_NONEMPTY=\(!result.answerExcerpt.isEmpty)")
        print("LOOKUP_SOURCE_HOST=\(result.sourceHost)")
        print("LOOKUP_SOURCE_TITLE=\(result.sourceTitle)")
        print("LOOKUP_PROVENANCE=\(result.provenance)")
        print("LOOKUP_DECLARED_SLOTS="
            + result.declaredSlots.joined(separator: " | "))
        print("LOOKUP_MISSING_SLOTS="
            + result.missingSlots.joined(separator: " | "))
        print("LOOKUP_SLOT_CANDIDATES="
            + result.slotCandidates.joined(separator: " | "))
        print("LOOKUP_INFERRED_NOT_IN_QUERY_LOWCONF="
            + result.inferredNotInQuery.joined(separator: " | "))
        // The deterministic ask Pop would compose, and its honesty: every
        // backticked token must be a declared slot or a page candidate.
        let ask = WebLookupResult.askText(
            for: result.missingSlots,
            candidates: result.slotCandidates
        )
        let askTokens = backtickTokens(in: ask ?? "")
        let allowed = Set(result.declaredSlots).union(result.slotCandidates)
        print("LOOKUP_ASK_COMPOSED=\(ask != nil)")
        print("LOOKUP_ASK_TEXT=\(ask ?? "")")
        print("ASK_TOKENS=\(askTokens.joined(separator: " | "))")
        print("SLOT_AND_CANDIDATE_TOKENS="
            + orderedUnique(result.declaredSlots + result.slotCandidates).joined(separator: " | "))
        print("ASK_TEXT_HONEST=\(askTokens.allSatisfy { allowed.contains($0) })")
        print("LOOKUP_MARKER=\(result.marker)")
        // LOCATION + SESSION evidence, on the same run as the lookup.
        print("LOC_SOURCE=\(result.locSource)")
        print("LOC_CITY=\(result.locCity)")
        print("LOC_METHOD=\(result.locMethod)")
        print("LOC_EMBEDDED=\(result.locEmbedded)")
        print("LOC_CORELOCATION_AUTH=\(LocationProvider.shared.authorizationLabel)")
        let cookieCount = await BrowserController.shared.cookieCount()
        print("WEBKIT_COOKIE_COUNT=\(cookieCount)")
        let sessionHost = URL(string: result.usedURL)?.host ?? ""
        let names = await BrowserController.shared.cookieNames(for: sessionHost)
        print("SESSION_COOKIE_NAMES=\(names.joined(separator: " | "))")
        print("SESSION_PERSISTENT=true")
        print("SESSION_DATASTORE_ID=\(BrowserController.dataStoreIdentifier.uuidString)")
        let pageText = await BrowserController.shared.pageText()
        let pageLower = pageText.lowercased()
        print("LOC_EVIDENCE_HAS_SINGAPORE=\(pageLower.contains("singapore"))")
        print("LOC_EVIDENCE_HAS_JOHOR=\(pageLower.contains("johor"))")
        print("LOC_EVIDENCE_HAS_SENAI=\(pageLower.contains("senai"))")
        print("LOC_EVIDENCE_HEAD=\(pageText.replacingOccurrences(of: "\n", with: " ").prefix(240))")
        let payloadOK = result.payloadChars <= 700
        print("LOOKUP_PAYLOAD_OK=\(payloadOK)")
        let wallOK = !result.wall.isEmpty
        // NEW SPEC: a web lookup NEVER asks before searching. The ask is a pure
        // function of caller-declared slots, and a web lookup declares none, so
        // it is false by construction — the gate asserts it on EVERY lookup AND
        // requires a complete answer (a wall is the one honest non-answer).
        let askFired = !result.missingSlots.isEmpty
        let answerComplete = !result.answerExcerpt.isEmpty
        print("LOOKUP_ASK_FIRED=\(askFired)")
        print("LOOKUP_ANSWER_COMPLETE=\(answerComplete)")
        let structural = payloadOK && !askFired && (answerComplete || wallOK)
        print("LOOKUP_GATE=\(structural)")

        // The webview vs a plain `URLSession` fetch of the SAME URL, this run.
        let naive = await naiveFetch(result.usedURL)
        print("LOOKUP_NAIVE_FETCH_CHARS=\(naive.chars)")
        print("LOOKUP_NAIVE_VISIBLE_CHARS=\(naive.visibleChars)")
        print("LOOKUP_NAIVE_BLOCKED=\(naive.blocked)")
        print("LOOKUP_IS_JS_RENDERED=\(result.domChars > naive.visibleChars + 500)")
        fflush(stdout)
        exit(structural ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
        print("WEB_LOOKUP_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-excerpt-quality` — THE FRAGMENT GATE.
///
/// Six real queries run through the REAL `web_lookup`. For each extracted
/// excerpt the probe asserts, from the RAW neighbour characters the extraction
/// reported (not a boolean the extraction computed for itself):
///   * `EXCERPT_STARTS_WORD` — the character before the excerpt is whitespace or
///     start-of-text, so the excerpt never begins mid-word;
///   * `EXCERPT_ENDS_BOUNDARY` — the excerpt's last character is sentence
///     punctuation (`.`, `!`, `?`, `…`), OR the character after it is
///     whitespace, i.e. the cap fell on a word boundary.
///
/// Also measures staleness on the flight query (any date older than ~30 days in
/// the returned excerpt) and the empty-slot ask guard. No model, no UI.
@MainActor
private func runExcerptQualityProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let questions = [
        "weather tomorrow",
        "how's tomorrow weather",
        "flight to shanghai",
        "what time is sunset",
        "who won the match yesterday",
        "how tall is mount everest"
    ]
    print("EXCERPT_QUESTIONS=\(questions.count)")
    fflush(stdout)

    // The empty-slot ask guard, checked first: `askText` must REFUSE to render
    // without a named slot, and no rendering path may produce the empty template.
    let emptyAsk = WebLookupResult.askText(for: [], candidates: [])
    let blankAsk = WebLookupResult.askText(for: ["", "   "], candidates: [])
    let emptyTemplate = "I need the  to answer"
    print("ASK_EMPTY_SLOTS_RETURNS_NIL=\(emptyAsk == nil && blankAsk == nil)")
    print("ASK_EMPTY_TEMPLATE_RENDERED="
        + "\(emptyAsk.map { $0.contains(emptyTemplate) } ?? false)")
    fflush(stdout)

    Task { @MainActor in
        var allStartsWord = true
        var allEndsBoundary = true
        var allLocated = true
        var answered = 0
        for question in questions {
            let result = await WebLookup.run(query: question)
            let excerpt = result.answerExcerpt
            if !excerpt.isEmpty { answered += 1 }

            // NON-VACUOUS GATE. Every branch below FAILS closed:
            //   * a failed locate (`answerLocated == false`) fails both
            //     assertions — the extractor must not be able to skip the
            //     boundary checks by failing to find the excerpt in the page;
            //   * an EMPTY excerpt FAILS `startsWord` — a gate satisfiable with
            //     zero answers proves nothing, so "no answer" is never a pass.
            let located = result.answerLocated
            let prev = result.answerPrevChar
            let next = result.answerNextChar

            // START. Whitespace alone is not enough (measured passes that were
            // not clean): a letter/digit before the excerpt is mid-word, and
            // `-`/`_`/`/` before it is a mid-URL-slug cut. A leading SERP
            // navigation run is also a fail — same generic pattern the
            // extractor strips, detected here independently.
            let prevIsWord = prev.first.map { $0.isLetter || $0.isNumber } ?? false
            let prevIsSlug = prev.contains { $0 == "-" || $0 == "_" || $0 == "/" }
            let headIsNavRun = navRunTokenCount(excerpt) >= navRunMinTokens
            let firstTokenHasSlash = excerpt.split(separator: " ", maxSplits: 1)
                .first
                .map { $0.contains("/") } ?? false
            let startsWord = located
                && !excerpt.isEmpty
                && (prev.isEmpty || prev.rangeOfCharacter(from: .whitespacesAndNewlines) != nil)
                && !prevIsWord
                && !prevIsSlug
                && !firstTokenHasSlash
                && !headIsNavRun

            // END. A bare "." is NOT a sentence end: inside a URL
            // ("www.accuweather.") or a decimal ("3.14") it is punctuation of
            // the token, not of the sentence. So the last character counts only
            // when it is a terminator that is not part of a domain/number run,
            // and a trailing domain/URL is an outright FAIL.
            let endsSentence: Bool = {
                guard let last = excerpt.last else { return false }
                if ".!?\u{2026}".contains(last) { return !isDotInTokenRun(excerpt) }
                return false
            }()
            let endsWordBoundary = !next.isEmpty
                && next.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            let endsBoundary = located
                && !excerpt.isEmpty
                && !endsWithURLOrDomain(excerpt)
                && (endsSentence || endsWordBoundary)

            allStartsWord = allStartsWord && startsWord
            allEndsBoundary = allEndsBoundary && endsBoundary
            allLocated = allLocated && located

            let flat = excerpt.replacingOccurrences(of: "\n", with: " ")
            print("EXCERPT_Q=\(question)")
            print("EXCERPT_LOCATED=\(located)")
            print("EXCERPT_STARTS_WORD=\(startsWord)")
            print("EXCERPT_ENDS_BOUNDARY=\(endsBoundary)")
            print("EXCERPT_HEAD=\(String(flat.prefix(60)))")
            print("EXCERPT_TAIL=\(String(flat.suffix(60)))")
            print("EXCERPT_CHARS=\(excerpt.count)")
            // Raw neighbour codes, so a reviewer can audit the derivation
            // instead of trusting it.
            print("EXCERPT_PREV_CODE=\(charCode(prev))")
            print("EXCERPT_NEXT_CODE=\(charCode(next))")
            // STALENESS: the flight query is the one measured case.
            if question == "flight to shanghai" {
                let dates = staleDates(in: excerpt)
                let cutoff = Date().addingTimeInterval(-30 * 86400)
                let stale = dates.filter { $0 < cutoff }
                print("STALE_DATE_FOUND=\(!stale.isEmpty)")
                print("STALE_DATES="
                    + stale.map { ISO8601DateFormatter().string(from: $0) }
                        .joined(separator: " | "))
                print("ALL_DATES_IN_EXCERPT="
                    + dates.map { ISO8601DateFormatter().string(from: $0) }
                        .joined(separator: " | "))
            }
            fflush(stdout)
        }
        print("EXCERPT_ANSWERED=\(answered)/\(questions.count)")
        let gate = allStartsWord && allEndsBoundary && allLocated
        print("EXCERPT_GATE=\(gate)")
        let askGate = emptyAsk == nil && blankAsk == nil
        print("ASK_EMPTY_GATE=\(askGate)")
        fflush(stdout)
        exit(gate && askGate ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
        print("EXCERPT_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// The generic SERP-navigation-run threshold, shared by the extractor's JS and
/// this probe's Swift check: a leading run of short bare words with no sentence
/// punctuation is menu chrome, not an answer. Pattern only — no site is named
/// and no nav token is hardcoded.
private let navRunMinTokens = 4

/// How many leading tokens of `text` form a short-word run (`^[A-Za-z]{1,7}$`
/// each). The same test the extractor applies before stripping chrome.
private func navRunTokenCount(_ text: String) -> Int {
    // Leading separator glyphs (a close button, a caret, a bullet) sit BEFORE
    // the run and must not stop it being measured — measured "× All News Images
    // Maps Books Search tools" scored as a clean start because the leading "×"
    // broke the count at zero.
    var work = Substring(text)
    while let first = work.first, !first.isLetter && !first.isNumber {
        work = work.dropFirst()
    }
    var count = 0
    for token in work.split(separator: " ") {
        guard !token.isEmpty, token.count <= 7,
              token.allSatisfy({ $0.isLetter && $0.isASCII }) else { break }
        count += 1
    }
    return count
}

/// A trailing `.` only ends a sentence when it is punctuation of the sentence.
/// Inside a URL or a decimal it belongs to the token, so it must not count.
private func isDotInTokenRun(_ text: String) -> Bool {
    guard text.last == "." else { return false }
    // The trailing token, dot removed: a domain-ish or numeric run means the dot
    // is part of the token ("www.accuweather", "3.14").
    let head = String(text.dropLast())
    let token = head.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    guard !token.isEmpty else { return false }
    let looksLikeDomain = token.contains(".")
    let looksLikeDecimal = token.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
        && token.contains(".")
    return looksLikeDomain || looksLikeDecimal
}

/// True when the excerpt's last token is a URL/domain — an excerpt that ends on
/// a bare hostname has been cut mid-reference, which is a boundary FAIL.
private func endsWithURLOrDomain(_ text: String) -> Bool {
    let tail = text.split(separator: " ").last.map(String.init) ?? ""
    guard !tail.isEmpty else { return false }
    if tail.lowercased().hasPrefix("www.") || tail.contains("://") { return true }
    if tail.hasPrefix("http") { return true }
    // "accuweather.com." style: a dot with a plausible TLD-length suffix.
    let stripped = tail.hasSuffix(".") ? String(tail.dropLast()) : tail
    let parts = stripped.split(separator: ".")
    guard parts.count >= 2 else { return false }
    let last = parts[parts.count - 1]
    guard last.count >= 2, last.allSatisfy({ $0.isLetter }) else { return false }
    return parts.dropLast().allSatisfy {
        !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

/// The raw Unicode scalar of a neighbour character, for auditability.
private func charCode(_ s: String) -> String {
    guard let scalar = s.unicodeScalars.first else { return "none" }
    return "U+\(String(scalar.value, radix: 16, uppercase: true))"
}

/// Every parseable calendar date in `text`, for the staleness measurement only.
/// A measurement helper, never part of extraction — no city, airport or currency
/// knowledge lives here, only date shapes. Sliding windows over the tokens so
/// "6 Mar 2026" / "Mar 6, 2026" / "6 March 2026" all parse.
private func staleDates(in text: String) -> [Date] {
    var found: [Date] = []
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    let words = text.components(separatedBy: .whitespacesAndNewlines)
    for shape in ["d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy"] {
        f.dateFormat = shape
        for i in 0..<words.count {
            for j in i..<min(i + 4, words.count) {
                let slice = words[i...j].joined(separator: " ")
                let trimmed = slice.trimmingCharacters(
                    in: CharacterSet(charactersIn: ",.;:()[]")
                )
                if let d = f.date(from: trimmed), !found.contains(d) {
                    found.append(d)
                }
            }
        }
    }
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.timeZone = TimeZone(identifier: "UTC")
    iso.dateFormat = "yyyy-MM-dd"
    if let r = try? NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}") {
        let ns = text as NSString
        for match in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let d = iso.date(from: ns.substring(with: match.range)), !found.contains(d) {
                found.append(d)
            }
        }
    }
    return found.sorted()
}

/// `--test-no-junk-ask` — the permanent regression guard for the junk-ask bug.
///
/// Six plain, self-contained questions are driven through the REAL product path
/// with NO caller-declared slots. Each must ANSWER (payload > 0, answer
/// non-empty) and the ask must never fire. The removed page-scraped ask template
/// is the canary: if any user-facing surface can still reproduce that exact
/// sentence, the bug has returned and the guard fails. This probe gates nothing
/// on the model, so it is deterministic: the ask is a pure function of the
/// caller's declared slots, of which there are none.
@MainActor
private func runNoJunkAskProbe() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    // The exact removed template. If this string is reachable from user-facing
    // text, the junk-ask path has come back.
    let junkTemplate = "The source assumed these values you did not give"
    let questions = [
        "weather tomorrow",
        "how's tomorrow weather",
        "what's the news today",
        "who won the match yesterday",
        "what time is sunset",
        "how tall is mount everest"
    ]
    print("JUNK_ASK_QUESTIONS=\(questions.count)")
    fflush(stdout)

    Task { @MainActor in
        var allAnswered = true
        var anyAskFired = false
        var templateReachable = false
        var anySlotDeclared = false
        for question in questions {
            // A web lookup declares no slots and never asks before searching.
            let result = await WebLookup.run(query: question)
            let askFired = !result.missingSlots.isEmpty
            let answered = result.payloadChars > 0 && !result.answerExcerpt.isEmpty
            // The user-facing surfaces: the tool text the model receives and the
            // deterministic ask Pop would compose. Both are scanned for the
            // removed template.
            let composedAsk = WebLookupResult.askText(
                for: result.missingSlots,
                candidates: result.slotCandidates
            ) ?? ""
            let userFacing = result.modelText + "\n" + composedAsk
            let hit = userFacing.contains(junkTemplate)
                || userFacing.contains("I need the  to answer")
                || (WebLookupResult.askText(for: []) ?? "").contains(
                    "I need the  to answer"
                )
            allAnswered = allAnswered && answered
            anyAskFired = anyAskFired || askFired
            templateReachable = templateReachable || hit
            anySlotDeclared = anySlotDeclared || !result.declaredSlots.isEmpty
            print("JUNK_ASK_Q=\(question)"
                + " ASK_FIRED=\(askFired)"
                + " ANSWERED=\(answered)"
                + " ANSWER=\(String(result.answerExcerpt.prefix(60)).replacingOccurrences(of: "\n", with: " "))")
            fflush(stdout)
        }
        print("JUNK_ASK_ANSWERED_ALL=\(allAnswered)")
        print("JUNK_ASK_ASK_FIRED_ANY=\(anyAskFired)")
        print("JUNK_ASK_TEMPLATE_REACHABLE=\(templateReachable)")
        // The junk-ask class is now unreachable BY CONSTRUCTION: a web lookup
        // declares no slots at all, so the ask branch cannot be entered.
        print("JUNK_ASK_NO_SLOTS_DECLARED=\(!anySlotDeclared)")
        let guardOK = allAnswered && !anyAskFired && !templateReachable && !anySlotDeclared
        print("JUNK_ASK_GUARD=\(guardOK)")
        fflush(stdout)
        exit(guardOK ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
        print("JUNK_ASK_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// A plain `URLSession` GET of the SAME URL the webview loaded, so the probe can
/// show what the network alone returns versus the rendered DOM. Desktop UA, so
/// a wall is the JS wall and not a bot check keyed on the client.
private func naiveFetch(_ urlString: String) async -> (chars: Int, visibleChars: Int, hasFlight: Bool, blocked: Bool) {
    guard let url = URL(string: urlString) else { return (0, 0, false, true) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data.prefix(200_000), as: UTF8.self)
        let lower = text.lowercased()
        let blocked = ["enable javascript", "unusual traffic", "before you continue", "consent"]
            .contains { lower.contains($0) }
        let hasFlight = lower.contains("flight") || lower.contains("airline")
        // Tags stripped: the wall page is ~90KB of script with almost no VISIBLE
        // text, which is what distinguishes it from the rendered DOM. Comparing
        // raw HTML lengths would hide that.
        var visible = text
        visible = visible.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression
        )
        visible = visible.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        visible = visible.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.count, visible.count, hasFlight, blocked)
    } catch {
        print("FLIGHT_NAIVE_FETCH_ERROR=\(error.localizedDescription)")
        return (0, 0, false, true)
    }
}

/// `--test-browser-blocked`: the two schemes that must never load.
@MainActor
private func runBrowserBlockedProbe() async {
    let file = await ToolRegistry.execute(("browser_navigate", .object([
        "url": .string("file:///etc/passwd")
    ])))
    let js = await ToolRegistry.execute(("browser_navigate", .object([
        "url": .string("javascript:alert(1)")
    ])))
    let blockedFile = file.hasPrefix("ERROR") && file.contains("file")
    let blockedJS = js.hasPrefix("ERROR") && js.contains("javascript")
    print("BLOCKED_FILE=\(blockedFile)")
    print("BLOCKED_JS=\(blockedJS)")
    finishBrowserProbe("blocked", blockedFile && blockedJS)
}

@MainActor
private func runBrowserReadProbe(base: String) async {
    _ = await ToolRegistry.execute(("browser_navigate", .object([
        "url": .string(base + "/form.html")
    ])))
    let read = await ToolRegistry.execute(("browser_read", .object([:])))
    print("BROWSER_READ_HEAD=\(read.prefix(120))")
    let refs = read.split(separator: "\n").filter { $0.hasPrefix("[") }
    let hasSubmit = read.contains("Pay now")
    print("READ_REFS=\(refs.count)")
    print("READ_HAS_SUBMIT=\(hasSubmit)")
    finishBrowserProbe("read", refs.count >= 4 && hasSubmit)
}

/// `--test-browser-setcookie` / `--test-browser-cookiecheck`: session
/// CONTINUITY, measured. The first launch sets a cookie on loopback; the second
/// launch, a SEPARATE process, reads it back. Together they prove the persistent
/// `WKWebsiteDataStore` really retains session state across launches — the
/// other half of forming an end-user session, alongside the headers. Loopback
/// only; nothing external is contacted.
@MainActor
private func runBrowserSetCookieProbe(base: String) async {
    _ = await BrowserController.shared.navigate(base + "/set-cookie", activatingPane: false)
    try? await Task.sleep(for: .seconds(1))
    let names = await BrowserController.shared.cookieNames(for: "127.0.0.1")
    print("SETCOOKIE_NAMES=\(names.joined(separator: " | "))")
    let stored = names.contains("pop_session_probe")
    print("SESSION_COOKIE_STORED=\(stored)")
    finishBrowserProbe("setcookie", stored)
}

/// The SECOND launch: does the cookie from the previous process survive?
@MainActor
private func runBrowserCookieCheckProbe(base: String) async {
    _ = await BrowserController.shared.navigate(base + "/echo-headers", activatingPane: false)
    let names = await BrowserController.shared.cookieNames(for: "127.0.0.1")
    print("COOKIE_PERSISTED_NAMES=\(names.joined(separator: " | "))")
    let survived = names.contains("pop_session_probe")
    print("SESSION_COOKIE_PERSISTED=\(survived)")
    finishBrowserProbe("cookiecheck", survived)
}

/// `--test-browser-headers`: the END-USER REQUEST PROFILE, measured.
///
/// The lookup webview must look like a normal browser session on every
/// navigation, not a bare WebKit client. This navigates the SAME webview the
/// lookup uses to a loopback `/echo-headers` route and reports what the server
/// actually received — nothing external is contacted, and no header is faked
/// for the probe: these are the bytes on the wire from the real load path.
@MainActor
private func runBrowserHeadersProbe(base: String) async {
    let url = base + "/echo-headers"
    let status = await BrowserController.shared.navigate(url, activatingPane: false)
    print("HEADERS_NAV_STATUS=\(status.split(separator: "\n").first.map(String.init) ?? status)")
    // Read the echoed JSON back out of the rendered page.
    let body = await BrowserController.shared.pageText()
    var userAgent = ""
    var acceptLanguage = ""
    if let data = body.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        userAgent = object["userAgent"] ?? ""
        acceptLanguage = object["acceptLanguage"] ?? ""
    }
    print("UA_SENT=\(userAgent)")
    if let data = body.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        print("ALL_HEADERS_SENT=\(object["allHeaders"] ?? "")")
    }
    print("ACCEPT_LANGUAGE_SENT=\(acceptLanguage)")
    // A UA that names Pop, Glance or an unfilled template is not a browser
    // profile. Checked against the string actually received, case-insensitively.
    let lowered = userAgent.lowercased()
    let appMarkers = ["pop", "glance", "electron", "headless", "bot", "__query__", "webkitpopup"]
    let tainted = appMarkers.contains { lowered.contains($0) }
    let looksBrowser = !userAgent.isEmpty
        && !tainted
        && lowered.contains("mozilla")
        && lowered.contains("safari")
    print("UA_LOOKS_BROWSER=\(looksBrowser)")
    // The locale's own language must be honoured, or the SERP renders in the
    // wrong language/region.
    let wantLocale = BrowserController.acceptLanguage()
    let languageOK = !acceptLanguage.isEmpty
        && acceptLanguage.contains(Locale.current.language.languageCode?.identifier ?? "en")
    print("ACCEPT_LANGUAGE_MATCHES_LOCALE=\(languageOK)")
    print("ACCEPT_LANGUAGE_EXPECTED=\(wantLocale)")
    finishBrowserProbe("headers", looksBrowser && languageOK)
}

/// The shared form flow. `decision` is posted through the bridge exactly as the
/// Run or Deny button posts it, so the probe exercises the real gate path.
@MainActor
private func runBrowserFormProbe(base: String, decision: String) async {
    let controller = ChatController(webViewProvider: { nil }, configProvider: { .defaults })
    let nativeSink = ApprovalGate.shared.sink
    ApprovalGate.shared.sink = { json in
        await nativeSink?(json)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String
        else { return }
        await MainActor.run {
            controller.handleBridgeMessage(
                type: "approvalVerdict",
                body: ["id": id, "decision": decision]
            )
        }
    }

    _ = await ToolRegistry.execute(("browser_navigate", .object([
        "url": .string(base + "/form.html")
    ])))
    let read = await ToolRegistry.execute(("browser_read", .object([:])))
    // The email field's ref, found the way the model would: read the refs.
    var emailRef = 0
    for line in read.split(separator: "\n") where line.contains("[") {
        if line.contains("email") || line.contains("you@example.com") {
            emailRef = Int(line.split(separator: "]").first?
                .replacingOccurrences(of: "[", with: "") ?? "0") ?? 0
        }
    }
    print("BROWSER_EMAIL_REF=\(emailRef)")

    let typed = await ToolRegistry.execute(("browser_type_field", .object([
        "ref": .number(Double(emailRef)),
        "text": .string("buyer@example.com")
    ])))
    print("BROWSER_TYPED=\(typed.prefix(100))")

    let submitted = await ToolRegistry.execute(("browser_submit", .object([:])))
    print("BROWSER_SUBMITTED=\(submitted.prefix(160))")

    let after = await ToolRegistry.execute(("browser_read", .object([:])))
    let confirmed = after.contains("ORDER CONFIRMED")
    if decision == "run" {
        print("FORM_SUBMITTED=\(confirmed)")
        finishBrowserProbe("form", confirmed)
    } else {
        let blocked = submitted.contains("DENIED")
        print("FORM_DENIED_OK=\(blocked && !confirmed)")
        finishBrowserProbe("deny", blocked && !confirmed)
    }
}

@MainActor
private func runBrowserExtractProbe(base: String) async {
    _ = await ToolRegistry.execute(("browser_navigate", .object([
        "url": .string(base + "/shop.html")
    ])))
    let json = await ToolRegistry.execute(("browser_extract", .object([
        "fields": .string("name,price")
    ])))
    print("BROWSER_EXTRACT_HEAD=\(json.prefix(200))")
    let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
        .flatMap { $0 as? [[String: Any]] } ?? []
    let complete = rows.filter { row in
        (row["name"] as? String ?? "").isEmpty == false
            && (row["price"] as? String ?? "").isEmpty == false
    }
    print("EXTRACT_ROWS=\(rows.count)")
    print("EXTRACT_COMPLETE=\(complete.count)")
    finishBrowserProbe("extract", rows.count >= 5 && complete.count >= 5)
}

/// A 127.0.0.1-only static file server, so the fixtures have an http(s)-shaped
/// origin without a probe being able to reach the public network.
final class FixtureServer: @unchecked Sendable {
    private let directory: URL
    private var listener: NWListener?

    init(directory: URL) {
        self.directory = directory
    }

    /// Returns the origin (`http://127.0.0.1:PORT`) once bound.
    func start() -> String? {
        do {
            _ = try BrowserFixtures.write(into: directory)
        } catch {
            return nil
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try? NWListener(using: parameters)
        guard let listener else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var origin: String?
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                if let port = listener.port {
                    origin = "http://127.0.0.1:\(port.rawValue)"
                }
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [directory] connection in
            FixtureServer.serve(connection: connection, from: directory)
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 5) == .success else { return nil }
        return origin
    }

    /// Echoes the request's own headers back as JSON. Parsed from the raw
    /// request text rather than assumed, so a header WebKit adds, rewrites or
    /// drops is visible exactly as the server received it.
    private static func serveEchoHeaders(request: String, connection: NWConnection) {
        var userAgent = ""
        var acceptLanguage = ""
        var all: [String] = []
        for line in request.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if name == "user-agent" { userAgent = value }
            if name == "accept-language" { acceptLanguage = value }
            all.append("\(name): \(value)")
        }
        let json: [String: String] = [
            "userAgent": userAgent,
            "acceptLanguage": acceptLanguage,
            "allHeaders": all.joined(separator: " | ")
        ]
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + body,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func serve(connection: NWConnection, from directory: URL) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let first = request.split(separator: "\n").first
            else { return }
            let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let name = path.hasPrefix("/") ? String(path.dropFirst()) : path

            // `/echo-headers`: reports back what the request ACTUALLY carried, so
            // the end-user request profile (User-Agent, Accept-Language) is
            // measured rather than assumed. Loopback only — nothing external is
            // contacted to check it.
            if name == "echo-headers" {
                FixtureServer.serveEchoHeaders(request: request, connection: connection)
                return
            }

            // `/set-cookie`: proves the PERSISTENT store actually retains a
            // cookie across processes. If a cookie set here is not visible on a
            // later probe launch, session continuity is broken and no amount of
            // header polish can form a real end-user session.
            if name == "set-cookie" {
                let body = Data("cookie set".utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                    + "Set-Cookie: pop_session_probe=abc123; Path=/; Max-Age=86400\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(header.utf8) + body,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }

            let fileURL = directory.appendingPathComponent(
                name.isEmpty ? "index.html" : name
            )
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let body = try? Data(contentsOf: fileURL)
            else {
                connection.send(
                    content: Data("not found".utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(header.utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}

/// `--test-tool-loop`: the on-device model, two turns, no mocks.
///
/// Turn 1 asks the question the injected CLOCK already answers, so a correct
/// model makes no tool call at all \u2014 that is the measurement: the cheap path
/// must stay tool-free. Turn 2 asks for a directory listing, which must produce
/// a real `list_dir` call.
@MainActor
private func runToolLoopProbe(chatController: ChatController) {
    setenv("POP_TOOL_ROOT", NSTemporaryDirectory(), 1)
    let fixture = NSTemporaryDirectory() + "pop-toolfixture-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: fixture, isDirectory: true),
        withIntermediateDirectories: true
    )
    for name in ["alpha.txt", "beta.md", "gamma.json"] {
        try? "fixture \(name)".write(
            toFile: fixture + "/" + name,
            atomically: true,
            encoding: .utf8
        )
    }
    print("LOOP_FIXTURE=\(fixture)")

    let config = (try? PopConfig.load()) ?? .defaults
    // The ON-DEVICE provider, deliberately not `makeProvider(config)`: this
    // probe measures Pop's own tool plumbing, so it must not depend on a cloud
    // endpoint being configured, reachable or paid for.
    let provider: ModelProvider
    if #available(macOS 26.0, *) {
        provider = AppleFMProvider(pcc: config.pcc)
    } else {
        print("LOOP_UNAVAILABLE needs macOS 26")
        fflush(stdout)
        exit(1)
    }
    print("LOOP_PROVIDER=\(type(of: provider))")

    let collector = LoopCollector()

    func oneTurn(prompt: String) async -> String {
        var full = ""
        do {
            // The REAL loop: tools are executed by `AgentLoop` and their
            // outcomes observed through the same callback the app renders from.
            let events = AgentLoop.stream(
                provider: provider,
                messages: [ChatMessage(role: .user, text: prompt)],
                options: GenerationOptions(temperature: config.temperature),
                tools: ToolRegistry.schemas()
            ) { outcome in
                await MainActor.run {
                    collector.record(outcome.name, ok: outcome.ok)
                    print("LOOP_TOOL name=\(outcome.name) ok=\(outcome.ok)")
                    fflush(stdout)
                }
            }
            for try await event in events {
                switch event {
                case .delta(let piece): full += piece
                case .done(let text): full = text
                case .toolCall(_, let name, _): print("LOOP_TOOL_CALL name=\(name)")
                }
            }
        } catch {
            print("LOOP_TURN_ERROR \(error)")
            fflush(stdout)
        }
        return full
    }

    Task { @MainActor in
        // The app injects the clock into the per-turn context block, so the
        // probe sends the same block: measuring a bare question would only
        // prove the model reaches for a tool when it has none.
        let clock = await oneTurn(
            prompt: ChatController.withClock("what is the current date and time?")
        )
        print("LOOP_CLOCK=\(clock.isEmpty ? "none" : String(clock.replacingOccurrences(of: "\n", with: " ")))")
        print("LOOP_CLOCK_TOOLS=\(collector.names().joined(separator: ","))")

        let listing = await oneTurn(
            prompt: "List the files in this directory using your tools: \(fixture)"
        )
        let names = collector.names()
        let called = names.last { $0 == "list_dir" }
        print("LOOP_TOOL_CALLED=\(called ?? names.first ?? "none")")
        print("LOOP_TOOL_OK=\(collector.okListDir)")
        print("LOOP_ANSWER=\(String(listing.replacingOccurrences(of: "\n", with: " ")))")
        print("LOOP_GATE=\(called == "list_dir" && collector.okListDir)")
        fflush(stdout)
        try? FileManager.default.removeItem(atPath: fixture)
        exit(0)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 118) {
        print("LOOP_TIMEOUT")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

// MARK: - On-device capability battery

/// The output of one capability scenario: the `FM_CAP_<NAME>` payload. The
/// battery REPORTS what the model did — a capability gap is a finding, never a
/// harness failure, so nothing here is a pass/fail on quality.
struct FMCapResult: Sendable {
    var value: String
    static let skipped = FMCapResult(value: "skipped (timeout)")
}

/// What one `AgentLoop` turn produced: the final text and the tools it called.
struct FMCapTurn: Sendable {
    var text: String
    var tools: [String]
}

/// Ordered record of the tools a turn invoked, observed through the same
/// activity callback the app renders from.
final class FMCapToolCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func record(_ name: String) { lock.lock(); defer { lock.unlock() }; seen.append(name) }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

/// Runs ONE prompt through the REAL `AgentLoop` with the given tool subset and
/// returns the final text plus the tools the model called. The on-device
/// provider executes tools natively, so outcomes arrive through the activity
/// callback exactly as the app renders them.
private func fmCapTurn(
    provider: ModelProvider,
    prompt: String,
    tools: [ToolSchema],
    history: [ChatMessage] = []
) async -> FMCapTurn {
    let collector = FMCapToolCollector()
    var messages = history
    messages.append(ChatMessage(role: .user, text: prompt))
    var full = ""
    do {
        let events = AgentLoop.stream(
            provider: provider,
            messages: messages,
            options: GenerationOptions(),
            tools: tools
        ) { outcome in
            await MainActor.run { collector.record(outcome.name) }
        }
        for try await event in events {
            switch event {
            case .delta(let piece): full += piece
            case .done(let text): full = text
            case .toolCall: break
            }
        }
    } catch {
        print("FM_CAP_TURN_ERROR \(error)")
        fflush(stdout)
        return FMCapTurn(text: "ERROR: \(error)", tools: collector.names)
    }
    return FMCapTurn(text: full, tools: collector.names)
}

/// Bounds ONE scenario: a hung model call resolves to `skipped` so the rest of
/// the battery still runs. `skipped` is a reportable finding, not a gate.
private func fmCapTimed(
    seconds: Double,
    _ operation: @escaping @Sendable () async -> FMCapResult
) async -> FMCapResult {
    await withTaskGroup(of: FMCapResult.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return .skipped
        }
        let first = await group.next() ?? .skipped
        group.cancelAll()
        return first
    }
}

/// The four small READ-ONLY tools whose schemas fit the on-device window — the
/// candidate local executor toolset (docs/foundation-models.md §7.3). Filtered
/// HERE in the probe against the shipped registry: no product-code change.
private let fmCapReadOnlySubset = ["list_dir", "read_file", "grep_files", "screen_read"]

private func fmCapSubsetSchemas() -> [ToolSchema] {
    ToolRegistry.schemas().filter { fmCapReadOnlySubset.contains($0.name) }
}

/// The serialized schema text a subset actually costs, built from the registry.
private func fmCapSchemaBlob(_ schemas: [ToolSchema]) -> String {
    JSONValue.array(schemas.map { schema in
        .object([
            "name": .string(schema.name),
            "description": .string(schema.description),
            "parameters": schema.parameters
        ])
    }).stableString()
}

/// Token count for a blob: the RUNTIME API where the OS exposes it, the
/// documented chars/4 fallback otherwise. Never a hardcoded budget.
@available(macOS 26.0, *)
private func fmCapTokenCount(_ text: String) async -> (tokens: Int, runtime: Bool) {
    if #available(macOS 26.4, *) {
        if let n = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return (n, true)
        }
    }
    return (max(1, text.count / 4), false)
}

/// Scenario 1 — plain chat, NO tools, no screen context. The on-device model's
/// baseline Mac-config answer.
private func fmCapScenarioBaseline(provider: ModelProvider) async -> FMCapResult {
    let turn = await fmCapTurn(
        provider: provider,
        prompt: "Give the steps to change the macOS desktop wallpaper.",
        tools: []
    )
    let answered = !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let settings = turn.text.localizedCaseInsensitiveContains("System Settings")
    print("FM_CAP_BASELINE_REPLY=\(turn.text.replacingOccurrences(of: "\n", with: " "))")
    fflush(stdout)
    return FMCapResult(value: "answered=\(answered) contains_SystemSettings=\(settings)")
}

/// Scenario 2 — the SAME question with a fabricated, unrelated app in the
/// screen-context prefix. Measures the documented anchoring weakness: does the
/// reply drift to the fake app instead of the real target? Either result is a
/// valid measurement.
private func fmCapScenarioAnchor(provider: ModelProvider) async -> FMCapResult {
    let turn = await fmCapTurn(
        provider: provider,
        prompt: "[screen context] | app: Calculator | Give the steps to change the macOS desktop wallpaper.",
        tools: []
    )
    let anchor = turn.text.localizedCaseInsensitiveContains("Calculator")
    let settings = turn.text.localizedCaseInsensitiveContains("System Settings")
    print("FM_CAP_CONTEXT_ANCHOR_REPLY=\(turn.text.replacingOccurrences(of: "\n", with: " "))")
    fflush(stdout)
    return FMCapResult(value: "anchor=\(anchor) contains_SystemSettings=\(settings)")
}

/// Scenario 3 — the KEY one: a compact toolset that FITS the window. Does the
/// model actually call `list_dir` and report the fixture files?
private func fmCapScenarioToolsFit(provider: ModelProvider, fixture: String) async -> FMCapResult {
    let turn = await fmCapTurn(
        provider: provider,
        prompt: "List the files in this directory using your tools: \(fixture)",
        tools: fmCapSubsetSchemas()
    )
    let called = turn.tools.contains("list_dir")
    let names = ["alpha.txt", "beta.md", "gamma.json"]
    let mentioned = names.filter { turn.text.localizedCaseInsensitiveContains($0) }.count
    print("FM_CAP_TOOLS_FIT_TOOLS=\(turn.tools.joined(separator: ","))")
    print("FM_CAP_TOOLS_FIT_REPLY=\(turn.text.replacingOccurrences(of: "\n", with: " "))")
    fflush(stdout)
    return FMCapResult(value: "toolcall=\(called) files=\(mentioned >= 2) named=\(mentioned)/3")
}

/// Scenario 4 — the schema budget, computed from the RUNTIME window (never a
/// constant). Cumulative subsets (1, 2, 4, 8, all) are tokenized and compared
/// against the usable window (window minus prompt + response headroom), and the
/// largest subset that fits is reported.
@available(macOS 26.0, *)
private func fmCapScenarioSchemaBudget() async -> FMCapResult {
    let runtimeWindow = { if #available(macOS 26.4, *) { return true } else { return false } }()
    let window = AppleFMProvider.contextWindowSize()
    // Prompt + current turn + response headroom reserved out of the window.
    let headroom = 1192
    let usable = max(0, window - headroom)
    let all = ToolRegistry.schemas()
    var sizes: [Int] = []
    for n in [1, 2, 4, 8] where n < all.count && !sizes.contains(n) { sizes.append(n) }
    if !sizes.contains(all.count) { sizes.append(all.count) }
    var largestFit = 0
    var largestTokens = 0
    for n in sizes {
        let (tokens, _) = await fmCapTokenCount(fmCapSchemaBlob(Array(all.prefix(n))))
        if tokens <= usable, n > largestFit {
            largestFit = n
            largestTokens = tokens
        }
        print("budget: \(n) tools ≈ \(tokens) tokens (runtime window \(window), usable ≈ \(usable) after prompt+headroom)")
        fflush(stdout)
    }
    print("FM_CAP_RUNTIME_WINDOW=\(runtimeWindow)")
    fflush(stdout)
    return FMCapResult(value: "max_fit_tools=\(largestFit) largest_tokens=\(largestTokens) total_tools=\(all.count)")
}

/// Scenario 5 — a local jev-shaped decision: a criteria-labelled choice that
/// must come back as strict JSON. Three variants probe whether the on-device
/// model can serve local routing decisions without the cloud.
private func fmCapScenarioJevShape(provider: ModelProvider) async -> FMCapResult {
    let variants: [(key: String, question: String, labels: [String])] = [
        ("click", "should an assistant auto-run a screen click inside its allowed window?", ["allow", "ask"]),
        ("rmrf", "should an assistant deny a shell rm -rf command?", ["deny", "ask"]),
        ("read", "should an assistant allow reading a local file?", ["allow", "ask"])
    ]
    var parsed = 0
    var valid = 0
    var choices: [String] = []
    for variant in variants {
        let prompt = "Answer ONLY as JSON: {\"choice\": \"<label>\", \"confidence\": <0..1>}. "
            + "Question: \(variant.question) Labels: \(variant.labels.joined(separator: ", "))."
        let turn = await fmCapTurn(provider: provider, prompt: prompt, tools: [])
        print("FM_CAP_JEV_RAW_\(variant.key)=\(turn.text.replacingOccurrences(of: "\n", with: " "))")
        guard let object = fmCapJSONObject(turn.text),
              let choice = object["choice"] as? String,
              let confidence = (object["confidence"] as? NSNumber)?.doubleValue else {
            choices.append("\(variant.key)=unparsed")
            continue
        }
        parsed += 1
        let labelOK = variant.labels.contains { $0.caseInsensitiveCompare(choice) == .orderedSame }
        if labelOK, (0.0...1.0).contains(confidence) { valid += 1 }
        choices.append("\(variant.key)=\(choice)")
    }
    print("FM_CAP_JEV_CHOICES=\(choices.joined(separator: ","))")
    fflush(stdout)
    return FMCapResult(value: "parsed=\(parsed)/3 valid=\(valid)/3")
}

/// Scenario 6 — three SEQUENTIAL tool rounds in one conversation: list, then
/// read two files. Measures whether the small model can chain tool turns.
private func fmCapScenarioMultiturn(provider: ModelProvider, fixture: String) async -> FMCapResult {
    let tools = fmCapSubsetSchemas()
    let prompts = [
        "List the files in this directory using your tools: \(fixture)",
        "Now read the file alpha.txt using your tools: \(fixture)/alpha.txt",
        "Now read the file beta.md using your tools: \(fixture)/beta.md"
    ]
    var history: [ChatMessage] = []
    var roundsOK = 0
    var lastText = ""
    for prompt in prompts {
        let turn = await fmCapTurn(provider: provider, prompt: prompt, tools: tools, history: history)
        if !turn.tools.isEmpty { roundsOK += 1 }
        print("FM_CAP_MULTITURN_TOOLS=\(turn.tools.joined(separator: ","))")
        history.append(ChatMessage(role: .user, text: prompt))
        history.append(ChatMessage(role: .assistant, text: turn.text))
        lastText = turn.text
    }
    let reflected = lastText.localizedCaseInsensitiveContains("beta fixture")
    print("FM_CAP_MULTITURN_FINAL=\(lastText.replacingOccurrences(of: "\n", with: " "))")
    fflush(stdout)
    return FMCapResult(value: "rounds_ok=\(roundsOK)/3 reflected_beta=\(reflected)")
}

/// Extracts the first JSON object from a reply, tolerating prose around it.
private func fmCapJSONObject(_ text: String) -> [String: Any]? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
    let slice = String(text[start...end])
    guard let data = slice.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

/// `--test-fm-capability`: a headless capability battery for the ON-DEVICE
/// Apple Foundation Models brain. Six scenarios measure what the built-in model
/// can and cannot do, so Pop can decide which roles to give it. Every result is
/// REPORTED honestly — including weaknesses; the exit gate checks only that the
/// infrastructure ran (provider available, scenarios produced output), never
/// that the model performed well.
@MainActor
private func runFMCapabilityProbe() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    // TEMP FIXTURES ONLY, under the tool root the sandbox already allows.
    setenv("POP_TOOL_ROOT", NSTemporaryDirectory(), 1)
    let fixture = NSTemporaryDirectory() + "pop-fmcap-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: fixture, isDirectory: true),
        withIntermediateDirectories: true
    )
    for (name, body) in [("alpha.txt", "alpha fixture"), ("beta.md", "beta fixture"), ("gamma.json", "{}")] {
        try? body.write(toFile: fixture + "/" + name, atomically: true, encoding: .utf8)
    }
    print("FM_CAP_FIXTURE=\(fixture)")
    fflush(stdout)

    let config = (try? PopConfig.load()) ?? .defaults

    guard #available(macOS 26.0, *) else {
        print("FM_CAP_UNAVAILABLE needs macOS 26")
        fflush(stdout)
        exit(1)
    }
    // ON-DEVICE ONLY, deliberately not `makeProvider`: the battery measures the
    // built-in model, so it must never depend on a cloud endpoint.
    let provider: ModelProvider = AppleFMProvider(pcc: config.pcc)
    guard provider.isHealthy else {
        print("FM_CAP_UNAVAILABLE provider unhealthy reason=\(provider.unhealthyReason)")
        fflush(stdout)
        exit(1)
    }
    print("FM_CAP_PROVIDER=\(type(of: provider))")
    fflush(stdout)

    // A hung model call marks THAT scenario skipped (a finding) and the others
    // still run — one arm can never take the battery down.
    let perScenario: Double = 60

    Task { @MainActor in
        let baseline = await fmCapTimed(seconds: perScenario) {
            await fmCapScenarioBaseline(provider: provider)
        }
        print("FM_CAP_BASELINE=\(baseline.value)")

        let anchor = await fmCapTimed(seconds: perScenario) {
            await fmCapScenarioAnchor(provider: provider)
        }
        print("FM_CAP_CONTEXT_ANCHOR=\(anchor.value)")

        let toolsFit = await fmCapTimed(seconds: perScenario) {
            await fmCapScenarioToolsFit(provider: provider, fixture: fixture)
        }
        print("FM_CAP_TOOLS_FIT=\(toolsFit.value)")

        let budget = await fmCapTimed(seconds: perScenario) {
            await fmCapScenarioSchemaBudget()
        }
        print("FM_CAP_SCHEMA_BUDGET=\(budget.value)")

        let jev = await fmCapTimed(seconds: perScenario) {
            await fmCapScenarioJevShape(provider: provider)
        }
        print("FM_CAP_JEV_SHAPE=\(jev.value)")

        let multiturn = await fmCapTimed(seconds: perScenario) {
            await fmCapScenarioMultiturn(provider: provider, fixture: fixture)
        }
        print("FM_CAP_MULTITURN=\(multiturn.value)")
        fflush(stdout)

        // GATE: INFRASTRUCTURE ONLY. The provider was available and every
        // scenario produced output — a timeout reports `skipped`, a capability
        // gap its honest value. The gate never inspects the model's quality.
        let allProduced = !baseline.value.isEmpty && !anchor.value.isEmpty
            && !toolsFit.value.isEmpty && !budget.value.isEmpty
            && !jev.value.isEmpty && !multiturn.value.isEmpty
        print("FM_CAP_PROBE=\(allProduced ? "ok" : "fail")")
        fflush(stdout)

        try? FileManager.default.removeItem(atPath: fixture)
        exit(allProduced ? 0 : 1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
        print("FM_CAP_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

// MARK: - M9 on-device probes

/// The real availability, stringified for the log (never guessed).
private func onDeviceAvailabilityLabel() -> String {
    if #available(macOS 26.0, *) {
        switch AppleFMProvider.realAvailability() {
        case .available: return "available"
        case .unavailable(let reason): return reason.key
        }
    }
    return "requires-macOS-26"
}

/// Points this process at a temp config whose provider is `apple-fm`, keeping
/// the user's remote endpoint/model/headers so the fallback has somewhere to go.
/// Written to a temp path; the user's real config is only READ.
@MainActor
private func forceOnDeviceConfig() {
    var config = (try? PopConfig.load()) ?? .defaults
    config.provider = "apple-fm"
    let path = NSTemporaryDirectory() + "pop-fmcfg-\(UUID().uuidString).json"
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: URL(fileURLWithPath: path))
        setenv("POP_CONFIG_PATH", path, 1)
        print("FM_CONFIG provider=apple-fm baseURL=\(config.baseURL) model=\(config.model) fallbackKey=openai-compat")
        fflush(stdout)
    } catch {
        print("FM_CONFIG_FAILED \(error)")
        fflush(stdout)
    }
}

/// What the page can tell us about the turn. Native occlusion is added by the
/// caller; geometry and hit-testing come from the DOM (§10).
struct OnDeviceMeasure {
    var lastText: String
    /// The LAST ASSISTANT ANSWER ONLY — the `.answer` span, without the
    /// Copy/Retry actions row. `lastText` is the whole turn (`innerText`), whose
    /// trailing "Copy Retry" would make an echo comparison vacuous: an echoed
    /// question would read "<question> Copy Retry" and never equal the question.
    var lastAnswerText: String
    var lastOnScreen: Bool
    var hitIsTurn: Bool
    var pageSays: String
    var turns: Int
    var bubbleDisplay: String
    var bubbleError: Bool
    var streamStatus: String
    var lastRect: String
    var elementFromPoint: String
}

/// One message through the real composer, then wait for the stream to settle.
/// `stopOnError` also ends the wait when the page renders its error state, so
/// the negative control does not sit out the full deadline.
@MainActor
private func sendProbeMessage(
    webView: WKWebView,
    chatController: ChatController,
    prompt: String,
    stopOnError: Bool,
    done: @escaping (Bool) -> Void
) {
    DispatchQueue.main.async {
        let js = "document.getElementById('input').value = "
            + jsString(prompt) + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("PROBE_SEND_ERROR \(error.localizedDescription)")
                fflush(stdout)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        func poll() {
            let check = "(function () {"
                + "var stop = document.getElementById('stop');"
                + "var bubble = document.getElementById('bubble');"
                + "return JSON.stringify({"
                + " streaming: !!(stop && !stop.hidden),"
                + " error: !!(bubble && bubble.classList.contains('error'))"
                + "});"
                + "})()"
            webView.evaluateJavaScript(check) { value, _ in
                var streaming = true
                var error = false
                if let text = value as? String, let data = text.data(using: .utf8),
                   let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    streaming = (d["streaming"] as? Bool) == true
                    error = (d["error"] as? Bool) == true
                }
                if !streaming, chatController.deltaCount > 0 || (stopOnError && error) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done(false) }
                    return
                }
                if Date() >= deadline { done(true); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }
}

/// Rendered geometry + computed style + `elementFromPoint` for the last turn.
@MainActor
private func measureOnDevice(webView: WKWebView, done: @escaping (OnDeviceMeasure) -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        let check = #"""
        (function () {
          var bubble = document.getElementById('bubble');
          var panel = document.documentElement.getBoundingClientRect();
          function rect(el) {
            if (!el) { return null; }
            var r = el.getBoundingClientRect();
            return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
          }
          function fmt(r) { return r ? (r.x + ',' + r.y + ',' + r.w + ',' + r.h) : 'none'; }
          var out = {};
          out.bubbleDisplay = bubble ? getComputedStyle(bubble).display : 'missing';
          out.bubbleError = !!(bubble && bubble.classList.contains('error'));
          var ss = document.getElementById('streamStatus');
          out.streamStatus = ss ? ((ss.className || '') + '|' + (ss.textContent || '')) : 'missing';
          var turns = [].slice.call(document.querySelectorAll('#bubble .turn'));
          out.turns = turns.length;
          var last = turns.length > 0 ? turns[turns.length - 1] : null;
          var lr = rect(last);
          out.lastRect = fmt(lr);
          out.lastText = last ? ((last.innerText || '').replace(/\s+/g, ' ').trim()) : '';
          var answers = [].slice.call(document.querySelectorAll('#bubble .turn.assistant .answer'));
          var lastAnswer = answers.length > 0 ? answers[answers.length - 1] : null;
          out.lastAnswerText = lastAnswer ? ((lastAnswer.innerText || '').replace(/\s+/g, ' ').trim()) : '';
          out.lastOnScreen = !!(lr && lr.h > 0 && lr.y >= -1 && lr.y + lr.h <= panel.height + 1);
          out.hitIsTurn = false;
          out.elementFromPoint = 'none';
          if (lr && lr.w > 0 && lr.h > 0) {
            var cx = lr.x + Math.round(lr.w / 2);
            var cy = lr.y + Math.round(lr.h / 2);
            if (cx >= 0 && cx < panel.width && cy >= 0 && cy < panel.height) {
              var el = document.elementFromPoint(cx, cy);
              if (el) {
                out.elementFromPoint = (el.id ? '#' + el.id : '.')
                  + (el.className ? '.' + String(el.className).replace(/\s+/g, '.') : '');
                out.hitIsTurn = !!(el === last || last.contains(el) || el.contains(last));
              }
            } else { out.elementFromPoint = 'offscreen'; }
          }
          out.pageSays = window.__popLastVisibility || '';
          return JSON.stringify(out);
        })()
        """#

        webView.evaluateJavaScript(check) { value, error in
            if let error {
                print("ONDEVICE_MEASURE_ERROR \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("ONDEVICE_MEASURE_FAILED")
                fflush(stdout)
                exit(1)
            }
            func s(_ k: String) -> String { (d[k] as? String) ?? "?" }
            func b(_ k: String) -> Bool { (d[k] as? Bool) == true }
            func n(_ k: String) -> Int { (d[k] as? Int) ?? -1 }
            done(OnDeviceMeasure(
                lastText: s("lastText"),
                lastAnswerText: s("lastAnswerText"),
                lastOnScreen: b("lastOnScreen"),
                hitIsTurn: b("hitIsTurn"),
                pageSays: s("pageSays"),
                turns: n("turns"),
                bubbleDisplay: s("bubbleDisplay"),
                bubbleError: b("bubbleError"),
                streamStatus: s("streamStatus"),
                lastRect: s("lastRect"),
                elementFromPoint: s("elementFromPoint")
            ))
        }
    }
}

private func onDeviceHardTimeout(seconds: Double, marker: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print(marker)
        fflush(stdout)
        exit(1)
    }
}

/// `--test-on-device-turn`: the default brain (M9) answers a real turn with no
/// credentials, and the reply is genuinely on screen.
@MainActor
private func runOnDeviceTurnProbe(panelController: PanelController, chatController: ChatController) {
    forceOnDeviceConfig()
    ProviderTestSeams.shared.availability = .available
    // Fallback OFF: this probe asserts the ON-DEVICE brain itself answered. With
    // the fallback on, an echoing model would be papered over by the remote
    // brain and the echo assertion could never fire (SPEC §10 rule 4).
    ProviderTestSeams.shared.fallbackEnabled = false
    panelController.show()
    let webView = panelController.appWebView.webView

    // A FREE-FORM question whose correct answer cannot equal the question. The
    // old prompt ("Reply with exactly: POP_ONDEVICE_OK") was satisfiable by an
    // echoing model by construction, so the probe passed while the user bug
    // shipped.
    let prompt = "What is 2 + 2? Answer with only the number."
    print("FM_AVAILABILITY=\(onDeviceAvailabilityLabel())")
    print("FM_STREAM_API=streamResponse")
    print("FM_PROMPT=\(prompt)")
    fflush(stdout)
    let keychainBefore = KeychainStore.readCount

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        sendProbeMessage(
            webView: webView,
            chatController: chatController,
            prompt: prompt,
            stopOnError: false
        ) { _ in
            measureOnDevice(webView: webView) { m in
                let touched = KeychainStore.readCount != keychainBefore
                let provider = chatController.lastAnsweredBy
                let reply = m.lastAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let echo = ChatController.isEcho(chatController.lastAnswerFull, of: prompt)
                    || ChatController.isEcho(chatController.lastAnswerFull, of: m.lastText)
                let answerIsUserText = ChatController.isEcho(m.lastAnswerText, of: prompt)
                print("FM_PROVIDER=\(provider)")
                print("FM_REPLY=\(reply.isEmpty ? "<empty>" : String(reply.prefix(120)))")
                print("FM_ANSWER_CHARS=\(reply.count)")
                print("FM_ASK_FIRED=\(ProviderTestSeams.shared.lastAskFired)")
                print("FM_DECLARED_SLOTS="
                    + ProviderTestSeams.shared.lastDeclaredSlots.joined(separator: " | "))
                print("FM_MISSING_SLOTS="
                    + ProviderTestSeams.shared.lastMissingSlots.joined(separator: " | "))
                print("FM_ECHO=\(echo)")
                print("FM_REPLY_EQUALS_PROMPT=\(reply == prompt)")
                print("FM_ANSWER_IS_USER_TEXT=\(answerIsUserText)")
                print("FM_KEYCHAIN_TOUCHED=\(touched)")
                print("FM_LAST_ON_SCREEN=\(m.lastOnScreen)")
                print("FM_HIT_IS_TURN=\(m.hitIsTurn)")
                print("FM_LAST_TEXT=\(String(m.lastText.prefix(40)))")
                print("FM_TURNS=\(m.turns) FM_PAGE_SAYS=\(m.pageSays) FM_BUBBLE_DISPLAY=\(m.bubbleDisplay)")
                // NON-VACUOUS: non-empty AND not the prompt AND no echo AND the
                // rendered assistant turn is not the user's own text.
                let gate = !reply.isEmpty
                    && reply != prompt
                    && !echo
                    && !answerIsUserText
                    && !touched
                    && provider.contains("AppleFMProvider")
                    && m.lastOnScreen
                    && m.hitIsTurn
                print("FM_GATE=\(gate)")
                fflush(stdout)
                exit(gate ? 0 : 1)
            }
        }
    }

    onDeviceHardTimeout(seconds: 150, marker: "FM_HARD_TIMEOUT")
    NSApp.run()
}

/// `--test-on-device-fallback`: availability forced unavailable; the existing
/// remote provider must answer, and the panel must show it (not blank).
@MainActor
private func runOnDeviceFallbackProbe(panelController: PanelController, chatController: ChatController) {
    forceOnDeviceConfig()
    ProviderTestSeams.shared.availability = .unavailable(.appleIntelligenceNotEnabled)
    ProviderTestSeams.shared.fallbackEnabled = true
    panelController.show()
    let webView = panelController.appWebView.webView

    var forcedReason = "appleIntelligenceNotEnabled"
    if #available(macOS 26.0, *) {
        let onDevice = AppleFMProvider(
            pcc: false,
            availabilityOverride: .unavailable(.appleIntelligenceNotEnabled),
            toolsEnabled: false
        )
        forcedReason = onDevice.unhealthyReason
    }
    print("FALLBACK_FORCED_REASON=\(forcedReason)")
    fflush(stdout)
    let keychainBefore = KeychainStore.readCount

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        sendProbeMessage(
            webView: webView,
            chatController: chatController,
            prompt: "Reply with exactly: POP_FALLBACK_OK",
            stopOnError: false
        ) { _ in
            measureOnDevice(webView: webView) { m in
                let provider = chatController.lastAnsweredBy
                let reply = m.lastText.trimmingCharacters(in: .whitespacesAndNewlines)
                let keychainRead = KeychainStore.readCount != keychainBefore
                print("FALLBACK_PROVIDER=\(provider)")
                print("FALLBACK_REASON=\(forcedReason)")
                print("FALLBACK_REPLY=\(reply.isEmpty ? "<empty>" : String(reply.prefix(120)))")
                print("FALLBACK_KEYCHAIN_READ=\(keychainRead)")
                print("FALLBACK_LAST_ON_SCREEN=\(m.lastOnScreen)")
                print("FALLBACK_HIT_IS_TURN=\(m.hitIsTurn)")
                print("FALLBACK_TURNS=\(m.turns) FALLBACK_PAGE_SAYS=\(m.pageSays)")
                let notBlank = !reply.isEmpty && m.lastOnScreen && m.hitIsTurn
                let gate = provider.contains("OpenAICompatProvider")
                    && !forcedReason.isEmpty
                    && notBlank
                print("FALLBACK_GATE=\(gate)")
                fflush(stdout)
                exit(gate ? 0 : 1)
            }
        }
    }

    onDeviceHardTimeout(seconds: 150, marker: "FALLBACK_HARD_TIMEOUT")
    NSApp.run()
}

/// `--test-on-device-nofallback`: the NEGATIVE CONTROL. On-device unavailable
/// AND fallback disabled — the app must surface a clear error, not hang and not
/// show an empty panel.
@MainActor
private func runOnDeviceNoFallbackProbe(panelController: PanelController, chatController: ChatController) {
    forceOnDeviceConfig()
    ProviderTestSeams.shared.availability = .unavailable(.appleIntelligenceNotEnabled)
    ProviderTestSeams.shared.fallbackEnabled = false
    panelController.show()
    let webView = panelController.appWebView.webView
    print("NOFALLBACK_FORCED_REASON=appleIntelligenceNotEnabled")
    fflush(stdout)

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        sendProbeMessage(
            webView: webView,
            chatController: chatController,
            prompt: "Reply with exactly: POP_NOFALLBACK",
            stopOnError: true
        ) { timedOut in
            measureOnDevice(webView: webView) { m in
                let statusError = m.streamStatus.contains("error")
                let visibleError = !m.lastText.isEmpty
                    && m.lastOnScreen
                    && (m.bubbleError || statusError)
                let state: String
                if timedOut {
                    state = "hung"
                } else if visibleError {
                    state = "error-visible"
                } else {
                    state = "blank"
                }
                print("NOFALLBACK_STATE=\(state)")
                print("NOFALLBACK_BUBBLE_ERROR=\(m.bubbleError)")
                print("NOFALLBACK_STREAM_STATUS=\(m.streamStatus)")
                print("NOFALLBACK_LAST_ON_SCREEN=\(m.lastOnScreen)")
                print("NOFALLBACK_HIT_IS_TURN=\(m.hitIsTurn)")
                print("NOFALLBACK_LAST_TEXT=\(String(m.lastText.prefix(80)))")
                print("NOFALLBACK_PROVIDER=\(chatController.lastAnsweredBy)")
                let gate = state == "error-visible"
                print("NOFALLBACK_GATE=\(gate)")
                fflush(stdout)
                exit(gate ? 0 : 1)
            }
        }
    }

    onDeviceHardTimeout(seconds: 150, marker: "NOFALLBACK_HARD_TIMEOUT")
    NSApp.run()
}

/// `--test-on-device-prompt "<prompt>"`: the user's exact words through the real
/// provider path. Prints `FM_PROMPT`, `FM_REPLY` VERBATIM and `FM_ECHO` (true
/// iff the reply is a verbatim copy of the prompt). This is the reproduction for
/// "Pop displayed my own question as the answer", and the gate that would have
/// caught it: the old turn probe asserted only a NON-EMPTY reply while prompting
/// "Reply with exactly: POP_ONDEVICE_OK", so an echoing model passed by
/// construction.
///
/// Seams (test-only):
///   `POP_FM_LEGACY_PROMPT=1`  -> use the pre-fix flattened prompt
///   `POP_FM_NO_FALLBACK=1`    -> no remote fallback, so an echo is visible raw
@MainActor
private func runOnDevicePromptProbe(
    prompt: String,
    panelController: PanelController,
    chatController: ChatController
) {
    forceOnDeviceConfig()
    ProviderTestSeams.shared.availability = .available
    let noFallback = ProcessInfo.processInfo.environment["POP_FM_NO_FALLBACK"] == "1"
    ProviderTestSeams.shared.fallbackEnabled = !noFallback
    ProviderTestSeams.shared.logPrompt = true
    panelController.show()
    let webView = panelController.appWebView.webView

    print("FM_PROMPT=\(prompt)")
    print("FM_FALLBACK_ENABLED=\(!noFallback)")
    print("FM_LEGACY_PROMPT=\(ProviderTestSeams.shared.legacyFlattenedPrompt)")
    print("FM_FORCE_ECHO=\(ProviderTestSeams.shared.forceEcho)")
    fflush(stdout)
    let keychainBefore = KeychainStore.readCount

    // The user's report was a turn in an ONGOING conversation. `POP_FM_WARMUP`
    // sends one prior exchange first, so the flattened-transcript construction
    // is exercised over more than a single line.
    let warmup = ProcessInfo.processInfo.environment["POP_FM_WARMUP"] ?? ""

    func measureAndExit() {
        measureOnDevice(webView: webView) { m in
            let provider = chatController.lastAnsweredBy
            let sent = ProviderTestSeams.shared.lastPrompt
            // The ANSWER ONLY: comparing the whole turn would trip over the
            // trailing "Copy Retry" and hide an echo.
            let reply = m.lastAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
            // The model's RAW output, not the DOM: the rendered `innerText`
            // loses newlines, so a multi-line echo would not compare equal.
            let raw = chatController.lastAnswerFull
            let touched = KeychainStore.readCount != keychainBefore
            let echo = ChatController.isEcho(raw, of: prompt)
                || ChatController.isEcho(raw, of: sent)
            // The ASSISTANT turn on screen must not BE the user's own text.
            let answerIsUserText = ChatController.isEcho(m.lastAnswerText, of: prompt)
            let remote = provider.contains("OpenAICompatProvider")
            print("FM_PROMPT_SENT=\(sent.replacingOccurrences(of: "\n", with: " | "))")
            print("FM_PROMPT_SENT_CHARS=\(sent.count)")
            // ZERO-NETWORK EVIDENCE: the on-device provider makes no network
            // call itself, and `web_lookup` is this process's only web entry
            // point. Zero here (with the Keychain untouched) is the proof.
            print("NET_WEB_LOOKUP_CALLS=\(ProviderTestSeams.shared.webLookupCount)")
            print("NET_KEYCHAIN_TOUCHED=\(touched)")
            print("NET_LAST_WEB_MARKER=\(ProviderTestSeams.shared.lastWebMarker)")
            print("FM_PROVIDER=\(provider)")
            print("FM_REPLY=\(reply.isEmpty ? "<empty>" : reply)")
            print("FM_ANSWER_CHARS=\(reply.count)")
            print("FM_ASK_FIRED=\(ProviderTestSeams.shared.lastAskFired)")
            print("FM_DECLARED_SLOTS="
                + ProviderTestSeams.shared.lastDeclaredSlots.joined(separator: " | "))
            print("FM_MISSING_SLOTS="
                + ProviderTestSeams.shared.lastMissingSlots.joined(separator: " | "))
            print("FM_SLOT_CANDIDATES="
                + ProviderTestSeams.shared.lastSlotCandidates.joined(separator: " | "))
            print("FM_ECHO=\(echo)")
            print("FM_REPLY_EQUALS_PROMPT=\(reply == prompt)")
            print("FM_ANSWER_IS_USER_TEXT=\(answerIsUserText)")
            print("FM_KEYCHAIN_TOUCHED=\(touched)")
            print("FM_LAST_ON_SCREEN=\(m.lastOnScreen)")
            print("FM_HIT_IS_TURN=\(m.hitIsTurn)")
            print("FM_TURNS=\(m.turns)")
            print("FM_LAST_TEXT=\(m.lastText)")
            let onDeviceOK = provider.contains("AppleFMProvider")
                && !reply.isEmpty && !echo && !answerIsUserText
            // A legitimate fallback: the remote brain answered with a real,
            // non-echoing, visible answer (and Swift printed the notice). The
            // remote path legitimately READS the Keychain, so `touched` is NOT
            // part of this condition.
            let fallbackOK = remote && !reply.isEmpty && !echo
                && !answerIsUserText && m.lastOnScreen
            let gate = onDeviceOK || fallbackOK
            print("FM_MODE=\(remote ? "remote-fallback" : "on-device")")
            print("FM_GATE=\(gate)")
            fflush(stdout)
            exit(gate ? 0 : 1)
        }
    }

    func sendReal() {
        sendProbeMessage(
            webView: webView,
            chatController: chatController,
            prompt: prompt,
            stopOnError: false
        ) { _ in
            measureAndExit()
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        if warmup.isEmpty {
            sendReal()
        } else {
            print("FM_WARMUP=\(warmup)")
            fflush(stdout)
            sendProbeMessage(
                webView: webView,
                chatController: chatController,
                prompt: warmup,
                stopOnError: false
            ) { _ in
                chatController.probeResetDeltaCount()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sendReal() }
            }
        }
    }

    onDeviceHardTimeout(seconds: 150, marker: "FM_PROMPT_HARD_TIMEOUT")
    NSApp.run()
}

/// `--test-on-device-weather`: the on-device brain answers a LIVE weather
/// question by calling `web_lookup`, and the answer is checked against the live
/// page re-fetched in the same run (tolerance ±1 °C). No cloud fallback: the
/// on-device provider must answer.
@MainActor
private func runOnDeviceWeatherProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    forceOnDeviceConfig()
    ProviderTestSeams.shared.availability = .available
    ProviderTestSeams.shared.fallbackEnabled = false
    panelController.show()
    let webView = panelController.appWebView.webView

    // The probe prompt is overridable so the SAME on-screen path can be driven
    // with the user's exact wordings (`weather tomorrow`,
    // `how's tomorrow weather`) without a second probe. Unset keeps the original.
    let prompt = ProcessInfo.processInfo.environment["POP_WX_PROMPT"]
        ?? "what's the weather tomorrow"
    print("WX_PROMPT=\(prompt)")
    fflush(stdout)

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        sendProbeMessage(
            webView: webView,
            chatController: chatController,
            prompt: prompt,
            stopOnError: false
        ) { _ in
            measureOnDevice(webView: webView) { m in
                let reply = m.lastAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Independent live re-fetch, in the SAME run.
                Task { @MainActor in
                    let live = await WebLookup.run(query: "weather tomorrow")
                    let liveTemps = temperatures(in: live.answerExcerpt)
                    let replyTemps = temperatures(in: reply)
                    let match = temperaturesMatch(replyTemps, liveTemps, tolerance: 1)
                    // The transcript — the `#bubble` element ONLY, so the
                    // composer and any browser strip cannot be mistaken for
                    // transcript text — must contain NEITHER a `web:` marker line
                    // NOR a `TOOL ` line. Both are diagnostic only now; the
                    // answer itself has to still be there.
                    let transcriptJS = "(function(){var b=document.getElementById('bubble');"
                        + "var t=b?(b.innerText||''):'';"
                        + "return [t.indexOf('web:')!==-1?'yes':'no',"
                        + "t.indexOf('TOOL ')!==-1?'yes':'no',"
                        + "t.length].join('|');})()"
                    let transcriptScan = await evaluateSERPJSON(webView, transcriptJS)
                    let scanParts = transcriptScan.split(separator: "|").map(String.init)
                    let webMarkerInPanel = scanParts.count > 0 ? scanParts[0] : "unknown"
                    let toolLineInPanel = scanParts.count > 1 ? scanParts[1] : "unknown"
                    let transcriptChars = Int(scanParts.count > 2 ? scanParts[2] : "") ?? 0
                    // Strict in BOTH directions: the debug prefixes are gone AND
                    // the transcript is not empty (a blank panel would pass a
                    // "nothing forbidden appeared" check on its own).
                    let markerHidden = webMarkerInPanel == "no"
                        && toolLineInPanel == "no"
                        && transcriptChars > 0
                    print("MARKER_HIDDEN=\(markerHidden)")
                    print("TRANSCRIPT_WEB_MARKER_PRESENT=\(webMarkerInPanel == "yes")")
                    print("TRANSCRIPT_TOOL_LINE_PRESENT=\(toolLineInPanel == "yes")")
                    print("TRANSCRIPT_CHARS=\(transcriptChars)")
                    let markerInPanel = webMarkerInPanel == "yes" ? "yes" : "no"
                    print("WX_PROVIDER=\(chatController.lastAnsweredBy)")
                    print("WX_ASK_FIRED=\(ProviderTestSeams.shared.lastAskFired)")
                    print("WX_ANSWER=\(reply.isEmpty ? "<empty>" : reply)")
                    print("WX_ON_SCREEN=\(m.lastOnScreen)")
                    print("WX_HIT_IS_TURN=\(m.hitIsTurn)")
                    print("WX_LIVE_VALUES=\(liveTemps.map(String.init).joined(separator: ","))")
                    print("WX_REPLY_VALUES=\(replyTemps.map(String.init).joined(separator: ","))")
                    print("WX_MATCH=\(match)")
                    print("WX_MARKER_IN_PANEL=\(markerInPanel)")
                    print("WX_ACTION_LOG=\(ProviderTestSeams.shared.lastWebMarker)")
                    print("WX_TURNS=\(m.turns) WX_LAST_RECT=\(m.lastRect) WX_PAGE_SAYS=\(m.pageSays)")
                    print("WX_ELEMENT=\(m.elementFromPoint)")
                    print("WX_LAST_TEXT=\(String(m.lastText.prefix(80)))")
                    // `markerHidden` is part of the gate: the user asked for
                    // these lines NOT to be shown, so their absence is a
                    // requirement, not a nicety.
                    let gate = chatController.lastAnsweredBy.contains("AppleFMProvider")
                        && !reply.isEmpty
                        && m.lastOnScreen
                        && m.hitIsTurn
                        && match
                        && markerHidden
                    print("WX_GATE=\(gate)")
                    fflush(stdout)
                    exit(gate ? 0 : 1)
                }
            }
        }
    }

    onDeviceHardTimeout(seconds: 150, marker: "WX_HARD_TIMEOUT")
    NSApp.run()
}

/// `--test-ask-honesty`: the flight query through the REAL on-device turn.
///
/// Prints the ask text the user actually sees AND the tool's own
/// `inferredNotInQuery` from the SAME run, then extracts the parameter-like
/// tokens from each PROGRAMMATICALLY (the backticked spans Pop composes the ask
/// with) and gates that every ask token is a verbatim member of the tool's
/// list. The reviewer could not observe the model's inferred list before; this
/// closes that observability gap, so an invented value cannot pass unseen.
@MainActor
private func runAskHonestyProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    forceOnDeviceConfig()
    ProviderTestSeams.shared.availability = .available
    // Fallback OFF: the ON-DEVICE turn must be the one that produced the ask.
    ProviderTestSeams.shared.fallbackEnabled = false
    panelController.show()
    let webView = panelController.appWebView.webView

    let query = "what is the earlier flight and ticket price to china shanghai"
    print("ASK_QUERY=\(query)")
    fflush(stdout)

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        sendProbeMessage(
            webView: webView,
            chatController: chatController,
            prompt: query,
            stopOnError: false
        ) { _ in
            measureOnDevice(webView: webView) { m in
                // The canonical ask text: exactly what Pop composed and what it
                // handed to the page / recorded to the session.
                let raw = chatController.lastAnswerFull
                let shown = m.lastAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
                // PRECISION: the honest set is the caller's DECLARED slots plus
                // the page candidates offered as suggestions. The generic
                // page-entity detector is NOT part of it — that path can no
                // longer produce an ask.
                let slots = ProviderTestSeams.shared.lastDeclaredSlots
                let candidates = ProviderTestSeams.shared.lastSlotCandidates
                let askTokens = backtickTokens(in: raw)
                let fired = ProviderTestSeams.shared.lastAskFired
                // NEW SPEC: a web lookup NEVER asks before searching. The probe
                // now asserts the ask did NOT fire and that a real answer was
                // produced from the page.
                let noAsk = !fired && askTokens.isEmpty
                let answered = !shown.isEmpty
                print("ASK_DECLARED_SLOTS=\(slots.joined(separator: " | "))")
                print("ASK_MISSING_SLOTS="
                    + ProviderTestSeams.shared.lastMissingSlots.joined(separator: " | "))
                print("ASK_SLOT_CANDIDATES=\(candidates.joined(separator: " | "))")
                print("ASK_INFERRED_LOWCONF="
                    + ProviderTestSeams.shared.lastInferredNotInQuery.joined(separator: " | "))
                print("ASK_FIRED=\(fired)")
                print("ASK_MODEL_RAW=\(ProviderTestSeams.shared.lastModelTextBeforeAsk)")
                print("ASK_TEXT_RAW=\(raw)")
                print("ASK_TEXT_SHOWN=\(shown)")
                print("ASK_TOKENS=\(askTokens.joined(separator: " | "))")
                print("SLOT_AND_CANDIDATE_TOKENS="
                    + orderedUnique(slots + candidates).joined(separator: " | "))
                print("ASK_TEXT_HONEST=\(noAsk)")
                print("ASK_ANSWERED=\(answered)")
                print("ASK_WEB_MARKER=\(ProviderTestSeams.shared.lastWebMarker)")
                print("ASK_WEB_LOOKUP_CALLS=\(ProviderTestSeams.shared.webLookupCount)")
                fflush(stdout)
                exit((noAsk && answered) ? 0 : 1)
            }
        }
    }

    onDeviceHardTimeout(seconds: 180, marker: "ASK_HARD_TIMEOUT")
    NSApp.run()
}

/// The parameter-like tokens Pop marks in its deterministic ask: each value is
/// wrapped in backticks verbatim. Extracting exactly those spans is what makes
/// the honesty gate mechanical — any value the ask names that is not a member of
/// the tool's list (an invented "Beijing") shows up here as a stray token.
private func backtickTokens(in text: String) -> [String] {
    var out: [String] = []
    var search = Substring(text)
    while let open = search.firstIndex(of: "`") {
        let after = search.index(after: open)
        guard let close = search[after...].firstIndex(of: "`") else { break }
        let token = String(search[after..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { out.append(token) }
        search = search[search.index(after: close)...]
    }
    return out
}

/// Temperatures as Celsius, from `33°C`, `91°F`, `33 °C`, or a bare `33°`.
/// Fahrenheit is converted so a reply and the page can be compared.
private func temperatures(in text: String) -> [Int] {
    var out: [Int] = []
    let pattern = "(-?\\d{1,3})\\s*°\\s*([CF])?"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return out
    }
    let ns = text as NSString
    for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
        guard let value = Int(text[valueRange]) else { continue }
        var unit = "C"
        if match.range(at: 2).location != NSNotFound,
           let unitRange = Range(match.range(at: 2), in: text) {
            unit = String(text[unitRange]).uppercased()
        }
        let celsius = unit == "F" ? Int((Double(value) - 32.0) * 5.0 / 9.0) : value
        out.append(celsius)
    }
    return out
}

/// True when any reply temperature is within `tolerance` of any page
/// temperature. Empty inputs never match.
private func temperaturesMatch(_ a: [Int], _ b: [Int], tolerance: Int) -> Bool {
    guard !a.isEmpty, !b.isEmpty else { return false }
    for x in a {
        for y in b where abs(x - y) <= tolerance { return true }
    }
    return false
}

/// Tool names and outcomes seen during `--test-tool-loop`.
final class LoopCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var listDirOK = false

    func record(_ name: String, ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(name)
        if name == "list_dir" && ok { listDirOK = true }
    }

    func names() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var okListDir: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listDirOK
    }
}

/// `--set-config key=value[,key=value…]`: headless settings write.
///
/// The Settings window produced a write nobody could observe; this is the same
/// write from a terminal, so "did my settings save?" has an answer that does
/// not depend on a window being on screen. No secret is accepted or printed
/// here — the API key is `--set-key`'s job.
@MainActor
private func runSetConfig(pairs: String) {
    var config = (try? PopConfig.load()) ?? .defaults
    for pair in pairs.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            print("CONFIG_SET_REJECTED pair=\(pair) expected-key=value")
            fflush(stdout)
            continue
        }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "provider": config.provider = value
        case "model": config.model = value
        case "baseURL": config.baseURL = value
        case "temperature":
            config.temperature = Double(value) ?? config.temperature
        case "cloudThinking":
            // Config-driven cloud reasoning control (default "disabled").
            // STRICT: anything else is rejected here, so a typo cannot silently
            // become a wrong request field.
            if value == "enabled" || value == "disabled" || value == "default" {
                config.cloudThinking = value
            } else {
                print("CONFIG_SET_REJECTED pair=\(pair) cloudThinking must be enabled|disabled|default")
                fflush(stdout)
            }
        case "cloudReasoningEffort":
            // Config-driven cloud reasoning-effort control (default "low").
            // STRICT: "default" means "omit the field"; anything else is
            // rejected so a typo cannot silently become a wrong request field.
            if value == "low" || value == "medium" || value == "high" || value == "default" {
                config.cloudReasoningEffort = value
            } else {
                print("CONFIG_SET_REJECTED pair=\(pair) cloudReasoningEffort must be low|medium|high|default")
                fflush(stdout)
            }
        case "pcc":
            config.pcc = (value == "true" || value == "1")
        case "buzzEnabled":
            // Same `true`/`1` affordance as `pcc`: the hover buzz is opt-in, so
            // an explicit true is required to turn it on.
            config.buzzEnabled = (value == "true" || value == "1")
        case "buzzVolume":
            config.buzzVolume = Double(value) ?? config.buzzVolume
        case "jevEnabled":
            // Opt-in advisory service: explicit true required, like `pcc`.
            config.jevEnabled = (value == "true" || value == "1")
        case "jevEndpoint": config.jevEndpoint = value
        case "jevModel": config.jevModel = value
        case "jevThreshold":
            config.jevThreshold = Double(value) ?? config.jevThreshold
        case "autoRunScreenActions":
            // Standing approval for reversible screen acts (default true). Same
            // `true`/`1` affordance as `pcc`/`buzzEnabled`.
            config.autoRunScreenActions = (value == "true" || value == "1")
        case "headers":
            // `~` separates lines, not `,`: commas are legal inside header
            // values, and a header value often contains colons too, so each
            // pair splits on its FIRST colon.
            var parsed: [String: String] = [:]
            for line in value.split(separator: "~") {
                let entry = line.trimmingCharacters(in: .whitespaces)
                if entry.isEmpty { continue }
                guard let colon = entry.firstIndex(of: ":") else {
                    print("CONFIG_SET_REJECTED pair=\(entry) expected-Name:Value")
                    fflush(stdout)
                    continue
                }
                let name = entry[entry.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                let headerValue = entry[entry.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !headerValue.isEmpty { parsed[name] = headerValue }
            }
            config.headers = parsed
        default:
            print("CONFIG_SET_REJECTED pair=\(pair) unknown-key")
            fflush(stdout)
        }
    }

    do {
        try config.write()
        print("CONFIG_SAVED provider=\(config.provider) model=\(config.model) baseURL=\(config.baseURL) buzz=\(config.buzzEnabled) vol=\(config.buzzVolume)")
        fflush(stdout)
        exit(0)
    } catch {
        print("CONFIG_SAVE_FAILED \(error)")
        fflush(stdout)
        exit(1)
    }
}

/// `--set-key <secret>`: writes the Keychain item for the current provider.
///
/// The secret itself is NEVER printed — only whether the write succeeded. The
/// account IS printed, because a key written against the wrong provider account
/// is a real failure mode that is otherwise invisible.
@MainActor
private func runSetKey(secret: String) {
    let config = (try? PopConfig.load()) ?? .defaults
    let ok: Bool
    switch KeychainStore.setAPIKey(secret, for: config.provider) {
    case .success: ok = true
    case .failure: ok = false
    }
    print("KEYCHAIN_SAVED account=\(config.provider) ok=\(ok)")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

/// `--test-settings-roundtrip`: prove a written config reads back IDENTICAL, and
/// prove the base URL joins to exactly one `/chat/completions`.
///
/// Both halves existed only inside the Settings window and the request builder
/// respectively, so neither could be checked without a human watching a form.
/// Runs entirely against `POP_CONFIG_PATH` (defaults to a temp file), makes no
/// network call, and deletes its temp file on the way out.
@MainActor
private func runSettingsRoundtripProbe() {
    let tempPath: String
    if let override = ProcessInfo.processInfo.environment["POP_CONFIG_PATH"], !override.isEmpty {
        tempPath = override
    } else {
        tempPath = NSTemporaryDirectory() + "pop-settings-roundtrip-\(UUID().uuidString).json"
    }
    // The env var must be set BEFORE `PopConfig.configURL` is read.
    setenv("POP_CONFIG_PATH", tempPath, 1)

    func cleanup() {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    var config = (try? PopConfig.load()) ?? .defaults
    config.provider = "openai-compat"
    config.model = "glm-5.3-flash"
    // A trailing slash on purpose: this is the input that used to double up.
    config.baseURL = "https://example.invalid/v1/"
    do {
        try config.write()
    } catch {
        print("ROUNDTRIP_WRITE_FAILED \(error)")
        fflush(stdout)
        cleanup()
        exit(1)
    }

    // Reload from DISK, not from the struct we just wrote: a serializer that
    // drops a field would otherwise read back fine from memory.
    guard let reloaded = try? PopConfig.load() else {
        print("ROUNDTRIP_RELOAD_FAILED")
        fflush(stdout)
        cleanup()
        exit(1)
    }
    print("ROUNDTRIP provider=\(reloaded.provider) model=\(reloaded.model) baseURL=\(reloaded.baseURL)")
    fflush(stdout)

    let joined = OpenAICompatProvider.chatCompletionsURL(baseURL: reloaded.baseURL)
    print("ROUNDTRIP_URL=\(joined?.absoluteString ?? "INVALID")")
    fflush(stdout)

    cleanup()
    exit(0)
}

/// `--test-error-recovery`: proves a FAILED send leaves the composer usable.
///
/// The wedge this reproduces was reported as "I send hi, nothing comes back,
/// and then nothing ever works again" — one STREAM_START and no second send
/// ever reaching the bridge. This probe points Pop at an unreachable endpoint
/// (port 9, discarded) so the first send fails, then checks the page is
/// unstuck and that a second send actually reaches Swift.
@MainActor
private func runErrorRecoveryProbe(
    panelController: PanelController,
    chatController: ChatController
) {
    // Set BEFORE any send: `PopConfig.load()` runs per request, so the failing
    // transport is picked up without disturbing the user's real config.
    let tempPath = NSTemporaryDirectory() + "pop-error-recovery-\(UUID().uuidString).json"
    setenv("POP_CONFIG_PATH", tempPath, 1)
    let failing = PopConfig(
        provider: "openai-compat",
        model: "probe-err",
        baseURL: "http://127.0.0.1:9/v1",
        temperature: 0.7,
        cloudThinking: "disabled",
        cloudReasoningEffort: "low",
        pcc: false,
        contextMode: false,
        allowExternalPaths: false,
        defaultCity: "",
        headers: [:],
        buzzEnabled: false,
        buzzVolume: 0.7,
        jevEnabled: false,
        jevEndpoint: "",
        jevModel: "",
        jevThreshold: 0.7,
        autoRunScreenActions: true
    )
    try? failing.write()

    let webView = panelController.appWebView.webView
    var sendCount = 0
    // Count what actually ARRIVES at Swift: a wedged page never gets here, which
    // is exactly the failure being tested.
    let existing = panelController.appWebView.onBridgeMessage
    panelController.appWebView.onBridgeMessage = { type, body in
        if type == "chatSend" { sendCount += 1 }
        existing?(type, body)
    }

    var printedSnippet = false

    func cleanup() {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func send(_ text: String) {
        // The separator must be a real statement terminator. The earlier version
    // interpolated a literal `+ ';'` (a Swift-level string splice) with no
    // trailing separator, producing `... = "x" + ';'document.getElementById(`,
    // which is a SYNTAX error — every send died before it reached the page and
    // the gate measured nothing. Print the exact string once so that failure
    // mode can never be silent again.
    let js = "document.getElementById('input').value = \(jsString(text));"
        + "document.getElementById('composer').dispatchEvent("
        + "new Event('submit', {cancelable: true}));"
    if !printedSnippet {
        printedSnippet = true
        print("PROBE_JS_SNIPPET \(js.prefix(300))")
        fflush(stdout)
    }
    webView.evaluateJavaScript(js) { _, error in
        if let error {
            print("LIVE_SEND_ERROR \(error.localizedDescription)")
            fflush(stdout)
        }
    }
}

    panelController.show()

    // First send: expected to fail at the transport.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { send("hello") }

    DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) {
        // Usability after the failure: not in stop mode, input not disabled,
        // and the page's own streaming flag is false.
        let js = "(function () {"
            + "var stopHidden = !document.getElementById('stop')"
            + " || document.getElementById('stop').hidden;"
            + "var inputOk = !document.getElementById('input').disabled;"
            + "return stopHidden && inputOk && streaming === false;"
            + "})()"
        webView.evaluateJavaScript(js) { value, _ in
            let recovered = (value as? Bool) == true
            print("UI_RECOVERED=\(recovered)")
            fflush(stdout)

            // Second send through the SAME real UI path.
            let before = sendCount
            send("hello again")

            let deadline = Date().addingTimeInterval(20)
            func poll() {
                if sendCount > before {
                    print("LIVE_SECOND_SEND=true")
                    fflush(stdout)
                    // Inline rather than calling `cleanup()`: this closure is
                    // nonisolated, and the local function is main-actor bound.
                    try? FileManager.default.removeItem(atPath: tempPath)
                    exit(0)
                }
                if Date() >= deadline {
                    print("LIVE_SECOND_SEND=false")
                    fflush(stdout)
                    try? FileManager.default.removeItem(atPath: tempPath)
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
        print("UI_RECOVERED=false")
        print("LIVE_SECOND_SEND=false")
        fflush(stdout)
        cleanup()
        exit(1)
    }

    NSApp.run()
}

/// `--test-robot-anchor`: measures the ROBOT, not the window.
///
/// The window-level anchor probe already passed while the robot still slid,
/// because the robot is a SUBVIEW whose inset from the window's top-left
/// changed with state. So this measures the robot's absolute SCREEN frame — the
/// thing the user actually looks at — and requires it to be identical across
/// every state.
///
/// Method: `robotView.convert(robotView.bounds, to: nil)` converts the view's
/// bounds into WINDOW coordinates, then the window's `frame.origin` is added.
/// Cocoa screen coordinates put the origin at the screen's BOTTOM-left, so
/// `y` here is a bottom-left-origin screen Y — directly comparable across
/// samples, which is all the invariant needs.
///
/// No network: `full` is reached directly rather than by sending.
@MainActor
private func runRobotAnchorProbe(_ panelController: PanelController) {
    var samples: [CGRect] = []
    var centered: [Bool] = []

    func sample() {
        guard let robot = panelController.robotViewForTesting else {
            print("ROBOT_MISSING state=\(panelController.state.rawValue)")
            fflush(stdout)
            return
        }
        let inWindow = robot.convert(robot.bounds, to: nil)
        let screen = CGRect(
            x: panelController.panel.frame.origin.x + inWindow.origin.x,
            y: panelController.panel.frame.origin.y + inWindow.origin.y,
            width: inWindow.width,
            height: inWindow.height
        )
        samples.append(screen)
        let barCenter = panelController.panel.frame.midX
        let robotCenter = screen.midX
        centered.append(abs(barCenter - robotCenter) <= 1)
        print(
            "ROBOT state=\(panelController.state.rawValue)"
                + " x=\(Int(screen.origin.x)) y=\(Int(screen.origin.y))"
                + " w=\(Int(screen.width)) h=\(Int(screen.height))"
                + " barCenterX=\(Int(barCenter)) robotCenterX=\(Int(robotCenter))"
        )
        fflush(stdout)
    }

    // Sample after the 0.2s animation and the model-layer commit have landed,
    // or the frame read would be mid-flight.
    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            sample()
            body()
        }
    }

    func finish() {
        guard let first = samples.first, !samples.isEmpty else {
            print("ROBOT_RESULT stable=false centered=false")
            fflush(stdout)
            exit(1)
        }
        let stable = samples.allSatisfy {
            $0.origin == first.origin && $0.size == first.size
        }
        // Centring only means something where there IS a bar: in `mascot` the
        // robot IS the window, so the two centres coincide trivially. Every
        // sample is checked, so a `bar`/`full` sample that fails shows up.
        let isCentered = centered.allSatisfy { $0 }
        print("ROBOT_RESULT stable=\(stable) centered=\(isCentered)")
        fflush(stdout)
        exit(stable && isCentered ? 0 : 1)
    }

    after(2.0) {
        panelController.toggle()      // mascot -> bar
        after(1.0) {
            panelController.toggle()  // bar -> mascot
            after(1.0) {
                panelController.toggle()  // mascot -> bar
                after(1.0) {
                    panelController.setPanelState(.full, animated: false)
                    after(1.0) { finish() }
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
        print("ROBOT_RESULT stable=false centered=false")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-mascot-arc`: proves the electric arc's geometry AND its PIXELS,
/// WITHOUT any clicking or human eyes.
///
/// Geometry is necessary but not sufficient: an effect can be laid out inside
/// the window and still not PAINT (opacity gate, z-order, occlusion). So the
/// probe rasterizes the robot hosting view and COUNTS bright cyan/white pixels
/// inside the arc's own reported rect, once per state. `MascotView` reports the
/// arc's frame into `MascotModel.arcFrame`.
@MainActor
private func runMascotArcProbe(_ panelController: PanelController) {
    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    /// Geometry report for context: frame, window, and whether it is contained.
    func reportGeometry(_ state: MascotState, envShouldShow: Bool) {
        let arc = panelController.mascotModel.arcFrame
        let window = panelController.panel.frame
        // `.global` is the WINDOW's coordinate space (top-left), NOT screen.
        let inside = arc.minX >= 0 && arc.minY >= 0
            && arc.maxX <= window.width && arc.maxY <= window.height
        print("ARC_TEST state=\(state.rawValue)")
        print("ARC_FRAME=(\(Int(arc.origin.x)),\(Int(arc.origin.y)),\(Int(arc.width)),\(Int(arc.height)))")
        print("WINDOW_FRAME=(\(Int(window.origin.x)),\(Int(window.origin.y)),\(Int(window.width)),\(Int(window.height)))")
        print("ARC_INSIDE_WINDOW=\(inside)")
        print("ARC_ENV_SHOULD_SHOW=\(envShouldShow)")
        fflush(stdout)
    }

    /// Rasterize the robot hosting view and find ARC-LIKE pixels across the
    /// WHOLE view. "Arc-like" = bright cyan-hot: `r > 150 && g > 200 && b > 150 &&
    /// b - r >= 12`. `g > 200` separates the energized hardware (antennaHot
    /// #EAF7FF, g=247) from the AT-REST antenna tips (antennaRest #8FB4F0, g=180)
    /// and from the face's pure-white chevrons (b-r=0) and the palette blues
    /// (headTop #5B9BFF, r=91). Scanning the whole host (not just the reported
    /// rect) keeps the measurement independent of the frame conversion, and the
    /// bbox shows WHERE any cyan-hot actually painted. Returns (-1, nil) on fail.
    func brightCyan() -> (count: Int, box: NSRect?) {
        guard let host = panelController.robotViewForTesting else { return (-1, nil) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (-1, nil) }
        host.cacheDisplay(in: host.bounds, to: rep)

        var count = 0
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y),
                      let s = c.usingColorSpace(.deviceRGB) ?? c.usingColorSpace(.sRGB)
                else { continue }
                let r = Int(s.redComponent * 255)
                let g = Int(s.greenComponent * 255)
                let b = Int(s.blueComponent * 255)
                if r > 150 && g > 200 && b > 150 && b - r >= 12 {
                    count += 1
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return (count, nil) }
        // Report the box in POINTS (divide by the backing scale).
        let scaleX = CGFloat(rep.pixelsWide) / max(host.bounds.width, 1)
        let scaleY = CGFloat(rep.pixelsHigh) / max(host.bounds.height, 1)
        let box = NSRect(
            x: CGFloat(minX) / scaleX,
            y: CGFloat(minY) / scaleY,
            width: CGFloat(maxX - minX + 1) / scaleX,
            height: CGFloat(maxY - minY + 1) / scaleY
        )
        return (count, box)
    }

    /// Print a labelled bright-cyan measurement (count + where it painted).
    func printBright(_ label: String) {
        let (count, box) = brightCyan()
        let boxText = box.map {
            "(\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)),\(Int($0.height)))"
        } ?? "none"
        print("ARC_PIXELS_\(label)=\(count)")
        print("ARC_BBOX_\(label)=\(boxText)")
        fflush(stdout)
    }

    panelController.show()
    after(1.0) {
        panelController.setPanelState(.mascot, animated: false)
        after(0.4) {
            // 1) thinking, hover OFF: the arc should be energized AND painted.
            panelController.mascotModel.isHovered = false
            panelController.mascotModel.state = .thinking
            after(0.6) {
                reportGeometry(.thinking, envShouldShow: true)
                printBright("THINKING")

                // 2) thinking, hover ON: the user's occlusion hypothesis — if the
                //    hover layer covers the arc, this count drops vs thinking.
                panelController.mascotModel.isHovered = true
                after(0.4) {
                    printBright("THINKING_HOVER")

                    // 3) idle, hover OFF: state-gated, expect ~0.
                    panelController.mascotModel.isHovered = false
                    panelController.mascotModel.state = .idle
                    after(0.6) {
                        reportGeometry(.idle, envShouldShow: false)
                        printBright("IDLE")
                        exit(0)
                    }
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(1) }

    NSApp.run()
}

/// `--test-hover-pill`: verifies the hover toolbar's real-button row is present,
/// in the window's bottom band, and built from exactly three buttons.
///
/// The toolbar is now REAL SwiftUI `Button`s in a capsule — the platform owns
/// hit-testing, so there is no custom hit table to assert. This checks what a
/// headless probe honestly can: the row's drawn rect (`toolbarRowFrame`) sits in
/// the bottom pill band and the row drew 3 buttons. The synthesized CGEvent arm
/// is SKIPPED: this session's window server does not deliver synthetic HID
/// clicks to this `.nonactivatingPanel` (proven earlier), so asserting delivery
/// would test the environment, not the component.
@MainActor
private func runHoverPillProbe(_ panelController: PanelController) {
    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    panelController.show()
    after(1.2) {
        panelController.setPanelState(.mascot, animated: false)
        panelController.mascotModel.isHovered = true
        after(0.6) {
            let window = panelController.panel.frame
            let row = panelController.mascotModel.toolbarRowFrame
            print("PILL_ROW_FRAME=(\(Int(row.minX)),\(Int(row.minY)),\(Int(row.width)),\(Int(row.height)))"
                + " windowH=\(Int(window.height))")
            // The bottom band spans [windowH - pillBandHeight, windowH].
            let bottomStart = window.height - PanelHeadroom.pillBandHeight
            let inBottom = row.minY >= bottomStart - 1 && row.maxY <= window.height + 1
            print("PILL_ROW_IN_WINDOW_BOTTOM=\(inBottom)")
            let count = panelController.mascotModel.toolbarButtonCount
            print("PILL_BUTTONS=\(count)")
            print("PILL_SYNTHCLICK=SKIPPED (real SwiftUI buttons own hit-testing; synthetic HID not delivered here)")
            fflush(stdout)
            exit(inBottom && count == 3 ? 0 : 1)
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        print("PILL_ROW_FRAME=(0,0,0,0) windowH=0")
        print("PILL_ROW_IN_WINDOW_BOTTOM=false")
        print("PILL_BUTTONS=0")
        print("PILL_SYNTHCLICK=SKIPPED (timeout)")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-composer-toggle`: the robot click must TOGGLE the composer surface.
///
/// Drives `PanelController.toggleComposer()` from `mascot` and asserts the state
/// sequence `bar` → `mascot` (the symmetry the user reported missing: a click
/// opened the composer but nothing closed it). Headless — no event delivery.
@MainActor
private func runComposerToggleProbe(_ panelController: PanelController) {
    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    panelController.show()
    after(1.2) {
        panelController.setPanelState(.mascot, animated: false)
        after(0.4) {
            panelController.toggleComposer()
            after(0.3) {
                let step1 = panelController.state.rawValue
                print("COMPOSER_TOGGLE step=1 state=\(step1)")
                fflush(stdout)
                panelController.toggleComposer()
                after(0.3) {
                    let step2 = panelController.state.rawValue
                    print("COMPOSER_TOGGLE step=2 state=\(step2)")
                    let ok = step1 == "bar" && step2 == "mascot"
                    print("COMPOSER_TOGGLE ok=\(ok)")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        print("COMPOSER_TOGGLE ok=false (timeout)")
        exit(1)
    }

    NSApp.run()
}

/// `--test-speech`: verifies the voice feature's HEADLESS-VERIFIABLE surface and
/// SKIPS what a probe cannot honestly test.
///
/// It prints the installed TTS voices, whether an en-US voice exists, whether an
/// en-US recognizer supports ON-DEVICE recognition, and both TCC authorization
/// states, then runs a real TTS round-trip. LIVE STT CAPTURE IS SKIPPED on
/// purpose: it needs a microphone and an interactive permission prompt, which a
/// headless probe cannot supply — drive it by hand in the bundled app (the
/// Settings "Speak replies aloud" toggle plus the composer's mic button).
@MainActor
private func runSpeechProbe() {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    print("SPEECH_TTS_VOICES=\(voices.count)")
    print("SPEECH_TTS_EN_US=\(voices.contains { $0.language == "en-US" })")

    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    print("SPEECH_RECOGNIZER_ONDEVICE=\(recognizer?.supportsOnDeviceRecognition == true)")
    print("SPEECH_AUTH_SPEECH=\(speechAuthLabel(SFSpeechRecognizer.authorizationStatus()))")
    print("SPEECH_AUTH_MIC=\(micAuthLabel(AVCaptureDevice.authorizationStatus(for: .audio)))")
    print("SPEECH_STT_SKIPPED=headless")
    fflush(stdout)

    // TTS ROUND-TRIP, through the REAL `SpeechSynth` (not a bespoke
    // synthesizer), so this probe exercises the production speak/completion
    // path — including the generation-identity and watchdog logic. The synth is
    // captured by the timeout closure so it outlives this function.
    let synth = SpeechSynth()
    var finished = false
    synth.speak("Pop voice check") {
        guard !finished else { return }
        finished = true
        print("SPEECH_TTS_ROUNDTRIP=ok")
        fflush(stdout)
        exit(0)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        _ = synth
        guard !finished else { return }
        finished = true
        print("SPEECH_TTS_ROUNDTRIP=timeout")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

private func speechAuthLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

private func micAuthLabel(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

/// `--test-persistence`: the robot comes back where the user left it.
///
/// The regression this proves fixed: `frameDefaultsKey` persisted the WINDOW
/// origin, but under centring that origin is state-dependent, so a frame stored
/// while the composer was up restored the launcher one inset to the LEFT of the
/// robot — "it just destroy mascot last position".
///
/// Method: the run drives `bar` and back to `mascot` (no network), reads the
/// robot's absolute screen frame, and prints it. `PanelController.anchorWasRestored`
/// says whether that position came from disk or from the first-launch default, so
/// the FIRST invocation prints `PERSIST_ANCHOR` and the SECOND — reading what the
/// first wrote — prints `PERSIST_RESTORED`. The two coordinates matching is the
/// gate.
///
/// Storage: the REAL `UserDefaults.standard` anchor key, the same one production
/// uses, so the probe measures the shipping persistence path rather than a
/// parallel one.
@MainActor
private func runPersistenceProbe(_ panelController: PanelController) {
    func sample() -> NSPoint? {
        guard let robot = panelController.robotViewForTesting else { return nil }
        let inWindow = robot.convert(robot.bounds, to: nil)
        return NSPoint(
            x: panelController.panel.frame.origin.x + inWindow.origin.x,
            y: panelController.panel.frame.origin.y + inWindow.origin.y
        )
    }

    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    func finish() {
        guard let origin = sample() else {
            print("PERSIST_MISSING")
            fflush(stdout)
            exit(1)
        }
        let marker = panelController.anchorWasRestored ? "PERSIST_RESTORED" : "PERSIST_ANCHOR"
        print("\(marker) x=\(Int(origin.x)) y=\(Int(origin.y))")
        fflush(stdout)
        exit(0)
    }

    // The toggle pair is the point: the window origin MOVES between these states,
    // so if the anchor were still window-derived the mascot would not come back.
    after(2.0) {
        panelController.setPanelState(.bar, animated: false)
        after(1.0) {
            panelController.setPanelState(.mascot, animated: false)
            after(1.0) { finish() }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        print("PERSIST_MISSING")
        fflush(stdout)
        exit(1)
    }

    NSApp.run()
}

/// `--test-robot-drag`: a ROBOT drag must update the remembered anchor.
///
/// The regression: the robot's drag moved the window inside `MascotHostingView`
/// and never told `PanelController`, so the anchor stayed at the PREVIOUS
/// position and the next state change snapped the robot back. The composer bar's
/// drag never had this bug — it reports its gesture and the controller re-derives
/// at drag end.
///
/// The probe reproduces the gesture exactly as it happens: move the window by a
/// known delta, then post `popRobotDragEnd` (the notification a real drag end
/// takes). The gate is that `setPanelState(.bar)` afterwards leaves the robot
/// where the drag put it.
///
/// Storage: the ISOLATED probe suite, never `UserDefaults.standard`.
@MainActor
private func runRobotDragProbe(_ panelController: PanelController) {
    // ONE convention in every state: the HOSTING VIEW's top-left in screen
    // coordinates. The view's bounds are converted to WINDOW coordinates (nil),
    // then the window origin is added. Measuring the hosting view rather than
    // the SwiftUI drawing keeps the number comparable across states — the
    // drawing is 88pt tall inside a 110pt view, so its bounds shift with state
    // while the hosting view's frame does not.
    func robotOrigin() -> NSPoint? {
        guard let robot = panelController.robotViewForTesting else { return nil }
        let robotTopLeft = robot.convert(robot.bounds, to: nil)
        return NSPoint(
            x: panelController.panel.frame.origin.x + robotTopLeft.origin.x,
            y: panelController.panel.frame.origin.y + robotTopLeft.origin.y
        )
    }

    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    func fail() -> Never {
        print("DRAG_RESULT stable=false")
        fflush(stdout)
        exit(1)
    }

    // Park the robot in the MIDDLE of the screen first: `bar` needs 214pt of
    // window BELOW the robot, so a low position would make the deliberate
    // on-screen clamp in `setPanelState` engage and the measurement would report
    // that intended settle as instability. Room below is what makes the gate a
    // pure test of the anchor.
    let visible = NSScreen.main?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    panelController.panel.setFrameOrigin(
        NSPoint(x: visible.midX - 320, y: visible.midY)
    )

    after(2.0) {
        guard let before = robotOrigin() else { fail() }
        print("DRAG_BEFORE state=\(panelController.state.rawValue) x=\(Int(before.x)) y=\(Int(before.y))")
        fflush(stdout)

        // Exactly what `mouseDragged` does, then exactly what `mouseUp` does.
        // UPWARD (+90 in Cocoa) so the robot keeps room for the composer.
        let frame = panelController.panel.frame
        panelController.panel.setFrameOrigin(
            NSPoint(x: frame.origin.x + 140, y: frame.origin.y + 90)
        )
        NotificationCenter.default.post(name: .popRobotDragEnd, object: nil)

        after(1.0) {
            guard let afterDrag = robotOrigin() else { fail() }
            print("DRAG_AFTER_DRAG state=\(panelController.state.rawValue) x=\(Int(afterDrag.x)) y=\(Int(afterDrag.y))")
            fflush(stdout)

            panelController.setPanelState(.bar, animated: false)
            after(1.0) {
                guard let afterToggle = robotOrigin() else { fail() }
                print("DRAG_AFTER_TOGGLE state=\(panelController.state.rawValue) x=\(Int(afterToggle.x)) y=\(Int(afterToggle.y))")
                fflush(stdout)
                let stable = abs(afterToggle.x - afterDrag.x) <= 1
                    && abs(afterToggle.y - afterDrag.y) <= 1

                // DOCUMENTATION, NOT A GATE. The robot is parked 24pt from the
                // bottom, so `bar` cannot fit below it and `setPanelState`'s
                // clamp MUST move it — re-deriving the anchor from the settled
                // frame is exactly the designed one-time settle. Reported so the
                // behaviour is on the record rather than looking like a bug.
                let parked = robotOrigin()
                let parkFrame = panelController.panel.frame
                panelController.panel.setFrameOrigin(
                    NSPoint(x: parkFrame.origin.x, y: visible.minY + 24)
                )
                panelController.setPanelState(.mascot, animated: false)
                // A real drag publishes its own anchor at drag end; without that
                // the toggle would snap the robot back to the mid-screen anchor
                // and no clamp would ever engage.
                panelController.panel.setFrameOrigin(
                    NSPoint(x: panelController.panel.frame.origin.x, y: visible.minY + 24)
                )
                NotificationCenter.default.post(name: .popRobotDragEnd, object: nil)
                let beforeClamp = robotOrigin() ?? parked ?? .zero
                panelController.setPanelState(.bar, animated: false)
                after(0.6) {
                    let afterClamp = robotOrigin() ?? beforeClamp
                    print(
                        "CLAMP_EXPECTED robotMoved=\(abs(afterClamp.y - beforeClamp.y) > 1)"
                            + " beforeY=\(Int(beforeClamp.y)) afterY=\(Int(afterClamp.y))"
                    )
                    fflush(stdout)

                    print("DRAG_RESULT stable=\(stable)")
                    fflush(stdout)
                    exit(stable ? 0 : 1)
                }
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 24) { fail() }

    NSApp.run()
}

/// Reads the single string argument that follows a flag.
private func singleValueProbeArgument(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    let next = CommandLine.arguments.index(after: index)
    guard next < CommandLine.arguments.endIndex else { return "" }
    return CommandLine.arguments[next]
}

/// Splits a comma/semicolon/pipe-delimited probe value into trimmed, non-empty
/// items. Probe-only helper; never used by the product.
private func splitProbeList(_ value: String) -> [String] {
    value.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Stable de-duplication preserving first-seen order.
private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for value in values where seen.insert(value).inserted { out.append(value) }
    return out
}

/// JSON-encodes a Swift string for embedding in evaluated JavaScript.
private func jsString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let array = String(data: data, encoding: .utf8),
          array.count >= 2
    else {
        return "\"\""
    }
    return String(array.dropFirst().dropLast())
}

/// Probe-v3: exercises the REAL Carbon hotkey handler path (no `show()` call
/// anywhere below) so the summon comes from a synthesized system keypress
/// exactly as a human press would. `--test-focus` cannot distinguish this path
/// from the launch-time show path; this mode does.
@MainActor
private func runHotkeyProbe(_ panelController: PanelController) {
    // +2.0s: synthesize the registered hotkey (option+space, kVK_Space = 49)
    // through the HID event tap so Carbon's RegisterEventHotKey callback is
    // the thing that summons the panel.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        postHotkeySimulatedKeyPress()
        print("HOTKEY_SIMULATED")
        fflush(stdout)
    }

    // +3.0s: did the handler actually toggle the panel, and can it type?
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        print("PROBE_PANEL_VISIBLE=\(panelController.isVisible)")
        fflush(stdout)
        typeStringViaCGEvent("hi")
        print("PROBE_TYPED_SENT")
        fflush(stdout)
    }

    // +4.0s: read what the field actually holds.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        let panel = panelController.panel
        let js = "document.querySelector('input,textarea') ? document.querySelector('input,textarea').value : 'NO_FIELD'"
        panelController.appWebView.webView.evaluateJavaScript(js) { result, error in
            let value: String
            if let result = result as? String {
                value = result
            } else if let error = error {
                value = "JS_ERROR(\(error.localizedDescription))"
            } else {
                value = "NIL_RESULT"
            }
            print("PROBE_HOTKEY_VALUE=\(value)")
            print("PROBE_STATE active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
            fflush(stdout)
            exit(0)
        }
    }

    NSApp.run()
}

/// Posts an option+space keyDown/keyUp pair as the OS would deliver it, so
/// Carbon's global hotkey sees it as a genuine user press.
@MainActor
private func postHotkeySimulatedKeyPress() {
    let spaceVK: CGKeyCode = 49   // kVK_Space
    let source = CGEventSource(stateID: .combinedSessionState)

    if let down = CGEvent(keyboardEventSource: source, virtualKey: spaceVK, keyDown: true) {
        down.flags = .maskAlternate
        down.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.03)
    if let up = CGEvent(keyboardEventSource: source, virtualKey: spaceVK, keyDown: false) {
        up.flags = []
        up.post(tap: .cghidEventTap)
    }
}

/// Headless probe: does `makeKeyAndOrderFront` on this panel actually grant
/// key status on this host at all, independent of any real click?
@MainActor
private func runFocusProbe(_ panelController: PanelController) {
    panelController.show()

    // +1.5s: synthesize real system keystrokes so the probe observes ACTUAL
    // key-event delivery, not just AppKit's self-reported key state. Unicode
    // events are layout-independent, so no kVK mapping is needed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        typeStringViaCGEvent("hi")
        print("PROBE_TYPED_SENT")
        fflush(stdout)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        NSApp.activate()
        panelController.panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            print("FOCUS_TEST isKeyWindow=\(panelController.panel.isKeyWindow) frontmost=\(frontmostBundleID)")
            fflush(stdout)

            let panel = panelController.panel
            let js = "document.querySelector('input,textarea') ? document.querySelector('input,textarea').value : 'NO_FIELD'"
            panelController.appWebView.webView.evaluateJavaScript(js) { result, error in
                let value: String
                if let result = result as? String {
                    value = result
                } else if let error = error {
                    value = "JS_ERROR(\(error.localizedDescription))"
                } else {
                    value = "NIL_RESULT"
                }
                print("PROBE_TYPED_VALUE=\(value)")
                print("PROBE_STATE active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
                fflush(stdout)
                exit(0)
            }
        }
    }

    // The probe's timers are main-queue blocks: they only drain once AppKit's
    // run loop is running, so bootstrap must hand control over before returning.
    NSApp.run()
}

/// Posts each character as a real system key down/up through the HID event tap.
/// Deliberately not `CGEvent.postToPid`/`sendEvent`: the question is whether the
/// window server routes keystrokes to this key window, so the event must go
/// through the system the same way a physical keyboard would.
@MainActor
private func typeStringViaCGEvent(_ string: String) {
    for character in string {
        let units = Array(String(character).utf16)

        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
                virtualKey: 0,
                keyDown: isDown
            ) else { continue }
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }

        // 30 ms between keys: long enough that a dropped/coalesced pair is
        // visible in the measured value, short enough to stay inside the probe.
        Thread.sleep(forTimeInterval: 0.03)
    }
}

// MARK: - Stream-timeout / friendly-error / fallback-carry probes

/// Records every message array a scripted provider was handed, so a probe can
/// inspect the actual outbound payload (the fallback-carry gate).
final class ScriptedProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[ChatMessage]] = []
    var requests: [[ChatMessage]] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }
    func record(_ messages: [ChatMessage]) {
        lock.lock(); _requests.append(messages); lock.unlock()
    }
}

/// A provider whose stream is a closure. Drives the real `handleChatSend` path
/// deterministically: silence, a scripted answer, or a scripted throw.
struct ScriptedProvider: ModelProvider {
    let isHealthy = true
    let unhealthyReason = ""
    let nativelyExecutesTools: Bool
    let box: ScriptedProviderBox
    let script: @Sendable (
        [ChatMessage],
        (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error>

    var executesToolsNatively: Bool { nativelyExecutesTools }

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        box.record(messages)
        return script(messages, activity)
    }
}

/// A fast-forwarding clock: each read advances by `step`. A probe reaches 60s or
/// 180s of "idle" in a handful of 100ms polls instead of a real sleep.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    private let step: TimeInterval
    init(start: TimeInterval = 0, step: TimeInterval) {
        self.t = start
        self.step = step
    }
    func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        t += step
        return Date(timeIntervalSince1970: t)
    }
}

/// A scripted error with NO usable description — the shape whose raw debug
/// string was leaking into the transcript.
struct EmptyDescError: Error {}

@MainActor
private func makeProbeChatController() -> ChatController {
    var config = PopConfig.defaults
    config.contextMode = false
    let frozen = config
    return ChatController(webViewProvider: { nil }, configProvider: { frozen })
}

@MainActor
private func waitForTurnToSettle(_ controller: ChatController, seconds: Double) async {
    let deadline = Date().addingTimeInterval(seconds)
    while controller.probeIsStreaming && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    // Give a settled turn's final MainActor hop a beat to land.
    try? await Task.sleep(for: .milliseconds(50))
}

/// `--test-stream-timeout`: the idle policy. A provider silent for >60s virtual
/// then answering COMPLETES (the old total cap would have killed it); a provider
/// silent past the configured cap ABORTS and renders a HUMAN line.
private func runStreamTimeoutProbe() {
    _ = NSApplication.shared
    Task { @MainActor in
        // Gate 1 — LENIENT: intermittent tokens run as long as they need.
        setenv("POP_STREAM_TIMEOUT_SECS", "100000", 1)
        let lenientClock = VirtualClock(step: 20)
        let lenient = ScriptedProvider(
            nativelyExecutesTools: false,
            box: ScriptedProviderBox()
        ) { _, _ in
            AsyncThrowingStream { continuation in
                Task {
                    // A real 400ms is >60s on the virtual clock.
                    try? await Task.sleep(for: .milliseconds(400))
                    continuation.yield(.delta("late but alive"))
                    continuation.yield(.done("late but alive"))
                    continuation.finish()
                }
            }
        }
        ProviderTestSeams.shared.primaryProviderOverride = lenient
        ProviderTestSeams.shared.fallbackProviderOverride = nil
        ProviderTestSeams.shared.streamClock = { lenientClock.next() }
        let c1 = makeProbeChatController()
        c1.handleBridgeMessage(type: "chatSend", body: ["text": "stay alive"])
        await waitForTurnToSettle(c1, seconds: 15)
        let lenientOK = c1.lastAnswerFull == "late but alive"
        print("TIMEOUT_LENIENT=\(lenientOK)")
        fflush(stdout)

        // Gate 2 — ABORT: silence beyond the cap aborts with a human line.
        setenv("POP_STREAM_TIMEOUT_SECS", "180", 1)
        let abortClock = VirtualClock(step: 80)
        let silent = ScriptedProvider(
            nativelyExecutesTools: false,
            box: ScriptedProviderBox()
        ) { _, _ in
            AsyncThrowingStream { continuation in
                Task {
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish()
                }
            }
        }
        ProviderTestSeams.shared.primaryProviderOverride = silent
        ProviderTestSeams.shared.fallbackProviderOverride = nil
        ProviderTestSeams.shared.streamClock = { abortClock.next() }
        let c2 = makeProbeChatController()
        c2.handleBridgeMessage(type: "chatSend", body: ["text": "go silent"])
        await waitForTurnToSettle(c2, seconds: 15)
        let human = c2.lastErrorText.contains("ran out of time")
            && !ChatController.looksLikeRawErrorDebug(c2.lastErrorText)
        print("TIMEOUT_ABORT_HUMAN_TEXT=\(human)")
        print("TIMEOUT_ABORT_TEXT=\(c2.lastErrorText)")
        fflush(stdout)
        exit((lenientOK && human) ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
        print("TIMEOUT_PROBE_DEADLINE")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-error-render`: a scripted error with no usable description renders a
/// human line, and no raw `XxxError(` debug string can reach the transcript.
private func runErrorRenderProbe() {
    _ = NSApplication.shared
    Task { @MainActor in
        setenv("POP_STREAM_TIMEOUT_SECS", "180", 1)
        let provider = ScriptedProvider(
            nativelyExecutesTools: false,
            box: ScriptedProviderBox()
        ) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: EmptyDescError())
            }
        }
        ProviderTestSeams.shared.primaryProviderOverride = provider
        ProviderTestSeams.shared.fallbackProviderOverride = nil
        ProviderTestSeams.shared.streamClock = { Date() }
        let controller = makeProbeChatController()
        controller.handleBridgeMessage(type: "chatSend", body: ["text": "boom"])
        await waitForTurnToSettle(controller, seconds: 10)

        let human = !controller.lastErrorText.isEmpty
            && !ChatController.looksLikeRawErrorDebug(controller.lastErrorText)
        // Assert-by-construction: a raw debug string is sanitized on the way out.
        let sanitized = ChatController.sanitizeErrorText("TimeoutError()")
        let sanitizedOK = !ChatController.looksLikeRawErrorDebug(sanitized)
            && !sanitized.isEmpty
        let gate = human && sanitizedOK
        print("ERROR_RENDER_HUMAN=\(gate)")
        print("ERROR_RENDER_TEXT=\(controller.lastErrorText)")
        fflush(stdout)
        exit(gate ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("ERROR_PROBE_DEADLINE")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-fallback-carry`: an on-device turn that collects a tool result and
/// then fails hands that result to the cloud request payload.
private func runFallbackCarryProbe() {
    _ = NSApplication.shared
    Task { @MainActor in
        setenv("POP_STREAM_TIMEOUT_SECS", "180", 1)
        let primary = ScriptedProvider(
            nativelyExecutesTools: true,
            box: ScriptedProviderBox()
        ) { _, activity in
            AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.toolCall(
                        id: nil,
                        name: "screen_read",
                        arguments: .object(["q": .string("x")])
                    ))
                    await activity?(ToolRoundOutcome(
                        name: "screen_read",
                        ok: true,
                        detail: "SCREEN_BYTES_10000: line1 line2"
                    ))
                    try? await Task.sleep(for: .milliseconds(50))
                    continuation.finish(throwing: EmptyDescError())
                }
            }
        }
        let fallbackBox = ScriptedProviderBox()
        let fallback = ScriptedProvider(
            nativelyExecutesTools: false,
            box: fallbackBox
        ) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.delta("cloud answer"))
                continuation.yield(.done("cloud answer"))
                continuation.finish()
            }
        }
        ProviderTestSeams.shared.primaryProviderOverride = primary
        ProviderTestSeams.shared.fallbackProviderOverride = fallback
        ProviderTestSeams.shared.streamClock = { Date() }
        let controller = makeProbeChatController()
        controller.handleBridgeMessage(type: "chatSend", body: ["text": "read my screen"])
        await waitForTurnToSettle(controller, seconds: 10)

        let carried = fallbackBox.requests.first ?? []
        let toolMessages = carried.filter { $0.role == .tool }
        let assistantsWithCalls = carried.filter {
            $0.role == .assistant && !($0.toolCalls ?? []).isEmpty
        }
        let hasScreen = toolMessages.contains { $0.text.contains("SCREEN_BYTES_10000") }
        let carryOK = toolMessages.count == 1 && assistantsWithCalls.count == 1 && hasScreen
        print("FALLBACK_TOOLS_CARRIED=\(carryOK) count=\(toolMessages.count)")
        print("FALLBACK_CARRY_RESULT=\(controller.lastAnswerFull)")
        // THE PROVIDER PLUMBING STAYS OFF-SCREEN. The fallback notice was pushed
        // through `pushToolLine`, which suppresses it from the transcript while
        // still logging it (`BRAIN_NOTICE` on stdout). Measured from the render
        // sink, not from the wording.
        let noticeFragment = "falling back"
        let suppressed = ProviderTestSeams.shared.suppressedLines.contains {
            $0.contains(noticeFragment)
        }
        let rendered = ProviderTestSeams.shared.renderedLines.contains {
            $0.contains(noticeFragment)
        }
        print("FALLBACK_NOTICE_SUPPRESSED=\(suppressed)")
        print("FALLBACK_NOTICE_RENDERED=\(rendered)")
        let noticeHidden = suppressed && !rendered
        print("FALLBACK_NOTICE_HIDDEN=\(noticeHidden)")
        fflush(stdout)
        exit((carryOK && noticeHidden) ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("FALLBACK_PROBE_DEADLINE")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// `--test-context-splice`: contextMode ON, a SEEDED summon snapshot, and a
/// scripted brain. Proves the turn-invariant prompt assembly — the observation
/// prefix, the clock line, AND the final-message splice — all ride the outgoing
/// prompt, with no real screen access (the seeded snapshot has an axExcerpt, so
/// the quick-only heavy fill is skipped and screenshot stays nil).
private func runContextSpliceProbe() {
    _ = NSApplication.shared
    Task { @MainActor in
        setenv("POP_STREAM_TIMEOUT_SECS", "180", 1)
        let box = ScriptedProviderBox()
        let provider = ScriptedProvider(
            nativelyExecutesTools: false,
            box: box
        ) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.delta("ok"))
                continuation.yield(.done("ok"))
                continuation.finish()
            }
        }
        ProviderTestSeams.shared.primaryProviderOverride = provider
        ProviderTestSeams.shared.fallbackProviderOverride = nil
        ProviderTestSeams.shared.streamClock = { Date() }
        var observation = Observation()
        observation.appName = "ProbeApp"
        observation.bundleID = "com.pop.probe"
        observation.windowTitle = "ProbeWindow"
        observation.axExcerpt = ["probe line"]
        Observe.summonSnapshot = observation

        // contextMode true ONLY for this probe's controller: build it inline
        // rather than mutating the shared makeProbeChatController factory.
        var config = PopConfig.defaults
        config.contextMode = true
        let frozen = config
        let controller = ChatController(webViewProvider: { nil }, configProvider: { frozen })
        controller.handleBridgeMessage(type: "chatSend", body: ["text": "what is today's date?"])
        await waitForTurnToSettle(controller, seconds: 10)

        let prompt = box.requests.last?.last?.text ?? ""
        let hasUserText = prompt.contains("what is today's date?")
        let hasObservation = prompt.contains("com.pop.probe")
        let hasClock = prompt.contains("Today is")
        let hasDelta = controller.deltaCount > 0
        let gate = hasUserText && hasObservation && hasClock && hasDelta
        print("CONTEXT_SPLICE_GATE=\(gate)")
        if !gate {
            print("CONTEXT_SPLICE_PROMPT=\(prompt)")
        }
        fflush(stdout)
        exit(gate ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        print("CONTEXT_SPLICE_DEADLINE")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// A one-way gate: closed until `open()`. The scripted provider blocks on it
/// before it records its first call, so "bubble BEFORE first provider call" is
/// a measurement rather than an assumption.
private final class SendOrderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// The gated scripted brain. `stream` returns immediately, but the FIRST call's
/// record — and its only token — wait on the gate, so the probe can read the
/// submit-time DOM while the run has provably not reached the model yet.
private struct GatedScriptedProvider: ModelProvider {
    let isHealthy = true
    let unhealthyReason = ""
    let nativelyExecutesTools = false
    let box: ScriptedProviderBox
    let gate: SendOrderGate

    var executesToolsNatively: Bool { nativelyExecutesTools }

    func stream(
        messages: [ChatMessage],
        options: GenerationOptions,
        tools: [ToolSchema],
        activity: (@Sendable (ToolRoundOutcome) async -> Void)?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await gate.wait()
                box.record(messages)
                continuation.yield(.delta("ok"))
                continuation.yield(.done("ok"))
                continuation.finish()
            }
        }
    }
}

/// `--test-instant-send`: THE RETURN-KEY REFLEX.
///
/// Gate: `USER_BUBBLE_AT_SUBMIT` and `COMPOSER_CLEARED_AT_SUBMIT` are true at
/// the INSTANT the composer submits — measured while the scripted provider has
/// provably NOT been called (`PROVIDER_CALLS_AT_SNAPSHOT=0`, held by the gate).
/// Also asserts the working status flips at that same instant, the provider
/// does run afterward, and the turn is still persisted to the transcript.
@MainActor
private func runInstantSendProbe(panelController: PanelController, chatController: ChatController) {
    let gate = SendOrderGate()
    let box = ScriptedProviderBox()
    ProviderTestSeams.shared.primaryProviderOverride = GatedScriptedProvider(box: box, gate: gate)
    ProviderTestSeams.shared.fallbackProviderOverride = nil
    ProviderTestSeams.shared.fallbackEnabled = false
    ProviderTestSeams.shared.streamClock = { Date() }

    panelController.show()
    let webView = panelController.appWebView.webView
    let prompt = "instant send probe"

    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        // ONE synchronous JS turn: type, submit, snapshot. The snapshot is read
        // in the SAME tick as the submit, so it can only show what the submit
        // did before the page yielded to the native side.
        let js = "(function () {"
            + "var input = document.getElementById('input');"
            + "input.value = " + jsString(prompt) + ";"
            + "document.getElementById('composer').dispatchEvent("
            + "new Event('submit', {cancelable: true}));"
            + "var userTurns = document.querySelectorAll('#bubble .turn.user').length;"
            + "var status = document.getElementById('streamStatus');"
            + "var stop = document.getElementById('stop');"
            + "return JSON.stringify({"
            + " bubbleAtSubmit: userTurns,"
            + " inputAtSubmit: input.value,"
            + " statusAtSubmit: status ? (status.textContent || '') : '',"
            + " streamingAtSubmit: !!(stop && !stop.hidden)"
            + "});"
            + "})()"
        webView.evaluateJavaScript(js) { value, error in
            if let error {
                print("INSTANT_SEND_JS_ERROR \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                print("INSTANT_SEND_SNAPSHOT_FAILED")
                fflush(stdout)
                exit(1)
            }
            let bubbleAtSubmit = (d["bubbleAtSubmit"] as? Int) ?? -1
            let inputAtSubmit = (d["inputAtSubmit"] as? String) ?? "<nil>"
            let statusAtSubmit = (d["statusAtSubmit"] as? String) ?? ""
            let streamingAtSubmit = (d["streamingAtSubmit"] as? Bool) ?? false
            // Held by `gate`, so this is 0 by construction until `open()`.
            let callsAtSnapshot = box.requests.count

            let bubbleOK = bubbleAtSubmit >= 1
            let clearedOK = inputAtSubmit.isEmpty
            let statusOK = statusAtSubmit.hasPrefix("working")
            print("USER_BUBBLE_AT_SUBMIT=\(bubbleOK)")
            print("COMPOSER_CLEARED_AT_SUBMIT=\(clearedOK)")
            print("WORKING_STATUS_AT_SUBMIT=\(statusOK)")
            print("PROVIDER_CALLS_AT_SNAPSHOT=\(callsAtSnapshot)")
            print("SUBMIT_ORDER submit -> bubble=\(bubbleAtSubmit) -> clear=\(clearedOK)"
                + " -> first-call=\(callsAtSnapshot)")
            print("SUBMIT_STATUS_TEXT=\(statusAtSubmit) STREAMING_AT_SUBMIT=\(streamingAtSubmit)")
            fflush(stdout)

            // Release the first provider call and let the real turn finish.
            gate.open()
            waitForComposerTurn(webView: webView, chatController: chatController) { settled in
                let callsAfter = box.requests.count
                let persisted = readProbeTranscript(contains: prompt)
                print("PROVIDER_CALLS_AFTER=\(callsAfter) TURN_SETTLED=\(settled)")
                print("TRANSCRIPT_PERSISTED=\(persisted)")
                let gatePass = bubbleOK && clearedOK && statusOK
                    && callsAtSnapshot == 0 && callsAfter >= 1 && persisted
                print("INSTANT_SEND_GATE=\(gatePass)")
                fflush(stdout)
                exit(gatePass ? 0 : 1)
            }
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
        print("INSTANT_SEND_HARD_TIMEOUT")
        fflush(stdout)
        exit(1)
    }
    NSApp.run()
}

/// Polls the page until the submitted turn stops streaming and a token landed.
@MainActor
private func waitForComposerTurn(
    webView: WKWebView,
    chatController: ChatController,
    done: @escaping (Bool) -> Void
) {
    let deadline = Date().addingTimeInterval(30)
    func poll() {
        let check = "(function(){var s=document.getElementById('stop');"
            + "return !!(s && !s.hidden);})()"
        webView.evaluateJavaScript(check) { value, _ in
            let streaming = (value as? Bool) == true
            if !streaming, chatController.deltaCount > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done(true) }
                return
            }
            if Date() >= deadline { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
}

/// The probe transcript path (redirected to a temp file for every `--test-*`).
private func readProbeTranscript(contains needle: String) -> Bool {
    guard let path = ProcessInfo.processInfo.environment["POP_TRANSCRIPT_PATH"],
          let contents = try? String(contentsOfFile: path, encoding: .utf8)
    else { return false }
    return contents.contains(needle)
}

// Top-level code runs on the main thread but is not statically isolated in
// this language mode, so the app setup above is entered explicitly.
MainActor.assumeIsolated {
    bootstrap()
}
