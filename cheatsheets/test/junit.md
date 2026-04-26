# JUnit 5 (Jupiter)

@trace spec:agent-cheatsheets

**Version baseline**: JUnit 5.10+ (Jupiter API). Pulled via Maven/Gradle dependency, not baked into the forge image.
**Use when**: testing Java code — unit tests through Surefire, integration tests through Failsafe.

## Provenance

- JUnit 5 user guide (official, docs.junit.org): <https://docs.junit.org/current/user-guide/> — annotations, assertions, parameterized tests, extensions, lifecycle
- JUnit 5 Javadoc API reference: <https://junit.org/junit5/docs/current/api/> — `org.junit.jupiter.api.*` and `org.junit.jupiter.params.*`
- **Last updated:** 2026-04-25

Verified: `@Test`, `@BeforeEach`, `@AfterEach`, `@BeforeAll`, `@AfterAll`, `@Disabled`, `@Nested`, `@Tag`, `@ParameterizedTest`, `@ValueSource`, `@CsvSource`, `@MethodSource`, `@TestFactory`, `@ExtendWith`, `@Timeout`, `@TestInstance`, `assertAll`, `assertThrows`, `assumeTrue` all documented in the JUnit 5 user guide (sections: Annotations, Assertions, Parameterized Tests, Extensions, Timeouts).

## Quick reference

| Annotation / API | Effect |
|---|---|
| `@Test` | Mark a method as a test case |
| `@BeforeEach` / `@AfterEach` | Run before/after every `@Test` in the class |
| `@BeforeAll` / `@AfterAll` | Run once per class — must be `static` (unless `PER_CLASS`) |
| `@DisplayName("...")` | Human-readable name in reports |
| `@Disabled("reason")` | Skip a test or class |
| `@Nested` | Group related tests in an inner class |
| `@Tag("slow")` | Filter at runtime via `-Dgroups=slow` |
| `@ParameterizedTest` | Run the same test with multiple inputs |
| `@ValueSource(ints = {1,2,3})` | Inline literal arguments |
| `@CsvSource({"a,1", "b,2"})` | Inline rows of arguments |
| `@MethodSource("provider")` | Pull arguments from a static method returning `Stream<Arguments>` |
| `@TestFactory` | Generate `DynamicTest` instances at runtime |
| `@ExtendWith(MyExt.class)` | Hook in a custom `Extension` |
| `@Timeout(5)` | Fail if the test exceeds 5 seconds |
| `@TestInstance(PER_CLASS)` | One instance per class — allows non-static `@BeforeAll` |
| `assertEquals(exp, act)` | Equality check |
| `assertThrows(Ex.class, () -> ...)` | Assert + capture an exception |
| `assertAll(() -> ..., () -> ...)` | Group assertions; report all failures |
| `assertTimeout(Duration.ofSeconds(2), () -> ...)` | Assert lambda finishes in time |
| `assumeTrue(cond)` | Skip rather than fail when precondition unmet |

Imports live under `org.junit.jupiter.api.*` and `org.junit.jupiter.params.*`. The legacy JUnit 4 package `org.junit.*` is a different framework — do not mix.

## Common patterns

### Pattern 1 — Parameterized test with multiple sources

```java
@ParameterizedTest(name = "{0} squared = {1}")
@CsvSource({"2,4", "3,9", "4,16"})
void squares(int input, int expected) {
    assertEquals(expected, input * input);
}

@ParameterizedTest
@MethodSource("primes")
void isPrime(int n) { assertTrue(Primes.test(n)); }

static Stream<Arguments> primes() {
    return Stream.of(arguments(2), arguments(3), arguments(5));
}
```

`@ValueSource` for a single literal column, `@CsvSource` for tabular rows, `@MethodSource` for objects or large datasets.

### Pattern 2 — Custom extension via `@ExtendWith`

```java
@ExtendWith(MockitoExtension.class)
class UserServiceTest {
    @Mock UserRepo repo;
    @InjectMocks UserService svc;

    @Test void findsUser() { /* ... */ }
}
```

Extensions replace JUnit 4 `@RunWith` + `@Rule`. Stack multiple with `@ExtendWith({A.class, B.class})`.

### Pattern 3 — Assertion grouping with `assertAll`

```java
@Test
void address() {
    var a = new Address("1 Main", "Boston", "MA");
    assertAll("address",
        () -> assertEquals("1 Main", a.street()),
        () -> assertEquals("Boston", a.city()),
        () -> assertEquals("MA", a.state()));
}
```

All lambdas execute even if one fails — the report lists every failure rather than stopping at the first.

### Pattern 4 — Dynamic tests via `@TestFactory`

```java
@TestFactory
Stream<DynamicTest> palindromes() {
    return Stream.of("racecar", "level", "noon")
        .map(s -> dynamicTest("is palindrome: " + s,
            () -> assertEquals(s, new StringBuilder(s).reverse().toString())));
}
```

Use when the set of cases is computed (e.g. files in a directory) rather than known at compile time.

### Pattern 5 — Per-class lifecycle for shared expensive setup

```java
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class DatabaseTest {
    Connection conn;

    @BeforeAll                       // no `static` needed
    void openDb() { conn = DriverManager.getConnection(...); }

    @AfterAll
    void closeDb() throws SQLException { conn.close(); }
}
```

Default lifecycle is `PER_METHOD` (a fresh instance per test). `PER_CLASS` reuses one instance — convenient but tests now share state.

## Common pitfalls

- **JUnit 4 vs Jupiter imports** — `org.junit.Test` (JUnit 4) and `org.junit.jupiter.api.Test` (JUnit 5) are different annotations from different frameworks. Mixing them silently means half your tests never run; the IDE shows green because the JUnit 4 ones are picked up by the vintage engine if present, dropped otherwise.
- **Surefire vs Failsafe naming** — Surefire scans `*Test.java`, `Test*.java`, `*Tests.java`; Failsafe scans `*IT.java`, `IT*.java`. Name an integration test `FooTest` and Surefire runs it during `mvn test`, before your container fixtures (`pre-integration-test`) are up — flaky failures.
- **`@BeforeAll` must be `static`** — under default `PER_METHOD` lifecycle, JUnit cannot call an instance method before the instance exists. Either add `static` or annotate the class with `@TestInstance(PER_CLASS)`. The error message is clear; the surprise is that it compiles.
- **Mixing AssertJ and Hamcrest matchers** — both ship `assertThat`. Importing both yields ambiguous-method compile errors or, worse, the wrong overload at runtime. Pick one matcher library per module and stick with it.
- **Parameterized name interpolation requires the `name` attribute** — `@ParameterizedTest` alone reports `[1]`, `[2]`, … which is useless on failure. Always set `@ParameterizedTest(name = "{0} -> {1}")` so failures identify the row.
- **`@Test void` returning a value compiles but isn't a test** — Jupiter requires `void`; a non-void test method is silently ignored by the engine. The IDE may show a green icon next to it because annotation presence ≠ execution.
- **`assertThrows` swallows the exception** — the assertion succeeds and returns the captured exception; if you want to assert on its message or cause, capture and inspect: `var ex = assertThrows(...); assertEquals("...", ex.getMessage());`.
- **`@Disabled` without a reason rots silently** — six months later nobody remembers why. Always pass a string: `@Disabled("flaky on CI, see #1234")`.

## See also

- `languages/java.md` — language reference
- `build/maven.md` — Surefire/Failsafe runner integration
- `build/gradle.md` — `useJUnitPlatform()` task configuration
