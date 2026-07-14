# Antigravity lane crashes instantly on tray launch

- Date: 2026-07-12
- Class: exploration (work packet — order 307)
- Filed by: linux_mutable meta-orchestration cycle (operator repro)

## Operator repro (2026-07-12, local build, fresh --init)

Tray → Antigravity: the lane window "crashed right away". No error was
readable because agent entrypoints had no exit pause — the popup closed with
the container.

## This cycle's changes (observability + likely contributing fixes)

- All agent entrypoints now trap EXIT and pause on non-zero exit
  ("Press any key…", mirroring entrypoint-terminal.sh), so the NEXT repro
  shows the real error instead of a vanishing window.
- `GIT_SSL_CAINFO` now points at the combined CA bundle in every forge lane
  (git/libcurl ignored `SSL_CERT_FILE` and the injected gitconfig pinned the
  enclave-CA-only file) — fixes any git-over-HTTPS step in the agy installer
  path.

## Confirmed root cause (forge-big-pickle 2026-07-12)

**Forge proxy blocks the agy release server.** The installer downloads
successfully (7354 bytes from `antigravity.google/cli/install.sh`) but the
inner binary download from `antigravity-cli-auto-updater-974169037036.us-central1.run.app`
fails with `Connection reset by peer` — the Squid proxy's egress allowlist
does not include `*.us-central1.run.app` domains. No `run.app` domains
appear anywhere in the proxy configuration. Since agy is installed
EVERY_LAUNCH (not baked into the image), the binary is never present and
`exec agy` fails with exit code 127.

Secondary: vault has no `GEMINI_API_KEY` / `GEMINI_OAUTH_TOKEN` — even
if agy installed successfully, it would likely demand authentication.

## Fix applied this cycle

`entrypoint-forge-antigravity.sh:121-141`: replaced the trace-only
"agy not found on PATH" with a fail-fast block that prints a clear
error message naming the proxy allowlist gap and exits 1 before
reaching the `exec agy` line. The exit-pause trap is now redundant
for this failure mode (the explicit exit 1 triggers it) but remains
as a safety net for other failures.

## Remaining work (split packets)

- **Proxy egress allowlist**: add `antigravity-cli-auto-updater-*.us-central1.run.app`
  to the Squid proxy egress rules. Operator action required (proxy config
  is outside the forge container's write scope). File as
  `plan/issues/forge-proxy-egress-antigravity-2026-07-12.md` or include in
  order 303/304 login-flow work.
- **Gemini credential in vault**: requires Antigravity OAuth login flow
  (orders 303/304, deferred per operator directive until stable ships).

## Structural improvements (forge 2026-07-13)

1. **`require_antigravity()`** replaces one-shot curl installer with 3-attempt
   retry + exponential backoff (2s, 4s, 8s). Aligns with the npm harness retry
   pattern in `ensure_forge_harnesses`. Previous one-shot curl would fail
   silently on proxy hiccups, leaving agy absent.

2. **`export_project_env`** added — exports `TILLANDSIAS_PROJECT_PATH` and
   `TILLANDSIAS_PROJECT_GENUS`. Present in all other entrypoints (claude, opencode)
   but was missing from antigravity.

3. **`agent-profile.sh`**: added `antigravity` case (was falling through to
   `*) "Unknown"`).

## Exit criteria (order 307)

- [x] Reproduce with the new exit-pause trap and capture the actual error text
  into this file.
- [x] Root cause identified and either fixed or split into the owning packet
  (proxy egress → operator action; login flows → order 303/304).
- [ ] Antigravity lane launches to a usable TUI on a host with a valid Gemini
  credential in the vault. **Blocked on proxy egress allowlist + vault credential.**
