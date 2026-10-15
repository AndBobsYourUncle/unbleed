"""Analyse an OBS multi-track recording: 1 mix, 2 cleaned mic, 3 game, 4 raw mic.

Reports clipping, levels, game leakage in the cleaned mic, and dropouts in the game track.
usage: analyze_session.py <prefix>   (reads <prefix>_track1..4.wav)
"""
import sys

import numpy as np
import soundfile as sf

prefix = sys.argv[1]
SR = 48000
W = SR // 20  # 50 ms frames
LAG = int(0.043 * SR)  # cleaned mic + game are delayed 43 ms relative to the raw mic

tracks = {}
for i, name in enumerate(["mix", "clean", "game", "raw"], 1):
    x, sr = sf.read(f"{prefix}_track{i}.wav", dtype="float32")
    assert sr == SR
    tracks[name] = x.mean(axis=1) if x.ndim > 1 else x
    peak = np.abs(x).max()
    clipped = int((np.abs(x) > 0.99).sum())
    print(f"track {i} {name:<6} peak {20 * np.log10(peak + 1e-12):6.1f} dBFS   samples ≥ -0.1 dBFS: {clipped}")

raw = tracks["raw"][:len(tracks["raw"]) - LAG]
clean = tracks["clean"][LAG:]
game = tracks["game"][LAG:]
n = min(len(raw), len(clean), len(game)) // W * W


def frames_db(x):
    return 10 * np.log10(np.mean(x[:n].reshape(-1, W) ** 2, axis=1) + 1e-12)


r, c, g = frames_db(raw), frames_db(clean), frames_db(game)
mins = n / SR / 60

# Talking: cleaned mic well above its own floor and close to the raw level.
floor = np.percentile(c, 10)
talking = (c > floor + 20) & (c > r - 6)
game_on = g > -50
print(f"\n{mins:.1f} min analysed; game audible {100 * game_on.mean():.0f}% of the time, you talking ~{100 * talking.mean():.0f}%")

speech = c[talking]
print(f"your voice (cleaned): median {np.median(speech):.1f} dB, loud moments (95th pct) {np.percentile(speech, 95):.1f} dB")
print(f"game track: median {np.median(g[game_on]):.1f} dB, loud moments {np.percentile(g[game_on], 95):.1f} dB "
      f"→ game sits {np.median(speech) - np.median(g[game_on]):.1f} dB under your voice")

# Leakage: game playing, you silent. How loud is the game in the raw mic vs what's left in the cleaned mic?
quiet = game_on & ~talking & (r > np.percentile(r, 20))
if quiet.any():
    print(f"\ngame playing while you're silent ({100 * quiet.mean():.0f}% of the time):")
    print(f"  raw mic hears game at   median {np.median(r[quiet]):.1f} dB")
    print(f"  cleaned mic leaves      median {np.median(c[quiet]):.1f} dB, worst 5% {np.percentile(c[quiet], 95):.1f} dB")
    print(f"  removal                 median {np.median(r[quiet] - c[quiet]):.1f} dB, "
          f"weakest 5% of moments {np.percentile(r[quiet] - c[quiet], 5):.1f} dB")
    # worst leak moments, for listening
    worst = np.argsort(c - 999 * ~quiet)[-5:][::-1]
    print("  loudest leaks at: " + ", ".join(f"{int(k * 0.05 // 60)}:{k * 0.05 % 60:04.1f}" for k in worst))

# Dropouts: game track digitally silent for >2 s while the raw mic hears something loud (game in the room)
silent = g < -100
runs, start = [], None
for k, s in enumerate(silent):
    if s and start is None:
        start = k
    if (not s or k == len(silent) - 1) and start is not None:
        if k - start >= 40 and np.median(r[start:k]) > -45:
            runs.append((start, k))
        start = None
print(f"\ngame-track dropouts (digital silence ≥2 s while the room was loud): {len(runs)}")
for a, b in runs:
    print(f"  {int(a * 0.05 // 60)}:{a * 0.05 % 60:04.1f} – {int(b * 0.05 // 60)}:{b * 0.05 % 60:04.1f}")
