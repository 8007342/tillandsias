#!/usr/bin/env bash
# scripts/wsl-build/build-forge.sh — build the Tillandsias forge WSL distro.
#
# @trace spec:cross-platform, spec:default-image
# @cheatsheet runtime/wsl-on-windows.md
#
# Replicates images/default/Containerfile imperatively in WSL.
# This is the heaviest service: Fedora-minimal + dnf (~50 packages) +
# npm globals + pipx tools + upstream binaries (yq, grpcurl, gradle,
# geckodriver, flutter) + coding agents + cheatsheets.
#
# Resulting tarball is large (~5-7 GB). Build time on a fresh host is
# ~15-25 minutes depending on network throughput.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

SERVICE=forge
FEDORA_BASE="fedora-minimal-43"
DISTRO_TMP="tillandsias-build-${SERVICE}"
OUT_TAR="${TILL_WSL_OUT}/tillandsias-${SERVICE}.tar"
OUT_TAR_WIN=$(to_winpath "$OUT_TAR")

cleanup() {
    if [[ "$TILL_HAS_WSL" == 1 ]]; then
        wsl_unregister_quiet "$DISTRO_TMP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Stage cheatsheets/ into images/default/.cheatsheets/ — same logic
# scripts/build-image.sh uses for the podman path.
STAGED_CHEATS="${TILL_REPO_ROOT}/images/default/.cheatsheets"
if [[ -d "${TILL_REPO_ROOT}/cheatsheets" ]]; then
    log "staging cheatsheets/ into forge build context"
    rm -rf "$STAGED_CHEATS"
    cp -r "${TILL_REPO_ROOT}/cheatsheets" "$STAGED_CHEATS"
else
    log "WARNING: no cheatsheets/ dir; using placeholder"
    mkdir -p "$STAGED_CHEATS"
    echo "Cheatsheets directory missing at build time" > "$STAGED_CHEATS/MISSING.md"
fi

base_tar=$("${SCRIPT_DIR}/bases.sh" "$FEDORA_BASE")
base_tar_win=$(to_winpath "$base_tar")

wsl_import_temp "$DISTRO_TMP" "$base_tar_win"

# ── Phase A: system packages via microdnf ─────────────────────
log "Phase A: microdnf install (~50 packages)"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
microdnf install -y \
    glibc-langpack-en \
    bash coreutils findutils grep sed gawk tar gzip xz unzip zip bzip2 zstd \
    procps-ng shadow-utils ca-certificates which file less tree \
    fish zsh \
    git git-lfs gh curl wget jq ripgrep fd-find fzf \
    vim nano man-db \
    gcc gcc-c++ clang lld llvm make cmake ninja-build \
    autoconf automake libtool pkgconf pkgconf-pkg-config patch \
    gdb strace ltrace binutils \
    python3 python3-pip python3-devel python3-virtualenv pipx \
    nodejs npm \
    java-21-openjdk-devel maven \
    golang \
    rust cargo rust-std-static \
    sqlite postgresql \
    openssh-clients rsync iputils iproute bind-utils \
    bash-completion socat netcat openssl \
    ShellCheck shfmt protobuf-compiler protobuf-devel xmlstarlet libxml2 \
    chromium-headless firefox chromedriver
microdnf clean all
EOF_SCRIPT

# ── Phase B: npm globals ──────────────────────────────────────
log "Phase B: npm install -g yarn pnpm"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
npm install -g --prefix=/usr yarn pnpm
yarn --version
pnpm --version
EOF_SCRIPT

# ── Phase C: pipx tools ───────────────────────────────────────
log "Phase C: pipx install ruff black mypy pytest httpie uv poetry"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
export PIPX_HOME=/opt/pipx
export PIPX_BIN_DIR=/usr/local/bin
mkdir -p "$PIPX_HOME"
pipx install --global ruff
pipx install --global black
pipx install --global mypy
pipx install --global pytest
pipx install --global httpie
pipx install --global uv
pipx install --global poetry
EOF_SCRIPT

# ── Phase D: upstream binaries ────────────────────────────────
log "Phase D: gradle, yq, grpcurl, geckodriver"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux

# Gradle
GRADLE_VERSION=8.10
curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip
unzip -q /tmp/gradle.zip -d /opt
mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle
rm /tmp/gradle.zip
ln -sf /opt/gradle/bin/gradle /usr/local/bin/gradle

# yq + grpcurl
YQ_VERSION=4.45.1
GRPCURL_VERSION=1.9.1
curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
/usr/local/bin/yq --version
curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" -o /tmp/grpcurl.tar.gz
tar -xzf /tmp/grpcurl.tar.gz --no-same-owner -C /usr/local/bin grpcurl
chmod +x /usr/local/bin/grpcurl
rm /tmp/grpcurl.tar.gz

# chromium-headless symlink
ln -sf /usr/lib64/chromium-browser/headless_shell /usr/local/bin/chromium-headless

# geckodriver
GECKODRIVER_VERSION=0.36.0
curl -fsSL "https://github.com/mozilla/geckodriver/releases/download/v${GECKODRIVER_VERSION}/geckodriver-v${GECKODRIVER_VERSION}-linux64.tar.gz" -o /tmp/geckodriver.tar.gz
tar -xzf /tmp/geckodriver.tar.gz --no-same-owner -C /usr/local/bin geckodriver
chmod +x /usr/local/bin/geckodriver
rm /tmp/geckodriver.tar.gz
EOF_SCRIPT

# ── Phase E: Flutter SDK (heavy ~1 GB) ────────────────────────
log "Phase E: Flutter SDK (this is heavy)"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
FLUTTER_VERSION=3.24.5
curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" -o /tmp/flutter.tar.xz
tar -xJf /tmp/flutter.tar.xz -C /opt
rm /tmp/flutter.tar.xz
git config --system --add safe.directory /opt/flutter
/opt/flutter/bin/flutter --no-version-check config --no-analytics
/opt/flutter/bin/flutter --no-version-check precache --linux --web --no-android --no-ios --no-macos --no-windows
chmod -R a+rX /opt/flutter
EOF_SCRIPT

# ── Phase F: coding agents ────────────────────────────────────
log "Phase F: claude, openspec, opencode"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
mkdir -p /opt/agents/claude /opt/agents/openspec /opt/agents/opencode/bin
npm install -g --prefix=/opt/agents/claude @anthropic-ai/claude-code
npm install -g --prefix=/opt/agents/openspec @fission-ai/openspec
ln -sf /opt/agents/claude/bin/claude /usr/local/bin/claude
ln -sf /opt/agents/openspec/bin/openspec /usr/local/bin/openspec
curl -fsSL https://opencode.ai/install | OPENCODE_INSTALL_DIR=/opt/agents/opencode bash
if [ ! -x /opt/agents/opencode/bin/opencode ] && [ -x /root/.opencode/bin/opencode ]; then
    cp /root/.opencode/bin/opencode /opt/agents/opencode/bin/opencode
fi
rm -rf /root/.opencode
ln -sf /opt/agents/opencode/bin/opencode /usr/local/bin/opencode
/usr/local/bin/claude --version
/usr/local/bin/openspec --version
/usr/local/bin/opencode --version
EOF_SCRIPT

# ── Phase G: forge user + dirs ────────────────────────────────
log "Phase G: forge user, dirs, /etc/skel"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
useradd -u 1000 -m -s /bin/bash forge
mkdir -p /home/forge/src \
         /home/forge/.cache/tillandsias \
         /home/forge/.config/opencode \
         /home/forge/.config/fish/conf.d \
         /etc/skel/.config/fish \
         /usr/local/lib/tillandsias \
         /usr/local/share/tillandsias \
         /etc/tillandsias/locales \
         /opt/agents/tillandsias-cli/bin \
         /opt/cheatsheets-image
chmod 1777 /tmp
EOF_SCRIPT

# ── Phase H: copy image files (entrypoints, configs, shells, locales, CLIs) ──
log "Phase H: copying entrypoint scripts and configs"
IMG="${TILL_REPO_ROOT}/images/default"
wsl_copy_into "$DISTRO_TMP" "${IMG}/lib-common.sh" "/usr/local/lib/tillandsias/lib-common.sh"
wsl_copy_into "$DISTRO_TMP" "${IMG}/entrypoint.sh" "/usr/local/bin/tillandsias-entrypoint.sh"
wsl_copy_into "$DISTRO_TMP" "${IMG}/entrypoint-forge-opencode.sh" "/usr/local/bin/entrypoint-forge-opencode.sh"
wsl_copy_into "$DISTRO_TMP" "${IMG}/entrypoint-forge-opencode-web.sh" "/usr/local/bin/entrypoint-forge-opencode-web.sh"
wsl_copy_into "$DISTRO_TMP" "${IMG}/entrypoint-forge-claude.sh" "/usr/local/bin/entrypoint-forge-claude.sh"
wsl_copy_into "$DISTRO_TMP" "${IMG}/entrypoint-terminal.sh" "/usr/local/bin/entrypoint-terminal.sh"
wsl_copy_into "$DISTRO_TMP" "${IMG}/sse-keepalive-proxy.js" "/usr/local/bin/sse-keepalive-proxy.js"
wsl_copy_into "$DISTRO_TMP" "${IMG}/opencode.json" "/home/forge/.config/opencode/config.json"
wsl_copy_into "$DISTRO_TMP" "${IMG}/config-overlay/opencode/tui.json" "/home/forge/.config/opencode/tui.json"
wsl_copy_into "$DISTRO_TMP" "${IMG}/shell/bashrc" "/etc/skel/.bashrc"
wsl_copy_into "$DISTRO_TMP" "${IMG}/shell/zshrc" "/etc/skel/.zshrc"
wsl_copy_into "$DISTRO_TMP" "${IMG}/shell/config.fish" "/etc/skel/.config/fish/config.fish"
wsl_copy_into "$DISTRO_TMP" "${IMG}/shell/config.fish" "/home/forge/.config/fish/conf.d/tillandsias.fish"
wsl_copy_into "$DISTRO_TMP" "${IMG}/shell/bashrc" "/home/forge/.bashrc"
wsl_copy_into "$DISTRO_TMP" "${IMG}/shell/zshrc" "/home/forge/.zshrc"
wsl_copy_into "$DISTRO_TMP" "${IMG}/forge-welcome.sh" "/usr/local/share/tillandsias/forge-welcome.sh"

# CLI tools.
for cli in tillandsias-inventory tillandsias-services tillandsias-models tillandsias-logs; do
    wsl_copy_into "$DISTRO_TMP" "${IMG}/cli/${cli}" "/opt/agents/tillandsias-cli/bin/${cli}"
done

# Locales — recursive copy.
log "copying locales/ recursively"
locale_files=$(find "${IMG}/locales" -type f 2>/dev/null)
for f in $locale_files; do
    rel="${f#${IMG}/locales/}"
    wsl_copy_into "$DISTRO_TMP" "$f" "/etc/tillandsias/locales/$rel"
done

# Cheatsheets — recursive copy.
log "copying staged cheatsheets to /opt/cheatsheets-image/"
# Use a tar-piped approach for speed (many small files).
tar_path=$(mktemp /tmp/cheatsheets-XXXXXX.tar)
tar -cf "$tar_path" -C "$STAGED_CHEATS" .
wsl_copy_into "$DISTRO_TMP" "$tar_path" "/tmp/cheatsheets.tar"
wsl_run_in "$DISTRO_TMP" 'tar -xf /tmp/cheatsheets.tar -C /opt/cheatsheets-image && rm -f /tmp/cheatsheets.tar'
rm -f "$tar_path"

# .bash_profile so login bash sources .bashrc (not a COPY in the
# Containerfile, but a printf > redirect).
wsl_run_in "$DISTRO_TMP" "printf '# Login bash sources .bashrc so PATH + welcome + prompt apply.\n[ -f ~/.bashrc ] && . ~/.bashrc\n' > /home/forge/.bash_profile"

# ── Phase I: chmod + ownership ────────────────────────────────
log "Phase I: chmod entrypoints, chown /home/forge"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
chmod +x /usr/local/bin/tillandsias-entrypoint.sh \
         /usr/local/bin/entrypoint-forge-opencode.sh \
         /usr/local/bin/entrypoint-forge-opencode-web.sh \
         /usr/local/bin/entrypoint-forge-claude.sh \
         /usr/local/bin/entrypoint-terminal.sh \
         /usr/local/bin/sse-keepalive-proxy.js \
         /usr/local/share/tillandsias/forge-welcome.sh
chmod +x /opt/agents/tillandsias-cli/bin/*
ln -sf /opt/agents/tillandsias-cli/bin/tillandsias-inventory /usr/local/bin/tillandsias-inventory
ln -sf /opt/agents/tillandsias-cli/bin/tillandsias-services /usr/local/bin/tillandsias-services
ln -sf /opt/agents/tillandsias-cli/bin/tillandsias-models /usr/local/bin/tillandsias-models
ln -sf /opt/agents/tillandsias-cli/bin/tillandsias-logs /usr/local/bin/tillandsias-logs
chmod -R a+rX /opt/cheatsheets-image
chmod -R go-w /opt/cheatsheets-image
chown -R 1000:1000 /home/forge
EOF_SCRIPT

# ── Phase J: cleanup, export ──────────────────────────────────
wsl_run_in "$DISTRO_TMP" 'rm -rf /var/cache/yum/* /var/cache/dnf/* /tmp/* 2>/dev/null || true'

mkdir -p "$(dirname "$OUT_TAR")"
wsl_export_and_unregister "$DISTRO_TMP" "$OUT_TAR_WIN"

write_meta "$SERVICE" "forge" 1000 0

log "DONE: ${OUT_TAR}"
ls -lh "$OUT_TAR" >&2
