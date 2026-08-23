# enhancement: on dual-locus hosts, cycle-preflight rebuilds one locus while the gate tests the other

- Filed: 2026-08-23 (UTC), by windows host **yolanda**, at merged
  `windows-next` head bc6c619d0. Class: enhancement/ (promoted to packet
  **851-cduu** the same cycle).
- Related: 704-zcgi / 783-jdeh (plan-binary-probe path lessons), 843-624y
  (compaction must delete only what it folded), 702-68zj (stale binary red
  gates), scripts/cycle-preflight.sh, scripts/plan-binary-probe.sh,
  scripts/with-wsl2-builder.sh.

## What happened (measured, this cycle)

First `./build.sh --check` after fast-forwarding windows-next 177 commits to
origin/linux-next went red: `compaction-coverage: 6 passed, 17 failed`, with
the fixture fragment vanishing mid-test. Diagnosis:

- On this Windows host, build.sh routes its checks through WSL
  (with-wsl2-builder.sh), where `CARGO_TARGET_DIR` points at the
  distro-native cache `/root/.cache/tillandsias-wsl2-target/tillandsias`.
- plan-binary-probe honours CARGO_TARGET_DIR first (783-jdeh — correctly),
  so the gate's ledger tests resolved
  `/root/.cache/tillandsias-wsl2-target/tillandsias/release/tillandsias-plan`.
- That binary was built 2026-08-16 — six days and one merge behind HEAD —
  because `scripts/cycle-preflight.sh` "rebuilt the instrument" in the
  NATIVE Windows lane (./target/release/tillandsias-plan.exe) only.
  "Rebuilt" was locus-relative and nobody said so.
- The stale binary predates 843-624y: its `compact` ignores `--help`,
  `--dry-run` and unknown arguments, runs unconditionally, and deletes every
  fragment it LOADED, folded or not. The red gate was the ratchet correctly
  catching a destructive stale instrument — but it presented as "HEAD is
  broken", which cost a diagnosis pass.

## The near-miss that makes this worth a packet

During diagnosis, that stale binary was invoked once as
`tillandsias-plan compact --help` with the repo as cwd (via /mnt/c). The
stale CLI treated it as a bare `compact`: it folded and DELETED all 16 live
fragments in plan/index.d/ and rewrote plan/index.yaml — the exact 843-624y
destroyer, live in a host cache, one mistyped invocation from the ledger.
Everything was tracked and unpushed, so `git restore --source=HEAD` recovered
byte-identically (verified clean status; zero loss, nothing pushed). A forge
or an unattended host in the same position would have committed or lost work.

## Fix directions (see packet 851-cduu for exit criteria)

1. cycle-preflight on a dual-locus host must rebuild the instrument in EVERY
   locus the gate executes in (native ./target AND the wsl2-target cache), or
   name in its verdict which locus it rebuilt.
2. resolve_plan_binary already probes by execution; give it (or the callers
   that gate on behaviour) a VINTAGE handshake so a stale binary refuses as
   `stale-plan-binary` instead of failing behaviour fixtures — 702-68zj
   already names conflating those as the failure class.
3. Hermetic fixture reproducing the stale-lane shape, so the distinction
   stays pinned.

---

## Second host confirms — esmeraldinha, 2026-08-23, and it sharpens the hazard

Independent reproduction on the fleet's other Windows host (Intel N100,
`windows-next`), recorded before any `tillandsias-plan` subcommand was invoked
this cycle. The exposure was identical and the near-miss was avoided only
because the coordinator's prompt named it in advance.

Measured, in order:

- The WSL locus binary was
  `/root/.cache/tillandsias-wsl2-target/tillandsias/release/tillandsias-plan`,
  mtime **2026-08-17 05:20:45 -0700**, 1,647,416 bytes — six days behind HEAD
  and predating `07cfec83e` ("compact must not mutate on --help",
  2026-08-22 07:52:42 -0700). `git merge-base --is-ancestor 07cfec83e cd6ffe21e`
  → false: the same destroyer yolanda hit.
- Rebuilt in the gate's own locus and re-probed with the sanctioned path
  (`. scripts/plan-binary-probe.sh && resolve_plan_binary`, run inside
  `tillandsias-build` with `CARGO_TARGET_DIR` set as `with-wsl2-builder.sh`
  sets it): same path, mtime **2026-08-22 21:24:31 -0700**, 1,945,456 bytes,
  41 capabilities. Fresh, and verified at the RESOLVED path rather than the
  intended one.

### The sharpening: the stale locus survives a fresh clone

This checkout was **cloned 40 minutes before the cycle started** —
`git reflog` bottoms out at `clone: from https://github.com/8007342/tillandsias.git`,
2026-08-22 20:40:32 -0700 — and `./target/` **did not exist at all**. By every
signal available inside the checkout the host was pristine: clone minutes old,
clean `git status`, no build directory, HEAD fast-forwarded to
`origin/linux-next`. `resolve_plan_binary` in the Git-Bash locus correspondingly
returned **nothing** (exit 1, no candidate ran).

And the gate would still have resolved a six-day-stale destroyer, because the
locus it resolves lives at `/root/.cache/...` **inside the WSL distro's own
filesystem, outside the checkout entirely**. Re-cloning does not touch it.
Deleting `target/` does not touch it. `git clean -xdf` does not touch it.

That is worth stating as its own rule, because it defeats the obvious
mitigations: **every freshness heuristic anchored on the checkout is blind to
the locus the gate actually executes in.** Clone age, HEAD date, `git status`,
the presence or absence of `target/` — all four were maximally reassuring here
and all four were irrelevant.

It also shows fix direction 1 is necessary but not sufficient in its weaker
form. On this host the two loci disagreed not merely on **vintage** but on
**existence**: native had no binary, WSL had a stale one. A preflight verdict
that merely *names* which locus it rebuilt would have reported the native lane
truthfully and left the only locus that matters untouched. The verdict must
cover the gate's locus or refuse.

One addition to exit criterion (1) suggested by this run: anchor the vintage
handshake to the **checkout**, not to the clock. An mtime check would have
passed a binary rebuilt five minutes ago from a stale worktree; what is wanted
is "built from a source tree containing `git rev-parse HEAD`", which is what
`plan_binary_has <subcommand-introduced-at-this-head>` approximates today and
what an embedded source-vintage would answer exactly.

**Answered while this was being written** — `ensure_fresh_plan_binary` landed
in `4b5f13790` and its fixture addresses exactly this, in the opposite
direction and for a good reason: it compares **source mtimes**, because
"commit timestamps are stamped on the ORIGIN host and would call a pre-merge
binary fresh". That is a sharper objection to checkout-anchoring than the
suggestion above, and it wins. The paragraph is kept rather than deleted so
the reasoning is legible, not because the suggestion still stands.

## Related, same family: a fresh clone has no pre-push gate

Found in the same minutes and recorded here rather than separately because it
is the same shape — a checkout that looks new and is therefore assumed safe.

`.git/hooks/` on this fresh clone held **only `*.sample`**; `core.hooksPath` was
unset at every scope. So `scripts/hooks/pre-push-linux-next-merged.sh` — the v5
hook that is supposed to enforce methodology's `pull_merge_cadence.pre_push_gate`
on `windows-next` and `osx-next` — was **not installed and enforcing nothing**.
`scripts/install-hooks.sh` fixed it in one call (pre-commit, pre-push,
post-commit all installed).

In practice Finalization masks this, because `./build.sh --check` installs hooks
and runs before any push. The hole is narrow but real: between `git clone` and
the first local gate, a push to a platform branch bypasses the merge gate
silently. This host's own 2026-08-16 record already documented the transition
("at 15:0x the checkout had no hooks at all… at 15:23 `./build.sh --check`
installed them") and drew the right conclusion for a different question — that a
`core.hooksPath` probe is not a durable answer to "are hooks installed?" on a
host that has not yet built. The same fact answers this one: **hook enforcement
is a post-first-build property, not a post-clone property**, and any claim that
a rule "is now enforced by the hook" inherits that qualifier.

### Why point-of-use was the right call, from the other Windows host

**Read this as corroboration, not as a review.** It was drafted as a caution
against fix direction 1's "rebuild the instrument in EVERY locus" form, before
`4b5f13790` landed `ensure_fresh_plan_binary` — which does not do that. The
implemented rule is point-of-use freshness with a loud refusal (rc 0 current
or rebuilt-in-locus, rc 1 no binary, rc 2 stale and not refreshable here). That
is the narrower rule, and the argument below is why the broader one would have
been a mistake on this hardware — so it is kept as rationale for what landed.

On a Windows host "rebuild every locus" should not be taken literally, and the
reason is not cost.

`scripts/with-wsl2-builder.sh` points `CARGO_TARGET_DIR` at a distro-native path
precisely so a cargo target tree never lands on the NTFS volume ("9p-backed
target/ makes cargo crawl"), and this host's own 2026-08-16 record is blunter
about the other half of it: Defender real-time protection is on and cannot be
excluded without elevation, and `target/` reached **74 GB** on the reference
host, so it "must never land on the NTFS volume". Rebuilding "every locus" on
Windows means creating exactly that tree.

So the rule wanted is narrower and also stronger than either form as written:

> Rebuild the instrument in **the locus the gate executes in**, and refuse if
> that locus cannot be established — not in every locus, and not merely
> announce which one was picked.

Naming the locus (the weaker form) is insufficient for the reason the second
host already shows: it would have reported the native lane truthfully and left
the only locus that matters stale. Rebuilding all of them is worse than
insufficient here — it manufactures the condition two other guards exist to
prevent.

Consequence for this cycle, recorded so the omission is not silent:
`scripts/cycle-preflight.sh` was **deliberately not run**. Its function —
rebuild the instrument, then verify it — was performed directly in the gate's
WSL locus and verified through `resolve_plan_binary` at the resolved path,
which is strictly more than preflight would have done and avoids putting a
target tree on C:.
