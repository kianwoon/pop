# Pop — Spec v0.2

**Pop** is a macOS floating AI assistant that lives on top of any app. Summon it with a hotkey, and it understands what you're looking at, chats with context, and — with your approval — acts in the browser and on the desktop.

- Status: draft for review
- Date: 2026-10-07
- Revised: platform findings from the local SDK spike (see §9) and the verification doctrine (§10)
- Target machine class: Apple Silicon Mac, Apple Intelligence capable (reference machine: macOS 27.2, M3 Max)

---

## 1. Vision

Every AI assistant today lives in its own window or its own app. Pop inverts this: it floats **over** whatever you're doing, inherits your context (frontmost app, selection, screen), and helps without an app switch. Its differentiators:

1. **Native intelligence** — Apple's Foundation Models framework (on-device + Private Cloud Compute) is the default brain: zero API cost, private by default, native tool calling.
2. **Configurable brains** — the user can point Pop at any LLM (OpenAI-compatible, Anthropic, local Ollama) and at their own **jev** decision service.
3. **Skills with discipline** — browser and computer-use skills inherit the observe → decide → act → **verify** loop (modeled on a GUI-driver agent contract): the agent owns its loop, never acts without approval, and always verifies the effect of an action.

## 2. Decisions locked (2026-10-05)

| Decision | Choice | Basis |
|---|---|---|
| App stack | **Swift app core + WKWebView chat UI** (hybrid) | Foundation Models / AX / CGEvent / ScreenCaptureKit / NSPanel are all Swift-first; web UI gives fast chat-surface iteration. jev rating 0.67, user-confirmed. |
| v0 autonomy | **Act with approval** | Every computer/browser action renders a preview card; one click to run. Read-only observation needs no approval. |
| Distribution | Developer ID (direct), **not** Mac App Store | Sandbox is incompatible with Accessibility control of other apps. |
| Privacy default | On-device (Apple FM) | Cloud providers are opt-in per provider config, with a visible session banner when active. |
| Model layer direction | **LOCKED: on-device-first, automatic fallback to the configured remote provider** (user decision, 2026-10-07) | The on-device `SystemLanguageModel` is the DEFAULT brain; when its availability is not `.available` OR its call throws, Pop falls back to the configured OpenAI-compatible provider. Fallback is automatic, non-blocking, and VISIBLE (transcript notice + privacy pill). Availability is read through an injected seam so it is testable; each unavailable reason (`deviceNotEligible` / `appleIntelligenceNotEnabled` / `modelNotReady`) has its own honest string. |
| Deployment target | **PROPOSED: raise 26.0 → 27.0** — not yet locked | Unlocks `LanguageModel` (custom-provider abstraction) and `@Generable`, both macOS 27.0+ in the installed SDK. jev strength **0.55**, below the 0.60 floor; the reach cost (drops macOS 26 machines) is unresolved ⇒ pending user sign-off. **Note (2026-10-07):** the target did NOT change for M9 — `SystemLanguageModel`, `LanguageModelSession`, `respond`/`streamResponse` and `Tool` are all macOS 26.0, and every FoundationModels call is behind `#available`, so the on-device brain ships at 26.0. `@Generable`/`LanguageModel` remain the only reasons a bump would buy anything. |

## 3. Product shape

### 3.1 The Pop launcher (robot + bar — one widget)

Pop's primary identity is a **launcher**: a small animated cloud robot perched on one long rounded composer bar, floating near the bottom of the screen. One widget — robot and bar are inseparable. (User reference design, authoritative: bumpy cloud head with `>_<` chevron eyes, tiny body with stubby arms, standing with feet just above the bar's top edge; bar = `[+]  start new chat  [↑]`.)

```
       ╭──────╮
      (  >_<  )        ← robot (idle blink/bob · thinking · speaking · happy)
       ╰─┐  ┌─╯
     ╭──────────────────────────────╮
     │ +   start new chat        ↑  │  ← composer bar
     ╰──────────────────────────────╯
   [ chat grows upward above the bar
     only when a conversation exists ]
```

- **One window**: robot and bar live in a single borderless, always-on-top panel (`.canJoinAllSpaces`, `.fullScreenAuxiliary`, non-activating, transparent background). No cross-window sync exists by construction. Position persists across launches; drag anywhere (robot or bar) moves the whole assembly, clamped to screen.
- **Ambient presence**: the robot is always visible after launch (like the Dock). It never auto-hides. **Default state is the robot alone** — no bar, no chat (user-mandated, 2026-10-06).
- **Three states, one window**:
  - **Mascot (default)**: robot alone, 110×110. No bar, no chat.
  - **Launcher (bar)**: ⌥Space or click the robot → robot + composer bar, input focused. NO chat. Type your question here.
  - **Chat**: sending expands the conversation area upward. ✎ / New chat collapses to launcher.
- **`⌥Space`**: mascot → launcher (+input focus) · launcher → mascot · chat → mascot (everything collapses). It never merely resizes.
- **`+` menu**: New chat · context toggles (App context ✓ · Screenshot ✓ · Selection ✓ when present) · privacy indicator (On-device ●/Cloud ●). No other chrome.
- **Robot states** drive from agent events: idle (bob/blink) → thinking (orbiting dots, head tilt) on send → speaking (mouth bar) while streaming → happy (bounce + sparkles) on completion → idle.
- **Context chips are state, not decoration**: what Pop will see (app/title, screenshot, selection) is reflected in the `+` menu; removed items are excluded from the next request.
- **Selection capture**: summoning with text selected pre-fills the input as a quoted draft (never auto-sent).
- **Menu-bar orb**: Hide Pop (explicit, the only full dismissal) · Show Mascot · Settings · Quit.

### 3.2 Modes

| Mode | What it does | Permissions |
|---|---|---|
| **Chat** | Plain assistant chat. | none |
| **Context** | Aware of frontmost app: window title, selected text, AX tree excerpt, optional screenshot. | Accessibility (read), Screen Recording (optional) |
| **Computer use** | Multi-step desktop actions with approval cards. | Accessibility (act), Automation |
| **Browser** | In-panel browser + page read/fill/extract skills. | none (in-panel); Automation for controlling external browser tabs |

### 3.3 First run

Guided TCC onboarding: Pop works as plain chat with **zero** permissions, and each capability lights up as its permission is granted. Degraded, never blocked.

## 4. Architecture

```
┌────────────────────────────────────────────────────────┐
│ Pop.app                                                │
│                                                        │
│  ┌──────────────┐   typed JSON bridge   ┌───────────┐ │
│  │ Web Chat UI  │ ◄──────────────────► │ Swift     │ │
│  │ (WKWebView,  │  WKScriptMessage     │ Shell     │ │
│  │  TS/HTML)    │  Handler ↔ JS        │ (NSPanel, │ │
│  └──────────────┘                      │ hotkey,   │ │
│         ▲                              │ settings, │ │
│         │ renders                      │ TCC flow) │ │
│  ┌──────┴──────────────────────────────┴─────────┐ │
│  │ Agent Core (Swift)                             │ │
│  │  session loop: observe → plan → act → verify   │ │
│  │  transcript store · approval gate · action log │ │
│  └──────┬──────────────────────┬─────────────────┘ │
│         │                      │                   │
│  ┌──────▼───────┐      ┌───────▼───────────────┐   │
│  │ Model Layer  │      │ Skills (FM Tool proto)│   │
│  │ ModelProvider│      │  computer-use         │   │
│  │  apple-fm*   │      │  browser              │   │
│  │  openai-*    │      └───────┬───────────────┘   │
│  │  anthropic   │              │                    │
│  │  ollama      │      ┌───────▼───────────────┐   │
│  └──────┬───────┘      │ jev Bridge (HTTP)     │   │
│         │              │  advisory decisions,  │   │
│  Keychain / Config    │  fail-open            │   │
└─────────┴──────────────┴────────────────────────┘
```

### 4.1 Swift Shell (AppKit/SwiftUI)

- NSPanel host, global hotkey, menu-bar extra (orb), settings window, TCC onboarding flow, permission state machine.
- Owns the WKWebView and the typed bridge: Swift → UI state pushes (transcript chunks, approval cards, permission banners); UI → intents (send prompt, approve/deny action, config changes).

### 4.2 Agent core

- **Session loop** (inherited discipline from GUI-driver agents): observe → decide (plan) → act → verify. The loop owner picks its own observation cadence and mechanics — Pop never prescribes per-click steps to the model.
- **Approval gate**: every non-read action becomes a card (verb, target, arguments, risk tag) in the chat stream; Run / Edit / Deny. Denial returns control to the model with the denial as feedback.
- **Action log**: append-only record of every synthesized event (what, target app, timestamp, approval id). Viewable in settings.
- **Unambiguous-target rule**: an action against a window/app Pop cannot unambiguously re-focus is refused, not guessed.

### 4.3 Model layer

`ModelProvider` protocol: `stream(prompt, tools, schema?) -> events`. One implementation per provider; tool-calling normalized to a common shape.

| Provider | Backing | Notes |
|---|---|---|
| **apple-fm** (default) | Foundation Models `LanguageModelSession` | On-device; PCC toggle for larger context; `@Generable` for typed structured output (action plans, approvals); multimodal image attachments for screen understanding; `Tool` protocol is the skills interface |
| openai-compatible | any OpenAI-shaped endpoint | covers OpenAI, Groq, OpenRouter, LM Studio |
| anthropic | Messages API | |
| ollama | local HTTP | fully-offline third path |

**Verified against the installed SDK, not documentation** (macOS 27.2, Swift 6.4, SDK 27.0; spike output in §9):

- `SystemLanguageModel` and its `availability` API are **macOS 26.0** — cases `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`.
- `Tool` (the skills interface) is **macOS 26.0**.
- `LanguageModelSession` exists with `respond(to:)` / `streamResponse(to:)` and is `@unchecked Sendable`.
- `LanguageModel` (the custom-provider protocol) and the `@Generable` macro are **macOS 27.0+**. ⇒ The provider abstraction in the table above requires target 27.0; the on-device path does not.
- Wrapping an OpenAI-shaped endpoint as a `LanguageModel` costs ~7 required members — `LanguageModel`: `associatedtype Executor`, `capabilities`, `executorConfiguration`; `Executor`: `Configuration`, `Model`, `init(configuration:)`, `respond(…)` (`prewarm` has a default implementation) — plus SSE→channel translation (`.response(.appendText…)` / `.toolCalls(.toolCall(…, action: .appendArguments…))`) and `Transcript`⇄messages mapping.
- **Correction to earlier planning:** `CoreAI.framework` in the installed SDK is a stub (`@_exported import CoreAIDelegates`; low-level `AIModel`, `InferenceFunction`, `ComputeStream`, `AIModelAsset`, `AIModelCache`). There is **no `CoreAILanguageModel` and no `MLXLanguageModel`** symbol in the installed interface. Those backends are documented externally but UNCONFIRMED locally — do not design on them.

- Streaming (partial text + partial structured output) is uniform across providers.
- **Model config is per-conversation switchable.**

**M9 — on-device-first with fallback (2026-10-07).** `ChatController.resolveProvider` is the single decision point: if `provider == "openai-compat"`, the remote provider is primary (unchanged, pre-M9 behaviour); otherwise the on-device `AppleFMProvider` is primary and the configured remote provider is a LAZY fallback, used when availability is not `.available` OR the on-device stream throws. A fallback renders a visible transcript notice and moves the privacy pill to "Cloud" — a silent fallback is indistinguishable from a broken app. Availability is read through an injected seam (`ProviderTestSeams` / `AppleFMProvider(availabilityOverride:)`): production uses `SystemLanguageModel.default.availability`, probes force a value. Each unavailable reason has a distinct, actionable string. Every FoundationModels symbol used is macOS 26.0, so all calls sit behind `#available(macOS 26.0, *)` and the 26.0 deployment target is unchanged.

**On-device turns currently run tool-less BY DESIGN.** The M9 product path constructs the on-device session with no tools (`AppleFMProvider(toolsEnabled: false)`), so mutating tools keep running on the remote path through the existing approval gate. The FM-native `Tool` wiring (`FMToolAdapter`, M4b) is retained for the dedicated `--test-tool-loop` probe; switching the default brain onto it is a separate milestone.

**Prior turns are carried as a session `Transcript`, not a flattened prompt.** The prompt passed to `LanguageModelSession.streamResponse(to:)` is the CURRENT user turn alone; earlier user/assistant turns are `.prompt`/`.response` entries in a `Transcript` (plus an `.instructions` entry holding `AppleFMProvider.systemPrompt`). The pre-fix construction flattened the whole conversation into one `"Role: text"` string, which the small model treated as a transcript to CONTINUE — it echoed the user's own line (or a context line) instead of answering. `--test-on-device-prompt "<text>"` sends an arbitrary prompt and reports `FM_ECHO` (verbatim-copy detection); its negative control is `POP_FM_FORCE_ECHO=1` (plus `POP_FM_NO_FALLBACK=1`), which makes the provider answer with the prompt verbatim and the gate fail. Because an on-device reply can still be a non-answer, `ChatController.isUsableReply` routes an EMPTY reply, a verbatim ECHO of the user's words/prompt, or a SHORT explicit refusal to the remote fallback (with a visible notice and a UI reset of the discarded text); a short real answer ("4", "yes") is deliberately NOT treated as a failure.

### 4.4 jev bridge

Pop treats **jev as the user-configurable advisory decision service** — the same role it plays for the agent that authored this spec:

- Config: endpoint URL, model, auth token, thresholds (all in settings; disabled by default until configured).
- Uses: (a) **skill routing** — which skill/hand should take a request; (b) **risk scoring** — advisory strength on approval cards (labels + probabilities, never a hard gate); (c) **run-state labeling** — stall/drift detection on long computer-use sessions.
- **Fail-open contract**: jev unreachable ⇒ Pop proceeds on rule-based defaults and says so in the action log. jev shapes; it never blocks.

### 4.5 Skills

Each skill implements the FM `Tool` protocol (so apple-fm calls it natively) plus a normalized adapter for other providers.

**computer-use** (inherits computer-aid concepts)
- Observe: frontmost app + window title, AXUIElement tree (roles, labels, values, actions), ScreenCaptureKit screenshot, selection text.
- Act (approval-gated): CGEvent mouse/keyboard synthesis, AX actions (`press`, `setSelected`, `setValue`), app activation, scroll.
- Verify: post-action AX/screenshot diff must confirm the expected state change before the loop proceeds; unverified action ⇒ retry once ⇒ report failure.

**browser**
- v0: in-panel WKWebView browsing (address bar, tabs) + JS-injection skills: `read_page`, `extract(selector/schema)`, `fill_form`, `click` — all acts approval-gated.
- External-browser tab control (Safari/Chrome via Apple Events) is a stretch goal post-v0.

## 5. Permissions & security

| Permission | Used for | Failure mode without it |
|---|---|---|
| Accessibility | AX read + AX/CGEvent act | Context mode loses tree; computer-use disabled; chat fine |
| Screen Recording | screenshots, visual verify | falls back to AX-tree-only observation |
| Automation (per app) | Apple Events to Safari/Chrome etc. | external-tab skills disabled |
| Notifications | run-complete / approval-needed nudges | panel badge only |

- Secrets (API keys, jev token) live in **Keychain**, never in config files.
- Screen content leaves the device **only** when a cloud provider is selected; a persistent banner shows the active provider whenever a screenshot or AX content is in the prompt.
- Non-sandboxed app (required for AX control); hardened runtime + notarization.

## 6. Configuration (settings UI)

- **LLM**: provider, model id, API key, temperature, PCC on/off (apple-fm), base URL (openai-compatible/ollama).
- **jev**: endpoint URL, model, auth token, feature toggles (routing / risk scoring / run labeling), threshold overrides.
- **Skills**: per-skill on/off, autonomy mode (v0: approval-only; later: per-app allowlists), action-log viewer.
- **Shell**: hotkey, panel position/size, appearance (light/dark/auto), menu-bar orb on/off.

Config file: `~/Library/Application Support/Pop/config.json` (no secrets) + Keychain items (secrets).

## 7. Non-goals (v0)

- Autonomous-by-default execution (arrives as allowlist mode post-v0).
- Mac App Store distribution; Windows/Linux.
- Voice input; Pop-to-Pop sync; plugin marketplace.

## 8. Success criteria (v0)

1. Cold summon to first token < 1.5 s on-device (apple-fm, warm).
2. "Summarize what I'm looking at" answers correctly about the frontmost app with zero typing.
3. "Click the blue button" completes on a test app via approval card, and is correctly verified; denial aborts cleanly.
4. A fill-and-submit browser form completes end-to-end in-panel.
5. Pulling the network cable: on-device chat + computer-use still work; jev-less runs degrade gracefully.
6. Idle memory < ~300 MB; panel never steals focus on summon.
- **The reply is actually visible.** For every panel state, a completed turn must be on screen — not merely present in the DOM. Native pane occlusion and layout clipping are failure modes; both are verified by measurement, not inspection (see §10).

## 9. Platform findings (local SDK spike, 2026-10)

Read from the installed Swift interface, not docs. Evidence: `FoundationModels.framework` Swift interface in the active SDK; a scratch SwiftPM package at `.macOS("27.0")` that links, runs, and returns `FM_REPLY=PONG` from the on-device model with no credentials.

| Fact | Value |
|---|---|
| On-device model availability | `.available` on this machine |
| `SystemLanguageModel` / `Tool` / `LanguageModelSession` | macOS 26.0 |
| `LanguageModel` protocol / `@Generable` macro | macOS 27.0+ |
| Required members to wrap an HTTP provider as `LanguageModel` | ~7 (see §4.3) |
| `CoreAI.framework` | stub in this SDK; no `CoreAILanguageModel` / `MLXLanguageModel` symbol |
| Pop deployment target today | 26.0 (`Package.swift`, `Pop.xcodeproj`) |
| Evaluations framework | documented externally; **not verified locally** |

## 10. Verification doctrine (non-negotiable)

Earned from three consecutive false "fixed" reports on the same user-visible symptom. These are rules, not suggestions:

1. **A probe may never report success for a configuration the user has not confirmed.** Gates must reproduce the user's real state — restored session, actual panel state, browser open or closed.
2. **Presence in the DOM is not visibility.** Assert rendered geometry and computed style, and hit-test with `document.elementFromPoint`.
3. **Native views are invisible to DOM probes.** A web-only check cannot detect a native view painting over web content; occlusion must be measured from the native side too (frame geometry + paint order).
4. **Every gate ships with a negative control that fails on the bug.** A gate that cannot fail is worthless. (Witness: `--test-real-state-gate` is vacuous for the pane-visibility line because it navigates the browser before measuring. Second witness: the M9 on-device turn probe asserted only a non-empty reply while prompting `"Reply with exactly: POP_ONDEVICE_OK"`, so an echoing model passed — caught by the user, not the suite.)
5. **One source of truth per layout decision.** Duplicated visibility logic across the native and web layers is what produced the blank panel.
6. **Probes never write user storage** — `POP_SESSIONS_PATH` / `POP_TRANSCRIPT_PATH` redirect to temp.
