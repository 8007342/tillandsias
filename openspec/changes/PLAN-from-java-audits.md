# Plan: Synthesizing the `../java/` Zen-model audits into Tillandsias OpenSpec changes

**Author:** planning agent (Opus 4.7, 1M context)
**Date:** 2026-04-25
**Status:** DRAFT — pending human greenlight before scaffolding any `openspec new change`.

This plan reads the audits the user produced inside `/var/home/machiyotl/src/java/`
while running Tillandsias-launched experiments, cross-references them with the
current forge/inference image source, and proposes a ranked set of OpenSpec
changes plus the cheatsheet and methodology updates that should ride with them.

---

## 1. Audit Synthesis (top findings)

Findings grouped by theme, each with the audit file it came from and a short
quote for grounding.

### A. The forge is fully loaded but invisible to the model
1. **`tillandsias_audit.md`** caught the forge's tool surface correctly (Rust crate split, `--cap-drop=ALL`, ephemeral `--rm`) — the architecture audit was done from a model that knew what it was looking at. Verdict: "Exceptional foundation." The structural problems are not security; they are visibility.
2. **`ENVIRONMENT_REPORT.md`** — *the same forge a different model attempted to use* — concluded the opposite: "Java/JDK: Not installed in PATH … Maven Central URLs return 404/403 … RxJava JAR must be committed to repository." The model downloaded Adoptium into `.tools/jdk/` and committed JARs into the repo. The forge actually ships `java-21-openjdk-devel`, `maven`, `gradle`, and the proxy allowlists Maven Central — **the model never discovered any of it**. This is the single most important finding: the discoverability gap turns a fully loaded forge into an empty Fedora box from the agent's seat.
3. **`container_enhancements.md` §1.1–1.3, 6.1, 6.3** — explicit asks for: a `tillandsias-inventory` command, `TILLANDSIAS_IMAGE_VERSION`/`TILLANDSIAS_CAPABILITIES` env vars, a "what can you do?" capability guide, a launch banner that lists tools (the welcome banner exists but does not enumerate the 30+ runtimes), and a refcard.

### B. Local-model affordability and routing are undocumented at runtime
4. **`model_affordability_plan.md` §"Current Discoverability Issues"** — "No Model Inventory … No Affordance Mapping … No Hardware Detection." The forge has `OLLAMA_HOST=http://inference:11434` exported but no instructions on which model to invoke for which task.
5. **`local_model_testrun.md`** confirms the empirical side: the model worked out `qwen2.5:0.5b` is fine for routing and `llama3.2:3b` is fine for analysis, but had to **discover this by trial and error against a live ollama server** — a `models.json` registry would have answered it in one read.
6. **`container_enhancements.md` §3.1 + 7.1** — `OLLAMA_HOST` is set but never health-checked; `model-routing.md` mentions the Ollama pool exists but does not enumerate which models are loaded.

### C. Cache discipline gaps cost real bandwidth
7. **`ENVIRONMENT_REPORT.md`** records `lib/log4j-api-2.20.0.jar successfully downloaded (306K)` and `RxJava JAR must be committed`. Both should have been Maven-cache hits. The forge sets `CARGO_HOME`/`GOPATH`/`NPM_CONFIG_PREFIX`/`PYTHONUSERBASE` to `~/.cache/tillandsias/...` (good) but **never sets `MAVEN_OPTS=-Dmaven.repo.local=...`, `GRADLE_USER_HOME=...`, or `PUB_CACHE=...`** (bad). And the forge container has **no `MountSource::CacheDir` mount at all** — `~/.cache/tillandsias` exists on the host (1.6GB models, 834M mirrors, 389M tools-overlay), but only the inference container bind-mounts it. Forge containers re-download every package on every restart for *every* language ecosystem.

### D. Local model availability vs the squid-EOF wall
8. **Project memory `project_squid_ollama_eof.md`** + the existing `entrypoint.sh` of `images/inference/`: T0 + T1 are baked in; T2-T5 try a runtime pull but `the SSL-bump EOFs hard on big manifests`. Models for tier ≥2 essentially never arrive. The user's ask #4 ("lazy pull of additional models once the inference container is launched") collides with this directly — we need a strategy other than "ollama pull through Squid."

### E. Methodology (Nix, OpenSpec, source-of-truth) is not surfaced to the agent
9. **`tillandsias_audit.md` §3.4** identifies Nix flake-based image building as a strength of the project, but inside the forge there is no `nix` binary, no methodology recommending it. The user's ask #8 wants this lifted from "internal Tillandsias-only" to "standard for agent-built projects."
10. **`container_enhancements.md` §2.3** — "OpenSpec is used in the workflow but there's no self-test to verify it's working." The methodology cheatsheet is mounted via `instructions/methodology.md` but never explains *how* to scaffold an OpenSpec change; the model on `../java/` never invoked OpenSpec.

---

## 2. Proposed Change Set (ranked)

Six changes. Listed in dependency order (earliest first). Sizes are rough, in spec lines + LOC.

### CHG-1 — `forge-cache-bind-mounts` *(L)*
**Why.** This is ask #5, "the big one." Forge variants today mount only `ConfigOverlay` and `ContainerLogs`. Add a new `ProfileMount` that bind-mounts `~/.cache/tillandsias/forge/` (host) → `/home/forge/.cache/tillandsias/` (container) `Rw`, then point every per-language cache env var (Maven, Gradle, Pub, Flutter, .npm, pipx state, uv) into a subdir of that path. Verifies cache-hit on second container launch.

**Capabilities touched.** MODIFIED `default-image`, `forge-shell-tools`, `podman-orchestration`. NEW `forge-cache-binds`.

**Dependencies.** None.

**Open questions.**
- Should each project get its own forge cache subdir (`~/.cache/tillandsias/forge/<project>/`) for namespace cleanliness, or one shared cache for multi-project hit-rate? Recommendation: one shared, per-language subdirs (cargo, maven, gradle, pub, npm, pip, uv-cache).
- `chown` semantics under `--userns=keep-id` — host paths must be writable by host UID; we already do this for `mirrors/` so the pattern exists.

**Estimated effort.** 1.5–2 days.

---

### CHG-2 — `forge-environment-discoverability` *(M)*
**Why.** Ask #2, #3, and the `ENVIRONMENT_REPORT.md` blind-spot. Bake into the forge: `tillandsias-inventory` (lists every runtime + version), `tillandsias-services` (web-services port table from `web-services.md`), `tillandsias-models` (curls inference, prints loaded models with tier), and `TILLANDSIAS_IMAGE_VERSION`/`TILLANDSIAS_CAPABILITIES` env vars set at image-build time. Update `forge-welcome.sh` to enumerate the loaded runtimes (one line each) and surface the inventory command. Update the OpenCode methodology instruction to tell the model **on first turn**: "Run `tillandsias-inventory`. Read `$TILLANDSIAS_CHEATSHEETS/INDEX.md`. Do not assume tools are missing."

**Capabilities touched.** MODIFIED `default-image`, `forge-welcome`, `environment-runtime`, `agent-cheatsheets`.

**Dependencies.** Independent of CHG-1, but ships with the same forge image rebuild.

**Open questions.**
- `tillandsias-inventory` as Bash script or Rust binary baked into the image? Recommend Bash — zero compile cost, easy to read, matches existing `forge-welcome.sh` style.
- Should the welcome banner *enumerate* runtimes or just point to `tillandsias-inventory`? Recommend enumerate (one short row per category) — agents read welcome output before they read anything else.

**Estimated effort.** 2–3 days.

---

### CHG-3 — `forge-opencode-methodology-overhaul` *(M)*
**Why.** Ask #2 + #3. Today `instructions/methodology.md` is 36 lines of generalities. The model in `ENVIRONMENT_REPORT.md` never even tried `which java` because the methodology never told it to. Replace with a structured, action-first methodology that covers: (a) first-turn discovery sequence (inventory → cheatsheets → existing openspec changes), (b) cache discipline (do not re-download — paths are bind-mounted), (c) Nix-first recommendation for new projects (ask #8), (d) when to delegate to Ollama vs Zen, (e) the OpenSpec workflow with a worked example (one paragraph per step). Add `instructions/forge-discovery.md` and `instructions/cache-discipline.md` so the methodology is decomposed and individually load-bearing.

**Capabilities touched.** MODIFIED `default-image` (config-overlay change). NEW capability: `forge-opencode-onboarding`.

**Dependencies.** CHG-2 (the methodology references the new commands).

**Open questions.**
- Do we keep `methodology.md` as a single file or split into the four discovery/cache/nix/openspec sub-files referenced in `config.json`? Recommend split — opencode loads them all and split files survive cheatsheet drift better.
- Should the methodology link the `@trace spec:...` URL pattern from CLAUDE.md? Yes — it is currently invisible to anyone reading just the in-forge instructions.

**Estimated effort.** 2 days.

---

### CHG-4 — `inference-lazy-pull-via-host` *(L)*
**Why.** Asks #4 + #5. The current entrypoint already attempts T2+ pulls in the background but `project_squid_ollama_eof.md` says they fail. Two changes here:

1. **Move the lazy pull off the squid path.** Instead of `ollama pull` inside the inference container (which goes through `proxy:3128` and EOFs), have the *host-side* tray binary pull tier-appropriate models directly using its own network into `~/.cache/tillandsias/models/` (already bind-mounted into the inference container), then the inference container picks them up at next list. Triggered by a tray-side background task spawned right after `inference` reports "ready." Pull tier is decided host-side from `gpu.rs`'s VRAM detection, which is more authoritative than `nvidia-smi` inside the container.
2. **Persist baked manifests properly.** The current `cp -an /opt/baked-models/. $OLLAMA_MODELS/` happens only when `manifests/.../qwen2.5/0.5b` is missing — but if the host cache exists from a previous host install, the seed never runs and T0/T1 may also be missing if the user wiped models. Make the seed unconditional-but-no-clobber per file, and verify both T0 and T1 manifest files individually.

**Capabilities touched.** MODIFIED `inference-container`. NEW capability: `inference-host-side-pull`.

**Dependencies.** None — orthogonal to forge changes.

**Open questions.**
- Where does the tray-side pull live in source? `src-tauri/src/handlers.rs` or a new `inference_lazy_pull.rs`? Recommend new file, called from the existing inference startup path.
- Do we expose a tray menu item "Pull more local models"? Probably yes — power users want it. AJ never sees it.
- Models to lazy-pull per tier (audit-cited): T2=`qwen2.5-coder:7b` (dropping `qwen2.5:7b` — the audit prefers the coder variant), T3=`qwen2.5-coder:14b`, T4=`gpt-oss:20b`, T5=`qwen2.5-coder:32b`. Pulled directly from `registry.ollama.ai` over the host's existing network. Need user to confirm preferred T2-T5 list.
- Time-to-completion: a 7B is ~4GB, 14B ~9GB, 32B ~20GB. On a typical home connection this is hours. Need a progress indicator and a cancellable flag in the lazy-pull state.

**Estimated effort.** 3–4 days.

---

### CHG-5 — `forge-bake-nix` *(M)*
**Why.** Ask #8. Add `nix` (single-user mode), `direnv`, `nix-direnv` to the forge image, set up `/etc/nix/nix.conf` with `experimental-features = nix-command flakes`, point the nix store at a bind-mounted host cache (`~/.cache/tillandsias/forge/nix/`) so flakes survive container restarts, and update the methodology to recommend Nix flakes for any new project the agent scaffolds. Add a `cheatsheets/build/nix.md` cheatsheet (with proper provenance).

**Capabilities touched.** MODIFIED `default-image`, `forge-shell-tools`, `forge-opencode-onboarding`. NEW: `forge-nix-toolchain`.

**Dependencies.** CHG-1 (nix store needs the cache mount), CHG-3 (methodology references nix-first).

**Open questions.**
- Single-user nix vs root-required daemon? Forge runs as UID 1000, no sudo — so single-user nix only. Confirm that's OK (it limits parallel builds but matches the ephemeral model).
- Do we pre-warm the nix store with anything (nixpkgs metadata?) at image-build time, or accept the first-flake cold start? Recommend pre-warm `nixpkgs` channel index only — full pkg pre-build defeats the cache-on-host design.
- direnv will want to source `.envrc` automatically — that requires shell hooks in bashrc/zshrc/config.fish. Already a place for that, low risk.

**Estimated effort.** 2–3 days.

---

### CHG-6 — `cheatsheet-bake-priority-batch` *(M)*
**Why.** Ask #6 + #7. The audits expose specific cheatsheet gaps (Java best-practices for the `../java/` test case, protobuf naming and file-hierarchy guidance, model affordability, nix). Provenance-mandatory means each cheatsheet must cite a high-authority source and ship without the DRAFT banner. This change ships **only the new ones load-bearing for this initiative**; a separate sweep can re-provenance the existing DRAFT files. See §3 below for the list.

**Capabilities touched.** MODIFIED `agent-cheatsheets`, `default-image` (re-COPY of `cheatsheets/`).

**Dependencies.** CHG-2 (`tillandsias-inventory` + welcome banner reference some of these). CHG-5 (nix cheatsheet ships with the nix change).

**Open questions.**
- Single change for all 6 cheatsheets, or one change per cheatsheet? Recommend single change — they share provenance methodology and one cheatsheet rebuild.
- Should this change include re-provenancing the existing DRAFT cheatsheets? No — separate `cheatsheet-provenance-sweep` change. Otherwise it never ends.

**Estimated effort.** 3 days (most of the time is sourcing + verifying provenance URLs).

---

## 3. Cheatsheet Plan

**Six new cheatsheets to ship with this initiative.** All ship without the DRAFT banner; all cite high-authority sources with `**Last updated:** 2026-04-25`.

| # | Title | Category | Sources to cite | Why load-bearing |
|---|---|---|---|---|
| 1 | `build/nix.md` | build | nixos.org/manual/nix/stable, nix.dev, NixOS/nixpkgs README | Required by CHG-5; methodology recommends Nix-first. |
| 2 | `agents/model-affordability.md` | agents | ollama.com/library, the Qwen2.5 / Llama 3.2 model cards on HuggingFace | Replaces the gap `model_affordability_plan.md` documented; lists tiers + invocation strings. |
| 3 | `languages/java-best-practices.md` | languages | docs.oracle.com/en/java/javase/21/, openjdk.org JEP index, Effective Java (citation only — book) | The `../java/` model failed because Java best-practice was nowhere. Beyond syntax — covers records, sealed classes, virtual threads, `try-with-resources`, packaging conventions. |
| 4 | `web/protobuf-style.md` | web | protobuf.dev/programming-guides/style/, protobuf.dev/programming-guides/proto3/ | Ask #7 — naming conventions, file hierarchy (one message per file, package layout, `option java_package`), versioning. |
| 5 | `runtime/forge-cache-discipline.md` | runtime | None external (this is project policy) — cite `images/default/Containerfile` and the spec from CHG-1 | Required by CHG-3 methodology — tells agent which env vars are persistent and never to commit downloaded JARs. |
| 6 | `runtime/forge-tool-discovery.md` | runtime | None external (project policy) — cite spec from CHG-2 | The "first thing you do in the forge" cheatsheet — `tillandsias-inventory`, `INDEX.md`, etc. |

Existing `languages/java.md` (currently DRAFT) should be **replaced or merged** with #3 above as part of CHG-6 — the user explicitly asked for "brief single-page version of the language API … as well as best practices."

---

## 4. Cache Discipline Audit

Cached download paths actually **persisted** today (host bind mount `~/.cache/tillandsias/...`):

| Path | Size now | Bind-mounted to forge? | Used? |
|---|---|---|---|
| `~/.cache/tillandsias/models/` | 2.3 GB | Inference only | yes (Ollama) |
| `~/.cache/tillandsias/mirrors/` | 834 MB | Git-service only | yes (git mirror clones) |
| `~/.cache/tillandsias/proxy-cache/` | 4 KB | Proxy only | yes (Squid spool) |
| `~/.cache/tillandsias/openspec/` | 16 MB | Tray only | yes |
| `~/.cache/tillandsias/opencode/` | 160 MB | Tray only | yes (session db) |
| `~/.cache/tillandsias/tools-overlay/` | 389 MB | nothing now | tombstoned 2026-04-25 |
| `~/.cache/tillandsias/secrets/` | 8 KB | git-service only | yes |
| `~/.cache/tillandsias/appimage-builder/` | 2 GB | nothing | host-only build artifact |

Cached download paths **NOT persisted** today (re-downloaded every container launch — these are the leak):

| Inside the forge | Env var set in shell? | Bind-mounted? | Re-downloaded on restart? |
|---|---|---|---|
| `~/.cache/tillandsias/cargo/` | Yes (bashrc/zshrc/fish) | **NO** | YES — every `cargo build` |
| `~/.cache/tillandsias/go/` | Yes | **NO** | YES — every `go get` |
| `~/.cache/tillandsias/npm-global/` | Yes | **NO** | YES — every `npm install -g` |
| `~/.cache/tillandsias/pip/` | Yes | **NO** | YES — every `pip install` |
| Maven `~/.m2/` | **NO env var set** | NO | YES — every `mvn package` |
| Gradle `~/.gradle/` | **NO env var set** | NO | YES — every `gradle build` |
| Flutter `PUB_CACHE` | Set to `/opt/flutter/.pub-cache` (image-state) | NO | YES — every new dep |
| `~/.cache/yarn/`, `~/.cache/pnpm/` | NO | NO | YES |
| `uv` cache | NO | NO | YES |

**The fix is structural** (CHG-1): one new `MountSource::CacheDir` mount on the forge profile + one consistent root path + one set of env vars in `lib-common.sh` covering Maven (`MAVEN_OPTS=-Dmaven.repo.local=$CACHE/maven`), Gradle (`GRADLE_USER_HOME=$CACHE/gradle`), Flutter (`PUB_CACHE=$CACHE/flutter-pub`), yarn/pnpm, uv.

The user is right that this is a **big one**. The waste is per-language-ecosystem, repeated on every attach.

---

## 5. Lazy Model Pull Design

### Models to pull (per tier, audit-cited)
| Tier | Model | Size | Source |
|---|---|---|---|
| T0 | `qwen2.5:0.5b` | 400 MB | already baked |
| T1 | `llama3.2:3b` | 2 GB | already baked |
| T2 | `qwen2.5-coder:7b` | 4.4 GB | lazy pull (audit prefers coder over generic) |
| T3 | `qwen2.5-coder:14b` | 8.9 GB | lazy pull |
| T4 | `gpt-oss:20b` | 12 GB | lazy pull (per `config.json` — already enumerated) |
| T5 | `qwen2.5-coder:32b` | 20 GB | lazy pull |

### Where they go
- **Baked (T0+T1):** `/opt/baked-models/` inside the inference image (built into image). Seeded into the runtime cache on first run.
- **Lazy (T2+):** Pulled by **host tray**, not by container — direct to `~/.cache/tillandsias/models/`, which is bind-mounted into the inference container. Avoids Squid SSL-bump entirely.

### Avoiding the squid-EOF
Two layers of defence:
1. **Host-side pull** (CHG-4 design above) — never goes through Squid.
2. **If a future change does need in-container pulls,** add `registry.ollama.ai` to a Squid bypass list (or set `NO_PROXY=registry.ollama.ai` for the inference container only). Document this as a known workaround in `cheatsheets/runtime/networking.md`.

### Trigger
- Inference container reports ready → tray spawns lazy-pull task → tier decided from host VRAM (already in `gpu.rs`) → `ollama pull` invoked from a small spawned binary that writes to `~/.cache/tillandsias/models/` directly. The existing `OLLAMA_MODELS=$cache_path` host invocation works because ollama uses the same on-disk schema host- and container-side.

### Cache-hit checklist
- `manifests/registry.ollama.ai/library/<name>/<tag>` exists → skip pull.
- `blobs/sha256-<digest>` size matches manifest → already complete.
- Otherwise resume (ollama pull is resumable).

---

## 6. Nix-in-forge Plan

### Packages to bake
- `nix` (single-user mode, no daemon — forge has no root)
- `direnv`
- `nix-direnv` (the `.envrc` shim that integrates direnv with `nix develop` flakes)
- **NOT** `nixpkgs` checkout — too big, fetched on first flake use into `~/.cache/tillandsias/forge/nix/`.

### Methodology language to add to `~/src/tillandsias/CLAUDE.md`
Under the existing `## OpenSpec — Monotonic Convergence` section, add a sibling:

> ## Nix-First for New Projects
>
> When the user asks the agent to scaffold a new project from scratch inside
> a forge container, the agent SHOULD propose a Nix flake (`flake.nix` +
> `.envrc` with `use flake`) as the build/dev-shell layer. Nix gives the
> project: reproducibility across host machines, hermetic dev shells, and a
> no-surprise contract about which tools are required.
>
> The forge ships `nix`, `direnv`, and `nix-direnv` pre-installed, with the
> store bind-mounted to `~/.cache/tillandsias/forge/nix/` so flake closures
> persist across container restarts.
>
> Existing projects without a flake are fine — do not retrofit unless the
> user asks. The recommendation is for **new** projects.

### Cheatsheet
`cheatsheets/build/nix.md` (already in the cheatsheet plan, item #1). Cites
nixos.org/manual/nix/stable + nix.dev + a brief "your first flake" pattern
covering `flake.nix`, `flake.lock`, `nix develop`, `direnv`'s `use flake`.

---

## 7. Clarifying Questions for the User (≤10)

1. **Cache scope** — one shared host cache (`~/.cache/tillandsias/forge/`) for all projects, or per-project (`~/.cache/tillandsias/forge/<project>/`)? Recommendation: shared, sub-divided per language. Confirm.
2. **Model tiers to lazy-pull** — confirm T2-T5 list above (coder variants for T2/T3/T5, `gpt-oss:20b` for T4). Or: do you want a different mix (e.g., always `qwen2.5-coder` family, or include `mistral-large` somewhere)?
3. **Lazy-pull tray UX** — surface as a tray menu item ("Pull more local models"), or fully automatic based on VRAM detection? Or both (auto-trigger but show progress in tray)?
4. **Cheatsheet sweep scope** — CHG-6 ships only the 6 new cheatsheets needed for this initiative. Should we also ride along a re-provenance sweep of the existing DRAFT files, or split that into its own change later? Recommendation: split.
5. **Methodology split** — should `instructions/methodology.md` stay as one file, or split into `methodology.md` + `forge-discovery.md` + `cache-discipline.md` + `nix-first.md`? (opencode loads all listed instructions.)
6. **Nix bake size** — single-user nix adds ~50MB to the forge image. Acceptable, or should the forge stay leaner and let the user opt-in via a per-project install? Recommendation: bake — discoverability requires it being on PATH.
7. **`tillandsias-inventory` format** — plain text columns like the audit's example, or grep-friendly KEY=VALUE lines? Or both (text by default, `--json` for scripts)?
8. **Web-services discoverability** — `web-services.md` instruction file already exists; should `tillandsias-services` command duplicate it (single source of truth via `awk`) or just print a hardcoded table? Recommendation: parse the markdown table to stay single-sourced.
9. **OpenSpec self-test** — `container_enhancements.md` §2.3 wants `openspec --version` at startup. Add to entrypoint or skip (the welcome banner could `which openspec` instead)?
10. **Tombstone behavior for the `.tools/jdk/` pattern** — the `../java/` test committed a 200MB JDK because the model didn't know one was installed. Do we want a *forge guard* that warns when `lib/*.jar` or `.tools/` is `git add`-ed, suggesting the model use the in-forge tools? (Could be a git pre-commit hook in the agent overlay.) This goes beyond the audits' explicit asks but addresses the underlying anti-pattern.

---

## 8. Effort & Sequencing

**Total estimate: 14–17 working days** of focused work, spread across 6 OpenSpec changes.

Suggested order (respecting dependencies):

1. **CHG-1** `forge-cache-bind-mounts` — foundation, biggest impact (1.5–2 d).
2. **CHG-2** `forge-environment-discoverability` — unblocks methodology (2–3 d).
3. **CHG-3** `forge-opencode-methodology-overhaul` — depends on CHG-2 (2 d).
4. **CHG-6** `cheatsheet-bake-priority-batch` — partial; ships first 5 cheatsheets, defers nix.md to CHG-5 (3 d).
5. **CHG-5** `forge-bake-nix` — depends on CHG-1 + CHG-3 (2–3 d). Ships `nix.md` cheatsheet.
6. **CHG-4** `inference-lazy-pull-via-host` — orthogonal, slot in last to avoid blocking the others (3–4 d).

Between CHG-3 and CHG-5: rebuild the forge image, verify in a real attach session that the model can find tools without prompting (regression test against the `../java/` failure mode).

---

## 9. What this plan does NOT do

- Does not address tray/icon/router work — out of scope per audit content.
- Does not retrofit `## Sources of Truth` to existing specs — that's `agent-source-of-truth` change, already in flight.
- Does not propose health checks for all containers (audit §5.3) — useful but not in the user's explicit asks; defer to a separate hygiene change.
- Does not propose audit logging (audit §5.4) or container resource limits (§5.5) — same reasoning.
- Does not change anything about the credential isolation model — the audits explicitly call it "exemplary" and "no critical security issues."

---

*End of plan. Awaiting greenlight before invoking `openspec new change` for any of CHG-1 through CHG-6.*
