## Cycle 2026-08-17T07:24Z (linux-immutable yoga — cycle 13, hourly fleet loop)

The operator interrupted mid-cycle with a critique that redirected the work:
"podman not available, on Fedora Silverblue? ... look at the fixes on top of
fixes you've been doing lately, and justify them. Chances are you need to
remove things instead, and let frameworks do their thing instead of fixing the
edge case that should have been a config." Both halves landed.

### 793-a62g — the mechanism it asked to be proven or refuted

REFUTED as podman-sqlite lock contention. `c249dde2e` (macuahuitl) had already
found one half: parallel cargo tests racing process-global TILLANDSIAS_PODMAN_BIN,
which made tests invoke REAL podman and manufactured the load. This host found
the other half, which that commit explicitly left open.

`scripts/common.sh` chose its podman storage backend by racing
`timeout 5 podman info`. Lose that race and the lane silently switched to a
generated wrapper with a private graphroot and `driver = "vfs"`. A five-second
threshold is not a fact about a host, it is a fact about how busy the host was
at that instant — so `--ci-full` picked its storage backend by coin flip.

Measured here: podman answers `info` in 0.07s idle, 0.26s loaded, native
overlay, shipped in the OS image. Reproduced the switch deterministically with
a healthy podman that only sleeps 6s on `info`.

Why losing the race is expensive AND silent: vfs COPIES layers instead of
stacking them (the 30s budget timeouts), and the private graphroot holds none
of the host's tillandsias-* images (the missing-image failures). The wrapper is
written to ONE fixed path shared by every parallel lane, so lanes truncate it
while siblings exec it — measured 50/400 = 12.5% ETXTBSY failures under
concurrent rebuild. That is the false message: `require_podman` only ran
`$PODMAN --version`, so "Text file busy" was indistinguishable from absence,
and the gate said "podman is not available on PATH" on Silverblue, where a
reader can see the claim is false.

The wrapper is now CONFIGURATION, never inference. This DELETES both escape
hatches previously maintained around it: 022226ce3's bypass (added because the
wrapper split the image inventory in two) and c8ee28dee's macOS special case
(added because the flags it generates do not exist there). Neither is needed
once the default is simply "use podman as the OS provides it".

### The audit of my own recent work — two guards deleted, not repaired

`check-tracked-config-host-paths.sh` (789-nc2s, 2 cycles old) reported
`ok:tracked-config-host-paths:1 scanned` while `/c/Users/bullo/...` sat in
`.claude/settings.local.json`, the file that motivated it, because its severity
split refused only the env block. I wrote that split and recorded at the time
that "the file did not need untracking after all". It did. A guard narrowed
until the offending tree passes is a green light with a rationale attached.
Shared keys moved to a tracked `.claude/settings.json`; untracking filed as
795-x7ux behind the per-host-kind gate 793-rb9u established, because
`git rm --cached` deletes the working copy on every host that pulls and three
unattended hosts losing their allowlist mid-night is a prompt nobody answers.

`check-guard-asset-skew.sh` (783-6rik, 1 cycle old) said earlier and vaguer
what `check-credential-channel.sh` already says at the point of failure. Three
layers in one night, none of which let a lane drain.

NOT taken from the audit: softening `blocked:upstream-auth-unpublished`. That
block is what stops a forge draining into a mirror that cannot push upstream —
the 756-2jnj two-commit loss. Verified before rejecting.

### Host state — operator action, not mine

This host runs Silverblue deployment 44.20260815.0 while 44.20260816.0 (13
upgraded packages) is staged and unbooted; uptime 1d15h; installed release
v0.4.260815.1. The operator's "maybe your system just needs a restart after a
system upgrade" is literally true here. Not rebooted from an unattended cycle:
it would end this session, the hourly loop, and any running forge.

Filed 795-e5c7 — the cause under three CA permission fixes is
`CA_DIR = "/tmp/tillandsias-ca"`, with the key chmod'd after openssl writes it
at ambient umask. `XDG_RUNTIME_DIR` or `DirBuilder::mode(0o700)` ends the
class, and `clamp-ca-material.sh` needs a retirement condition rather than
running on every host every cycle forever.
