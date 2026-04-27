# default-image Specification

## ADDED Requirements

### Requirement: Forge image build pipeline includes a cheatsheet fetch-and-bake stage

`scripts/build-image.sh forge` SHALL run a fetch-and-bake stage immediately before the existing cheatsheet staging step (the `COPY cheatsheets/ /opt/cheatsheets-image/` step established by `default-image`). The fetch-and-bake stage SHALL:

1. Read every cheatsheet's frontmatter under `cheatsheets/**/*.md` and filter to entries with `tier: bundled`.
2. For each, derive the URL → `/opt/cheatsheet-sources/<host>/<path>` mapping.
3. Compute a cache key as `SHA-256( sorted(union(URLs)) || --max-age-days flag )`.
4. Look up the cache key in `$CACHE_DIR/cheatsheet-source-bake/<key>/`. On miss, invoke `scripts/fetch-cheatsheet-source.sh --tier=bundled` to populate the directory.
5. Stage the directory as the build context's `cheatsheet-sources/` subtree.
6. The forge image SHALL `COPY cheatsheet-sources/ /opt/cheatsheet-sources/` near the end of the build, after the `/opt/cheatsheets-image/` COPY step but before the locale-files COPY.
7. For each bundled cheatsheet, inject `image_baked_sha256` and `structural_drift_fingerprint` into a side-channel `.cheatsheets-meta/<category>/<name>.frontmatter.json` so `populate_hot_paths()` can reflect the SHA in `INDEX.md` without rewriting the cheatsheet inside the image.

The build SHALL accept `--refresh-sources` to force re-fetch regardless of cache hit, and `--max-age-days N` to age-pin (CI default: 7). **Network failure during the fetch step SHALL NOT fail the build** — the previous cache key (if any) is reused with a WARN, and no `last_verified` field is bumped.

#### Scenario: Image build performs fetch-and-bake before cheatsheet staging

- **WHEN** `scripts/build-image.sh forge` runs
- **THEN** the fetch-and-bake stage SHALL execute before the `COPY cheatsheets/ /opt/cheatsheets-image/` step
- **AND** the resulting forge image SHALL contain `/opt/cheatsheet-sources/<host>/<path>` for every bundled cheatsheet's cited URLs
- **AND** the resulting image SHALL contain `/opt/cheatsheets-image/` and `/opt/cheatsheets/` (per existing requirements) — the new bundled sources are additive

#### Scenario: Cache hit on rebuild produces byte-identical bundled-source layer

- **WHEN** `scripts/build-image.sh forge` runs twice with no changes to bundled-tier `source_urls[]`
- **THEN** the second run's cache key SHALL match the first run's
- **AND** the fetch step SHALL NOT invoke the network
- **AND** the resulting `/opt/cheatsheet-sources/` content SHALL be byte-identical between the two builds

#### Scenario: --refresh-sources forces re-fetch

- **WHEN** `scripts/build-image.sh forge --refresh-sources` runs
- **THEN** the fetcher SHALL be invoked even on cache hit
- **AND** the cache key directory SHALL be replaced with the freshly-fetched content

#### Scenario: Network failure during fetch does not fail the build

- **WHEN** the fetch step is invoked and the network is unreachable
- **AND** a previous cache key directory exists
- **THEN** the build SHALL emit `WARN: network unreachable, reusing cache key <prev>`
- **AND** the build SHALL succeed using the previous cache
- **AND** the resulting forge image SHALL contain the previous-build's bundled sources

#### Scenario: Frontmatter SHA injected into side-channel for INDEX rendering

- **WHEN** the fetch-and-bake stage completes for a bundled cheatsheet at `cheatsheets/languages/python.md`
- **THEN** a file SHALL exist at the build context's `.cheatsheets-meta/languages/python.frontmatter.json`
- **AND** the JSON SHALL contain `image_baked_sha256` and `structural_drift_fingerprint`
- **AND** `populate_hot_paths()` at runtime SHALL read this side-channel to render `[bundled, verified: <sha8>]` in `/opt/cheatsheets/INDEX.md` without rewriting the cheatsheet file inside the image

### Requirement: Forge image discovers a package manifest for distro-packaged validation

The forge image SHALL expose a discoverable list of installed OS packages so that `scripts/check-cheatsheet-sources.sh` can validate `tier: distro-packaged` cheatsheets' `package:` field. The discovery order SHALL be: (1) `flake.nix` `contents` attribute (parsed by the host-side validator), (2) `images/default/Containerfile` `dnf install` lines, (3) a dedicated `images/default/distro-packages.txt` text file (one package per line). The validator SHALL try each source in order and SHALL accept the first that succeeds.

For runtime use inside the forge container, the same package list SHALL be obtainable via `rpm -qa --qf '%{NAME}\n'` (Fedora-based image) or equivalent.

#### Scenario: flake.nix contents is the canonical source

- **WHEN** the host-side validator runs
- **AND** `flake.nix` declares the forge image's `contents` with `[ pkgs.java-21-openjdk-doc pkgs.perl-doc ]`
- **THEN** the validator SHALL recognize `java-21-openjdk-doc` and `perl-doc` as valid `package:` values for distro-packaged cheatsheets

#### Scenario: distro-packages.txt fallback when flake.nix not parseable

- **WHEN** the validator's flake.nix parser fails (or `flake.nix` does not declare `contents`)
- **AND** `images/default/distro-packages.txt` exists with `java-21-openjdk-doc` on its own line
- **THEN** the validator SHALL accept `java-21-openjdk-doc` as a valid `package:` value

#### Scenario: Runtime in-image package list verifiable

- **WHEN** an in-forge agent runs `rpm -qa --qf '%{NAME}\n' | grep -x java-21-openjdk-doc`
- **THEN** the command SHALL exit 0 if and only if the package is installed
- **AND** the cheatsheet's `local:` path SHALL resolve to a file the package owns

### Requirement: populate_hot_paths merges project-committed cheatsheets after image-baked canonical

`populate_hot_paths()` (per `forge-hot-cold-split` and the existing `default-image` requirement that runs it from every forge entrypoint) SHALL extend to merge `<project>/.tillandsias/cheatsheets/` into `/opt/cheatsheets/` (tmpfs view) AFTER copying the image-baked canonical from `/opt/cheatsheets-image/`. Project-committed files at the same relative path as a forge default SHALL OVERWRITE the forge default in the tmpfs view.

For each project-committed file that shadows a forge default, the function SHALL emit one banner line to forge launch output:

```
[cheatsheet override] <path> → project version (reason: <first line of override_reason>)
```

The function SHALL also re-render `/opt/cheatsheets/INDEX.md` after the merge to reflect the runtime-merged state (per the `cheatsheets-license-tiered` tier-aware INDEX requirement). Pulled materializations under `~/.cache/tillandsias/cheatsheets-pulled/<project>/` SHALL appear in the runtime INDEX with a `[pulled]` badge.

#### Scenario: Project-committed cheatsheet overlays forge default in tmpfs

- **WHEN** the forge container starts for project `acme`
- **AND** `<project>/.tillandsias/cheatsheets/languages/jdk-api.md` exists
- **AND** `cheatsheets/languages/jdk-api.md` is the forge default at `/opt/cheatsheets-image/languages/jdk-api.md`
- **THEN** after `populate_hot_paths()` completes, `/opt/cheatsheets/languages/jdk-api.md` SHALL contain the project version's content
- **AND** `/opt/cheatsheets-image/languages/jdk-api.md` SHALL remain unchanged (RO image lower layer)

#### Scenario: Shadow banner emitted at forge launch

- **WHEN** `populate_hot_paths()` merges a project shadow whose `override_reason:` first line reads `JDK 17 LTS pin (deployment target Android Gradle Plugin 8.x)`
- **THEN** the forge launch output SHALL contain a line:
  ```
  [cheatsheet override] languages/jdk-api.md → project version (reason: JDK 17 LTS pin (deployment target Android Gradle Plugin 8.x))
  ```

#### Scenario: Net-new project cheatsheets merge without banner

- **WHEN** a project-committed cheatsheet exists at a path NOT shadowed by any forge default
- **THEN** `populate_hot_paths()` SHALL include it in `/opt/cheatsheets/`
- **AND** SHALL NOT emit a `[cheatsheet override]` banner line for it

#### Scenario: INDEX.md re-rendered post-merge with runtime badges

- **WHEN** `populate_hot_paths()` completes
- **THEN** `/opt/cheatsheets/INDEX.md` SHALL be a regenerated file (not the byte-identical copy from `/opt/cheatsheets-image/INDEX.md`)
- **AND** project-committed cheatsheets SHALL appear with `[pull-on-demand: project-committed]` badges
- **AND** any pulled materializations under `~/.cache/tillandsias/cheatsheets-pulled/<project>/` SHALL appear with `[pulled]` badges

### Requirement: Forge image declares cheatsheet-telemetry as an EXTERNAL log producer

The forge image SHALL bake `images/default/external-logs.yaml` declaring `role: cheatsheet-telemetry` per the `cheatsheets-license-tiered` cheatsheet-telemetry requirement and the `external-logs-layer` producer/manifest contract. The forge `ContainerProfile` SHALL set `external_logs_role: Some("cheatsheet-telemetry")`. The launcher SHALL bind-mount `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/` RW at `/var/log/tillandsias/external/cheatsheet-telemetry/` inside every forge container.

#### Scenario: Manifest baked into forge image

- **WHEN** the forge image is built
- **THEN** `/etc/tillandsias/external-logs.yaml` (the in-image path baked from `images/default/external-logs.yaml`) SHALL exist
- **AND** the manifest's `role` field SHALL be `cheatsheet-telemetry`
- **AND** the manifest SHALL declare `lookups.jsonl` with `format: jsonl` and `rotate_at_mb: 10`

#### Scenario: Forge container has the producer mount

- **WHEN** a forge container starts
- **THEN** `/var/log/tillandsias/external/cheatsheet-telemetry/` SHALL be a writable bind mount of `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/`
- **AND** the in-forge agent SHALL be able to append JSON lines to `lookups.jsonl`

#### Scenario: Tray auditor recognizes the new producer within 60 seconds

- **WHEN** the forge container starts and a new `lookups.jsonl` event is appended
- **THEN** within 60 seconds the tray auditor (per `external-logs-layer`) SHALL discover the role and validate the manifest
- **AND** SHALL flag any file written outside the manifest as a `[external-logs] LEAK: cheatsheet-telemetry wrote <file>` event

## REMOVED Requirements

### Requirement: Forge image bakes the cheatsheets directory at /opt/cheatsheets/

**Reason**: Superseded by `Forge image ships cheatsheets at /opt/cheatsheets-image (image-baked canonical)` which pre-existed in the same spec. The older requirement asserted that `/opt/cheatsheets/` is the image-baked path; the newer (correct) requirement states that `/opt/cheatsheets-image/` is image-baked while `/opt/cheatsheets/` is a runtime tmpfs view populated by `populate_hot_paths()`. Both requirements coexisting was a pre-existing inconsistency surfaced by the `cheatsheets-license-tiered` design review.

**Migration**: No code change required — the newer requirement is already implemented. This REMOVAL aligns the spec with the actual behavior. The `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` environment variable and the EACCES write-protection scenario remain valid (they describe the runtime tmpfs view, not the image-baked path) and are preserved by the surrounding requirements (`Forge entrypoint surfaces TILLANDSIAS_CHEATSHEETS to agents` and `forge-welcome.sh prints the cheatsheet location once per session`).

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — architectural rationale for image-baked source bundling at the forge boundary.
- `cheatsheets/runtime/forge-hot-cold-split.md` — `populate_hot_paths()` is the merge point for image-baked + project-committed + pulled-materialization views.
- `cheatsheets/runtime/external-logs.md` — EXTERNAL-tier producer/consumer contract that the new `cheatsheet-telemetry` role implements; `images/git/external-logs.yaml` is the reference pattern.
- `cheatsheets/build/nix-flake-basics.md` — `dockerTools.buildLayeredImage` `contents` (canonical package manifest source) and `extraCommands` (where the cheatsheet-sources COPY lands).
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — `<project>/.tillandsias/cheatsheets/` is on the project bind mount; pulled cache lives under per-project ephemeral.
