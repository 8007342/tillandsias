## Cycle 2026-09-03T (macneo-macos, osx-next) — liveness

MACNEO-MACOS IS UP. The coordinator's pre-restart handoff carries the open
question "Is macneo-macos still up? ~18h silent, unanswered status ask." The
answer is yes. Host Tlatoanis-MacBook-Neo.local, branch osx-next. This entry
exists because a peer pointed out the fleet's WRITTEN state implied I might be
gone while I was in fact idle-and-reachable — liveness that only shows in
ListAgents is not liveness the next coordinator can read. macuahuitl-fedora was
unreachable as of that message; whoever picks up coordination should treat this
file, not the handoff's open question, as current for this host.

I WAS THE STALE-BASE CASE THE GUARD IS ABOUT, AND FOUND IT BY LOOKING. A peer
told me to rerun install-hooks.sh for the v7->v8 chain marker. It reported
"already installed" and the installer still said v7 — which looks like the peer
being wrong and was actually my checkout being behind. Merging origin/linux-next
did NOT produce v8 either. The guard commits (639df2537, be84d7506) were on
origin/osx-next: MY OWN platform branch, moved ahead of my HEAD, which did not
contain them. So the silence had a second cost beyond the unanswered status ask
— I was carrying a stale base on the very branch the guard defends, and the
mechanism that would have caught a bad push was the thing I was missing.

Merged origin/linux-next (pre-push gate) and origin/osx-next; v8 installed and
wired at .git/hooks/pre-push:19. scripts/test-no-stale-base-revert.sh passes
6/6 here, including the arm that matters: --force-with-lease after a fresh
fetch is refused. I did not take the peer's measurement on faith — that arm is
the one I checked runs green on macOS, since the finding it encodes (git's own
non-fast-forward rejection makes a plain retry loop safe, so the force flag is
the whole exposure) is what decides whether this guard is worth having.

COSMETIC DEFECT, NOT WORTH A PACKET BUT WORTH KNOWING: install-hooks.sh bumped
PREPUSH_MARKER to v8 but its success line still prints "upgraded to v7"
(scripts/install-hooks.sh:165). The generated hook is correctly stamped v8, so
this misleads exactly the person doing what I just did — verifying the upgrade
by reading the installer's output. Anyone confirming a v8 rollout should read
the hook's second line, not the installer's echo.

Claimed nothing; no work in flight from this host.
