#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# No PATH changes, brew, package installation or implicit network fetches.
TOOLS_DIR="${MEDIAFORGE_TOOLS_DIR:-$ROOT/.tools/source-build/prefix/bin}"
FFMPEG="${FFMPEG_PATH:-$TOOLS_DIR/ffmpeg}"
FFPROBE="${FFPROBE_PATH:-$TOOLS_DIR/ffprobe}"
NOTICES="${MEDIAFORGE_THIRD_PARTY_DIR:-$ROOT/ThirdParty}"
MANIFEST="${MEDIAFORGE_ENGINE_MANIFEST:-$NOTICES/EngineSource/engine-manifest.json}"
SOURCE_ARCHIVE="${MEDIAFORGE_ENGINE_SOURCE_ARCHIVE:-$ROOT/.tools/source-build/MediaForge-engine-source-9.0.tar.gz}"
SOURCE_RECORD="${MEDIAFORGE_ENGINE_SOURCE_RECORD:-$NOTICES/EngineSource/source-archive.json}"
IDENTITY="${MEDIAFORGE_SIGN_IDENTITY:--}"
PYTHON="${PYTHON3:-/usr/bin/python3}"
APP="$ROOT/dist/MediaForge.app"

if [[ ! -x "$FFMPEG" || ! -x "$FFPROBE" ]]; then
    printf 'Both source-built ffmpeg and ffprobe are required.\nFFmpeg: %s\nFFprobe: %s\nBuild with: /usr/bin/python3 scripts/build-engine.py && /usr/bin/python3 scripts/package-engine-source.py\n' "$FFMPEG" "$FFPROBE" >&2
    exit 1
fi
for notice in NOTICE.md FFmpeg/COPYING.GPLv2 FFmpeg/COPYING.GPLv3; do
    [[ -f "$NOTICES/$notice" ]] || { printf 'Missing third-party notice: %s\n' "$NOTICES/$notice" >&2; exit 1; }
done
HELPER_ARGS=(--manifest "$MANIFEST" --ffmpeg "$FFMPEG" --ffprobe "$FFPROBE" --source-archive "$SOURCE_ARCHIVE" --source-record "$SOURCE_RECORD")
# Reject unknown inputs BEFORE executing anything from their toolchain.
"$PYTHON" "$ROOT/scripts/verify-helpers.py" "${HELPER_ARGS[@]}"
printf 'Source-built GPL engine: distribute the matching MediaForge-engine-source-9.0.tar.gz with this app; read ThirdParty/NOTICE.md.\n' >&2
if [[ -e "$APP" && "${MEDIAFORGE_REPLACE_APP:-0}" != 1 ]]; then
    printf 'Existing app preserved: %s\nAfter checking that it is not running, the integrator may set MEDIAFORGE_REPLACE_APP=1.\n' "$APP" >&2
    exit 1
fi

# MEDIAFORGE_BINARY allows packaging an already-built app without invoking SwiftPM.
if [[ -n "${MEDIAFORGE_BINARY:-}" ]]; then
    BIN="$MEDIAFORGE_BINARY"
else
    swift build -c release --product MediaForge
    BIN_DIR="$(swift build -c release --show-bin-path)"
    BIN="$BIN_DIR/MediaForge"
fi
[[ -x "$BIN" ]] || { printf 'Missing app executable: %s\n' "$BIN" >&2; exit 1; }
"$PYTHON" "$ROOT/scripts/verify-helpers.py" "${HELPER_ARGS[@]}" --app-binary "$BIN"

mkdir -p "$ROOT/dist"
STAGE="$(mktemp -d "$ROOT/dist/.MediaForge-stage.XXXXXX")"
cleanup() {
    # Verify resolved, absolute deletion scope; never clean a computed unchecked path.
    [[ -n "${STAGE:-}" && -d "$STAGE" ]] || return 0
    local resolved
    resolved="$(cd "$STAGE" && pwd -P)"
    case "$resolved" in "$ROOT"/dist/.MediaForge-stage.*) /bin/rm -rf -- "$resolved" ;; *) printf 'Refusing unsafe cleanup: %s\n' "$resolved" >&2 ;; esac
}
trap cleanup EXIT
STAGED_APP="$STAGE/MediaForge.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Helpers"
cp "$BIN" "$STAGED_APP/Contents/MacOS/MediaForge"
cp "$FFMPEG" "$STAGED_APP/Contents/Helpers/ffmpeg"
cp "$FFPROBE" "$STAGED_APP/Contents/Helpers/ffprobe"
chmod 755 "$STAGED_APP/Contents/MacOS/MediaForge" "$STAGED_APP/Contents/Helpers/"*
mkdir -p "$STAGED_APP/Contents/Resources/ThirdParty/EngineSource" "$STAGED_APP/Contents/Resources/ThirdParty/FFmpeg"
cp -R "$NOTICES/EngineSource/." "$STAGED_APP/Contents/Resources/ThirdParty/EngineSource/"
cp "$NOTICES/NOTICE.md" "$NOTICES/SOURCES.md" "$STAGED_APP/Contents/Resources/ThirdParty/"
cp "$NOTICES/FFmpeg/COPYING.GPLv2" "$NOTICES/FFmpeg/COPYING.GPLv3" "$NOTICES/FFmpeg/FFmpeg-LICENSE.md" "$STAGED_APP/Contents/Resources/ThirdParty/FFmpeg/"
cp "$MANIFEST" "$STAGED_APP/Contents/Resources/ThirdParty/engine-manifest.json"
BUNDLED_ARGS=(--manifest "$MANIFEST" --ffmpeg "$STAGED_APP/Contents/Helpers/ffmpeg" --ffprobe "$STAGED_APP/Contents/Helpers/ffprobe" --source-archive "$SOURCE_ARCHIVE" --source-record "$SOURCE_RECORD")
"$PYTHON" "$ROOT/scripts/verify-helpers.py" "${BUNDLED_ARGS[@]}" --app-binary "$STAGED_APP/Contents/MacOS/MediaForge" --report "$STAGED_APP/Contents/Resources/ThirdParty/bundled-engine-audit.json"
/usr/bin/swift "$ROOT/scripts/make-icon.swift" "$ROOT/.build/MediaForge.iconset"
/usr/bin/iconutil -c icns "$ROOT/.build/MediaForge.iconset" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>MediaForge</string>
    <key>CFBundleDisplayName</key><string>MediaForge</string>
    <key>CFBundleExecutable</key><string>MediaForge</string>
    <key>CFBundleIdentifier</key><string>dev.mediaforge.converter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MediaForge — local media conversion; FFmpeg notices in Resources/ThirdParty</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
# Sign nested executables individually, inside-out; never rely on --deep to sign.
for helper in "$STAGED_APP/Contents/Helpers/"*; do
    /usr/bin/codesign --force --sign "$IDENTITY" "$helper"
    /usr/bin/codesign --verify --strict "$helper"
done
/usr/bin/codesign --force --sign "$IDENTITY" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
# The only replacement target is this workspace's known dist/MediaForge.app.
[[ "$APP" == "$ROOT/dist/MediaForge.app" && ! -L "$APP" ]] || { printf 'Unsafe app target\n' >&2; exit 1; }
if [[ -d "$APP" ]]; then
    [[ "$(cd "$APP" && pwd -P)" == "$ROOT/dist/MediaForge.app" ]] || exit 1
    /bin/rm -rf -- "$APP"
elif [[ -e "$APP" ]]; then
    printf 'App target is not a directory\n' >&2; exit 1
fi
[[ "$(cd "$STAGED_APP" && pwd -P)" == "$STAGE/MediaForge.app" ]] || exit 1
/bin/mv -- "$STAGED_APP" "$APP"
printf '\nBuilt MediaForge 0.2.0: %s\nBundled helpers: %s\nOpen with: open "%s"\n' "$APP" "$APP/Contents/Helpers" "$APP"
