#!/usr/bin/env bash
# install-forge-swap-service.sh — the ONE-TIME root step behind per-launch swap.
# @trace order:1376-8zdz, order:1380-zmpi (the installer's PENDING ACTIONS banner prints it)
#
# The tray never runs sudo. The operator runs this once:
#     sudo bash scripts/install-forge-swap-service.sh
# It installs (design plan/issues/forge-memory-swap-architecture-design-2026-09-26.md §9):
#   /usr/local/libexec/tillandsias-swap                  root-owned helper (0755)
#   /etc/systemd/system/tillandsias-swap@.service        per-launch template (never enabled)
#   /etc/systemd/system/tillandsias-swap-gc.{service,timer}  lease GC every 2 min
#   /etc/polkit-1/rules.d/50-tillandsias-swap.rules      start/stop of that template only
#   /etc/tillandsias/swap.conf                           size/dir/priority (kept if present)
#   group "tillandsias", with the installing user added
# On Silverblue /usr/local is /var/usrlocal: every path above is in /etc or
# /var, persistent across deployments, no layering, no RPM (§9.8).
# IDEMPOTENT: a second run rewrites the same bytes and reports the same verdict.
#
#   --prefix DIR   install under DIR instead of / (the test uses this; no root
#                  needed and no system action is taken)
#   --user NAME    the user the polkit rule names (default: $SUDO_USER)
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/forge-swap"
prefix=/; user="${SUDO_USER:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        --user) user="$2"; shift 2 ;;
        *) echo "refused:install-swap:unknown-argument:$1"; exit 64 ;;
    esac
done
live=0; [ "$prefix" = / ] && live=1
if [ "$live" = 1 ] && [ "$(id -u)" != 0 ]; then
    echo "refused:install-swap:needs-root — run: sudo bash $0"
    exit 1
fi
[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "refused:install-swap:user:'$user' — pass --user or run through sudo"; exit 1; }
for f in tillandsias-swap tillandsias-swap@.service tillandsias-swap-gc.service tillandsias-swap-gc.timer 50-tillandsias-swap.rules swap.conf; do
    [ -f "$SRC/$f" ] || { echo "refused:install-swap:missing-source:$SRC/$f"; exit 1; }
done

P="${prefix%/}"
helper_path="/usr/local/libexec/tillandsias-swap"
[ "$live" = 1 ] || helper_path="$P$helper_path"   # a scratch install points at itself
units="$P/etc/systemd/system"
mkdir -p "$P/usr/local/libexec" "$units" "$P/etc/polkit-1/rules.d" "$P/etc/tillandsias" || exit 1

install -m 0755 "$SRC/tillandsias-swap" "$P/usr/local/libexec/tillandsias-swap" || exit 1
for u in tillandsias-swap@.service tillandsias-swap-gc.service tillandsias-swap-gc.timer; do
    sed "s|@HELPER@|$helper_path|g" "$SRC/$u" > "$units/$u.tmp" && mv "$units/$u.tmp" "$units/$u" && chmod 0644 "$units/$u" || exit 1
done
sed "s|@INSTALL_USER@|$user|g" "$SRC/50-tillandsias-swap.rules" > "$P/etc/polkit-1/rules.d/50-tillandsias-swap.rules" \
    && chmod 0644 "$P/etc/polkit-1/rules.d/50-tillandsias-swap.rules" || exit 1
# The operator's edits to the config win over a re-install.
[ -f "$P/etc/tillandsias/swap.conf" ] || install -m 0644 "$SRC/swap.conf" "$P/etc/tillandsias/swap.conf" || exit 1

if [ "$live" = 1 ]; then
    groupadd -f tillandsias || exit 1
    usermod -aG tillandsias "$user" || exit 1
    systemctl daemon-reload || exit 1
    systemctl enable --now tillandsias-swap-gc.timer >/dev/null || exit 1
    # polkitd re-reads rules.d on change; the group resolves at check time
    # (getgrouplist), so no re-login is needed (§9.5).
fi
echo "ok:install-swap:prefix=$prefix:user=$user:helper=$helper_path"
