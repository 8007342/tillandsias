---
tags: [external-logs, observability, logs, runtime, podman, rsyslog]
languages: []
since: 2026-05-12
last_verified: 2026-05-12
sources:
  - https://docs.podman.io/en/stable/markdown/podman-cp.1.html
  - https://docs.podman.io/en/stable/markdown/podman-run.1.html
  - https://www.rsyslog.com/doc/master/concepts/index.html
  - https://doc.rust-lang.org/std/macro.include_str.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# External logs

## Provenance

- `podman cp(1)`: <https://docs.podman.io/en/stable/markdown/podman-cp.1.html>
- `podman run(1)`: <https://docs.podman.io/en/stable/markdown/podman-run.1.html>
- rsyslog concepts: <https://www.rsyslog.com/doc/master/concepts/index.html>
- `include_str!`: <https://doc.rust-lang.org/std/macro.include_str.html>
- **Last updated:** 2026-05-12

## Source-backed takeaways

- `podman cp` can stream container files to stdout, which is useful for reading manifests or exported log artifacts without mutating the container.
- `podman run` bind mounts support read-write and read-only roles, which is the primitive behind producer/consumer file layouts.
- `include_str!` embeds text assets at compile time, which is useful when a manifest should be baked into the binary.
- rsyslog organizes logs by facilities and rules, which is the upstream mechanism for syslog-based routing.

## See also

- `openspec/specs/external-logs-layer/spec.md`
- `openspec/specs/cheatsheets-license-tiered/spec.md`
