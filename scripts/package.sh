#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
sh "$ROOT/scripts/build.sh" release >/dev/null
APP="$ROOT/dist/One Cli.app"
ZIP_NAME=One-Cli-macos-arm64.zip
mkdir -p "$ROOT/.tmp"
STAGE="$(mktemp -d "$ROOT/.tmp/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

# Guard against shipping local runtime data or signing secrets.
FORBIDDEN="$(find "$APP" \( -name auth.json -o -name credentials.json -o -name .env -o -name .git -o -name layout.json -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.jsonl' -o -name '*.log' \) -print)"
[ -z "$FORBIDDEN" ] || { printf 'Unexpected private files in bundle:\n%s\n' "$FORBIDDEN" >&2; exit 1; }
for binary in "$APP/Contents/MacOS/AIETerminal" "$APP/Contents/Helpers/AIEHookHelper" "$APP/Contents/Helpers/AIERemoteHelper" "$APP/Contents/Helpers/cloudflared"; do
  LINKS="$(otool -L "$binary" | tail -n +2 | awk '{print $1}')"
  for library in $LINKS; do
    case "$library" in
      /usr/lib/*|/System/*) ;;
      *) printf 'Unexpected runtime dependency: %s\n' "$library" >&2; exit 1 ;;
    esac
  done
done
/usr/bin/codesign --verify --deep --strict "$APP"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGE/$ZIP_NAME"
/usr/bin/ditto -x -k "$STAGE/$ZIP_NAME" "$STAGE/unpacked"
/usr/bin/codesign --verify --deep --strict "$STAGE/unpacked/One Cli.app"
(cd "$STAGE" && shasum -a 256 "$ZIP_NAME" > One-Cli-macos-arm64.sha256)
mv "$STAGE/$ZIP_NAME" "$ROOT/dist/$ZIP_NAME"
mv "$STAGE/One-Cli-macos-arm64.sha256" "$ROOT/dist/One-Cli-macos-arm64.sha256"
printf '%s\n' "$ROOT/dist/$ZIP_NAME" "$ROOT/dist/One-Cli-macos-arm64.sha256"
