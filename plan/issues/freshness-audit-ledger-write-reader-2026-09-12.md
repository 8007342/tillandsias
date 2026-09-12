# Freshness audit — ledger-write-reaches-its-reader — 2026-09-12

- **Classification**: optimization
- **Status**: completed
- **Auditor**: `forge-forge-tillandsias-opencode-20260912t022452z`
- **Host**: `forge-tillandsias`
- **Component**: `scripts/test-ledger-write-reaches-its-reader.sh`
- **Disposition**: **updated**

Standing freshness audit class (order 372): this cycle re-validated one
component. The component's prior stamp (`added 2026-09-06 macneo-macos (order
1080-4deb)`) dated the original ARM 1 + ARM 3 landing; this cycle substantively
changed the file by adding ARM 2 (blocker-in-prose report) and the ARM 4
(correction-fragment) cross-reference presence arm, so the correct disposition
is `updated`, not `refreshed`.

Evidence:

- `bash -n scripts/test-ledger-write-reaches-its-reader.sh` — PASS.
- `bash scripts/test-ledger-write-reaches-its-reader.sh` — exit 0, 15 arm
  assertions, all `ok`. Arms: negative control (+ vacuity), denominator (6
  ready fixture packets), ARM 2 (4 assertions incl. both prose block fixtures
  and healthy/claim-free negatives), ARM 4 presence, ARM 3 (2), ARM 1 (4).
- Pre-fix RED (report call commented out) captured on the packet's event
  stream before enabling, per the packet's own next_action item 1.
- A scan of the LIVE ledger with `blocked_in_prose_orders` reports zero hits
  (reference instances 317 / 1070-qi2e were re-statused), so the checker does
  not flag currently-healthy rows.

Coverage note: inventory reports 1712 components, 72 stamped (4.2%); the
defined-subset target is unchanged (delivered by `freshness-target:` reading
methodology.yaml). No denominator drift this cycle.