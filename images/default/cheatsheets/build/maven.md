---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html
  - https://maven.apache.org/ref/current/maven-embedder/cli.html
  - https://maven.apache.org/plugins/maven-dependency-plugin/tree-mojo.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Maven

@trace spec:agent-cheatsheets

## Provenance

- Apache Maven — Introduction to the Build Lifecycle: <https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html> — validate/compile/test/package/verify/install/deploy/clean phases; surefire (unit) vs failsafe (integration) plugin lifecycle bindings
- Apache Maven CLI reference: <https://maven.apache.org/ref/current/maven-embedder/cli.html> — -P (profiles), -D (properties), -pl/-am/-amd (reactor), -fae/-ff, -U, -o, -T flags
- Maven dependency:tree: <https://maven.apache.org/plugins/maven-dependency-plugin/tree-mojo.html> — "nearest wins" resolution, -Dverbose mode for version conflict diagnosis
- **Last updated:** 2026-04-25

**Version baseline**: Maven 3.9+ (Fedora 43 `maven` package).
**Use when**: building Java projects with `pom.xml`.

## Quick reference

| Item | Effect |
|---|---|
| `mvn validate` | Verify project structure + pom is valid |
| `mvn compile` | Compile main sources to `target/classes/` |
| `mvn test` | Compile + run unit tests (surefire) |
| `mvn package` | Produce `target/<artifact>-<version>.jar` (or war/ear) |
| `mvn verify` | Run integration tests (failsafe) + checks |
| `mvn install` | Copy artifact into local `~/.m2/repository/` |
| `mvn deploy` | Push artifact to remote repository |
| `mvn clean` | Delete `target/` (chain: `mvn clean package`) |
| `-P <id>` | Activate a `<profile>` from pom or settings.xml |
| `-D<key>=<val>` | Override a property (e.g. `-Dmaven.test.skip=true`) |
| `-pl <module>` | Restrict reactor to one module (`--projects`) |
| `-am` / `-amd` | Also-make dependencies / dependents |
| `-fae` / `-ff` | Fail-at-end / fail-fast across reactor |
| `-U` | Force-update SNAPSHOT dependencies |
| `-o` | Offline mode (no network) |
| `-T 1C` | Parallel build, 1 thread per CPU core |
| `mvn dependency:tree` | Print resolved dep graph |
| `mvn help:effective-pom` | Render fully-merged pom (parents + profiles) |

Key plugins: `maven-compiler-plugin` (javac), `maven-surefire-plugin` (unit tests), `maven-failsafe-plugin` (integration tests, `*IT.java`), `maven-shade-plugin` (uber-jar), `maven-jar-plugin` (manifest, main-class).

## Common patterns

### Pattern 1 — Clean package (most common build)

```bash
mvn clean package -DskipTests        # quick artifact, skip test execution
mvn clean verify                     # full build with integration tests
```

### Pattern 2 — Activate a profile

```xml
<!-- pom.xml -->
<profiles>
  <profile>
    <id>release</id>
    <build>...</build>
  </profile>
</profiles>
```

```bash
mvn -P release package
```

### Pattern 3 — Dependency scopes

```xml
<dependency>
  <groupId>org.slf4j</groupId>
  <artifactId>slf4j-api</artifactId>
  <version>2.0.13</version>
  <scope>compile</scope>   <!-- compile (default) | provided | runtime | test | system -->
</dependency>
```

`provided` (e.g. servlet API) is on classpath but not packaged. `test` is JUnit-only. `runtime` is not on compile classpath.

### Pattern 4 — Parent POM + dependencyManagement

```xml
<!-- parent pom.xml -->
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>com.fasterxml.jackson</groupId>
      <artifactId>jackson-bom</artifactId>
      <version>2.17.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

Children declare deps without `<version>`; parent pins it. Single source of truth across modules.

### Pattern 5 — Multi-module reactor build

```xml
<!-- root pom.xml -->
<packaging>pom</packaging>
<modules>
  <module>core</module>
  <module>api</module>
  <module>app</module>
</modules>
```

```bash
mvn -pl app -am package         # build app + its module deps
mvn -T 1C clean install         # parallel, 1 thread / core
```

## Common pitfalls

- **`~/.m2` is ephemeral in the forge** — every fresh container re-downloads the world. Within one session subsequent builds are cached; across stops they are not. Plan first builds to be slow.
- **`-fae` (fail-at-end) hides early failures** — useful for CI summary, painful for iteration. Default fail-fast catches the real bug sooner; switch to `-fae` only for "what else is broken?" surveys.
- **Test phase silently skipped if compile fails** — `mvn test` runs `compile` first; a compile error reports zero tests run, not "tests failed". Always read the BUILD FAILURE line, not just the test summary.
- **Surefire vs failsafe** — surefire (`*Test.java`) runs in `test` phase and fails the build immediately. Failsafe (`*IT.java`) runs in `integration-test` and only fails in `verify`, after `post-integration-test` cleanup. Mixing them up means cleanup never runs.
- **Version conflicts resolve via "nearest wins"** — Maven picks the dep declared closest to your pom in the tree, NOT the highest version. Use `mvn dependency:tree -Dverbose` to see why an older version was chosen, then pin via `dependencyManagement`.
- **Missing `-U` keeps stale SNAPSHOTs** — Maven only re-checks SNAPSHOT deps once per day by default. After a colleague pushes a new `1.0-SNAPSHOT`, you need `mvn -U` or you keep building against yesterday's bytes.
- **Plugin versions are NOT inherited automatically** — declare every plugin's version in `pluginManagement` of the parent. Without it, Maven picks "the latest available" non-deterministically and your build is no longer reproducible.
- **JDK version mismatch silently wrong** — `<maven.compiler.source>` and `<target>` only control javac flags; if `JAVA_HOME` is JDK 11 but you set `<source>21</source>`, you get cryptic "invalid target release" errors. Pin via `<maven.compiler.release>` (JDK 9+) for true cross-compilation.

## Forge-specific

- `~/.m2/repository` is ephemeral. First build of new deps re-downloads through the enclave proxy; subsequent builds in the same forge session are cached.
- The forge can reach Maven Central via the proxy — Maven honours `HTTPS_PROXY` through JVM defaults (`-Dhttps.proxyHost`/`-Dhttps.proxyPort` are auto-set from the env). Custom mirrors must be added to `~/.m2/settings.xml` AND on the proxy allowlist.

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
  - `https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html`
- **License:** see-license-allowlist
- **License URL:** https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/maven.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `languages/java.md` — language reference
- `build/gradle.md` — JVM build alternative
- `runtime/networking.md` — proxy egress + allowlist
- `runtime/forge-container.md` — `~/.m2` ephemerality
