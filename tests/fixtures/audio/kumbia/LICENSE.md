# Kumbia Kombat loop excerpts: provenance and terms

These eleven FLAC files are short excerpts of music from **Kumbia Kombat**,
the Tillandsias project's own game. They are its room themes "garden",
"bar" and "billiards". They are here only as inputs for the audio studio's
glitch detector fixture (`scripts/lua/test-audio-studio-glitches.lua`,
order 2078-kmbx).

**Permission.** Operator ruling, 2026-11-10 (relayed by macuahuitl-fedora):
real kumbia excerpts are allowed as detector fixtures in the tillandsias
repository, under 10 MB in total, with this provenance note. The set here is
4,165,940 bytes. The fixture asserts the total, and the sha256 of every file,
before it reads a verdict.

**How they were made.** These are the project's own renders, made by the
kumbias-forge session for the project's operator:

- **Model:** ACE-Step 1.5 XL turbo, `acestep_v1.5_xl_turbo_bf16.safetensors`
  from Comfy-Org/ACE-Step-1.5, revision 371bb1680f8c, Apache-2.0. Text
  encoders `qwen_0.6b_ace15` and `qwen_4b_ace15`, VAE `ace_1.5_vae`.
- **Engine:** ComfyUI v0.40.0, through `studio.run_workflow`, pipeline
  56.11.6.2.
- **Parent renders:**
  - garden: 2026-11-07T03:11:12Z, seed 1054986036;
  - bar: 2026-11-07T03:11:58Z, seed 1610602055;
  - billiards: 2026-11-07T03:13:24Z, seed 2355447521.
- **Further steps:**
  - layered tiers derived with `audio.transform`, 2026-11-09;
  - the game mix by mixrs, 2026-11-10;
  - the shipped game loop decoded from its Opus .ogg;
  - the HPSS parts of #04 (percussive and harmonic) split by median filter.

**The cuts.** Each file is 96,000 frames: 2 s of 48 kHz stereo, FLAC 24-bit.
A "wrap" cut is the source's last 48,000 samples followed by its first 48,000,
so the source's loop point sits at 1.000 s. The planted files (#08, #09) are
1 s either side of the planted fault. Each cut matches its source float WAV to
1.2e-7, the 24-bit step. The source files lived under kumbias-forge's
`/work/tmp/audio/calib/`, and the cuts came to this repository from
kumbia-kombat `work/2620-fixt` at 23dc6c8. That ref's `manifest.json` names
each one's source path and length.

| file | source | cut | kind | the fixture expects |
|---|---|---|---|---|
| 01-garden-low-rolled | calib/garden--low--rolled.wav (n=2425263) | wrap | rolled loop | no finding |
| 02-bar-low-rolled | calib/bar--low--rolled.wav (n=2684272) | wrap | rolled loop | no finding |
| 03-billiards-mid-rolled | calib/billiards--mid--rolled.wav (n=3225600) | wrap | rolled loop | no finding (seam reads 1.01x p99, a thin margin under 1.5) |
| 04-billiards-mid-mix | calib/loops/billiards--mid.wav (n=3225600) | wrap | shipped game loop, Opus-decoded | no finding; its OWN end-to-start wrap is a hard cut, reported as loop_seam |
| 05-bar-mid-xfade20 | calib/bar-mid-src--xfade20.wav (n=2608302) | wrap | 20 ms crossfade | no finding |
| 06-garden-mid-xfade20 | calib/garden-mid-src--xfade20.wav (n=2351020) | wrap | 20 ms crossfade | no loop_seam (its click and clipping are real: the source peaks at 1.0) |
| 07-bar-low-offwrap | calib/planted/bar--low--offwrap.wav (n=2674265) | wrap | last 10007 samples cut | loop_seam at 1.000 s |
| 08-bar-low-click03 | calib/planted/bar--low--rolled--click03.wav | 10.758 s ±1 s | +0.3 on one sample | click at 1.000 s |
| 09-bar-low-dropout1ms | calib/planted/bar--low--rolled--dropout1ms.wav | 20.300 s ±1 s | 1 ms of zeros | dropout at 1.000 s |
| 12a-billiards-mid-perc | calib/billiards--mid--perc.wav (n=3225600) | wrap | HPSS percussive part of #04 | loop_seam (the split is not circular) |
| 12b-billiards-mid-harm | calib/billiards--mid--harm.wav (n=3225600) | wrap | HPSS harmonic part of #04 | loop_seam |

**Not here, and why.** Two real faults could not be excerpted: the shipped
Opus codec steps at the comedor-low and salón-low wraps. On the whole loops
they read 9.47x and 3.95x p99. The same joint, cut as an excerpt of 2 s or
8 s, reads clean.

kumbias-forge measured why on 2026-11-10. The step is a small high-frequency
mismatch, about -27 to -33 dB, between Opus's two codings of loop[0]. The
detector's 32-pole LPC, fitted over the whole quiet 62 s loop, has a large
high-frequency gain that magnifies it: the wrap residual is 134.87. Fitted
over an 8 s excerpt, the same step reads 16.01. The interior p99 barely moves
either way.

Each whole loop alone (about 14 MB and 11 MB as FLAC) is over this set's 10 MB budget. So this is a
measured limit of excerpts, recorded and not asserted: a seam judged with
`--seam-at` inside a short excerpt cannot see a codec step that only the
whole loop's fit magnifies.

The FLAC files are the project's own work. They may be redistributed with
this repository for testing, and used for nothing else without the project
operator's permission.
