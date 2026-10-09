---
# 2026-10-05 — macOS accessory-app floating panel: focus debugging patterns

- Symptom: NSPanel (.nonactivatingPanel + .borderless + .utilityWindow, LSUIElement app) reports isKeyWindow=true while real keystrokes go to the frontmost app.
- System Events AX "frontmost" is UNRELIABLE for accessory apps — do not use it as a typing-focus oracle; NSWorkspace.frontmostApplication and AX can disagree with actual key routing. Ground truth = type and see where text lands.
- macOS 14+ cooperative activation ignores activation requests driven by SYNTHETIC clicks (CGEvent HID posts lack user-intent provenance). A real global-hotkey press IS honored. Synthetic GUI tests cannot prove click-to-focus for such panels.
- Working pattern: defer past the click/hotkey event turn (asyncAfter ~250ms), NSApp.activate() + panel.makeKeyAndOrderFront(nil); webview needs needsPanelToBecomeKey=true + acceptsFirstMouse; hidesOnDeactivate=false. Verify HEADLESSLY: app posts CGEvent unicode keystrokes to itself after activation, then reads the field value via evaluateJavaScript (probe prints PROBE_<...>_VALUE). CLI-only, no GUI churn, decisive.
- For a chat panel, take focus on summon (Spotlight-style) — no-focus-steal belongs to companion/pill layers, not the explicit chat surface.

- UPDATE (drag): synthetic HID mouse-downs cannot START window-server drags — NSWindow.performDrag(with:) logs "Window move completed without beginning" for injected events while real human drags work perfectly with the same code. Corollary: drag, like focus, is human-verifiable only; do not build robot probes for window-drag, gate on user verdict.
