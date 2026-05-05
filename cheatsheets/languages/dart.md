---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://dart.dev/language
  - https://api.dart.dev/dart-async/dart-async-library.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Dart

@trace spec:agent-cheatsheets

## Provenance

- Dart language reference (dart.dev): <https://dart.dev/language> — official language tour covering null safety, records, patterns, sealed classes, Future/async/await, Stream, late, mixins, extension methods (verified covers Dart 3.x)
- Dart library reference: <https://api.dart.dev/dart-async/dart-async-library.html> — dart:async (Future, Stream, Completer)
- **Last updated:** 2026-04-25

**Version baseline**: Dart 3.x (bundled with Flutter 3.24.5 at `/opt/flutter/bin/dart`)
**Use when**: writing Dart in the forge, typically alongside Flutter (web + desktop targets only here).

## Quick reference

| Task | Command / syntax |
|------|------------------|
| Run script | `dart run script.dart` |
| REPL-ish | `dart run` (no true REPL; use a `main()` + `dart run`) |
| One-liner | `dart -e "print(DateTime.now());"` (via `dart eval` package) |
| New package | `dart create -t package my_pkg` |
| Resolve deps | `dart pub get` (or `flutter pub get` in a Flutter project) |
| Add dep | `dart pub add http` / `dart pub add --dev test` |
| Run tests | `dart test` (pure Dart) / `flutter test` (Flutter) |
| Format / lint | `dart format .` / `dart analyze` |
| Type-check | `dart analyze` (sound null safety always on in 3.x) |
| Null assert | `value!` (throws if null) |
| Null-aware access | `obj?.field` -> null if obj null |
| Null coalesce | `a ?? b` / assign-if-null `a ??= b` |
| If-null in cascade | `obj?..foo()..bar()` |
| Late init | `late final String x;` (init exactly once before read) |
| Required named | `void f({required int x})` |
| Records (3.0+) | `(int, String) r = (1, 'a'); r.$1;` |
| Patterns (3.0+) | `if (obj case (int x, String y)) { ... }` |
| Switch expr (3.0+) | `final s = switch (x) { 0 => 'zero', _ => 'other' };` |
| Sealed class (3.0+) | `sealed class Shape {}` -> exhaustive switch |
| Const ctor | `const Point(this.x, this.y);` -> compile-time constant |

## Common patterns

### Sound null safety
```dart
String greet(String? name) {
  // ?? gives a default; `!` would throw if null.
  final n = name ?? 'world';
  return 'hi $n';
}

class Cache {
  late final Map<String, int> _data; // initialized lazily, exactly once
  void load(Map<String, int> d) => _data = d;
}
```
`?` on a type allows null; `!` asserts non-null at runtime. `late` defers initialization but locks the variable as non-nullable for callers.

### Class + mixin + extension method
```dart
mixin Loggable {
  void log(String msg) => print('[$runtimeType] $msg');
}

class Service with Loggable {
  void run() => log('running');
}

extension StringX on String {
  String get reversed => split('').reversed.join();
}
// 'abc'.reversed -> 'cba'
```
Mixins compose behavior without single-inheritance limits. Extensions add methods to types you don't own.

### Future + async/await
```dart
Future<int> fetch(int n) async {
  await Future.delayed(const Duration(milliseconds: 100));
  return n * 2;
}

Future<void> main() async {
  // Run in parallel and collect results.
  final results = await Future.wait([fetch(1), fetch(2), fetch(3)]);
  print(results); // [2, 4, 6]
}
```
`async` functions always return a `Future`. `Future.wait` is the parallel join; sequential `await` in a loop is serial.

### Stream basics
```dart
Stream<int> ticks(int n) async* {
  for (var i = 0; i < n; i++) {
    await Future.delayed(const Duration(milliseconds: 50));
    yield i;
  }
}

Future<void> main() async {
  await for (final t in ticks(3)) {
    print(t);
  }
}
```
`async*` + `yield` produces a Stream. Use `await for` to consume; use `.listen()` for fire-and-forget subscriptions.

### Records + pattern matching (3.0+)
```dart
(int, String) parseLine(String s) {
  final parts = s.split(':');
  return (int.parse(parts[0]), parts[1]);
}

void main() {
  final (code, msg) = parseLine('42:hello'); // destructure
  final summary = switch ((code, msg)) {
    (0, _) => 'ok',
    (final c, final m) when c >= 400 => 'err $c: $m',
    _ => 'other',
  };
  print(summary);
}
```
Records are lightweight tuples — no class needed. Patterns destructure in `if-case`, `switch`, and assignments. `sealed` classes make `switch` exhaustive.

## Common pitfalls

- **`Map<K, V?>` vs `Map<K, V>?`** — the first is a map whose values may be null (always present); the second is a map that may itself be null. `m[key]` on `Map<K, V>` returns `V?` regardless — absent keys give null. Don't write `Map<K, V?>` unless null is a meaningful value.
- **`late` initialization traps** — reading a `late` variable before its first assignment throws `LateInitializationError` at runtime, not compile time. Prefer `late final` so the second write is also caught. Avoid `late` when a constructor initializer or `?` would do.
- **Async without `await`** — calling an `async` function without `await` returns the `Future` and silently drops errors. The analyzer flags this as `unawaited_futures`; either `await` it or wrap with `unawaited(...)` from `dart:async` to make the intent explicit.
- **Mixin order matters** — `class C extends A with M1, M2` linearizes as `A -> M1 -> M2 -> C`; later mixins override earlier ones. If two mixins define the same method, the rightmost wins. Reorder with intent, not alphabetically.
- **`const` constructors and mutability** — `const` instances are canonicalized (same args -> same instance). All fields must be `final` and initializable at compile time. Adding a non-final field silently breaks `const` callers with a confusing analyzer error far from the change site.
- **`==` on records compares structurally; on classes, by identity** — `(1, 'a') == (1, 'a')` is `true`, but `Point(1, 2) == Point(1, 2)` is `false` unless you override `==` and `hashCode` (or use a `data class` package / `equatable`).
- **`for (final x in stream)` doesn't exist** — Streams require `await for`. Plain `for-in` works only on `Iterable`. Mixing them is a common copy-paste bug.
- **`int` and `double` in dart2js / web** — on the web, both compile to JS `Number`. `1 is int` and `1.0 is int` can both be true. Don't rely on numeric type checks for web targets; use `.truncate()` / `.round()` explicitly.

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
  - `https://dart.dev/language`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/dart.dev/language`
- **License:** see-license-allowlist
- **License URL:** https://dart.dev/language

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/dart.dev/language"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://dart.dev/language" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/languages/dart.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/flutter.md` — Flutter web + desktop builds
- `runtime/forge-container.md` — no Android/iOS in forge; web + desktop only
