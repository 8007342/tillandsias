# `nix-toolbox.sh ensure` creates the toolbox and never installs nix into it

Filed 2026-08-30 by yoga while taking the 917-zkge instrumentation slice.

## What happened

`scripts/nix-toolbox.sh` opens with: "give this host a usable `nix` invocation,
creating and initializing a toolbox if that is what it takes." On yoga:

    scripts/nix-toolbox.sh capability
    -> none:nix-capability:no-nix-and-no-toolbox

    scripts/nix-toolbox.sh ensure
    -> detail:nix-toolbox:chroot:nix: command not found on PATH
       blocked:nix-toolbox:no-nix-and-no-toolbox

The `tillandsias-nix` toolbox already existed and had been up for 21 hours. The
only thing missing was nix INSIDE it:

    toolbox run -c tillandsias-nix sudo dnf install -y nix
    -> nix (Nix) 2.34.8

    scripts/nix-toolbox.sh capability
    -> ok:nix-capability:toolbox

One command. The host went from "not nix-capable" to nix-capable at the toolbox
rung, with the shared `$HOME` chroot store answering `store info` normally.

## Why the verdict was wrong rather than merely unhelpful

`ensure_toolbox()` returns 0 when the toolbox EXISTS. `resolve_rung()` then asks
`toolbox_nix_works()`, which fails because nix was never installed, and the rung
reports `no-nix-and-no-toolbox` — a verdict naming an absent toolbox that is in
fact present and running.

The install step is not missing from the design; it is in a source COMMENT:
"After `dnf install nix` in the tillandsias-nix toolbox, `command -v nix`
succeeds..." — written as an observation about a past manual run, not performed
by the script. So `ensure` initializes everything about the toolbox except the
thing the toolbox exists for.

## Why it matters beyond one host

This is the difference between "this host cannot participate" and "this host is
one command from participating", and the verdict reports the first. 917-zkge's
context records that "yoga, pirria, calmecacpilli, macbook and yolanda each
independently confirmed no nix at all" — a fleet-wide capability conclusion that
may rest on the same reading. At least one of those hosts (this one) was
nix-capable the whole time and answered otherwise.

It is also the evening's recurring shape once more: a check that reports an
ABSENCE where the truth is an OMISSION, with the two indistinguishable from
outside.

## Suggested direction

- `ensure` should install nix into a toolbox it is willing to create, or say
  plainly that it will not and name the command. A function documented as
  initializing a toolbox should not stop one step short of the initialization.
- The `no-nix-and-no-toolbox` verdict must distinguish "no toolbox" from
  "toolbox present, nix not installed". They have different remedies and only
  one of them is a real incapability.
- Re-check the other hosts' `no nix at all` conclusions against this: if any of
  them has a `tillandsias-nix` toolbox, the conclusion needs re-taking.

## What is NOT claimed

Whether the toolbox rung is fast enough to be worth using for real builds is
unmeasured here — only that it exists and works. And nix landing in the toolbox
does not make the host a cache CONSUMER: the with/without wall-clock comparison
917-zkge asks for is still open on yoga (see that packet's events).

Related: 917-zkge (instrumentation slice), 736-mcy3, 795-h8er, 934-7jd4 (the
host-escape shim in the BUILDER toolbox, which forwards `nix` to a host binary
that does not exist here — a second reason a reader concludes "no nix").
