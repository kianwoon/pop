# Relaunching a signed .app by exec'ing its bare binary (nohup MacOS/Pop &) breaks TCC bundle attribution: macOS then can't match the bundle's usage descriptions and SIGABRTs the process on the first privacy-gated API call (symptom: EXC_CRASH / TCC __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__ even though Info.plist HAS the keys). Relaunch via LaunchServices ('open -n App.app --stdout file --stderr file') — same stdout capture, correct TCC identity. Verify launch method FIRST when a TCC privacy crash contradicts an intact Info.plist.

- **Date**: 2026-10-09T20:38:44+0800
- **Type**: lesson

## What happened



## Root cause / fix


