# `http://127.0.0.1:11434` names two different inference servers on a Windows host, and both answer

- classification: research
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 3)
- status: measured; evidence for two open decision packets, no change made
- related: **718-ja7g** (expert-inference-endpoint-contract-for-dev-hosts,
  ready, p1 — this is the concrete failure its contract must exclude),
  **718-nkm2** (wsl2-inference-substrate-decision, ready, p1,
  `pickup_role: windows`), 718-rtnh (bare-metal expert inference parity)

## The finding

`.claude/settings.local.json` on this host sets:

```json
"TILLANDSIAS_INFERENCE_ENDPOINT": "http://127.0.0.1:11434",
"TILLANDSIAS_EMBED_ENDPOINT":     "http://127.0.0.1:11434/v1",
"TILLANDSIAS_SPEC_EXPERT_ENDPOINT":"http://127.0.0.1:11434/v1"
```

That **one** literal address resolves to **two different Ollama servers**,
selected by which side of the WSL2 boundary the reader happens to run on:

| Reader | `/api/version` | `/api/tags` |
|---|---|---|
| Windows (Git Bash, PowerShell) | **0.32.13** | `gemma3:270m, nomic-embed-text, phi3.5:3.8b, qwen2.5:0.5b, qwen3:0.6b, smollm2:135m, smollm2:360m, tinyllama:1.1b` |
| Inside WSL2 (either distro) | **0.32.14** | `nomic-embed-text, qwen2.5:0.5b` |

**Both answer. Neither errors.** There is no failure mode to notice — just a
different engine, a different version, and a different model set behind an
identical string.

## Why this is worse than unreachability

An unreachable endpoint fails loudly and gets fixed. This one succeeds, so:

- A request for `phi3.5:3.8b` **succeeds on Windows and 404s in WSL2** from the
  same configuration.
- Any measurement taken "at `127.0.0.1:11434`" is unattributable after the fact
  unless the side was recorded. Two benchmark runs of the same config can
  legitimately disagree.
- It has gone unnoticed because `TILLANDSIAS_INFERENCE_MODEL=qwen2.5:0.5b`
  happens to exist on **both** sides. The moment a tier above T0 is used, the
  two sides diverge.

## Supporting facts measured on this host

- **The WSL2 distros share a network namespace.** `tillandsias` and
  `tillandsias-build` both see the same `127.0.0.1:11434` and `:11435`
  services, so a service in one distro is reachable from the other on loopback.
  "In-distro" is therefore not a per-distro address space.
- **Windows -> WSL2 loopback forwarding did NOT work here.** A server bound to
  `0.0.0.0:11435` inside WSL2 is reachable from both distros and
  **unreachable from Windows** (`Failed to connect to 127.0.0.1:11435`). There
  is no `%USERPROFILE%\.wslconfig` on this host, so networking is the default
  NAT mode.
- Direction matters and is not symmetric: WSL2 -> Windows loopback also does not
  cross (a distro asking `127.0.0.1:11434` gets the WSL2 server, not the Windows
  one). Each side simply resolves loopback to itself, which is exactly why both
  succeed.

### Measurement hygiene note

`ps`, `ss`, `netstat`, `ip` and `pgrep` are **all absent** from the runtime
`tillandsias` distro (a minimal Fedora container image). An early pass here read
their empty output as "no process listening" and drew the wrong conclusion. On a
minimal image, absent output means an absent *tool*; probe the service, not the
process table. (`/etc/wsl.conf` in that distro also sets `automount = false`, so
it has no `/mnt/c` — worth knowing before assuming a shared checkout path.)

## What this means for the two open packets

**718-ja7g (endpoint contract)** already records that
`TILLANDSIAS_INFERENCE_ENDPOINT` is *read* in three places and *written* in
none, and names two silent-drop traps in `semantic_expert.rs` (a hostname fails
`addr.parse::<SocketAddr>()`; a value not starting with `http://` is ignored).
This finding adds a third trap of a different kind: **a syntactically valid,
reachable, correct-looking endpoint that designates different servers to
different readers.** A contract that only validates *form* cannot exclude it.

The smallest contract change that would: require the endpoint to be
**side-qualified** — either a non-loopback address that both sides resolve
identically, or an explicit declaration of which side owns it, with the
consumer refusing when it cannot confirm it is on that side.

**718-nkm2 (substrate decision)** lists four options and instructs: *"Pick by
which one an unattended cycle can re-establish after a reboot without an
operator."* Two of its options are affected by measurements taken here:

- **Option A (in-distro ollama)**: works, but if placed in the *runtime*
  `tillandsias` distro it is **not durable** — `with-wsl2-builder.sh:26-31`
  records that destructive smoke e2e **unregisters that distro on every run**.
  An in-distro endpoint must therefore live somewhere e2e does not destroy.
- **Option C (`networkingMode=mirrored`)**: is the only listed option that makes
  loopback mean the same thing on both sides, which would remove this ambiguity
  rather than document around it. It requires the `.wslconfig` this host does
  not have — the same file needed for cgroup v2 before any podman
  `--memory`/`--cpus` limit stops being a silent no-op.

Not proposing a decision here: 718-nkm2 is a `kind: decision` packet with
`pickup_role: windows`, and the operator owns the choice. This file supplies the
evidence it asked for.

## Residual

Not tested: whether `networkingMode=mirrored` actually resolves the ambiguity on
this host. That needs a `.wslconfig` write plus a full WSL restart, which
restarts the build distro mid-cycle; deferred rather than done inside a cycle
that was measuring other things. It is the obvious next experiment and would
close the option-C branch of 718-nkm2 empirically.
