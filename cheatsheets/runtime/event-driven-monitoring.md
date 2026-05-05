---
tags: [monitoring, events, podman, docker, event-api, systemd, journalctl, observable-systems]
languages: [bash, rust]
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://docs.podman.io/en/latest/markdown/podman-events.1.html
  - https://docs.docker.com/engine/api/v1.45/#tag/Events
  - https://man7.org/linux/man-pages/man1/journalctl.1.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Event-driven monitoring

@trace spec:container-health, spec:external-logs-layer
@cheatsheet architecture/event-driven-basics.md

**Version baseline**: Podman 4.0+, Docker 20.10+, systemd 250+
**Use when**: building observable systems that react to container lifecycle events, service state changes, or log stream updates; avoiding polling loops and wasted CPU cycles.

## Provenance

- Podman events reference (event types, filtering, output formats, streaming): <https://docs.podman.io/en/latest/markdown/podman-events.1.html>
- Docker Engine API — Events endpoint (event types, filters, streaming semantics): <https://docs.docker.com/engine/api/v1.45/#tag/Events>
- journalctl(1) man page (log streaming, filters, JSON output, system integration): <https://man7.org/linux/man-pages/man1/journalctl.1.html>
- **Last updated:** 2026-04-27

## Quick reference

| Source | Command | Output | Use case |
|---|---|---|---|
| **Podman containers** | `podman events --format json` | newline-delimited JSON | container lifecycle (start/stop/health) |
| **systemd journal** | `journalctl -f -o json` | newline-delimited JSON | system logs, service state changes |
| **Podman health** | `podman events --type=container --filter event=health_status` | subset of container events | health check status only |
| **systemd status** | `systemctl list-units --type=service --state=failed --no-pager` | text table | failed services (one-shot query, not streaming) |

**Why NOT polling:** polling wastes CPU, adds latency, and breaks when the poll interval exceeds the event frequency. Events are free and instant.

## Common patterns

### Pattern 1 — Monitor all container events (JSON streaming)

```bash
podman events --format json | jq 'select(.Type == "container")'
```

Reads events as they happen, filters to container events, discards everything else. Ctrl+C to stop.

**Output:**
```json
{
  "Type": "container",
  "Event": "start",
  "Actor": {
    "ID": "abc123...",
    "Attributes": {
      "name": "tillandsias-forge-proj1-aeranthos"
    }
  },
  "Time": 1714252800,
  "TimeNano": 1714252800123456789
}
```

### Pattern 2 — Stream health check events

```bash
podman events \
  --type=container \
  --filter event=health_status \
  --format '{{.Time}} {{.Actor.Attributes.name}} {{.Actor.Attributes.health_status}}'
```

Outputs human-readable lines: `2026-04-27T14:30:00... tillandsias-forge-proj1 healthy`.

### Pattern 3 — Rust async event stream (tokio)

```rust
use tokio::process::Command;
use tokio::io::BufReader;
use futures::stream::StreamExt;
use serde_json::Value;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut child = Command::new("podman")
        .args(&["events", "--format", "json"])
        .stdout(std::process::Stdio::piped())
        .spawn()?;
    
    let stdout = child.stdout.take().unwrap();
    let reader = BufReader::new(stdout);
    let mut lines = tokio::io::AsyncBufReadExt::lines(reader);
    
    while let Some(line) = lines.next_line().await? {
        let event: Value = serde_json::from_str(&line)?;
        
        if event["Type"] == "container" {
            let event_type = &event["Event"];
            let name = &event["Actor"]["Attributes"]["name"];
            
            println!("{}: {}", event_type, name);
            
            // React to the event
            match event_type.as_str() {
                Some("start") => println!("Container started!"),
                Some("die") => println!("Container died!"),
                Some("health_status") => {
                    let status = &event["Actor"]["Attributes"]["health_status"];
                    println!("Health: {}", status);
                }
                _ => {}
            }
        }
    }
    
    Ok(())
}
```

Never blocks; drives the event loop via futures.

### Pattern 4 — Monitor systemd journal in real-time

```bash
# Follow all logs as JSON
journalctl -f -o json | jq 'select(.SYSLOG_IDENTIFIER == "tillandsias-router")'

# Track specific service
journalctl -f -u tillandsias-router -o short-iso

# Combine stdout + stderr (both captured as PRIORITY field)
journalctl -f --no-pager -n 0  # -n 0 = no history, only live
```

`-f` (follow) streams new entries as they arrive, never polls.

### Pattern 5 — Combined event + log monitoring

```bash
# Watch container events and journal logs simultaneously
(
  podman events --format json &
  journalctl -f -o json
) | jq 'select(.Type == "container" or .MESSAGE != null)'
```

Merges two event streams (podman + systemd) into one JSON feed. In production, run these as separate background processes and aggregate elsewhere.

## Common pitfalls

- **Polling in a loop instead of streaming** — `while true; podman ps; sleep 5` wastes CPU, misses events, and adds 5s latency. Use `podman events` instead.
- **Forgetting `--format json`** — plain output is hard to parse and fragile to text changes. Always use `--format json` for automation and filter with jq.
- **Missing `select()` filters** — raw `podman events` outputs 20+ event types (create, remove, exec, etc.). Use `jq 'select(.Type == "container")'` to silence noise.
- **Not handling EOF** — if podman/journalctl connection drops, the listener exits silently. Wrap in a supervisor or retry loop.
- **Buffering delays** — some systems buffer JSON event lines. Ensure stdout is unbuffered: in bash, use `| while read -r line; do ...` (line-buffered). In Rust, flush after each event.
- **Mixing old and new APIs** — Docker v1.40 added better filters; older versions have limited event types. Use Podman or modern Docker with version checks.
- **Timezone issues in timestamps** — podman timestamps are Unix epoch (seconds since 1970), systemd has ISO-8601. Convert consistently in your aggregation layer.
- **Running out of event buffer** — if the event consumer is too slow, podman may drop events. Critical monitoring should use a dedicated journal sink (log to a file, not tail from socket).

## Comparison: events vs. polling

| Concern | Polling | Events |
|---|---|---|
| CPU usage | High (per poll cycle) | Zero (kernel-driven) |
| Latency | Poll interval (1-5s typical) | <100ms (kernel queue) |
| Missed events | Possible (fast changes between polls) | Never (all enqueued) |
| Complexity | Simple loop | Async select/epoll |
| Scalability | ~10 sources max | Unlimited (kernel multiplexing) |

**Conclusion:** Always event-driven. Polling is acceptable only for one-shot checks (cron jobs, CI steps) with explicit acceptance of the latency.

## See also

- `runtime/container-health-checks.md` — health check status (subset of events)
- `runtime/external-logs.md` — curated log aggregation (not raw journalctl)
- `architecture/event-driven-basics.md` — design patterns for event systems
- `architecture/reactive-streams-spec.md` — backpressure and flow control for high-frequency event streams
- `languages/rust.md` — tokio, futures, async patterns
- `utils/jq.md` — filtering and transforming JSON event streams

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: Event stream APIs are stable; bundling docs exceeds image size targets.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the pull cache by following the recipe below.

### Source

- **Upstream URL(s):**
  - `https://docs.podman.io/en/latest/markdown/podman-events.1.html`
  - `https://docs.docker.com/engine/api/v1.45/#tag/Events`
  - `https://man7.org/linux/man-pages/man1/journalctl.1.html`
- **Archive type:** `single-html`
- **Expected size:** `~2 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/podman-docker-journalctl-event-docs/`
- **License:** Podman (Apache 2.0), Docker (Community license), man-pages (GPL v2)
- **License URL:** https://github.com/containers/podman/blob/main/LICENSE

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/podman-docker-journalctl-event-docs"
mkdir -p "$TARGET_DIR"
for URL in \
  "https://docs.podman.io/en/latest/markdown/podman-events.1.html" \
  "https://docs.docker.com/engine/api/v1.45/#tag/Events" \
  "https://man7.org/linux/man-pages/man1/journalctl.1.html"; do
  FILENAME=$(basename "$URL" | cut -d'#' -f1)  # strip fragment
  curl --fail --silent --show-error "$URL" -o "$TARGET_DIR/$FILENAME"
done
echo "Cached to $TARGET_DIR"
```

### Generation guidelines (after pull)

1. Read the pulled files to understand container event types, filtering, and journal streaming semantics.
2. If your project monitors container or service state extensively (e.g., tillandsias tray monitoring), generate a project-contextual cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/event-driven-monitoring.md` using `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.
