## ADDED Requirements

Mirror of the draft durable spec `openspec/specs/command-policies/spec.md` (stamped req-ids live there; see tasks.md §5).

### Requirement: A built-in floor that a project seed can only tighten

The policy engine SHALL compile in a floor of rules: `no-shell-strings`,
`no-credential-mutation` (`gh auth login|refresh|logout|token`,
`git credential approve|reject`, `vault login`), `no-self-consent`
(`tillandsias-plan policy consent grant` through any agent door), and the
consent classes
`soft-reset` (`--reset-state` on every platform, `--reset-guest` on Linux,
the `podman system reset --force` a platform reset uses —
`host-state-lifecycle`'s SOFT set), `hard-reset` (`--reset-guest` on a
guest regime, `wsl --unregister`, the VM directory wipe,
`TILLANDSIAS_INSTALL_RESET=hard`), `workspace-destroy` (`rm -rf` outside the
workspace) and `force-push` (`git push --force*` to a protected ref). A
per-project seed `.tillandsias/command-policies.yaml` MAY add rules and MAY
tighten a floor rule (deny where the floor asks consent) but SHALL NOT
loosen one; a seed that tries is refused at load with
`refused:policy-seed:cannot-loosen:<rule-id>` and the engine answers from
the floor alone. An unmatched request is allowed until the default flips
(`ok:policy:allow:default`). The flip is MEASURED, not dated (operator
ruling 2026-09-27): the seed's `default: {deny_after_quiet_days: N}` flips
unmatched requests to deny once the host's audit shows N consecutive days
with zero deny and zero ask decisions from `caller=pretooluse`; the first
flipped evaluation prints `ok:policy:default=deny:since=<date>`. N is
14, operator-confirmed 2026-09-27 ("14 days is a good starting point");
changing it is a seed edit reviewed like code.

#### Scenario: The default flips on a quiet period, not a date

- **WHEN** the seed says `deny_after_quiet_days: 14` and the audit holds
  fourteen consecutive days with no bridge deny or ask
- **THEN** the next unmatched request answers `refused:policy:default-deny`
  with a remedy naming the seed rule to add
- **AND** a day with one bridge deny resets the count

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
kind; the `hard-reset` class SHALL be `deny` in a forge and the
`soft-reset` class SHALL be `allow` there.

#### Scenario: The same argv, two hosts, two answers

- **WHEN** `tillandsias-tray --reset-guest` (a guest regime) is evaluated
  with host kind `bare-metal`
- **THEN** the answer is `consent:policy:hard-reset`
- **WHEN** it is evaluated with host kind `forge`
- **THEN** the answer is `refused:policy:hard-reset:not-grantable-in-forge`
- **WHEN** `tillandsias --reset-state` is evaluated with host kind `forge`
- **THEN** the answer is `ok:policy:soft-reset:forge-preauthorised`

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

### Requirement: Consent is per run; soft reset is pre-authorised in forges, hard reset never is

`tillandsias-plan policy consent grant <class> [--ttl 30m] -- <argv…>`
SHALL write a token bound to host, class, the EXACT argv (its sha256) and
expiry (mode 0600; `--ttl` at most 24h); a grant with no argv, or for an
argv that is not of that class on this host, SHALL be refused by name. An
evaluation of a consent class SHALL succeed once against a valid token and
spend it (an atomic rename, so two racing runs cannot both spend it), with
`consent_source=token`; the spent token is gone, so a replay answers
`consent:policy:<class>` again and its `why` says the token was already
spent. An expired or foreign-host token SHALL answer
`refused:consent:invalid:<reason>` and be deleted; a token for a different
argv SHALL answer `refused:consent:invalid:argv-mismatch` and be kept for
its own run. Tokens SHALL be honoured only where the host-kind EVIDENCE says
bare metal, never on a claimed kind. Minting through any agent door SHALL be
refused by the floor rule `no-self-consent` (`refused:policy:no-self-consent`):
a consent is the operator's approval, typed in the operator's own terminal.
The grant verb SHALL refuse in a forge. Operator ruling 2026-09-27,
verbatim: "Forges should keep pre-authorizing SOFT RESET always. HARD
RESET should require explicit approval each time." Therefore the
`soft-reset` class SHALL be allowed in a forge always
(`consent_source=forge-policy`) and, on bare metal, by
`TILLANDSIAS_DESTRUCTIVE_RESET_OK=1` only when the caller is one of the two
registered smoke skills (`consent_source=env`; `=0` stays the one opt-out
per `host-state-lifecycle`), else by a per-run token. The `hard-reset` class
SHALL require a per-run operator-minted token EVERY time, SHALL have no
environment pre-authorisation and none SHALL be added, and SHALL never be
grantable in a forge.

#### Scenario: The smoke skill's environment covers soft, never hard

- **WHEN** `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1` and
  `TILLANDSIAS_SKILL=smoke-curl-install-and-test-e2e` are set on bare metal
- **THEN** `--reset-state` is allowed with `consent_source=env`
- **AND** `--reset-guest` on a guest regime still answers
  `consent:policy:hard-reset`

#### Scenario: A token is consumed by its first use

- **WHEN** the operator minted a `hard-reset` token for exactly
  `tillandsias-tray --reset-guest`, and that argv
  is evaluated twice on a guest regime
- **THEN** the first answer is `ok:policy:hard-reset:consented`
- **AND** the second is `consent:policy:hard-reset`

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
