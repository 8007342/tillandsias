## 1. Add process limit and filesystem hardening fields to ContainerProfile

- [x] 1.1 Add `pids_limit: u32`, `read_only: bool`, `tmpfs_mounts: Vec<&'static str>` to `ContainerProfile` struct
- [x] 1.2 Set per-profile values: forge/terminal=512, git=64, proxy=32, inference=128, web=32
- [x] 1.3 Set `read_only=true` + tmpfs mounts for git, proxy, inference, web profiles
- [x] 1.4 Add unit tests verifying all profiles have correct limits and read-only settings

## 2. Emit hardening flags in build_podman_args

- [x] 2.1 Add `--pids-limit=N` to non-negotiable security flags section
- [x] 2.2 Add `--read-only` + `--tmpfs` flags when profile.read_only is true
- [x] 2.3 Update web container's manually-built podman command string with pids-limit and read-only
- [x] 2.4 Add integration tests for pids-limit, read-only, tmpfs in args output

## 3. Add credential isolation tracing

- [x] 3.1 Add `@trace spec:secret-management` log at D-Bus forwarding point in launch.rs
- [x] 3.2 Update forge/terminal credential-free logs to include pids-limit and D-Bus absence
- [x] 3.3 Add git service launch log noting D-Bus access + pids-limit + read-only
- [x] 3.4 Add proxy launch log noting CA-certs-only + pids-limit + read-only

## 4. Update spec

- [x] 4.1 Add "Process isolation and hardening" requirement to secret-management spec
- [x] 4.2 Add scenarios for git service, forge, proxy, inference, web containers

## 5. Verify

- [x] 5.1 Run `cargo test --workspace`
