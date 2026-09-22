#!/usr/bin/env bash
# @trace spec:inference-container
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
# GRAMMAR — one line, or two on a could-not-run (see below):
#   ^(ok:macos-model-share-writable:[0-9]+|violation:macos-model-share-writable:.*|unsupported:macos-model-share-writable:.*|skip:macos-model-share-writable:.*|refused:macos-model-share-writable:.*)$
#
# EVERY verdict line ends with a subject clause naming the binary that answered
# (1332-tdde). The runner's patterns match by substring, so appending it does
# not disturb them; a reader of any past run can now say WHAT was tested.
#
# A COULD-NOT-RUN PRINTS TWO LINES: the `unsupported:` detail, then the `skip:`
# line the runner scores (1330-i4hu). Order is load-bearing.
set -uo pipefail

# WHICH BINARY ANSWERED (order 1332-tdde). Every verdict carries it, so a reader
# of any past run can say what was tested instead of inferring it from a path.
#
# THE WHOLE `--version` LINE, sha and build stamp included, never a parsed
# field of it. MEASURED: a pre-fix binary at git 2f5f2a90a and a post-fix binary
# at git 65994e1e5 BOTH report "56.9.21.1", so a version comparison reads two
# different subjects as one. A path is not an identity either — the default
# target is a path in the checkout, and what sits there may be ten days old.
SUBJECT="unresolved"
subject_of() {
    [ -x "$1" ] || { printf 'absent(%s)' "$1"; return 0; }
    local line
    line="$("$1" --version 2>/dev/null | head -1)"
    [ -n "$line" ] && printf '%s' "$line" || printf 'unreadable(%s)' "$1"
}
verdict() { echo "$1 subject=[$SUBJECT]"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ROOT MUST BE A CHECKOUT BEFORE ANYTHING DERIVED FROM IT IS TRUSTED (1332-tdde).
#
# A COPY of this script run from outside the tree resolves ROOT to the parent of
# wherever it sits — `/` for a copy in /tmp — and every path built from it then
# describes that place instead of the product. MEASURED: such a copy found no
# app bundle under `/` and said so, which is TRUE about `/` and a FALSE
# description of what happened.
#
# THIS IS A REFUSAL, NOT A COULD-NOT-RUN, and the distinction is deliberate.
# `cannot_run` means "the HOST cannot answer this question" and its terminal
# `skip:` leaves the step out of the rate — correct for a host without a
# bundle, and catastrophic here, because a script that does not know where it
# is cannot be trusted about anything else it reports. Routing this through
# `cannot_run` would turn a red into a silent skip. `refused:` is in the
# runner's failure set (run-litmus-test.sh:966), checked FIRST and
# short-circuiting, so it stays red whatever follows it.
[ -f "$ROOT/build.sh" ] && [ -d "$ROOT/crates" ] || {
    verdict "refused:macos-model-share-writable:root-is-not-a-tillandsias-checkout-$ROOT"
    exit 1
}

# A precondition this fixture cannot satisfy: say what was not tested, then end
# on the line the runner scores (1330-i4hu). scripts/run-litmus-test.sh
# step_terminal_verdict (:960) consults ONLY the last non-empty line and
# recognises only `skip:`/`advisory:`; with the detail line last the step falls
# through to check_signal and :992 returns FAILURE. Never used for a red.
cannot_run() {
    verdict "unsupported:macos-model-share-writable:$1"
    verdict "skip:macos-model-share-writable:$1"
    exit 0
}

# --- Arm 0: the source-level guard, which needs no VM and no macOS ----------
# If the load-bearing flag leaves the run-args, say so on every host, not only
# on the one macOS box that can boot a guest.
HEADLESS="$ROOT/crates/tillandsias-headless/src/main.rs"
if [ -f "$HEADLESS" ]; then
    if ! grep -q '"--security-opt=label=disable".into()' "$HEADLESS"; then
        verdict "violation:macos-model-share-writable:inference-run-args-lost-label-disable"
        exit 1
    fi
fi

# The source guard above still ran, and that is the half a Linux CI lane can
# honestly answer. Say which half was skipped rather than report green.
[ "$(uname -s)" = "Darwin" ] || cannot_run "not-darwin-source-arm-only"

TRAY="${TILLANDSIAS_TRAY_BIN:-$ROOT/dist/Tillandsias.app/Contents/MacOS/tillandsias-tray}"
SUBJECT="$(subject_of "$TRAY")"
# A bare target/release binary has no com.apple.security.virtualization
# entitlement and cannot start a VM at all — name that, rather than let the
# caller meet it as a confusing "boot loader is invalid".
[ -x "$TRAY" ] || cannot_run "no-app-bundle-run-scripts/build-macos-tray.sh"

HOST_CACHE="$HOME/Library/Caches/tillandsias/models"
if [ -d "$HOST_CACHE" ] && [ -n "$(ls -A "$HOST_CACHE" 2>/dev/null)" ]; then
    cannot_run "cache-not-empty-precondition-unmet"
fi

OUT="$(mktemp -t macos-model-share-writable)"
trap 'rm -f "$OUT"' EXIT

# Both live arms run the SAME command against the SAME mount. The only
# difference is the one flag this fixture claims is load-bearing.
"$TRAY" --exec-guest '
M=/root/.cache/tillandsias/models
# 1087-h2z9: resolve the CONCRETE version tag rather than depend on a mutable
# one. A fixture pinned to a floating tag measures whatever happens to carry
# that tag today, which is the opposite of what a regression guard is for; the
# sha256- tags are skipped because the version tag is the one a reader can match
# against a release.
IMG="$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
       | awk -F: '\''$0 ~ /tillandsias-inference/ && $NF != "latest" && $NF !~ /^sha256-/ { print; exit }'\'')"
# verbatim from build_inference_run_args, minus the parts that need the enclave
PFLAGS="--cap-drop=ALL --security-opt=no-new-privileges --security-opt=label=disable --userns=keep-id --pids-limit=1024"
MUTATED="--cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id --pids-limit=1024"

[ -n "$IMG" ] && podman image exists "$IMG" || { echo "ARM0:no-version-tagged-inference-image"; exit 0; }
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
    cannot_run "$arm0"
fi
if [ -z "$arm1" ] || [ -z "$arm2" ]; then
    verdict "violation:macos-model-share-writable:no-arm-output-guest-unreachable"
    exit 1
fi
if [ "$arm1" != "pass" ]; then
    verdict "violation:macos-model-share-writable:product-flags-cannot-create-the-engine-payload-dir"
    exit 1
fi
if [ "$arm2" != "fail" ]; then
    # The control did not red. Either the mechanism moved or the probe stopped
    # measuring it — either way arm 1's green means nothing on its own.
    verdict "violation:macos-model-share-writable:mutation-arm-passed-fixture-does-not-discriminate"
    exit 1
fi
verdict "ok:macos-model-share-writable:3"
