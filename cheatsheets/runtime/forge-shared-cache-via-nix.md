---
tags: [forge, cache, nix, shared-libraries, content-addressed, isolation]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://nixos.org/manual/nix/stable/store/
  - https://nix.dev/concepts/nix-language
  - https://github.com/8007342/tillandsias/blob/main/openspec/changes/forge-cache-architecture/proposal.md
authority: high
status: current
---

# Forge shared cache via nix (the only shared-write surface)

@trace spec:forge-cache-architecture, spec:forge-cache-dual
@cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md, build/nix-flake-basics.md

## Provenance

- Official Nix manual, "Nix store": <https://nixos.org/manual/nix/stable/store/> — the canonical reference for content-addressed storage
- nix.dev, "The Nix language": <https://nix.dev/concepts/nix-language> — concept page
- Tillandsias OpenSpec change `forge-cache-architecture`: <https://github.com/8007342/tillandsias/blob/main/openspec/changes/forge-cache-architecture/proposal.md>
- **Last updated:** 2026-04-25

## Use when

You're trying to share a library across projects without paying the download cost twice, OR you're confused about why every other tool writes to a per-project cache while nix gets to write to a shared one.

## The single-entry-point rule

`/nix/store/` is the **only** writable-shared cache surface in the Tillandsias forge model. Other tools (Maven, Gradle, npm, cargo registry, Flutter pub) write to the **per-project** cache. This is by design — and the design works because nix's store is **content-addressed**, which makes it conflict-free.

| Surface | Who writes | Why it's safe to share |
|---|---|---|
| `/nix/store/` (RO from forge) | host-side `nix build`, `nix-collect-garbage` | Each entry is `<sha256>-<name>-<version>` — different content = different path. Two projects asking for "openssl 3.2.1" point at the same path; two projects asking for slightly different builds get different paths. No trampling possible. |
| `~/.cache/tillandsias/forge-projects/<project>/maven/` | the project's `mvn` | Per-project, isolated, no sharing — so no conflict. Cost: re-downloads if two projects use the same JAR. |

## Why content-addressing makes shared writes safe

Per the Nix store reference: every store path includes a hash of the inputs that produced it (`/nix/store/abc123-foo-1.2.3-x86_64-linux/`). Two different inputs produce two different paths. Two identical inputs produce identical paths AND identical contents. Therefore:

1. There is no "race" to write the same path with different content — the hash is part of the path.
2. Reads are stable forever — once `/nix/store/abc123-foo/` exists, its contents will not change.
3. Garbage collection (`nix-collect-garbage`) is safe — it only removes paths nothing references.

This is why the user said "use nix as a single source of entry to this cache so shared projects don't trample on each other." Nix's design is the trampling-prevention mechanism. Other tools (Maven's flat `~/.m2/repository/<group>/<artifact>/<version>/`) are NOT content-addressed — version `1.2.3-snapshot` is a single mutable entry, races are real, so they can't safely share across projects in our model.

## How to use it from a project

You don't write to `/nix/store/` directly from inside the forge — the mount is `:ro`. Instead:

1. **Declare deps in `flake.nix`** at the project root (or import a shared flake).
2. **Run `nix build` or `nix develop` HOST-SIDE** (or via a future tray-managed builder container) — this populates `/nix/store/` on the host.
3. **Forge container's RO mount** automatically sees the new entries on next attach.

Example flake fragment that pulls in `openssl` from nixpkgs:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = [ pkgs.openssl pkgs.pkg-config ];
    };
  };
}
```

After `nix develop` (host-side), `openssl` and `pkg-config` exist under `/nix/store/<hash>-openssl-3.x/` and the forge sees them via the RO mount. A second project asking for the same `openssl` version reads the same store entry — no re-download.

See `cheatsheets/build/nix-flake-basics.md` for the broader flake authoring patterns.

## What this means for non-nix projects

A project that doesn't use nix gets the per-project cache for its tooling — Maven still works, npm still works, cargo still works. But each project pays the download cost for its own deps independently. If you find yourself wanting to share something across projects without nix, the answer is: add nix to one of them and let nix manage the shared dep.

## Common pitfalls

- **Trying to write to `/nix/store/` from inside the forge** — fails with EROFS. The mount is `:ro` by design. Use `nix build` host-side instead.
- **Deleting the nix store from the host** — wipes shared deps for ALL projects on this host. Annoying to recover (every flake re-builds on next attach). Use `nix-collect-garbage` to remove only unreferenced entries.
- **Confusing per-project nix profile with shared store** — a project's `nix profile install foo` writes a profile under `~/.cache/tillandsias/forge-projects/<project>/nix-profile/` (per-project, RW, NOT shared). The store entries the profile references live in `/nix/store/` (shared). Profile = pointer; store = content.
- **`nix-shell` (legacy) vs `nix develop` (flakes)** — different code paths, different caches. Stick with flakes (`nix develop`) for new work.
- **Expecting the forge to install nix packages** — the forge has `nix` baked in (per `forge-bake-nix` change) but it's read-only against `/nix/store/`. Building new flake outputs happens host-side or in a privileged builder container.

## Verification

```bash
# Inside the forge:
ls -la /nix/store/ | head    # should show many <hash>-<name> entries owned by some root-equivalent
touch /nix/store/test         # should fail with EROFS

# From the host:
ls ~/.cache/tillandsias/forge-shared/nix-store/ | head   # same entries, host-side
nix-store --gc --print-roots                              # see what's keeping store entries alive
```

## See also

- `runtime/forge-paths-ephemeral-vs-persistent.md` — the four-category path model
- `build/nix-flake-basics.md` — flake authoring (host-side store population)
- `runtime/forge-container.md` (DRAFT) — broader runtime contract
