# FOUNDATIONAL DIRECTIVE: runtime ephemerality — destroy-and-recreate over fix-forward, always

- Date: 2026-07-17
- Source: The Tlatoāni, verbatim-close session directive, after a live
  cascade where an agent (me) repeatedly tried to hand-fix a borked
  host/VM/guest/podman/vault stack instead of destroying and recreating it.
- Scope: methodology principle + a sweep of ALL skills, scripts, and error
  messages to embody it.
- Related: methodology/philosophy.yaml (core principle), the runtime
  ephemerality vs the existing WORK-state ephemerality in
  methodology/between-commits-work-discipline.yaml (distinct — this is about
  the RUNTIME substrate, not commits), guest-crashloop-detection +
  guest-intentional-ephemeral-reset (windows-260717-3/-4),
  vault-unseal-secret-regenerated-on-reensure (windows-260717-2),
  stable-milestone-v1 (order 334).

## The principle (operator, verbatim intent)

"The whole idea of Tillandsias is that everything is ephemeral by design.
Our persistence is just convenience, but is a side effect. Do not slow down
because of borked state ever, just destructively recreate as needed."

"Whenever something is borked:
 1) Throw it away and build a new one from scratch. Everything will work
    because we designed to do so.
 2) If that fails, throw that away AND one level higher up also throw away,
    and rebuild them from scratch.
 3) Repeat 2) as needed."

"Stop 'fixing' stuff, and start destroying and recreating stuff. ALL THE
TIME. There's no 'just this one tiny fix forward'."

"Even our error messages should go 'just recreate this container bro' ;)"

## Why (the anti-pattern this kills)

Fix-forward on a disposable substrate is a trap: each hand-patch of a
borked host/VM/guest/podman/vault layer tends to produce a NEW failure one
layer down (observed live 2026-07-17: vault key skew → manual generate-root
→ unseal-secret regen → podman pause-process → podman uid_map/subuid → …),
burning time and compounding breakage. The substrate is DESIGNED to be
rebuilt cleanly, so the fast, reliable path is always: destroy the borked
layer and recreate it. Persistence (vaults, clones, caches) is a
convenience side-effect; its loss costs at most a re-auth, and everything of
value lives in the cloud + the operator's identity.

## The layer ladder (destroy-and-recreate escalation)

Bottom→top, each layer recreatable from the one above:
`podman/stack  →  guest (WSL distro / VZ VM)  →  host tray/app  →  release`.

On borked state, escalate ONLY as far as needed, and never hesitate:

1. Recreate the borked unit from scratch (e.g. `podman rm` + re-ensure the
   container; `--reset-guest`). It is designed to come up clean.
2. If that still fails, throw away the unit AND the layer above it, recreate
   both (e.g. unregister the guest + reprovision; if the guest keeps coming
   up broken because the tray pins a stale version, recreate the TRAY too —
   full reinstall — so the guest it fetches is current).
3. Repeat up the ladder until clean. A stale release is itself a layer:
   recreating from it reproduces its bugs, so "recreate" may mean rebuild
   from CURRENT source (the local build path), not re-fetch the release.

Corollary (learned live): the guest version FOLLOWS the tray version, so
recreating only the guest against a stale tray reproduces the stale guest —
you must go up a rung to the tray. And the published release can itself be
the stale layer (order 334): recreate from source when the release lags.

## What must change (the sweep)

1. **Methodology**: a first-class runtime-ephemerality principle
   (philosophy.yaml + a dedicated recovery doc) that names the ladder and
   declares destroy-and-recreate the DEFAULT recovery, fix-forward the
   exception (only for durable source/spec/config bugs, never for borked
   runtime substrate).
2. **Skills**: every skill that touches the runtime (build/smoke/e2e/
   meta-orchestration/advance-work/coordinate) must, on borked substrate,
   destroy-and-recreate per the ladder rather than diagnose-and-patch — and
   must NOT slow the loop to nurse a borked layer. Audit + edit the skill
   text. The destructive-reset policies already in several skills are the
   seed; generalize them.
3. **Scripts**: recovery/ensure paths should prefer `--replace` / recreate
   over in-place repair; provide/за wire the one-click reset
   (windows-260717-4) and expose it from tooling.
4. **Error messages**: user- and agent-facing errors for borked runtime
   state should TELL YOU TO RECREATE — literally "just recreate this
   container/guest — everything's ephemeral; you'll re-auth once" — with the
   exact command, instead of "operation not permitted / try podman system
   migrate / reboot to recover" dead-ends. Recreation guidance is the
   correct remediation surface.

## Guardrails (so this is not reckless)

- Destroy-and-recreate applies to the RUNTIME substrate (containers, guest,
  VM, tray install, caches). It does NOT license destroying DURABLE work:
  committed code, specs, plan, methodology, or unpushed commits — those
  follow between-commits-work-discipline (push to origin first). The one
  thing to never wipe casually is un-pushed durable work; the runtime is
  always fair game.
- Recreation must actually converge (the thing is designed to come up
  clean). If recreation ITSELF loops, that is a real bug in the recreate
  path (file it), not a reason to fall back to fix-forward.

## Verifiable closures (for the sweep packets)

- Methodology: philosophy.yaml carries the runtime-ephemerality invariant;
  a recovery doc states the ladder; both linted/parsed.
- Skills: a grep/audit shows each runtime-touching skill's borked-state
  branch says "recreate" not "repair"; a litmus or checklist pins it.
- Error messages: a source scan asserts runtime-borked error paths emit
  a recreate-this instruction with a command (no bare
  "operation not permitted" dead-ends for recreatable substrate).
