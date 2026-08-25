# Proposal: every platform builds through a container backed by the nix cache

Order 873-b1nx (operator direction 2026-08-24, verbatim intent recorded on
the row). One build lane, selected the way `with-wsl2-builder` already
selects a target dir: the developer types the same command everywhere, and
the toolchain closure arrives from the enclave nix cache instead of being
re-paid cold on every host and every fresh checkout.

Status: Linux measurements complete (design.md); builder-container slice and
the WSL2/macOS lanes pending. The lane is OPT-IN and build.sh behaviour is
byte-identical while `TILLANDSIAS_BUILD_LANE` is unset (exit criterion 3).
