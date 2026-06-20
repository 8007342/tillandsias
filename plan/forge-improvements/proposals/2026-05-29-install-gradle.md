---
title: Install Gradle build tool for Java/JVM projects
gap: GRADLE_USER_HOME is exported in lib-common.sh but Gradle is not installed in the forge image
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T18:00:00Z
changes:
  - file: images/default/Containerfile
    description: Add Gradle installation (via gradle.org releases tarball, extracted to /opt/gradle, symlinked to /usr/local/bin/gradle). GRADLE_USER_HOME is already exported by lib-common.sh routing Gradle caches to the per-project cache.
approved_by: null
---

## Gap

The forge image exports `GRADLE_USER_HOME` (lib-common.sh:536) routing Gradle build caches and wrapper distributions to the per-project cache. However, Gradle itself is not installed in the image.

Gradle is the dominant build system for JVM projects and is commonly needed for:
1. **Android builds**: Flutter projects with Android native components require Gradle
2. **Spring Boot / JVM projects**: Gradle is the primary build system for modern JVM projects
3. **Kotlin Multiplatform**: Gradle is the required build tool
4. **Agent-driven development**: agents building Java/Kotlin projects expect Gradle availability

Maven is already installed (Containerfile line 23) with `MAVEN_OPTS` routing its repo to the per-project cache. Gradle should be similarly available for parity.

## Evidence

- `images/default/lib-common.sh` line 536: `export GRADLE_USER_HOME="$PROJECT_CACHE/gradle"`
- `images/default/Containerfile` line 23: `java-25-openjdk-headless maven` — Maven is installed, Gradle is not
- `images/default/Containerfile` lines 17-24: no gradle package
- Gradle is available from https://gradle.org/releases/ as a standalone tarball (~120 MB with distribution)

## Safety

- Gradle installation uses the official Gradle releases tarball via HTTPS — the same channel used for geckodriver (already in the Containerfile).
- GRADLE_USER_HOME already points to per-project cache; Gradle caches and wrapper distributions will be stored there.
- Fedora also offers `gradle` via microdnf if preferred over the tarball approach.
- No credentials or secrets are involved.
