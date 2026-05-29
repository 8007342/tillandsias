---
tags: [logging, tracing, observability, runtime, privacy, redaction]
languages: [rust, bash]
since: 2026-05-07
last_verified: 2026-05-07
sources:
  - https://docs.rs/tracing/latest/tracing/
  - https://docs.rs/tracing-subscriber/latest/tracing_subscriber/
  - https://docs.rs/tracing-appender/latest/tracing_appender/
  - https://opentelemetry.io/docs/specs/semconv/
  - https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Runtime Logging

@trace spec:runtime-logging, spec:logging-accountability, spec:external-logs-layer

**Use when**: implementing or reviewing Tillandsias logging behavior, tracing layers, redaction policy, or accountability windows.

## Provenance

- `tracing` crate docs: <https://docs.rs/tracing/latest/tracing/>
- `tracing-subscriber` crate docs: <https://docs.rs/tracing-subscriber/latest/tracing_subscriber/>
- `tracing-appender` crate docs: <https://docs.rs/tracing-appender/latest/tracing_appender/>
- OpenTelemetry semantic conventions: <https://opentelemetry.io/docs/specs/semconv/>
- OWASP Logging Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html>
- **Last updated:** 2026-05-07

## Source-backed takeaways

- `tracing_appender::non_blocking` writes off-thread and uses a `WorkerGuard` to flush buffered events on drop.
- `tracing-subscriber` composes `Layer`s and `Filter`s; `EnvFilter` is the normal runtime filter mechanism.
- OpenTelemetry semantic conventions standardize names for logs and events so telemetry can be correlated across systems.
- OWASP logging guidance says sensitive data such as access tokens, passwords, and PII should usually be removed, masked, sanitized, hashed, or encrypted rather than logged directly.
- OWASP also warns that logs can become a confidentiality, integrity, and availability target.

## See also

- `openspec/specs/runtime-logging/spec.md`
- `openspec/specs/logging-accountability/spec.md`
- `openspec/specs/external-logs-layer/spec.md`
