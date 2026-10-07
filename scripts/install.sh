#!/usr/bin/env bash
# Build, install to ~/Applications/Shout.app and (re)launch.
# Always running from the same path keeps macOS's permission records tidy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/Shout.app"

"$ROOT/scripts/bundle.sh"

if pgrep -x Shout >/dev/null; then
    echo "==> Quitting running Shout"
    osascript -e 'tell application id "dev.local.Shout" to quit' >/dev/null 2>&1 || pkill -x Shout || true
    for _ in {1..20}; do pgrep -x Shout >/dev/null || break; sleep 0.25; done
fi

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/build/Shout.app" "$DEST"

if [[ "${1:-}" != "--no-launch" ]]; then
    echo "==> Launching"
    open "$DEST"
fi
