# @trace order:2090-ausx (spec: openspec/changes/audio-studio-node-graph, task 1.7)
# Property self-test of the tillandsias_audio node pack. Runs INSIDE the studio
# image only, CPU, no network (never on the host), from the checkout root:
#   podman run --rm --network none \
#     -v $PWD/images/imagegen-studio/nodes:/pack:ro,Z \
#     -v $PWD/images/imagegen-studio:/t:ro,Z --entrypoint python \
#     <the locally built tillandsias-imagegen-studio image> /t/audio-nodes-selftest.py
# One ok/FAIL line per property, then ALL OK (exit 0) or FAILED n (exit 1).
# Pre-fix result: FAILS (ModuleNotFoundError: tillandsias_audio).
import os, sys, struct, tempfile, wave, json
sys.argv = ["selftest", "--cpu"]
sys.path.insert(0, "/opt/comfyui")
sys.path.insert(0, "/pack")
import comfy.options; comfy.options.enable_args_parsing()
import numpy as np, torch
import folder_paths
tmp = tempfile.mkdtemp()
folder_paths.set_output_directory(os.path.join(tmp, "out")); os.makedirs(os.path.join(tmp, "out"))
folder_paths.set_input_directory(os.path.join(tmp, "in")); os.makedirs(os.path.join(tmp, "in/inst/samples"))
import tillandsias_audio as P
from tillandsias_audio import dsp, symbolic
N = P.NODE_CLASS_MAPPINGS
fs = 48000
def A(x): return {"waveform": torch.tensor(x, dtype=torch.float32)[None], "sample_rate": fs}
def X(a): return a["waveform"][0].double().numpy()
t = np.arange(fs * 3) / fs
sine = np.vstack([0.5 * np.sin(2 * np.pi * 1000 * t)] * 2)
ok = []
def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name, detail); ok.append(bool(cond))

# loudness: 1 kHz stereo sine at -6.02 dBFS peak -> BS.1770 reads about -6.0+... ref: 0 dBFS 1k sine mono = -3.01 LUFS
lufs, tp, js = N["TillandsiasAudioLoudness"]().run(A(sine))["result"]
ref = -3.01 + 20*np.log10(0.5) + 3.01  # two channels add 3.01
check("loudness 1k stereo sine", abs(lufs - ref) < 0.1, f"{lufs:.3f} vs {ref:.3f}")
check("true peak", abs(tp - 20*np.log10(0.5)) < 0.1, f"{tp:.3f}")
check("bandwidth near 1k", 900 < json.loads(js)["bandwidth_hz"] < 1500, json.loads(js)["bandwidth_hz"])
norm = X(N["TillandsiasAudioNormalizeLoudness"]().run(A(sine * 0.1), -14.0, -1.0)[0])
check("normalize to -14", abs(dsp.integrated_lufs(norm, fs) + 14) < 0.2, dsp.integrated_lufs(norm, fs))
loud = X(N["TillandsiasAudioLimiter"]().run(A(sine * 1.8), -1.0, 5.0)[0])
check("limiter ceiling", np.abs(loud).max() <= 10**(-1/20) + 1e-6, np.abs(loud).max())
c = X(N["TillandsiasAudioCompressor"]().run(A(sine), -20.0, 4.0, 5.0, 50.0, 0.0)[0])
check("compressor reduces", np.abs(c[:, fs:]).max() < 0.5 * 0.5, np.abs(c[:, fs:]).max())
p = X(N["TillandsiasAudioPan"]().run(A(sine[:1]), -1.0)[0])
check("pan hard left", np.abs(p[1]).max() < 1e-6 and np.abs(p[0]).max() > 0.6)
cf = X(N["TillandsiasAudioCrossfade"]().run(A(sine), A(sine), 0.5)[0])
check("crossfade length", cf.shape[1] == 2*sine.shape[1] - fs//2, cf.shape)
# loop seam: a ramp-ish signal; after seam the wrap step must be small
noise = np.vstack([np.cumsum(np.random.default_rng(1).normal(0, 0.001, fs*2))]*2)
noise -= noise.mean()
ls = X(N["TillandsiasAudioLoopSeam"]().run(A(noise), 0.1)[0])
wrap = np.abs(ls[0, -1] - ls[0, 0]); raw = np.abs(noise[0, -1] - noise[0, 0])
check("loop seam wrap", wrap < 0.01 and ls.shape[1] == noise.shape[1] - int(0.1*fs), f"{wrap:.4f} (raw {raw:.4f})")
e = X(N["TillandsiasAudioEQ"]().run(A(sine), "lowpass", 200.0, 0.707, 0.0)[0])
check("lowpass attenuates 1k", np.abs(e[:, fs:]).max() < 0.05, np.abs(e[:, fs:]).max())
img = N["TillandsiasAudioScope"]().run(A(sine), 512, 192)[0]
check("scope image", tuple(img.shape) == (1, 192, 512, 3) and float(img.max()) <= 1.0)
s, d, gj = N["TillandsiasBarGrid"]().run(180.0, 4, 4, 96, fs, 4, 12, 0.0)
check("bar grid 180bpm 4/4", abs(s - 4*4/3) < 1e-9 and abs(d - 8*4/3) < 1e-9, (s, d))
g = json.loads(gj); check("grid sample-exact", g["bar_starts_samples"][96] == 96*64000)
man = json.loads(N["TillandsiasSaveLoopWAV"]().run(A(sine), "loops/t", 0.5, 2.5, 24, gj)["result"][0])
f = os.path.join(tmp, "out", man["file"]); buf = open(f, "rb").read()
check("loop wav smpl", dsp.read_wav_loop(buf) == (24000, 119999), dsp.read_wav_loop(buf))
with wave.open(f) as w: check("wav readable", w.getnframes() == sine.shape[1] and w.getsampwidth() == 3)
check("manifest sidecar", os.path.exists(f[:-4] + ".json") and man["bytes"] == len(buf))
from comfy_extras.nodes_audio import load as cload
wv, sr = cload(f); check("comfy loads loop wav", sr == fs and abs(float(wv[0, 48000]) - sine[0, 48000]) < 1e-4)
mb = X(N["TillandsiasAudioMixBus"]().run(A(sine), -6.0, A(sine[:, :fs]), 0.0)[0])
check("mix bus", mb.shape == sine.shape and abs(mb[0, 100] - (sine[0,100]*0.501187 + sine[0,100])) < 1e-3)

# MIDI: format 1, 2 tracks, tempo 180, notes 60 & 64 (ch0), 36 (ch9)
def vlq(v):
    b = [v & 0x7F]; v >>= 7
    while v: b.insert(0, (v & 0x7F) | 0x80); v >>= 7
    return bytes(b)
def trk(evs): body = b"".join(evs) + b"\x00\xff\x2f\x00"; return b"MTrk" + struct.pack(">I", len(body)) + body
t0 = trk([b"\x00\xff\x51\x03" + (333333).to_bytes(3, "big")])
t1 = trk([vlq(0) + b"\x90\x3c\x64", vlq(480) + b"\x80\x3c\x00", vlq(0) + b"\x90\x40\x50", vlq(480) + b"\x40\x00",
          vlq(0) + b"\x99\x24\x7f", vlq(240) + b"\x89\x24\x00"])
mid = b"MThd" + struct.pack(">IHHH", 6, 1, 2, 480) + t0 + t1
open(os.path.join(tmp, "in", "s.mid"), "wb").write(mid)
m, summ = N["TillandsiasLoadMIDI"]().run("s.mid")
ks = [(n["key"], round(n["t"], 4), round(n["d"], 4), n["ch"]) for n in m["notes"]]
check("midi parse", ks == [(60, 0.0, 0.3333, 0), (64, 0.3333, 0.3333, 0), (36, 0.6667, 0.1667, 9)], ks)
(m2,) = N["TillandsiasMIDITransform"]().run(m, 12, 1.0, 1.0, 0.0, 0, 0, 127)
check("midi transform part+transpose", [n["key"] for n in m2["notes"]] == [72, 76])
# SFZ: a 440 Hz sample at key a4 (69) via #define + default_path + #include
s440 = (0.5*np.sin(2*np.pi*440*np.arange(fs)/fs)*32767).astype("<i2")
with wave.open(os.path.join(tmp, "in/inst/samples/a 4.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(fs); w.writeframes(s440.tobytes())
open(os.path.join(tmp, "in/inst/regions.sfz"), "w").write("<group> lovel=1 hivel=127 // comment\n<region> sample=$DIR/a 4.wav lokey=0 hikey=127 pitch_keycenter=a4 ampeg_release=0.01 xfin_lovel=3\n")
open(os.path.join(tmp, "in/inst/k.sfz"), "w").write('#define $DIR samples\n<control> default_path=\n#include "regions.sfz"\n')
(m3,) = N["TillandsiasMIDITransform"]().run(m, 0, 1.0, 1.0, 0.0, 0, 0, 127)
au, rep = N["TillandsiasSFZRender"]().run(m3, "input/inst/k.sfz", fs, 0.5, 0.0, 0)
r = json.loads(rep); y = X(au)
check("sfz report", r["unmatched_notes"] == 0 and r["missing_samples"] == [] and "xfin_lovel" in r["ignored_opcodes"], r)
seg = y[0, int(0.05*fs):int(0.3*fs)]
spec = np.abs(np.fft.rfft(seg)); f0 = np.argmax(spec) * fs / len(seg)
want = 440 * 2**((60-69)/12)
check("sfz pitch c4", abs(f0 - want) < 6, f"{f0:.1f} vs {want:.1f}")
check("sfz silent after release", np.abs(y[:, int(0.70*fs):]).max() < 1e-6)
print("ALL OK" if all(ok) else f"FAILED {ok.count(False)}")
sys.exit(0 if all(ok) else 1)
