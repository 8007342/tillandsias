#!/usr/bin/env bash
# @trace order:804-bpke, spec:app-lifecycle
set -uo pipefail

# Fixture for the shipped uninstaller's data-loss guard (order 804-bpke).
#
# THE BREACH THIS PINS. On macOS three of uninstall.sh's six directories
# collapse onto one path: LIB_DIR is a subdirectory of DATA_DIR, CONFIG_DIR is
# byte-identical to it, and that same directory is vz.rs's image_root — where
# rootfs.img lives. `rm -rf "$DATA_DIR"`, written for the Linux meaning of
# DATA_DIR ("bundled data: flake, scripts, images"), therefore deleted the whole
# VM. It sat OUTSIDE the --wipe guard, needed no root and had no confirmation
# prompt, and the script then printed "Cache preserved. Use --wipe to remove
# everything." Measured on a macOS dev host 2026-08-17: DATA_DIR 11.83 GiB
# against a CACHE_DIR of 8 KB, i.e. the reassuring path destroyed ~11.8 GiB and
# the scary one added 8 KB.
#
# uninstall.sh is a SHIPPED release artifact (.github/workflows/release.yml
# installs it and asserts it is present), so this is operator-reachable, which
# is why it is pinned rather than merely fixed.
#
# Everything runs against a sandboxed $HOME plus the two fixture seams
# (TILLANDSIAS_UNINSTALL_FAKE_UNAME, TILLANDSIAS_UNINSTALL_INSTALL_DIR), so no
# real path is touched and the macOS arm is exercised from any host.
#
# Exit 0 only when all six assertions pass. Falsifiability spot-checked by
# reverting the guard: the fixture goes red on exactly
# `macos-default-preserves-the-vm-image` and green again on restore.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="$ROOT/scripts/uninstall.sh"
fail=0

[ -f "$UNINSTALL" ] || { echo "FAIL: no uninstall.sh at $UNINSTALL"; exit 1; }

# Build a sandbox HOME that looks like a provisioned host, and echo its path.
# `os` is darwin|linux; the VM image only exists on the macOS layout.
make_sandbox() {
    _os="$1"
    _d="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-fixture.XXXXXX")" || return 1
    if [ "$_os" = "darwin" ]; then
        mkdir -p "$_d/Library/Application Support/tillandsias/lib" \
                 "$_d/Library/Logs/tillandsias" \
                 "$_d/Library/Caches/tillandsias"
        # The expensive artifact: stand-in for the 11.33 GiB rootfs.img.
        echo "rootfs" > "$_d/Library/Application Support/tillandsias/rootfs.img"
        echo "settings" > "$_d/Library/Application Support/tillandsias/settings.json"
        echo "cache" > "$_d/Library/Caches/tillandsias/blob"
    else
        mkdir -p "$_d/.local/share/tillandsias" "$_d/.local/lib/tillandsias" \
                 "$_d/.config/tillandsias" "$_d/.local/state/tillandsias" \
                 "$_d/.cache/tillandsias"
        echo "bundled" > "$_d/.local/share/tillandsias/flake.nix"
    fi
    echo "$_d"
}

# Run the real uninstaller against a sandbox. Never touches a real path.
run_uninstall() {
    _home="$1"; _os="$2"; shift 2
    _fake="Linux"; [ "$_os" = "darwin" ] && _fake="Darwin"
    mkdir -p "$_home/fixture-bin"
    HOME="$_home" \
    TILLANDSIAS_UNINSTALL_FAKE_UNAME="$_fake" \
    TILLANDSIAS_UNINSTALL_INSTALL_DIR="$_home/fixture-bin" \
        bash "$UNINSTALL" "$@" 2>&1
}

check() {
    _name="$1"; _cond="$2"
    if [ "$_cond" = "0" ]; then
        echo "ok: $_name"
    else
        echo "FAIL: $_name"
        fail=1
    fi
}

# ── 1. THE REGRESSION ITSELF: macOS without --wipe must keep the VM image ─────
d="$(make_sandbox darwin)"
out="$(run_uninstall "$d" darwin)"
vm="$d/Library/Application Support/tillandsias/rootfs.img"
[ -f "$vm" ]; check "macos-default-preserves-the-vm-image" "$?"
[ ! -d "$d/Library/Logs/tillandsias" ]; check "macos-default-still-removes-logs" "$?"

# ── 2. The message must not claim a preservation it did not perform ──────────
case "$out" in
    *"VM image, settings and cache preserved"*) check "macos-default-message-names-the-vm" 0 ;;
    *) echo "FAIL: macos-default-message-names-the-vm — got: $(printf '%s' "$out" | grep -i preserved)"; fail=1 ;;
esac
# And it must NOT have warned that the VM dir "will be removed" — the preamble
# is the only notice the user gets; there is no confirmation prompt.
case "$out" in
    *"Application Support/tillandsias/ (app data"*)
        echo "FAIL: macos-default-preamble-must-not-list-the-vm-as-removed"; fail=1 ;;
    *) check "macos-default-preamble-does-not-list-the-vm-as-removed" 0 ;;
esac
rm -rf "$d"

# ── 3. --wipe still removes everything, or the escape hatch is a lie ─────────
d="$(make_sandbox darwin)"
out="$(run_uninstall "$d" darwin --wipe)"
[ ! -e "$d/Library/Application Support/tillandsias/rootfs.img" ]
check "macos-wipe-removes-the-vm-image" "$?"
rm -rf "$d"

# ── 4. NEGATIVE CONTROL: Linux behaviour must be unchanged ───────────────────
# Without this, a "fix" that preserved DATA_DIR on BOTH platforms would pass
# every test above while silently breaking the Linux uninstall, where DATA_DIR
# genuinely is cheap-to-reinstall bundled data and removing it is correct.
d="$(make_sandbox linux)"
out="$(run_uninstall "$d" linux)"
[ ! -e "$d/.local/share/tillandsias/flake.nix" ]
check "linux-default-still-removes-bundled-data" "$?"
rm -rf "$d"

if [ "$fail" -eq 0 ]; then
    echo "ok: uninstall-preserves-vm 6/6"
    exit 0
fi
echo "FAIL: uninstall-preserves-vm had failures"
exit 1
