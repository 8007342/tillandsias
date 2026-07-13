# Forge entrypoint: "OpenSpec init failed — /opsx commands may not work"

- Date: 2026-07-13
- Class: optimization
- discovered_by: /build-install-and-smoke-test-e2e (linux_mutable), gate 4
  forge lane, evidence target/build-install-smoke-e2e/20260713*/04-meta-orchestration.log

## Symptom

On the cold-store forge lane launch (pristine cache after
`podman system reset --force`), the opencode entrypoint printed:

```
[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work
```

The lane proceeded and the in-forge meta-orchestration cycle completed
successfully (order 316 fixed + pushed), so this is non-fatal — but /opsx
commands were potentially unavailable for that session, and the warning
does not include the underlying error line the entrypoint captured.

## Repro

Cold e2e: reset store → `tillandsias --init` → `tillandsias . --opencode
--prompt ...`; observe entrypoint stderr on first lane launch.

## Smallest next action

Surface `$OS_OUTPUT`'s first error line in the WARNING (it is captured but
only partially echoed), and probe whether first-launch timing (openspec
installed by the backgrounded harness updater while the entrypoint's
foreground `openspec init` runs) is the cause — if so, `require_openspec`
before init already ran, so capture which binary/path failed.
