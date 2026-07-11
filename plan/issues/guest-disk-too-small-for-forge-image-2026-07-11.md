# Guest VM disk (~5 GB) too small for the forge-base image → every agent attach fails (2026-07-11)

- class: bug — macOS FIXED this session (vz.rs); windows sibling promoted order 295
- found by: operator interactive session on a fresh macOS provision, via the
  TILLANDSIAS_PTY_DEBUG tee (idiomatic layer, no ssh/root)

## Symptom

On a freshly provisioned macOS VM the operator logged in (worked — remote
projects listed, a cloud-only repo cloned and appeared under local projects),
then every agent/maintenance launch (OpenCode, Claude, Codex, Terminal) showed
a blank terminal that timed out. The PTY debug tee captured the real cause: the
first attach triggers the forge-base image build, which downloads all 558
packages fine, then the microdnf **install** step fails, repeatedly:

```
- installing package ltrace-… needs 186MB more space on the / filesystem
- installing package delve-…  needs 290MB more space on the / filesystem
- installing package gopls-…  needs 372MB more space on the / filesystem
Error: building at STEP "RUN microdnf install -y --nogpgcheck … bash coreutils …"
[pty-debug] session=1 CLOSE code=1 signal=None
```

Every agent lane needs that forge image, so all of them fail the same way.
Login itself succeeded (session CLOSE code=0).

## Root cause

`crates/tillandsias-vm-layer/src/vz.rs::convert_qcow2_to_raw` did a straight
`qemu-img convert -f qcow2 -O raw` of the Fedora Cloud image with NO resize —
so the guest disk was the Fedora default ~5 GB (rootfs.img was exactly
5,368,709,120 bytes). The forge-base image installs a full dev toolchain (gcc,
valgrind, delve, gopls, rust, node, python, zsh, …) on top of the base OS,
podman's overlay store for every enclave image, and the cloned project — many
GB, far past 5 GB. This is ALSO the real reason the earlier order-273 "agent
attach runs the login flow" theory never reproduced cleanly: the substrate ran
out of space (or was corrupt, order 281) before anything could be judged.

## macOS fix (this session)

`convert_qcow2_to_raw` now `qemu-img resize`s the raw disk to `GUEST_DISK_SIZE`
(**250G**, operator direction — sparse, so it costs no host disk until
written) before first boot. Fedora Cloud's cloud-init (cc_growpart +
cc_resizefs) grows the root partition/filesystem to fill the disk on first
boot. Drift-pinned by `convert_grows_raw_disk_before_first_boot` (source scan +
≥32 GiB floor). Requires a re-provision to take effect (done this session).

## Windows sibling (order 295)

WSL2 provisions differently (no qemu-img convert; the distro's VHDX grows
dynamically by default up to a per-distro max, historically 256 GB / 1 TB on
newer WSL). But the forge-base build will hit the same wall if the WSL VHDX
max, the ext4 inside it, or any intermediate rootfs is capped near the Fedora
default. Needs a host-appropriate audit + fix — see order 295.
