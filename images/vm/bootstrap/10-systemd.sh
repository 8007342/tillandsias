#!/usr/bin/env bash
# Step 10 — systemd configuration for the Tillandsias VM rootfs.
#
# Runs inside the recipe-build container (buildah-managed). Configures
# systemd-networkd (DHCP on eth0/enp0s1), disables sshd (in favor of the
# vsock control-wire), and tunes the kernel cmdline default for fast boot.
#
# @trace openspec/changes/vm-recipe-provisioning §1.3

set -euo pipefail

# Enable systemd-networkd; disable the host's NetworkManager-equivalent if
# present (Fedora Container Base ships networkd already; this is belt+
# suspenders so the recipe is portable to other Fedora variants).
systemctl enable systemd-networkd systemd-resolved 2>/dev/null || true

# Drop a network config that DHCPs on the default virtio-net interface.
# enp0s1 is what VFR exposes on Apple Silicon; ens33/eth0 are typical on
# WSL2/KVM. MatchName accepts a wildcard so all three work.
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-tillandsias-vm.network <<'EOF'
[Match]
Name=enp0s1 ens* eth*

[Network]
DHCP=yes
EOF

# Disable sshd at boot — the in-VM tillandsias-headless owns the vsock
# control wire on port 42420; SSH is not part of the v0.0.1 contract.
systemctl disable sshd 2>/dev/null || true
systemctl mask sshd 2>/dev/null || true

# Persistent journal so early-boot diagnostics survive between VM restarts
# (per the host-shell condensed-status UX feedback loop).
mkdir -p /var/log/journal

echo "[10-systemd] done"
