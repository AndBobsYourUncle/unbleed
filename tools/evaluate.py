"""Score echo-removal pipelines on a synthetic talk-over-game take built from two calibration takes.

Sound adds linearly in the air, so  mic = voice-only take + game-only take  is a realistic double-talk
recording where the clean voice is known. Each pipeline gets (mic, game reference) and is scored on:
  leak     output level while you're silent (lower = less game leaking)
  echo     output level when fed the game-only take alone
  SI-SDR   similarity to the clean voice while you talk (higher = less damage + less leak)
  PESQ     wideband speech quality vs the clean voice (1-4.5)

usage: evaluate.py <game-take.wav> <voice-take.wav> <outdir>
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf
from pesq import pesq
from scipy.signal import firwin, lfilter, resample_poly, stft, istft

sys.path.insert(0, os.path.dirname(__file__))
from dtln_offline import dtln  # noqa: E402

SR = 48000
AEC3 = os.path.join(os.path.dirname(__file__), "..", "build", "aec3_offline")


def aec3(mic, ref, transparency):
    with tempfile.TemporaryDirectory() as d:
        mic.astype(np.float32).tofile(f"{d}/m"); ref.astype(np.float32).tofile(f"{d}/r")
        subprocess.run([AEC3, f"{d}/m", f"{d}/r", f"{d}/o", str(transparency)], check=True)
        out = np.fromfile(f"{d}/o", np.float32)
    return np.pad(out, (0, len(mic) - len(out)))


NAEC = os.path.join(os.path.dirname(__file__), "..", "build", "naec_offline")
MODEL = os.path.join(os.path.dirname(__file__), "..", "models", "dtln_aec_512")


def naec(mic, ref, band=2, power=2.0, delay=80, model=MODEL):
    """The real-time C++ pipeline, run offline."""
    with tempfile.TemporaryDirectory() as d:
        mic.astype(np.float32).tofile(f"{d}/m"); ref.astype(np.float32).tofile(f"{d}/r")
        subprocess.run([NAEC, model, f"{d}/m", f"{d}/r", f"{d}/o", str(band), str(power), str(delay)], check=True)
        out = np.fromfile(f"{d}/o", np.float32)
    return np.pad(out, (0, len(mic) - len(out)))


def fir_delay_comp(x, taps=255):
    return np.concatenate([x[taps // 2:], np.zeros(taps // 2)])


LP = firwin(255, 7500, fs=SR)
HP = -LP.copy(); HP[127] += 1
BAND = firwin(255, [3000, 7500], fs=SR, pass_zero=False)


DTLN_LATENCY = 1152  # 24 ms at 48 kHz: DTLN's output lags its input by BLOCK - SHIFT samples


def dtln48(mic, ref, size=512):
    """DTLN output at 48 kHz, shifted back into alignment with its input."""
    out = resample_poly(dtln(resample_poly(mic, 1, 3), resample_poly(ref, 1, 3), size), 3, 1)
    return np.concatenate([out[DTLN_LATENCY:], np.zeros(DTLN_LATENCY)])[:len(mic)]


def steer_gain(mic, low, hop=384, attack=0.8, release=0.3, power=1.0):
    """Per-sample gain: how much of the mic's 3-7.5 kHz band DTLN kept, smoothed."""
    e_in = lfilter(BAND, 1, mic) ** 2
    e_out = lfilter(BAND, 1, low) ** 2
    frames = len(mic) // hop
    g = np.zeros(frames); level = 0.0
    for k in range(frames):
        r = np.sqrt((e_out[k * hop:(k + 1) * hop].sum() + 1e-10) / (e_in[k * hop:(k + 1) * hop].sum() + 1e-10))
        t = min(r, 1.0) ** power
        level += (t - level) * (attack if t > level else release)
        g[k] = level
    return np.interp(np.arange(len(mic)), np.arange(frames) * hop + hop / 2, g)


def ref_wiener_highband(mic, ref, hf, delay_ms=79, floor=0.05, over=2.0, smooth_t=0.7):
    """Reference-aware gain on the high band: suppress bins where the delayed game reference explains
    the mic energy. Coupling per bin is learned from frames where the reference dominates."""
    d = int(delay_ms * SR / 1000)
    ref_d = np.concatenate([np.zeros(d), ref[:len(ref) - d]])
    n, hop = 1024, 384
    _, _, M = stft(hf, SR, nperseg=n, noverlap=n - hop)
    _, _, R = stft(lfilter(HP, 1, ref_d), SR, nperseg=n, noverlap=n - hop)
    pm, pr = np.abs(M) ** 2, np.abs(R) ** 2
    # coupling: running min-tracking of mic/ref ratio where ref is active (robust to voice)
    coupling = np.zeros(pm.shape[0]) + 1e-3
    G = np.ones_like(pm); g_prev = np.ones(pm.shape[0])
    for t in range(pm.shape[1]):
        active = pr[:, t] > 1e-9
        ratio = pm[:, t] / (pr[:, t] + 1e-12)
        coupling = np.where(active, np.where(ratio < coupling, 0.7 * coupling + 0.3 * ratio,
                                             0.995 * coupling + 0.005 * ratio), coupling)
        echo = coupling * pr[:, t]
        g = np.clip(1 - over * echo / (pm[:, t] + 1e-12), floor, 1)
        g = np.convolve(g, np.ones(5) / 5, mode="same")           # smooth across frequency (anti-chirp)
        g = smooth_t * g_prev + (1 - smooth_t) * g if True else g  # and across time
        g_prev = g; G[:, t] = g
    _, y = istft(M * G, SR, nperseg=n, noverlap=n - hop)
    return np.pad(y, (0, max(0, len(hf) - len(y))))[:len(hf)]


def hybrid(mic, ref, low=None, hf_src=None, ref_aware=False, **steer):
    low = dtln48(mic, ref) if low is None else low
    hf_src = mic if hf_src is None else hf_src
    g = steer_gain(mic, low, **steer)
    hf = g * lfilter(HP, 1, hf_src)
    if ref_aware:
        hf = ref_wiener_highband(mic, ref, hf)
    return fir_delay_comp(lfilter(LP, 1, low) + hf)


def align(out, voice, max_lag=2400):
    """Shift `out` so it lines up with the clean voice (pipelines have different latencies)."""
    a, b = out[2 * SR:], voice[2 * SR:]
    c = np.fft.irfft(np.fft.rfft(a, 2 * len(a)) * np.conj(np.fft.rfft(b, 2 * len(a))))
    lags = np.concatenate([c[:max_lag + 1], c[-max_lag:]])
    k = int(np.argmax(np.abs(lags))); k = k if k <= max_lag else k - len(lags)
    return np.roll(out, -k), k


def level_db(x):
    return 10 * np.log10(np.mean(x ** 2) + 1e-12)


def si_sdr(est, ref):
    a = np.dot(est, ref) / (np.dot(ref, ref) + 1e-12)
    e = est - a * ref
    return 10 * np.log10(np.sum((a * ref) ** 2) / (np.sum(e ** 2) + 1e-12))


def main():
    game_take, voice_take, outdir = sys.argv[1:4]
    os.makedirs(outdir, exist_ok=True)
    g, _ = sf.read(game_take, dtype="float32"); v, _ = sf.read(voice_take, dtype="float32")
    n = min(len(g), len(v))
    game_mic, ref, voice = g[:n, 0].astype(np.float64), g[:n, 1].astype(np.float64), v[:n, 0].astype(np.float64)
    mic = game_mic + voice

    # voice activity from the clean take, 20 ms frames
    w = SR // 50
    lv = np.array([level_db(voice[k * w:(k + 1) * w]) for k in range(n // w)])
    floor = np.percentile(lv, 5)
    act = np.repeat(lv > floor + 20, w); act = np.pad(act, (0, n - len(act)))
    sil = np.repeat(lv < floor + 6, w); sil = np.pad(sil, (0, n - len(sil)))
    skip = 2 * SR  # let adaptive filters converge before scoring
    act[:skip] = False; sil[:skip] = False

    candidates = {
        "raw mic": lambda m, r: m,
        "aec3 full": lambda m, r: aec3(m, r, 1),
        "aec3 t16": lambda m, r: aec3(m, r, 16),
        "dtln512": lambda m, r: dtln48(m, r),
        "hybrid (last)": lambda m, r: hybrid(m, r, hf_src=aec3(m, r, 10000)),
        "hybrid hf=raw": lambda m, r: hybrid(m, r),
        "hybrid p2": lambda m, r: hybrid(m, r, power=2.0),
        "hybrid p2 fastclose": lambda m, r: hybrid(m, r, power=2.0, release=0.6),
        "hybrid refaware": lambda m, r: hybrid(m, r, ref_aware=True),
        "hybrid p2 refaware": lambda m, r: hybrid(m, r, power=2.0, ref_aware=True),
        "cpp dtln only": lambda m, r: naec(m, r, band=0),
        "cpp steered p2": lambda m, r: naec(m, r, band=1),
        "cpp p2 refaware": lambda m, r: naec(m, r, band=2),
        "aec3 off > dtln": lambda m, r: dtln48(np.roll(aec3(m, r, 10000), -432), r),
        "aec3 off > hybrid": lambda m, r: hybrid(np.roll(aec3(m, r, 10000), -432), r),
    }
    only = [k for k in sys.argv[4:]] or list(candidates)
    candidates = {k: candidates[k] for k in only}
    voice16 = resample_poly(voice, 1, 3)
    hp_voice = lfilter(HP, 1, voice)
    print(f"{'pipeline':<22}{'leak':>7}{'echo':>7}{'SDR':>6}{'PESQ':>6}{'PESQv':>7}{'HFleak':>8}{'HFsdr':>7}")
    for name, fn in candidates.items():
        out, lag = align(fn(mic, ref), voice)
        echo_only = fn(game_mic, ref)
        leak = level_db(out[sil]); echo = level_db(echo_only[skip:])
        sdr = si_sdr(out[act], voice[act])
        q = pesq(16000, voice16[skip // 3:], resample_poly(out, 1, 3)[skip // 3:len(voice16)], "wb")
        vonly, _ = align(fn(voice, np.zeros_like(voice)), voice)  # garbling with no game at all
        qv = pesq(16000, voice16[skip // 3:], resample_poly(vonly, 1, 3)[skip // 3:len(voice16)], "wb")
        hf = lfilter(HP, 1, out)
        hf_leak = level_db(hf[sil]); hf_sdr = si_sdr(hf[act], hp_voice[act])
        print(f"{name:<22}{leak:7.1f}{echo:7.1f}{sdr:6.1f}{q:6.2f}{qv:7.2f}{hf_leak:8.1f}{hf_sdr:7.1f}")
        sf.write(os.path.join(outdir, name.replace(" ", "_").replace("(", "").replace(")", "") + ".wav"),
                 out.astype(np.float32), SR)
    print(f"{'(clean voice)':<22}{level_db(voice[sil]):7.1f}{'':>7}{'':>6}{'4.64':>6}{'4.64':>7}{level_db(hp_voice[sil]):8.1f}")


if __name__ == "__main__":
    main()
