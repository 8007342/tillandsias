## Cycle 2026-09-03T21:15Z — tlatoanis-macbook-air (osx-next)

Closed 836-smm2 and 837-svzd (810a2fc24). Both were READY-BUT-DONE — their
deliverables were already satisfied and nobody had closed them.

I nearly spent the cycle re-implementing 836-smm2. It surfaced as the
highest-priority any-role packet in architecture-audit-epic, I read it as live
work, and only a grep before starting showed the two functions were already
deleted (c3f6591a1). That is what a finished packet left in ready costs: the
next host pays the discovery instead of the work. Checked both against the tree
with named commands rather than assuming, then closed.

WHAT I VERIFIED AND WHAT I DID NOT, because the two packets differ:
* 836-smm2 criteria 1-3 read directly off the tree, and its own named closure —
  scripts/check-exec-argv-vector-workarounds.sh — reports
  ok:exec-argv-workarounds-absent:2 checked. Criterion 4's clippy/test is NOT
  verified for the Windows target from here: notify_icon.rs is a windows-only
  source macOS does not typecheck, and the event records that rather than
  claiming it.
* 837-svzd's second half I could verify BY COMPILATION — wsl.rs has no cfg
  gate, so this host builds it. wsl_root_sh now uses --exec, bypassing the
  guest login shell so there is no re-join to shred the payload.

CLOSED A WINDOWS-ROLE PACKET FROM macOS deliberately (837-svzd): the deliverable
is objective, has no exit_criteria requiring a Windows run, compiles here, and
the packet is neither a split parent nor depended on. Said so on the record so a
Windows host can reopen it in one command if they disagree.

PROCESS FIX THAT MATTERS MORE THAN EITHER CLOSURE. Shell backtick expansion ate
a phrase from an event for the FOURTH time this session. I had written down "do
not use backticks in event prose" twice and done it again — attention is not a
fix. The tool already refuses the unsafe form and names the safe one:
--summary-file. Switched to it. Same argument this fleet has made all day about
guards, applied to my own habits: a rule that depends on remembering is a hope.

Gate green (278s).
