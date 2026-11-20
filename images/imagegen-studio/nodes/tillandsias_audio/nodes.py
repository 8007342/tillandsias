# @trace order:2090-ausx (spec: openspec/changes/audio-studio-node-graph, design D1-D4)
"""ComfyUI node classes. AUDIO is ComfyUI's own type: {"waveform": tensor
(batch, channels, samples), "sample_rate": int}; batch item 0 is processed
(the studio's audio workflows are batch 1). Every class_type here must also be
a row of images/imagegen-studio/node-classes.tsv (package tillandsias_audio).
"""
import hashlib
import json
import os

import numpy as np
import torch

import folder_paths

from . import dsp, symbolic

CAT = "tillandsias/audio"
MIDI = "TILLANDSIAS_MIDI"

# SFZ instruments live in the read-only model mount (extra_model_paths.yaml
# maps `sfz`); register the folder with an .sfz filter, keeping mapped paths.
_paths = folder_paths.folder_names_and_paths.get("sfz", ([], set()))[0]
folder_paths.folder_names_and_paths["sfz"] = (_paths, {".sfz"})


def _np(audio):
    return audio["waveform"][0].detach().cpu().double().numpy(), int(audio["sample_rate"])


def _audio(x, fs):
    return {"waveform": torch.from_numpy(np.ascontiguousarray(x, dtype=np.float32)).unsqueeze(0), "sample_rate": int(fs)}


def _resample(x, fs, to):
    if fs == to:
        return x
    from scipy.signal import resample_poly
    from math import gcd
    g = gcd(fs, to)
    return resample_poly(x, to // g, fs // g, axis=1)


def _load_sample(path):
    from comfy_extras.nodes_audio import load
    w, sr = load(path)
    return w.double().numpy(), int(sr)


# ---- mix ---------------------------------------------------------------------

class TillandsiasAudioPan:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "position": ("FLOAT", {"default": 0.0, "min": -1.0, "max": 1.0, "step": 0.01})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, position):
        x, fs = _np(audio)
        return (_audio(dsp.pan(x, position), fs),)


class TillandsiasAudioMixBus:
    """Sum up to four stems with per-stem gain (dB) into one bus. Sample rates
    are matched to the first input; lengths to the longest."""
    @classmethod
    def INPUT_TYPES(cls):
        g = ("FLOAT", {"default": 0.0, "min": -60.0, "max": 24.0, "step": 0.1})
        return {"required": {"a": ("AUDIO",), "gain_a_db": g},
                "optional": {"b": ("AUDIO",), "gain_b_db": g, "c": ("AUDIO",), "gain_c_db": g,
                             "d": ("AUDIO",), "gain_d_db": g}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, a, gain_a_db, b=None, gain_b_db=0.0, c=None, gain_c_db=0.0, d=None, gain_d_db=0.0):
        xa, fs = _np(a)
        parts = [(xa, gain_a_db)]
        for s, g in ((b, gain_b_db), (c, gain_c_db), (d, gain_d_db)):
            if s is not None:
                x, f = _np(s)
                parts.append((_resample(x, f, fs), g))
        ch = max(p[0].shape[0] for p in parts)
        n = max(p[0].shape[1] for p in parts)
        out = np.zeros((ch, n))
        for x, g in parts:
            if x.shape[0] != ch:
                x = np.repeat(x[:1], ch, 0)
            out[:, : x.shape[1]] += x * dsp.db_to_gain(g)
        return (_audio(out, fs),)


class TillandsiasAudioCrossfade:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"a": ("AUDIO",), "b": ("AUDIO",),
                             "seconds": ("FLOAT", {"default": 0.5, "min": 0.0, "max": 60.0, "step": 0.01})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, a, b, seconds):
        xa, fs = _np(a)
        xb, fb = _np(b)
        return (_audio(dsp.crossfade(xa, _resample(xb, fb, fs), int(seconds * fs)), fs),)


class TillandsiasAudioLoopSeam:
    """Make a seamless loop: the tail's last `seconds` are crossfaded into the
    head and removed; the output's end flows into its start."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "seconds": ("FLOAT", {"default": 0.05, "min": 0.0, "max": 30.0, "step": 0.001})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, seconds):
        x, fs = _np(audio)
        return (_audio(dsp.loop_seam(x, int(seconds * fs)), fs),)


class TillandsiasAudioEQ:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "kind": (["peak", "lowshelf", "highshelf", "highpass", "lowpass"],),
                             "frequency_hz": ("FLOAT", {"default": 1000.0, "min": 10.0, "max": 24000.0}),
                             "q": ("FLOAT", {"default": 0.707, "min": 0.1, "max": 20.0, "step": 0.01}),
                             "gain_db": ("FLOAT", {"default": 0.0, "min": -24.0, "max": 24.0, "step": 0.1})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, kind, frequency_hz, q, gain_db):
        x, fs = _np(audio)
        return (_audio(dsp.eq(x, fs, kind, frequency_hz, q, gain_db), fs),)


class TillandsiasAudioCompressor:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "threshold_db": ("FLOAT", {"default": -18.0, "min": -60.0, "max": 0.0, "step": 0.1}),
                             "ratio": ("FLOAT", {"default": 4.0, "min": 1.0, "max": 50.0, "step": 0.1}),
                             "attack_ms": ("FLOAT", {"default": 10.0, "min": 0.1, "max": 500.0}),
                             "release_ms": ("FLOAT", {"default": 120.0, "min": 1.0, "max": 5000.0}),
                             "makeup_db": ("FLOAT", {"default": 0.0, "min": -24.0, "max": 24.0, "step": 0.1})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, threshold_db, ratio, attack_ms, release_ms, makeup_db):
        x, fs = _np(audio)
        return (_audio(dsp.compress(x, fs, threshold_db, ratio, attack_ms, release_ms, makeup_db), fs),)


class TillandsiasAudioLimiter:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "ceiling_db": ("FLOAT", {"default": -1.0, "min": -24.0, "max": 0.0, "step": 0.1}),
                             "lookahead_ms": ("FLOAT", {"default": 5.0, "min": 0.1, "max": 50.0, "step": 0.1})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, ceiling_db, lookahead_ms):
        x, fs = _np(audio)
        return (_audio(dsp.limit(x, fs, ceiling_db, lookahead_ms), fs),)


class TillandsiasAudioSaturate:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "drive_db": ("FLOAT", {"default": 6.0, "min": 0.0, "max": 40.0, "step": 0.1}),
                             "mix": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, drive_db, mix):
        x, fs = _np(audio)
        return (_audio(dsp.saturate(x, drive_db, mix), fs),)


# ---- loudness and analysis ----------------------------------------------------

class TillandsiasAudioLoudness:
    """EBU R128 integrated loudness (LUFS) and true peak (dBTP), plus the
    long-term spectrum (centroid, bandwidth). The JSON is the report a
    pipeline or a project-side gate reads."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",)}}
    RETURN_TYPES = ("FLOAT", "FLOAT", "STRING"); RETURN_NAMES = ("lufs", "true_peak_db", "report_json")
    FUNCTION = "run"; CATEGORY = CAT; OUTPUT_NODE = True

    def run(self, audio):
        x, fs = _np(audio)
        lufs = dsp.integrated_lufs(x, fs)
        tp = dsp.true_peak_db(x)
        rep = {"integrated_lufs": lufs, "true_peak_dbtp": tp, "seconds": x.shape[1] / fs,
               "channels": x.shape[0], **dsp.spectrum_stats(x, fs)}
        js = dsp.to_json(rep)
        return {"ui": {"text": [js]}, "result": (float(lufs), float(tp), js)}


class TillandsiasAudioNormalizeLoudness:
    """Gain to an integrated-loudness target, then a lookahead limiter at the
    true-peak ceiling (so a loud target cannot clip)."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "target_lufs": ("FLOAT", {"default": -16.0, "min": -40.0, "max": -5.0, "step": 0.1}),
                             "ceiling_db": ("FLOAT", {"default": -1.0, "min": -12.0, "max": 0.0, "step": 0.1})}}
    RETURN_TYPES = ("AUDIO",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, target_lufs, ceiling_db):
        x, fs = _np(audio)
        now = dsp.integrated_lufs(x, fs)
        if np.isfinite(now):
            x = x * dsp.db_to_gain(target_lufs - now)
        # The limiter works on sample peaks; leave 0.5 dB for inter-sample overs.
        return (_audio(dsp.limit(x, fs, ceiling_db - 0.5, 5.0), fs),)


class TillandsiasAudioScope:
    """Spectrogram (top) and waveform (bottom) as an IMAGE, for audition next
    to the node's audio player (connect to PreviewImage)."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "width": ("INT", {"default": 1024, "min": 128, "max": 4096}),
                             "height": ("INT", {"default": 384, "min": 96, "max": 2048})}}
    RETURN_TYPES = ("IMAGE",); FUNCTION = "run"; CATEGORY = CAT

    def run(self, audio, width, height):
        x, fs = _np(audio)
        return (torch.from_numpy(dsp.scope_image(x, fs, width, height)).unsqueeze(0),)


# ---- grid and export ---------------------------------------------------------

class TillandsiasBarGrid:
    """Bar and beat boundaries (sample-exact) for a constant tempo and meter,
    plus the region [start_bar, end_bar) in seconds for TrimAudioDuration and
    the loop export."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"bpm": ("FLOAT", {"default": 120.0, "min": 20.0, "max": 400.0, "step": 0.01}),
                             "beats_per_bar": ("INT", {"default": 4, "min": 1, "max": 32}),
                             "beat_unit": ([4, 8, 2, 16],),
                             "bars": ("INT", {"default": 8, "min": 1, "max": 4096}),
                             "sample_rate": ("INT", {"default": 48000, "min": 8000, "max": 192000}),
                             "start_bar": ("INT", {"default": 0, "min": 0, "max": 4096}),
                             "end_bar": ("INT", {"default": 8, "min": 1, "max": 4096}),
                             "offset_s": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 3600.0, "step": 0.001})}}
    RETURN_TYPES = ("FLOAT", "FLOAT", "STRING"); RETURN_NAMES = ("start_s", "duration_s", "grid_json")
    FUNCTION = "run"; CATEGORY = CAT

    def run(self, bpm, beats_per_bar, beat_unit, bars, sample_rate, start_bar, end_bar, offset_s):
        g = dsp.bar_grid(bpm, beats_per_bar, int(beat_unit), bars, sample_rate, offset_s)
        if not 0 <= start_bar < end_bar <= bars:
            raise ValueError(f"region bars [{start_bar}, {end_bar}) is outside 0..{bars}")
        s = g["bar_starts_samples"][start_bar] / sample_rate
        e = g["bar_starts_samples"][end_bar] / sample_rate
        g["region"] = {"start_bar": start_bar, "end_bar": end_bar, "start_s": s, "end_s": e}
        return (s, e - s, dsp.to_json(g))


class TillandsiasSaveLoopWAV:
    """Write a WAV with a RIFF smpl loop (and a cue point) plus a JSON manifest
    fragment next to it: file, bytes, sha256, sample rate, channels, length,
    loop points in samples and seconds, loudness. A project-side exporter maps
    the fragment onto its own schema; nothing here knows any project's format."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"audio": ("AUDIO",),
                             "filename_prefix": ("STRING", {"default": "audio/loop"}),
                             "loop_start_s": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 36000.0, "step": 0.001}),
                             "loop_end_s": ("FLOAT", {"default": -1.0, "min": -1.0, "max": 36000.0, "step": 0.001}),
                             "bits": ([24, 16, 32],)},
                "optional": {"grid_json": ("STRING", {"forceInput": True})}}
    RETURN_TYPES = ("STRING",); RETURN_NAMES = ("manifest_json",)
    FUNCTION = "run"; CATEGORY = CAT; OUTPUT_NODE = True

    def run(self, audio, filename_prefix, loop_start_s, loop_end_s, bits, grid_json=None):
        x, fs = _np(audio)
        n = x.shape[1]
        ls = int(round(loop_start_s * fs))
        le = n - 1 if loop_end_s < 0 else int(round(loop_end_s * fs)) - 1
        if not 0 <= ls < le < n:
            raise ValueError(f"loop [{ls}, {le}] is outside the {n}-sample audio")
        out_dir = folder_paths.get_output_directory()
        full, name, counter, sub, _ = folder_paths.get_save_image_path(filename_prefix, out_dir)
        fname = f"{name}_{counter:05}_.wav"
        buf = dsp.wav_with_loop(x, fs, ls, le, int(bits))
        with open(os.path.join(full, fname), "wb") as f:
            f.write(buf)
        man = {"file": os.path.join(sub, fname), "bytes": len(buf),
               "sha256": hashlib.sha256(buf).hexdigest(), "sample_rate": fs,
               "channels": x.shape[0], "samples": n, "seconds": n / fs, "bits": int(bits),
               "loop": {"start_sample": ls, "end_sample_inclusive": le,
                        "start_s": ls / fs, "end_s": (le + 1) / fs},
               "integrated_lufs": dsp.integrated_lufs(x, fs), "true_peak_dbtp": dsp.true_peak_db(x)}
        if grid_json:
            man["grid"] = json.loads(grid_json)
        js = dsp.to_json(man)
        with open(os.path.join(full, fname[:-4] + ".json"), "w") as f:
            f.write(js + "\n")
        return {"ui": {"audio": [{"filename": fname, "subfolder": sub, "type": "output"}], "text": [js]},
                "result": (js,)}


# ---- symbolic ----------------------------------------------------------------

def _list(kind, ext):
    if kind == "input":
        base = folder_paths.get_input_directory()
        out = []
        for root, _, files in os.walk(base):
            out += [os.path.relpath(os.path.join(root, f), base) for f in files if f.lower().endswith(ext)]
        return sorted(out)
    return sorted(f for f in folder_paths.get_filename_list(kind) if f.lower().endswith(ext))


class TillandsiasLoadMIDI:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"midi_file": (_list("input", (".mid", ".midi")) or ["none"],)}}
    RETURN_TYPES = (MIDI, "STRING"); RETURN_NAMES = ("midi", "summary_json")
    FUNCTION = "run"; CATEGORY = CAT

    @classmethod
    def IS_CHANGED(cls, midi_file):
        p = folder_paths.get_annotated_filepath(midi_file)
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()

    def run(self, midi_file):
        p = folder_paths.get_annotated_filepath(midi_file)
        with open(p, "rb") as f:
            m = symbolic.parse_smf(f.read(), midi_file)
        chans = sorted({n["ch"] for n in m["notes"]})
        return (m, dsp.to_json({"notes": len(m["notes"]), "length_s": m["length_s"], "channels": chans}))


class TillandsiasMIDITransform:
    """Transpose, velocity scale, time scale (tempo change), quantise, and part
    extraction by channel and key range."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"midi": (MIDI,),
                             "transpose": ("INT", {"default": 0, "min": -48, "max": 48}),
                             "velocity_scale": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 4.0, "step": 0.01}),
                             "time_scale": ("FLOAT", {"default": 1.0, "min": 0.1, "max": 10.0, "step": 0.001}),
                             "quantize_s": ("FLOAT", {"default": 0.0, "min": 0.0, "max": 4.0, "step": 0.001}),
                             "channel": ("INT", {"default": -1, "min": -1, "max": 15}),
                             "min_key": ("INT", {"default": 0, "min": 0, "max": 127}),
                             "max_key": ("INT", {"default": 127, "min": 0, "max": 127})}}
    RETURN_TYPES = (MIDI,); FUNCTION = "run"; CATEGORY = CAT

    def run(self, midi, transpose, velocity_scale, time_scale, quantize_s, channel, min_key, max_key):
        return (symbolic.transform(midi, transpose, velocity_scale, time_scale, quantize_s,
                                   channel, min_key, max_key),)


class TillandsiasSFZRender:
    """Render MIDI through an SFZ instrument (a drum kit is an SFZ instrument:
    this is also the drum sampler). Instruments come from the read-only `sfz`
    model folder (CC0/CC-BY libraries from sfz-libraries.tsv) or the input
    folder. One call renders one part: one stem."""
    @classmethod
    def INPUT_TYPES(cls):
        inst = [f"models/{f}" for f in _list("sfz", ".sfz")] + [f"input/{f}" for f in _list("input", ".sfz")]
        return {"required": {"midi": (MIDI,),
                             "instrument": (inst or ["none"],),
                             "sample_rate": ("INT", {"default": 48000, "min": 8000, "max": 192000}),
                             "tail_s": ("FLOAT", {"default": 2.0, "min": 0.0, "max": 30.0, "step": 0.1}),
                             "gain_db": ("FLOAT", {"default": 0.0, "min": -60.0, "max": 24.0, "step": 0.1}),
                             "seed": ("INT", {"default": 0, "min": 0, "max": 2 ** 31 - 1})}}
    RETURN_TYPES = ("AUDIO", "STRING"); RETURN_NAMES = ("audio", "report_json")
    FUNCTION = "run"; CATEGORY = CAT

    def run(self, midi, instrument, sample_rate, tail_s, gain_db, seed):
        where, _, rel = instrument.partition("/")
        if where == "models":
            path = folder_paths.get_full_path("sfz", rel)
        elif where == "input":
            path = os.path.join(folder_paths.get_input_directory(), rel)
        else:
            path = None
        if not path or not os.path.isfile(path):
            raise ValueError(f"SFZ instrument not found: {instrument}")
        regions = symbolic.parse_sfz(path)
        x, rep = symbolic.render(midi, regions, _load_sample, sample_rate, tail_s, seed, gain_db)
        rep["instrument"] = instrument
        return (_audio(x, sample_rate), dsp.to_json(rep))


NODE_CLASS_MAPPINGS = {c.__name__: c for c in (
    TillandsiasAudioPan, TillandsiasAudioMixBus, TillandsiasAudioCrossfade, TillandsiasAudioLoopSeam,
    TillandsiasAudioEQ, TillandsiasAudioCompressor, TillandsiasAudioLimiter, TillandsiasAudioSaturate,
    TillandsiasAudioLoudness, TillandsiasAudioNormalizeLoudness, TillandsiasAudioScope,
    TillandsiasBarGrid, TillandsiasSaveLoopWAV,
    TillandsiasLoadMIDI, TillandsiasMIDITransform, TillandsiasSFZRender,
)}
NODE_DISPLAY_NAME_MAPPINGS = {k: k.replace("Tillandsias", "Tillandsias ") for k in NODE_CLASS_MAPPINGS}
