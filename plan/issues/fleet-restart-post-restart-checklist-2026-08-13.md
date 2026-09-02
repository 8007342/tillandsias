# Fleet restart + post-restart verification checklist (2026-08-13)

Operator is applying system upgrades everywhere, restarting the whole stack, and
rebuilding MCP servers on every host. This checklist survives the restart so any
host resuming the loop knows exactly what to verify BEFORE trusting its tools or
launching forges/delegates. Anchored by order 718-nuvm.

Fleet state at close-out (linux_mutable, HEAD 87829093):
- VERSION: main / linux-next / windows-next = `0.4.260812.1`; **osx-next = `0.4.260810.1`** (behind).

## Do these on EVERY host after the restart, in order

1. **Rebuild MCP servers from the CURRENT checkout, then VERIFY freshness.**
   Rebuilding is not enough — the stale-expert trap is a server that predates the
   commit it serves (bit us before commit b005490b). After rebuild, confirm
   forge-plan / project-info serve the LIVE checkout: their `freshness.source_commit`
   MUST equal `git rev-parse HEAD`. Do NOT trust `plan_answer` / `project_answer`
   until this holds (682-z5h8; a delegate verified this PASSes when fresh). If
   `confidence=unsupported` everywhere, the binary is pre-expert or the index is
   stale — rebuild from a branch carrying `crates/tillandsias-plan/src/answer.rs`.

2. **Clock / NTP sync — verify on every host, Windows especially.**
   At close-out the Windows host clock was ~7h AHEAD of UTC (its loop_status files
   stamped 20:05–22:05Z while real UTC was 14:49Z). A skewed clock breaks the
   SSH-CA design's 30-minute cert TTLs (certs issued "in the future" or instantly
   expired vs the mirror's clock), poisons freshness stamps, and scrambles the
   merge-cadence timestamp ordering. Sync NTP during the upgrade — this is a
   prerequisite for the 451/606 authenticated-push work.

3. **Rebuild ALL forge images at the current VERSION (`tillandsias --init`).**
   A toolchain (rustc) bump from the system upgrade changes the musl builds; a
   forge launched on a stack whose binary and images disagree DOAs in ~2s
   (version-skew). Bring the whole stack whole (every image at the installed
   VERSION) before launching any forge or delegate. `TILLANDSIAS_SKIP_VERSION_BUMP=1
   ./build.sh --install` then `tillandsias --init` is the reliable path.

4. **Reinstall git hooks (per-checkout).** Hooks do not survive a fresh clone.
   `./build.sh` installs them; confirm the pre-push gate and the post-commit
   expert-refresh hook are present. Forge uses the unconditional order-396 hook
   (lib-common.sh, by design); bare-metal/mirror hosts use the env-gated v4 hook
   (install-hooks.sh, gated on TILLANDSIAS_HOST_EXPERTS).

5. **Router sidecar is a build artifact now (710-w9kc).**
   `images/router/tillandsias-router-sidecar` is gitignored — a fresh clone does
   NOT contain it. `build-sidecar.sh` stages it (wired into build.sh + build-image.sh
   before the router image build). If a router image build fails on a missing COPY
   source, run the build path that stages it first; do not re-commit the binary.

6. **VERSION alignment / macOS unblock (702-eusw).** main now carries
   `0.4.260812.1`, so a platform branch that merges origin/linux-next is
   sync-forward and the pre-push VERSION guard accepts its push. When macOS
   resumes: `git fetch && git merge origin/linux-next` on osx-next brings it to
   0.4.260812.1; its first gated push WITHOUT --no-verify is 702-eusw criterion 2
   (Windows already proved this). The new check-version-bump-isolation.sh guard
   prevents a future VERSION bump from being swept into an unrelated commit.

7. **Clear stale delegate handles.** Defunct opencode processes from in-forge
   delegates do not always reap; a full restart clears them. `delegate-outcome.sh
   sweep` reconciles any registered-but-unfinished delegate.

## Pending work that survives in the ledger (no action needed to persist — already committed)

- v0.5 heavy remainder (focused/operator-guided sessions): 606-bvnp (SSH-CA
  per-project identity — design SIGNED + crit5 verified in-forge; Vault-roles +
  mirror-DNS + sidecar/sshd IMPL + §4a negative-matrix litmus remain),
  137/141/145 (vsock/encrypted-channel Rust), 601-462g / 245 (big cross-platform
  audits), 640-iujb (tlatoani-seated coverage-target decision).
- Experts milestone (391): 712-r5x8 refined to "cheatsheet corpus not loaded
  in-forge" (spec_answer refusal is already discoverable via its reason string);
  707-gm3q/kk8u (v0.6 rungs).
- macOS packets stalled during the dark window: 702-6jza (attach terminal
  corrupt), 702-griq (stale forge images on VERSION tag alone).

## 2026-09-02 macuahuitl restart — what step 3 got wrong, and what else the restart taught

Applied on macuahuitl after the 2026-09-02 upgrade + reboot (kernel
7.1.12-200.fc44, installed binary v56.9.1.2, experts l0/l1/l2 ready at HEAD,
NTP synced). Corrections to the list above, in the order they bit:

- **Step 3's failure mode is not only "images older than the binary".** The
  version guard (`crates/tillandsias-core/src/version_guard.rs`, called from
  `downgrade_refusal()` in the headless main) compares the app VERSION against
  the LOCAL IMAGE TAGS. An aborted or never-installed
  `./build.sh --ci-full --install` leaves images tagged at a version NO binary
  carries (here `v56.9.1.10`: ten images from a bumped run whose install step
  never landed), and `tillandsias --init` then REFUSES as a downgrade — exit 1,
  "launch the newer build you already have" — and builds nothing. A checklist
  that says "run --init" and moves on reads that refusal as done. Order:
  (a) `podman images` census by tag; (b) prune every versioned tag that is not
  the installed VERSION — this is the daily-maintenance "superseded images"
  step (55 tags removed here; ~1G on disk, because versions share layers);
  (c) THEN `--init`, and read its exit code, not its silence.
  `--force-downgrade` is the wrong tool when the "newer" enclave is an orphan
  tag: it rebuilds the same images and prints a rollback warning about a
  rollback that is not one.
- **`--init` after a tag prune is a COLD bake.** The pruned tags held the
  shared layers; forge-base rebuilt from dnf (573 packages). Launch it
  throttled (`nice -n 19 ionice -c 3`) and expect 15–30 min. Do not launch a
  lane until `INIT_RC=0`: a lane launch contends the same 900s image flock and
  bakes unthrottled on the operator's desktop.
- **Censusing the bake: pgrep is ERE, `$!` is the wrong pid.**
  `pgrep -f 'a\|b'` matches NOTHING (`\|` is a literal in ERE) and reads as
  "the build died"; write `pgrep -f 'a|b'`. And `tail --pid=$!` on a
  `nice ionice setsid nohup` chain watches the setsid PARENT, which forks and
  exits at once, so the watch ends in seconds while the build runs on. Watch
  the wrapper shell's pid (from `pgrep -f` after launch), never `$!`. Both
  fired in the same minute here and produced a confident, wrong
  "killed mid-build" — nearly a second `--init` onto the flock.
- **The nix binary cache is `blocked:nix-cache:no-ca` until the first stack
  ensure.** The enclave CA lives on `/tmp/tillandsias-ca` (tmpfs), so every
  reboot mints a new root at the next stack launch; `nix-cache-service.sh
  ensure` BEFORE that launch is a sequencing fact, not a failure. Run it
  after the first lane comes up. (The tmpfs CA is also the HTTPS
  durable-trust-root item: same root cause.)
- **The tray does not auto-start after a reboot on this host** — no
  `~/.config/autostart` entry, no user unit. `pgrep -x tillandsias` is the
  only truthful "tray alive" check. Podman's restart policy DID bring
  `tillandsias-dev-inference` back on its own (on the pinned
  `v0.4.260818.1` inference image, by design not per-version), so a running
  expert container is not evidence the tray is up.
- **Daily gate + cargo hygiene.** `check-daily-maintenance.sh check` said
  `due:stale:2026-08-29`. The body ran throttled: nix gc freed 1G to the 20G
  ceiling, delegate sweep clean, nix-toolbox fixture 13/13, nix-deps stable;
  then `cargo clean --profile dev` took target/ from 86G to 7.8G and the disk
  from 86% to 82% — on btrfs the 86% was itself a performance defect (the
  thrash the operator felt). The stamp names each step that actually ran.
