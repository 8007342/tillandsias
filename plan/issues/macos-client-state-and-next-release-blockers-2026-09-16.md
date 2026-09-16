# macOS client state, and what must be in the next cut

**Written at the operator's instruction 2026-09-16, as diagnosis only.** They
were installing the newly-promoted stable on `tlatoanis-macbook-air`, hit the
GitHub-login refusal, and asked for the real state recorded rather than repaired
tonight: "take note of anything that needs to get done, and make sure it happens
by the next release whenever that happens."

**THERE IS NO MECHANISM THAT ENFORCES THAT INSTRUCTION.** `release-preflight.sh`
has exactly four gates — VERSION monotonicity, retired CLI flags, plan-ledger
integrity, Actions budget — and none of them reads "this row must ship next".
So "make sure it happens by the next release" today means *somebody remembers*,
which is the failure mode this fleet keeps writing down. Filed as 1218-25z3.
This document is the list that gate does not yet read.

## 1. The accurate state of the macOS client — specific, not wholesale

The client is NOT broken across the board, and saying so would misdirect whoever
picks this up. On `v56.9.13.1`, macbookair's own curl-install smoke recorded
**PASS with no product findings**: install clean into `/Applications` with no
`~/Applications` fallback, destructive reset real (2.3 GB of Application Support
plus a sparse `rootfs.img` removed and their absence asserted), provision from
pristine including a full 528 MB Fedora image download, `diagnose_exit=0`,
`provisioned=true`, `rootfs_present=true`, version matching the tag exactly.

**What is broken is GitHub login, and everything downstream of it**: no remote
project enumeration, and no git-mirror relay credential. That is severe and it is
not "the macOS client is broken" — it is one lane, and the distinction decides
where anyone looks.

## 2. Why there is no operator-side workaround on macOS

Three candidates were checked and all three are dead:

- **`TILLANDSIAS_PROJECT_REMOTE_URL`**, which the shipped refusal advertises, is
  INERT for this path. `read_host_project_origin_url` reads `git config` and
  `.git`-pointer files and never consults the environment. The variable is real
  and the cloud lanes read it, which is exactly what makes the wrong advice
  plausible. Order 1211-34v6 deleted that sentence — **on trunk, not in this
  tag** — so the shipped stable actively sends operators in a circle.
- **"Run it from a checkout"** has no macOS lane at all. The repository is
  resolved from the CWD of the process running the login, which is the in-VM
  daemon the tray talks to — not the operator's shell, and not the ephemeral
  login helper container (the container only RECEIVES the resolved `owner_repo`
  as a string; see `github_push_authorization_probe_args`). The operator cannot
  set that CWD from the tray, and `scripts/build-macos-tray.sh` copies exactly
  one binary into the bundle, `tillandsias-tray`. The release workflow builds no
  `apple-darwin` headless target, so the documented CLI remedy does not exist on
  this platform.
- **A forge session** cannot run it either: `images/default/Containerfile`
  installs `tillandsias-help`, `tillandsias-inventory` and
  `tillandsias-brew-shim-exec`, and no headless CLI.

## 3. NOT CAUSED BY THE PROMOTION

`v56.9.12.2` — the previous stable — carries the identical defect; it is the
build yolanda-windows diagnosed it on. Promoting `v56.9.13.1` did not introduce
this and did not repair it. Recorded because a version bump immediately followed
by a visible failure invites the wrong causal reading.

## 4. Must be in the next cut

Ordered by what they cost a user who hits them.

| row | state now | why it must ship |
|---|---|---|
| **1211-34v6** | fixed on trunk, NOT in v56.9.13.1 | the shipped refusal advertises a remedy that cannot work. Until this ships, every operator who reads it spends time on a dead end. Cheapest item here and the highest ratio. |
| **1215-xazj** | UNFIXED everywhere | the tray's `--github-login` cannot succeed on any platform. This is the defect itself. Its principled fix is blocked on 1217-54vw; an interim that merely reaches the probe would still be strictly better than the current state. |
| **yoga's criterion 4** (`37d16f864`) | landed on trunk 2026-09-16 | the probe names WHICH repository it verified, on both the success and refusal paths, printed BEFORE the probe runs so a hang still says what was about to be checked. Also splits an absent origin from a non-GitHub origin, which previously produced one message about absence. Without it the next failure is as undiagnosable as this one was. |
| **1171-ccf2** | implemented on trunk, NOT in the tag | the Windows zip does not carry `tillandsias-headless.exe`. Windows-only; does not affect macOS. |
| **890-y72v** | on trunk | DeliverCredentialsReply carries an accept/reject discriminator — a **WIRE v4 BUMP**. Host and guest must move together, so this must not be split across releases. |
| **1201-t6ms** | on trunk | the server-side wire-version refusal test, which the two wire bumps rest on. Ships with 890-y72v or neither. |

## 5. Open and NOT release-blocking, recorded so they are not lost

- **1217-54vw** — the probe verifies ONE repository and seeds a credential used
  for ALL of them. yoga-silverblue is costing per-project credentials against
  check-at-use, publishing method and no recommendation. Its first
  could-not-measure entry is the seeded token's actual scope: reading it sends
  the operator's credential to an external service under their identity, which
  is theirs to authorize per run. The coordinator proposed that read without
  that authorization and yoga correctly refused.
- **1215-cxgb** — yolanda-windows' working login rests on a hand-written
  `.git/config` nothing provisions, in a guest the tray reprovisions itself.
  Operator decision, three options, has a clock.

## 6. What this test run established

The operator's session ends here. It produced, in order: a stable promotion from
blessed artifacts; a live reproduction of 1215-xazj on a fourth host by the
operator personally; confirmation that the shipped refusal text misdirects; and
the finding that no release gate can express "must ship next". The last of those
is the one that makes the other five survive.

trace: 759-vceg, 1211-34v6, 1215-xazj, 1217-54vw, 1218-25z3, 803-49re
host: macuahuitl (coordinator), reproducing host tlatoanis-macbook-air

## 7. A correction to this document, left visible rather than tidied away

Section 4's row for yoga's criterion 4 first cited **`9ac4e0237`**. **That commit
does not exist in this repository.** The coordinator took it from yoga's
in-flight message — they wrote "landing as 9ac4e0237" while it was still in its
gate — and wrote it into the list as though it were a fact about origin. The
landed implementation is **`37d16f864`**, with the claim release at `60294e3de`
and the cycle record at `9f2394147`; all three are ancestors of `origin/linux-next`
and were verified with `git merge-base --is-ancestor` before this correction.

This is the shape the fleet already has a rule for — hand peers a CONDITION, not
a local SHA — arriving in the one document whose whole purpose is to be acted on
by someone who was not here. A dead reference in a blocker list is worse than no
reference: it reads as precision and costs the next reader the time to discover
it resolves to nothing. Corrected rather than silently replaced, because the
error is instructive about how this list should be read: **verify every sha in
section 4 against origin before acting on it.**

## 8. The measured cost of section 4 having no gate — verified timestamps

Relayed independently by macbookair-macos from the host it happened on, and
re-verified here against origin rather than repeated:

```
release v56.9.13.1 published   2026-09-14T01:57:30Z
e15c81e6d committed            2026-09-15T21:28:45Z   fix(1211-34v6)
operator hit the refusal       2026-09-16, hours after that commit
```

The fix postdates the artefact by **1 day 19 hours 31 minutes** — and it was
**already on trunk when the operator walked into it**. Not missing, not
unwritten, not unreviewed: landed, green, and sitting in a branch no artefact
had been cut from. The operator read the exact sentence that commit deletes.

That is the concrete cost of 1218-25z3 and the reason this document exists. The
operator's own emphasis, in their words via macbookair: timing does not matter
to them — what matters is that fixes REACH MAIN AND A RELEASE.

**Recorded next to the complaint, because the complaint reads harsher without
it:** the guard behaved correctly. It refused, wrote nothing to Vault, cited
759-vceg and 803-49re by order, and explained why seeding on authentication
alone is the failure that looked healthy and broke the operator forty minutes
later. The single defect was the remedy line. A guard that fails closed with a
wrong remedy is still far better than one that seeds and breaks at first push.

