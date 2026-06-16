---
title: Install Gradle build tool
gap: "missing_tools: gradle; Java 25 + Maven installed, GRADLE_USER_HOME preconfigured, but gradle binary absent"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:30:00Z
changes:
  - file: images/default/Containerfile.base
    description: |
      Install gradle via microdnf (`gradle` package) on the existing
      system-packages RUN layer.
approval_required: orchestrator
---

## Gap

Java 25 and Maven are installed in the forge base image, and
`GRADLE_USER_HOME` is preconfigured in the diagnostics-prompt
environment checks, but the `gradle` binary is absent. This prevents
JVM builds without manual install.

## Evidence

From `plan/diagnostics/diagnostics_20260616T081755Z-summary.md`:

- `proposed_enhancements` includes java ecosystem entry:
  `{"tool": "gradle", "ecosystem": "java", "why": "Java 25 is installed and GRADLE_USER_HOME is preconfigured, but gradle binary is missing — prevents JVM builds without manual install."}`

Note: Gradle was mentioned in the earlier `2026-05-28-additional-tools-from-summary.md`
proposal (status: implemented) alongside dart/flutter/kotlin, but only
Dart SDK was actually added. This proposal scopes the specific Gradle gap.

## Privacy / Isolation Assessment

- Gradle installs via microdnl (`gradle` package) — standard Fedora package,
  same envelope as `maven` which is already installed.
- All build artifacts land in the existing preconfigured `GRADLE_USER_HOME`
  cache mount.
- No new network egress, credentials, mounts, or privileges required.
- **Safe within the existing privacy/isolation envelope.**
