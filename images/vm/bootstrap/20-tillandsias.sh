#!/usr/bin/env bash
# Step 20 — wire tillandsias-headless into the VM rootfs.
#
# tillandsias-headless is NOT compiled or baked into the image. Per owner
# decision 2026-05-26, the in-VM agent is curl-installed on FIRST BOOT from
# the GitHub release: first boot already downloads the Fedora base, the
# enclave containers, and (on Windows) WSL2 itself, so fetching one ~MB
# binary at that point is negligible. This also fully decouples the
# mac/windows tray builds from the headless binary — the rootfs only needs
# a download URL, never the binary at build time.
#
# This script installs (build-time, inside the recipe container):
#   1. /usr/local/lib/tillandsias/fetch-headless.sh — the first-boot fetcher
#   2. tillandsias-headless-fetch.service — oneshot, runs the fetcher once
#      (ConditionPathExists=!<binary>, so it no-ops on subsequent boots)
#   3. tillandsias-headless.service — the vsock control-wire service,
#      ordered After=+Requires= the fetch unit so it can't start before the
#      binary exists (per RECIPE vsock-listen directive in the Recipefile).
#
# @trace openspec/changes/vm-recipe-provisioning §1.4, §D7

set -euo pipefail

# --- 1. First-boot fetcher script -----------------------------------------
# Resolves the per-arch asset from the GitHub `releases/latest` redirect
# (a stable URL that always points at the newest release's asset). The URL
# base is overridable via the TILLANDSIAS_HEADLESS_URL_BASE env var so a
# future pinned-tag build can drop in an env file without changing this
# script. ca-certificates + curl are installed in the base RUN.
install -d -m 0755 /usr/local/lib/tillandsias
cat > /usr/local/lib/tillandsias/fetch-headless.sh <<'FETCH'
#!/usr/bin/env bash
set -euo pipefail

DEST="/usr/local/bin/tillandsias-headless"
if [[ -x "$DEST" ]]; then
    echo "[fetch-headless] $DEST already present — nothing to do"
    exit 0
fi

ARCH="$(uname -m)"   # x86_64 | aarch64
URL_BASE="${TILLANDSIAS_HEADLESS_URL_BASE:-https://github.com/8007342/tillandsias/releases/latest/download}"
ASSET="tillandsias-headless-${ARCH}-unknown-linux-musl"
URL="${URL_BASE}/${ASSET}"

echo "[fetch-headless] downloading ${URL}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 20 \
    --output "$TMP" "$URL"
install -D -m 0755 "$TMP" "$DEST"
echo "[fetch-headless] installed $DEST"
FETCH
chmod 0755 /usr/local/lib/tillandsias/fetch-headless.sh

# --- 2. First-boot fetch oneshot -------------------------------------------
# ConditionPathExists=! means systemd skips this entirely once the binary is
# in place, so it only does work on the very first boot. Ordered Before= the
# headless service so the binary exists by the time it starts.
cat > /etc/systemd/system/tillandsias-headless-fetch.service <<'EOF'
[Unit]
Description=Fetch tillandsias-headless on first boot
Documentation=https://github.com/8007342/tillandsias
After=network-online.target
Wants=network-online.target
Before=tillandsias-headless.service
ConditionPathExists=!/usr/local/bin/tillandsias-headless

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/tillandsias/fetch-headless.sh
# Give a slow first-boot network time to come up before failing.
TimeoutStartSec=300s

[Install]
WantedBy=multi-user.target
EOF

# --- 3. The headless vsock service -----------------------------------------
# Requires + After the fetch unit so it never launches before the binary is
# downloaded. Listens on vsock 42420 (CONTROL_WIRE_VSOCK_PORT). The RECIPE
# vsock-listen directive in the Recipefile triggers materializer-side
# validation that this unit exists.
cat > /etc/systemd/system/tillandsias-headless.service <<'EOF'
[Unit]
Description=Tillandsias headless (in-VM vsock control wire)
After=network-online.target podman.service tillandsias-headless-fetch.service
Requires=tillandsias-headless-fetch.service
Wants=network-online.target

[Service]
# Type=exec, not notify: tillandsias-headless binds the vsock listener at
# startup but does NOT call sd_notify(READY=1). Under Type=notify systemd
# SIGTERMs the "unfinished" start after the timeout (~17s) and restart-loops
# it, so the listener never reaches `active` and the host has nothing stable
# to connect to (cross-host blocker reported by windows-next 2026-05-27).
# Type=exec marks the unit active once the binary has exec'd successfully,
# which is correct here: the listener binds within milliseconds of exec and
# the host-side connect already retries. (Proper long-term: add sd_notify to
# the binary + restore Type=notify — tracked as a follow-up.)
Type=exec
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
KillSignal=SIGTERM
TimeoutStopSec=20s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable tillandsias-headless-fetch.service
systemctl enable tillandsias-headless.service

echo "[20-tillandsias] done — first-boot fetcher + headless vsock unit enabled"
