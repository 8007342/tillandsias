#!/usr/bin/env bash
# @trace spec:accel-capability-probe, spec:inference-engine-slots
#
# nvidia-cdi-ensure.sh — make the NVIDIA CDI spec present and CURRENT, so the
# product's own GPU lane can light up without a second sudo. Order 408.
#
# Verdict grammar, exactly one line on stdout:
#   ok:nvidia-cdi:current:<driver>      spec present and matches the live driver
#   ok:nvidia-cdi:generated:<driver>    spec written (absent, or driver moved)
#   skip:nvidia-cdi:no-gpu              no NVIDIA GPU on this host
#   skip:nvidia-cdi:no-nvidia-ctk       toolkit absent — nothing to generate with
#   degraded:nvidia-cdi:<reason>        wanted to generate and could not
#
# WHY THIS EXISTS AND WHY IT IS SMALL. The product already resolves the tier and
# already refuses to claim CUDA without a spec:
#     effective_inference_tier() -> "gpu-cuda" if nvidia_cdi_available() else "cpu"
# and nvidia_cdi_available() honours ~/.config/cdi. So on a host with the card,
# the driver, and the toolkit, the ONLY thing standing between "cpu" and
# "gpu-cuda" was a file nobody wrote. Measured on macuahuitl 2026-08-17:
# generating it flipped `tillandsias --capabilities` from accel_gpu=unusable to
#     accel_class=workstation-gpu accel_gpu=usable legacy_tier=gpu-cuda
# with no other change to the product. An RTX A5000 with 24564 MiB sat at the
# CPU terminal of the router's fallback chain for weeks over a missing file.
#
# THE FRESHNESS CHECK IS THE POINT, not the generation. A CDI spec pins
# VERSIONED library paths (…/libnvidia-ml.so.610.57.04). A driver upgrade moves
# them, and the stale spec then either fails the container at startup or, worse,
# injects paths that no longer exist while the tier still claims cuda. Presence
# is therefore not currency: this records the driver the spec was generated for
# and regenerates when the live driver differs. That is the same lesson as
# 797-w8kf, where a wrapper was judged "fresh" by mtime while the binary it
# exec'd had been deleted — asking about the artifact instead of its subject.
#
# ROOTLESS BY CONSTRUCTION. Writes only to the per-user CDI dir. It never asks
# for sudo and never touches /etc/cdi: a dev host must be able to enable its own
# accelerator without privilege, and an END USER RUNTIME must not have its host
# reconfigured by a script that came with a checkout.

set -uo pipefail

CDI_DIR="${TILLANDSIAS_CDI_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cdi}"
CDI_SPEC="$CDI_DIR/nvidia.yaml"
CDI_STAMP="$CDI_DIR/.nvidia-driver-version"

# No card -> nothing to do, and this is the common case across the fleet
# (macOS, most Silverblue boxes, any host with an AMD or Intel GPU only).
if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf 'skip:nvidia-cdi:no-gpu\n'
    exit 0
fi

_live_driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]')"
if [ -z "$_live_driver" ]; then
    printf 'skip:nvidia-cdi:no-gpu\n'
    exit 0
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
    # Deliberately not a failure: a host can legitimately have the card and not
    # the container toolkit. Name the remedy rather than the absence.
    printf 'skip:nvidia-cdi:no-nvidia-ctk\n'
    exit 0
fi

_stamped=""
[ -f "$CDI_STAMP" ] && _stamped="$(tr -d '[:space:]' <"$CDI_STAMP" 2>/dev/null)"

if [ -s "$CDI_SPEC" ] && [ "$_stamped" = "$_live_driver" ]; then
    printf 'ok:nvidia-cdi:current:%s\n' "$_live_driver"
    exit 0
fi

mkdir -p "$CDI_DIR" 2>/dev/null || {
    printf 'degraded:nvidia-cdi:cannot-create-%s\n' "$CDI_DIR"
    exit 0
}

# Generate into a fresh DIRECTORY and move the file into place, so a failed
# generation cannot replace a working spec with a truncated one.
#
# The output path must NOT already exist. Measured here 2026-08-17: given an
# existing (mktemp-created, empty) target, `nvidia-ctk cdi generate` logs
# "Generated CDI spec with version 0.7.0", exits 0, and leaves the file at ZERO
# BYTES. Exit status alone would have certified an empty spec as a success, and
# the next `nvidia_cdi_available()` would then see a plausible nvidia*.yaml and
# promote the tier to gpu-cuda on the strength of a file with nothing in it.
# Hence the size test below: the tool's own verdict is not sufficient evidence
# that it produced anything.
#
# `nvidia-ctk` also warns about X-server libraries (nvidia_drv.so,
# libglxserver) on a compute-only host. Those are expected and must not be read
# as failure — which is why the check is "did a non-empty file appear", not
# "were there warnings".
_tmpd="$(mktemp -d "${TMPDIR:-/tmp}/nvidia-cdi.XXXXXX")" || {
    printf 'degraded:nvidia-cdi:cannot-mktemp\n'
    exit 0
}
_tmp="$_tmpd/nvidia.yaml"
if nvidia-ctk cdi generate --output="$_tmp" --format=yaml >/dev/null 2>&1 && [ -s "$_tmp" ]; then
    if mv -f "$_tmp" "$CDI_SPEC" 2>/dev/null; then
        printf '%s\n' "$_live_driver" >"$CDI_STAMP" 2>/dev/null || true
        rm -rf "$_tmpd" 2>/dev/null || true
        printf 'ok:nvidia-cdi:generated:%s\n' "$_live_driver"
        exit 0
    fi
    rm -rf "$_tmpd" 2>/dev/null || true
    printf 'degraded:nvidia-cdi:cannot-install-spec\n'
    exit 0
fi

rm -rf "$_tmpd" 2>/dev/null || true
printf 'degraded:nvidia-cdi:generate-failed\n'
exit 0
