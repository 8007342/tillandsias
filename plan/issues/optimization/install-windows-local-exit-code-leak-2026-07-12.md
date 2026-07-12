# build-and-install-windows-local.ps1 leaks --diagnose exit 2 as its own exit code (2026-07-12)

- class: optimization (script ergonomics / automation correctness)
- found by: windows meta-orchestration cycle (windows-bullo-fable5-20260712T1940Z),
  discovered_by: /build-install-and-smoke-test-e2e (windows)
- status: open
- trace: scripts/build-and-install-windows-local.ps1 (post-install sanity check)

## Symptom

A fully successful build + install run (build green in 3m07s, binary
installed, `--version` verified `0.3.260712.1 (7eaa8319)` == HEAD,
`--diagnose --json` exit 2 = expected "distro not provisioned/running"
degraded state) still terminates with **script exit code 2**, so any
automation wrapping the installer (background task runners, CI lanes,
`$LASTEXITCODE` checks) reports the install as FAILED.

## Root cause

The post-install sanity check documents exit 2 as acceptable ("only exit 1
hard-fails") and correctly does not `throw` — but the script never resets
`$LASTEXITCODE` / never ends with an explicit `exit 0`, so the last native
command's exit code (`cmd.exe /c ... --diagnose --json`, exit 2) becomes the
script's own exit status.

## Fix direction

End the script with an explicit `exit 0` on the healthy paths (or map the
documented-acceptable diagnose exits to 0), keeping `throw`/`exit 1` for the
genuine failure branches. Add the tri-state contract (0 ok, 2 acceptable
degraded, 1 hard fail) to the header comment.

## Repro

`scripts/build-and-install-windows-local.ps1 -Provision` on a host whose
distro is stopped or unregistered → observe green output, `$LASTEXITCODE` = 2.
