# Smoke e2e findings — release v56.9.5.1 — 2026-09-05 — esmeraldinha (windows floor)

- lane: windows / `windows-next`
- host: ESMERALDINHA — Intel N100, 4c/4t, 15.8 GB RAM, Win11 Home 26200, WSL 2.7.12.0
- release under test: `v56.9.5.1` (daily, cut 2026-09-05; run 33938905320 success 03:24:33Z)
- installed build: `tillandsias-tray 56.9.5.1 (b528680d2)` — matches `origin/main`
- sibling heads: main b528680d2 / linux-next 406395823 / windows-next 61a6039cb / osx-next 6169b531d
- runbook defects worked around: 1043-c73v (`Continue` not `Stop`), 1044-na6u (evidence deleted at
  step start), 1045-8yyw (§2b row read from `origin/linux-next`)

## PASS / FAIL

| # | Step | Result | Evidence |
|---|---|---|---|
| 0.2b | Ledger row readable on this lane | **FAIL (1045-8yyw persists)** | row absent on `windows-next`/`main`, present on `linux-next`/`osx-next`; read from trunk |
| 1 | Curl-install published artifact | PASS | `install_exit=0`, sha256 ok `7305c983…b515` |
| 1 | Installed version == release tag | PASS | `tillandsias-tray 56.9.5.1 (b528680d2)` |
| 2 | `wsl --unregister tillandsias` | PASS | distro gone; `tillandsias-build` preserved (802-bajv) |
| 2 | Cache/state purge | PASS | only `wsl-build/` remains |
| 2 | Host vault credentials cleared (804-ckst) | **PASS — decisively this round** | both present beforehand, `CMDKEY: Credential deleted successfully` ×2, whole-store read confirms absent |
| 2 | `tillandsias-vm-uuid` preserved | PASS | present after reset |
| 2 | Runbook's own credential predicate | **FAIL (3rd confirmation)** | ground truth absent, predicate reports both present |
| 3 | **Cold provision from pristine** | PASS | `provision_exit=0`, **129 s** |
| 3 | Fresh rootfs, not a survivor | PASS | destruction marker precedes the new vhdx |
| 3 | Wire Ready at provision exit | PASS | `phase=Ready podman_ready=True` **`wire_version=3`** |
| 3 | Final `--diagnose` (last step) | PASS | `diagnose_exit=0`, `version=56.9.5.1`, **`guest_version=56.9.5.1`**, `distro_running=true`, `wire.reachable=true` |
| 4 | Forge continuous-enhancement | NOT APPLICABLE | §4 is the Linux `tillandsias . --opencode` CLI; absent on Windows |
| 4b | First-launch egress assertion | NOT APPLICABLE | host-podman assertion; Windows runs podman in the guest |

**Cold-provision reference for the floor: 129 s** (v56.9.2.1 was 117 s on the same
host). This is a true cold number — distro unregistered, cache purged, measured
inline. The v56.9.4.1 round could not produce one because 1043-c73v killed the
run partway.

## 803-49re — WALKED AT LAST, and it does NOT reproduce

Two rounds recorded this as unwalkable. This round had the exact preconditions the
packet describes — freshly wiped and re-provisioned guest, host vault credentials
verified cleared — plus a live GitHub token, and the login **succeeded**:

    [tillandsias] GitHub authentication complete for 8007342

No `cached root token rejected`, no `cipher: message authentication failed`, no
`OPERATOR ACTION REQUIRED`. **Part A holds on this host**: with the host
credentials cleared, nothing stale was pushed into the fresh guest and the vault
path completed. The residual reconcile half (890-y72v) is untouched by this and
remains unproven — a host that still holds a stale credential is a different case
and this run does not speak to it.

## 759-vceg — no-upstream arm exercised, incidentally

The same command printed both halves of what that order is about:

    NOTE: no GitHub upstream is configured for this checkout, so push pe…
    token is being seeded on authentication alone — if it lacks Contents:write,
    the failure will appear at the first push, not here (order 759-vceg).

So the lane does warn that authentication is not authorization. Whether the
push-time failure is well-formed is NOT tested here — that needs a token
deliberately lacking `Contents:write`.

## FINDING — the non-interactive login's prerequisite names a tool the guest does not have

    Error: non-interactive GitHub login requires an existing git user.name;
           configure it before using --with-token

But `git` is **ABSENT** in the guest for both `root` and `forge`
(`command -v git` → nothing, no `/root/.gitconfig`). An operator following that
message cannot run `git config`, because there is no git. Writing `~/.gitconfig`
by hand — 82 bytes, `[user] name/email` — satisfies it, and the login then
succeeds; the code reads the FILE, not the binary.

Two fixes are possible and they are not the same: state the remedy in terms of
the file (`write ~/.gitconfig with a [user] name`), or install git in the guest
if the login genuinely needs it later. The message currently implies the second
while the code only needs the first.

### CORRECTION 2026-09-05 — the "race" below is RETRACTED; there is no race

RETRACTED, quoted so the record shows what was claimed:

> Note also a **race**: the first attempt failed on this prerequisite while
> `image git ensure still running in its detached helper` was printed by the same
> command. The second attempt, 40 s later, succeeded. So the error can fire for a
> not-ready-yet condition and blame the operator's configuration for it.

**The file came first.** Three timestamps from the artifacts, not from memory:

    03:51:40Z   target/803-walk3.log      the prerequisite refusal
    03:52:09Z   /root/.gitconfig          written by hand, 82 bytes
    03:52:14Z   target/803-walk4.log      the successful login

The write and the successful login were issued in the **same tool call** — the
command wrote `/root/.gitconfig`, then piped the token into
`--github-login --with-token`. So the retry was not "unchanged": the one thing
the error asked for had just been created, five seconds earlier.

MECHANISM, established by yoga reading the binary for 1052-gw8w, either half of
which is sufficient on its own:
1. The `image git ensure still running in its detached helper` line is emitted
   inside the blocking waiter's loop as a **liveness beat**. It is what waiting
   looks like, not evidence that the ensure was incomplete — the ensure had
   already completed before the login was reached.
2. **Nothing in any ensure or provisioning step writes the searched gitconfig
   paths.** No amount of elapsed time could have turned that refusal into a
   success.

HOW THE ERROR WAS MADE, since that is the part worth carrying: two true
observations — the liveness line, and 40 s of elapsed time — were joined into a
causal claim without noticing that the intervening command had changed the exact
condition under test. The elapsed time was real; "unchanged" was supplied by the
author. **A grep for the gitconfig path in the provisioning scripts would have
refuted the timing story in seconds, and the story was already satisfying.**

WHAT IS UNAFFECTED: everything above this block. `git` is genuinely absent in the
guest for both `root` and `forge`, the message genuinely instructs the operator to
run `git config`, and the code genuinely reads the FILE rather than the binary —
which is why 82 hand-written bytes worked. That finding is 1052-984i and it
stands; only the race paragraph is withdrawn (1052-gw8w, disposed false-premise).

## Ledger claims (README row, read from `origin/linux-next`)

**EXERCISED**
- **WIRE_VERSION bumped to 3** (997-e4v2 step 3, 1029-5vwd) — measured
  `wire_version=3` at Ready; it was `2` on v56.9.4.1 on this host. Direct confirmation.
- **1022-px54** proxy parse gate pinning a stale launch string — verified fixed on this
  host earlier tonight (gate 8 dropped it from the failure list after 9cac76676).
- Release assets publish and verify; `--version` carries the exact tag.
- `guest_version` is now populated (`56.9.5.1`) under a plain `--diagnose`; it read
  `null` in the two previous rounds on this host.

**NOT APPLICABLE (other platform / other lane)**
- macOS `--diagnose` stale `crashloop.state` (980-ja2m), mac HOME/CA items.
- AMD Vulkan placement; Linux tray `~/src` retirement.
- 1009-gccx cheap-decider hoisting, 1036-jamx, metrics litmus re-pin — CI-gate lane.

**NOT CHECKED — this lane could have looked and did not**
- **1032-utne**, the Windows Guest health line saying what it is and how old. This is
  the most Windows-specific claim in the row. `--diagnose --json` carries no health or
  age field (keys enumerated: no `health*`, no `age*`, no `verdict*`), so the claim
  appears to concern the tray's GUI line, which this lane cannot click. Recorded as
  unreachable-from-CLI rather than untested-by-choice.
- **1043-kvvn** duplicate `[[bin]]` names — a gate-side guard, not exercised by the smoke.
- **1031-q4pb** project-label validation failing closed; **873-vgyg** forge launch
  wedging; **972-umik** shared wire parser.

**EXERCISED WITH A QUALIFICATION — 1038-d7vw**
Not in the NOT-CHECKED list, because this lane did measure it. The row credits the
freshness-inventory fix with "18 s → 0.7 s". On this host the fixed walk measures
**13.5 s**, not 0.7 s, because the cost here is the drvfs regime rather than the
quadratic bash — the same box does **725 ms on native ext4**, in a three-way
within-host control. The fix is real and verified here; the headline number is
regime-specific and does not travel to a Windows host. A footnote on the row, not
a correction to it.

A PASS here means install, reset, cold provision and wire bring-up are sound on
the Windows floor for v56.9.5.1, and that the 803-49re login brick does not
reproduce with host credentials cleared. It says nothing about the tray UI
claims, the forge lane, or push-time authorization.
