# macOS union-red: the 956-llei/958-b36m guard family assumed a GNU/Linux host

Date: 2026-09-02
Host: tlatoanis-macbook-air (macos, osx-next)
Class: enhancement
Related: 731-eupn (union shape), 851-gpb5 (macOS host dialect), 956-llei, 958-b36m

## Shape

`osx-next` was 345 commits behind `linux-next`. Both branches were green alone;
the merge was red — the 731-eupn shape, five distinct times. Every failure was a
GNU/Linux assumption in code that had never executed on a Mac, and none of them
were merge conflicts: git merged cleanly and the union still did not build.

## The five

1. `crates/tillandsias-headless/src/accel_probe.rs` — `enumerate_npus` is called
   only from a `#[cfg(target_os = "linux")]` arm but was itself ungated, so
   `-D dead-code` failed the workspace clippy on macOS and Windows. Every other
   platform-only helper in that file carries the attribute; this one did not.

2. `scripts/check-litmus-bindings.sh` — the newly-bound-name extraction used
   `\+` in a **BRE**. BSD sed has no `\+` and matches a literal plus, so
   `added_names` was empty, `checked_new=0`, and the gate reported `ok:` over a
   newly-bound unrunnable file. **A gate that silently stops gating on one
   platform is worse than one that fails there** — this one was green while
   enforcing nothing.

3. `scripts/run-litmus-test.sh` — `. .../timing-log.sh 2>/dev/null || true`.
   bash 3.2 (the system shell on every macOS host) ABORTS a non-interactive
   shell when `.` cannot find its file, and `|| true` does not save it; bash 4.4+
   does not, which is why it survived on Linux. A "best-effort side-channel that
   must never change the runner's exit" was killing the runner outright.
   Reproduce: `bash -c 'set -eo pipefail; . /nonexistent 2>/dev/null || true; echo X'`
   prints nothing and exits 1 under 3.2.57.

4/5. `scripts/test-litmus-kill-adjudicator.sh`,
   `scripts/test-litmus-retired-phase-skip.sh`,
   `scripts/test-litmus-stdin-does-not-eat-the-spec-list.sh` — each builds a temp
   PROJECT_ROOT with a symlinked `scripts/` and an empty `target/`, so the
   runner's own metadata reads (746-htj9) resolve no `tillandsias-plan` and fall
   back to yq — which no macOS host has. Every arm failed as `No litmus tests
   bound to spec`, i.e. for a reason unrelated to what each fixture pins.
   Also `scripts/test-bound-litmus-is-runnable.sh` used bare `sed -i` and a `\n`
   in an `s///` replacement, both GNU-only.

## Fixes landed this cycle

All five, in the merge commit's follow-up. The fixtures now name the reader
through the shared probe (`plan-binary-probe.sh`, per the 721-nyev guard) and
absolutize its relative path; `check-litmus-bindings.sh` repeats the character
class instead of `\+`; `run-litmus-test.sh` tests `-f` before sourcing.

## The finding worth keeping

Four of these are the same defect class — **a Linux-authored guard that reads as
platform-neutral** — and three of them were guards, not product code. The
`--check` gate is the only trunk protection (no push CI), so a guard that
degrades to a no-op on a platform removes that protection exactly where the
platform is least exercised. `scripts/check-bash-dialect.sh` (761-g36m) already
scans for GNU-only idioms and passed over items 2 and 3: `\+` inside a BRE and
an unguarded `.` are not in its vocabulary. **Extending that check to those two
idioms is the reduction** — it is the one instrument that could have caught them
on the authoring host, before a Mac was 345 commits behind.
