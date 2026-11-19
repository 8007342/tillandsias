# @trace order:2090-ausx (spec: openspec/changes/audio-studio-node-graph, design D3)
"""Standard MIDI File reading, note transforms, and a small SFZ sampler.

The MIDI value passed between nodes is a plain dict:
  {"notes": [{"t": start_s, "d": dur_s, "key": 0..127, "vel": 1..127, "ch": 0..15}],
   "length_s": float, "source": str}
Times are seconds (the tempo map is applied at load), so transforms never need
to know about ticks.

The SFZ sampler supports the subset the CC0 libraries in sfz-libraries.tsv use
for one-shot and sustained playback: <control> default_path, <global>/<master>/
<group>/<region> inheritance, #define and #include, sample, key, lokey, hikey,
pitch_keycenter, lovel, hivel, volume, amplitude, tune, transpose, pan,
trigger=attack, loop_mode one_shot, ampeg_release, offset, seq_length/seq_position
(round-robin), and lorand/hirand (seeded). Anything else is ignored and named
in the render report, so a pipeline can see what was not honoured.
"""
import os
import random
import re
import struct

import numpy as np


# ---- MIDI --------------------------------------------------------------------

def _vlq(b, i):
    v = 0
    while True:
        c = b[i]; i += 1
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            return v, i


def parse_smf(data, source=""):
    if data[:4] != b"MThd":
        raise ValueError("not a Standard MIDI File (no MThd)")
    hlen, fmt, ntrk, div = struct.unpack(">IHHH", data[4:14])
    if div & 0x8000:
        raise ValueError("SMPTE time division is not supported")
    i = 8 + hlen
    events, tempos = [], []
    for _ in range(ntrk):
        if data[i:i + 4] != b"MTrk":
            raise ValueError("bad track chunk")
        tlen = struct.unpack(">I", data[i + 4:i + 8])[0]
        j, end, tick, status = i + 8, i + 8 + tlen, 0, 0
        while j < end:
            dt, j = _vlq(data, j)
            tick += dt
            b0 = data[j]
            if b0 == 0xFF:
                typ = data[j + 1]
                ln, j = _vlq(data, j + 2)
                if typ == 0x51 and ln == 3:
                    tempos.append((tick, int.from_bytes(data[j:j + 3], "big")))
                j += ln
                continue
            if b0 in (0xF0, 0xF7):
                ln, j = _vlq(data, j + 1)
                j += ln
                continue
            if b0 & 0x80:
                status = b0; j += 1
            hi = status & 0xF0
            n = 1 if hi in (0xC0, 0xD0) else 2
            d = data[j:j + n]; j += n
            if hi in (0x80, 0x90):
                events.append((tick, status & 0x0F, d[0], d[1] if hi == 0x90 else 0))
        i = end
    # One tempo per tick (the last event at a tick wins, in track order);
    # 120 bpm until the first tempo event.
    tmap = {}
    for tk, us in tempos:
        tmap[tk] = us
    tempos = sorted(tmap.items())
    if not tempos or tempos[0][0] > 0:
        tempos.insert(0, (0, 500000))

    def seconds(tk):
        s, last_t, last_us = 0.0, 0, 500000
        for t, us in tempos:
            if t >= tk:
                break
            s += (t - last_t) * last_us / div / 1e6
            last_t, last_us = t, us
        return s + (tk - last_t) * last_us / div / 1e6

    events.sort(key=lambda e: (e[0], e[3] == 0 and 0 or 1))
    open_, notes = {}, []
    for tick, ch, key, vel in events:
        if vel > 0:
            open_.setdefault((ch, key), []).append((tick, vel))
        elif open_.get((ch, key)):
            t0, v = open_[(ch, key)].pop(0)
            a = seconds(t0)
            notes.append({"t": a, "d": max(seconds(tick) - a, 0.0), "key": key, "vel": v, "ch": ch})
    notes.sort(key=lambda n: (n["t"], n["key"]))
    length = max((n["t"] + n["d"] for n in notes), default=0.0)
    return {"notes": notes, "length_s": length, "source": source}


def transform(midi, transpose=0, velocity_scale=1.0, time_scale=1.0, quantize_s=0.0,
              channel=-1, min_key=0, max_key=127):
    out = []
    for n in midi["notes"]:
        if channel >= 0 and n["ch"] != channel:
            continue
        k = n["key"] + transpose
        if k < min_key or k > max_key or k < 0 or k > 127:
            continue
        t, d = n["t"] * time_scale, n["d"] * time_scale
        if quantize_s > 0:
            t = round(t / quantize_s) * quantize_s
        v = int(max(1, min(127, round(n["vel"] * velocity_scale))))
        out.append({"t": t, "d": d, "key": k, "vel": v, "ch": n["ch"]})
    length = max((n["t"] + n["d"] for n in out), default=0.0)
    return {"notes": out, "length_s": length, "source": midi.get("source", "")}


# ---- SFZ ---------------------------------------------------------------------

NOTE = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


def note_num(v):
    v = v.strip().lower()
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    m = re.fullmatch(r"([a-g])([#b]?)(-?\d+)", v)
    if not m:
        raise ValueError(f"bad note {v!r}")
    acc = {"#": 1, "b": -1}.get(m.group(2), 0)
    return NOTE[m.group(1)] + acc + (int(m.group(3)) + 1) * 12


def _preprocess(path, defines, root, depth=0):
    """Expand #define and #include. Include paths are relative to the ROOT
    .sfz file's directory (as sfizz and the libraries assume), not to the
    including file."""
    if depth > 16:
        raise ValueError("#include nesting too deep")
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    out = []
    for line in text.splitlines():
        line = re.sub(r"//.*$", "", line)
        m = re.match(r'\s*#define\s+(\$\w+)\s+(.*?)\s*$', line)
        if m:
            defines[m.group(1)] = m.group(2)
            continue
        m = re.match(r'\s*#include\s+"([^"]+)"', line)
        if m:
            inc = os.path.join(root, m.group(1).replace("\\", "/"))
            out.append(_preprocess(inc, defines, root, depth + 1))
            continue
        for k in sorted(defines, key=len, reverse=True):
            line = line.replace(k, defines[k])
        out.append(line)
    return "\n".join(out)


def parse_sfz(path):
    """[region opcode dicts] with header inheritance resolved, and the sample
    paths made absolute."""
    text = _preprocess(path, {}, os.path.dirname(path))
    tokens = re.split(r"(<\w+>)", text)
    level = {"control": {}, "global": {}, "master": {}, "group": {}}
    regions, into = [], None
    for tok in tokens:
        h = re.fullmatch(r"<(\w+)>", tok)
        if h:
            name = h.group(1)
            if name == "region":
                into = {**level["global"], **level["master"], **level["group"]}
                regions.append(into)
            elif name in level:
                level[name] = {}
                if name in ("global", "master"):
                    level["group"] = {}
                if name == "global":
                    level["master"] = {}
                into = level[name]
            else:
                into = None  # <curve>, <effect>, <midi>...: not rendered
            continue
        if into is None:
            continue
        # opcode=value; `sample` values may contain spaces up to the next opcode.
        for m in re.finditer(r"(\w+)=(.*?)(?=\s+\w+=|\s*$)", tok.strip(), flags=re.S):
            into[m.group(1)] = m.group(2).strip()
    base = os.path.dirname(path)
    dpath = level["control"].get("default_path", "")
    out = []
    for r in regions:
        smp = r.get("sample", "")
        # `*sine`, `*silence`, `*noise`: built-in generators, not files; not rendered.
        if smp and not smp.startswith("*"):
            r["_path"] = os.path.normpath(os.path.join(base, dpath, smp.replace("\\", "/")))
            out.append(r)
    return out


HONOURED = {"sample", "key", "lokey", "hikey", "pitch_keycenter", "lovel", "hivel", "volume",
            "amplitude", "tune", "transpose", "pan", "trigger", "loop_mode", "ampeg_release",
            "offset", "seq_length", "seq_position", "lorand", "hirand", "_path",
            "sw_last", "sw_default", "sw_lokey", "sw_hikey"}


def _region_keys(r):
    if "key" in r:
        k = note_num(r["key"]); return k, k, k
    lo = note_num(r.get("lokey", "0")); hi = note_num(r.get("hikey", "127"))
    c = note_num(r["pitch_keycenter"]) if "pitch_keycenter" in r else lo
    return lo, hi, c


def render(midi, regions, load_sample, fs, tail_s=1.0, seed=0, gain_db=0.0):
    """Render the notes through the regions. load_sample(path) -> (array (ch, n), sr).
    Returns (stereo array, report dict)."""
    rng = random.Random(seed)
    length = int((midi["length_s"] + tail_s) * fs) + 1
    out = np.zeros((2, length), dtype=np.float64)
    cache, ignored, missing, unmatched = {}, set(), set(), 0
    for r in regions:
        ignored.update(k for k in r if k not in HONOURED)
    prepared = []
    for r in regions:
        lo, hi, c = _region_keys(r)
        prepared.append((r, lo, hi, c, int(r.get("lovel", 0)), int(r.get("hivel", 127))))
    seq_counter = {}
    # Keyswitches: a note inside a region's sw_lokey..sw_hikey selects the
    # articulation (sw_last) and does not sound; sw_default is the start.
    sw_range = set()
    sw = None
    for r in regions:
        if "sw_lokey" in r and "sw_hikey" in r:
            sw_range.update(range(note_num(r["sw_lokey"]), note_num(r["sw_hikey"]) + 1))
        if sw is None and "sw_default" in r:
            sw = note_num(r["sw_default"])
    for n in midi["notes"]:
        if n["key"] in sw_range:
            sw = n["key"]
            continue
        cand = [p for p in prepared if p[1] <= n["key"] <= p[2] and p[4] <= n["vel"] <= p[5]
                and p[0].get("trigger", "attack") == "attack"
                and ("sw_last" not in p[0] or note_num(p[0]["sw_last"]) == sw)]
        rnd = rng.random()
        cand = [p for p in cand if float(p[0].get("lorand", 0)) <= rnd < float(p[0].get("hirand", 1.0001))]
        seqd = [p for p in cand if "seq_length" in p[0]]
        if seqd:
            pos = seq_counter.get(n["key"], 0)
            seq_counter[n["key"]] = pos + 1
            cand = [p for p in cand if "seq_length" not in p[0]
                    or (pos % int(p[0]["seq_length"])) + 1 == int(p[0].get("seq_position", 1))]
        if not cand:
            unmatched += 1
            continue
        for r, lo, hi, c, _, _ in cand:
            path = r["_path"]
            if path not in cache:
                try:
                    cache[path] = load_sample(path)
                except Exception:
                    cache[path] = None
                    missing.add(os.path.basename(path))
            if cache[path] is None:
                continue
            smp, sr = cache[path]
            if smp.shape[0] == 1:
                smp = np.vstack([smp, smp])
            smp = smp[:2, int(r.get("offset", 0)):]
            semis = n["key"] - c + float(r.get("transpose", 0)) + float(r.get("tune", 0)) / 100.0
            ratio = (2 ** (semis / 12.0)) * sr / fs
            one_shot = r.get("loop_mode") == "one_shot"
            rel = float(r.get("ampeg_release", 0.005))
            dur = smp.shape[1] / sr / (2 ** (semis / 12.0))
            play = dur if one_shot else min(dur, n["d"] + rel)
            m = max(1, int(play * fs))
            pos = np.arange(m) * ratio
            pos = pos[pos < smp.shape[1] - 1]
            if pos.size == 0:
                continue
            seg = np.vstack([np.interp(pos, np.arange(smp.shape[1]), smp[k]) for k in range(2)])
            if not one_shot:
                held = int(n["d"] * fs)
                if seg.shape[1] > held:
                    env = np.ones(seg.shape[1])
                    rl = seg.shape[1] - held
                    env[held:] = np.linspace(1.0, 0.0, rl)
                    seg = seg * env
            amp = (n["vel"] / 127.0) * 10 ** (float(r.get("volume", 0)) / 20.0) * float(r.get("amplitude", 100)) / 100.0
            p = float(r.get("pan", 0)) / 100.0
            seg = seg * amp * np.array([[min(1.0, 1 - p)], [min(1.0, 1 + p)]])
            s0 = int(n["t"] * fs)
            e0 = min(length, s0 + seg.shape[1])
            if e0 > s0:
                out[:, s0:e0] += seg[:, :e0 - s0]
    out *= 10 ** (gain_db / 20.0)
    report = {"notes": len(midi["notes"]), "unmatched_notes": unmatched,
              "regions": len(regions), "missing_samples": sorted(missing),
              "ignored_opcodes": sorted(ignored)}
    return out, report
