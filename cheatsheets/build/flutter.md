---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://docs.flutter.dev/reference/flutter-cli
  - https://docs.flutter.dev/platform-integration/web/renderers
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Flutter

@trace spec:agent-cheatsheets

## Provenance

- Flutter CLI reference (docs.flutter.dev): <https://docs.flutter.dev/reference/flutter-cli> — official command reference for flutter pub get/upgrade/add, flutter run, flutter build, flutter analyze, flutter test, flutter clean, flutter doctor, flutter devices
- Flutter web rendering docs: <https://docs.flutter.dev/platform-integration/web/renderers> — --web-renderer canvaskit vs html options
- **Last updated:** 2026-04-25

**Version baseline**: Flutter 3.24.5 stable (baked at `/opt/flutter`, on `PATH`).
**Use when**: building Flutter apps in the forge — web + Linux desktop only (no Android, iOS, macOS, Windows tooling in this image).

## Quick reference

| Command | Effect |
|---|---|
| `flutter pub get` | Resolve and fetch deps from `pubspec.yaml` into `.dart_tool/` |
| `flutter pub upgrade` | Upgrade deps to latest semver-compatible versions |
| `flutter pub upgrade --major-versions` | Bump majors (rewrites `pubspec.yaml` constraints) |
| `flutter pub outdated` | Show deps with newer versions available |
| `flutter pub add <pkg>` / `pub remove <pkg>` | Add or drop a dependency |
| `flutter devices` | List available run targets (chrome, linux, web-server) |
| `flutter run -d chrome` | Run app in Chrome with hot reload |
| `flutter run -d linux` | Run app as a native Linux desktop window |
| `flutter run -d web-server --web-port 8080` | Headless web target (useful in forge) |
| `flutter build web --release` | Compile web bundle to `build/web/` |
| `flutter build linux --release` | Compile Linux desktop binary to `build/linux/x64/release/bundle/` |
| `flutter analyze` | Static analysis using `analysis_options.yaml` |
| `flutter test` | Run unit + widget tests under `test/` |
| `flutter test --coverage` | Generate `coverage/lcov.info` |
| `dart format .` / `dart format --set-exit-if-changed .` | Format / verify formatting |
| `flutter clean` | Wipe `build/` and `.dart_tool/` (force full rebuild) |
| `flutter doctor -v` | Diagnose toolchain (expect missing Android/iOS — that is fine here) |

## Common patterns

### Pattern 1 — New project + first run

```bash
flutter create --platforms=web,linux my_app
cd my_app
flutter pub get
flutter run -d chrome
```

### Pattern 2 — Web release build

```bash
flutter build web --release --web-renderer canvaskit
# Output: build/web/  (static, ready for any httpd)
```

Switch `--web-renderer html` for smaller bundle / lower fidelity.

### Pattern 3 — Linux desktop release build

```bash
flutter build linux --release
# Output: build/linux/x64/release/bundle/<app>
```

### Pattern 4 — Static analysis with project rules

```yaml
# analysis_options.yaml
include: package:flutter_lints/flutter.yaml
linter:
  rules:
    prefer_const_constructors: true
    avoid_print: true
```

```bash
flutter analyze            # honours the file above
```

### Pattern 5 — Tests with coverage

```bash
flutter test --coverage
# coverage/lcov.info — feed to genhtml or a CI badge
```

## Common pitfalls

- **No Android / iOS / macOS / Windows toolchains** — image runs `flutter precache --no-android --no-ios --no-macos --no-windows`. `flutter run -d android` / `flutter build apk` / `flutter build ios` will fail. Use a different image for mobile builds.
- **`flutter doctor` shows missing toolchains and that is OK** — red Xs against Android/Xcode/Visual Studio are expected in this forge. Only the "Flutter" and "Linux toolchain" / "Chrome" rows need to be green.
- **`PUB_CACHE` is baked, not `~/.pub-cache`** — image sets `PUB_CACHE=/opt/flutter/.pub-cache` so prefetched packages are reused. Do not point it at `~/.pub-cache` unless you want a cold cache on every container start.
- **`--web-renderer` choice matters** — `canvaskit` (default) ships ~2 MB WASM, pixel-perfect; `html` is smaller but loses some Skia features. Pick at build time, not runtime.
- **Flutter SDK channel is pinned** — image is on `stable`. Do not switch channels (`flutter channel beta`) inside a forge: it tries to mutate `/opt/flutter` and fails.
- **State-management choice is yours** — Flutter ships no opinionated state lib; BLoC, Provider, Riverpod, GetX are all third-party. The forge has none preinstalled — `flutter pub add` brings them in via the proxy.
- **Null safety is mandatory** — Flutter 3.x / Dart 3+ are sound-null-safe. Old packages without null-safety migrations will refuse to resolve; pick a maintained alternative.
- **Hot reload != hot restart** — `r` reloads code preserving state, `R` restarts the app. Changes to `main()`, top-level state, or generics often need `R`.
- **`flutter clean` is heavy in the forge** — it deletes `.dart_tool/` and `build/`, both of which live on the ephemeral overlay. Next `pub get` will re-fetch the world through the proxy.

## Forge-specific

- `/opt/flutter` is read-only image state. Do **NOT** run `flutter upgrade` — it tries to `git pull` inside `/opt/flutter` and fails. SDK bumps happen via the forge `Containerfile`, then a new image build.
- Web + Linux desktop targets only. Mobile (Android/iOS) and other-OS desktop (macOS/Windows) need a different forge image.
- Pub registry pulls go through `tillandsias-proxy`. A "Could not resolve host: pub.dev" error means the proxy allowlist is missing pub.dev / storage.googleapis.com.
- `build/` and `.dart_tool/` live on the ephemeral overlay — lost on container stop. Commit early or rebuild on next attach.

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
  - `https://docs.flutter.dev/reference/flutter-cli`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.flutter.dev/reference/flutter-cli`
- **License:** see-license-allowlist
- **License URL:** https://docs.flutter.dev/reference/flutter-cli

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/docs.flutter.dev/reference/flutter-cli"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://docs.flutter.dev/reference/flutter-cli" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/flutter.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `languages/dart.md` — language reference (syntax, null safety, async)
- `runtime/forge-container.md` — overlay ephemerality, proxy egress
