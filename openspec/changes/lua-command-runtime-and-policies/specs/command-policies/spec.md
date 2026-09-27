## ADDED Requirements

Mirror of the draft durable spec `openspec/specs/command-policies/spec.md` (stamped req-ids live there; see tasks.md §5).

### Requirement: A built-in floor that a project seed can only tighten

The policy engine SHALL compile in a floor of rules: `no-shell-strings`,
`no-credential-mutation` (`gh auth login|refresh|logout|token`,
`git credential approve|reject`, `vault login`), and the consent classes
`substrate-reset` (`podman system reset`, `--reset-state`, `rm -rf` outside
the workspace, `git push --force*` to a protected ref). A per-project seed
`.tillandsias/command-policies.yaml` MAY add rules and MAY tighten a floor
rule (deny where the floor asks consent) but SHALL NOT loosen one; a seed
that tries is refused at load with `refused:policy-seed:cannot-loosen:<rule-id>`
and the engine answers from the floor alone. An unmatched request is
allowed in this phase (`ok:policy:allow:default`); flipping the default is
an operator decision recorded in the seed's `default:` field.

#### Scenario: A seed cannot re-enable a credential mutation

- **WHEN** a seed rule sets `decision: allow` for `gh auth refresh`
- **THEN** loading prints `refused:policy-seed:cannot-loosen:no-credential-mutation`
- **AND** `policy eval -- gh auth refresh` still answers deny

### Requirement: Evaluation is keyed by command family, host kind and regime

A request SHALL carry `argv`, `cwd`, the names (not values) of the
environment it adds, `host_kind` (`bare-metal | forge | ci`), `platform`,
`regime` (`interactive | gate | fixture | hook | relay`) and `caller`. Host
kind SHALL be derived from `TILLANDSIAS_HOST_KIND`, `/run/.containerenv` and
the `.forge-startup-context.md` marker together, and a disagreement SHALL be
reported in the decision. A rule MAY give a different decision per host
kind; the `substrate-reset` class SHALL be `deny` in a forge.

#### Scenario: The same argv, two hosts, two answers

- **WHEN** `podman system reset --force` is evaluated with host kind
  `bare-metal`
- **THEN** the answer is `consent:policy:substrate-reset`
- **WHEN** it is evaluated with host kind `forge`
- **THEN** the answer is `refused:policy:substrate-reset:not-grantable-in-forge`

### Requirement: Every refusal names why and what would clear it

A deny or consent answer SHALL print the verdict token on stdout
(`refused:policy:<rule-id>` or `consent:policy:<class>`), then a
`  why: <rule>` line and a `  remedy: <what clears it>` line on stderr. The
remedy SHALL name a concrete form (the argv spelling, the consent grant
verb, the operator-only login path), never only the rule.

#### Scenario: A denied credential mutation says how tokens arrive

- **WHEN** `gh auth login` is evaluated
- **THEN** the remedy names `tillandsias --github-login --with-token` on stdin
  as the only token path

### Requirement: Filesystem scope under the fixture regime

Under `regime: fixture` with `TILLANDSIAS_FIXTURE_SCOPE=<dir>`, `fs.write`,
`fs.mkdir` and a `proc.run` whose argv writes (`gate-stamp.sh write`,
`git update-ref`, `git push`, `rm` under the git dir) SHALL be refused when
the target is the real checkout's git dir or outside the scope, with
`refused:policy:fixture-writes-outside-scope`. The litmus runner SHALL export
the regime and scope for every step.

#### Scenario: A fixture cannot mint a gate stamp

- **WHEN** a fixture step runs `gate-stamp.sh write --scope full` against the
  real git dir
- **THEN** the step goes red naming `fixture-gate-stamp-write`
- **AND** the real git dir's stamp bytes are unchanged

### Requirement: Consent is per run, operator-minted, and never grantable in a forge

`tillandsias-plan policy consent grant <class> [--ttl]` SHALL write a token
bound to host, class and expiry (mode 0600). An evaluation of a consent
class SHALL succeed once against a valid token and consume it. An expired,
foreign-host or consumed token SHALL answer `refused:consent:invalid:<reason>`.
The grant verb SHALL refuse in a forge. `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1`
SHALL map to a `substrate-reset` consent only when the caller is one of the
two registered smoke skills, and the audit SHALL record `consent_source=env`.

#### Scenario: A token is consumed by its first use

- **WHEN** a token for `substrate-reset` exists and `podman system reset` is
  evaluated twice
- **THEN** the first answer is `ok:policy:substrate-reset:consented`
- **AND** the second is `consent:policy:substrate-reset`

### Requirement: Every decision is audited with secrets redacted

The engine SHALL append one JSONL line per evaluation to
`.cache/metrics/command-policy-audit.jsonl` on the host with `ts`, `run_id`,
`host_kind`, `regime`, `caller`, `program`, `argv_digest`, `rule_id`,
`decision` and `consent_source`. Token-shaped literals SHALL be replaced by
`<redacted:token>` in the audit and in any refusal text before formatting.
`tillandsias-plan policy audit --since <dur>` SHALL summarise counts per rule
and decision and SHALL answer `ok:policy-audit:empty` when no log exists.

#### Scenario: A token never reaches the log

- **WHEN** an argv contains a `ghp_…` literal
- **THEN** the audit line and any refusal text carry `<redacted:token>`
  in its place
