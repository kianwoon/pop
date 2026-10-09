# Pop — Build Plan v0.1

Companion to `SPEC.md`. Each milestone has an acceptance gate; a milestone is done only when its gate passes on the reference machine (macOS 27.2, M3 Max). Dependencies are explicit; independent tracks may run in parallel.

```
M0 Scaffold ──► M1 Model layer ──► M2 Web chat UI ──► M5 Browser skill ──┐
   │                   │                                                 ├──► M7 Hardening
   └────► M3 Observe ──┴──► M4 Act + approval ─────────────────────────────┘
                M6 jev bridge (any time after M1)
```

---

## M0 — Scaffold & floating panel

**Goal**: prove the shell risk first — a panel that floats over any app without stealing focus.

- Xcode project (Swift, SwiftUI lifecycle + AppKit NSPanel host), hardened-runtime settings.
- Global hotkey (default ⌥Space) toggles panel; menu-bar orb with show/hide/quit.
- NSPanel: `.nonactivatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, float level; drag; position persistence.
- WKWebView embedded, loads a placeholder TS page, typed bridge skeleton (ping/pong).

**Gate**: summon over Safari *and* over a full-screen app; hotkey summon takes key focus (Spotlight-style — typing lands in the panel immediately, verified by ground-truth keystroke); mascot/pill layer never takes focus on its own; bridge ping→pong round-trip works; memory idle < 250 MB. (Corrected 2026-10-05: "no focus steal on summon" was mis-scoped — see SPEC §3.1.)
**Risk**: NSPanel focus/full-screen quirks — this is why it is M0.

## M1 — Model layer & config

> **Order note (2026-10-05)**: a mascot **visual spike** (SwiftUI art + pill toolbar, no agent wiring) was pulled ahead of M1 at the user's request — see "Spike S" below. M2's full mascot work (agent-event states) still depends on M1.

**Spike S — Mascot visual spike (pulled forward)**: SwiftUI-drawn cloud-head robot mascot in its own borderless non-activating window + pill toolbar (✎ live, ∿/⏺ disabled "coming soon"), idle bob/blink, `--mascot-cycle` debug state cycler, drag + position persistence, double-click/✎ toggles chat panel, right-click menu. Gate: build clean; floats over spaces without stealing focus; all states previewable; user art-direction verdict.

**Goal**: `ModelProvider` protocol + apple-fm implementation; user-configurable providers.

- `ModelProvider` protocol: streaming text events, tool declarations, structured output (schema), image attachments.
- `AppleFMProvider`: `LanguageModelSession`, streaming, `@Generable` structured output, image attachments, PCC toggle, availability handling (Apple Intelligence off / unsupported ⇒ clear error + provider fallback hint).
- `OpenAICompatProvider` (one implementation covers OpenAI/OpenRouter/LM Studio/Ollama-style endpoints).
- Settings window: provider/model/API key (Keychain), temperature; per-conversation model switch in UI.
- Transcript store (SQLite or JSONL) with session resume.

**Gate**: streaming chat works on-device end-to-end with zero network; switching to openai-compatible endpoint works via config; keys never touch disk outside Keychain; availability failure degrades with a clear message.
**Depends on**: M0 (panel shell for the settings window may lag — headless test harness acceptable).

## M2 — Web chat UI + mascot companion

**Goal**: the real chat surface, plus Pop's visual identity — the mascot and pill toolbar (user reference design, 2026-10-05).

- TS/HTML chat UI in WKWebView: streaming markdown, tool-call/action cards, approval cards, provider banner, transcript list.
- Bridge: typed message protocol (Swift→UI: chunk/tool-card/state; UI→Swift: send/approve/deny/config), versioned JSON schema.
- Quick actions: summon-with-selection prefill; stop/cancel generation.
- **Mascot layer**: second borderless always-on-top window hosting the mascot (vector art + idle blink/bob animation in v0) and the pill toolbar (✎ new chat · ∿ voice · ⏺ mic; voice/mic render disabled "coming soon" in v0). Draggable, position persisted, non-activating. Double-click toggles the chat panel; ✎ expands it.
- **Mascot states**: idle / thinking / speaking / happy wired to agent-core events (thinking while streaming, happy on verified task completion); listening state reserved for voice work post-v0.

**Gate**: streaming tokens render live (markdown, code blocks) in the panel from the configured provider; headless `--test-ui-chat` probe proves bridge→provider→DOM end-to-end; mascot shows thinking→speaking→happy across one on-device chat exchange (user-visible); settings window edits config + Keychain round-trip (`--test-keychain`); regression `--test-chat` stays green. (Corrected 2026-10-06: approval-card round-trip moved to M4 where the agent core lives; selection prefill moved to M3 — it requires the AX observation layer.)
**Depends on**: M1.

## M3 — Observe (context + computer-use read half)

**Goal**: Pop knows what you're looking at.

- Frontmost app + window title + URL (browser) detection.
- AX tree reader (depth-limited, role/label/value/action snapshot, perf-capped).
- ScreenCaptureKit screenshot (window-scoped or region) → FM image attachment.
- Context mode prompt assembly: selection + title + AX excerpt (+ screenshot if permitted).
- Permission onboarding flow (TCC prompts with rationale screens).

**Gate**: "What am I looking at?" correctly describes the frontmost app (tested against Safari, Finder, Xcode) using AX + screenshot; works with Screen Recording denied (AX-only degradation); observation snapshot < 300 ms for a typical window.

## M4 — Act + approval gate (computer-use write half)

**Goal**: approval-gated desktop actions with verification.

- Action planner: `@Generable` action-list schema (verb, target hint, args, risk tag) rendered as cards.
- Executors: CGEvent mouse/keyboard, AX actions, app activation; unambiguous-target rule enforced.
- Approval cards: Run / Edit / Deny; denial feeds back to the model as an event.
- Verify step: post-action AX/screenshot diff confirms expected change; fail ⇒ one retry ⇒ failure report.
- Append-only action log.

**Gate**: "Click the blue button" completes on a purpose-built test app (card → approve → act → verified); denial aborts with no synthetic event emitted; every action logged; all gates pass with Screen Recording off (AX-verify path).

## M5 — Browser skill

**Goal**: in-panel browser + page skills.

- WKWebView browser (address bar, tabs, history) inside the Pop panel.
- Skills: `read_page` (text/DOM summary), `extract` (selector or schema-guided), `fill_form`, `click` — acts approval-gated, verified by DOM state.
- Page JS injection layer + CSP-safe messaging.

**Gate**: fill-and-submit on a local test form completes end-to-end with approval + verification; `read_page` summarizes a real news page accurately; acts blocked when approval denied.

## M6 — jev bridge

**Goal**: the user-configurable advisory brain.

- Config surface (endpoint, model, token, toggles, thresholds); Keychain for token.
- Three hooks: skill routing (which skill handles a request), risk scoring on approval cards (probability labels, advisory only), run-state labeling (stall/drift on long sessions).
- Fail-open contract + audit trail: jev calls and outcomes logged to the action log; unreachable jev ⇒ rule-based defaults, surfaced in UI footer.

**Gate**: with jev configured, approval cards show jev risk labels; killing the jev endpoint mid-session degrades gracefully with a visible "jev unavailable — defaults in use" note; no decision ever hard-blocks on jev.

## M7 — Hardening & packaging

**Goal**: a distributable Developer-ID app.

- Fresh-machine TCC onboarding replay; permission state machine edge cases.
- Developer ID signing + notarization; sparkle-style update path decision (defer if costly).
- Perf budget: idle memory < 300 MB, cold summon→first-token < 1.5 s (apple-fm warm).
- Action-log viewer in settings; secret-scan pass over the repo before any tagged build.

**Gate**: all SPEC §8 success criteria pass on a clean user account; notarized build launches and completes onboarding.

## M9 — On-device brain (Foundation Models) — IN PROGRESS (user decision, 2026-10-07)

- **DONE — on-device is the default brain** behind the existing `ModelProvider` seam; the OpenAI-compatible provider is retained and is now the automatic FALLBACK (used when on-device availability is not `.available`, or its call throws). `openai-compat` in the config keeps the old behaviour exactly.
- **DONE — availability gate**: an injected availability seam drives the decision; `appleIntelligenceNotEnabled` / `deviceNotEligible` / `modelNotReady` each get an honest, distinct string, and the fallback is non-blocking and visible (transcript notice + privacy pill), never a dead panel. Gated by `--test-on-device-turn`, `--test-on-device-fallback`, and the `--test-on-device-nofallback` negative control.
- **DONE — turns run tool-less by design** on the product path; mutating tools still run on the remote path through the existing approval gate.
- OPEN — structured output: `@Generable` for action plans and approval cards (requires target 27.0 — see the deployment-target decision in SPEC §2).
- OPEN — move the default on-device session onto the `Tool` protocol (macOS 26.0); FM-native wiring exists (M4b) but is not the default brain's path yet.
- Acceptance (partial): one real turn answered by the on-device model in the app, verified on screen; the remote provider still works; no permission regressions. Structured-output acceptance stays until the target decision is resolved.

## M10 — Verification doctrine & test harness — PROPOSED

- Encode SPEC §10 as the standing bar for every UI/AI gate in `main.swift`.
- Fix the known vacuous gate: `--test-real-state-gate` must exercise `full`-without-navigation (the state where the pane bug occurred).
- Every user-visible gate: rendered geometry + in-frame + occlusion (native and web) + a negative control that fails on the regression.

---

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| NSPanel focus/space/full-screen quirks | Shell unusable on some setups | M0 exists to burn this risk first; test matrix: normal space, full-screen app, Stage Manager, multiple displays |
| Foundation Models availability gating (Apple Intelligence off, model loading) | Default brain unavailable | Availability check at startup; provider fallback chain (apple-fm → configured cloud/local); clear onboarding copy |
| TCC friction (Accessibility + Screen Recording prompts) | Cold onboarding drop-off | Progressive onboarding — chat works with zero permissions; rationale screens before each prompt |
| AX tree perf/instability on complex apps (Electron apps, games) | Slow or noisy observation | Depth limits + caching + change-dirty detection; screenshot path as alternative channel |
| Apple FM tool-calling vs custom providers drift | Skill behavior differs per provider | Single normalized tool schema in `ModelProvider`; provider-specific conformance tests per milestone |
| PCC/network dependency surprises | "Offline" promise broken silently | Provider banner always visible; offline mode test in M7 gate |
| WKWebView bridge schema rot | UI/core mismatch bugs | Versioned typed bridge schema; contract test in CI per milestone that touches the bridge |
| Synthetic input mistakes (wrong target clicked) | User harm | Unambiguous-target rule; approval cards with risk tags; verify-after-act; append-only action log |
| Probes measuring a different state than the user's (three false "fixed" reports) | Verification doctrine (SPEC §10): reproduce the real state, assert rendered geometry, ship a negative control, one source of truth per layout decision. |

## Suggested execution order for a solo builder

1. **Weeks 1–2: M0** — panel + hotkey + bridge skeleton (risk burn).
2. **Weeks 3–4: M1** — apple-fm provider; have real streaming chat in the panel.
3. **Weeks 5–6: M2** — chat UI polish; M6 (jev config + one hook) can slot here in parallel.
4. **Weeks 7–9: M3 → M4** — observe, then act+approve. The demo moment: "click the blue button."
5. **Weeks 10–11: M5** — browser skill.
6. **Week 12: M7** — onboarding, notarization, success-criteria sweep.
