#!/usr/bin/env bash
# @trace spec:vm-recipe-provisioning
#
# test-macos-model-share-writable.sh — order 1183-j9dk.
#
# WHAT IT PROTECTS. On macOS the model cache is a virtiofs SHARE, not the
# podman volume the Linux lane uses (order 313). The engine self-installs into
# `${OLLAMA_MODELS}.tools/ollama` — TWO levels — and if the inference container
# cannot create that path the engine FATALs on every launch and the cache stays
# empty forever, so every downstream claim about local experts on macOS rests
# on a lane that never ran.
#
# THE MECHANISM IS SELINUX LABELLING, NOT OWNERSHIP. Measured on
# tlatoanis-macbook-air 2026-09-18 against a live guest, with the arms that
# discriminate rather than merely exhibit:
#   guest root, outside a container, any depth          -> OK
#   unconfined container uid 1000, mkdir at mount ROOT  -> OK
#   unconfined container uid 1000, one level DOWN       -> Permission denied
#   unconfined container as ROOT (--user 0:0), one down -> Permission denied
#   share chmod 0777 first                              -> still denied
#   `chown` inside the share                            -> returns 0, does NOT apply
#   same command with --security-opt label=disable      -> OK
# Container-ROOT failing while guest-root succeeds rules out uid, ownership and
# mode together. macOS Virtualization.framework virtiofs cannot persist security
# xattrs, so a file created in the share reads back without an inheritable label
# and confined container_t is denied. DO NOT go after "make the share writable
# by uid 1000": that sends the reader after a chown that silently no-ops.
#
# `:z`/`:Z` ON THE BIND ARE NOT THE REMEDY — both were measured and both FAILED,
# because relabelling writes xattrs this filesystem cannot keep. `:Z` was worse
# than useless: it stamped a per-container MCS category onto the SHARED
# directory that OUTLIVED the container and then denied every later container,
# including the case that had been working.
#
# WHY THE PRODUCT SURVIVES, and what this fixture therefore pins: the inference
# container already ships `--security-opt=label=disable` (build_inference_run_args
# in crates/tillandsias-headless/src/main.rs), which is the ONLY reason the
# share is writable. That flag is load-bearing, and nothing said so. Remove it
# for tidiness and macOS inference dies from a clean cache with no other signal.
#
# WHY THE PRECONDITION IS THE WHOLE TEST. The defect exists ONLY before
# `.tools/` is created: once it is there the extract has a target and every
# later launch works. A run against a POPULATED cache verifies nothing, so this
# refuses rather than guesses — and that guard has already fired once here, on
# residue a killed probe left behind.
#
# WHY IT GOES TWO LEVELS DEEP. A single-level mkdir in the mount ROOT SUCCEEDS
# as uid 1000 — the mount root itself carries container_file_t. A probe that
# stops there reports green against a broken host, and one already did: this
# packet's own reproduce command was single-level and produced a false
# retraction that propagated. USE THE PRODUCT'S SHAPE, NOT A PARAPHRASE.
#
# GRAMMAR — exactly one line:
#   ^(ok:macos-model-share-writable:[0-9]+|violation:macos-model-share-writable:.*|unsupported:macos-model-share-writable:.*)$
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Arm 0: the source-level guard, which needs no VM and no macOS ----------
# If the load-bearing flag leaves the run-args, say so on every host, not only
# on the one macOS box that can boot a guest.
HEADLESS="$ROOT/crates/tillandsias-headless/src/main.rs"
if [ -f "$HEADLESS" ]; then
    if ! grep -q '"--security-opt=label=disable".into()' "$HEADLESS"; then
        echo "violation:macos-model-share-writable:inference-run-args-lost-label-disable"
        exit 1
    fi
fi

[ "$(uname -s)" = "Darwin" ] || {
    # The source guard above still ran, and that is the half a Linux CI lane
    # can honestly answer. Say which half was skipped rather than report green.
    echo "unsupported:macos-model-share-writable:not-darwin-source-arm-only"
    exit 0
}

TRAY="${TILLANDSIAS_TRAY_BIN:-$ROOT/dist/Tillandsias.app/Contents/MacOS/tillandsias-tray}"
[ -x "$TRAY" ] || {
    # A bare target/release binary has no com.apple.security.virtualization
    # entitlement and cannot start a VM at all — name that, rather than let the
    # caller meet it as a confusing "boot loader is invalid".
    echo "unsupported:macos-model-share-writable:no-app-bundle-run-scripts/build-macos-tray.sh"
    exit 0
}

HOST_CACHE="$HOME/Library/Caches/tillandsias/models"
if [ -d "$HOST_CACHE" ] && [ -n "$(ls -A "$HOST_CACHE" 2>/dev/null)" ]; then
    echo "unsupported:macos-model-share-writable:cache-not-empty-precondition-unmet"
    exit 0
fi

OUT="$(mktemp -t macos-model-share-writable)"
trap 'rm -f "$OUT"' EXIT

# Both live arms run the SAME command against the SAME mount. The only
# difference is the one flag this fixture claims is load-bearing.
"$TRAY" --exec-guest '
M=/root/.cache/tillandsias/models
IMG=localhost/tillandsias-inference:latest
# verbatim from build_inference_run_args, minus the parts that need the enclave
PFLAGS="--cap-drop=ALL --security-opt=no-new-privileges --security-opt=label=disable --userns=keep-id --pids-limit=1024"
MUTATED="--cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id --pids-limit=1024"

podman image exists "$IMG" || { echo "ARM0:no-inference-image"; exit 0; }
mountpoint -q "$M" || { echo "ARM0:model-cache-not-mounted"; exit 0; }

probe() {
  # The product shape: TWO levels, then a FILE — a directory that cannot hold
  # the extracted engine payload is no better than no directory.
  rm -rf "$M/.tools-probe"
  podman run --rm $1 -v "$M:/home/ollama/.ollama/models:rw" --entrypoint sh "$IMG" -c \
    "mkdir -p /home/ollama/.ollama/models/.tools-probe/ollama && touch /home/ollama/.ollama/models/.tools-probe/ollama/payload" \
    >/dev/null 2>&1 && echo pass || echo fail
  rm -rf "$M/.tools-probe"
}

echo "ARM1:$(probe "$PFLAGS")"
echo "ARM2:$(probe "$MUTATED")"
' >"$OUT" 2>&1

arm0="$(sed -n 's/^ARM0://p' "$OUT" | tr -d '\r')"
arm1="$(sed -n 's/^ARM1://p' "$OUT" | tr -d '\r')"
arm2="$(sed -n 's/^ARM2://p' "$OUT" | tr -d '\r')"

if [ -n "$arm0" ]; then
    echo "unsupported:macos-model-share-writable:$arm0"
    exit 0
fi
if [ -z "$arm1" ] || [ -z "$arm2" ]; then
    echo "violation:macos-model-share-writable:no-arm-output-guest-unreachable"
    exit 1
fi
if [ "$arm1" != "pass" ]; then
    echo "violation:macos-model-share-writable:product-flags-cannot-create-the-engine-payload-dir"
    exit 1
fi
if [ "$arm2" != "fail" ]; then
    # The control did not red. Either the mechanism moved or the probe stopped
    # measuring it — either way arm 1's green means nothing on its own.
    echo "violation:macos-model-share-writable:mutation-arm-passed-fixture-does-not-discriminate"
    exit 1
fi
echo "ok:macos-model-share-writable:3"
