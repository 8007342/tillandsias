# Maven

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

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

## See also

- `languages/java.md` — language reference
- `build/gradle.md` — JVM build alternative
- `runtime/networking.md` — proxy egress + allowlist
- `runtime/forge-container.md` — `~/.m2` ephemerality
