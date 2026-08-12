#!/usr/bin/env bash
# Compile the Airwindows repertoire into a single SuperCollider plugin.
#
# The Airwindows sources are used UNMODIFIED — they compile against our own
# minimal audioeffectx.h (Scripts/airwindows/vstshim), so the DSP, and
# therefore the sound, is exactly as published. Only the wrapper differs: a
# UGen instead of a VST.
#
# Plugins that fail to compile are dropped and the registry is regenerated
# without them, so one awkward plugin cannot block the other 150.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/build/deps"
AW="$DEPS/airwindows/plugins/MacVST"
SC="$DEPS/supercollider"
GEN="$ROOT/build/airwindows-gen"
OBJ="$ROOT/build/airwindows-obj"
VENDOR="$ROOT/vendor/airwindows"
ARCH="${ARCHS:-arm64}"
JOBS="$(sysctl -n hw.ncpu)"

[[ -d "$AW" ]] || { echo "error: airwindows source missing — run Scripts/fetch-airwindows.sh" >&2; exit 1; }
[[ -d "$SC/include/plugin_interface" ]] || { echo "error: SuperCollider headers missing at $SC" >&2; exit 1; }

echo "==> Generating UGen wrappers"
python3 "$ROOT/Scripts/airwindows/generate.py" || exit 1

mkdir -p "$OBJ" "$VENDOR"
rm -f "$OBJ"/*.o

INCLUDES=(
    -I"$SC/include/plugin_interface"
    -I"$SC/include/common"
    -I"$SC/include/server"
    -I"$ROOT/Scripts/airwindows/vstshim"
)
CXXFLAGS=(-std=c++17 -O2 -fPIC -arch "$ARCH" -w -DNDEBUG)

compile() {
    local src="$1" out="$2"; shift 2
    clang++ "${CXXFLAGS[@]}" "${INCLUDES[@]}" "$@" -c "$src" -o "$out" 2>/dev/null
}
export -f compile
export CXXFLAGS INCLUDES

echo "==> Compiling (arch $ARCH, $JOBS jobs)"
FAILED="$OBJ/failed.txt"; : > "$FAILED"

# One job per plugin: its two sources plus the generated wrapper must all
# succeed for that plugin to be included.
build_one() {
    local name="$1"
    local src="$AW/$name/source"
    local ok=1
    for unit in "$src/$name.cpp" "$src/${name}Proc.cpp" "$GEN/aw_$name.cpp"; do
        local base; base="$(basename "$unit" .cpp)"
        # Every plugin defines the VST entry point createEffectInstance at
        # global scope; 154 of them in one binary collide. We never call it,
        # so rename it per plugin rather than editing the sources.
        clang++ -std=c++17 -O2 -fPIC -arch "$ARCH" -w -DNDEBUG \
            "-DcreateEffectInstance=aw_entry_$name" \
            -I"$SC/include/plugin_interface" -I"$SC/include/common" -I"$SC/include/server" \
            -I"$ROOT/Scripts/airwindows/vstshim" -I"$src" \
            -c "$unit" -o "$OBJ/${name}__${base}.o" 2>/dev/null || ok=0
    done
    if [[ $ok -eq 0 ]]; then
        echo "$name" >> "$FAILED"
        rm -f "$OBJ/${name}__"*.o
    fi
}
export -f build_one
export AW SC ROOT GEN OBJ ARCH FAILED

ls "$GEN"/aw_*.cpp | sed 's|.*/aw_||; s|\.cpp$||' | grep -v '^registry$' \
    | xargs -P "$JOBS" -I{} bash -c 'build_one "$@"' _ {}

if [[ -s "$FAILED" ]]; then
    echo "    dropped $(wc -l < "$FAILED" | tr -d ' '): $(tr '\n' ' ' < "$FAILED")"
    # Regenerate the registry and manifest without the failures.
    python3 "$ROOT/Scripts/airwindows/prune.py" "$FAILED" || exit 1
fi

compile "$ROOT/Scripts/airwindows/aw_support.cpp" "$OBJ/aw_support.o" || {
    echo "error: shim support failed to compile" >&2; exit 1; }
clang++ -std=c++17 -O2 -fPIC -arch "$ARCH" -w -DNDEBUG \
    -I"$SC/include/plugin_interface" -I"$SC/include/common" -I"$SC/include/server" \
    -I"$ROOT/Scripts/airwindows/vstshim" \
    -c "$GEN/aw_registry.cpp" -o "$OBJ/aw_registry.o" || {
    echo "error: registry failed to compile" >&2; exit 1; }

echo "==> Linking GranolaAirwindows.scx"
clang++ -bundle -arch "$ARCH" -o "$VENDOR/GranolaAirwindows.scx" "$OBJ"/*.o || exit 1

COUNT=$(python3 -c "import json;print(len(json.load(open('$GEN/airwindows-manifest.json'))))")
cp "$GEN/airwindows-manifest.json" "$VENDOR/"
echo "ok: $COUNT Airwindows effects in $(du -h "$VENDOR/GranolaAirwindows.scx" | cut -f1)"
