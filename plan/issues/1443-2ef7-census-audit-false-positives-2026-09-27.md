# 1443-2ef7 census audit: all 10 hits are false positives

Filed by forge-tillandsias, 2026-09-27, at macuahuitl-fedora's request to turn
the 1443-2ef7 census's 10 misclassified specs into a fix list for the
integration-layer classifier (1443-b85g). Manual review of each hit's actual
`critical_path[].command` text found **zero genuine layer misclassifications**
— every hit is the census's own matcher firing on a substring that happens to
appear in a source PATH or a grep PATTERN, not on an actual forge/VM/guest
launch. No fix-list rows are filed here; filing "current vs correct
size/phase" against a correctly-classified spec would hand 1443-b85g false
data.

## What the census actually matched

`scripts/census-litmus-layer-classification.sh` flags a `size: instant` spec
whose command lines contain `run-forge-standalone.sh`, `tillandsias --init`,
`podman run`, or `build.sh --ci-full`, and a `phase: pre-build` spec whose
command lines contain `guest-agent`, `vm-layer`, `launch_vm`, or
`run-forge-standalone.sh`. It matches these as plain substrings of the
command TEXT — it cannot tell "this command RUNS X" from "this command's
argument NAMES X" (a grep target, a file path, a quoted string in a doc).

| Spec | Declared | Census flagged | What the command actually does |
|---|---|---|---|
| `litmus-forge-standalone-runtime-shape` | size:instant, phase:pre-build | size, phase | `grep -F 'exec podman run' run-forge-standalone.sh` — greps the SCRIPT'S TEXT for the string `podman run`; never execs podman. |
| `litmus-forge-standalone-traceability` | size:instant, phase:pre-build | size, phase | `bash -n build-forge.sh run-forge-standalone.sh` (syntax-check only) and `grep -F '@trace ...' ...run-forge-standalone.sh` — the filename is a grep argument, never run. |
| `litmus-guest-vsock-loopback-ordered-before-readiness-probe` | phase:pre-build | phase | `sed`/`grep` over `crates/tillandsias-vm-layer/src/readiness.rs` — `vm-layer` matched because it's a substring of the CRATE PATH, not a VM launch. |
| `litmus-macos-tray-architectural-invariants` | phase:pre-build | phase | `grep`/`awk` over `crates/tillandsias-vm-layer/src/vz.rs` — same crate-path substring match. |
| `litmus-post-merge-litmus-pass-shape` | size:instant | size | `grep -q 'build.sh --ci-full' skills/coordinate-multihost-work/SKILL.md` — greps a SKILL doc's prose for that string; never invokes `build.sh`. |
| `litmus-vm-launch-graceful-failure-shape` | phase:pre-build | phase | `grep` over `crates/tillandsias-vm-layer/src/wsl.rs` and `.../spec.md` — crate-path substring match. |
| `litmus-vsock-exec-heartbeat` | phase:pre-build | phase | `cargo test -p tillandsias-vm-layer 'vsock_exec::tests'` — a cargo unit-test invocation; `vm-layer` matched the CRATE NAME argument to `-p`, not a VM. |
| `litmus-wsl-platform-preflight-shape` | phase:pre-build | phase | `grep`/`awk` over `crates/tillandsias-vm-layer/src/wsl.rs` — crate-path substring match. |

Eight distinct specs, ten flags (two carry both a size and a phase flag).
None launches `run-forge-standalone.sh`, `podman run`, a guest, or a VM; all
are static source/doc greps or `cargo test` unit-test invocations. Their
declared `size: instant` / `phase: pre-build` is correct as written.

## Root cause in the census, and the fix it needs before reuse

`crates/tillandsias-vm-layer` and `crates/tillandsias-windows-tray` are the
two crates most litmus specs legitimately grep for source invariants — their
PATHS contain `vm-layer` as a plain substring, and `run-forge-standalone.sh`
is a common grep TARGET across the forge-standalone specs. A token table doing
plain substring matching on full command lines will keep re-finding this same
false-positive shape on any future run.

Before this census is trustworthy input to 1443-b85g, `match_token` needs to
distinguish "the token is the invoked command/argument" from "the token
appears inside a quoted grep pattern or a bare filename argument to
grep/sed/awk/cargo test path filters." A cheap tightening: skip matches where
the token is immediately preceded by a quote character (`'`/`"`) opened by
`grep -F`/`grep -q`-style invocations, and skip matches inside a
`crates/<name>/` path segment specifically for `vm-layer` (the one token that
is also a crate directory name). That would have suppressed all ten hits
above without new arms; a harder case (a real forge/VM launch reached only via
an indirect wrapper script) is out of scope for a grep census and stays a
known limitation.

## Disposition

- No plan rows filed against 1443-b85g: there is nothing to reclassify.
- 1443-2ef7 itself is unaffected — its verifiable_closure only required the
  self-test and the live summary line, both of which are correct as landed.
- Follow-up (not filed as a packet here — flagging for triage): harden
  `census-litmus-layer-classification.sh`'s matcher per above before its
  output is used as anyone's fix list.
