"""Prepare the selected Pixabay downloads. Requires ffmpeg; pass their directory."""
import array
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]
SOUNDS = ROOT / 'ChessTV' / 'Sounds'
RATE = 44100
CLIPS = [
    ('yoink', 'Cartoon Yoink 1', 'floraphonic', 'cartoon-yoink-1-183915', 0.40),
    ('pop', 'Pop Cartoon', 'CreatorsHome', 'pop-cartoon-328167', 0.20),
    ('boing', 'Spring Boing', 'Universfield', 'spring-boing-229170', 0.55),
    ('bonk', 'Cartoon Impact 02', 'Universfield', 'cartoon-impact-02-278820', 0.40),
]


def decode(arguments, data=None):
    raw = subprocess.run(['ffmpeg', '-v', 'error', *arguments,
                          '-f', 'f32le', '-ac', '1', '-ar', str(RATE), 'pipe:1'],
                         input=data, capture_output=True, check=True).stdout
    samples = array.array('f')
    samples.frombytes(raw)
    return samples


def prepare(directory):
    sources = []
    for name, title, author, slug, duration in CLIPS:
        source = directory / f'{author.lower()}-{slug}.mp3'
        samples = decode(['-i', str(source)])
        threshold = max(map(abs, samples)) * 0.005
        active = [i for i, value in enumerate(samples) if abs(value) > threshold]
        samples = samples[max(0, active[0] - 88):min(len(samples), active[-1] + 442)]
        # Lower pitch by five semitones and compress time independently.
        pitch = 2 ** (-5 / 12)
        speed = max(1, len(samples) / RATE / duration)
        samples = decode(['-f', 'f32le', '-ar', str(RATE), '-ac', '1', '-i', 'pipe:0',
                          '-af', f'asetrate={round(RATE*pitch)},aresample={RATE},atempo={speed/pitch}'],
                         samples.tobytes())
        samples = samples[:round(duration * RATE)]
        gain = 0.55 / max(map(abs, samples))
        pcm = array.array('h', (round(value * gain * 32767 * min(1, i / 88, (len(samples)-1-i) / 662))
                               for i, value in enumerate(samples)))
        target = SOUNDS / f'capture-{name}.wav'
        with wave.open(str(target), 'wb') as output:
            output.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
            output.writeframes(pcm.tobytes())
        sources.append(dict(file=target.name, title=title, author=author,
                            url=f'https://pixabay.com/sound-effects/film-special-effects-{slug}/',
                            source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                            duration_seconds=round(len(samples)/RATE, 4)))
        print(f'{target.name}: {len(samples)/RATE:.3f}s')
    (SOUNDS / 'capture-sources.json').write_text(json.dumps(dict(
        license='Pixabay Content License', license_url='https://pixabay.com/service/license-summary/',
        modifications='Silence trimmed; pitch lowered five semitones; duration compressed; peak normalized; fades applied.',
        sources=sources), indent=2) + '\n')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]))
