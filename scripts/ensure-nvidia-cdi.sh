#!/usr/bin/env bash
# ORDER 935-jhh5 — give this host a working NVIDIA CDI device, idempotently,
# WITHOUT layering anything onto an immutable OS.
#
# THE OPERATOR'S QUESTION WAS "host or toolbox?", AND THE MEASURED ANSWER IS
# BOTH, SPLIT ON A LINE NOBODY HAD DRAWN. Measured on lenovinha (Fedora
# Silverblue, RTX 3070 Laptop + AMD Cezanne iGPU, driver 610.57.04) 2026-08-29:
#
#   nvidia-container-toolkit  -> TOOLBOX. No rpm-ostree layering, no reboot.
#   the generated CDI spec    -> must describe the HOST, not the toolbox.
#   the nvidia-cdi-hook binary-> must exist ON THE HOST: crun executes it during
#                                container setup, so a toolbox-only copy is
#                                referenced and never found.
#
# WHY A TOOLBOX-GENERATED SPEC IS 98% RIGHT AND 100% BROKEN. Generating inside
# the toolbox with no flags produced 55 paths of which 2 do not exist on the
# host — `/etc/vulkan/implicit_layer.d/nvidia_layers.json` (the host keeps it
# under /usr/share) and the hook. One wrong path is enough: crun refuses the
# container with "cannot stat …: No such file or directory". Generating with
# `--driver-root=/run/host` fixes the first, and it works because on Silverblue
# /run/host is a symlink to / — so a path discovered through it is already
# host-absolute.
#
# PODMAN DOES NOT LOOK IN ~/.config/cdi BY DEFAULT. Its defaults are
# [/etc/cdi, /var/run/cdi]; neither is user-writable without root, and
# /var/run/cdi is tmpfs. 665-zddn's recorded remediation writes to
# ~/.config/cdi, which is correct ONLY once cdi_spec_dirs names it — this
# script configures that, so the fix needs no sudo and survives reboot.
#
# SELINUX IS THE LAST BLOCKER AND IT IS NOT THIS SCRIPT'S TO FIX. With the spec
# resolving, a rootless container still gets "Permission denied" on
# /dev/nvidiactl under enforcing SELinux (the nodes are
# xserver_misc_device_t). Callers need `--security-opt label=disable`, which
# this repo already uses for the nix store. Recorded here so the next reader
# does not re-derive it.
#
# IDEMPOTENT: re-running regenerates the spec, which is exactly what a driver
# update needs (665-zddn's stale-spec strand). Cheap enough for a preflight.
set -uo pipefail

CDI_DIR="${TILLANDSIAS_CDI_DIR:-$HOME/.config/cdi}"
HOOK="${TILLANDSIAS_CDI_HOOK:-$HOME/.local/bin/nvidia-cdi-hook}"
TOOLBOX="${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}"
CONF="$HOME/.config/containers/containers.conf"

command -v nvidia-smi >/dev/null 2>&1 || { echo "skip:nvidia-cdi:no-driver"; exit 0; }
nvidia-smi -L 2>/dev/null | grep -q . || { echo "skip:nvidia-cdi:no-gpu"; exit 0; }
command -v toolbox >/dev/null 2>&1 || { echo "blocked:nvidia-cdi:no-toolbox"; exit 1; }

_tb() { env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= toolbox run --container "$TOOLBOX" "$@"; }

# 1. the toolkit, in the toolbox
if ! _tb command -v nvidia-ctk >/dev/null 2>&1; then
    _tb sh -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null \
        && sudo dnf install -y nvidia-container-toolkit' >/dev/null 2>&1 \
        || { echo "blocked:nvidia-cdi:toolkit-install-failed"; exit 1; }
fi

# 2. the hook, on the HOST — crun runs it, so it cannot live only in the toolbox
mkdir -p "$(dirname "$HOOK")"
if [ ! -x "$HOOK" ] || ! "$HOOK" --version >/dev/null 2>&1; then
    _tb cat /usr/bin/nvidia-cdi-hook > "$HOOK" 2>/dev/null
    chmod 755 "$HOOK" 2>/dev/null
    "$HOOK" --version >/dev/null 2>&1 || { echo "blocked:nvidia-cdi:hook-not-runnable"; exit 1; }
fi

# 3. teach podman where to look — no sudo, survives reboot
mkdir -p "$CDI_DIR" "$(dirname "$CONF")"
if ! grep -q 'cdi_spec_dirs' "$CONF" 2>/dev/null; then
    [ -f "$CONF" ] || printf '[engine]\n' > "$CONF"
    grep -q '^\[engine\]' "$CONF" || printf '\n[engine]\n' >> "$CONF"
    printf '\n# 935-jhh5: podman defaults to [/etc/cdi,/var/run/cdi]; neither is\n# user-writable without root and /var/run/cdi is tmpfs.\ncdi_spec_dirs = ["%s", "/etc/cdi", "/var/run/cdi"]\n' "$CDI_DIR" >> "$CONF"
fi

# 4. the spec, describing the HOST. ONE spec only: two files both declaring
#    nvidia.com/gpu make podman report the device UNRESOLVABLE, which reads
#    exactly like no spec at all — measured, and it cost an hour.
find "$CDI_DIR" -maxdepth 1 -name 'nvidia*.yaml' ! -name 'nvidia.yaml' -delete 2>/dev/null
_tb nvidia-ctk cdi generate --driver-root=/run/host --dev-root=/ \
    --nvidia-cdi-hook-path="$HOOK" --output="$CDI_DIR/nvidia.yaml" >/dev/null 2>&1 \
    || { echo "blocked:nvidia-cdi:generate-failed"; exit 1; }

# 5. VERIFY, never assert. Every path the spec names must exist on THIS host —
#    the check that would have caught the toolbox-root spec immediately.
missing=0
for p in $(grep -oE '(hostPath|path): +[^ ]+' "$CDI_DIR/nvidia.yaml" | awk '{print $2}' | sort -u); do
    [ -e "$p" ] || { missing=$((missing + 1)); echo "  missing: $p" >&2; }
done
if [ "$missing" -gt 0 ]; then
    echo "blocked:nvidia-cdi:spec-references-$missing-absent-paths"
    exit 1
fi

total=$(grep -oE '(hostPath|path): +[^ ]+' "$CDI_DIR/nvidia.yaml" | awk '{print $2}' | sort -u | wc -l)
echo "ok:nvidia-cdi:spec=$CDI_DIR/nvidia.yaml:paths=$total:missing=0:selinux-callers-need=label=disable"
