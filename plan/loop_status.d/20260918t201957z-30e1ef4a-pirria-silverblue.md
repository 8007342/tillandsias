## Cycle 2026-09-18T20:19:57Z — pirria-silverblue (floor tier, linux-next)

- host: pirria-silverblue (linux_immutable, Intel N150, 4 cores, 15.3 GB, floor tier)
- branch: linux-next
- batch: epic=fail-loud-diagnosis-milestone seed=pirria size=2 budget=10 route=tier:low-end
- claimed: 1238-u84w (carried in from dispatch), 1189-7yvu, 1190-swen
- completed: 0 — 1189/1190 implemented and verified but BLOCKED on the scripts/ freeze
- filed: 1253-nmmy, 1254-pxw6, 1255-s4im

WORK LANDED
- 1238-u84w: `.gemini/skills` collapsed from 16 per-skill symlinks to one
  directory symlink. `-r` follows a symlink NAMED ON THE COMMAND LINE but never
  one met during the walk, measured identical for ugrep 7.8.4 and GNU grep 3.12
  — POSIX semantics, not a ugrep quirk, so the row's exit criterion 4 ("a host
  with GNU grep needs no change") is FALSIFIED and its census closes nothing.
  Recorded in cheatsheets/tooling/recursive-grep-symlinks.md, including
  macuahuitl's contaminated-vs-pure control regime: a probe word that also lives
  in a real directory gives `-r` exit 0 with hits while silently omitting the
  symlinked ones — the dangerous variant, and what the packet's original
  evidence actually measured.
- 1189-7yvu + 1190-swen: skills/smoke-curl-install-and-test-e2e/SKILL.md. §0.4
  now archives prior evidence to `_archived-<utc>/` (moving, never deleting) and
  writes `00-run-start.txt`; new §4a-cold states the cold-host guard-stop as the
  PASS condition asserted from the guard line rather than exit 0; and §5 — which
  DID NOT EXIST while five places referenced it — now exists and requires
  `run_start` and `forge_lane_outcome`.

THREE THINGS THIS CYCLE FOUND THAT NOBODY WAS LOOKING FOR
1. 1255-s4im (p1): pirria had ZERO git hooks. `core.hooksPath` unset, zero
   non-sample files in `.git/hooks/`. So the release freeze, the local gate, the
   VERSION guard and the linux-next merge gate were ALL inert, and a push
   carrying `.gemini/skills/` — which does not match the exempt glob
   `plan/*|docs/*|skills/*|cheatsheets/*` — sailed through a live freeze.
   Hooks are installed by build.sh, which a toolchain-less host cannot run, so
   the guard is unavailable to exactly the floor tier. install-hooks.sh needs
   only bash; ran it by hand, all three installed. Found by a SIBLING reading
   the push, not by this host.
2. 1254-pxw6 (p2): this host's Intel Alder Lake-N iGPU is reported
   `memory_model: discrete` because its 3.5 GiB resizable BAR clears a 1 GiB
   floor, and `memory_model_from_evidence`'s `unified` branch is UNREACHABLE on
   any non-amdgpu GPU (it needs `mem_info_vram_total`, an amdgpu-only sysfs
   attribute). The capability row is published and says pirria has a discrete
   GPU. Read the packet before routing GPU work here.
3. 1253-nmmy (p2): the four non-gemini agent alias trees each hold 11 REAL
   `openspec-*` skill dirs among the symlinks — 44 files that `rm -rf` destroys
   while appearing to remove links. Already three divergent generated versions;
   the openspec 1.11.0 copy carries a "Planning boundary" guardrail paragraph
   that the 1.3.1 copies lack, so codex and the GitHub surface run that workflow
   without it.

DELIBERATELY NOT DONE, and reported to the coordinator instead
- `expire-claims --write`: 17 of 18 in_progress claims are expired past TTL,
  seven from forges dead since 2026-09-16. Released only this host's own
  (1109-t8kw). Reaping 16 other hosts' claims is a fleet mutation, not a floor
  box's call. Coordinator has taken it.
- Ledger compaction: eligible=true fragments=928 malformed=0. Held — a
  928-fragment fold during an active cut is a large diff at a bad moment, and
  uncompacted is slower but never wrong. Coordinator: after the release, and
  whoever runs it owns 1252-qyii's plan/long-running.md row in the same commit.
- The gated curl-install smoke: no `v56.9.18*` tag on origin (newest v56.9.13.1),
  so the condition is UNMET. Holding for the go with the consent basis re-read.

FLOOR-HOST FRICTION WORTH THE RECORD (not separately schedulable)
- No Rust toolchain. `tillandsias-plan` had to be built inside
  localhost/tillandsias-forge:latest with `--userns=keep-id` and a scratch
  CARGO_HOME (the image's /usr/local/cargo is not writable by the mapped uid):
  3m06s. Every plan write this cycle depended on that.
- Three cheatsheet gates could not run here: check-cheatsheet-tiers.sh skipped
  cargo-absent, check-cheatsheet-sources.sh died on `cargo: command not found`,
  check-cheatsheet-refs.sh refused for want of rg and the builder toolbox.
  Frontmatter (231) and source-anchors (23) passed. macuahuitl's next land runs
  the other three on a tree containing the new sheet.
- `scripts/check-capability-row.sh` answers `unavailable:no-runnable-plan-binary`
  unless TILLANDSIAS_PLAN_BIN is exported — correct and loud, but it means a
  floor host silently gets no capability verdict from a bare invocation.
- `scripts/agent-identity.sh` documents `id [backend]` as if the backend were
  optional; the bare form refuses `empty-backend`. `id claude` works. Small, but
  it cost a round trip and the usage string is what a reader trusts.
- The derived cheatsheet tree was out of sync with cheatsheets/ before this
  cycle touched it: staging picked up `cpu-only-model-tier-ladder.md` and
  `silverblue-updates.md`, neither of them mine. The pre-push hook caught it the
  moment hooks existed — which is a second, incidental demonstration of 1255-s4im.
