# Tasks — external-logs-layer

Five independently committable stages per the strategy memo §"Implementation
sequencing".

## 1. Core model (chunk 1)

- [ ] 1.1 `crates/tillandsias-core/src/container_profile.rs`: add `MountSource::ExternalLogsProducer { role: &'static str }` and `MountSource::ExternalLogsConsumerRoot` variants.
- [ ] 1.2 `ContainerProfile`: add `external_logs_role: Option<&'static str>` and `external_logs_consumer: bool`. Default both to `None`/`false` in all 7 profile constructors (preserves current behaviour).
- [ ] 1.3 `crates/tillandsias-core/src/config.rs`: add `external_logs_dir() -> PathBuf` and `external_logs_role_dir(role: &str) -> PathBuf` helpers (mirror existing `log_dir` / `container_log_dir`).
- [ ] 1.4 `src-tauri/src/launch.rs::resolve_mount_source`: handle the two new variants. Producer = create + bind-mount RW. Consumer = bind-mount parent RO. Mirror the existing `ContainerLogs` branch for directory creation.
- [ ] 1.5 Test: `external_logs_consumer_resolves_to_root` and `external_logs_producer_creates_role_dir`.
- [ ] 1.6 Test: `profile_cannot_be_both_producer_and_consumer` — refuses BOTH set on a single profile (assertion in profile constructor or builder).

## 2. git-service migration (chunk 2)

- [ ] 2.1 `git_service_profile()`: set `external_logs_role: Some("git-service")`.
- [ ] 2.2 `src-tauri/src/handlers.rs::ensure_external_logs_dir`: one-shot called at tray startup. If `~/.local/state/tillandsias/containers/git/logs/git-push.log` exists, move it to `~/.local/state/tillandsias/external-logs/git-service/git-push.log`. Leave `MIGRATED.txt` stub at the old path with the new path inside.
- [ ] 2.3 Verify `images/git/post-receive-hook.sh` continues to write to `/var/log/tillandsias/git-push.log` from inside the container — the bind-mount shadow does the work; no entrypoint change needed.
- [ ] 2.4 Manual smoke: launch a forge for any project, observe that the bare mirror's post-receive writes to `~/.local/state/tillandsias/external-logs/git-service/git-push.log` (NOT to the old per-container dir).

## 3. Forge consumer wiring + tillandsias-logs (chunk 3)

- [ ] 3.1 Three forge profiles (`forge_opencode`, `forge_claude`, `forge_opencode_web`) + `terminal_profile`: set `external_logs_consumer: true`.
- [ ] 3.2 New script `images/default/cli/tillandsias-logs` (POSIX shell, executable, COPY'd to `/usr/local/bin/`) with three subcommands: `ls` (list role/file/size/mtime/lines), `tail <role> <file>` (`tail -f` wrapper with `[role/file]` prefix), `combine` (interleave consumer's own internal log + every external log, sorted by mtime).
- [ ] 3.3 `images/default/lib-common.sh`: export `TILLANDSIAS_EXTERNAL_LOGS=/var/log/tillandsias/external` for tools that want the path without the CLI.
- [ ] 3.4 Manual smoke: from a forge, `tillandsias-logs ls` shows `git-service/git-push.log` after a push.

## 4. Manifest + auditor (chunk 4)

- [ ] 4.1 `images/git/external-logs.yaml` (NEW): canonical example. Single entry: `git-push.log`.
- [ ] 4.2 `images/git/Containerfile`: COPY the manifest to `/etc/tillandsias/external-logs.yaml`.
- [ ] 4.3 `src-tauri/src/handlers.rs::external_logs_audit_tick`: 60s tray-side task. For each running producer:
   - `podman cp <container>:/etc/tillandsias/external-logs.yaml -` to read manifest.
   - Diff against on-disk files; emit `[external-logs] LEAK: ...` at WARN+accountability for any unlisted file.
   - 10 MB cap with truncate-to-tail rotation.
   - Growth-rate alarm > 1 MB/min sustained for 5 min → WARN.
- [ ] 4.4 Reverse-breach refusal at producer-launch time: any profile with BOTH role+consumer is rejected before podman.
- [ ] 4.5 Tray UI: external-logs chip (yellow on alarm).
- [ ] 4.6 Tests: `auditor_detects_unlisted_file_emits_leak`, `auditor_truncates_oversized_file`, `auditor_growth_rate_alarm_after_5_min`.

## 5. Cheatsheet + cross-image manifests (chunk 5)

- [ ] 5.1 Write `cheatsheets/runtime/external-logs.md` (≤200 lines with full Provenance per the agent-cheatsheets template).
- [ ] 5.2 Update `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`: add fifth row "External logs (curated)".
- [ ] 5.3 Update `cheatsheets/runtime/forge-container.md`: short note pointing at the new cheatsheet.
- [ ] 5.4 `images/proxy/external-logs.yaml`: Squid `access.log` (curated subset) + `denied.log`.
- [ ] 5.5 `images/router/external-logs.yaml`: Caddy `access.log`.
- [ ] 5.6 `images/inference/external-logs.yaml`: `model-load.log`.
- [ ] 5.7 Each producer image's Containerfile gains the `COPY external-logs.yaml /etc/tillandsias/`.
- [ ] 5.8 `scripts/regenerate-cheatsheet-index.sh` picks up the new cheatsheet.
- [ ] 5.9 `openspec/changes/external-logs-layer/specs/external-logs-layer/spec.md` (NEW capability spec).
- [ ] 5.10 `openspec/changes/external-logs-layer/specs/runtime-logging/spec.md` (delta) + `podman-orchestration/spec.md` (delta).
- [ ] 5.11 `openspec validate external-logs-layer` — expect 0 errors.
- [ ] 5.12 Archive: `openspec archive external-logs-layer -y`.
