#!/usr/bin/env bash
# @trace order:1181-bkem, spec:app-lifecycle
set -uo pipefail

# Fixture for scripts/uninstall.sh's TILLANDSIAS_RESET_KEEP_MODELS support
# (1181-bkem). The operator's word ("let's add the keep models flag to our
# resets") makes --wipe spare $CACHE_DIR/models when the flag is set, and
# leaves --wipe byte-for-byte unchanged when it is not.
#
# Hermetic: a scratch $HOME under mktemp, seeded cache contents, and a
# PATH-prefixed stub dir shadowing every external command uninstall.sh calls
# outside its root-only branches (podman, pgrep, pkill,
# update-desktop-database) plus the root-only ones (userdel, groupdel,
# runuser, loginctl, systemctl) for defense in depth even though this fixture
# never runs as root. Nothing touches a real cache, a real podman store, or a
# real HOME.
#
# Four arms:
#   1. flag set + --wipe    -> models/ survives byte-identical, everything
#                              else under the cache dir is gone, stdout names
#                              the spared path.
#   2. flag unset + --wipe  -> the cache dir is gone entirely (today's
#                              behaviour, unchanged).
#   3. MUTATION CONTROL     -> a copy of uninstall.sh with the sparing
#                              construct stripped back to the plain
#                              `rm -rf "$CACHE_DIR"` it replaced (built by
#                              editing content, not by git provenance; cmp
#                              proves the strip actually applied). Arm 1's
#                              positive assertion must red against it.
#   4. NEGATIVE             -> flag set, NO --wipe: the cache dir is
#                              untouched. The flag never widens what gets
#                              deleted.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="$ROOT/scripts/uninstall.sh"
NAME="uninstall-keeps-models"
total=0
fail=0

[ -f "$UNINSTALL" ] || { echo "FAIL: no uninstall.sh at $UNINSTALL"; exit 1; }

check() {
    _name="$1"; _cond="$2"
    total=$((total + 1))
    if [ "$_cond" = "0" ]; then
        echo "ok: $_name"
    else
        echo "FAIL: $_name"
        fail=$((fail + 1))
    fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-keeps-models-fixture.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── The stub PATH dir: shadow every external command uninstall.sh invokes ────
# outside plain coreutils (awk, chmod, du, grep, id, mv, uname, xargs), which
# stay real because they only ever touch the sandbox and are needed for the
# script's own dotfile-editing and sizing logic to behave correctly.
STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
CALLS_LOG="$WORK/calls.log"
: > "$CALLS_LOG"

make_stub() {
    _cmd="$1"; _body="$2"
    cat > "$STUBBIN/$_cmd" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$_cmd" "\$*" >> "$CALLS_LOG"
$_body
STUB
    chmod +x "$STUBBIN/$_cmd"
}

# podman: "images" must print nothing (no matching images -> the script's
# grep finds nothing and its guarded xargs never runs); "rmi" is a no-op.
make_stub podman 'exit 0'
# pgrep: report no matching process, so the pkill branch is never entered.
make_stub pgrep 'exit 1'
make_stub pkill 'exit 0'
make_stub update-desktop-database 'exit 0'
# Root-only branches this fixture never reaches (EUID stays non-zero), stubbed
# anyway so a wrong assumption about IS_ROOT can never touch a real account.
make_stub userdel 'exit 0'
make_stub groupdel 'exit 0'
make_stub runuser 'exit 0'
make_stub loginctl 'exit 0'
make_stub systemctl 'exit 0'
make_stub launchctl 'exit 0'
make_stub sudo 'exit 1'

# ── Seed a scratch HOME with a Linux-layout cache dir ─────────────────────────
seed_home() {
    _home="$1"
    mkdir -p "$_home/.cache/tillandsias/models"
    mkdir -p "$_home/.cache/tillandsias/vault-data"
    mkdir -p "$_home/.cache/tillandsias/build-output"
    head -c 2048 /dev/urandom > "$_home/.cache/tillandsias/models/weights.bin"
    echo "fallback" > "$_home/.cache/tillandsias/fallback_x"
    echo "y" > "$_home/.cache/tillandsias/vault-data/y"
    echo "other" > "$_home/.cache/tillandsias/other.txt"
    echo "nix-output" > "$_home/.cache/tillandsias/build-output/artifact"
}

run_uninstall() {
    _uninstall="$1"; _home="$2"; shift 2
    mkdir -p "$_home/fixture-bin"
    HOME="$_home" \
    PATH="$STUBBIN:$PATH" \
    TILLANDSIAS_UNINSTALL_FAKE_UNAME="Linux" \
    TILLANDSIAS_UNINSTALL_INSTALL_DIR="$_home/fixture-bin" \
        bash "$_uninstall" "$@" 2>&1
}

# ── Arm 1: flag set + --wipe -> models spared, everything else gone ──────────
h1="$WORK/home1"
mkdir -p "$h1"
seed_home "$h1"
CACHE1="$h1/.cache/tillandsias"
before_sha="$(sha256sum "$CACHE1/models/weights.bin" | awk '{print $1}')"

out1="$(TILLANDSIAS_RESET_KEEP_MODELS=1 run_uninstall "$UNINSTALL" "$h1" --wipe)"

if [ -f "$CACHE1/models/weights.bin" ]; then
    after_sha="$(sha256sum "$CACHE1/models/weights.bin" | awk '{print $1}')"
    [ "$before_sha" = "$after_sha" ]; check "arm1-models-weights-byte-identical" "$?"
else
    check "arm1-models-weights-byte-identical" 1
fi
[ ! -e "$CACHE1/fallback_x" ]; check "arm1-fallback-x-removed" "$?"
[ ! -e "$CACHE1/vault-data" ]; check "arm1-vault-data-removed" "$?"
[ ! -e "$CACHE1/other.txt" ]; check "arm1-other-txt-removed" "$?"
[ ! -e "$CACHE1/build-output" ]; check "arm1-build-output-removed" "$?"
case "$out1" in
    *"keep-models: spared $CACHE1/models ("*) check "arm1-stdout-names-spared-path" 0 ;;
    *) echo "FAIL: arm1-stdout-names-spared-path — got: $(printf '%s' "$out1" | grep -i keep-models || echo '<nothing>')"
       total=$((total + 1)); fail=$((fail + 1)) ;;
esac

# ── Arm 2: flag unset + --wipe -> the cache dir is gone entirely ─────────────
h2="$WORK/home2"
mkdir -p "$h2"
seed_home "$h2"
CACHE2="$h2/.cache/tillandsias"
run_uninstall "$UNINSTALL" "$h2" --wipe >/dev/null
[ ! -e "$CACHE2" ]; check "arm2-flag-unset-cache-dir-entirely-gone" "$?"

# ── Arm 3: MUTATION CONTROL — strip the sparing construct FROM CONTENT ───────
# uninstall.sh's --wipe cache-removal reads, verbatim, as an if/else on
# KEEP_MODELS whose "else" branch is the original one-liner. The mutant
# replaces the whole if/else/fi with that original one-liner, i.e. it
# reproduces pre-1181-bkem behaviour by editing the CONTENT of a copy, never
# by reading git history.
MUTANT="$WORK/uninstall.mutant.sh"
START_LINE="$(grep -nF 'if [[ "$KEEP_MODELS" == true && -d "$CACHE_DIR/models" ]]; then' "$UNINSTALL" | head -1 | cut -d: -f1)"
[ -n "$START_LINE" ] || { echo "FAIL: could not locate the sparing construct to strip"; exit 1; }
END_LINE=$((START_LINE + 6))
FI_LINE="$(sed -n "${END_LINE}p" "$UNINSTALL")"
case "$FI_LINE" in
    *fi*) : ;;
    *) echo "FAIL: sparing-construct block shape drifted (line $END_LINE is not its closing fi): $FI_LINE"; exit 1 ;;
esac
{
    sed -n "1,$((START_LINE - 1))p" "$UNINSTALL"
    echo '    rm -rf "$CACHE_DIR"'
    sed -n "$((END_LINE + 1)),\$p" "$UNINSTALL"
} > "$MUTANT"
chmod +x "$MUTANT"

# Prove the strip actually applied: the mutant must differ from the original.
# (A no-op strip — e.g. a marker string that no longer matches anything —
# would leave the copy byte-identical to the original and this would fail.)
if cmp -s "$MUTANT" "$UNINSTALL"; then
    check "arm3-mutant-differs-from-original-cmp" 1
else
    check "arm3-mutant-differs-from-original-cmp" 0
fi
bash -n "$MUTANT" 2>/dev/null; check "arm3-mutant-is-valid-bash" "$?"

h3="$WORK/home3"
mkdir -p "$h3"
seed_home "$h3"
CACHE3="$h3/.cache/tillandsias"
run_uninstall "$MUTANT" "$h3" --wipe >/dev/null
# Arm 1's positive assertion must RED here: under the mutant, the flag is
# ignored and models/ is gone along with everything else.
[ ! -e "$CACHE3/models/weights.bin" ]; check "arm3-mutant-reds-model-preservation" "$?"

# ── Arm 4: NEGATIVE — flag set, no --wipe: the flag never widens deletion ────
h4="$WORK/home4"
mkdir -p "$h4"
seed_home "$h4"
CACHE4="$h4/.cache/tillandsias"
before4_sha="$(sha256sum "$CACHE4/models/weights.bin" | awk '{print $1}')"
TILLANDSIAS_RESET_KEEP_MODELS=1 run_uninstall "$UNINSTALL" "$h4" >/dev/null
[ -d "$CACHE4" ]; check "arm4-flag-without-wipe-cache-dir-survives" "$?"
[ -f "$CACHE4/models/weights.bin" ]; check "arm4-flag-without-wipe-models-survives" "$?"
if [ -f "$CACHE4/models/weights.bin" ]; then
    after4_sha="$(sha256sum "$CACHE4/models/weights.bin" | awk '{print $1}')"
    [ "$before4_sha" = "$after4_sha" ]; check "arm4-flag-without-wipe-models-byte-identical" "$?"
else
    check "arm4-flag-without-wipe-models-byte-identical" 1
fi
[ -f "$CACHE4/fallback_x" ]; check "arm4-flag-without-wipe-fallback-x-survives" "$?"
[ -d "$CACHE4/vault-data" ]; check "arm4-flag-without-wipe-vault-data-survives" "$?"
[ -f "$CACHE4/other.txt" ]; check "arm4-flag-without-wipe-other-txt-survives" "$?"

if [ "$fail" -eq 0 ]; then
    echo "PASS: $NAME $total/$total (1181-bkem)"
    exit 0
fi
echo "FAIL: $NAME $((total - fail))/$total (1181-bkem)"
exit 1
