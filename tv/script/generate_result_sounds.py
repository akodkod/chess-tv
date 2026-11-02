"""Generate ChessTV's original, short win/loss chimes (no external assets)."""
import math
from pathlib import Path
import struct
import wave

SAMPLE_RATE = 44100
DESTINATION = Path(__file__).resolve().parents[1] / 'ChessTV' / 'Sounds'

for name, notes in [('win', [523.25, 659.25, 783.99, 1046.50]),
                    ('lose', [392.00, 349.23, 293.66, 261.63])]:
    duration, step = 0.36, 0.16
    samples = [0.0] * int(SAMPLE_RATE * (step * (len(notes) - 1) + duration))
    for index, frequency in enumerate(notes):
        offset = int(index * step * SAMPLE_RATE)
        for frame in range(int(duration * SAMPLE_RATE)):
            t = frame / SAMPLE_RATE
            envelope = min(t / 0.012, 1.0) * (1 - t / duration) ** 2
            tone = math.sin(2 * math.pi * frequency * t)
            tone += 0.15 * math.sin(4 * math.pi * frequency * t)
            samples[offset + frame] += 0.24 * envelope * tone
    with wave.open(str(DESTINATION / f'game-{name}.wav'), 'wb') as output:
        output.setparams((1, 2, SAMPLE_RATE, 0, 'NONE', 'not compressed'))
        output.writeframes(b''.join(struct.pack('<h', round(value * 32767)) for value in samples))
