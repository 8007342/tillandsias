## Cycle 5 2026-08-15 tlatoani — a lost completion, and 6MB of audit records on a doomed layer

**A completion was silently reverted, and no gate could see it.** The stranded
sweep rose 0 → 2. Packet 532 read `in_progress` while its work was done and on
the remote: TWO `completed` events (02:01:51, 02:02:00), then a `claim` event at
02:06:00 landed AFTER them and left the status non-terminal. So it advertised
itself as claimable work whose exit criterion was already green.

`check-fragment-status-loss.sh` could not catch it — for ONE reason, not the two
I first wrote down. **I got this wrong and corrected it before landing:** my
first draft claimed the closure-event shape "has no detector". False. That check
has existed since 2026-08-09; I read the script's first `case` block, stopped,
and asserted a gap from half a file — the exact half-reading this project keeps
filing packets about.

The real gap is narrower and still real: the detector reads `"$FRAG_DIR"/*.yaml`
— `plan/index.d` only. Compaction had just folded every fragment into the base,
so 532's events are INLINE in `plan/index.yaml` and the check that exists could
not see the packet it was written for. `ok:no-fragment-status-loss:16 checked`
was truthful and useless: 16 fragments checked, and the defective packet was not
among them. Filed **751-i9mb** (p1), deliberately ADVISORY — auto-promoting a
status from an event is how a false completion becomes permanent. 532 was only
closable because its litmus was re-run (STEP 15 green, spec 7/7), checked against
the TREE per the sweep's own rule.

**And filing that packet reproduced a second defect (752-pst5, p2).** The gate
refused the push, reporting a closure event on a packet whose only event is
`filed`. Cause: the awk clears its `packet_id` on a key at two-space indent, but
fragment fields are indented four — so the id stays live across the whole body
and any PROSE mentioning the marker is read as a declaration. My packet had
quoted the methodology passage about it. The checker already carries a fix for a
sibling false positive (awk variables crossing file boundaries, which invented a
completion for 598-kibt) and states the stakes itself: "a checker that invents
completions is worse than no checker". Same class, different door.

Left alone: 735-ead5 (v0.4 promotion — merge to main and publish) is also
stranded, but its own notes say it is HELD pending two sibling e2e gates. That
is operator-owned release work and correctly parked; the detector simply cannot
tell "deliberately parked" from "abandoned".

**Drained 749-8iw4 (T9), the rung I split out as independently claimable.**
Measured the defect before fixing it:

    mounts:  /vault/file /vault/logs /vault/data     ← no /vault/audit
    inside:  /vault/audit/audit.json = 6,182,307 bytes

The file audit device (`images/vault/entrypoint.sh:226`) was enabled and writing
6 MB of REAL records onto the container layer. `vault audit list` reports a
healthy device throughout — which is exactly what let V12 survive: the records
genuinely exist, right up until the container is recreated.

Fixed by mounting `~/.cache/tillandsias/vault-audit:/vault/audit:U` alongside
the data volume. `:U` for the same userns-drift reason as `/vault/data`, and it
matters more here: an audit device that cannot write is FATAL to Vault — every
request fails once nothing can record it.

RUNTIME PROOF, not inspection: recreated the container between two reads —
audit.json 92463 → 184926 bytes with the SAME first record accessor, so
pre-recreate history survived and new records appended. NEGATIVE CONTROL: the
same write without a volume is `No such file or directory` after recreate.
Pinned by NEW `litmus:vault-audit-persistence-shape` 5/5 — including a step
asserting the volume is actually PASSED to `podman run` rather than merely
constructed, which is the way this fix could silently regress.

Held at `implemented`, not completed: my own exit criterion claimed "§4a M6
becomes passable", and only HALF of M6 is mine. The records must survive AND
carry project/lane/principal/fingerprint/serial/refs — survival is done, field
population is 749-2fqj (T6 receive wrapper). Recording the imprecision rather
than declaring it met.

Suite green. Plan 881 packets. Release: untouched.
