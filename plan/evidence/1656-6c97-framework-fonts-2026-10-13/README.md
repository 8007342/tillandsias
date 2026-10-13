# 1656-6c97: the chromium-framework image ships CJK and emoji fonts; the 612-nvf3 launcher fixture is wired

Host: lenovinha (Fedora Silverblue, podman 5.8.7). Date: 2026-10-13.

## Criterion 2 corrected (coordinator ruling, 2026-10-13)

The row first asked for a fixture asserting that the entrypoint REFUSES
`--no-sandbox`. That misread 612-nvf3:
- `images/chromium/chromium-framework-launch.sh` ADDS `--no-sandbox` when the
  Chromium wrapper accepts it. Fedora's wrapper accepts the flag without
  advertising it in `--help`, hence the probe.
- Chromium's setuid sandbox cannot start under `--cap-drop=ALL` plus
  `no-new-privileges`; without the flag the container exits 21.
- A refusal would break every window.

The real gap was that the 612-nvf3 fixture, `scripts/test-chromium-framework-launch.sh`,
existed but nothing ran it. The `list-replace` event in this PR
(`plan/index.d/20261013t080711z-027e7aec-lenovinha.yaml`) replaces criterion 2
with: "scripts/test-chromium-framework-launch.sh is ported to Lua and bound to a
litmus step; it goes red when the probe is dropped and when it is made
unconditional."

## Criterion 1: fonts (`fc-list-*.txt`, `summary.txt`)

**Red, the installed image** (`red-fc-list.txt`):
- Latin was already present, brought in by Chromium's dependencies: Noto Sans,
  Adwaita Sans/Mono and Cantarell. So "red today (no fonts)" in the row is
  true for CJK and emoji only.
- `fc-list :lang=ja`, `:lang=zh-cn`, `:lang=ko`, `:color=true` and
  `:charset=1f600` were all **empty**.

**Green.** `build.sh.txt` builds on a PRIVATE podman store, twice, from the
installed `tillandsias-chromium-core:v56.9.27.2`:
- the baseline (linux-next's Containerfile.framework);
- this branch's version (the font layer).

| | baseline | with fonts |
|---|---|---|
| `:lang=ja` | — | Noto Sans CJK JP, Noto Sans Mono CJK JP |
| `:lang=zh-cn` | — | Noto Sans CJK SC, Noto Sans Mono CJK SC |
| `:lang=ko` | — | Noto Sans CJK KR, Noto Sans Mono CJK KR |
| color emoji, U+1F600 | — | Noto Color Emoji |
| metric-compatible Arial/Times/Courier | — | Liberation Sans/Serif/Mono |

## Criterion 3: size growth

- **Image:** 2 269 177 333 → 2 367 966 936 bytes, **+98 789 603 bytes (94 MiB, +4.4 %)**.
- **/usr/share/fonts:** 9.3 MB → 83.3 MB.
- **By package (rpm sizes):**
  - google-noto-sans-cjk-vf-fonts: 32.7 MB;
  - google-noto-sans-mono-cjk-vf-fonts: 31.9 MB, pulled in by the CJK package;
  - google-noto-color-emoji-fonts: 5.1 MB;
  - liberation-sans/serif/mono: 1.7, 1.5 and 1.2 MB.

The CJK pair is two thirds of the growth. It is a single variable OTC per
style, the smallest complete CJK coverage Fedora ships.

The operator's containers, networks and image list were unchanged before and
after (`op-before`, `op-after`). The installed images were only read, with
`podman save`.

## Criterion 2: the launcher fixture (`launch-fixture.txt`)

`scripts/lua/test-chromium-framework-launch.lua` replaces the `.sh`. That
deletion pays one shell-to-lua item; its floor line is dropped. Its arms:
1. A wrapper that accepts the flag is exec'd with `--no-sandbox`.
2. A wrapper that rejects it is exec'd without it.
3. Mutant A, the probe dropped, must turn arm 1 red.
4. Mutant B, the probe unconditional, must turn arm 2 red.

It is bound to `litmus-chromium-variants-launch-shape` (step 10).

Mutating the REAL launcher with `sed` turns it red, naming the broken
property:
- probe dropped: `FAIL: 1 ACCEPTS`, `violation:chromium-framework-launch:3:of:4`;
- probe unconditional: `FAIL: 2 REJECTS`, `violation:chromium-framework-launch:2:of:4`.

Step 11 pins the font layer, with a negative control.
