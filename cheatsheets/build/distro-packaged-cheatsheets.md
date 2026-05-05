---
tags: [build, cheatsheet-system, distro-packaged, package-manager, dnf, nix]
languages: []
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://docs.fedoraproject.org/en-US/packaging-guidelines/LicensingGuidelines/
  - https://nix.dev/manual/nix/2.18/language/builtins.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Adding a distro-packaged cheatsheet

@trace spec:cheatsheets-license-tiered, spec:default-image
@cheatsheet runtime/cheatsheet-tier-system.md, runtime/cheatsheet-frontmatter-spec.md

**Use when**: A doc package ships in the forge image's package manifest (e.g. `java-21-openjdk-doc`, `perl-doc`, `glibc-devel-info`) and you want to author a cheatsheet that points agents at the OS-installed file rather than fetching or stubbing the upstream URL.

## Provenance

- Fedora Packaging Licensing Guidelines: <https://docs.fedoraproject.org/en-US/packaging-guidelines/LicensingGuidelines/> — the `dnf install` license-acceptance contract that distro-packaged tier inherits
- Nix language builtins reference: <https://nix.dev/manual/nix/2.18/language/builtins.html> — `flake.nix` `contents` parsing for package-manifest validation
- `openspec/specs/cheatsheets-license-tiered/spec.md` — normative spec; `tier: distro-packaged` requirement
- **Last updated:** 2026-04-27

## Quick reference — the four steps

| Step | What you do |
|---|---|
| 1 | Pick a documentation package the forge image installs (or add one). |
| 2 | Verify the on-disk path the package writes (typically `/usr/share/doc/...` or `/usr/share/javadoc/...`). |
| 3 | Author the cheatsheet with `tier: distro-packaged` frontmatter, `package: <pkg-name>`, `local: <on-disk path>`. |
| 4 | Run `scripts/check-cheatsheet-sources.sh` — validator confirms the package is in `flake.nix`/`Containerfile` and the local path exists in the built image. |

## Common patterns

### JDK API documentation (canonical example)

The forge image installs `java-21-openjdk-doc` via `flake.nix`'s `contents` (or `images/default/Containerfile`'s `dnf install`). The package writes the API HTML to `/usr/share/javadoc/java-21-openjdk/api/index.html`.

Cheatsheet at `cheatsheets/languages/jdk-api.md`:

```yaml
---
tier: distro-packaged
package: java-21-openjdk-doc
local: /usr/share/javadoc/java-21-openjdk/api/index.html
source_urls:
  - https://docs.oracle.com/en/java/javase/21/docs/api/   # upstream truth
summary_generated_by: hand-curated
bundled_into_image: true
---

# JDK 21 API quick reference

**Use when**: You need fast lookups for java.util.concurrent, java.nio, java.lang.invoke, etc.

## Provenance

- OpenJDK 21 javadoc package: locally at `/usr/share/javadoc/java-21-openjdk/api/index.html`
- Upstream HTML mirror: <https://docs.oracle.com/en/java/javase/21/docs/api/>
- **Last updated:** 2026-04-27

## Quick reference

(... your distilled summary; for depth, the agent reads the local index.html directly)
```

### Perl module documentation

```yaml
---
tier: distro-packaged
package: perl-doc
local: /usr/share/perl5/pod/perlfunc.pod
source_urls:
  - https://perldoc.perl.org/perlfunc
---
```

The `perl-doc` package installs `perlfunc.pod` and the rest of the core POD. Agents that need module reference can `cat /usr/share/perl5/pod/<topic>.pod` instead of pulling.

## Common pitfalls

- **Adding the cheatsheet without adding the package to the image manifest** — validator emits `ERROR: distro-packaged cheatsheet references missing package: <name>`. Always verify the package is in `flake.nix` `contents` (preferred) or `images/default/Containerfile`'s `dnf install` lines BEFORE authoring the cheatsheet.
- **Using a Fedora package name in a Containerfile that uses Alpine apk** — package names differ across distros. Match the name to the actual package manager. Tillandsias's forge uses Fedora 43 + dnf today.
- **Pointing `local:` at a path that the package doesn't actually create** — packages can move files between releases. Verify with `podman run --rm tillandsias-forge ls /usr/share/javadoc/java-21-openjdk/api/index.html` after rebuild. Validator catches missing paths post-build but not at author time.
- **Forgetting `source_urls`** — even though distro-packaged cheatsheets read from disk, the upstream URL is required so the structural-drift fingerprint discipline can compare local-vs-upstream over time. Without `source_urls`, drift detection has nothing to compare against.
- **Mixing `tier: distro-packaged` with `tier: bundled` on cheatsheets covering the same upstream** — pick one. If the package ships docs, prefer `distro-packaged` (no duplicate bytes). If you need a specific section the package doesn't carry, use `bundled` and fetch only that section.
- **License assumption from the package** — package-manager license acceptance is the OS distro's contract, not yours. Re-confirm the upstream license URL in your cheatsheet's `## Provenance` so cross-platform readers (e.g., a non-Fedora forge variant) see the actual constraint. Most OpenJDK / Apache / GPL packages are safe; Oracle-FTC packages are not redistributable even if your distro packaged them.

## Adding a new distro-packaged tier

When a project needs documentation that's available as a distro package not yet in the forge image:

1. Pick the package (`dnf search <topic>-doc` or equivalent).
2. Add to `flake.nix` `contents` OR `images/default/Containerfile` `dnf install`.
3. Rebuild the forge image (`scripts/build-image.sh forge`).
4. Confirm the file exists: `podman run --rm tillandsias-forge ls <expected-path>`.
5. Author the cheatsheet with `tier: distro-packaged`.
6. Run `scripts/check-cheatsheet-sources.sh` — should pass.

The forge image grows by the package's docs size. Budget accordingly: JDK docs are ~80 MB, Perl docs ~20 MB, glibc info ~5 MB.

## See also

- `runtime/cheatsheet-tier-system.md` — the three tiers; pick distro-packaged when the package manager already accepts the license + ships the bytes
- `runtime/cheatsheet-frontmatter-spec.md` — `tier: distro-packaged` requires `package:` + `local:`; forbids `image_baked_sha256` + `pull_recipe`
- `runtime/cheatsheet-pull-on-demand.md` — alternative when no distro package exists
- `cheatsheets/license-allowlist.toml` — domain license declarations (informational for distro-packaged cheatsheets — the package manager handled the legal accept)
