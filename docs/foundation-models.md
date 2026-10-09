# macOS Built-in AI (Foundation Models) — Pop Reference

> What Apple's on-device foundation model is, what it can and cannot do, and how
> Pop should use it. Sources retrieved 2026-10-09; all "measured" facts come
> from live runs on this machine (macOS 27.2, Apple Silicon) on that date.

## 1. What it is

- Apple's on-device "System One"-class language model, accessed via the
  **Foundation Models** framework (`SystemLanguageModel`,
  `LanguageModelSession`), macOS 26.0+.
- Apple's own positioning: *"On-device models excel at … summarization, entity
  extraction, text and image understanding, refinement, dialog … When you need
  more reasoning capabilities and context size, use Private Cloud Compute or
  any server model provider."*
- The prompting doc is blunt: the on-device model *"is much smaller"* and
  *"doesn't have the resources to handle long or confusing prompts."*

## 2. Context window (the hard constraint)

| Version | Window | Source |
|---|---|---|
| macOS 26.0 (docs) | **4,096 tokens/session** | "Managing the context window" |
| macOS 27.2 (this machine, measured) | **8,192 tokens** | Live error: "Provided 8,783 tokens, but the maximum allowed is 8,192" |

Rules that matter:

- **Everything consumes the window**: prompts, instructions, **tool definitions
  (name + description + parameter schema)**, generable-type schemas, tool
  outputs, and all model responses.
- Exceeding it throws `LanguageModelError.contextSizeExceeded` — recover by
  trimming history or starting a new session.
- **Never hardcode the budget.** Query it:
  - `SystemLanguageModel.contextSize` → max tokens the model supports
  - `SystemLanguageModel.tokenCount(for:)` → tokens for a prompt/instruction/tool
  - (Both APIs exist since macOS/iOS 26.4.)
- Pop measurement (2026-10-09): the FULL `ToolRegistry.schemas()` serializes to
  **≈8,783 tokens** — the on-device model physically cannot hold Pop's complete
  toolset. Measured live: both probe turns died with `inferenceFailed` before
  the model produced a word.

## 3. Tool calling

- Tool definitions are injected into the prompt so the model can decide when to
  call them — this is the token cost above.
- `Tool.includesSchemaInInstructions` (per-tool Bool): omit a tool's schema from
  the session instructions — **the lever for fitting more tools on-device**.
- The model executes back-to-back tool calls when one tool's output feeds
  another; tools must be `Sendable`.
- macOS 27 adds `GenerationOptions.ToolCallingMode` — control whether the model
  may call tools at all (native support for Pop's "tool-less chat" mode).
- macOS 27 adds **Vision `OCRTool` and `BarcodeReaderTool`** — first-class OCR
  tools the model can call (relevant to Pop's screenshot reading).
- Pop status: `AppleFMProvider` has full native wiring (`makeTools` +
  `FMToolAdapter`, probe `--test-tool-loop`), but the product path runs
  `toolsEnabled: false` — mutating tools are skipped on-device
  (`FM_TOOL_SKIP … not-on-device-eligible`) and hands-on turns promote to the
  cloud brain.

## 4. Measured capabilities in Pop (2026-10-09)

| Capability | Verdict | Evidence |
|---|---|---|
| Plain chat / Mac questions (no tools) | ✅ Works — real answers, on-device, passed echo gates | `--test-on-device-prompt` (FM_GATE=true, FM_ECHO=false) |
| Context anchoring | ⚠️ **Weakness** — "change the wallpaper" + Brave on screen → answered about *Brave's* wallpaper, not System Settings | `FM_PROMPT_SENT` shows the screen-context prefix; live probe |
| Full toolset on-device | ❌ Impossible — schemas alone ≈8,783 tokens > 8,192 window | `--test-tool-loop` (inferenceFailed both turns) |
| Read-only tools (screen_read, browser_focus_tab, web_lookup) | ✅ Works on-device (product path) | Trace: TOOL_CALL … under PROVIDER_DECISION=on-device |
| Mutating tools on-device | ❌ Skipped by design (quality decision, M9) | FM_TOOL_SKIP lines |

## 5. Apple's prompting guidance for the small model (maps 1:1 to Pop's designs)

From "Prompting an on-device foundation model":

- Keep prompts **short, direct, imperative**; one goal per prompt; 1–3 paragraphs max.
- **"Split complex prompts into a series of simpler requests"** → Pop's plan +
  `see`-checkpoint executor.
- **"Reduce the thinking the model needs to do"** → Pop's mechanical executor
  with verify-after-act.
- **"Add 'logic' to conditional prompts with if-else statements"** → Pop's
  routing classes.
- Give the model a **role/persona**; use **few-shot** examples where needed.
- Context-window strategies: shorten prompts, cap response length
  (`GenerationOptions.maximumResponseTokens`), simplify `@Generable` types
  (descriptions consume schema tokens), break tasks into separate sessions.

## 6. Newer APIs worth adopting (macOS 27 / June 2026 updates)

- **`PrivateCloudComputeLanguageModel`** — Apple's PCC: *"more reasoning
  capabilities and a larger context size"*. Candidate promotion target for
  hands-on turns (native, no API key) alongside the configured z.ai endpoint.
- **`LanguageModel` protocol** — plug ANY model (server or on-device, e.g. MLX
  models) into the same framework.
- **`ToolCallingMode`** — native control of tool availability per request.
- **Vision `OCRTool` / `BarcodeReaderTool`** — model-callable OCR (macOS 27).
- **Xcode Foundation Models instrument** — profiles token usage per interaction.
- Open source: `apple/foundation-models-utilities`,
  `apple/coreai-models` (CoreAILanguageModel), `ml-explore/mlx-swift-lm`.

## 7. Pop usage policy (the how-to-use summary)

1. **Default brain**: on-device for plain chat and read-only tool turns — fast,
   free, private. (Working today.)
2. **Hands-on turns** (computer-use/browser routed): promote to the cloud brain
   — the on-device model does not carry mutating tools. (Working today.)
3. **On-device whitelist (planned)**: a curated tool subset whose schemas fit
   the runtime `contextSize` budget (with `includesSchemaInInstructions=false`
   on verbose tools), enabling local Mac-native acts without the cloud.
4. **Prompting**: short, direct, single-goal prompts; screen context suppressed
   or labeled for system-config questions (measured anchoring weakness);
   checkpoints (`see` flags) instead of model round-trips between steps.
5. **Budgets**: always computed from runtime APIs (`contextSize`,
   `tokenCount(for:)`), never hardcoded — Apple changes the model and window
   per OS update (26.0: 4,096 → 27.2: 8,192 measured).

## Sources (Apple Inc., © 2026 — retrieved 2026-10-09)

- Foundation Models framework overview:
  https://developer.apple.com/documentation/foundationmodels
- Managing the context window:
  https://developer.apple.com/documentation/foundationmodels/managing-the-context-window
- Prompting an on-device foundation model:
  https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model
- Tool protocol:
  https://developer.apple.com/documentation/foundationmodels/tool
- Foundation Models updates (version history):
  https://developer.apple.com/documentation/updates/foundationmodels
