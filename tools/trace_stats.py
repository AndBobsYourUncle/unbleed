"""Summarise a NAEC_TRACE delay trajectory against when you were talking.
usage: trace_stats.py <trace.txt> <cleaned-voice-track.wav>"""
import sys
import numpy as np
import soundfile as sf

rows = [l.split() for l in open(sys.argv[1]) if l[0].isdigit()]
sec = np.array([int(r[0]) for r in rows]); d = np.array([float(r[1]) for r in rows])
v, _ = sf.read(sys.argv[2], dtype="float32"); v = v.mean(1) if v.ndim > 1 else v
talk = np.array([10 * np.log10(np.mean(v[s * 48000:(s + 1) * 48000] ** 2) + 1e-12) > -45 for s in sec])
near_talk = np.array([talk[max(0, i - 3):i + 1].any() for i in range(len(d))])
changes = np.flatnonzero(np.diff(d) != 0) + 1
print(f"estimate: {d.min():.1f}–{d.max():.1f} ms (std {d.std():.1f}); seconds talking: {talk.sum()}/{len(d)}")
print(f"changes near talking: {near_talk[changes].sum()}, elsewhere: {(~near_talk[changes]).sum()}")
print("trajectory:", " ".join(f"{x:.0f}" for x in d))
