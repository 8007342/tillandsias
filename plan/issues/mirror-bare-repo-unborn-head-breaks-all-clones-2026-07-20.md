# Mirror bare repository has an unborn HEAD, so every forge clone transfers objects but checks out no tree (2026-07-20)

- order: 454
- status: completed 2026-07-20 (this cycle) — fix implemented + offline-verified;
  live rebuilt-image proof rides order 452 slice 3. See plan/index.yaml order 454.
- **Class**: bug (git-mirror bootstrap / checkout correctness)
- **Severity**: P0 — every clone-only forge launch fails at checkout
- **Found**: reproduced 2026-07-20 at checkout `c5708f79` over the production
  `git://` upload-pack transport
- **Owner host**: linux
- **Related**: order 452 (missing piece of exit criterion 1),
  `forge-launch-must-guarantee-fresh-checkout-idempotency-2026-07-20.md`

## Symptom and concrete reproduction

Every clone-only forge launch fails, on every harness and every launch, even
when the current mirror is fully seeded. After order 452's fail-loud guard, the
guest clones the mirror and immediately runs `git rev-parse HEAD`. That command
fails, so the guest removes the checkout, retries five times at one-second
intervals, then exits 1 with:

```text
Refusing to launch an agent on an empty working tree
```

The clone itself exits 0 after transferring the refs and objects, but emits:

```text
warning: remote HEAD refers to nonexistent ref, unable to checkout
```

The resulting working tree is empty and its local `HEAD` is unborn. Order 452
correctly converted the earlier silent "forge had no checkout" symptom into a
loud launch failure; it did not create the underlying mirror defect.

## Root cause

`images/git/entrypoint.sh:99` creates the mirror with `git init --bare`. Alpine
Git initializes the bare repository with symbolic `HEAD` pointing to
`refs/heads/master`. The seed fetch at line 243 writes the upstream `main` and
`linux-next` heads into the mirror, but no startup path repoints the bare
repository's `HEAD`.

Live `git ls-remote` evidence from 2026-07-20 shows that
`github.com/8007342/tillandsias` has no `master` branch: its advertised heads
were only `main` at `7914f2ea` and `linux-next` at `c5708f79`. Therefore the
mirror advertises a symbolic default that does not exist. A clone over the
production `git://` upload-pack transport can successfully transfer every
object and branch while leaving the checkout empty because the remote `HEAD`
cannot be resolved.

## Blast radius

The blast radius is total for clone-only forges: no agent on any harness can
start with a checkout. Before order 452 this violated the checkout guarantee
silently by launching the agent into an empty tree. After order 452 it fails
loudly and consistently, which is the correct failure mode but still prevents
all forge work.

## Corroborating live-host evidence

On the Linux coordinator host at approximately 15:24 PDT on 2026-07-20, the
Podman volume `tillandsias-mirror-tillandsias` existed but was completely empty:
there was no bare repository, showing that the seed had never completed in
that launch. No `tillandsias-git` container existed. The support stack had
started at 15:21 and was torn down at 15:24; Podman recorded vault exit 137,
inference exit 137, and proxy exit 139 after Squid logged a graceful shutdown.

This is a second route to the same user-visible empty-checkout failure. It also
shows why mirror readiness is still required, but an already fully seeded
mirror independently reproduces the unborn-`HEAD` failure described above.

## Smallest correct fix and exit criteria

1. Add `ensure_mirror_head` to `images/git/entrypoint.sh`. Invoke it after
   `git init --bare`, after the empty-mirror seed fetch, and after the startup
   fast-forward fetch. When `git rev-parse -q --verify HEAD` fails, it must run
   `git symbolic-ref HEAD refs/heads/<target>`, selecting the target in this
   order: `$TILLANDSIAS_PROJECT_DEFAULT_BRANCH`; the upstream symref parsed from
   `git ls-remote --symref origin HEAD`; `main` if it exists; otherwise the
   first available head.
2. Pass `TILLANDSIAS_PROJECT_DEFAULT_BRANCH`, set to the host checkout's current
   branch, into the git container environment from the launcher.
3. Add an offline fixture that creates an `init --bare` mirror whose default
   `master` ref does not exist, reproduces the successful-but-unborn clone, then
   runs the repair and proves a new clone has a resolvable `HEAD` and a
   non-empty working tree.
4. Verify a fresh-volume forge launch lands the agent on the operator's current
   working branch, not merely GitHub's default branch.

Closure requires all four criteria. In particular, a readiness gate alone does
not close the packet if the populated mirror still advertises a nonexistent
default ref.
