# `build-guest-binaries.sh` treats a VERSION match as "up to date", so a source change at an unchanged VERSION never restages

- Order: 695-r7k8
- Class: enhancement
- Filed: 2026-08-12, windows host, branch `windows-next`
- Found by: meta-orchestration cycle 5, while restaging the guest to observe a
  line the same cycle had just added to it

## Observation

Changed `crates/tillandsias-headless/src/main.rs` (the 620-duta preflight line),
then ran the staging script:

```
$ ./scripts/build-guest-binaries.sh
[build-guest-binaries] Staged binaries are up-to-date. Skipping build.
[build-guest-binaries] ✓ x86_64 version check passed: Tillandsias v0.4.260810.1
[build-guest-binaries] ✓ Verification SUCCESS
```

No rebuild. The staged binary still predated the edit, and the script reported
success — twice, with a checkmark.

The cause is the fast path near the top of the build branch:

```bash
if verify_binaries >/dev/null 2>&1; then
    echo "[build-guest-binaries] Staged binaries are up-to-date. Skipping build."
```

`verify_binaries` checks existence, arch, staticness, and that the binary
carries the workspace VERSION **string**. None of that is a currency check
against the SOURCE. A VERSION stamp only rolls on release, so every source
change between releases leaves the staged binary stale while satisfying every
condition the script tests.

## Why this is the root of a chain, not an isolated annoyance

This is the third face of the same mistaken equivalence — *version equality
implies currency* — and the three compound:

1. `build-guest-binaries.sh` skips restaging on a VERSION match (this packet),
   so the staged binary keeps the old code.
2. `build-windows-tray.ps1` embedded whatever was staged without a currency
   check (689-gipe, fixed 2026-08-11), so the tray shipped that old code.
3. `reconcile_adopted_guest` returns early on a VERSION match, so even a
   correct tray injects nothing into an adopted guest at the same stamp
   (visible since 620-duta criterion 1 as `outcome: skipped-version-match`).

Any one of the three is survivable. Together they mean a guest-side fix
developed between releases can pass through the whole build-and-deploy path and
reach nothing, with every step reporting success. That is exactly what happened
with 627-sgtt, and it took three cycles and a new diagnose field to establish.

Step 3 is arguably correct as designed (skipping work on a genuinely unchanged
guest is the fast path that keeps healthy installs fast) — but it is only safe
if steps 1 and 2 cannot hand it a lie about what "this version" contains.

## Smallest next action

Make the staging fast path source-aware rather than stamp-aware. The cheapest
honest form: skip only when the staged binary is NEWER than the newest mtime
under the crates the guest binary is built from; otherwise rebuild. A
content-hash of the source set would be stricter and is not obviously worth the
complexity here — the failure mode to kill is "silently skipped", and a
timestamp comparison kills it.

Whatever the mechanism, `--verify` must keep its order-447 behaviour
(`verify:skip-stale-staging` on stale staging, loud only on a real integrity
defect). This packet is about the BUILD path's skip decision, not the verifier's.

## Verifiable closure

Touch a source file under `crates/tillandsias-headless/`, run
`scripts/build-guest-binaries.sh` with an already-current-VERSION staged binary,
and observe that it REBUILDS. Negative control, and the load-bearing half: with
no source change, a second consecutive run must still skip — a fix that simply
always rebuilds passes the first check while making every tray build minutes
slower.

## Related

- 689-gipe — step 2 of the chain, fixed.
- 620-duta — step 3 made visible.
- 627-sgtt — the packet the chain misled.
- 447 — the ruling that stale staging is host state; unchanged by this.
