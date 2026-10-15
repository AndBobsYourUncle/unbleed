"""Offline check of DTLN-aec on a stream-audio recording (raw mic, system audio, AEC3 variants...).

Writes, for each model size: the DTLN output alone (16 kHz content, saved at 48 kHz), and a hybrid
that uses DTLN below 7.5 kHz and an AEC3 channel above it. Prints the same level/dropout stats as
the Swift split tool so results are comparable.

usage: dtln_offline.py <recording.wav> <outprefix> [highband-channel=4]
"""
import sys

import numpy as np
import soundfile as sf
from ai_edge_litert.interpreter import Interpreter
from scipy.signal import firwin, lfilter, resample_poly

MODELS = "third_party/DTLN-aec/pretrained_models/dtln_aec_{}_{}.tflite"
BLOCK, SHIFT = 512, 128


def dtln(mic, lpb, size):
    """Streaming DTLN-aec at 16 kHz, block by block, exactly as it would run live."""
    m1 = Interpreter(model_path=MODELS.format(size, 1))
    m2 = Interpreter(model_path=MODELS.format(size, 2))
    m1.allocate_tensors(); m2.allocate_tensors()
    i1, o1 = m1.get_input_details(), m1.get_output_details()
    i2, o2 = m2.get_input_details(), m2.get_output_details()
    s1 = np.zeros(i1[1]["shape"], np.float32)
    s2 = np.zeros(i2[1]["shape"], np.float32)

    pad = np.zeros(BLOCK - SHIFT)
    mic = np.concatenate([pad, mic, pad]); lpb = np.concatenate([pad, lpb, pad])
    out = np.zeros(len(mic))
    buf_mic = np.zeros(BLOCK, np.float32); buf_lpb = np.zeros(BLOCK, np.float32)
    buf_out = np.zeros(BLOCK, np.float32)
    for k in range((len(mic) - (BLOCK - SHIFT)) // SHIFT):
        buf_mic = np.roll(buf_mic, -SHIFT); buf_mic[-SHIFT:] = mic[k * SHIFT:(k + 1) * SHIFT]
        buf_lpb = np.roll(buf_lpb, -SHIFT); buf_lpb[-SHIFT:] = lpb[k * SHIFT:(k + 1) * SHIFT]
        spec = np.fft.rfft(buf_mic)
        m1.set_tensor(i1[0]["index"], np.abs(spec).reshape(1, 1, -1).astype(np.float32))
        m1.set_tensor(i1[2]["index"], np.abs(np.fft.rfft(buf_lpb)).reshape(1, 1, -1).astype(np.float32))
        m1.set_tensor(i1[1]["index"], s1)
        m1.invoke()
        mask = m1.get_tensor(o1[0]["index"]); s1 = m1.get_tensor(o1[1]["index"])
        est = np.fft.irfft(spec * mask).reshape(1, 1, -1).astype(np.float32)
        m2.set_tensor(i2[1]["index"], s2)
        m2.set_tensor(i2[0]["index"], est)
        m2.set_tensor(i2[2]["index"], buf_lpb.reshape(1, 1, -1))
        m2.invoke()
        block = m2.get_tensor(o2[0]["index"]); s2 = m2.get_tensor(o2[1]["index"])
        buf_out = np.roll(buf_out, -SHIFT); buf_out[-SHIFT:] = 0
        buf_out += np.squeeze(block)
        out[k * SHIFT:(k + 1) * SHIFT] = buf_out[:SHIFT]
    return out[BLOCK - SHIFT:BLOCK - SHIFT + len(mic) - 2 * len(pad)]


def steered_highband(mic48, low48, high_src, sr=48000, hop=384):
    """High band (> 7.5 kHz) of `high_src`, gated by how much DTLN kept of the mic's 3-7.5 kHz band.

    DTLN only sees up to 8 kHz; this transfers its keep/suppress decision upward instead of running a
    second suppressor (which is what produced the chirps).
    """
    band = firwin(255, [3000, 7500], fs=sr, pass_zero=False)
    e_in = lfilter(band, 1, mic48) ** 2
    e_out = lfilter(band, 1, low48) ** 2
    frames = len(mic48) // hop
    g = np.zeros(frames)
    level = 0.0
    for k in range(frames):
        ratio = np.sqrt((e_out[k * hop:(k + 1) * hop].sum() + 1e-10) / (e_in[k * hop:(k + 1) * hop].sum() + 1e-10))
        target = min(ratio, 1.0)
        # open fast (consonants), close a little slower (avoid pumping)
        level += (target - level) * (0.8 if target > level else 0.3)
        g[k] = level
    gain = np.interp(np.arange(len(mic48)), np.arange(frames) * hop + hop / 2, g)
    hp = -firwin(255, 7500, fs=sr); hp[127] += 1
    return gain * lfilter(hp, 1, high_src)


def stats(name, x, sr=48000):
    w = sr // 20
    lv = np.array([10 * np.log10(np.mean(x[k * w:(k + 1) * w] ** 2) + 1e-12) for k in range(len(x) // w)])
    gaps = sum(1 for k in range(1, len(lv) - 1) if lv[k] < min(lv[k - 1], lv[k + 1]) - 20)
    span = np.sort(lv[60:320])
    print(f"{name:<14} quietest-10% {span[len(span) // 10]:6.1f} dB  loudest-10% {span[len(span) * 9 // 10]:6.1f} dB  gaps {gaps}")


def main():
    path, prefix = sys.argv[1], sys.argv[2]
    high_ch = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    rec, sr = sf.read(path, dtype="float32")
    assert sr == 48000
    raw, game, high = rec[:, 0], rec[:, 1], rec[:, high_ch]

    # Linear-phase crossover at 7.5 kHz; the high-pass is the exact complement so the bands sum flat.
    taps = 255
    lp = firwin(taps, 7500, fs=sr)
    hp = -lp; hp[taps // 2] += 1
    delay = taps // 2

    stats("raw", raw)
    for size in (128, 256, 512):
        low = dtln(resample_poly(raw, 1, 3), resample_poly(game, 1, 3), size)
        low48 = resample_poly(low, 3, 1)[:len(raw)].astype(np.float32)
        sf.write(f"{prefix}_dtln{size}.wav", low48, sr)
        stats(f"dtln{size}", low48)
        hybrid = lfilter(lp, 1, low48) + lfilter(hp, 1, high)
        hybrid = np.concatenate([hybrid[delay:], np.zeros(delay)]).astype(np.float32)
        sf.write(f"{prefix}_hybrid{size}.wav", hybrid, sr)
        stats(f"hybrid{size}", hybrid)


if __name__ == "__main__":
    main()
