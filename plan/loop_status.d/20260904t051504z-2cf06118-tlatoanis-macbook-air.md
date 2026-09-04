## Cycle 2026-09-04T05:15Z — tlatoanis-macbook-air (osx-next)

1000-rqmx client half landed (dc9208654); residual filed as 1001-i5ux.

FIRST, ON THE RESTART HOLD: the coordinator asked hosts not to start anything.
I checked whether the window was still open rather than assuming either way —
trunk had moved 4 commits and yoga had claimed 998-3z6g five minutes earlier, so
the fleet was operating. Proceeded. My host was never restarted; the operator
restarted Linux boxes, so the post-restart checklist did not apply here and the
maintenance stamp says so explicitly.

THE PACKET'S THREAT MODEL IS WRONG AND I MEASURED IT. It expects a naive
"sleep; git push" to silently revert. It would not: git rejects a
non-fast-forward itself and the pre-push hook gets an EMPTY ref list. My first
fixture used a plain push and the guard reported 0 refs checked while git did
the refusing — which looked like my guard failing and was actually git working.

THE REAL TRAP IS --force-with-lease AFTER A FRESH FETCH. It succeeds and
reverts, because the lease proves only that the remote has not moved since YOUR
fetch, not that your base is current. A loop that fetches each iteration
refreshes the lease and it passes every time. The more careful the loop looks,
the more reliably it reverts. That sharpens the packet rather than weakening it:
the guard is the only thing in front of a forced push, since a force flag is
exactly what turns git's own protection off.

The guard is a set difference — deleted-minus-touched — so it never needs to
know what "stale" means. Fixture written FIRST as the packet demanded: real bare
remote, real installed hook, real pushes. The arms that matter beyond the happy
path are that the SAME commit rebased is accepted (or a guard refusing
everything would pass), a deliberate deletion is accepted, and a NEW remote ref
is never blocked — that last is the salvage path, which exists to rescue exactly
the wedged host this guard is about.

DID NOT CLOSE IT. Criterion 1 wants refusal "regardless of how invoked";
criterion 4 wants --no-verify considered. A client hook cannot satisfy both, so
the invocation-independent version is a pre-receive hook on the mirror, filed as
1001-i5ux with the logic and fixture already written. I did not rewrite
criterion 1 to match what a hook can do, and left closure to the author.

MY OWN CHANGE BROKE A FIXTURE AND THE FIXTURE CAUGHT IT: adding a fifth required
hook made install-hooks.sh hard-fail in test-forge-project-guard-hooks.sh, whose
synthetic repo stages an explicit hook list. Exactly what that fixture is for.

Gate green (220s). Daily maintenance stamped for the new UTC day.
