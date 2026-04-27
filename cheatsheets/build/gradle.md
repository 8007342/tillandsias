---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://docs.gradle.org/current/userguide/command_line_interface.html
  - https://docs.gradle.org/current/userguide/java_library_plugin.html
  - https://docs.gradle.org/current/userguide/platforms.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Gradle

@trace spec:agent-cheatsheets

## Provenance

- Gradle Command-Line Interface reference: <https://docs.gradle.org/current/userguide/command_line_interface.html> — gradle tasks/assemble/build/test/check/clean/run, :sub:task syntax, --rerun-tasks, --refresh-dependencies, -P/-D flags, --scan, --no-daemon, ./gradlew wrapper generation
- Gradle dependency configurations reference: <https://docs.gradle.org/current/userguide/java_library_plugin.html> — implementation vs api vs runtimeOnly vs testImplementation scopes
- Gradle Version Catalogs: <https://docs.gradle.org/current/userguide/platforms.html> — gradle/libs.versions.toml [versions]/[libraries]/[plugins] tables
- **Last updated:** 2026-04-25

**Version baseline**: Gradle 8.10 (baked at `/opt/gradle`, on `PATH` as `gradle`).
**Use when**: Java/Kotlin builds with `build.gradle` / `build.gradle.kts` — Android excluded in forge.

## Quick reference

| Command | Effect |
|---|---|
| `gradle tasks` | List tasks available in current project (add `--all` for everything) |
| `gradle assemble` | Build all outputs (jars, distributions) without running tests |
| `gradle build` | `assemble` + `check` (compile + test + lint) |
| `gradle test` | Run unit tests; reports under `build/reports/tests/` |
| `gradle check` | All verification tasks (test, lint, style) |
| `gradle clean` | Delete `build/` directory |
| `gradle run` | Execute the `application` plugin's main class |
| `gradle :sub:task` | Run `task` only in subproject `sub` |
| `gradle <task> --rerun-tasks` | Force tasks to re-execute, ignoring up-to-date checks |
| `gradle <task> --refresh-dependencies` | Bypass cached metadata; re-resolve every dep |
| `gradle <task> -P<key>=<val>` | Pass a project property (visible as `findProperty("key")`) |
| `gradle <task> -D<key>=<val>` | Pass a JVM system property |
| `gradle <task> --scan` | Publish a build scan to `scans.gradle.com` (network required) |
| `gradle <task> --no-daemon` | Disable the long-lived daemon (recommended in CI / forge) |
| `gradle wrapper --gradle-version 8.10` | Generate / pin `./gradlew` |
| `./gradlew <task>` | Project-pinned wrapper — preferred entry point in shared repos |
| `gradle dependencies` | Print resolved dependency graph |
| `gradle help --task <name>` | Show usage + options for a specific task |

## Common patterns

### Pattern 1 — Bootstrap a Kotlin DSL project

```bash
gradle init \
  --type kotlin-application \
  --dsl kotlin \
  --test-framework junit-jupiter \
  --package com.example
```

Generates `settings.gradle.kts`, `app/build.gradle.kts`, and a wrapper. Always commit `gradle/wrapper/`.

### Pattern 2 — Dependency configurations

```kotlin
// build.gradle.kts
dependencies {
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0") // not exposed to consumers
    api("org.slf4j:slf4j-api:2.0.13")                                    // exposed in compile classpath
    runtimeOnly("ch.qos.logback:logback-classic:1.5.6")                  // runtime only
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
```

Prefer `implementation` by default — `api` leaks into downstream compile classpath.

### Pattern 3 — Multi-project layout

```kotlin
// settings.gradle.kts
rootProject.name = "my-app"
include("core", "api", "cli")
```

```bash
gradle :api:test            # one subproject
gradle build                # all subprojects, root coordinates
```

### Pattern 4 — Custom task

```kotlin
// build.gradle.kts
tasks.register<Copy>("stageDocs") {
    from("src/docs")
    into(layout.buildDirectory.dir("staged-docs"))
    doLast { println("Staged ${inputs.files.files.size} files") }
}
```

### Pattern 5 — Version catalog

```toml
# gradle/libs.versions.toml
[versions]
kotlin = "2.0.0"
junit  = "5.10.2"

[libraries]
kotlin-stdlib = { module = "org.jetbrains.kotlin:kotlin-stdlib", version.ref = "kotlin" }
junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }
```

```kotlin
// build.gradle.kts
dependencies {
    implementation(libs.kotlin.stdlib)
    testImplementation(libs.junit.jupiter)
}
```

Single source of truth across multi-project builds; no more drifting version literals.

## Common pitfalls

- **`~/.gradle` and project `.gradle/` are ephemeral in the forge** — first build re-downloads every dep through the proxy; expect 1-3 minutes of "Resolving" before any compile happens. Prefer warming a long-lived forge or using a host-mounted cache for repeat work.
- **`implementation` vs `api` scope leaks** — accidentally using `api` puts a transitive dep on every consumer's compile classpath. When the lib upgrades incompatibly, every downstream project breaks. Default to `implementation`; use `api` only when the type is part of your published surface.
- **Kotlin DSL ↔ Groovy DSL is not 1:1** — `apply plugin: 'foo'` (Groovy) vs `plugins { id("foo") }` (KTS); string properties become typed methods; `ext` becomes `extra`. Auto-conversion tools miss closures and dynamic property access — review every line.
- **Daemon is wasted in short-lived containers** — the Gradle daemon caches JIT state across invocations, but a forge that runs one `gradle build` and exits pays the daemon spawn cost without any reuse. Pass `--no-daemon` (or set `org.gradle.daemon=false` in `gradle.properties`) for CI and one-shot forge sessions.
- **Plugin version inheritance is implicit** — applying a plugin in a subproject without a version uses whatever the root project pinned. Removing the root pin silently breaks every subproject. Centralise plugin versions in `settings.gradle.kts` `pluginManagement {}` or the version catalog `[plugins]` table.
- **Gradle ↔ JDK compatibility matrix is strict** — Gradle 8.10 requires JDK 8 to run, supports compiling for 8-22, but tooling integration (Kotlin, AGP) imposes tighter bounds. Mismatched JDK and Gradle versions surface as opaque `Unsupported class file major version` errors. Check the official compat matrix before bumping either side.
- **`--refresh-dependencies` forces a full re-download** — bypasses every cached `*.pom`, `*.module`, and `*.jar` and re-resolves from remote. Useful for diagnosing a suspect cache, painful on a slow proxy. Use it surgically, not as a habit.
- **Configuration cache vs build cache are different** — `--configuration-cache` serialises the configuration phase; `--build-cache` reuses task outputs across builds. Enabling both is usually correct, but configuration cache breaks any task that reads project state at execution time (a common anti-pattern in older plugins).

## Forge-specific

- Gradle 8.10 is baked at `/opt/gradle` — newer than Fedora's package. Use `gradle` directly or `./gradlew` (pinned per project).
- `~/.gradle/caches` is gone on container stop — first build is slow; subsequent builds in the same session are fast.
- Daemon mode (default) does not help short-lived forges; use `--no-daemon` or set `org.gradle.daemon=false` for one-shot work.
- Dependency resolution flows through `tillandsias-proxy`. A "Could not GET" against Maven Central usually means the host is not on the proxy allowlist, not a network outage.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://docs.gradle.org/current/userguide/command_line_interface.html`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.gradle.org/current/userguide/command_line_interface.html`
- **License:** see-license-allowlist
- **License URL:** https://docs.gradle.org/current/userguide/command_line_interface.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.gradle.org/current/userguide/command_line_interface.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://docs.gradle.org/current/userguide/command_line_interface.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/gradle.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `languages/java.md`, `build/maven.md`
- `runtime/forge-container.md` — ephemeral cache lifecycle
