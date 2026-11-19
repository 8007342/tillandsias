# @trace order:2090-ausx (spec: openspec/changes/audio-studio-node-graph, design D2)
"""Pure numpy/scipy DSP shared by the ComfyUI node pack and (later) audio-tool.

Every function takes and returns float arrays shaped (channels, samples). No
ComfyUI, torch or I/O import here, so the same file can be copied into
images/audio-studio unchanged (design D2: one implementation, two callers).
"""
import json
import math
import struct

import numpy as np
from scipy.ndimage import minimum_filter1d, uniform_filter1d
from scipy.signal import lfilter, stft


def db_to_gain(db):
    return 10.0 ** (db / 20.0)


def gain_to_db(g):
    return 20.0 * math.log10(max(g, 1e-12))


# ---- mix ---------------------------------------------------------------------

def pan(x, position):
    """Constant-power pan, position -1 (left) .. 1 (right). Mono becomes stereo."""
    if x.shape[0] == 1:
        x = np.vstack([x, x])
    theta = (position + 1.0) * math.pi / 4.0
    return np.vstack([x[0] * math.cos(theta) * math.sqrt(2), x[1] * math.sin(theta) * math.sqrt(2)])


def match_channels(a, b):
    if a.shape[0] == b.shape[0]:
        return a, b
    if a.shape[0] == 1:
        return np.repeat(a, b.shape[0], 0), b
    if b.shape[0] == 1:
        return a, np.repeat(b, a.shape[0], 0)
    raise ValueError(f"channel counts differ: {a.shape[0]} and {b.shape[0]}")


def crossfade(a, b, n):
    """a then b, overlapping n samples with an equal-power fade."""
    a, b = match_channels(a, b)
    n = int(min(n, a.shape[1], b.shape[1]))
    if n <= 0:
        return np.concatenate([a, b], axis=1)
    t = np.linspace(0.0, 1.0, n, endpoint=True)
    fo, fi = np.cos(t * math.pi / 2), np.sin(t * math.pi / 2)
    mid = a[:, -n:] * fo + b[:, :n] * fi
    return np.concatenate([a[:, :-n], mid, b[:, n:]], axis=1)


def loop_seam(x, n):
    """A seamless loop: the last n samples are crossfaded into the first n and
    dropped, so playing the result end-to-start is continuous. Length L - n."""
    n = int(min(n, x.shape[1] // 2))
    if n <= 0:
        return x.copy()
    t = np.linspace(0.0, 1.0, n, endpoint=False)
    fi, fo = np.sin(t * math.pi / 2), np.cos(t * math.pi / 2)
    out = x[:, : x.shape[1] - n].copy()
    out[:, :n] = x[:, :n] * fi + x[:, -n:] * fo
    return out


def saturate(x, drive_db, mix):
    d = db_to_gain(drive_db)
    wet = np.tanh(x * d) / math.tanh(d) if d > 0 else x
    return (1.0 - mix) * x + mix * wet


# ---- filters (RBJ cookbook biquads) -----------------------------------------

def biquad(kind, fs, f0, q, gain_db=0.0):
    a_ = 10 ** (gain_db / 40.0)
    w0 = 2 * math.pi * f0 / fs
    cw, sw = math.cos(w0), math.sin(w0)
    alpha = sw / (2 * q)
    if kind == "peak":
        b = [1 + alpha * a_, -2 * cw, 1 - alpha * a_]; a = [1 + alpha / a_, -2 * cw, 1 - alpha / a_]
    elif kind == "lowshelf":
        s = 2 * math.sqrt(a_) * alpha
        b = [a_ * ((a_ + 1) - (a_ - 1) * cw + s), 2 * a_ * ((a_ - 1) - (a_ + 1) * cw), a_ * ((a_ + 1) - (a_ - 1) * cw - s)]
        a = [(a_ + 1) + (a_ - 1) * cw + s, -2 * ((a_ - 1) + (a_ + 1) * cw), (a_ + 1) + (a_ - 1) * cw - s]
    elif kind == "highshelf":
        s = 2 * math.sqrt(a_) * alpha
        b = [a_ * ((a_ + 1) + (a_ - 1) * cw + s), -2 * a_ * ((a_ - 1) + (a_ + 1) * cw), a_ * ((a_ + 1) + (a_ - 1) * cw - s)]
        a = [(a_ + 1) - (a_ - 1) * cw + s, 2 * ((a_ - 1) - (a_ + 1) * cw), (a_ + 1) - (a_ - 1) * cw - s]
    elif kind == "highpass":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]; a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "lowpass":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]; a = [1 + alpha, -2 * cw, 1 - alpha]
    else:
        raise ValueError(f"unknown filter {kind}")
    return np.array(b) / a[0], np.array(a) / a[0]


def eq(x, fs, kind, f0, q, gain_db):
    f0 = min(f0, fs * 0.49)
    b, a = biquad(kind, fs, f0, q, gain_db)
    return lfilter(b, a, x, axis=1)


# ---- dynamics ----------------------------------------------------------------

def _smooth(target, att, rel):
    """One-pole attack/release smoothing of a gain-reduction curve (dB, <= 0)."""
    out = np.empty_like(target)
    g = 0.0
    for i, t in enumerate(target):
        c = att if t < g else rel
        g = c * g + (1 - c) * t
        out[i] = g
    return out


def compress(x, fs, threshold_db, ratio, attack_ms, release_ms, makeup_db):
    """Feed-forward compressor, linked channels, computed on 1 ms blocks (the
    envelope is interpolated back to samples)."""
    blk = max(1, int(fs / 1000))
    n = x.shape[1]
    nb = -(-n // blk)
    pad = np.pad(np.max(np.abs(x), axis=0), (0, nb * blk - n))
    level = 20 * np.log10(np.maximum(pad.reshape(nb, blk).max(axis=1), 1e-9))
    over = np.maximum(level - threshold_db, 0.0)
    target = -over * (1.0 - 1.0 / max(ratio, 1.0))
    att = math.exp(-1.0 / max(attack_ms, 0.01))
    rel = math.exp(-1.0 / max(release_ms, 0.01))
    gr = _smooth(target, att, rel)
    curve = np.interp(np.arange(n), np.arange(nb) * blk + blk / 2, gr)
    return x * db_to_gain(makeup_db) * (10 ** (curve / 20.0))


def limit(x, fs, ceiling_db, lookahead_ms):
    """Lookahead brickwall limiter. The gain is the moving average (window L)
    of the moving minimum (window 2L+1) of the per-sample required gain, so it
    never exceeds the required gain at any sample: the output peak is at most
    the ceiling, with no hard clip."""
    ceil = db_to_gain(ceiling_db)
    peak = np.max(np.abs(x), axis=0)
    need = np.minimum(1.0, ceil / np.maximum(peak, 1e-12))
    L = max(1, int(fs * lookahead_ms / 1000.0))
    g = minimum_filter1d(need, size=2 * L + 1, mode="nearest")
    g = uniform_filter1d(g, size=L, mode="nearest")
    g = np.minimum(g, need)  # float rounding guard
    return x * g


# ---- loudness (ITU-R BS.1770-4 / EBU R128) ----------------------------------

def k_weight(x, fs):
    """BS.1770 K-weighting at any rate (libebur128's bilinear design; at
    48 kHz it reproduces the Recommendation's tabulated coefficients)."""
    f0, g, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = math.tan(math.pi * f0 / fs)
    vh = 10 ** (g / 20.0)
    vb = vh ** 0.4996667741545416
    a0 = 1 + k / q + k * k
    b1 = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0]
    a1 = [1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
    f0, q = 38.13547087602444, 0.5003270373238773
    k = math.tan(math.pi * f0 / fs)
    a0 = 1 + k / q + k * k
    a2 = [1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
    return lfilter([1.0, -2.0, 1.0], a2, lfilter(b1, a1, x, axis=1), axis=1)


def integrated_lufs(x, fs):
    """Gated integrated loudness, LUFS. Channel weights 1.0 (L, R, C, mono)."""
    y = k_weight(x, fs)
    blk, hop = int(0.4 * fs), int(0.1 * fs)
    if y.shape[1] < blk:
        y = np.pad(y, ((0, 0), (0, blk - y.shape[1])))
    starts = range(0, y.shape[1] - blk + 1, hop)
    z = np.array([np.mean(y[:, s:s + blk] ** 2, axis=1).sum() for s in starts])
    lk = -0.691 + 10 * np.log10(np.maximum(z, 1e-20))
    z1 = z[lk > -70.0]
    if z1.size == 0:
        return -math.inf
    rel = -0.691 + 10 * math.log10(z1.mean()) - 10.0
    z2 = z[(lk > -70.0) & (lk > rel)]
    if z2.size == 0:
        return -math.inf
    return -0.691 + 10 * math.log10(z2.mean())


def true_peak_db(x):
    """Peak after 4x oversampling (BS.1770 Annex 2 approximation), dBTP."""
    from scipy.signal import resample_poly
    up = resample_poly(x, 4, 1, axis=1)
    return gain_to_db(float(np.max(np.abs(up))) if up.size else 0.0)


# ---- analysis ------------------------------------------------------------------

def spectrum_stats(x, fs, floor_db=-60.0):
    """Long-term spectrum: centroid, the -floor_db rolloff ('bandwidth'), and
    the energy share above 16 kHz (a lossy-codec lowpass shows as ~0)."""
    mono = x.mean(axis=0)
    f, _, Z = stft(mono, fs=fs, nperseg=4096, noverlap=3072)
    p = (np.abs(Z) ** 2).mean(axis=1)
    tot = p.sum() + 1e-20
    pdb = 10 * np.log10(p / (p.max() + 1e-20) + 1e-20)
    above = np.nonzero(pdb > floor_db)[0]
    return {
        "sample_rate": fs,
        "centroid_hz": float((f * p).sum() / tot),
        "bandwidth_hz": float(f[above[-1]]) if above.size else 0.0,
        "bandwidth_floor_db": floor_db,
        "energy_above_16k": float(p[f >= 16000].sum() / tot),
        "rms_dbfs": gain_to_db(float(np.sqrt(np.mean(x ** 2))) if x.size else 0.0),
        "peak_dbfs": gain_to_db(float(np.max(np.abs(x))) if x.size else 0.0),
    }


def scope_image(x, fs, width=1024, height=384):
    """An RGB float image (H, W, 3): log spectrogram above, waveform below."""
    mono = x.mean(axis=0)
    sh = height * 2 // 3
    wh = height - sh
    _, _, Z = stft(mono, fs=fs, nperseg=1024, noverlap=768)
    S = 20 * np.log10(np.abs(Z) + 1e-9)
    S = np.clip((S - (S.max() - 90)) / 90.0, 0, 1)[::-1]
    cols = np.linspace(0, S.shape[1] - 1, width).astype(int)
    rows = np.linspace(0, S.shape[0] - 1, sh).astype(int)
    spec = S[rows][:, cols]
    img = np.zeros((height, width, 3), dtype=np.float32)
    img[:sh, :, 0] = spec ** 0.7
    img[:sh, :, 1] = spec ** 1.5
    img[:sh, :, 2] = 0.3 + 0.7 * spec ** 3 * (spec > 0.05)
    edges = np.linspace(0, len(mono), width + 1).astype(int)
    mid = sh + wh // 2
    for c in range(width):
        seg = mono[edges[c]:max(edges[c + 1], edges[c] + 1)]
        if seg.size == 0:
            continue
        hi = int(mid - np.clip(seg.max(), -1, 1) * (wh // 2 - 1))
        lo = int(mid - np.clip(seg.min(), -1, 1) * (wh // 2 - 1))
        img[hi:lo + 1, c, 1] = 0.9
        img[hi:lo + 1, c, 0] = 0.4
    img[mid, :, :] = np.maximum(img[mid, :, :], 0.25)
    return img


# ---- bar grid and loop export ----------------------------------------------

def bar_grid(bpm, beats_per_bar, beat_unit, bars, fs, offset_s=0.0):
    """Sample-exact bar and beat boundaries for a constant tempo and meter.
    A quarter-note bpm is converted for the beat unit (6/8 at 120 = 6 eighths)."""
    beat_s = 60.0 / bpm * (4.0 / beat_unit)
    bar_s = beat_s * beats_per_bar
    return {
        "bpm": bpm, "meter": f"{beats_per_bar}/{beat_unit}", "sample_rate": fs,
        "offset_s": offset_s, "beat_s": beat_s, "bar_s": bar_s, "bars": bars,
        "bar_starts_samples": [int(round((offset_s + i * bar_s) * fs)) for i in range(bars + 1)],
        "beat_starts_samples": [int(round((offset_s + i * beat_s) * fs)) for i in range(bars * beats_per_bar + 1)],
    }


def wav_with_loop(x, fs, loop_start, loop_end, bits=24):
    """WAV bytes (PCM 16/24 or float 32) with a RIFF `smpl` chunk carrying one
    forward loop [loop_start, loop_end] (inclusive end, as the chunk defines),
    and a `cue ` point at loop_start."""
    ch, n = x.shape
    y = np.clip(x, -1.0, 1.0).T
    if bits == 16:
        data = (y * 32767.0).round().astype("<i2").tobytes(); fmt_tag = 1
    elif bits == 24:
        v = (y * 8388607.0).round().astype("<i4").reshape(-1)
        b = v.view(np.uint8).reshape(-1, 4)[:, :3]
        data = b.tobytes(); fmt_tag = 1
    else:
        data = y.astype("<f4").tobytes(); fmt_tag = 3; bits = 32
    ba = ch * bits // 8
    fmt = struct.pack("<HHIIHH", fmt_tag, ch, fs, fs * ba, ba, bits)
    period = int(round(1e9 / fs))
    smpl = struct.pack("<9I", 0, 0, period, 60, 0, 0, 0, 1, 0)
    smpl += struct.pack("<6I", 0, 0, int(loop_start), int(loop_end), 0, 0)
    cue = struct.pack("<I", 1) + struct.pack("<II4sIII", 1, int(loop_start), b"data", 0, 0, int(loop_start))

    def chunk(tag, body):
        return tag + struct.pack("<I", len(body)) + body + (b"\0" if len(body) % 2 else b"")

    body = b"WAVE" + chunk(b"fmt ", fmt) + chunk(b"cue ", cue) + chunk(b"smpl", smpl) + chunk(b"data", data)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def read_wav_loop(buf):
    """(loop_start, loop_end) from a WAV's smpl chunk, or None. For tests."""
    i = 12
    while i + 8 <= len(buf):
        tag, size = buf[i:i + 4], struct.unpack("<I", buf[i + 4:i + 8])[0]
        if tag == b"smpl":
            s = buf[i + 8:i + 8 + size]
            if struct.unpack("<I", s[28:32])[0] >= 1:
                return struct.unpack("<II", s[36 + 8:36 + 16])
        i += 8 + size + (size & 1)
    return None


def to_json(obj):
    return json.dumps(obj, sort_keys=True)
