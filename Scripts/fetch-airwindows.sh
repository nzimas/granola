#!/usr/bin/env bash
# Fetch the Airwindows source tree (MIT, Chris Johnson).
# Only needed once; Scripts/build-airwindows.sh compiles from it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/build/deps"
mkdir -p "$DEPS"
if [[ -d "$DEPS/airwindows" ]]; then
    echo "already present: $DEPS/airwindows"
else
    git clone --depth 1 https://github.com/airwindows/airwindows.git "$DEPS/airwindows"
fi
echo "ok: $(ls -d "$DEPS/airwindows/plugins/MacVST"/*/ | wc -l | tr -d ' ') plugins available"
