# Pop 🤖

A little robot that lives on your Mac's desktop — a launcher, a voice assistant, and an agent, in one always-present companion.

![platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue) ![swift](https://img.shields.io/badge/Swift-6-orange) ![arch](https://img.shields.io/badge/arch-Apple%20Silicon-green)

## What is Pop?

Pop is a tiny robot that sits on your screen. Click it to summon a composer, talk to it, and put it away when you're done — the robot never leaves. Under the hood it runs a full agent loop with tools, on-device speech, and your choice of AI provider.

## Features

- **Robot launcher** — the mascot is always on screen; a click (or ⌥Space) summons the composer, Esc tucks it away. The robot is the anchor; the window grows around it.
- **Voice dictation, on-device** — press the mic and speak; partials appear live in the transcript bubble. Recognition runs on-device when available. Stopping and speaking again *appends* to your draft, pauses don't lose your first sentence, and dismissing the bar always stops the mic — a forgotten live mic is impossible.
- **Voice replies** — Pop can read answers aloud (opt-in), with barge-in: talking to Pop silences a reply in flight.
- **Agent loop with real tools** — web lookup, file read/write with an approval gate, screen OCR, AppleScript app control, and more. Every mutating action asks you first.
- **Two providers** — Apple's on-device Foundation Models (no key, no cloud) or any OpenAI-compatible endpoint (base URL + key in the Keychain, never in plain text).
- **Hover feedback** — hover the robot and its antenna arc energizes; an optional synthesized electric-arc buzz (off by default, volume in Settings) hums while you hover.
- **Real Settings** — provider, model, temperature, custom headers, permissions status, and sound preferences in one floating window; also scriptable headlessly via `--set-config key=value`.

## Install

1. Grab `Pop.app.zip` from the [latest release](https://github.com/kianwoon/pop/releases/latest).
2. Unzip and drag **Pop.app** to `/Applications`.
3. First launch: right-click → **Open** (the binary is currently ad-hoc signed, so Gatekeeper asks once).
4. Grant microphone/speech access when you first use voice — that's it.

**Requirements:** macOS 26 or newer, Apple Silicon.

## Privacy posture

- Speech recognition runs **on-device** whenever the Mac supports it (you're told if it has to fall back).
- API keys live in the **Keychain**, never in `config.json` or anywhere on disk in plain text.
- Google sign-in (for web lookups) stores cookie **names only** in memory for session detection — never values.
- Nothing is telemetry'd, nothing phones home.

## Source code

The source is **not published yet**. This repository currently hosts the README, license, and release binaries only.
