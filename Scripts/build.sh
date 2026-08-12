#!/usr/bin/env bash
# Builds Granola.app with SuperCollider's audio server embedded.
#
# The finished bundle has no external SuperCollider dependency: scsynth, its
# UGen plugins and libsndfile all live inside Contents/Resources. SuperCollider
# is needed only on THIS machine, at build time, to compile the SynthDefs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC_APP="${SC_APP:-/Applications/SuperCollider.app}"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Granola.app"

echo "==> Compiling SynthDefs"
"$ROOT/Scripts/build-synthdefs.sh" >/dev/null

echo "==> Building Granola ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BINARY="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Granola"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/SuperCollider/plugins"
mkdir -p "$APP/Contents/Resources/Frameworks"
mkdir -p "$APP/Contents/Resources/synthdefs"

cp "$BINARY" "$APP/Contents/MacOS/Granola"
cp "$ROOT/Resources/synthdefs/"*.scsyndef "$APP/Contents/Resources/synthdefs/"

# --- embed the audio server -------------------------------------------------
# scsynth loads libsndfile via @loader_path/../Frameworks, and each plugin via
# @loader_path/../../Frameworks. Placing scsynth in Resources/SuperCollider and
# the plugins one level below makes both resolve to Resources/Frameworks, so no
# install_name_tool surgery is required.
if [[ ! -x "$SC_APP/Contents/Resources/scsynth" ]]; then
    echo "error: scsynth not found in $SC_APP" >&2
    echo "       install SuperCollider, or set SC_APP=/path/to/SuperCollider.app" >&2
    exit 1
fi

cp "$SC_APP/Contents/Resources/scsynth" "$APP/Contents/Resources/SuperCollider/scsynth"
cp "$SC_APP/Contents/Resources/plugins/"*.scx "$APP/Contents/Resources/SuperCollider/plugins/"
cp "$SC_APP/Contents/Frameworks/libsndfile.dylib" "$APP/Contents/Resources/Frameworks/"

# sc3-plugins, built by Scripts/fetch-sc3-plugins.sh. JPverb is the reverb, and
# the rest of the suite comes along so future effects have it available.
if [[ -d "$ROOT/vendor/sc3-plugins/plugins" ]]; then
    cp "$ROOT/vendor/sc3-plugins/plugins/"*.scx "$APP/Contents/Resources/SuperCollider/plugins/"
else
    echo "error: vendor/sc3-plugins/plugins missing — run Scripts/fetch-sc3-plugins.sh" >&2
    exit 1
fi

# Airwindows performance FX: 154 effects compiled from unmodified upstream DSP
# by Scripts/build-airwindows.sh.
if [[ -f "$ROOT/vendor/airwindows/GranolaAirwindows.scx" ]]; then
    cp "$ROOT/vendor/airwindows/GranolaAirwindows.scx" "$APP/Contents/Resources/SuperCollider/plugins/"
    cp "$ROOT/vendor/airwindows/airwindows-manifest.json" "$APP/Contents/Resources/"
else
    echo "error: Airwindows plugin missing — run Scripts/build-airwindows.sh" >&2
    exit 1
fi

PLUGIN_COUNT=$(ls -1 "$APP/Contents/Resources/SuperCollider/plugins/" | wc -l | tr -d ' ')
echo "    embedded scsynth + $PLUGIN_COUNT UGen plugins (core + sc3-plugins)"

# --- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Granola</string>
    <key>CFBundleDisplayName</key><string>Granola</string>
    <key>CFBundleExecutable</key><string>Granola</string>
    <key>CFBundleIdentifier</key><string>com.granola.Granola</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <!-- No NSMicrophoneUsageDescription on purpose: Granola granulates files
         and pins scsynth to the default output device, so it never opens an
         input. Add the key back if live-input granulation is implemented. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Granola connects to the M-Vave SMC-Mixer over Bluetooth MIDI.</string>
</dict>
</plist>
PLIST

# --- signing ----------------------------------------------------------------
# Ad-hoc signature. Nested binaries are signed before the bundle that contains
# them, which is what --deep gets wrong often enough to be worth doing by hand.
echo "==> Signing"
codesign --force --sign - "$APP/Contents/Resources/Frameworks/libsndfile.dylib"
for plugin in "$APP/Contents/Resources/SuperCollider/plugins/"*.scx; do
    codesign --force --sign - "$plugin"
done
codesign --force --sign - "$APP/Contents/Resources/SuperCollider/scsynth"
codesign --force --sign - "$APP"

echo "==> Verifying"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP"
echo "Run it with:  open \"$APP\""
