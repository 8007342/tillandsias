## Cycle 2026-09-02T20:29Z — lenovinha-tillandsias-forge (forge, CPU-only)

**Story: 919-vvyv (claimed, worked, released to ready — not closed).**

Measured the CPU-only forge regime from inside it, then fixed what the
measurement found. Three of the packet's premises were stale:

- D1 (embed model absent) did NOT reproduce — nomic-embed-text cached and
  answering. But nothing PULLS it; it was present by accident of the mounted
  cache.
- D2 root cause is one level up: `OLLAMA_HOST` is declared on both forge
  profiles (container_profile.rs:393,:692) and never reaches the container, so
  the existing D1/D2 fix was INERT in its own lane. Wiring the endpoint by hand
  moved experts-probe from l1=unset straight to l1=no-index.
- The "~60 min on CPU" index build is **214s for 22645 chunks** (~17x off).

Landed (7cdbc7546): probed forge fallback for the embed endpoint; a separate
embed-model pre-pull kept out of the litmus-pinned DEFAULT_MODELS; the RAM-keyed
CPU tier ladder cheatsheet; `embed_model=` on the capability line. After the
fixes: `l0=ready l1=ready l2=ready advice=-`.

NOT closed: the closure needs a cold forge launch from a rebuilt image, which an
in-forge agent cannot perform. Released with a carry-forward.

**Filed:** 964-zedm (spec-index stages into a 256 MB /tmp tmpfs and dies on
ENOSPC while the index root has 1.2 TB free — the real gate on criterion 2, not
CPU time), 964-i4j9 (litmus:host-expert-refresh-gate-shape red at HEAD, confirmed
pre-existing), 965-sxec **p0** (below).

**BLOCKED — no MO-FULL marker this cycle.** `./build.sh --check` cannot pass in a
forge: scripts/archive-plan-packets.sh has a hard ruby dependency, the forge image
carries no ruby by design, and it exits 127. build.sh:2214 maps rc==3 to
could-not-run (923-ws3r) but 127 falls to :2217 and asserts "the plan archiver
would CHANGE THE READY SET" — a substantive claim about the ledger made on a
command that never ran.

Worse, and escalated to p0: the ruby shim stacks an unreaped
`timeout 150 brew install --formula ruby` per invocation. Measured 801 of them
plus 3206 bash, taking pids.current to 4065 of 4096. Past that the container
cannot fork a thread and git fails with "unable to create threaded lstat" /
"invalid index-pack output" — so the forge could not commit or push, with the
diagnostic trail pointing at git rather than ruby. Reaping took it to 60.

**Two defects of my own, both repaired.** The 919-vvyv measurement event was
written with flat keys and no `event:` block, so the fold dropped it silently
(866-pvsx) and the ledger went `incomplete: PARTIAL corpus`, blocking fleet
pushes; repaired in c01bdc0d3, ledger now `ok: 585 packets`. I had run
`fragment-event-packets` on that fragment, seen EMPTY output, and read it as a
pass — empty is the failure signal. Second: authored a cheatsheet without running
`scripts/stage-image-cheatsheets.sh --stage`.

**Checkout:** the shared checkout at /home/forge/src/tillandsias was
dirty-start-refused (22 `.claude/opsx` generated paths;
check-opsx-generated-dirt.sh only knows the `.opencode/` set, so it reads
`non-opsx:`). Salvaged to salvage/unknown/20260902-opsx-claude-lane-dirt
(b0536e86); all work done in a clean clone. The 22 paths are untouched.

**Advisories:** compaction eligible=true fragments=34; corpus-coverage 3 classes
neither indexed nor declined (.tsv/.lua/.jsonl); scratchpad tmpfs is 256 MB and
too small to build in.
