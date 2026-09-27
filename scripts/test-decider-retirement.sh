#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1443-xkwb
#
# test-decider-retirement.sh — the four arms of 1443-xkwb.
#
#   1  each bash decider prints `population=<n> bootstrap=<b>` on STDERR while
#      its stdout stays exactly one verdict line (the interface is unchanged)
#   2  scripts/check-decider-retirement.sh says retire:<decider> for all three
#      over a tree whose shell is only bootstrap shell, live for a tree with
#      one migratable script, and ok:decider-retirement:3 live over this tree
#   3  NEGATIVE CONTROL: an empty scripts/ makes every decider REFUSE, and the
#      retirement check says blocked, never retire
#   4  the allowlist is the design §6.5 table resolved to disk, and a dangling
#      entry is refused
#
# Pre-fix: FAILS at arm 1 (no decider prints a population line).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETIRE="$ROOT/scripts/check-decider-retirement.sh"
ALLOW="$ROOT/scripts/portability/bootstrap-shell-allowlist.txt"
W="$(mktemp -d "${TMPDIR:-/tmp}/test-decider-retirement.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# A git tree whose shell files are exactly the given paths, each setting
# pipefail so all three deciders count it.
make_tree() {
    local d="$1" f
    shift
    mkdir -p "$d/scripts"
    git -C "$d" init -q .
    for f in "$@"; do
        mkdir -p "$d/$(dirname "$f")"
        printf '#!/usr/bin/env bash\nset -euo pipefail\necho hi\n' > "$d/$f"
    done
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm fixture --allow-empty
}

# run_decider <name> <tree> → $W/<name>.out / .err
run_decider() {
    local s="$ROOT/scripts/$1.sh"
    case "$1" in
        check-bash-dialect) ( cd "$2" && bash "$s" ) ;;
        check-jq-callsite-ratchet) bash "$s" --root "$2" ;;
        check-sigpipe-verdict-pipelines-added) TILLANDSIAS_SIGPIPE_ROOT="$2" bash "$s" ;;
    esac > "$W/$1.out" 2> "$W/$1.err"
}

BOOT="$W/boot"
make_tree "$BOOT" scripts/install.sh scripts/ensure_toolbox.sh \
    scripts/hooks/pre-commit-openspec.sh build.sh launch.sh

# ── arm 1 ────────────────────────────────────────────────────────────────────
for pair in "check-bash-dialect:ok:bash-dialect-clean" \
            "check-sigpipe-verdict-pipelines-added:ok:sigpipe-verdict-added:base-unavailable" \
            "check-jq-callsite-ratchet:ok:jq-callsites:0:floor:0"; do
    d="${pair%%:*}"
    want="${pair#*:}"
    run_decider "$d" "$BOOT"
    if [ "$(cat "$W/$d.out")" = "$want" ] && grep -qx 'population=[0-9]* bootstrap=[0-9]*' "$W/$d.err"; then
        ok "arm 1: $d stdout is exactly '$want'; stderr carries $(grep -x 'population=[0-9]* bootstrap=[0-9]*' "$W/$d.err")"
    else
        bad "arm 1: $d stdout=[$(cat "$W/$d.out")] want [$want]; stderr population line: [$(grep '^population=' "$W/$d.err")]"
    fi
done

# ── arm 2 ────────────────────────────────────────────────────────────────────
out="$(bash "$RETIRE" --root "$BOOT")"; rc=$?
if [ "$rc" -eq 0 ] &&
    grep -q '^retire:check-bash-dialect ' <<<"$out" &&
    grep -q '^retire:check-sigpipe-verdict-pipelines-added ' <<<"$out" &&
    grep -q '^retire:check-jq-callsite-ratchet ' <<<"$out" &&
    [ "$(tail -n 1 <<<"$out")" = "ok:decider-retirement:0 live" ]; then
    ok "arm 2: a bootstrap-only tree retires all three deciders, rc 0"
else
    bad "arm 2 (bootstrap-only): rc=$rc [$out]"
fi
MIXED="$W/mixed"
make_tree "$MIXED" scripts/install.sh build.sh launch.sh scripts/migratable.sh
out="$(bash "$RETIRE" --root "$MIXED")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(tail -n 1 <<<"$out")" = "ok:decider-retirement:3 live" ] &&
    ! grep -q '^retire:' <<<"$out"; then
    ok "arm 2: one migratable script keeps all three live"
else
    bad "arm 2 (mixed): rc=$rc [$out]"
fi
out="$(bash "$RETIRE")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(tail -n 1 <<<"$out")" = "ok:decider-retirement:3 live" ]; then
    ok "arm 2: this tree: ok:decider-retirement:3 live"
else
    bad "arm 2 (real tree): rc=$rc [$out]"
fi

# ── arm 3: NEGATIVE CONTROL ─────────────────────────────────────────────────
EMPTY="$W/empty"
make_tree "$EMPTY"
for pair in "check-bash-dialect:blocked:bash-dialect:scan-empty" \
            "check-sigpipe-verdict-pipelines-added:blocked:sigpipe-verdict-added:scan-empty" \
            "check-jq-callsite-ratchet:blocked:jq-ratchet-empty-population"; do
    d="${pair%%:*}"
    want="${pair#*:}"
    run_decider "$d" "$EMPTY"; rc=$?
    if [ "$(cat "$W/$d.out")" = "$want" ]; then
        ok "arm 3: $d refuses an empty scripts/: $want"
    else
        bad "arm 3: $d on an empty scripts/ said [$(cat "$W/$d.out")], want [$want]"
    fi
done
out="$(bash "$RETIRE" --root "$EMPTY")"; rc=$?
if [ "$rc" -eq 1 ] && ! grep -q '^retire:' <<<"$out" &&
    [ "$(grep -c '^blocked:decider-retirement:check-' <<<"$out")" = 3 ]; then
    ok "arm 3: an empty tree is blocked for all three, never retire, rc 1"
else
    bad "arm 3 (retirement over empty): rc=$rc [$out]"
fi

# ── arm 4 ────────────────────────────────────────────────────────────────────
entries="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" | awk '{print $1}' | LC_ALL=C sort)"
table="$(cd "$ROOT" && {
    printf '%s\n' build.sh launch.sh scripts/install.sh scripts/install-macos.sh scripts/ensure_toolbox.sh
    git ls-files -- 'scripts/*.ps1' 'scripts/hooks/*.sh' 'images/*/entrypoint*.sh'
} | LC_ALL=C sort -u)"
if [ "$entries" = "$table" ]; then
    ok "arm 4: the allowlist is the §6.5 table resolved to disk ($(printf '%s\n' "$entries" | grep -c .) entries)"
else
    bad "arm 4: allowlist differs from the §6.5 table: $(diff <(printf '%s\n' "$entries") <(printf '%s\n' "$table") | tr '\n' ' ')"
fi
missing=""
while read -r p; do [ -e "$ROOT/$p" ] || missing="$missing $p"; done <<EOF
$entries
EOF
[ -z "$missing" ] && ok "arm 4: every allowlist entry exists on disk" || bad "arm 4: dangling:$missing"
cp "$ALLOW" "$W/dangling.txt"
echo "scripts/no-such-bootstrap.sh" >> "$W/dangling.txt"
out="$(TILLANDSIAS_BOOTSTRAP_ALLOWLIST="$W/dangling.txt" bash "$RETIRE" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "blocked:decider-retirement:dangling-allowlist-entry:scripts/no-such-bootstrap.sh" ]; then
    ok "arm 4: a dangling entry is refused before anything runs"
else
    bad "arm 4 (dangling): rc=$rc [$out]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: decider-retirement $pass/$total (1443-xkwb)"
    exit 0
fi
echo "FAIL: decider-retirement $pass/$total (1443-xkwb)"
exit 1
