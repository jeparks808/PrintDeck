#!/usr/bin/env python3
"""Generate PrintDeck's bundled sounds into Resources/ (rerun to change them).
chime.wav: rising three-note chime (print finished). alarm.wav: two-tone alert (paused / failed).
The app icon comes from apps/tools/make-icons.py (shared by all the apps)."""
import math, os, struct, sys, wave

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
RATE = 22050

def write_wav(name, notes):
    frames = bytearray()
    for freq, dur, vol in notes:
        n = int(RATE * dur)
        for i in range(n):
            t = i / RATE
            env = min(1.0, t / 0.01) * math.exp(-3.0 * t / dur)
            v = vol * env * (math.sin(2 * math.pi * freq * t) + 0.3 * math.sin(4 * math.pi * freq * t))
            frames += struct.pack("<h", int(max(-1, min(1, v)) * 32000))
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(bytes(frames))

write_wav("chime.wav", [(784, 0.22, 0.7), (988, 0.22, 0.7), (1319, 0.6, 0.8)])
write_wav("alarm.wav", [(880, 0.25, 0.8), (660, 0.25, 0.8)] * 3)

print("wrote", sorted(os.listdir(OUT)))
