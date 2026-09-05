---
tags: [toolbox, portability, scripts, sweeps, fail-loud]
languages: [bash]
since: 2026-08-26
last_verified: 2026-08-26
sources:
  - plan/archive/packets-2026-08.yaml order:799-tb7q
  - plan/index.yaml order:914-ahsy
  - scripts/lib/tool-dispatch.sh
  - scripts/test-tool-dispatch-lib.sh
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
---

# Host-tool dispatch sweeps: four hazards, and which ones a fixture catches

Converting scripts from `some-tool …` to a host-preferred / toolbox-fallback
dispatch looks mechanical. It is not. Four hazard classes each cost a cycle to
find during the 799-tb7q sweep (23 callers converted across five slices), and
**none of them is visible from the framing "add the dispatch line"**.

The table says which the suite catches for you and which you must watch for by
hand. **Provenance: every number below was measured on lenovinha (Fedora
Silverblue) 2026-08-26 unless stated.**

| # | Hazard | Guarded by a fixture? |
|---|---|---|
| 1 | Exclusion classes — some scripts must NEVER convert | **Yes** — `litmus:tool-dispatch-lib` arms 4b, 5 |
| 2 | Heredoc scope — `$VAR` inside a generated script | **Yes** — arm 4c (needle passed as an awk variable) |
| 3 | Write-path namespace — tools that write files | **Partly** — arm 4e checks the current callers write under `/tmp`; it cannot check a path you add later |
| 4 | Depth-sensitive source path | **Yes** — arm 4f, with a mutation control |

## 0. First: does the toolbox actually have the tool?

The pattern is only valid for tools the toolbox **has**. Writing the dispatch
line for a tool it lacks makes things *worse* than the host failure it replaced:
the fallback arm runs and reports `command not found` from inside a container,
which is a more confusing failure than the one you removed.

```bash
toolbox run --container tillandsias-builder <tool> --version
```

That check is why 799-tb7q had to grow the init set (jq, yq, ripgrep, openssl)
*before* any sweep could start.

## 1. Exclusion classes — never convert these

Each one reads as an oversight to whoever finishes the sweep, so each is guarded
**and** carries its reason at the call site.

- **Curl-piped installers.** `install-macos.sh` is fetched from a release URL and
  piped straight into `bash`. There is no checkout and no sibling file to source.
  Converting it breaks the installer for every user.
- **Bootstrap wrappers.** `with-tillandsias-builder.sh` *creates* the toolbox. It
  cannot use the toolbox to decide how to make the toolbox.
- **Shipped diagnostics.** `tray-diagnose.sh`, `diagnose-macos-provision.sh` run
  on end-user machines. A diagnostic that fails to source its helper fails at the
  moment its output is needed, **with a failure that looks like the thing it was
  sent to investigate**. Two justified copies beat one fragile abstraction.

## 2. Heredoc scope

**`$JQ` must never appear inside a heredoc that generates another script.** The
variable belongs to the generating scope, not the generated one. This broke two
fixtures in *opposite* ways:

- quoted heredoc → `$JQ` is unset in the stub, so the pipeline runs with an
  **empty command**;
- unquoted heredoc → `$JQ` expands at generation time and bakes
  `toolbox run --container tillandsias-builder jq` into the stub, breaking on
  exactly the jq-less host the sweep exists to serve.

A synthetic test double is not a dev-host script. Leave it calling the bare tool.

## 3. Write-path namespace

Applies to tools that **write files**, not to pure filters.

`jq` reads stdin and writes stdout, so a toolbox fallback is namespace-agnostic.
`openssl req` generates a cert *into a directory*: the fallback only works where
the container shares that path, and otherwise the file lands where the caller
cannot find it — **a silent break, not an error**.

Measured: `/tmp` is shared bidirectionally with the toolbox. Anything else must
be re-checked before converting.

## 4. Depth-sensitive source path — the one that *looks done*

```bash
# WRONG for any caller not sitting directly in scripts/
. "$(dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh" 2>/dev/null || true
```

From `scripts/foo.sh` that resolves correctly. From
`scripts/refusal-calibration/foo.sh` it points at a lib that does not exist, the
`|| true` swallows the miss, and the tool variable falls back to the bare name.
**The conversion passes review, passes the suite, and changes nothing.**

Walk up instead:

```bash
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
```

## The cost that decides *whether* to convert

A single `toolbox run … jq` is **~264 ms**; host `jq` is **~1 ms**.

- **Flat caller, 7–9 sites** → ~2 s on a jq-less host. Fine.
- **Caller invoking the tool inside a LOOP** → one round trip per iteration. A
  script iterating ledger rows goes from milliseconds to minutes, on exactly the
  host the dispatch exists to serve.

Loop callers need **restructuring to a single pass**, which is different work
from a sweep. That is why the 17 remaining callers became their own row
(914-ahsy) rather than more of 799-tb7q.

## Two process rules, each paid for twice

- **Run the converted scripts. Do not trust `bash -n`.** Syntax was valid in both
  cases where a conversion broke behaviour.
- **Stash-compare before attributing any failure.** Across three cycles this gave
  three different answers: one script *looked* broken and was not
  (`generate-dashboard.sh` — a pre-existing usage contract), two looked fine and
  were broken (the heredoc pair), and one *looked* hung and was not
  (`check-cheatsheet-refs.sh` — a cold-cache artifact). "The script I just
  touched now fails" is the shape that gets a good change reverted.
