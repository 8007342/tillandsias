# Forensic record: committed ELF `images/router/tillandsias-router-sidecar`

- **Filed:** 2026-08-12 (operator-directed, git-hygiene audit follow-up)
- **Packets:** 710-w9kc (fix), this note is its forensic evidence
- **Class:** supply-chain hygiene smell (committed binary artifact) — **NOT** a
  confirmed malicious-agent incident. Integrity verified clean (see below).
- **Repo (open source):** https://github.com/8007342/tillandsias

## What the artifact is

A 1.9 MB statically-linked musl x86-64 ELF at
`images/router/tillandsias-router-sidecar`, COPY'd into the router image by
`images/router/Containerfile:81`. It is a **legitimate compile of the repo's own
source** — embedded strings carry `crates/tillandsias-router-sidecar/src/main.rs`,
`.../src/http.rs`, and `crates/tillandsias-otp/src/lib.rs`; Tokio runtime; rustc
1.95.0. `scripts/build-sidecar.sh` builds this exact crate to this exact path.

**Integrity scan: clean.** A strings scan for exfil / shell-exec / beacon
indicators (external hosts, `curl|wget|nc -e`, `base64 -d`, `eval(`, ngrok,
pastebin, `.onion`) returned **nothing unexpected**. No injected payload; the
binary matches what the in-repo crate compiles to. The problem is that a
committed binary is **unverifiable-by-inspection and bloats history**, not that
this one is hostile.

## Commit provenance (git forensics)

Three commits touch the path; each is a **distinct recompile** (different blob +
byte size), all authored & committed under the maintainer's own "Tlatoani"
identities:

| Commit | Date | Identity | Blob size | Agent trailer |
|--------|------|----------|-----------|---------------|
| `58f69f38` | 2026-04-30 | `tlatoani@machiyotl.dev` | 2,574,880 (**first add**, `Bin 0→…`) | **none** |
| `30fafafb` | 2026-05-18 | `tlatoani@macuahuitl.ayahuitlcalpan.com` | 1,927,280 | **Co-Authored-By: Claude Opus 4.7 (1M context)** |
| `91c5a16b` | 2026-06-12 | `bulloncito@gmail.com` (primary) | 1,955,952 (**current** blob `3be4d56b`) | **none** |

**Attribution finding (honest):** the practice was **not** introduced by an
identifiable rogue agent. The initial add and the commit that set the current
blob carry no agent attribution; only the middle revision (an *update* to an
already-committed binary) was Claude-Opus-4.7-assisted. "Where it was running"
resolves only to three maintainer git identities/host configs above — no host
beyond the git config can be determined from history.

History footprint: 3 blobs across history (~6.5 MB uncompressed pre-dedup);
scrubbing them fully is a coordinated multi-host `git-filter-repo` event across
`main`/`linux-next`/`windows-next`/`osx-next` — requires explicit operator
authorization (releases-are-fixed-forward; not done here).

## Chosen remediation (operator, 2026-08-12)

The binary is a build artifact and must not live in the tree. Rather than
build-at-image-time (superseded), the **Containerfile must fetch the sidecar
from the LATEST tillandsias release artifact** — the signed, versioned,
cosign-verifiable source of truth. Blocking sub-fact discovered: the current
release (`v0.4.260810.1`) does **not** publish `tillandsias-router-sidecar` as
an asset (assets are the tray/headless/installer set + SHA256SUMS + cosign
bundles). So the fix requires, in order:

1. Publish `tillandsias-router-sidecar-x86_64-unknown-linux-musl` as a release
   asset with its `SHA256SUMS` entry + `.cosign.bundle` (release pipeline).
2. Rewrite `images/router/Containerfile` to download that asset at build time,
   **verify the SHA256 + cosign signature**, then install it — no COPY of a
   tree blob.
3. `git rm` the tracked blob + gitignore the path once (1)+(2) are green and the
   router image builds with the tree blob absent.
4. (Separately, operator-gated) coordinated history scrub of the 3 blobs.

## Reporting note (Anthropic)

An accurate disclosure would state: *in this open-source repo a committed ELF
build-artifact exists; one revision (`30fafafb`) was Claude-Opus-4.7-assisted
(co-author trailer); the binary is a clean compile of the repo's own Rust crate
with no malicious content.* It is a supply-chain **hygiene** observation, not
evidence of malicious agent behavior. Claude Code cannot transmit this to an
internal Anthropic team from a session; the maintainer can file model-behavior
/ safety feedback through Anthropic's public channels, and may link this note
and the commits above (repo is public).
