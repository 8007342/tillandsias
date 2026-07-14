#!/usr/bin/env bash
# @trace spec:git-mirror-service
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

require_source() {
    local file="$1"
    local literal="$2"
    grep -Fq -- "$literal" "$file" || {
        echo "FAIL: $file does not contain required shared-guest marker: $literal" >&2
        exit 1
    }
}

forbid_host_override() {
    local surface="$1"
    if rg -n 'GIT_CONFIG_GLOBAL|GIT_SSL_CAINFO|SSL_CERT_FILE|REQUESTS_CA_BUNDLE|NODE_EXTRA_CA_CERTS|CURL_CA_BUNDLE|/home/forge/\.gitconfig|ca-chain\.crt' "$surface"; then
        echo "FAIL: host-specific Git/trust override found in $surface" >&2
        exit 1
    fi
}

# VZ and WSL both boot the same Linux headless binary. Git configuration and
# runtime CA injection therefore remain in the shared in-guest launcher/image
# path instead of growing platform-specific tray fallbacks.
require_source crates/tillandsias-vm-layer/src/vz.rs \
    'ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420'
require_source crates/tillandsias-vm-layer/src/wsl.rs \
    'ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock {port}'
require_source crates/tillandsias-windows-tray/src/wsl_lifecycle.rs \
    'ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420'
require_source crates/tillandsias-macos-tray/src/diagnose.rs \
    'exec /usr/local/bin/tillandsias-headless --opencode {path}'

for surface in \
    crates/tillandsias-vm-layer/src \
    crates/tillandsias-windows-tray/src \
    crates/tillandsias-macos-tray/src \
    scripts/build-macos-tray.sh \
    scripts/build-windows-tray.ps1
do
    forbid_host_override "$surface"
done

cargo test -q -p tillandsias-host-shell launch_spec
cargo test -q -p tillandsias-vm-layer vz_cloud_init_headless_service_has_control_wire_preflight
cargo test -q -p tillandsias-headless forge_credential_quarantine_mounts_present
cargo test -q -p tillandsias-headless opencode_args_mount_workspace_and_prompt
scripts/test-forge-standard-gitconfig-path.sh
scripts/test-forge-runtime-ca-trust.sh

echo "PASS: Linux live behavior and macOS/Windows shared-guest source paths converge"
