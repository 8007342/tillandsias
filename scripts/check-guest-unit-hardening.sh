#!/usr/bin/env bash
# @trace spec:vm-provisioning-lifecycle, spec:vsock-transport
# freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-17 verdict=refreshed scope=309 authoring
#
# Guest headless unit hardening guard (order 309, criterion 3 — static half).
#
# WHY THIS EXISTS. Order 308 shipped `NoNewPrivileges=yes` +
# `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` on the guest headless unit as a
# zero-trust checklist item, and it wedged EVERY podman operation. The
# mechanism is the part worth remembering:
#
#     a cap-stripped uid-0 podman SELECTS ROOTLESS MODE and wedges every ensure
#
# podman inspects its own capability state and switches behaviour. So the unit
# that FORKS PODMAN cannot be confined at all — not "needs the right caps",
# cannot. Re-adding those directives without first splitting the listener from
# the orchestrator (the design drafted in
# plan/issues/headless-least-privilege-split-design-2026-08-17.md) reproduces
# the outage.
#
# The 2026-08-17 audit found the guest units carry zero such directives today,
# which is correct-by-accident: nothing prevented their return. This makes it
# correct-by-construction.
#
# SCOPE, AND ITS EXPIRY. This guards the unit that forks podman. When 309's
# split lands, the LISTENER unit should be confined — and confined hard — so
# this check must then be re-aimed at the orchestrator unit only. It is a
# guard against regression, not an argument that confinement is wrong.
#
# Grammar (one line on stdout):
#   ok:guest-unit-unconfined     — no 308-family directive in a podman-forking unit
#   blocked:guest-unit-hardened:<count>
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Directives that make podman re-decide it is rootless, plus the sandboxing
# family that would break its namespace and mount work for the same reason.
PAT='NoNewPrivileges|CapabilityBoundingSet|AmbientCapabilities|ProtectSystem|ProtectHome|PrivateTmp|PrivateDevices|PrivateUsers|RestrictNamespaces|SystemCallFilter|ReadOnlyPaths|ProtectKernelModules|ProtectKernelTunables|LockPersonality|MemoryDenyWriteExecute|RestrictSUIDSGID'

# Each entry: <file>:<start-marker>:<end-marker>. The unit text is embedded in
# Rust source (a heredoc in the VZ provisioning script, a string literal in the
# WSL one), so the region is bounded by markers rather than parsed as an INI.
UNITS="crates/tillandsias-vm-layer/src/vz.rs|cat > /etc/systemd/system/tillandsias-headless.service|^EOF$
crates/tillandsias-vm-layer/src/wsl.rs|cat > /etc/systemd/system/tillandsias-headless.service|systemctl enable tillandsias-headless.service"

hits=0
found_any_unit=0
while IFS='|' read -r file start end; do
    [ -n "${file:-}" ] || continue
    [ -f "$file" ] || continue
    region="$(awk -v s="$start" -v e="$end" '
        index($0, s) { inblock = 1 }
        inblock { print }
        inblock && $0 ~ e && index($0, s) == 0 { exit }
    ' "$file")"
    [ -n "$region" ] || continue
    found_any_unit=1
    bad="$(printf '%s\n' "$region" | grep -nE "$PAT" || true)"
    if [ -n "$bad" ]; then
        echo "[check-guest-unit-hardening] $file — the guest headless unit forks podman and must not be confined:" >&2
        printf '%s\n' "$bad" | head -5 >&2
        hits=$((hits + 1))
    fi
done <<EOF
$UNITS
EOF

if [ "$found_any_unit" -eq 0 ]; then
    # Fail closed: if the markers stopped matching, the guard is silently
    # guarding nothing — the exact shape 700-nz4n exists to refuse.
    echo "[check-guest-unit-hardening] could not locate any guest headless unit text; the markers have drifted and this guard is inert" >&2
    echo "blocked:guest-unit-not-found"
    exit 1
fi

if [ "$hits" -gt 0 ]; then
    echo "[check-guest-unit-hardening] Order 308 shipped exactly this and wedged every podman ensure: a cap-stripped uid-0 podman selects ROOTLESS mode. Confinement requires the listener/orchestrator split first — see plan/issues/headless-least-privilege-split-design-2026-08-17.md (order 309). If the split HAS landed, re-aim this guard at the orchestrator unit rather than deleting it." >&2
    echo "blocked:guest-unit-hardened:$hits"
    exit 1
fi
echo "ok:guest-unit-unconfined"
exit 0
