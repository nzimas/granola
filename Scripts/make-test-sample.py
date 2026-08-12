#!/usr/bin/env python3
"""Generate a stereo test sample whose channels are unmistakably different.

Left  = 300 Hz sine, Right = 900 Hz sine. If anything in the signal path
collapses the file to mono, the two channels become identical and the stereo
checks in Scripts/check-stereo.py fail loudly instead of subtly.
"""
import math
import struct
import sys
import wave

OUT = sys.argv[1] if len(sys.argv) > 1 else "build/test-stereo.wav"
RATE = 48000
SECONDS = 4.0
LEFT_HZ = 300.0
RIGHT_HZ = 900.0

frames = bytearray()
for n in range(int(RATE * SECONDS)):
    t = n / RATE
    # A slow amplitude ramp gives the waveform overview something to draw.
    envelope = 0.35 + 0.3 * math.sin(2 * math.pi * 0.25 * t)
    left = math.sin(2 * math.pi * LEFT_HZ * t) * envelope
    right = math.sin(2 * math.pi * RIGHT_HZ * t) * envelope
    frames += struct.pack("<hh", int(left * 32767), int(right * 32767))

with wave.open(OUT, "wb") as f:
    f.setnchannels(2)
    f.setsampwidth(2)
    f.setframerate(RATE)
    f.writeframes(bytes(frames))

print(f"wrote {OUT}: {SECONDS}s stereo, L={LEFT_HZ}Hz R={RIGHT_HZ}Hz")
