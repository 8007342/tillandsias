# podman-logging — Container Log Inspection

**Use when**: Debugging container failures, monitoring live application output, troubleshooting build issues, viewing container startup sequences.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-logs.1.html — Official Podman logs command reference
- https://docs.podman.io/en/latest/markdown/podman-events.1.html — Official Podman events command reference
- **Last updated:** 2026-05-02

@trace spec:cli-diagnostics, spec:observability-convergence

## Quick Reference

| Command | Purpose |
|---------|---------|
| `podman logs <container>` | Print all logs from a container |
| `podman logs -f <container>` | Stream logs in real-time (follow mode) |
| `podman logs --tail 20 <container>` | Last 20 lines only |
| `podman logs --timestamps <container>` | Include timestamps on each line |
| `podman logs <container> \| grep ERROR` | Filter logs by keyword |
| `podman ps` | List running containers |
| `podman ps -a` | List all containers (including stopped) |
| `podman inspect <container>` | Show container metadata (image, environment, mounts) |

## Real-Time Log Streaming

```bash
# Watch a single container
podman logs -f tillandsias-proxy

# Watch multiple containers (podman doesn't support multi-container tail)
# Use this pattern instead:
for container in tillandsias-proxy tillandsias-git; do
  podman logs -f $container &
done
wait

# Or use tillandsias diagnostics (preferred):
tillandsias --diagnostics /path/to/project
```

## Filtering and Formatting

```bash
# Last 10 lines with timestamps
podman logs --tail 10 --timestamps tillandsias-proxy

# Lines containing "ERROR" or "WARN"
podman logs tillandsias-forge | grep -E "ERROR|WARN"

# Follow logs while filtering
podman logs -f tillandsias-proxy | grep --line-buffered "CONNECT"

# Timestamp parsing (podman format: RFC3339Nano)
podman logs --timestamps tillandsias-proxy | awk '{print $1, $2}' # extract timestamp
```

## Container Discovery

```bash
# Find all tillandsias containers
podman ps | grep tillandsias

# Show full container names (not truncated)
podman ps --no-trunc

# Filter by status
podman ps -f "status=running"
podman ps -f "status=exited"

# Show container IDs only
podman ps --quiet
```

## Troubleshooting Common Issues

**Container logs are empty**
- Container crashed immediately: `podman inspect <container>` → check `State.ExitCode`
- Container is still initializing: wait a few seconds and retry
- Check container status: `podman ps -a | grep <container>`

**Logs are too verbose**
- Use `| tail -20` to see recent entries
- Filter by keyword: `| grep ERROR`
- Reduce verbosity in application (not podman setting)

**Logs stop appearing**
- Container exited: `podman ps -a` to confirm, then restart if needed
- Logs rotated out: limit is platform-dependent, use `--tail` to see older lines before rotation

## Tillandsias-Specific Log Sources

| Container | Source | Contains |
|-----------|--------|----------|
| `tillandsias-proxy` | Squid access log + startup | HTTP requests, cache decisions, certificate warnings |
| `tillandsias-git` | Git daemon + background sync | Clone/push operations, SSH key generation |
| `tillandsias-inference` | Ollama API + model loading | Model pull progress, API requests, GPU status |
| `tillandsias-<project>-forge` | OpenCode + build output | Dependency installation, test output, runtime errors |
| `tillandsias-<project>-browser-core` | Chromium startup | Browser initialization, page load events |
| `tillandsias-<project>-browser-framework` | Chromium with tools | Framework startup, debugging interface readiness |

## Source Label Format

When using `tillandsias --diagnostics`, each log line is prefixed with a source label:

```
[<container-type>:<owner>] <log line>
```

Examples:
- `[proxy:shared]` — Shared proxy container
- `[forge:visual-chess]` — Forge for the visual-chess project
- `[browser-core:visual-chess]` — Browser core for the visual-chess project
- `[inference:shared]` — Shared inference container

This makes it easy to grep for logs from a specific container:
```bash
tillandsias --diagnostics /project | grep '\[forge'
```
