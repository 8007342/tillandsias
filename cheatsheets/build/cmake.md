---
tags: [build, cmake, c, cpp, cross-platform, generator]
languages: [c, cpp]
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://cmake.org/cmake/help/latest/manual/cmake.1.html
  - https://cmake.org/cmake/help/latest/manual/cmake-commands.7.html
  - https://cmake.org/cmake/help/latest/manual/cmake-generator-expressions.7.html
  - https://cmake.org/cmake/help/latest/manual/cmake-policies.7.html
authority: high
status: current
---

# CMake

@trace spec:agent-cheatsheets

## Provenance

- CMake `cmake(1)` manual: <https://cmake.org/cmake/help/latest/manual/cmake.1.html> — `-S`, `-B`, `-G`, `--build`, `--install` flags
- CMake commands reference: <https://cmake.org/cmake/help/latest/manual/cmake-commands.7.html> — `add_executable`, `add_library`, `target_*`, `find_package`
- Generator expressions: <https://cmake.org/cmake/help/latest/manual/cmake-generator-expressions.7.html> — `$<$<...>:...>` syntax
- CMake policies: <https://cmake.org/cmake/help/latest/manual/cmake-policies.7.html> — `cmake_minimum_required` policy semantics
- **Last updated:** 2026-04-25

**Version baseline**: CMake 3.30+ (Fedora 43 `cmake`).
**Use when**: cross-platform C/C++/CUDA builds; meta-build that generates Make/Ninja/MSVC project files.

## Quick reference

| Command / directive | Effect |
|---|---|
| `cmake -S . -B build` | Configure: read `CMakeLists.txt`, write build tree to `build/` |
| `cmake -S . -B build -G Ninja` | Pick a generator (`Ninja`, `Unix Makefiles`, `Visual Studio 17 2022`) |
| `cmake --build build -j` | Run the configured backend (parallel) |
| `cmake --build build --target foo` | Build a single target |
| `cmake --install build --prefix /tmp/out` | Stage `install()` artifacts to a prefix |
| `ctest --test-dir build --output-on-failure` | Run tests registered with `add_test()` / `gtest_discover_tests` |
| `cmake -DCMAKE_BUILD_TYPE=Release` | Single-config generators only (Make/Ninja) |
| `cmake --build build --config Release` | Multi-config generators (Ninja Multi-Config, MSVC, Xcode) |
| `project(foo LANGUAGES CXX)` | Declare project + enabled languages (must precede targets) |
| `add_executable(app a.cpp b.cpp)` | Define a binary target |
| `add_library(foo STATIC|SHARED|INTERFACE ...)` | Define a library target |
| `target_link_libraries(app PRIVATE foo)` | Link + propagate usage requirements |
| `target_include_directories(foo PUBLIC include/)` | Add include path with scope |
| `target_compile_definitions(foo PRIVATE FOO=1)` | `-DFOO=1` for this target |
| `target_compile_features(foo PUBLIC cxx_std_20)` | Require C++20; preferred over `CMAKE_CXX_STANDARD` |
| `find_package(Pkg REQUIRED)` | Locate a dependency (Config or Find module) |
| `set(CMAKE_PREFIX_PATH /opt/foo)` | Hint where `find_package` should look |

## Common patterns

### Pattern 1 — Minimal modern `CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.30)
project(myapp LANGUAGES CXX)

add_executable(myapp src/main.cpp)
target_compile_features(myapp PRIVATE cxx_std_20)
target_include_directories(myapp PRIVATE include)
```

### Pattern 2 — Out-of-source build (always)

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
ctest --test-dir build --output-on-failure
cmake --install build --prefix dist
```

### Pattern 3 — `find_package` + link

```cmake
find_package(fmt 10 REQUIRED)              # imported target: fmt::fmt
find_package(Threads REQUIRED)             # imported target: Threads::Threads

add_executable(app src/main.cpp)
target_link_libraries(app PRIVATE fmt::fmt Threads::Threads)
```

```bash
cmake -S . -B build -DCMAKE_PREFIX_PATH="/opt/fmt;/opt/abseil"
```

### Pattern 4 — PUBLIC / PRIVATE / INTERFACE scope

```cmake
add_library(net STATIC src/net.cpp)
target_include_directories(net
    PUBLIC  include          # consumers see this
    PRIVATE src)             # only net.cpp sees this
target_link_libraries(net
    PUBLIC  Threads::Threads # consumers also link pthread
    PRIVATE fmt::fmt)        # consumers do NOT pull in fmt
```

### Pattern 5 — Generator expressions

```cmake
target_compile_options(app PRIVATE
    $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic>
    $<$<CXX_COMPILER_ID:MSVC>:/W4>
    $<$<CONFIG:Debug>:-O0 -g3>
    $<$<CONFIG:Release>:-O3 -DNDEBUG>)
```

## Common pitfalls

- **In-source builds pollute the tree** — running `cmake .` litters `CMakeCache.txt`, `CMakeFiles/`, generated Makefiles next to your source. Always use `-B build` (or any sibling directory) and `.gitignore` it. Recovering from an accidental in-source build means `git clean -xdn` first, then `-xdf`.
- **`PUBLIC` / `PRIVATE` / `INTERFACE` confusion** — `PRIVATE` is build-only, `INTERFACE` is consumer-only, `PUBLIC` is both. Wrong scope causes either missing transitive includes (under-specified) or accidental ABI leakage and recompile cascades (over-specified). When in doubt, start `PRIVATE` and promote on demand.
- **`find_package` silently uses the wrong copy** — if `CMAKE_PREFIX_PATH` is unset, CMake searches system paths and may pick up an old distro version. Always pass `-DCMAKE_PREFIX_PATH=...` explicitly, and prefer `REQUIRED` so missing packages fail at configure time, not link time.
- **Old-style global vars vs target-based** — pre-3.x tutorials use `include_directories()`, `add_definitions()`, `link_libraries()`. These leak into every subsequent target in the directory and break composition. Modern CMake (3.x+) is **target-based**: always use `target_*()` siblings.
- **`cmake_minimum_required` controls policy defaults** — bumping the minimum activates new `CMP*` policies which can change behaviour silently (e.g. `CMP0077` for `option()` overriding cached vars). Bump deliberately and read `cmake --help-policy CMP0077` when warnings appear.
- **Single-config vs multi-config generators** — Make/Ninja bake `CMAKE_BUILD_TYPE` at configure time (`-DCMAKE_BUILD_TYPE=Release`). Ninja Multi-Config / MSVC / Xcode pick at build time (`--config Release`). Mixing the two flags wastes time or silently builds the wrong type.
- **`install()` is not `add_custom_command(... POST_BUILD ...)`** — install rules run only on `cmake --install` (or `make install`), not on `cmake --build`. Build-tree binaries may not have RPATHs, stripped symbols, or generated headers that only appear after install.
- **Generator-specific quirks** — Ninja needs `CMAKE_EXPORT_COMPILE_COMMANDS=ON` for `compile_commands.json`; Make does not parallelise per-target by default; MSVC ignores Unix-style `-D` if you forget the `/D` form in raw flags. Test cross-generator before claiming portability.
- **`file(GLOB ...)` for sources is a footgun** — CMake re-globs only at configure time. Adding a new `.cpp` does not trigger a reconfigure; you get `undefined reference` at link. List sources explicitly, or use `CONFIGURE_DEPENDS` and accept the configure-time cost.

## Forge-specific

- CMake itself is part of the forge image; no install needed. `ninja-build` and `make` are also pre-installed.
- Build trees live under `/home/forge/src/<project>/build*/` — ephemeral on container stop. Treat `build/` as throwaway; `CMakeCache.txt` is cheap to regenerate.
- System `find_package` finds only forge-image packages. Vendored deps live in your repo (e.g. `third_party/`) and are wired via `add_subdirectory()` or `FetchContent`.
- `FetchContent_Declare(... GIT_REPOSITORY ...)` reaches GitHub through the enclave proxy. Use `URL https://...` over `GIT_REPOSITORY` when the proxy strips git-protocol headers.

## See also

- `build/make.md`, `build/ninja.md` — generator backends invoked under the hood
- `build/cargo.md` — Rust analogue (no separate configure step)
