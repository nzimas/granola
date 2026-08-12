#!/usr/bin/env bash
# Build sc3-plugins from source and stage it into vendor/.
#
# sc3-plugins gives us JPverb (the reverb) and Greyhole, plus ~170 other UGens
# that later effects can draw on. There are no official prebuilt binaries for
# current SuperCollider on Apple Silicon, and building from source avoids
# running downloaded binaries — so we compile it against the matching SC tag.
#
# Run once; the results land in vendor/ and are committed with the project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/build/deps"
VENDOR="$ROOT/vendor/sc3-plugins"
SC_APP="${SC_APP:-/Applications/SuperCollider.app}"
ARCHS="${ARCHS:-arm64}"

for tool in cmake git; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

# Build against the exact SuperCollider version we ship, so the plugin ABI matches.
SC_VERSION="$("$SC_APP/Contents/Resources/scsynth" -v 2>/dev/null | head -1 | awk '{print $2}')"
[[ -n "$SC_VERSION" ]] || { echo "error: could not determine SuperCollider version" >&2; exit 1; }
echo "==> Target SuperCollider $SC_VERSION"

mkdir -p "$DEPS"

if [[ ! -d "$DEPS/supercollider" ]]; then
    echo "==> Fetching SuperCollider $SC_VERSION source (plugin headers)"
    git clone --depth 1 --branch "Version-$SC_VERSION" \
        https://github.com/supercollider/supercollider.git "$DEPS/supercollider"
fi

if [[ ! -d "$DEPS/sc3-plugins" ]]; then
    echo "==> Fetching sc3-plugins"
    git clone --depth 1 --recursive \
        https://github.com/supercollider/sc3-plugins.git "$DEPS/sc3-plugins"
fi

echo "==> Building (arch: $ARCHS)"
mkdir -p "$DEPS/sc3-plugins/build"
cd "$DEPS/sc3-plugins/build"
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DSC_PATH="$DEPS/supercollider" \
    -DSUPERNOVA=OFF \
    -DQUARKS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS" >/dev/null

# NCAnalysisUGens fails to compile with modern clang (a chained comparison in
# SMS.cpp). It is an analysis suite Granola does not use, so the build carries
# on without it rather than blocking on an upstream bug.
cmake --build . --config Release -j "$(sysctl -n hw.ncpu)" 2>&1 | tail -3 || true

echo "==> Staging into vendor/"
rm -rf "$VENDOR"
mkdir -p "$VENDOR/plugins" "$VENDOR/classes"
find "$DEPS/sc3-plugins/build" -name "*.scx" -exec cp {} "$VENDOR/plugins/" \;

# Class files keep their directory structure — some suites rely on their own layout.
(cd "$DEPS/sc3-plugins/source" && find . -path "*/sc/*.sc" -print0 | while IFS= read -r -d '' f; do
    mkdir -p "$VENDOR/classes/$(dirname "$f")"
    cp "$f" "$VENDOR/classes/$f"
done)
cp "$DEPS/sc3-plugins/source/DEINDUGens/faust_src/GreyholeRaw.sc" "$VENDOR/classes/DEINDUGens/" 2>/dev/null || true

PLUGINS=$(ls -1 "$VENDOR/plugins" | wc -l | tr -d ' ')
CLASSES=$(find "$VENDOR/classes" -name "*.sc" | wc -l | tr -d ' ')
echo "ok: $PLUGINS plugins, $CLASSES class files staged in vendor/sc3-plugins"

for required in JPverb.scx Greyhole.scx; do
    [[ -f "$VENDOR/plugins/$required" ]] || { echo "error: $required missing" >&2; exit 1; }
done
echo "ok: JPverb and Greyhole present"
