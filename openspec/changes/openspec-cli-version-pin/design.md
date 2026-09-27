# Design — OpenSpec CLI version pin

## Where the collision was

```
entrypoint ─┬─ ensure_forge_harnesses &     npm install -g @fission-ai/openspec@latest ─┐
            │  (background, before clone)                                               ├─ same prefix:
            └─ require_openspec; init        "$NPM_CONFIG_PREFIX/bin/openspec" init ─────┘  ~/.cache/tillandsias-project/npm/global
```

The version that generated the committed tree was never recorded anywhere, so
nothing could say which of the two was "right". Host evidence from
macuahuitl-fedora: no openspec exists on the host or in `tillandsias-builder`.
The collision is entirely inside the forge.

## Decisions

**One openspec, in the global prefix, at the pinned version.** The shell rc
files (`bashrc`, `zshrc`, `config.fish`) put `$NPM_CONFIG_PREFIX/bin` first on
PATH. A pinned install in a side prefix would lose to the global `@latest` one
in every interactive shell and agent tool call. So the pin is installed into
the global prefix itself, and the refresher is told to leave it alone. The
foreground takes the same `npm-update.lock` the refresher holds (bounded wait),
so the two never write the prefix at once, and the foreground always runs
last. The refresher starts before the clone and cannot read the pin itself.
The marker (`~/.cache/tillandsias-project/openspec-pin`) is how the foreground
tells it, on the persistent per-project cache.

**The coordinator bumps; nobody else moves the generated sets.**
`openspec-pin.sh bump` installs the target into a version-keyed cache (never
the machine's global npm). It runs `openspec update --force` with
`XDG_CONFIG_HOME` set to a fresh temporary directory and telemetry and update
checks off, writes the pin, and verifies with `drift`. It never commits: the
coordinator commits the result as one change.

**Isolated config.** `openspec update` reads a per-machine global profile.
From an empty config it migrates a profile from the committed workflows
("Migrated: custom profile with 11 workflows"). The output then depends on the
repository alone, not on whichever machine runs the bump.

**Stop for review, never guess.** A bump that writes outside the generated
surface, leaves drift, or where the CLI reports a superseded copy
("Left 11 files in .codex/ that differ from the copy in .agents/") ends in
`review:` with the tree left for a person or agent to resolve inside the same
change.

**`drift` is the gate-readable record.** It reports every tracked `generatedBy`
that disagrees with the pin. It is what 1253-nmmy asked for ("the version is
recorded somewhere a gate can read").

## Kept from 1422-w3p8 and 1440-w8g8

`openspec_init_if_absent` still never rewrites a present set. That is the
backstop if the pinned install fails (offline enclave) and the forge falls back
to whatever openspec it has. `check-opsx-generated-dirt.sh` still refuses
launch dirt; with the pin in place, that dirt means something regressed.
