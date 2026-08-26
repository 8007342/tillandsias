# The macOS model cache lives inside `rootfs.img`, and four things delete it — one of them ships

- **Host**: macOS / MacBook Air `Mac17,3`. **Filed by**: `macos-opus5-metal-20260817`, 2026-08-17.
- **Branch**: `osx-next`, measured at `7e73b3de5`.
- **Orders**: 804-bpke (the shipped `uninstall.sh` inversion), 804-deux (the e2e
  `rm -rf "$VM_DIR"`, the macOS twin of 518).
- Cross-references: 518, 804-wfcu (the Linux `uninstall.sh` twin, filed
  2026-08-17), 406, 401, 690-cb62.

The operator's framing was *"your e2e's `rm -rf "$VM_DIR"` destroys every
downloaded model — the macOS twin of order 518."* That is confirmed. It is also
**not the worst of it**: the same directory is destroyed by a script we ship to
users, outside its own destructive-mode guard, which then prints that it
preserved things.

---

## 1. Confirmed: exactly one share, and the model cache is not on it

`crates/tillandsias-vm-layer/src/vz.rs` contains **exactly one**
`setDirectorySharingDevices` call in the whole repo (`vz.rs:1231`), installing an
`NSArray` of length **1**:

- `vz.rs:1426-1427` — the only production spec: `shared_host_dir:
  Some(home_src_dir())`, `share_tag: "home-src"`.
- `vz.rs:720-726` — `home_src_dir()` = `$HOME/src`.
- `vz.rs:563` — guest fstab: `home-src /home/forge/src virtiofs nofail 0 0`.
- `VZBootConfig` (`vz.rs:1030-1054`) has **no field for a second share**:
  `shared_host_dir` is a single `Option<PathBuf>`. There is no multi-share path
  to configure even if someone wanted one.

Full host↔guest device inventory (`vz.rs:1116-1235`): virtio-blk `rootfs.img`
(rw), virtio-blk `cidata.iso` (ro config ISO), virtio-net NAT, virtio-console →
`console.log`, virtio-entropy, virtio-balloon, **one** virtio-fs (`home-src`),
virtio-vsock. Nothing else crosses the boundary.

The model cache lands at `/root/.cache/tillandsias/models` inside the guest,
bind-mounted into the inference container as
`-v {model_cache_dir}:/home/ollama/.ollama/models:rw`
(`crates/tillandsias-headless/src/main.rs:4154-4159`). `/root/.cache` is not
under `/home/forge/src` by any path.

**So: the model cache is inside `rootfs.img`, and `rootfs.img` is not shared.**
Deleting the VM directory takes it.

Lost with it, and worth naming separately because it caused a real outage: the
**ollama engine payload** at `${OLLAMA_MODELS}/.tools` — a *subdirectory of the
mounted cache* (`images/inference/entrypoint.sh:103, 213, 218`) — holding
`llama-server` and `libggml`/`libllama`. Without it every `/api/generate` returns
HTTP 500 while `/api/version` still answers, which is exactly the order-406 root
cause (`e4fa379e1`).

## 2. Measured, on this host, today

`VM_DIR` = `$HOME/Library/Application Support/tillandsias`, and
`rootfs_image_path()` = `image_root.join("rootfs.img")` (`vz.rs:133-135`) — top
level, no subdirectory.

```
$ du -sk "$HOME/Library/Application Support/tillandsias"
12407656   →  11.83 GiB actual on disk
$ du -sk "$HOME/Library/Application Support/tillandsias/rootfs.img"
11881200   →  11.33 GiB actual on disk
$ stat -f %z rootfs.img
268435456000  →  250 GiB apparent (sparse)
$ du -sk "$HOME/Library/Caches/tillandsias"
8          →  8 KB
```

Note the sparse file: anything reasoning about cost from `ls -la` will read
**250 GiB** and anything reasoning from `du` will read 11.33 GiB. The second is
the real one.

### Mandatory re-download after a wipe

| Component | Size | Source |
|---|---|---|
| ollama engine, arm64 (what the aarch64 guest pulls) | **1.44 GiB** | live `curl -sIL` today → `v0.32.14/ollama-linux-arm64.tar.zst` `content-length` = 1,542,906,817 B |
| `qwen2.5:0.5b` T0 default model blob | **379 MiB** | 397,807,936 B, measured — `plan/issues/research/engine-parity-ollama-vs-llamacpp-2026-08-17.md:19` |
| Fedora Cloud base (re-provision) | **528 MB** | `target/smoke-e2e/03-provision.log`, measured 2026-08-15 |
| **Floor** | **≈ 2.47 GB** | |

Measured host throughput today: a 200 MiB range fetch from the real release URL
ran at **62.4 MB/s** (an independent re-run measured 60.6 MB/s). So ≈ **40 s of
pure transfer** — but that is the *host-direct* rate, and the guest pulls through
Squid over NAT (`entrypoint.sh:292-310`), where the recorded in-lane experience is
`this may take several minutes` per image (`target/smoke-e2e/04-opencode.log:6`).
This corroborates the only other model-pull number on record, ~65 MB/s
(`plan/issues/inference-container-startup-failure-2026-07-02.md:17-19`).

**Stated limits of the cost estimate, because they matter:**

- The 2.47 GB floor is soundly derived from four separately measured components.
- The **larger ~9 GB figure is not a measured rebuild cost.** It comes from a
  2.7 GiB → 11.83 GiB delta between `target/smoke-e2e/02-substrate-before.txt`
  (2026-08-15) and today, i.e. *growth over two days of normal use*. Treat it as
  order-of-magnitude, not measurement.
- **No model has been observed being pulled inside the macOS guest.** Grepping
  `04-opencode.log` and `07-349-closing-run.log` for `ollama|inference|model`
  shows the inference image being *built*, and no engine download, no model pull,
  and no `/api/generate`. The "models are lost" cost is a **path derivation** —
  sound, because the mount and the cache path are both pinned — but it is not an
  observation, and this report does not claim otherwise.
- The guest-side split of the 11.33 GiB `rootfs.img` between models and container
  images is **unmeasured**. `--exec-guest du -sh /root/.cache/tillandsias/models`
  would settle it, but see
  `plan/issues/macos-vz-vm-overhead-measurement-2026-07-24.md:36`: do **not**
  probe a live VM (risks a second VM against the same disk).

## 3. Four destroyers, not one

| # | Site | What it removes | Guard |
|---|---|---|---|
| 1 | `skills/build-install-and-smoke-test-e2e/SKILL.md:251` | `rm -rf "$VM_DIR" "$CACHE_DIR"` (`VM_DIR` at `:248`) | **none** — unconditional; `:253` asserts `test ! -e "$VM_DIR"` |
| 2 | `skills/smoke-curl-install-and-test-e2e/SKILL.md:193-195` | same directory | none |
| 3 | `crates/tillandsias-vm-layer/src/vz.rs:211-233` | `wipe_provisioned_artifacts()` — `rootfs.img`, `vmlinuz`, `initramfs.img`, `rootfs.qcow2`, `console.log`, `cidata.iso` | reachable via `--reset-guest` (`macos-tray/src/main.rs:175-177` → `diagnose.rs:584-585`) and the retained reset worker (`action_host.rs:1943`) |
| 4 | **`scripts/uninstall.sh:73`** | `rm -rf "$DATA_DIR"` = the whole VM dir | **OUTSIDE the `--wipe` guard** |

## 4. The one that ships — and says the opposite of what it does

`scripts/uninstall.sh` on macOS (`:5-12`):

```sh
DATA_DIR="$HOME/Library/Application Support/tillandsias"     #  ← 11.83 GiB
CACHE_DIR="$HOME/Library/Caches/tillandsias"                 #  ← 8 KB
```

`:73`, under a comment describing it as bundled data:

```sh
# ── Remove bundled data (flake, scripts, images) ──────────────
rm -rf "$DATA_DIR"
```

That line is **unconditional**. The only guards in `:66-129` are `IS_ROOT`
(`:82`, `:94`, `:112`) and `WIPE` (`:119`); line 73 is under neither. It needs no
root and there is no confirmation prompt (`:36-64` is a print-only preamble).

`:119-121`, the destructive mode:

```sh
if [[ "$WIPE" == true ]]; then
    rm -rf "$CACHE_DIR"
```

`:144`, what the user is told:

```sh
[[ "$WIPE" != true ]] && echo "  Cache preserved. Use --wipe to remove everything."
```

**The message is exactly inverted on macOS.** The default path destroys
**11.83 GiB** — the VM, the model cache, the engine payload, every guest-built
container image, the vault — and reports that it preserved the cache. Opting into
`--wipe` "to remove everything" adds **8 KB**. The ratio between what the
reassuring path deletes and what the scary path adds is roughly 1.5 million to
one.

This is not an internal script. It is a **shipped release artifact**:
`.github/workflows/release.yml:233` installs it into `release-artifacts/`, and
`:286` asserts it is present. It is operator-reachable in the current release.

Contrast with the Linux twin the linux host filed the same day (**804-wfcu**),
which they scoped honestly as *possibly packaging-only* — on Linux the analogous
`rm -rf "$SERVICE_HOME"` needs a `tillandsias` service account that no installer
currently provisions, so that path may be unreachable today. **The macOS path has
no such mitigation.** `$HOME/Library/Application Support/tillandsias` is where the
VM actually lives, right now, on this machine.

## 5. Why this gets worse, not better

Three reasons to fix it before the GPU work lands rather than after:

1. **Models are about to get bigger.** The whole point of 397 / 483 / 657-s6g8 is
   to run larger models on better hardware. Today's floor is a 379 MiB T0 model;
   a Metal lane exists to justify multi-gigabyte ones.
2. **The engine payload is inside the cache directory**, so a wipe re-creates the
   order-406 failure mode — healthcheck green, every generation HTTP 500 — until
   the 1.44 GiB payload is re-pulled.
3. **`rootfs.img` is sparse**, so the cost is invisible to the tools people
   reach for. `ls -la` says 250 GiB, which reads as "obviously nobody would keep
   that", and `df` movement after a wipe is 11.33 GiB, which nobody attributes.

## 6. What "fixed" looks like

Not prescribed as a single design, but the constraint is clear: **the model cache
and engine payload must survive a VM-directory deletion**, which means they must
live on a durable path that is either shared into the guest or reconstructed
without a network pull.

`vz.rs` currently cannot express this — `VZBootConfig` holds one
`Option<PathBuf>` and one tag (`:1030-1054`). A second virtiofs share (e.g.
`model-cache` → `$HOME/Library/Caches/tillandsias/models`) is the smallest change
that makes the durable path possible, and it has the pleasant side effect of
putting the models under the directory `--wipe` actually claims to own.

Separately and independently of any of that, the shipped `uninstall.sh` should
either move `rm -rf "$DATA_DIR"` behind `--wipe`, or stop printing "Cache
preserved" — the current pairing is the defect regardless of which side is judged
correct.

## 7. Verification pointers

Every measurement in §2 was re-run independently and reproduced exactly. Two
claims in the first draft of this investigation were **refuted** during
verification and are corrected above:

- "no test asserts the `-v` models bind" — **false**.
  `openspec/litmus-tests/litmus-inference-container-implementation-shape.yaml:93`
  greps `build_inference_run_args` for `/home/ollama/.ollama/models:rw`, and it
  is live at `openspec/litmus-bindings.yaml:509`. The correct narrow claim is
  "no *Rust unit* test asserts it".
- "the macOS lane demonstrably does run inference" — **overclaim**, retracted;
  see the bullet in §2.
