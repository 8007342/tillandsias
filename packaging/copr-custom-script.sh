#!/usr/bin/env bash
# COPR Custom Source script
# Called by COPR to obtain the SRPM inputs for a build.
# Downloads the latest pre-built RPM from GitHub Releases and writes a
# minimal .spec so COPR can repackage it.
set -euo pipefail

REPO="8007342/tillandsias"
RELEASE_URL="https://api.github.com/repos/${REPO}/releases/latest"

# --- Fetch release metadata ---------------------------------------------------
RELEASE_JSON=$(curl -fsSL "$RELEASE_URL")

VERSION=$(echo "$RELEASE_JSON" | grep -oP '"tag_name":\s*"v\K[^"]+')
if [ -z "$VERSION" ]; then
    echo "ERROR: Could not determine version from latest release" >&2
    exit 1
fi

RPM_URL=$(echo "$RELEASE_JSON" \
    | grep -oP '"browser_download_url":\s*"\K[^"]*\.rpm' \
    | grep 'x86_64' \
    | head -1)

if [ -z "$RPM_URL" ]; then
    echo "ERROR: No x86_64 RPM found in latest release (v${VERSION})" >&2
    exit 1
fi

# --- Download the RPM ---------------------------------------------------------
echo "Downloading: ${RPM_URL}"
curl -fsSL -o "tillandsias-${VERSION}-1.x86_64.rpm" "$RPM_URL"
echo "Downloaded tillandsias-${VERSION}-1.x86_64.rpm"

# --- Write the spec with the resolved version ---------------------------------
sed "s/%{version}/${VERSION}/g" packaging/tillandsias.spec \
    > "tillandsias.spec"

echo "resultdir ."
