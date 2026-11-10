# @trace order:2055-grzz, order:2055-d9sa
"""audio-tool: the audio studio appliance's one entrypoint.

Runs INSIDE images/audio-studio only (--network=none, uid 1001). The tray's
audio.* MCP tools (crates/tillandsias-headless/src/audio_studio.rs) call it
once per job; the agent can also use the same Python stack for its own
analysis. Every subcommand prints ONE JSON object on stdout; on a refusal it
prints {"error": "<code>: <detail>"} and exits 2.

  audio-tool versions
  audio-tool detect --input <file> [--loop]
  audio-tool transform --op <op> --input <file> --output <file> [--param k=v ...]
  audio-tool tiers --stems <dir> --tiers <json> --output <dir> [--param target_lufs=N]
  audio-tool separate --model htdemucs|htdemucs_6s --weights /models/<file>.safetensors
                      --sha256 <hex> --input <file> --output <dir>
  audio-tool fixture-weights --model <m> --output <file>     (fixtures only)

Paths must be under /work/tmp/audio (the lane's audio scratch volume); the
separation weights under /models (a read-only mount of the one verified file).

Separation (2068-cqis): Demucs HTDemucs on CPU, from the registered
safetensors ONLY. The file must end .safetensors, hash to --sha256, declare
class demucs.htdemucs.HTDemucs with the model's own sources, and fit it
strictly; torch.load is disabled before Demucs is imported, so no pickle can
load by any path. Stems are 32-bit float WAV, <output>/<source>.wav, at the
model's 44.1 kHz stereo, with the measured reconstruction (their sum against
the input) in the result.

Detection (one finding per fault: kind, start and end in seconds, detail):
  click          a sample-level impulse: the linear-prediction residual (LPC
                 order 32, fit on the whole file) above 12x its LOCAL robust
                 level (20 ms median), so a loud passage is not a click, AND
                 above 12x the residual's level in the 5 ms on EACH side of it,
                 so a drum onset (quiet before, noise after) is not a click.
  dropout        an interior run of digital silence of at least 1 ms (leading
                 and trailing silence are not dropouts).
  spectral_hole  a NOTCH at least 400 Hz wide, 25 dB under its own median
                 level, for at least 80 ms, in frames whose overall level is
                 normal, with 400 Hz of content present above and below it (an
                 empty top band between hi-hats is not a hole).
  clipping       runs of at least 3 identical full-scale samples (flat tops),
                 merged across gaps under 10 ms.
  loop_seam      with --loop only: playing the end into the start jumps, by
                 the residual across the wrap point, against its robust level,
                 over 1.5x the 99th percentile of the same measure taken
                 inside the loop (a continuous wrap reads like the interior).
                 The level step either side of the wrap is reported, and never
                 decides (a percussive loop's ends legitimately differ).
Clicks inside a dropout or clipping range (plus 5 ms) are that fault's edges,
not separate findings.
"""

import json
import os
import subprocess
import sys

ROOT = "/work/tmp/audio"
TOOL_VERSION = "3"  # 2068-cqis: separate (Demucs on CPU); 2: 2072-tap8 detect recalibration


def refuse(msg):
    print(json.dumps({"error": msg}))
    sys.exit(2)


def under_root(path, must_exist):
    if not path or not os.path.isabs(path):
        refuse(f"invalid_arguments: {path!r} is not an absolute path under {ROOT}/")
    real = os.path.realpath(path)
    if not (real == ROOT or real.startswith(ROOT + "/")):
        refuse(f"invalid_arguments: {path!r} is not under {ROOT}/")
    if must_exist and not os.path.isfile(real):
        refuse(f"input_missing: {path} is not a file")
    return real


def under_dir(path):
    """An absolute directory path under ROOT (it need not exist yet)."""
    if not path or not os.path.isabs(path):
        refuse(f"invalid_arguments: {path!r} is not an absolute path under {ROOT}/")
    real = os.path.realpath(path)
    if not real.startswith(ROOT + "/"):
        refuse(f"invalid_arguments: {path!r} is not under {ROOT}/")
    return real


def first_line(argv):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        text = (out.stdout or out.stderr or "").strip().splitlines()
        return text[0].strip() if text else "unknown"
    except Exception as e:  # a missing binary is a version of "unknown"
        return f"unavailable: {e}"


def versions():
    import numpy
    import pyloudnorm
    import scipy
    import soundfile

    try:
        import librosa
        librosa_v = librosa.__version__
    except Exception as e:
        librosa_v = f"unavailable: {e}"
    return {
        "audio_tool": TOOL_VERSION,
        "python": sys.version.split()[0],
        "ffmpeg": first_line(["ffmpeg", "-hide_banner", "-version"]),
        "sox": first_line(["sox", "--version"]),
        "rubberband": first_line(["rubberband", "--version"]),
        "numpy": numpy.__version__,
        "scipy": scipy.__version__,
        "librosa": librosa_v,
        "soundfile": soundfile.__version__,
        "pyloudnorm": getattr(pyloudnorm, "__version__", "unknown"),
    }


# ---------------------------------------------------------------- detection

def runs(mask):
    """[start, end) index pairs of the True runs in a boolean array."""
    import numpy as np

    if mask.size == 0:
        return []
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    return list(zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)))


def merge(pairs, gap):
    out = []
    for s, e in sorted(pairs):
        if out and s - out[-1][1] <= gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def lpc(x, order):
    import numpy as np
    from scipy.linalg import solve_toeplitz

    # Only lags 0..order: one dot product each, O(n * order). The full
    # np.correlate this replaced is O(n^2) and never returned on an 86 s
    # stereo file (2066-azxa).
    n = len(x)
    r = np.array([np.dot(x[:n - k], x[k:]) for k in range(order + 1)])
    if r[0] <= 0:
        return np.zeros(order)
    r = r.copy()
    r[0] *= 1.0 + 1e-9  # a whisker of regularisation for pure tones
    return solve_toeplitz(r[:order], r[1:order + 1])


def residual(x, a):
    from scipy.signal import lfilter
    import numpy as np

    return lfilter(np.concatenate(([1.0], -a)), [1.0], x)


CLICK_RATIO = 12.0
# Calibrated by kumbias on v56.11.10.1 (2026-11-10, this ref): wrap/interior_p99
# on continuous wraps (rolled, crossfaded, frame-aligned re-encodes) read at
# most 0.93; a real off-wrap cut 6.9; Opus codec steps at misaligned game-loop
# wraps 1.05-9.47. 1.5 flags the cut and every codec step from 1.64 up, and
# keeps every good wrap; the smallest codec steps (1.05-1.34) go unreported.
SEAM_FACTOR = 1.5
DROPOUT_SECS = 0.001


def two_sided(mag, s, e, sr):
    """The larger of the residual's robust levels just BEFORE [s, e) and just
    AFTER it (5 ms each, 0.5 ms clear of the event). An impulse stands out
    against both; a transient into sustained noise does not (2072-tap8)."""
    import numpy as np

    g, w = max(1, int(0.0005 * sr)), max(8, int(0.005 * sr))
    pre = mag[max(0, s - g - w):max(0, s - g)]
    post = mag[min(len(mag), e + g):min(len(mag), e + g + w)]
    lv = [float(np.median(v)) / 0.6745 for v in (pre, post) if v.size]
    return max(lv) if lv else 0.0


def seam_ratio(e, p, w, order):
    """The residual's peak within 8 samples of index p over its robust level in
    the w samples either side (64 samples clear): the loop-seam measure, taken
    at the wrap and at interior points alike (2072-tap8)."""
    import numpy as np

    joint = np.abs(e[p - 8:p + 8]).max()
    ref = np.concatenate((e[max(order, p - w):p - 64], e[p + 64:p + w]))
    return float(joint / max(robust_sigma(ref), 1e-9))


def robust_sigma(v):
    import numpy as np

    med = np.median(v)
    return 1.4826 * np.median(np.abs(v - med))


def detect(path, loop):
    import numpy as np
    import soundfile as sf
    from scipy.ndimage import median_filter
    from scipy.signal import stft

    data, sr = sf.read(path, dtype="float64", always_2d=True)
    n, channels = data.shape
    mono = data.mean(axis=1)
    sec = lambda i: round(float(i) / sr, 4)
    findings = []
    lsb = 1.5 / 32768.0

    # dropout: interior digital silence >= 1 ms (2072-tap8: was 5 ms, and a
    # planted 1 ms dropout in a drum loop went unreported)
    dropouts = []
    for s, e in runs(np.abs(mono) <= lsb):
        if s > 0 and e < n and e - s >= int(DROPOUT_SECS * sr):
            dropouts.append((s, e))
            findings.append({"kind": "dropout", "start": sec(s), "end": sec(e),
                             "detail": {"samples": int(e - s)}})

    # clipping: >= 3 identical full-scale samples, per channel
    clips = []
    for c in range(channels):
        x = np.abs(data[:, c])
        full = x.max() if n else 0.0
        if full < 0.98:
            continue
        flat = x >= full - 0.5 / 32768.0
        rr = [(s, e) for s, e in runs(flat) if e - s >= 3]
        for s, e in merge(rr, int(0.010 * sr)):
            clips.append((s, e))
            findings.append({"kind": "clipping", "start": sec(s), "end": sec(e),
                             "detail": {"channel": c, "level": round(float(full), 5)}})

    # click: LPC residual against its local robust level
    order = 32
    a = lpc(mono, order) if n > 4 * order else None
    if a is not None:
        e = residual(mono, a)
        mag = np.abs(e)
        glob = max(robust_sigma(e), 1e-9)
        local = median_filter(mag, size=max(3, int(0.020 * sr) | 1), mode="nearest") / 0.6745
        local = np.maximum(local, 0.1 * glob)
        cand = (mag > CLICK_RATIO * local) & (mag > 1e-3)
        cand[:order] = False
        guard = int(0.005 * sr)
        masked = [(s - guard, e2 + guard) for s, e2 in dropouts + clips]
        for s, e2 in merge(runs(cand), int(0.002 * sr)):
            if any(s < me and e2 > ms for ms, me in masked):
                continue
            # 2072-tap8: a drum onset passes the centred test above (quiet
            # before, loud after), so the impulse must also stand out against
            # the residual on BOTH sides of it. An impulse returns to the floor
            # after it; a drum hit keeps exciting the residual.
            ratio = mag[s:max(e2, s + 1)].max() / max(two_sided(mag, s, max(e2, s + 1), sr), 0.1 * glob)
            if ratio < CLICK_RATIO:
                continue
            findings.append({"kind": "click", "start": sec(s), "end": sec(max(e2, s + 1)),
                             "detail": {"peak_ratio": round(float(ratio), 1)}})

    # spectral hole: a band 25 dB under its own median, in normal-level frames
    nper = 2048
    if n >= 4 * nper:
        hop = nper // 4
        f, t, z = stft(mono, fs=sr, window="hann", nperseg=nper, noverlap=nper - hop)
        p = 10.0 * np.log10(np.abs(z) ** 2 + 1e-20)
        ref = np.median(p, axis=1)
        level = 10.0 * np.log10((np.abs(z) ** 2).sum(axis=0) + 1e-20)
        active = level >= np.median(level) - 6.0
        considered = ref >= ref.max() - 70.0
        idx = np.flatnonzero(considered)
        df = f[1] - f[0]
        holes = []  # (frame, flo, fhi)
        for ti in range(p.shape[1]):
            if not active[ti] or idx.size == 0:
                continue
            m = p[idx, ti] < ref[idx] - 25.0
            # 2072-tap8: a hole is a NOTCH, with at least 400 Hz of content
            # present on both sides of it in the same frame. A top band that is
            # empty between hi-hats is the music's shape, not a fault, and it
            # tracked the transients and the frame alignment.
            k = int(np.ceil(400.0 / df))
            present = [(ps, pe) for ps, pe in runs(~m) if pe - ps >= k]
            best = None
            for s, e2 in runs(m):
                if not (any(pe <= s for _, pe in present) and any(ps >= e2 for ps, _ in present)):
                    continue
                lo, hi = f[idx[s]], f[idx[e2 - 1]] + df
                if hi - lo >= 400.0 and (best is None or hi - lo > best[1] - best[0]):
                    best = (lo, hi)
            if best:
                holes.append((ti, best[0], best[1]))
        groups = []
        for ti, lo, hi in holes:
            g = groups[-1] if groups else None
            if g and ti - g["last"] <= 2 and lo < g["hi"] and hi > g["lo"]:
                g["last"], g["lo"], g["hi"] = ti, min(g["lo"], lo), max(g["hi"], hi)
            else:
                groups.append({"first": ti, "last": ti, "lo": lo, "hi": hi})
        half = hop / 2.0 / sr
        for g in groups:
            s, e2 = t[g["first"]] - half, t[g["last"]] + half
            if e2 - s >= 0.080:
                findings.append({"kind": "spectral_hole", "start": round(float(max(s, 0.0)), 4),
                                 "end": round(float(min(e2, n / sr)), 4),
                                 "detail": {"low_hz": round(float(g["lo"])), "high_hz": round(float(g["hi"]))}})

    # loop seam: play the end into the start
    if loop and a is not None and n > 2 * 4096 + 64:
        w = 4096
        y = np.concatenate((mono[-w:], mono[:w]))
        jump = seam_ratio(residual(y, a), w, w, order)
        # 2072-tap8: a WRAP IS ONE MORE POINT OF THE LOOP. A continuous wrap
        # reads like the loop's own interior, so the wrap is judged against the
        # same measure taken on a grid of interior points, not against a fixed
        # floor: kumbias' 7 good game-loop wraps read residual_ratio 6-166 under
        # audio-tool 1 (ordinary musical change across a bar line) and a real
        # off-wrap cut 287, so no fixed floor separates them. The grid has at
        # least 64 points (every 509 samples on a long loop), so even a short
        # loop has an interior to compare against. The level step is reported but decides nothing: a percussive loop's
        # first and last 50 ms legitimately differ (a kick on the one), and
        # kumbias' rolled and crossfaded controls read 7-14 dB with no seam.
        e_loop = residual(mono, a)
        grid = np.linspace(w, n - w - 1, num=max(64, (n - 2 * w) // 509)).astype(int)
        p99 = float(np.quantile([seam_ratio(e_loop, p, w, order) for p in grid], 0.99))
        k = int(0.050 * sr)
        rms = lambda v: float(np.sqrt(np.mean(v ** 2)) + 1e-12)
        step = abs(20.0 * np.log10(rms(mono[-k:]) / rms(mono[:k])))
        if jump > SEAM_FACTOR * p99:
            findings.append({"kind": "loop_seam", "start": sec(n - int(0.010 * sr)), "end": sec(n),
                             "detail": {"residual_ratio": round(float(jump), 1),
                                        "interior_p99": round(p99, 1),
                                        "level_step_db": round(step, 1)}})

    findings.sort(key=lambda x: (x["start"], x["kind"]))
    return {"input": path, "sample_rate": int(sr), "channels": int(channels),
            "duration": round(n / sr, 4), "loop": bool(loop), "findings": findings}


# --------------------------------------------------------------- transforms

def num(params, key, default, lo, hi):
    v = params.get(key, default)
    try:
        v = float(v)
    except (TypeError, ValueError):
        refuse(f"invalid_arguments: {key} must be a number")
    if not (lo <= v <= hi):
        refuse(f"invalid_arguments: {key}={v} is outside [{lo}, {hi}]")
    return v


def ext(path, allowed, op):
    e = os.path.splitext(path)[1].lower()
    if e not in allowed:
        refuse(f"invalid_arguments: {op} writes {', '.join(allowed)}, not {e or 'no extension'}")


def run(argv):
    r = subprocess.run(argv, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        refuse(f"engine_failed: {argv[0]} exited {r.returncode}: {(r.stderr or '').strip()[-400:]}")


def loudness(path):
    import pyloudnorm as pyln
    import soundfile as sf

    data, sr = sf.read(path, dtype="float64", always_2d=True)
    return data, sr, pyln.Meter(sr).integrated_loudness(data)


def transform(op, src, dst, params):
    import numpy as np
    import soundfile as sf

    meas = {}
    if op == "loudness_normalise":
        target = num(params, "target_lufs", -16.0, -40.0, -5.0)
        ext(dst, [".wav", ".flac"], op)
        data, sr, before = loudness(src)
        if not np.isfinite(before):
            refuse("invalid_arguments: the input is silent; its loudness is undefined")
        out = data * 10.0 ** ((target - before) / 20.0)
        peak = float(np.abs(out).max())
        if peak > 1.0 and str(params.get("allow_clip", "false")).lower() != "true":
            refuse(f"would_clip: reaching {target} LUFS needs a peak of {20 * np.log10(peak):.1f} dBFS; lower target_lufs or pass allow_clip=true")
        sf.write(dst, np.clip(out, -1.0, 1.0), sr, subtype="PCM_24")
        argv = ["pyloudnorm", "integrated", f"gain_db={target - before:.3f}"]
        meas = {"lufs_before": round(float(before), 2), "lufs_after": round(float(loudness(dst)[2]), 2),
                "peak_dbfs_after": round(float(20 * np.log10(max(peak, 1e-12))), 2)}
    elif op == "time_stretch":
        ratio = num(params, "ratio", 1.0, 0.25, 4.0)
        semis = num(params, "pitch_semitones", 0.0, -24.0, 24.0)
        ext(dst, [".wav", ".flac"], op)
        argv = ["rubberband", "-q", "-t", repr(ratio), "-p", repr(semis), src, dst]
        run(argv)
        meas = {"duration_in": round(sf.info(src).duration, 4), "duration_out": round(sf.info(dst).duration, 4)}
    elif op == "to_opus":
        kbps = int(num(params, "bitrate_kbps", 128, 6, 510))
        ext(dst, [".opus", ".ogg"], op)
        argv = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", src,
                "-c:a", "libopus", "-b:a", f"{kbps}k", dst]
        run(argv)
    elif op == "to_aac":
        kbps = int(num(params, "bitrate_kbps", 192, 32, 512))
        ext(dst, [".m4a", ".aac"], op)
        argv = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", src,
                "-c:a", "aac", "-b:a", f"{kbps}k", dst]
        run(argv)
    elif op == "resample":
        rate = int(num(params, "rate", 48000, 8000, 192000))
        ext(dst, [".wav", ".flac"], op)
        argv = ["sox", src, dst, "rate", "-v", str(rate)]
        run(argv)
    else:
        refuse(f"invalid_arguments: unknown op {op!r} (loudness_normalise, time_stretch, to_opus, to_aac, resample)")
    if not os.path.isfile(dst):
        refuse(f"engine_failed: {op} wrote no output")
    return {"op": op, "input": src, "output": dst, "params": params, "argv": argv, "measurements": meas}


# --------------------------------------------------------------- tiers
# @trace order:2055-d9sa

def tiers(stems_dir, spec, out_dir, params):
    """Cumulative mixes from separated stems (vertical layering, 2055-d9sa).

    stems_dir holds one <name>.wav/.flac per stem, all at one sample rate and
    length. spec is a JSON list of tiers; each tier lists EVERY stem it
    contains (["drums"], ["drums", "bass"], ...), so a tier never depends on
    the order of the others. Each tier's mix is the plain sum of its stems
    times ONE gain that brings it to target_lufs (pyloudnorm, BS.1770), so a
    mix contains exactly its stems: no per-stem rebalancing, no song form.
    Written as 32-bit float WAV, tier-<n>.wav, n from 1.
    """
    import numpy as np
    import soundfile as sf

    target = num(params, "target_lufs", -16.0, -40.0, -5.0)
    allow_clip = str(params.get("allow_clip", "false")).lower() == "true"
    try:
        plan = json.loads(spec)
    except (TypeError, ValueError) as e:
        refuse(f"invalid_arguments: --tiers is not JSON: {e}")
    if not (isinstance(plan, list) and plan and all(
            isinstance(t, list) and t and all(isinstance(s, str) and s for s in t) for t in plan)):
        refuse("invalid_arguments: --tiers must be a non-empty list of non-empty lists of stem names")
    if not os.path.isdir(stems_dir):
        refuse(f"input_missing: {stems_dir} is not a directory")
    stems, sr, length = {}, None, None
    for name in sorted(os.listdir(stems_dir)):
        base, e = os.path.splitext(name)
        if e.lower() not in (".wav", ".flac"):
            continue
        data, rate = sf.read(os.path.join(stems_dir, name), dtype="float64", always_2d=True)
        if sr is None:
            sr, length, channels = rate, data.shape[0], data.shape[1]
        if rate != sr or data.shape[0] != length or data.shape[1] != channels:
            refuse(f"invalid_arguments: stem {name} is {rate} Hz x {data.shape[0]} x {data.shape[1]}ch; "
                   f"every stem must match {sr} Hz x {length} x {channels}ch")
        if base in stems:
            refuse(f"invalid_arguments: two files name stem {base!r}")
        stems[base] = data
    for t in plan:
        for s in t:
            if s not in stems:
                refuse(f"invalid_arguments: tier {t} names stem {s!r}; the stems are {sorted(stems)}")
        if len(set(t)) != len(t):
            refuse(f"invalid_arguments: tier {t} names a stem twice")
    import pyloudnorm as pyln
    meter = pyln.Meter(sr)
    planned = []
    for n, t in enumerate(plan, 1):
        mix = sum(stems[s] for s in t)
        before = meter.integrated_loudness(mix)
        if not np.isfinite(before):
            refuse(f"invalid_arguments: tier {n} ({'+'.join(t)}) is silent; its loudness is undefined")
        gain_db = target - before
        out = mix * 10.0 ** (gain_db / 20.0)
        peak = float(np.abs(out).max())
        if peak > 1.0 and not allow_clip:
            refuse(f"would_clip: tier {n} ({'+'.join(t)}) at {target} LUFS peaks at {20 * np.log10(peak):.1f} dBFS; "
                   "lower target_lufs or pass allow_clip=true")
        planned.append((n, t, out, before, gain_db, peak))
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for n, t, out, before, gain_db, peak in planned:
        dst = os.path.join(out_dir, f"tier-{n}.wav")
        if os.path.exists(dst):
            refuse(f"output_exists: {dst}")
        sf.write(dst, out, sr, subtype="FLOAT")
        written.append({"tier": n, "stems": t, "output": dst, "gain_db": round(float(gain_db), 3),
                        "lufs_before": round(float(before), 2),
                        "lufs_after": round(float(meter.integrated_loudness(out)), 2),
                        "peak_dbfs": round(float(20 * np.log10(max(peak, 1e-12))), 2)})
    return {"op": "tiers", "stems_dir": stems_dir, "stems": sorted(stems), "sample_rate": sr,
            "target_lufs": target, "tiers": written}


# ---------------------------------------------------------------- separation

MODELS_ROOT = "/models"
# audio.separate's models: the class every weights file must declare, and its
# sources in the maintainer's order (read from both safetensors headers,
# 2026-11-10). Nothing else is ever instantiated from a file's metadata.
DEMUCS_CLASS = "demucs.htdemucs.HTDemucs"
DEMUCS_SOURCES = {
    "htdemucs": ["drums", "bass", "other", "vocals"],
    "htdemucs_6s": ["drums", "bass", "other", "vocals", "guitar", "piano"],
}


def no_pickles():
    """Disable torch.load BEFORE Demucs is imported: its own loaders
    (states.load_model on a path, solver checkpoints) call it on .th pickles.
    Every weight here arrives as safetensors, so any call is a defect, and
    it fails loudly instead of unpickling."""
    import torch
    import torch.serialization

    def refused(*_a, **_k):
        refuse("pickle_refused: torch.load was called; the audio studio loads safetensors only (2068-cqis)")

    torch.load = refused
    torch.serialization.load = refused
    return torch


def read_safetensors(buf, what):
    """(metadata, header) of a safetensors buffer, parsed here so the bytes
    that were hashed are the bytes that are loaded."""
    import struct
    if len(buf) < 8:
        refuse(f"weights_refused: {what} is not a safetensors file (too short)")
    (n,) = struct.unpack("<Q", buf[:8])
    if n <= 0 or 8 + n > len(buf):
        refuse(f"weights_refused: {what} is not a safetensors file (header length {n})")
    try:
        header = json.loads(buf[8:8 + n])
    except ValueError as e:
        refuse(f"weights_refused: {what} is not a safetensors file ({e})")
    if not isinstance(header, dict):
        refuse(f"weights_refused: {what} has no safetensors header object")
    meta = header.get("__metadata__")
    if not isinstance(meta, dict):
        refuse(f"weights_refused: {what} carries no model metadata")
    return meta


def decode_args(v):
    """The maintainer's JSON for init args: fractions as {_type: fraction}."""
    from fractions import Fraction
    if isinstance(v, dict):
        if v.get("_type") == "fraction":
            return Fraction(int(v["numerator"]), int(v["denominator"]))
        return {k: decode_args(x) for k, x in v.items()}
    if isinstance(v, list):
        return [decode_args(x) for x in v]
    return v


def load_demucs(model, weights, sha256):
    """The model, from exactly the registered safetensors file."""
    import hashlib
    if model not in DEMUCS_SOURCES:
        refuse(f"invalid_arguments: model must be one of {', '.join(DEMUCS_SOURCES)}, got {model!r}")
    if not weights or not os.path.isabs(weights):
        refuse(f"invalid_arguments: --weights {weights!r} is not an absolute path under {MODELS_ROOT}/")
    real = os.path.realpath(weights)
    if not real.startswith(MODELS_ROOT + "/"):
        refuse(f"invalid_arguments: --weights {weights!r} is not under {MODELS_ROOT}/")
    if not real.endswith(".safetensors"):
        refuse(f"weights_refused: {weights} is not a .safetensors file; the audio studio never loads "
               "a pickle (.th, .pt, .ckpt), whatever its hash")
    if not (sha256 and len(sha256) == 64 and all(c in "0123456789abcdef" for c in sha256)):
        refuse("invalid_arguments: --sha256 must be 64 lowercase hex")
    if not os.path.isfile(real):
        refuse(f"input_missing: {weights} is not a file (is the weights cache mounted?)")
    with open(real, "rb") as fh:
        buf = fh.read()
    got = hashlib.sha256(buf).hexdigest()
    if got != sha256:
        refuse(f"weights_refused: {weights} has sha256 {got}, not the registered {sha256}")
    meta = read_safetensors(buf, weights)
    if meta.get("klass") != DEMUCS_CLASS:
        refuse(f"weights_refused: {weights} declares class {meta.get('klass')!r}; only {DEMUCS_CLASS} is built")
    if "structure" in meta:
        refuse(f"weights_refused: {weights} is a packed (quantised) state; only a plain state is loaded")
    try:
        args = decode_args(json.loads(meta.get("args", "[]")))
        kwargs = decode_args(json.loads(meta.get("kwargs", "{}")))
    except (ValueError, KeyError, TypeError) as e:
        refuse(f"weights_refused: {weights} has unreadable init arguments: {e}")
    if args != [] or not isinstance(kwargs, dict):
        refuse(f"weights_refused: {weights} has positional or malformed init arguments")
    if kwargs.get("sources") != DEMUCS_SOURCES[model]:
        refuse(f"weights_refused: {weights} separates {kwargs.get('sources')}, not {model}'s {DEMUCS_SOURCES[model]}")
    torch = no_pickles()
    from safetensors.torch import load as st_load
    from demucs.htdemucs import HTDemucs
    tensors = st_load(buf)
    net = HTDemucs(**kwargs)
    try:
        net.load_state_dict(tensors, strict=True)
    except RuntimeError as e:
        refuse(f"weights_refused: {weights} does not fit {model}: {str(e)[:300]}")
    net.eval()
    return torch, net, got


def separate(model, weights, sha256, src, out_dir):
    """Split src into the model's stems, as 32-bit float WAV at the model's
    rate and channel count, <out_dir>/<source>.wav. Reports how well the stems
    sum back to the input as the model saw it (resampled to its rate, mono
    duplicated to stereo): Demucs does not constrain the sum, so this is a
    measurement, never forced by giving one stem the remainder."""
    import random
    import numpy as np
    import soundfile as sf

    torch, net, digest = load_demucs(model, weights, sha256)
    if os.path.exists(out_dir) and os.listdir(out_dir):
        refuse(f"output_exists: {out_dir} is not empty")
    try:
        wav, sr = sf.read(src, dtype="float32", always_2d=True)
    except Exception as e:
        refuse(f"invalid_arguments: {src} is not readable audio: {e}")
    if wav.shape[0] == 0:
        refuse(f"invalid_arguments: {src} is empty")
    if wav.shape[1] == 1:
        wav = np.repeat(wav, 2, axis=1)
    elif wav.shape[1] != net.audio_channels:
        refuse(f"invalid_arguments: {src} has {wav.shape[1]} channels; separation takes mono or stereo")
    if sr != net.samplerate:
        import soxr
        wav = soxr.resample(wav, sr, net.samplerate, quality="VHQ").astype(np.float32)
    mix = torch.from_numpy(np.ascontiguousarray(wav.T))  # (channels, frames)
    ref = mix.mean(0)
    mean, std = float(ref.mean()), float(ref.std()) + 1e-8
    from demucs.apply import apply_model
    torch.set_num_threads(max(1, os.cpu_count() or 1))
    random.seed(0)
    torch.manual_seed(0)
    try:
        with torch.no_grad():
            stems = apply_model(net, ((mix - mean) / std)[None], device="cpu", shifts=1, split=True,
                                overlap=0.25, progress=False, num_workers=0)[0]
    except RuntimeError as e:
        refuse(f"engine_failed: separation failed: {str(e)[:400]}")
    # Undo the normalisation; the offset goes in once across the stems, so
    # their sum carries the input's DC exactly once.
    stems = stems * std + mean / len(net.sources)
    s = stems.numpy().astype(np.float64)
    x = mix.numpy().astype(np.float64)
    err = x - s.sum(axis=0)
    sig_e, err_e = float((x * x).sum()), float((err * err).sum())
    snr = float("inf") if err_e == 0 else 10 * np.log10(max(sig_e, 1e-30) / err_e)
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for name, y in zip(net.sources, s):
        dst = os.path.join(out_dir, f"{name}.wav")
        sf.write(dst, y.T.astype(np.float32), net.samplerate, subtype="FLOAT")
        written.append({"source": name, "output": dst,
                        "rms_dbfs": round(float(10 * np.log10(max(float((y * y).mean()), 1e-20))), 2)})
    import demucs
    return {"op": "separate", "model": model, "weights_sha256": digest, "sources": list(net.sources),
            "sample_rate": net.samplerate, "channels": net.audio_channels, "frames": int(x.shape[1]),
            "input_sample_rate": sr, "stems": written,
            "reconstruction": {"snr_db": round(snr, 2) if np.isfinite(snr) else None,
                               "max_abs_error": round(float(np.abs(err).max()), 6),
                               "reference": f"the input at {net.samplerate} Hz, {net.audio_channels} channels"},
            "engine": {"torch": torch.__version__, "demucs": demucs.__version__, "device": "cpu",
                       "shifts": 1, "overlap": 0.25, "threads": torch.get_num_threads()}}


def fixture_weights(model, out):
    """FIXTURES ONLY: a RANDOMLY INITIALISED model of the registered class,
    written as safetensors with the maintainer's metadata layout, so a gate
    host with no acknowledged Demucs weights still exercises the loader, the
    refusals and the stem writer. It separates nothing meaningfully."""
    if model not in DEMUCS_SOURCES:
        refuse(f"invalid_arguments: model must be one of {', '.join(DEMUCS_SOURCES)}")
    torch = no_pickles()
    from safetensors.torch import save_file
    from demucs.htdemucs import HTDemucs
    torch.manual_seed(0)
    # The registered models' depth, segment and transformer shape with 8
    # channels instead of 48, so it is small and fast. The segment is written
    # in the maintainer's fraction JSON, so the decoder is exercised too.
    meta_kwargs = {"sources": DEMUCS_SOURCES[model], "samplerate": 44100, "audio_channels": 2,
                   "segment": {"_type": "fraction", "numerator": 39, "denominator": 5},
                   "channels": 8, "bottom_channels": 0, "t_layers": 1, "t_heads": 2}
    net = HTDemucs(**decode_args(meta_kwargs))
    kwargs = meta_kwargs
    sd = {k: v.contiguous() for k, v in net.state_dict().items()}
    if os.path.exists(out):
        refuse(f"output_exists: {out}")
    save_file(sd, out, metadata={"klass": DEMUCS_CLASS, "args": "[]", "kwargs": json.dumps(kwargs)})
    import hashlib
    with open(out, "rb") as fh:
        return {"op": "fixture-weights", "model": model, "output": out,
                "sha256": hashlib.sha256(fh.read()).hexdigest()}


def main(argv):
    if not argv:
        refuse("invalid_arguments: usage: audio-tool versions | detect --input F [--loop] | transform --op OP --input F --output F [--param k=v ...] | tiers --stems DIR --tiers JSON --output DIR [--param target_lufs=N] | separate --model M --weights /models/F.safetensors --sha256 H --input F --output DIR")
    cmd, rest = argv[0], argv[1:]
    opts, params, flags = {}, {}, set()
    i = 0
    while i < len(rest):
        k = rest[i]
        if k in ("--loop",):
            flags.add(k)
            i += 1
        elif k in ("--input", "--output", "--op", "--stems", "--tiers", "--model", "--weights", "--sha256") and i + 1 < len(rest):
            opts[k] = rest[i + 1]
            i += 2
        elif k == "--param" and i + 1 < len(rest) and "=" in rest[i + 1]:
            key, val = rest[i + 1].split("=", 1)
            params[key] = val
            i += 2
        else:
            refuse(f"invalid_arguments: unexpected {k!r}")
    if cmd == "versions":
        result = versions()
    elif cmd == "detect":
        result = detect(under_root(opts.get("--input"), True), "--loop" in flags)
        result["versions"] = versions()
    elif cmd == "tiers":
        stems_dir = under_dir(opts.get("--stems"))
        out_dir = under_dir(opts.get("--output"))
        result = tiers(stems_dir, opts.get("--tiers"), out_dir, params)
        result["versions"] = versions()
    elif cmd == "transform":
        src = under_root(opts.get("--input"), True)
        dst = under_root(opts.get("--output"), False)
        if os.path.exists(dst):
            refuse(f"output_exists: {opts['--output']}")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        result = transform(opts.get("--op"), src, dst, params)
        result["versions"] = versions()
    elif cmd == "separate":
        src = under_root(opts.get("--input"), True)
        out_dir = under_dir(opts.get("--output"))
        result = separate(opts.get("--model", "htdemucs"), opts.get("--weights"), opts.get("--sha256"),
                          src, out_dir)
        result["versions"] = versions()
    elif cmd == "fixture-pickle-probe":
        # FIXTURES ONLY: Demucs's own .th loader, behind the tripwire. The
        # file the fixture passes is not a pickle (no pickle ever comes onto a
        # machine); an unpickling error instead of pickle_refused means
        # torch.load ran.
        no_pickles()
        from demucs.states import load_model
        load_model(opts.get("--weights"))
        refuse("engine_failed: demucs.states.load_model returned without calling torch.load")
    elif cmd == "fixture-weights":
        dst = under_root(opts.get("--output"), False)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        result = fixture_weights(opts.get("--model", "htdemucs"), dst)
    else:
        refuse(f"invalid_arguments: unknown subcommand {cmd!r}")
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
