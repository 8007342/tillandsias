# The forge image omits three libs that `lib-common.sh` and both MCP servers source

Filed 2026-11-08 from the live forge on `macuahuitl` (order `2047-ci2k`).

## What is wrong

`images/default/Containerfile` copies each shared library into
`/usr/local/lib/tillandsias/` by name. Three libraries that are sourced in the
image are not copied:

| library | sourced by | image path it looks for |
|---|---|---|
| `lib-ledger-freshness.sh` | `lib-common.sh::inject_startup_context` | `/usr/local/lib/tillandsias/lib-ledger-freshness.sh` |
| `lib-experts-probe.sh` | `config-overlay/mcp/forge-plan.sh`, `config-overlay/mcp/project-info.sh` | `/usr/local/lib/tillandsias/lib-experts-probe.sh` |
| `lib-mcp-build-id.sh` | `config-overlay/mcp/forge-plan.sh`, `config-overlay/mcp/project-info.sh` | `/usr/local/lib/tillandsias/lib-mcp-build-id.sh` |

The Containerfile copies `lib-common.sh`, `codex-safe-state.sh`,
`lib-provider-limit.sh`, `lib-localized-errors.sh`, `lib-inference-state.sh`,
`lib-push-capability.sh`, `lib-lane.sh`, `lib-flaky-installs.sh`,
`lib-expert-capability.sh` and `lib-project-engine-capability.sh`, but not the
three above.

Measured in the live forge (2026-11-08):

```
$ ls /usr/local/lib/tillandsias/
bash-policy-hook  lib-common.sh  lib-expert-capability.sh  lib-flaky-installs.sh
lib-inference-state.sh  lib-lane.sh  lib-localized-errors.sh
lib-project-engine-capability.sh  lib-provider-limit.sh  lib-push-capability.sh
policy-bin/
$ for f in lib-experts-probe.sh lib-mcp-build-id.sh lib-ledger-freshness.sh; do
    [ -e /usr/local/lib/tillandsias/$f ] && echo "present $f" || echo "MISSING $f"; done
MISSING lib-experts-probe.sh
MISSING lib-mcp-build-id.sh
MISSING lib-ledger-freshness.sh
```

## What it costs

- `lib-common.sh` guards the source with `[ -r ... ]`, so the startup context
  silently loses its ledger-freshness line. The `835-h2wq` mechanism exists
  precisely to make a stale base visible; in the image it is absent and the
  absence reads as current.
- `forge-plan.sh` falls back to
  `FP_EXPERTS_ADVICE="TIER PROBE: unavailable (lib-experts-probe.sh not found)
  — tier liveness is UNKNOWN, not absent"` and `project-info.sh` loses the same
  tier probe.
- Both MCP servers compute the build id through `tillandsias_mcp_build_id`,
  which cannot find the lib and returns `unknown`. `check-mcp-live-build.sh`
  treats `unknown` as "could not tell", so the live-build check can never prove
  the running server is current.

Each fallback is deliberately fail-loud in prose, but all three are silent at
the process level: no gate is red, and the degraded state is only visible to a
reader who notices the substituted sentence.

## How it happened

The three libraries were added by commits that did not touch the Containerfile:

- `a50096a8c` (`823-u3k9`, `889-ewvt`) added `lib-mcp-build-id.sh`;
- `28ef92ce6` (`718-ja7g`) added `lib-experts-probe.sh`;
- the ledger-freshness library predates those; `93ee6e041` only fixed its
  dialect.

The source-tree path `"${BASH_SOURCE[0]%/*}/../../lib-*.sh"` in the MCP
wrappers resolves correctly in a checkout, which is where their tests run, so
the image path was never exercised.

## Exit criteria

A guard (`scripts/lua/check-image-ships-sourced-libs.lua` or equivalent)
enumerates every `lib-*.sh` sourced by `images/default/lib-common.sh` and the
two MCP wrappers, and every `COPY lib-*.sh` line in
`images/default/Containerfile`; it fails naming any sourced lib the image does
not copy. Pre-fix result: FAILS naming the three above. Then add the three
`COPY` lines and the guard goes green. The guard must also run when the image
changes, so the next library cannot repeat this.

## Not claimed

This packet does not rebuild or boot the image; it proves the source-level
omission and the guard. The image rebuild is the normal release path.
