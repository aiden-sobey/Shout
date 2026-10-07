#!/usr/bin/env bash
# Build Shout.app from the SwiftPM package and sign it.
#
#   scripts/bundle.sh            → build/Shout.app
#
# Signing: uses the "Shout Dev" code-signing certificate if it exists (see README), so
# macOS keeps Accessibility/Microphone permissions across rebuilds. Without it the app is
# ad-hoc signed and you'll need to re-grant permissions after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Shout.app"
IDENTITY="${SHOUT_SIGNING_IDENTITY:-Shout Dev}"

echo "==> Building (release)"
swift build -c release --package-path "$ROOT/app" 2>&1 | grep -v "ld: warning: search path" || true
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/Shout"
[[ -x "$BIN" ]] || { echo "Build failed: $BIN not found" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shout"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace ShoutEngineDirectory -string "$ROOT/engine" "$APP/Contents/Info.plist"

echo "==> Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    # Don't fall back to ad-hoc here: that would silently reset Shout's permissions.
    if ! codesign --force --sign "$IDENTITY" --identifier dev.local.Shout "$APP"; then
        echo "ERROR: couldn't sign with \"$IDENTITY\". If it says errSecInternalComponent, codesign" >&2
        echo "couldn't reach the keychain: run this from a normal Terminal (not a sandbox) and choose" >&2
        echo "\"Always Allow\" if macOS asks to use the key." >&2
        exit 1
    fi
    echo "    signed with \"$IDENTITY\""
else
    codesign --force --sign - --identifier dev.local.Shout "$APP"
    echo "    WARNING: no \"$IDENTITY\" certificate; ad-hoc signed."
    echo "    macOS will ask for permissions again after every rebuild. Run scripts/make-dev-cert.sh."
fi
codesign --verify "$APP"
echo "==> Done: $APP"
