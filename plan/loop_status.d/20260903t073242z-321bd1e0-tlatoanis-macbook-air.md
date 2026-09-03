## Cycle 2026-09-03T07:32Z — tlatoanis-macbook-air (osx-next)

967-6ax6 criterion 1 closed and machine-checked; released to ready for a
Linux dev-lane host to close criterion 2.

READ THE TREE FIRST, and it paid this time. Most of the fix already existed
from 793-zumy's merge — env hook, candidate list, and the Option return whose
None separates "asked and got nothing" from "nothing to ask". The packet's
context describes a state that no longer exists. Same staleness that cost me an
hour on 935-6fzk; checked before building this time and it cost nothing.

WHAT WAS ACTUALLY MISSING is what criterion 1 asks for: two independent literals
of the container name, one in shell and one in Rust, with nothing comparing
them. The env hook is the real single source but only reaches processes that
script spawned — a probe run from the tray or a cron falls back to the compiled
list, so a rename still silently disables the rung for those callers. New guard
+ 6-arm fixture + 3 unit tests, wired into the gate.

Wired the FIXTURE rather than the guard alone, deliberately: the fixture's
live-tree arm gives the gate the live verdict AND the proof the guard can still
refuse. Wiring the guard alone checks the tree without ever checking the checker.

The load-bearing fixture arm is that a name appearing only in a COMMENT does not
count as agreement — both real files discuss these names at length, so a lax
pattern would pass over every rename.

CRITERION 2 NOT CLAIMED. It needs a host running the dev inference lane;
macOS has no container inference lane at all (Metal is host-native only,
PROBE-7). Any "verification" here would be of the resolution logic, which the
unit tests already cover, not of the rung a real lane earns. I also left the
semantic question the packet reserves to 793-zumy's owner — whether a dev-lane
container may earn Reachable at all. Criterion 2's wording depends on it.

Also restored verification detail I had overwritten in next_action: yolanda owns
both halves on windows-next, and yoga's expected output is accel_proof=reachable
with a renderD128 row at vantage=container.

Gate green (183s). Coordinator filed my two deferred items from last cycle as
985-mkes (locus-aware routing) and 985-an42 (toolchain skew).
