#!/usr/bin/env bash
# =============================================================================
# Tillandsias — convert a materialized rootfs `.tar` into a VFR-bootable raw
# `.img` (GPT + EFI System Partition + ext4 root). Linux-runnable per D6 —
# meant to run on the CI runner that produces both `.tar` and `.img`
# artifacts for the recipe-publish workflow.
#
# Inputs:
#   $1  Path to the rootfs `.tar` (uncompressed; or `.tar.gz`/`.tar.xz` auto-
#       detected via the file's first bytes).
#   $2  Path to write the output `.img` (overwritten if exists).
#
# Env (optional):
#   IMG_SIZE_GB         Output image size in GB (default: 8).
#   ESP_SIZE_MB         EFI System Partition size in MB (default: 256).
#   ROOTFS_LABEL        ext4 label for the root partition (default: rootfs).
#
# Requires (Linux): parted, sgdisk, losetup, mkfs.vfat, mkfs.ext4, tar, sync.
# Refuses to run on macOS (no mkfs.ext4 native) — that's the whole point
# of D6: the conversion happens on Linux CI, the macOS host just fetches
# the resulting `.img`.
#
# @trace openspec/changes/vm-recipe-provisioning §3.7.1, §2b.2, §D6
# =============================================================================

set -euo pipefail

die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

# ── 1. Gates ────────────────────────────────────────────────────────────
[[ $# -eq 2 ]] || die "usage: $0 <rootfs.tar> <output.img>"
[[ "$(uname -s)" == "Linux" ]] \
    || die "this script must run on Linux (mkfs.ext4 is not native to macOS)"
(( EUID == 0 )) \
    || die "this script needs root for losetup + mount (try: sudo $0 …)"

ROOTFS_TAR="$1"
OUT_IMG="$2"
IMG_SIZE_GB="${IMG_SIZE_GB:-8}"
ESP_SIZE_MB="${ESP_SIZE_MB:-256}"
ROOTFS_LABEL="${ROOTFS_LABEL:-rootfs}"

[[ -f "$ROOTFS_TAR" ]] || die "rootfs tar not found: $ROOTFS_TAR"

for tool in parted sgdisk losetup mkfs.vfat mkfs.ext4 tar sync mount umount; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

# ── 2. Workspace ────────────────────────────────────────────────────────
WORK="$(mktemp -d -t tillandsias-tar2img.XXXXXX)"
ROOT_MOUNT="$WORK/root"
ESP_MOUNT="$WORK/esp"
mkdir -p "$ROOT_MOUNT" "$ESP_MOUNT"

LOOP_DEV=""
cleanup() {
    set +e
    if [[ -n "$LOOP_DEV" ]]; then
        umount "$ESP_MOUNT" 2>/dev/null
        umount "$ROOT_MOUNT" 2>/dev/null
        losetup -d "$LOOP_DEV" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── 3. Sparse image + partition table ───────────────────────────────────
say "create $OUT_IMG (sparse ${IMG_SIZE_GB}GB)"
rm -f "$OUT_IMG"
truncate -s "${IMG_SIZE_GB}G" "$OUT_IMG"

say "partition (GPT: ESP ${ESP_SIZE_MB}MB + ext4 root)"
parted --script "$OUT_IMG" -- \
    mklabel gpt \
    mkpart ESP fat32 1MiB "$((1 + ESP_SIZE_MB))MiB" \
    mkpart root ext4 "$((1 + ESP_SIZE_MB))MiB" 100% \
    set 1 esp on \
    set 1 boot on

# ── 4. Loop devices ─────────────────────────────────────────────────────
say "losetup"
LOOP_DEV="$(losetup --show -fP "$OUT_IMG")"
ESP_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# Wait briefly for partition device nodes to settle (udev).
sleep 0.5
[[ -b "$ESP_PART"  ]] || die "ESP partition node not present: $ESP_PART"
[[ -b "$ROOT_PART" ]] || die "root partition node not present: $ROOT_PART"

# ── 5. Format ───────────────────────────────────────────────────────────
say "mkfs.vfat (ESP) + mkfs.ext4 (root)"
mkfs.vfat -F 32 -n EFI "$ESP_PART" >/dev/null
mkfs.ext4 -F -L "$ROOTFS_LABEL" "$ROOT_PART" >/dev/null

# ── 6. Mount + extract ──────────────────────────────────────────────────
say "extract $ROOTFS_TAR → root partition"
mount "$ROOT_PART" "$ROOT_MOUNT"
mount "$ESP_PART"  "$ESP_MOUNT"

# tar auto-detects compression via header bytes when -a / --auto-compress
# isn't enough — use -f and let tar pick.
tar -xf "$ROOTFS_TAR" -C "$ROOT_MOUNT"

# ── 7. EFI bootloader placement ─────────────────────────────────────────
# Minimal viable: copy /boot/grub2 (if present in the rootfs) to ESP. A
# real production setup would invoke grub-install or bootctl — but the
# Fedora 44 Container Base ships shim/grub2 binaries that work if placed
# at the canonical EFI/BOOT path.
say "stage EFI bootloader on ESP (best-effort)"
mkdir -p "$ESP_MOUNT/EFI/BOOT" "$ESP_MOUNT/EFI/fedora"

if [[ -d "$ROOT_MOUNT/boot/efi/EFI" ]]; then
    # Already-staged EFI tree from the rootfs (e.g. kernel-core post-install
    # ran efibootmgr). Mirror it onto the ESP.
    cp -a "$ROOT_MOUNT/boot/efi/EFI/." "$ESP_MOUNT/EFI/"
elif [[ -f "$ROOT_MOUNT/usr/share/efi/aarch64/shimaa64.efi" ]] \
  || [[ -f "$ROOT_MOUNT/usr/share/efi/x64/shimx64.efi" ]]; then
    # Source the shim+grub binaries from the package manager's drop zone.
    arch="$(uname -m)"
    case "$arch" in
        aarch64) shim_src="$ROOT_MOUNT/usr/share/efi/aarch64"; bootefi="BOOTAA64.EFI" ;;
        x86_64)  shim_src="$ROOT_MOUNT/usr/share/efi/x64";    bootefi="BOOTX64.EFI"  ;;
        *) die "unsupported arch for shim placement: $arch" ;;
    esac
    cp "$shim_src/shim"*.efi "$ESP_MOUNT/EFI/BOOT/$bootefi"
    cp "$shim_src/grub"*.efi "$ESP_MOUNT/EFI/fedora/" 2>/dev/null || true
else
    say "  (no shim/grub2 found in rootfs — VM may not boot without EFI"
    say "   bootloader staged out-of-band; see vm-recipe-provisioning D5/D6)"
fi

# ── 8. /etc/fstab so the guest mounts root by label ─────────────────────
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"
cat > "$ROOT_MOUNT/etc/fstab" <<EOF
UUID=$ROOT_UUID  /          ext4  defaults,relatime  0  1
UUID=$ESP_UUID   /boot/efi  vfat  defaults,umask=0077 0  2
EOF

# ── 9. Sync + summarize ─────────────────────────────────────────────────
sync
umount "$ESP_MOUNT" "$ROOT_MOUNT"
losetup -d "$LOOP_DEV"; LOOP_DEV=""

SHA="$(sha256sum "$OUT_IMG" | awk '{print $1}')"
SIZE_BYTES="$(stat -c %s "$OUT_IMG")"
SIZE_MIB="$((SIZE_BYTES / 1048576))"
say "done: $OUT_IMG (${SIZE_MIB} MiB allocated, sha256 ${SHA})"
