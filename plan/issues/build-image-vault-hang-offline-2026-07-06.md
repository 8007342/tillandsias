# scripts/build-image.sh vault hangs indefinitely offline, before any Containerfile step runs — 2026-07-06

- class: research (build tooling)
- filed: 2026-07-06
- owner: linux
- status: ready
- trace: scripts/build-image.sh, images/vault/Containerfile
- discovered during: order 221 (sidecar Containerfile.base split research)

## Finding

While measuring rebuild times for `git`/`proxy`/`vault`/`inference` (order
221), `scripts/build-image.sh vault --force` hung indefinitely (killed at a
15s timeout with zero output) on a network-restricted host, right after
printing `Detected base distro: unknown` and before `podman build`'s own
`STEP 1/16` line ever appears. `git`/`proxy`/`inference` all completed their
equivalent rebuilds in ~2 seconds on the same host under the same network
conditions.

Isolated further: a **raw** `podman build -f images/vault/Containerfile
images/vault` (bypassing `scripts/build-image.sh` entirely) DOES reach
`STEP 1/16: FROM docker.io/hashicorp/vault:1.18` immediately and only fails
later at the real `RUN apk add --no-cache ...` step (a DNS-lookup failure
against Alpine's CDN — the same expected failure the other 3 images hit when
their package layer must genuinely re-execute, and matches this host having
no general internet egress). This means:

- The Containerfile itself is not the problem — `podman build` handles it
  fine (fails fast and legibly once it needs the network).
- The hang is specific to something `scripts/build-image.sh` does for the
  `vault` image BEFORE invoking `podman build` — between the distro-detect
  line and the actual build invocation. No `vault`-specific branch was found
  in a first-pass grep of the script (`grep -n "vault\|cosign\|verify.*base"`
  only matches the Containerfile-path selection and `--help` text), so the
  exact stuck call wasn't root-caused this cycle.

## Why this matters

An operator (or an automated smoke/build cycle) rebuilding images on a
network-restricted or offline host gets a silent, indefinite hang for
`vault` specifically instead of the same fast, legible failure the other 3
images give — a real velocity/debuggability gap distinct from (and not
fixed by) the Containerfile.base-split question this was found alongside.

## Work (next reduction step)

1. Reproduce with `set -x` / `bash -x scripts/build-image.sh vault --force`
   to find the exact command between the distro-detect line and the podman
   build invocation that blocks without a fast-failing timeout.
2. Give it a bounded timeout (or make it fail fast / skip when offline, same
   as the Alpine DNS failure does for the other images) rather than hanging
   indefinitely.
3. Re-run order 221's timing measurement for vault once fixed, for
   completeness (does not change that packet's split-vs-not decision either
   way — filed here as a separate, narrower fix).
