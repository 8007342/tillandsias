---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://docs.oracle.com/en/java/javase/21/docs/api/
  - https://docs.oracle.com/javase/specs/jls/se21/html/index.html
  - https://openjdk.org/jeps/444
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Java

@trace spec:agent-cheatsheets

## Provenance

- OpenJDK 21 API documentation: <https://docs.oracle.com/en/java/javase/21/docs/api/> — covers records (java.lang.Record), sealed interfaces, virtual threads (Executors.newVirtualThreadPerTaskExecutor, JEP 444), Stream/Collectors, CompletableFuture, java.nio.file, java.time, java.net.http.HttpClient
- Java Language Specification (Java SE 21): <https://docs.oracle.com/javase/specs/jls/se21/html/index.html> — sealed classes (§8.1.1.2), records (§8.10), pattern-matching switch (§14.11.1), text blocks
- JEP 444 — Virtual Threads (final, JDK 21): <https://openjdk.org/jeps/444> — virtual thread semantics and Executors.newVirtualThreadPerTaskExecutor()
- **Last updated:** 2026-04-25

**Version baseline**: Java 21 LTS (OpenJDK from Fedora 43 `java-21-openjdk-devel`)
**Use when**: writing Java in the forge — modern syntax, common stdlib, patterns.

## Quick reference

| Command / Pattern | Effect |
|---|---|
| `java --version` | Confirms OpenJDK 21 LTS |
| `javac --enable-preview --release 21 Foo.java` | Compile single file with preview features |
| `java --source 21 Foo.java` | Run a single source-file program (no `javac` step) |
| `jshell` | Interactive REPL — fastest way to test a snippet |
| `mvn package` | Maven build — produces `target/*.jar` |
| `gradle build` | Gradle build — produces `build/libs/*.jar` |
| `jpackage --type app-image …` | Bundle a runtime + app (rarely needed in forge) |

| Layout | Convention |
|---|---|
| Source root | `src/main/java/<pkg>/Foo.java` |
| Tests | `src/test/java/<pkg>/FooTest.java` |
| Resources | `src/main/resources/` (loaded via `getResourceAsStream`) |
| Module file | `src/main/java/module-info.java` (only if using JPMS) |

| Stdlib import | Used for |
|---|---|
| `java.util.{List,Map,Set,Optional}` | Collections, null-safety wrapper |
| `java.util.stream.{Stream,Collectors}` | Functional pipelines |
| `java.util.concurrent.{Executors,CompletableFuture}` | Threads, async |
| `java.nio.file.{Path,Files}` | Modern filesystem API (prefer over `java.io.File`) |
| `java.time.{Instant,Duration,LocalDate}` | Use this, never `java.util.Date` |
| `java.net.http.HttpClient` | Built-in HTTP/2 client, no Apache HttpClient needed |

## Common patterns

### Pattern 1 — records for value types

```java
public record Point(double x, double y) {
    public double distance(Point other) {
        return Math.hypot(x - other.x, y - other.y);
    }
}
```

Records auto-generate `equals`, `hashCode`, `toString`, accessors. Immutable by default. Reach for records anywhere you'd write a "data class" or DTO.

### Pattern 2 — sealed types + pattern-matching switch

```java
sealed interface Shape permits Circle, Square, Triangle {}
record Circle(double r) implements Shape {}
record Square(double side) implements Shape {}
record Triangle(double base, double h) implements Shape {}

static double area(Shape s) {
    return switch (s) {
        case Circle c    -> Math.PI * c.r() * c.r();
        case Square sq   -> sq.side() * sq.side();
        case Triangle t  -> 0.5 * t.base() * t.h();
    };
}
```

Compiler enforces exhaustiveness — no `default` needed when all permitted subtypes are covered. Adding a new variant is a compile error until every switch is updated.

### Pattern 3 — virtual threads for blocking I/O

```java
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    var futures = urls.stream()
        .map(url -> executor.submit(() -> fetch(url)))
        .toList();
    for (var f : futures) System.out.println(f.get());
}
```

Virtual threads are cheap (~KB each, not MB). Use them for blocking I/O — HTTP, JDBC, file reads. Do NOT use for CPU-bound work (use a fixed pool).

### Pattern 4 — Stream pipelines

```java
Map<String, Long> counts = words.stream()
    .filter(w -> !w.isBlank())
    .map(String::toLowerCase)
    .collect(Collectors.groupingBy(w -> w, Collectors.counting()));
```

Prefer `toList()` (Java 16+) over `collect(Collectors.toList())` for terminal collection. Streams are single-use — re-build, don't reuse.

### Pattern 5 — Optional for return values

```java
public Optional<User> findById(long id) {
    return Optional.ofNullable(cache.get(id));
}

User u = repo.findById(42)
    .or(() -> repo.fetchRemote(42))
    .orElseThrow(() -> new NotFoundException("user 42"));
```

Use `Optional` ONLY as a return type for "may be absent" results. Never as a field, parameter, or in collections.

## Common pitfalls

- **NPE from autoboxing** — `Integer i = map.get(missing); int x = i;` throws NPE on the unbox. Use `int x = map.getOrDefault(missing, 0);` or check first.
- **`Optional` misused as a field or parameter** — adds heap allocation, breaks serialization, signals confused design. `Optional` is for return values from queries that may have no result.
- **Mutable static state** — `static List<Foo> CACHE = new ArrayList<>();` is a thread-safety bomb and survives across tests. Use `ConcurrentHashMap`, dependency injection, or per-request scope.
- **`equals`/`hashCode` contract** — overriding one without the other breaks `HashMap`/`HashSet`. Records do this for you; for classes, generate both with the IDE or use `Objects.equals` + `Objects.hash`.
- **Swallowed exceptions** — `catch (Exception e) {}` or `catch (Exception e) { e.printStackTrace(); }` hides bugs. Either rethrow (wrap as `RuntimeException` if needed) or log with a real logger and continue deliberately.
- **`==` vs `.equals()` on strings** — `"foo" == someString` works for literals (string pool) but fails for runtime-built strings. Always use `.equals()` or `Objects.equals()`.
- **Forgetting try-with-resources** — leaking file handles, sockets, JDBC connections. Anything implementing `AutoCloseable` belongs in `try (var x = …)`.
- **Mixing `java.util.Date` with `java.time`** — `Date` is mutable, timezone-confused, and deprecated in spirit. Use `Instant` for timestamps, `LocalDate`/`LocalDateTime` for wall-clock, `ZonedDateTime` only when zones matter.
- **Checked exceptions in lambdas** — `stream().map(p -> Files.readString(p))` won't compile. Wrap in a helper that converts to `UncheckedIOException`, or use a try/catch inside the lambda.

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
  - `https://docs.oracle.com/en/java/javase/21/docs/api/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.oracle.com/en/java/javase/21/docs/api/`
- **License:** see-license-allowlist
- **License URL:** https://docs.oracle.com/en/java/javase/21/docs/api/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.oracle.com/en/java/javase/21/docs/api/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://docs.oracle.com/en/java/javase/21/docs/api/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/languages/java.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/maven.md` — Maven lifecycle, dependencies
- `build/gradle.md` — Gradle 8.x build script
- `test/junit.md` — JUnit 5 testing
- `runtime/forge-container.md` — `~/.m2` ephemeral; commit deps to lockfile
