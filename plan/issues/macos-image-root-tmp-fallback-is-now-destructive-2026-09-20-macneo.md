# macOS `image_root()` falls back to `/tmp` when HOME is unset — and since 1286-4437 that path is DESTRUCTIVE

- host: macneo (`Tlatoanis-MacBook-Neo.local`), macOS 27.0, arm64, branch `osx-next`
- found: 2026-09-20, while implementing the macOS arm of `--reset-state`
- deferred by the coordinator to a row of its own, filed once that arm landed
  (`170da62bb`)
- status: **MEASURED on macneo, 2026-09-20.** The fallback is reachable in a
  real invocation and already produces a false verdict in `--diagnose`, before
  `--reset-state` is considered at all.

## The code

`image_root()` in `crates/tillandsias-macos-tray/src/diagnose.rs`
(and its byte-identical twin `default_image_root()` in `status_item.rs`, which is
what the LIVE TRAY reads — a fix to one alone leaves the other)

```rust
let home = std::env::var_os("HOME")
    .map(PathBuf::from)
    .unwrap_or_else(|| PathBuf::from("/tmp"));
home.join("Library/Application Support/tillandsias")
```

With HOME unset this resolves to `/tmp/Library/Application Support/tillandsias`.

## Why it is worth a row NOW and was not before

Until 1286-4437 every caller of `image_root()` was a READ: `--diagnose` reports
on paths, `reset_guest_main` wipes the guest it just located. A wrong root made
those report or wipe *nothing*, which is visible and annoying.

`--reset-state` makes this a **destructive** path. `run_reset_state` removes
children of `image_root()` and hands it to `VzRuntime::wipe_provisioned_artifacts`.
If HOME is unset the reset does not destroy the real state — it destroys nothing,
under `/tmp`, and then reprovisions there.

**The failure is not the deletion; it is the announcement.** The flag's contract
is that it announces what it will destroy before destroying it, and the operator
is shown a list built from the same wrong root. So the output is internally
consistent and externally false: it names `/tmp/Library/...`, does what it said,
exits 0, and the real state at `$HOME/Library/...` is untouched while the
operator has been told the local state was cleared. That is the family this
fleet keeps meeting — a verdict produced by something other than the thing whose
success it claims — and here it is attached to the repair tool for a broken
install.

## The measurement

`target/debug/tillandsias-tray --diagnose --json`, same binary, same host,
seconds apart. `--diagnose` is static/filesystem-only and destroys nothing.

| | `image_root` | `rootfs_present` |
|---|---|---|
| HOME set (control) | `/Users/tlatoani/Library/Application Support/tillandsias` | `true` |
| `env -u HOME` | `/tmp/Library/Application Support/tillandsias` | **`false`** |

So the fallback is not theoretical, and the harm starts EARLIER than this packet
first claimed. With HOME unset `--diagnose` reports `rootfs_present: false` and
`rootfs_bytes: null` while **1.2 GiB of guest state exists** at the real root on
this host. An operator running the supported diagnostic is told the guest is not
provisioned, and the obvious next action — reprovision — is the destructive one.
The control is what makes this a finding rather than an anecdote: the same
binary one second earlier reported `true` and the real path.

## What is NOT claimed

- That HOME is ever actually unset in a shipped path. **The fallback is now
  measured as reachable; the contexts that reach it are not.** The installer invokes the
  tray from a shell that has it; `open -a` inherits a normal session. **A
  LaunchDaemon, a `sudo` variant that scrubs the environment, or a CI runner are
  the candidate contexts, and none has been tested.** If it turns out HOME is
  unset in none of them, the right outcome is to say so on this row and close it
  — that is a measurement, not a reason to skip filing.
- That `/tmp` is the wrong fallback *in general*. For a read-only diagnostic it
  is a defensible "answer something rather than panic".

## Suggested direction, not a decision

A destructive path should not have a silent default. Either `image_root()`
returns `Result`/`Option` and `run_reset_state` REFUSES when HOME is unset — the
same shape as its existing pre-flight refusal when the reprovision binary is
missing, which already proves the caller can fail loudly with its state intact —
or the fallback stays for readers and the destructive caller derives its root
through a variant that cannot fall back. The first is preferred: `--reset-state`
already owns a refusal path and a shared constant for naming it
(`RESET_NO_REPROVISION_PATH`), and a second refusal reason costs one branch.

## First step — DONE, and what is next

The reachability measurement is above. What remains is which real contexts have
HOME unset (LaunchDaemon, environment-scrubbing `sudo`, CI), which is a survey,
not a design question.

## A note on the host this was found on

macneo currently has **no `Tillandsias.app` in `/Applications` and 1.2 GiB of VM
state under the real image root** — the same unexplained condition recorded on
this host earlier today. That is exactly the state `--reset-state`'s pre-flight
guard was written for: it refuses, naming the missing reprovision path, before
touching anything, because destroying the state there would leave nothing to
reprovision from.

**The guard was NOT fired live to prove this.** Doing so would have risked 1.2
GiB of unre-derivable vault state (803-49re) against a guard verified by reading
its own ordering — the refusal returns before `image_root()` is computed. That
is the same asymmetric-cost reasoning that spared `nvram.bin` on this order: a
test whose downside is an unre-derivable loss needs a better reason than
tidiness. Someone with a disposable host should fire it.
