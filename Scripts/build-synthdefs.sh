#!/usr/bin/env bash
# Compile Scripts/synthdefs.scd -> Resources/synthdefs/*.scsyndef using the
# system sclang. This is a BUILD-TIME dependency only; the shipped app bundle
# contains just scsynth, the UGen plugins and the compiled .scsyndef files.
#
# sclang is pointed at an explicit class-library config rather than the user's
# own Extensions folder, so the build sees exactly the vendored sc3-plugins
# classes and nothing else — reproducible, and it leaves the system untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCLANG="${SCLANG:-/Applications/SuperCollider.app/Contents/MacOS/sclang}"
SC_CLASSLIB="${SC_CLASSLIB:-/Applications/SuperCollider.app/Contents/Resources/SCClassLibrary}"
VENDOR_CLASSES="$ROOT/vendor/sc3-plugins/classes"
AW_CLASSES="$ROOT/vendor/airwindows/classes"

if [[ ! -x "$SCLANG" ]]; then
    echo "error: sclang not found at $SCLANG" >&2
    echo "       install SuperCollider, or set SCLANG=/path/to/sclang" >&2
    exit 1
fi

if [[ ! -d "$VENDOR_CLASSES" ]]; then
    echo "error: sc3-plugins classes missing at $VENDOR_CLASSES" >&2
    echo "       run Scripts/fetch-sc3-plugins.sh first" >&2
    exit 1
fi

mkdir -p "$ROOT/Resources/synthdefs" "$ROOT/build"
rm -f "$ROOT/Resources/synthdefs"/*.scsyndef

CONFIG="$ROOT/build/sclang.yaml"
cat > "$CONFIG" <<YAML
includePaths:
  - $SC_CLASSLIB
  - $VENDOR_CLASSES
  - $AW_CLASSES
excludePaths:
postInlineWarnings: false
YAML

# sclang stays resident after evaluating a file, so run it headless and let the
# script's own 0.exit terminate it.
OUT="$( { "$SCLANG" -i none -l "$CONFIG" "$ROOT/Scripts/synthdefs.scd" 2>&1 || true; } )"

# Class-library compilation is noisy; only surface it when something breaks.
if echo "$OUT" | grep -qiE "^(ERROR|error:)|ERROR: syntax error|FAILURE"; then
    echo "$OUT"
    echo "error: sclang reported errors while compiling synthdefs" >&2
    exit 1
fi
echo "$OUT" | grep -E "^Granola:|compiled .* files" || true

# Airwindows effect SynthDefs, one per effect, emitted by generate.py.
AW_DEFS="$ROOT/build/airwindows-gen/aw-synthdefs.scd"
if [[ -f "$AW_DEFS" ]]; then
    AWOUT="$( { "$SCLANG" -i none -l "$CONFIG" "$AW_DEFS" "$ROOT/Resources/synthdefs" 2>&1 || true; } )"
    echo "$AWOUT" | grep -E "^Granola:" || true
    if echo "$AWOUT" | grep -qiE "^ERROR|error:"; then
        echo "$AWOUT" | grep -iE "^ERROR|error:" | head -5
        echo "error: Airwindows synthdefs failed to compile" >&2
        exit 1
    fi
fi

COUNT=$(ls -1 "$ROOT/Resources/synthdefs"/*.scsyndef 2>/dev/null | wc -l | tr -d ' ')
EXPECTED=6
if [[ "$COUNT" -lt "$EXPECTED" ]]; then
    echo "$OUT"
    echo "error: expected $EXPECTED synthdefs, got $COUNT" >&2
    exit 1
fi
echo "ok: compiled $COUNT synthdefs"
