## 1. Directory structure and scaffolding

- [x] 1.1 Create `knowledge/` directory with `cheatsheets/{infra,lang,frameworks,packaging,formats,ci}` subdirs
- [x] 1.2 Create `knowledge/manifest.toml` with schema and metadata
- [x] 1.3 Create `knowledge/README.md` explaining purpose and format
- [x] 1.4 Add `vendor/debug/` to `.gitignore`

## 2. XML index

- [x] 2.1 Create `knowledge/index.xml` with category and tag structure for Tier 1 cheatsheets

## 3. Tier 1 cheatsheets (core infrastructure)

- [x] 3.1 Create `cheatsheets/infra/podman-rootless.md` — user namespaces, keep-id, rootless networking
- [x] 3.2 Create `cheatsheets/infra/podman-security.md` — cap-drop, no-new-privileges, seccomp, SELinux
- [x] 3.3 Create `cheatsheets/infra/oci-runtime-spec.md` — crun vs runc, /proc/self/fd, namespace lifecycle
- [x] 3.4 Create `cheatsheets/infra/linux-namespaces.md` — user, mount, PID, network; unshare; nsenter
- [x] 3.5 Create `cheatsheets/packaging/nix-flakes.md` — flake structure, inputs/outputs, dockerTools
- [x] 3.6 Create `cheatsheets/lang/rust-async.md` — tokio, select!, spawn, channels, pinning

## 4. Debug source fetching

- [x] 4.1 Create `scripts/fetch-debug-source.sh` with manifest-driven fetching
- [x] 4.2 Create `scripts/debug-sources.toml` with repo URLs and default versions

## 5. Verify

- [x] 5.1 Validate all cheatsheets have correct YAML frontmatter
- [x] 5.2 Validate index.xml is well-formed and references all cheatsheets
- [x] 5.3 Run `./build.sh --check` to confirm no build impact
