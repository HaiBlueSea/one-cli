#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MODE="${1:-development}"
case "$MODE" in
  development) CONFIGURATION=debug; APP_NAME="One Cli Dev.app"; IDENTIFIER=com.aiterminal.dev; DISPLAY_NAME="One Cli Dev" ;;
  release) CONFIGURATION=release; APP_NAME="One Cli.app"; IDENTIFIER=com.aiterminal.app; DISPLAY_NAME="One Cli" ;;
  *) printf 'Usage: sh scripts/build.sh [development|release]\n' >&2; exit 2 ;;
esac
[ "$(uname -s)" = Darwin ] || { echo 'Building requires macOS.' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo 'The bundled cloudflared requires Apple silicon.' >&2; exit 1; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export COPYFILE_DISABLE=1

cd "$ROOT"
if [ "$MODE" = release ]; then
  swift build -c "$CONFIGURATION" -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." -Xswiftc -gnone >&2
else
  swift build -c "$CONFIGURATION" >&2
fi
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$ROOT/.tmp" "$ROOT/dist"
STAGE="$(mktemp -d "$ROOT/.tmp/build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
APP="$STAGE/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/AIETerminal" "$APP/Contents/MacOS/AIETerminal"
cp "$BIN/AIEHookHelper" "$APP/Contents/Helpers/AIEHookHelper"
cp "$BIN/AIERemoteHelper" "$APP/Contents/Helpers/AIERemoteHelper"
cp "$ROOT/Resources/Tools/cloudflared" "$APP/Contents/Helpers/cloudflared"
cp "$ROOT/Resources/Info-Dev.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $IDENTIFIER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP/Contents/Info.plist"
for item in Zsh Fonts AgentIcons Wrappers Licenses RemoteWeb; do
  cp -R "$ROOT/Resources/$item" "$APP/Contents/Resources/$item"
done
for item in launchers.json AI-Terminal.icns AppIcon.png ASSETS.md; do
  cp "$ROOT/Resources/$item" "$APP/Contents/Resources/$item"
done
for item in LICENSE THIRD_PARTY_NOTICES.md PRIVACY.md; do
  cp "$ROOT/$item" "$APP/Contents/Resources/$item"
done
find "$BIN" \( -name '*.bundle' -o -name '*.metallib' -o -name 'Shaders.metal' \) -print0 \
  | while IFS= read -r -d '' item; do cp -R "$item" "$APP/Contents/Resources/"; done
chmod +x "$APP/Contents/MacOS/AIETerminal" "$APP/Contents/Helpers/"* "$APP/Contents/Resources/Wrappers/"*
if [ "$MODE" = release ]; then
  /usr/bin/strip -S "$APP/Contents/MacOS/AIETerminal" "$APP/Contents/Helpers/AIEHookHelper" "$APP/Contents/Helpers/AIERemoteHelper"
fi
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
for binary in "$APP/Contents/Helpers/AIEHookHelper" "$APP/Contents/Helpers/AIERemoteHelper" "$APP/Contents/Helpers/cloudflared" "$APP"; do
  /usr/bin/codesign --force --sign - --timestamp=none "$binary"
done
/usr/bin/codesign --verify --deep --strict "$APP"
# Only replace this script's generated app bundle, never an installed app.
if [ -e "$ROOT/dist/$APP_NAME" ]; then
  OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/dist/$APP_NAME/Contents/Info.plist")"
  [ "$OLD_ID" = "$IDENTIFIER" ] || { echo 'Unexpected existing output; refusing to replace it.' >&2; exit 1; }
  rm -rf "$ROOT/dist/$APP_NAME"
fi
mv "$APP" "$ROOT/dist/$APP_NAME"
printf '%s\n' "$ROOT/dist/$APP_NAME"
