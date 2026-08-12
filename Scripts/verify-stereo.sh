#!/usr/bin/env bash
# End-to-end stereo regression test.
#
# Generates a stereo file whose channels are unmistakably different (300 Hz
# left, 900 Hz right), granulates it through the real app code path, and checks
# that the recorded output still carries two distinct channels.
#
# This is the guard against the usual granular-synthesis compromise: GrainBuf
# reads only mono buffers, so it is easy to silently collapse a stereo source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Granola.app"
OUTPUT="$ROOT/build/self-test-output.wav"

# With no argument, use the synthetic 300 Hz / 900 Hz file — its channels are
# known to be different, so a dual-mono result is unmistakable. Pass a path to
# run the same checks against real material instead.
SAMPLE="${1:-}"

if [[ ! -d "$APP" ]]; then
    echo "==> Building app"
    "$ROOT/Scripts/build.sh" >/dev/null
fi

SYNTHETIC=0
if [[ -z "$SAMPLE" ]]; then
    SAMPLE="$ROOT/build/test-stereo.wav"
    SYNTHETIC=1
    echo "==> Generating test sample"
    python3 "$ROOT/Scripts/make-test-sample.py" "$SAMPLE"
else
    echo "==> Using supplied sample: $SAMPLE"
fi

if [[ "$SYNTHETIC" == "1" ]]; then
    echo "==> Checking the source file is itself stereo"
    python3 "$ROOT/Scripts/check-stereo.py" "$SAMPLE" | tail -1
fi

echo "==> Granulating through the app"
rm -f "$OUTPUT"
pkill -f "Granola.app" 2>/dev/null || true
pkill scsynth 2>/dev/null || true
sleep 1

"$APP/Contents/MacOS/Granola" --self-test "$SAMPLE" "$OUTPUT" 2>&1 | sed 's/^/    /'

if [[ ! -f "$OUTPUT" ]]; then
    echo "FAIL: the app produced no output" >&2
    exit 1
fi

echo "==> Checking the granulated output"
if [[ "$SYNTHETIC" == "1" ]]; then
    # The synthetic file's channels are known-different, so demand real stereo.
    python3 "$ROOT/Scripts/check-stereo.py" "$OUTPUT"
else
    # Real material varies from wide to dual mono; the invariant that always
    # holds is that granulation must not narrow whatever came in.
    python3 "$ROOT/Scripts/check-stereo.py" --compare "$SAMPLE" "$OUTPUT"
fi
