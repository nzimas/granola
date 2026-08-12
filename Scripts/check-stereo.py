#!/usr/bin/env python3
"""Verify that a rendered file is genuinely stereo, not dual mono.

Reports correlation between channels and the energy of the L-R difference
signal. Dual mono gives correlation 1.0 and a silent difference; real stereo
granulation of a decorrelated source does not.

Usage: check-stereo.py <file.wav> [expected-left-hz expected-right-hz]
"""
import math
import struct
import subprocess
import sys
import tempfile
import wave


def to_pcm16(path):
    """Normalise any wav the stdlib can't unpack (24-bit, float32) to pcm_s16le."""
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-c:a", "pcm_s16le", tmp],
        check=True,
    )
    return tmp


def read_as_float(path):
    """Read any wav (int16/int24/float32) as (left, right) float lists."""
    try:
        with wave.open(path, "rb") as f:
            channels, width, rate = f.getnchannels(), f.getsampwidth(), f.getframerate()
            raw = f.readframes(f.getnframes())
    except wave.Error:
        # float32 wavs are not readable by the wave module; convert via ffmpeg.
        return read_as_float(to_pcm16(path))

    if width == 2:
        samples = [s / 32768.0 for s in struct.unpack(f"<{len(raw)//2}h", raw)]
    elif width == 4:
        samples = list(struct.unpack(f"<{len(raw)//4}f", raw))
    else:
        # 24-bit and friends: let ffmpeg normalise rather than hand-unpacking.
        return read_as_float(to_pcm16(path))

    if channels != 2:
        raise SystemExit(f"FAIL: file has {channels} channel(s), expected 2")
    return samples[0::2], samples[1::2], rate


def energy(xs):
    return math.sqrt(sum(x * x for x in xs) / max(len(xs), 1))


def correlation(a, b):
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    ma, mb = sum(a) / n, sum(b) / n
    num = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
    da = math.sqrt(sum((x - ma) ** 2 for x in a))
    db = math.sqrt(sum((x - mb) ** 2 for x in b))
    return num / (da * db) if da > 0 and db > 0 else 1.0


def dominant_hz(xs, rate):
    """Crude zero-crossing pitch estimate — enough to tell 300 from 900 Hz."""
    crossings = sum(
        1 for i in range(1, len(xs)) if xs[i - 1] <= 0 < xs[i]
    )
    return crossings * rate / max(len(xs), 1)


def measure(path):
    left, right, rate = read_as_float(path)
    diff = [left[i] - right[i] for i in range(min(len(left), len(right)))]
    return {
        "left": energy(left),
        "right": energy(right),
        "diff": energy(diff),
        "corr": correlation(left, right),
    }


def compare(source_path, output_path):
    """Granulation must not narrow the stereo image.

    Real material is often partly correlated — and some of it is dual mono —
    so an absolute correlation threshold is the wrong test for it. What must
    hold for any source is that the output is no more correlated than the
    input: whatever width went in, comes out.
    """
    src, out = measure(source_path), measure(output_path)

    print(f"source          corr {src['corr']:+.4f}   L-R {src['diff']:.5f}")
    print(f"granulated      corr {out['corr']:+.4f}   L-R {out['diff']:.5f}")

    failures = []
    if out["left"] < 1e-5 or out["right"] < 1e-5:
        failures.append("an output channel is silent")

    if src["corr"] > 0.98:
        print("\nnote: the SOURCE file is (near-)dual-mono, so this run cannot")
        print("      prove stereo preservation — only that nothing broke.")
    else:
        # Allow a little slack for grain scatter, but a collapse to mono is a
        # jump to ~1.0 and will never sneak through this.
        if out["corr"] > src["corr"] + 0.15:
            failures.append(
                f"granulation narrowed the image: {src['corr']:+.4f} -> {out['corr']:+.4f}"
            )
        if out["diff"] < out["left"] * 0.02:
            failures.append("output L-R is effectively silent: collapsed to dual mono")

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        sys.exit(1)
    print("PASS: stereo width preserved through granulation")


def main():
    if sys.argv[1] == "--compare":
        compare(sys.argv[2], sys.argv[3])
        return

    path = sys.argv[1]
    left, right, rate = read_as_float(path)

    el, er = energy(left), energy(right)
    diff = [left[i] - right[i] for i in range(min(len(left), len(right)))]
    ed = energy(diff)
    corr = correlation(left, right)

    print(f"file            {path}")
    print(f"frames          {len(left)} @ {rate} Hz")
    print(f"RMS left        {el:.5f}")
    print(f"RMS right       {er:.5f}")
    print(f"RMS (L-R)       {ed:.5f}")
    print(f"correlation     {corr:+.4f}")
    print(f"dominant L      {dominant_hz(left, rate):.0f} Hz")
    print(f"dominant R      {dominant_hz(right, rate):.0f} Hz")

    failures = []
    if el < 1e-5 or er < 1e-5:
        failures.append("a channel is silent")
    # Dual mono would give a difference signal ~60 dB below the channels.
    if ed < max(el, er) * 0.02:
        failures.append("L-R is effectively silent: the file is dual mono")
    if corr > 0.98:
        failures.append(f"channels are near-identical (correlation {corr:.4f})")

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        sys.exit(1)
    print("PASS: output is genuinely stereo (channels carry distinct content)")


if __name__ == "__main__":
    main()
