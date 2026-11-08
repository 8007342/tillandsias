# forge-lua-helpers Specification

## Purpose

Define the first `lib-*.sh` migration from shell to the Rust-hosted Lua runner:
a helper mode that is not a decider, five hot image helpers that keep their
machine-line contracts, and the packaging and ratchet that keep the migration
from silently regressing.

## ADDED Requirements

### Requirement: Helper runner mode
<!-- req-id: 023b73dc -->

`tillandsias-plan script run --helper <file.lua>` MUST run a Lua helper without
requiring a verdict and MUST NOT add anything to stdout. `verdict.*` MUST be
unavailable in helper mode; a helper that calls it MUST be refused as
`refused:helper-called-verdict:<name>`. A normal return MUST exit 0; a Lua
error MUST exit 1 with a diagnostic on stderr. The same `Cacheable`/`Observing`
split, `@env`, `@read-env`, fs roots and `proc.*` (no pipes) MUST apply.

#### Scenario: A helper returns its own stdout
- **WHEN** a helper prints `base_head=abc` and returns
- **THEN** stdout MUST be exactly `base_head=abc` with no verdict line
- **AND** the exit status MUST be 0

#### Scenario: A helper cannot masquerade as a decider
- **WHEN** a helper calls `verdict.ok("x")`
- **THEN** the runner MUST print `refused:helper-called-verdict:<name>` and exit 1
- **AND** the script MUST NOT be usable as a gate step

#### Scenario: A helper error is not a green
- **WHEN** a helper raises a Lua error
- **THEN** the runner MUST exit 1 and print a diagnostic on stderr
- **AND** stdout MUST NOT contain a verdict-shaped line

### Requirement: Ported helpers preserve their machine-line contracts
<!-- req-id: 00e6e290 -->

Each ported helper MUST keep its public shell function name, its machine-line
grammar and every named fallback. A multi-value helper MUST print one value per
line in its documented order, using `-` or `unknown` for an absent value and
never an empty line.

#### Scenario: inference state keeps its closed vocabulary
- **WHEN** `tillandsias_inference_state` runs against an endpoint that is
  unreachable, times out, answers non-2xx, serves no models, or has no curl
- **THEN** the reason MUST be one of `endpoint-unreachable`,
  `endpoint-timeout`, `endpoint-http-error`, `no-models`,
  `probe-tool-missing`, `probe-error-<n>`
- **AND** the `inference_state=` machine line MUST be unchanged
- **AND** the `endpoint-unreachable` detail MUST still name
  `reason=engine-` as the place to look

#### Scenario: expert probe keeps its substitutes and vocabulary
- **WHEN** the plan binary is absent, predates `experts-probe`, or emits no
  parseable line
- **THEN** the advice MUST be `probe-binary-missing`,
  `probe-subcommand-missing`, or `probe-no-verdict` respectively
- **AND** each tier MUST be one of
  `ready|unset|unreachable|scheme-unsupported|malformed|unknown`

#### Scenario: ledger freshness keeps unknown and the zero floor
- **WHEN** the checkout has no HEAD, no origin heads, or an older origin head
- **THEN** `TILLANDSIAS_BASE_HEAD`/`TILLANDSIAS_LEDGER_NEWEST` MUST be
  `unknown` and `TILLANDSIAS_LEDGER_LAG_H` MUST be `0`
- **AND** `origin` and `origin/HEAD` MUST NOT be reported as the newest branch

#### Scenario: build id keeps unknown
- **WHEN** the file is unreadable
- **THEN** `tillandsias_mcp_build_id` MUST print `unknown`
- **AND** it MUST NOT print an empty string or a fabricated id

#### Scenario: usage log keeps the base four keys and stays silent
- **WHEN** `mcp_log_usage` records a tool call
- **THEN** the JSONL line MUST contain `ts`, `server`, `tool`, `outcome`
- **AND** `latency_ms`/`confidence`/`citations` MUST be present only when supplied
- **AND** the function MUST write nothing to stdout

### Requirement: The image ships every sourced lib and named Lua module
<!-- req-id: 00bc0b97 -->

`images/default/Containerfile` MUST copy every `lib-*.sh` sourced by
`lib-common.sh` or the two MCP wrappers, and every `lua/*.lua` module those
wrappers name, into `/usr/local/lib/tillandsias/`. A guard MUST compare the
source references with the Containerfile `COPY` lines and refuse, naming the
missing file, when one is absent.

#### Scenario: A sourced lib missing from the image is refused
- **WHEN** a `lib-*.sh` is sourced by `lib-common.sh` or an MCP wrapper and no
  `COPY` line names it
- **THEN** the guard MUST exit non-zero and name the lib
- **AND** the guard MUST be red on today's tree for
  `lib-ledger-freshness.sh`, `lib-experts-probe.sh` and `lib-mcp-build-id.sh`

#### Scenario: A named Lua module missing from the image is refused
- **WHEN** a wrapper names `lua/<name>.lua` and the Containerfile does not copy
  `lua/`
- **THEN** the guard MUST exit non-zero and name the module

### Requirement: The shell-to-Lua migration is monotone
<!-- req-id: 046144a7 -->

The shell-outs in `images/default/lib-*.sh` MUST be counted as a counter of
the shell-to-lua carried-obligation backlog judged by
`scripts/lua/check-carried-obligations.lua`, not by a separate gate step. A
count above its floor MUST be refused, the floor MAY only decrease, and the
check MUST name each migrated helper. A change that cannot pay MUST carry a
`Carried-Waiver: shell-to-lua` trailer in the accepted grammar.

#### Scenario: A new shell-out is refused
- **WHEN** a helper adds a new external command or a new `.sh` helper outside
  the baseline
- **THEN** the guard MUST exit non-zero and name the file
- **AND** removing a migrated shell-out MUST be accepted and MUST lower the
  baseline

### Requirement: Helpers are deterministic and MCP-stdout safe
<!-- req-id: 074a82eb -->

Every ported helper MUST declare `-- @class observing` (it takes runtime
arguments or reads live state), MUST emit values in a fixed order, and MUST NOT
write to stdout when it is a side-effect helper sourced by an MCP server.

#### Scenario: Model names are byte-sorted
- **WHEN** the inference endpoint lists models in a different order on two runs
- **THEN** the `inference_warm` value MUST be byte-identical on both runs

#### Scenario: An MCP server's stdout is not corrupted
- **WHEN** a helper is invoked from `forge-plan.sh` or `project-info.sh`
- **THEN** the JSON-RPC stdout MUST receive no helper output
- **AND** a fixture MUST assert the wrapper writes only its documented lines

### Requirement: Helper children get the base environment only

A helper child MUST start from the same base environment as a decider child
(cleared, fixed passthrough, `TILLANDSIAS_*` minus secret-named variables).
`--helper` MUST NOT add caller-environment inheritance, and no helper MUST pass
a credential or a secret-named variable to a child (2029-39bt, 1551-nyzb).

#### Scenario: A helper child does not inherit the caller's environment
- **WHEN** the caller sets `HTTPS_PROXY` and `TILLANDSIAS_X_SECRET` and runs a
  helper that spawns `printenv`
- **THEN** neither variable MUST appear in the child's output

### Requirement: What stays shell is named, not implied
<!-- req-id: 16e05218 -->

The change MUST list the shell files it does not port and the reason for each:
`lib-sigpipe-verdict.sh` (measures the OS pipe race), `lib-env-forward.sh`
(emits shell source), `lib-ca-path.sh` and `lib-cargo-sites.sh` (host-side,
before a host binary exists), `scripts/common.sh` (podman resolution at the top
of `build.sh`), `entrypoint*.sh`, `lib-localized-errors.sh`, and
`scripts/build-forge-plan-bin.sh` (builds the binary).

#### Scenario: A port would change what is measured
- **WHEN** someone proposes porting `lib-sigpipe-verdict.sh`
- **THEN** the spec MUST refuse it by name, because `proc.chain` would measure
  the runtime rather than the shell site's real pipe race
