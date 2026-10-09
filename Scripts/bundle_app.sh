#!/usr/bin/env bash
#
# Assembles build/Pop.app from the release binary plus the web resources.
# Exits 0 on success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Pop.app"

cd "$ROOT"

# SINGLE SOURCE OF TRUTH FOR THE VERSION. The in-app update checker compares
# this string against the GitHub release tag, so the shipped bundle and the
# release tag MUST come from one place (the repo-root VERSION file) or every
# user is told to update forever. Fail the bundle rather than emit a versionless
# app that can never be compared.
VERSION_FILE="$ROOT/VERSION"
if [[ ! -s "$VERSION_FILE" ]]; then
  echo "bundle_app.sh: missing or empty VERSION at $VERSION_FILE" >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$VERSION" ]]; then
  echo "bundle_app.sh: VERSION is empty" >&2
  exit 1
fi

# ALWAYS rebuild before bundling. WHY: building only if the release binary is
# missing silently packaged a STALE `swift build -c release` output (one that
# predated the entire voice feature), so the bundle shipped code the source no
# longer had. A bundle must be traceable to nothing but current source.
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Pop"
if [[ ! -x "$BIN" ]]; then
  echo "bundle_app.sh: release binary not found at $BIN" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Pop"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Pop</string>
  <key>CFBundleIdentifier</key>
  <string>com.pop.app</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Pop</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>__POP_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__POP_VERSION__</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <!-- Cleartext http:// to a loopback OpenAI-compatible server (llama.cpp,
       Ollama, LM Studio) must not be blocked by ATS. Local networking only. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSHighResolutionCapable</key>
  <true/>
  <!-- Web lookups embed the user's current city so a signed-out SERP does not
       geo-guess the wrong place. The prompt is shown by macOS the first time a
       lookup runs; a denied permission falls back to the configured city. -->
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Pop uses your approximate location so web lookups return results for your area.</string>
  <!-- Voice input: the mic is only opened when the user starts dictation, and
       speech is transcribed on-device. Both prompts come from macOS on first
       use; a denied permission falls back to typing. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Pop uses the microphone so you can talk to your assistant.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Pop recognizes your speech on-device to turn it into messages.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Inject the single-source version into the literal placeholder (the heredoc is
# quoted so nothing else in the plist is subject to expansion).
sed -i '' "s|__POP_VERSION__|$VERSION|g" "$APP/Contents/Info.plist"

# Web resources land directly in Contents/Resources so that
# Bundle.main.url(forResource:"index", withExtension:"html") resolves.
cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"

# The app icon is a COMMITTED asset (Resources/AppIcon.icns), regenerated only
# via Scripts/make_icon.swift; copy it so the bundle always ships a real icon.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with the SAME identity the Xcode path uses (Config/Signing.xcconfig),
# so both build paths present one stable code identity to macOS. A changed
# identity is what resets TCC grants (Accessibility / Screen Recording).
#
# Resolution order: $POP_SIGN_IDENTITY -> Config/Signing.xcconfig -> PopDev.
#
# THE IDENTITY MUST NOT CHANGE PER BUILD. Pop reads an API key from the
# Keychain, and a Keychain ACL is bound to the code signature: a changed
# identity silently invalidates it and the app goes back to
# `KEYCHAIN_READ=missing`. `PopDev` is a stable, locally generated, self-signed
# code-signing certificate (CN=PopDev, EKU codeSigning) created once and kept in
# the login keychain, so every build from now on presents one identity to macOS.
#
# `GlanceDev` was the PREVIOUS value and is the reason for the churn above. It is
# tolerated for one reason only: Config/Signing.xcconfig still names it, so a
# stale read of that file must not silently pull the bundle back off PopDev. Any
# OTHER value from the xcconfig is still honoured, which keeps that file the one
# place that decides identity for the Xcode path.
PREVIOUS_SIGN_IDENTITY="GlanceDev"
SIGN_IDENTITY="${POP_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  XCCONFIG_IDENTITY="$(sed -n 's/^[[:space:]]*POP_SIGN_IDENTITY[[:space:]]*=[[:space:]]*//p' \
    "$ROOT/Config/Signing.xcconfig" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')"
  if [[ -n "$XCCONFIG_IDENTITY" && "$XCCONFIG_IDENTITY" != "$PREVIOUS_SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$XCCONFIG_IDENTITY"
  fi
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-PopDev}"

ENTITLEMENTS="$ROOT/Config/Pop.entitlements"
CODE_SIGN_EXTRA=()
if [[ -f "$ENTITLEMENTS" ]]; then
  CODE_SIGN_EXTRA+=(--entitlements "$ENTITLEMENTS")
fi

# A silently mis-signed bundle is WORSE than a failed build: it looks signed but
# carries the wrong trust, so Keychain grants silently stop matching and stored
# secrets go unreadable with no signal. Signing + verification are therefore
# FATAL when `codesign` exists; only an environment WITHOUT `codesign` skips
# (there is nothing to sign with).
if ! command -v codesign >/dev/null 2>&1; then
  echo "BUNDLE_SIGN_SKIPPED reason=codesign-unavailable"
else
  # WHY a PINNED designated requirement: a Keychain "Always Allow" ACL grant is
  # bound to the app's designated requirement, NOT to the build. Without an
  # explicit DR, each build carries whatever IMPLICIT DR codesign derives, and a
  # rebuild can silently change it — invalidating every stored-secret grant
  # (measured today: recurring prompts + unreadable tokens across rebuilds, and
  # legacy GlanceDev-era ACLs that no longer matched). Pinning the DR to
  # identifier + certificate CN makes it IDENTICAL across builds as long as
  # identity is unchanged, so a grant survives a rebuild; a real identity change
  # (e.g. GlanceDev) changes the DR and the loud prompts honestly signal it.
  DESIGNATED_REQUIREMENT="=designated => identifier \"com.pop.app\" and certificate leaf[subject.CN] = $SIGN_IDENTITY"
  if ! codesign --force --options runtime --timestamp=none \
        "${CODE_SIGN_EXTRA[@]+"${CODE_SIGN_EXTRA[@]}"}" \
        --requirements "$DESIGNATED_REQUIREMENT" \
        --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "BUNDLE_SIGN_FAILED reason=codesign-rejected identity=$SIGN_IDENTITY" >&2
    exit 1
  fi
  if ! codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    echo "BUNDLE_SIGN_FAILED reason=verify-failed identity=$SIGN_IDENTITY" >&2
    exit 1
  fi
  echo "BUNDLE_SIGN_IDENTITY=$SIGN_IDENTITY"
  # Surface the DR actually embedded, so future identity/requirement drift is
  # visible in the build log instead of only in a Keychain prompt.
  DR_REPORTED="$(codesign -dr - "$APP" 2>&1 | sed -n 's/^[[:space:]]*designated => //p' | head -1)"
  echo "BUNDLE_SIGN_DR=$DR_REPORTED"
fi

echo "BUNDLED $APP"