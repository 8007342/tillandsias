#!/usr/bin/env bash
# ORDER 747-knbp — an image rebuild must not orphan the tag the INSTALLED
# binary launches by.
#
# The launcher resolves forge/web/proxy/git/inference images as
# `localhost/tillandsias-<img>:v<version>` where <version> is the version of the
# RUNNING (installed) binary, while scripts/build-image.sh tags from the
# checkout's VERSION file and reaps every tillandsias-<img> tag outside its kept
# set. On a host whose installed tray predates the checkout — the normal case
# for "rebuild the image so my fix is live" — the rebuild deleted the launch tag
# and every subsequent forge launch was dead on arrival.
#
# This check DEMONSTRATES the guarantee under a deliberate skew rather than
# arguing it. It drives the real scripts/build-image.sh against a fake podman
# and a fake installed binary inside a temp HOME, and takes the "sources
# unchanged" shortcut so no image is actually built.
#
# Three arms:
#   1. SKEW           — installed v differs from VERSION: the installed tag
#                       exists after the rebuild.
#   2. SKEW/PRE-EXIST — the installed tag already present before the rebuild is
#                       not reaped (the exact 2026-08-15 failure).
#   3. NEGATIVE       — installed v == VERSION: no extra tag, and no warning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SKEW_VERSION="0.1.200001.1"   # deliberately older than any real VERSION
IMG=forge

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fake podman: an image store that is a file of tag lines ----------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/podman" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
STORE="$FAKE_PODMAN_STORE"
_norm() { echo "${1#localhost/}"; }
case "${1:-}" in
  --version) echo "podman version 0.0.0-fake"; exit 0 ;;
  images)
    while read -r t; do [[ -n "$t" ]] && echo "localhost/$t"; done < "$STORE"
    exit 0 ;;
  image)
    case "${2:-}" in
      exists) grep -qxF "$(_norm "$3")" "$STORE" && exit 0 || exit 1 ;;
      inspect) echo 0; exit 0 ;;
    esac
    exit 0 ;;
  tag)
    grep -qxF "$(_norm "$2")" "$STORE" || { echo "no such image $2" >&2; exit 1; }
    grep -qxF "$(_norm "$3")" "$STORE" || _norm "$3" >> "$STORE"
    exit 0 ;;
  rmi)
    shift
    for a in "$@"; do
      [[ "$a" == -* ]] && continue
      grep -vxF "$(_norm "$a")" "$STORE" > "$STORE.tmp" || true
      mv "$STORE.tmp" "$STORE"
    done
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/podman"

# Run one arm. $1 = arm name, $2 = version the fake installed binary reports,
# $3.. = tags pre-seeded into the store. Prints the resulting store to stdout
# via $ARM_STORE, the build output to $ARM_OUT.
run_arm() {
    local arm="$1" installed_version="$2"; shift 2
    local home="$WORK/$arm"
    ARM_STORE="$home/store"
    ARM_OUT="$home/out"
    mkdir -p "$home/.local/bin" "$home/.cache/tillandsias/build-hashes"

    cat > "$home/.local/bin/tillandsias" <<EOF
#!/usr/bin/env bash
echo "Tillandsias v${installed_version}"
EOF
    chmod +x "$home/.local/bin/tillandsias"

    # Seed the store with the content-hash tag so the "sources unchanged"
    # shortcut applies and no real build runs.
    local hash
    hash="$("$SCRIPT_DIR/hash-image-sources.sh" "$IMG" "$ROOT/images/default" "$ROOT")"
    : > "$ARM_STORE"
    echo "tillandsias-${IMG}:${hash}" >> "$ARM_STORE"
    local t; for t in "$@"; do echo "$t" >> "$ARM_STORE"; done
    echo "$hash" > "$home/.cache/tillandsias/build-hashes/.last-build-${IMG}.sha256"

    env -i \
        HOME="$home" \
        PATH="$WORK/bin:/usr/bin:/bin" \
        FAKE_PODMAN_STORE="$ARM_STORE" \
        TERM=dumb \
        bash "$SCRIPT_DIR/build-image.sh" "$IMG" > "$ARM_OUT" 2>&1 \
        || { cat "$ARM_OUT"; fail "$arm: build-image.sh exited nonzero"; }
}

# --- arm 1: skew, installed tag absent before the rebuild -------------------
run_arm skew "$SKEW_VERSION"
grep -qxF "tillandsias-${IMG}:v${SKEW_VERSION}" "$ARM_STORE" \
    || { cat "$ARM_OUT"; fail "skew: the installed binary's tag v${SKEW_VERSION} is not in the store after the rebuild — the launch path is orphaned"; }
grep -qi "version skew" "$ARM_OUT" \
    || fail "skew: the rebuild aliased the installed tag without saying so"

# --- arm 2: skew, installed tag ALREADY present (the 2026-08-15 failure) ----
run_arm skew-preexisting "$SKEW_VERSION" "tillandsias-${IMG}:v${SKEW_VERSION}"
grep -qxF "tillandsias-${IMG}:v${SKEW_VERSION}" "$ARM_STORE" \
    || { cat "$ARM_OUT"; fail "skew-preexisting: the rebuild REAPED the tag the installed binary launches by"; }

# --- arm 3: negative control — no skew, nothing extra, nothing said ---------
run_arm noskew "$VERSION"
extra="$(grep -v -e ":v${VERSION}\$" -e ":latest\$" -e ":[0-9a-f]\{16,\}\$" "$ARM_STORE" || true)"
[[ -z "$extra" ]] || fail "negative control: rebuild added unexpected tags: $extra"
if grep -qi "version skew" "$ARM_OUT"; then
    fail "negative control: installed binary and VERSION agree, but the rebuild warned about skew"
fi

echo "ok: build-image.sh keeps the installed binary's launch tag resolvable under version skew (747-knbp)"
