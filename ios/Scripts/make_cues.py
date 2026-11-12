#!/usr/bin/env python3
"""Writes Parla's start/stop cues deterministically (stdlib only): two soft sine notes each, rising to start, falling to stop."""
from pathlib import Path
import math, struct, wave

RATE = 44_100
ROOT = Path(__file__).resolve().parents[1] / 'Resources'

def note(freq, seconds, gain=0.32):
    out = []
    for i in range(int(RATE * seconds)):
        t = i / RATE
        envelope = min(1.0, t / 0.008) * math.exp(-t * 9)  # 8 ms attack, gentle exponential decay
        tone = math.sin(2 * math.pi * freq * t) + 0.18 * math.sin(4 * math.pi * freq * t)
        out.append(gain * envelope * tone / 1.18)
    return out

def write(name, notes):
    samples = [s for freq, seconds in notes for s in note(freq, seconds)] + [0.0] * int(RATE * 0.02)
    with wave.open(str(ROOT / name), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b''.join(struct.pack('<h', round(max(-1, min(1, s)) * 32767)) for s in samples))

if __name__ == '__main__':
    write('dictation-start.wav', [(659.25, 0.09), (987.77, 0.16)])  # E5 then B5
    write('dictation-stop.wav', [(987.77, 0.09), (659.25, 0.16)])   # B5 then E5
    for name in ['dictation-start.wav', 'dictation-stop.wav']:
        with wave.open(str(ROOT / name)) as w:
            assert (w.getnchannels(), w.getframerate(), w.getsampwidth()) == (1, RATE, 2) and 0.2 < w.getnframes() / RATE < 0.4
    print('Wrote Resources/dictation-start.wav and Resources/dictation-stop.wav')
