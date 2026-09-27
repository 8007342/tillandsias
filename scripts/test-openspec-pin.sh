#!/usr/bin/env bash
# @trace spec:meta-orchestration, openspec/changes/openspec-cli-version-pin (order 1441-myz3)
#
# Fixture for the project's openspec CLI pin: scripts/openspec-pin.sh (the
# coordinator's side) and ensure_openspec_pinned / ensure_forge_harnesses in
# images/default/lib-common.sh (the forge's side). Hermetic: npm and the
# openspec CLI are stubs, so no registry is contacted.
#
# The load-bearing cases are 7 and 8. Case 7 starts from the pre-fix forge
# state (the @latest openspec in the global prefix) and proves a pinned project
# ends up running exactly the pin. Case 8 proves the backgrounded refresher no
# longer moves a pinned openspec back to @latest, which is the collision that
# made every forge launch start dirty.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_SH="$ROOT/scripts/openspec-pin.sh"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-openspec-pin.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip:openspec-pin:no-git"; exit 0; }
[ -x "$PIN_SH" ] || fail "scripts/openspec-pin.sh missing or not executable"

# ── stubs ────────────────────────────────────────────────────────────────────
# The stub openspec, installed by the stub npm as <prefix>/.../openspec with its
# version baked in. `update` rewrites every generated skill it finds to its own
# version, records the config dir it was given, and can be told to leave a
# superseded copy or write outside the generated surface.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat >"$STUBS/openspec.tmpl" <<'STUB'
#!/usr/bin/env bash
V="__VERSION__"
case "${1:-}" in
    --version) echo "$V"; exit 0 ;;
    update)
        printf '%s\n' "${XDG_CONFIG_HOME:-unset}" >>"$STUB_LOG.xdg"
        for f in .claude/skills/openspec-*/SKILL.md .github/skills/openspec-*/SKILL.md; do
            [ -f "$f" ] || continue
            printf -- '---\nname: x\ngeneratedBy: "%s"\n---\n' "$V" >"$f"
        done
        if [ -n "${STUB_ORPHAN:-}" ]; then
            echo "Left 1 files in .codex/ that differ from the copy in .agents/. Nothing was overwritten."
        fi
        [ -n "${STUB_STRAY:-}" ] && echo stray >stray.txt
        exit 0 ;;
esac
exit 0
STUB
cat >"$STUBS/npm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "${1:-}" in
    view)
        [ -n "${STUB_OFFLINE:-}" ] && exit 1
        echo "$STUB_LATEST"; exit 0 ;;
    install)
        shift; prefix=""; global=0; spec=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --prefix) prefix="$2"; shift 2 ;;
                -g) global=1; shift ;;
                --*) shift ;;
                *) spec="$1"; shift ;;
            esac
        done
        v="${spec##*@}"
        [ "$v" = latest ] && v="$STUB_LATEST"
        if [ "$global" = 1 ]; then bin="$NPM_CONFIG_PREFIX/bin"; else bin="$prefix/node_modules/.bin"; fi
        case "$spec" in
            @fission-ai/openspec@*) name=openspec ;;
            *) name="stub-$(printf '%s' "${spec%@*}" | tr -c 'a-z0-9' '-')" ;;
        esac
        mkdir -p "$bin"
        sed "s/__VERSION__/$v/" "$STUB_TEMPLATE" >"$bin/$name"
        chmod +x "$bin/$name"
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUBS/npm"
export STUB_LOG="$WORK/npm.log" STUB_TEMPLATE="$STUBS/openspec.tmpl" STUB_LATEST=2.0.0
export OPENSPEC_PIN_NPM="$STUBS/npm" OPENSPEC_PIN_CACHE="$WORK/pin-cache"
: >"$STUB_LOG"

# A repo whose committed generated skills came from openspec 1.0.0.
make_repo() {
    local d="$1" pin="${2:-}"
    mkdir -p "$d/.claude/skills/openspec-explore" "$d/.github/skills/openspec-explore" "$d/openspec"
    printf -- '---\nname: x\ngeneratedBy: "1.0.0"\n---\n' >"$d/.claude/skills/openspec-explore/SKILL.md"
    printf -- '---\nname: x\ngeneratedBy: "1.0.0"\n---\n' >"$d/.github/skills/openspec-explore/SKILL.md"
    [ -n "$pin" ] && printf '%s\n' "$pin" >"$d/openspec/cli-version"
    git -C "$d" init -q .
    git -C "$d" add -A >/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
}
run() { # run <repo> <args...> → sets OUT and RC
    local d="$1"; shift
    OUT="$(cd "$d" && "$PIN_SH" "$@" 2>"$WORK/stderr")"
    RC=$?
}

# ── case 1: pin ──────────────────────────────────────────────────────────────
R="$WORK/unpinned"; make_repo "$R"
run "$R" pin;   [ "$OUT" = "absent:openspec-pin" ] && [ $RC -eq 4 ] || fail "case1 absent: '$OUT' rc=$RC"
run "$R" drift; [ "$OUT" = "absent:openspec-pin" ] && [ $RC -eq 4 ] || fail "case1 drift-absent: '$OUT' rc=$RC"
R="$WORK/pinned"; make_repo "$R" 1.0.0
run "$R" pin;   [ "$OUT" = "1.0.0" ] && [ $RC -eq 0 ] || fail "case1 pin: '$OUT' rc=$RC"
echo "case 1 ok: pin read, absence named"

# ── case 2: check ────────────────────────────────────────────────────────────
run "$R" check; [ "$OUT" = "due:openspec-bump:1.0.0->2.0.0" ] && [ $RC -eq 5 ] || fail "case2 due: '$OUT' rc=$RC"
STUB_LATEST=1.0.0 run "$R" check
[ "$OUT" = "ok:openspec-pin-current:1.0.0" ] && [ $RC -eq 0 ] || fail "case2 current: '$OUT' rc=$RC"
STUB_LATEST=1.0.0 STUB_OFFLINE=1 run "$R" check
[ "$OUT" = "unknown:openspec-latest:registry-unreachable" ] && [ $RC -eq 2 ] || fail "case2 offline: '$OUT' rc=$RC"
STUB_LATEST=1.10.0 run "$R" check
[ "$OUT" = "due:openspec-bump:1.0.0->1.10.0" ] || fail "case2 numeric compare (1.10.0 > 1.0.0): '$OUT'"
echo "case 2 ok: check says due / current / unknown, comparing numerically"

# ── case 3: drift ────────────────────────────────────────────────────────────
run "$R" drift
[ "$OUT" = "ok:openspec-generated-matches-pin:1.0.0:2" ] && [ $RC -eq 0 ] || fail "case3 ok: '$OUT' rc=$RC"
printf -- '---\ngeneratedBy: "0.9.0"\n---\n' >"$R/.github/skills/openspec-explore/SKILL.md"
git -C "$R" -c user.email=t@t -c user.name=t commit -qam skew
run "$R" drift
[ "$OUT" = "drift:openspec-generated:1.0.0:1" ] && [ $RC -eq 3 ] || fail "case3 drift: '$OUT' rc=$RC"
grep -q '.github/skills/openspec-explore/SKILL.md generatedBy=0.9.0' "$WORK/stderr" || fail "case3: drift did not name the file"
echo "case 3 ok: drift names the skewed file"

# ── case 4: bump regenerates at the new pin with an isolated config ──────────
R="$WORK/bump"; make_repo "$R" 1.0.0
echo dirt >"$R/scratch.txt"
run "$R" bump
[ "$OUT" = "refused:openspec-bump:dirty-tree" ] && [ $RC -eq 1 ] || fail "case4 dirty: '$OUT' rc=$RC"
rm -f "$R/scratch.txt"
: >"$STUB_LOG.xdg"
run "$R" bump
[ "$OUT" = "bumped:openspec:1.0.0->2.0.0:3-paths" ] && [ $RC -eq 0 ] || fail "case4 bump: '$OUT' rc=$RC ($(cat "$WORK/stderr"))"
[ "$(cat "$R/openspec/cli-version")" = "2.0.0" ] || fail "case4: pin not written"
run "$R" drift; [ "$OUT" = "ok:openspec-generated-matches-pin:2.0.0:2" ] || fail "case4: drift after bump: '$OUT'"
xdg="$(cat "$STUB_LOG.xdg")"
case "$xdg" in
    ""|unset|"$HOME"/.config*) fail "case4: update ran with the machine's own openspec config ('$xdg')" ;;
esac
[ -e "$xdg" ] && fail "case4: isolated config dir was not cleaned up"
[ -x "$OPENSPEC_PIN_CACHE/2.0.0/node_modules/.bin/openspec" ] || fail "case4: version-keyed install missing"
echo "case 4 ok: bump regenerates, writes the pin, isolates the config, never commits"

# ── case 5: a superseded copy is reported for review, not committed ─────────
R="$WORK/orphan"; make_repo "$R" 1.0.0
STUB_ORPHAN=1 run "$R" bump
[ "$OUT" = "review:openspec-bump:1.0.0->2.0.0:drift-or-superseded-copies" ] && [ $RC -eq 6 ] || fail "case5: '$OUT' rc=$RC"
grep -q 'superseded copy left by the CLI: .codex (superseded by .agents)' "$WORK/stderr" || fail "case5: orphan not named"
echo "case 5 ok: a copy the CLI left behind stops the bump for review"

# ── case 6: a write outside the generated surface is refused ────────────────
R="$WORK/stray"; make_repo "$R" 1.0.0
STUB_STRAY=1 run "$R" bump
[ "$OUT" = "review:openspec-bump:1.0.0->2.0.0:paths-outside-generated-surface" ] && [ $RC -eq 6 ] || fail "case6: '$OUT' rc=$RC"
grep -q 'stray.txt' "$WORK/stderr" || fail "case6: stray path not named"
echo "case 6 ok: a bump that writes outside the generated surface is stopped"

# ── forge side: load only the functions under test ───────────────────────────
trace_lifecycle() { printf '%s\n' "$*" >>"$WORK/trace.log"; }
harness_record_last_good() { return 0; }
harness_last_good_file() { printf '%s\n' "$WORK/last-good-$1"; }
harness_probe() { return 0; }
for fn in openspec_pin_marker ensure_openspec_pinned ensure_forge_harnesses; do
    eval "$(sed -n "/^$fn()/,/^}/p" "$LIB")"
    declare -F "$fn" >/dev/null || fail "could not load $fn from lib-common.sh"
done
export HOME="$WORK/home" NPM_CONFIG_PREFIX="$WORK/home/.cache/tillandsias-project/npm/global"
export TILLANDSIAS_HARNESS_FALLBACK_DIR="$WORK/no-fallback"
mkdir -p "$HOME/.cache/tillandsias-project"
PATH="$STUBS:$PATH"

# ── case 7: a pinned project runs exactly the pin, not the @latest global ────
"$STUBS/npm" install -g --no-audit @fission-ai/openspec@latest   # pre-fix state: 2.0.0
OS_BIN="$NPM_CONFIG_PREFIX/bin/openspec"
[ "$("$OS_BIN" --version)" = "2.0.0" ] || fail "case7 setup"
R="$WORK/forge-pinned"; make_repo "$R" 1.0.0
ensure_openspec_pinned "$R"
[ "$("$OS_BIN" --version)" = "1.0.0" ] || fail "case7: forge openspec is $("$OS_BIN" --version), want the pin 1.0.0"
[ "$(cat "$(openspec_pin_marker)")" = "1.0.0" ] || fail "case7: pin marker not written"
[ -d "$HOME/.cache/tillandsias-project/npm-update.lock" ] && fail "case7: npm-update lock leaked"
: >"$STUB_LOG"
ensure_openspec_pinned "$R"
grep -q install "$STUB_LOG" && fail "case7: an already-pinned openspec was reinstalled"
echo "case 7 ok: pinned project gets exactly its pin; a warm launch installs nothing"

# ── case 8: the background refresher leaves a pinned openspec alone ─────────
: >"$STUB_LOG"
( ensure_forge_harnesses ) >/dev/null 2>&1
grep -q '@fission-ai/openspec@latest' "$STUB_LOG" && fail "case8: refresher moved the pinned openspec to @latest"
grep -q '@openai/codex@latest' "$STUB_LOG" || fail "case8: refresher stopped refreshing the other harnesses"
[ "$("$OS_BIN" --version)" = "1.0.0" ] || fail "case8: pinned openspec changed"
rm -f "$(openspec_pin_marker)"
: >"$STUB_LOG"
( ensure_forge_harnesses ) >/dev/null 2>&1
grep -q '@fission-ai/openspec@latest' "$STUB_LOG" || fail "case8: an unpinned project lost its @latest refresh"
echo "case 8 ok: pinned openspec is never refreshed to @latest; unpinned projects still are"

# ── case 9: unpinned and malformed pins leave the forge as it was ───────────
"$STUBS/npm" install -g @fission-ai/openspec@latest >/dev/null
: >"$STUB_LOG"
R="$WORK/forge-unpinned"; make_repo "$R"
ensure_openspec_pinned "$R"
[ -s "$STUB_LOG" ] && fail "case9: an unpinned project triggered an install"
[ -e "$(openspec_pin_marker)" ] && fail "case9: an unpinned project wrote a pin marker"
R="$WORK/forge-bad"; make_repo "$R" "latest"
ensure_openspec_pinned "$R" 2>/dev/null
[ -s "$STUB_LOG" ] && fail "case9: a malformed pin triggered an install"
echo "case 9 ok: unpinned or malformed pins change nothing"

# ── case 10: every forge entrypoint installs the pin before init ────────────
for ep in entrypoint-forge-claude.sh entrypoint-forge-opencode.sh \
          entrypoint-forge-opencode-web.sh entrypoint-terminal.sh; do
    f="$ROOT/images/default/$ep"
    pin_line="$(grep -n 'ensure_openspec_pinned "$PROJECT_DIR"' "$f" | head -n 1 | cut -d: -f1)"
    init_line="$(grep -n 'openspec_init_if_absent "$PROJECT_DIR"' "$f" | head -n 1 | cut -d: -f1)"
    [ -n "$pin_line" ] || fail "case10: $ep never calls ensure_openspec_pinned"
    [ -n "$init_line" ] && [ "$pin_line" -lt "$init_line" ] || fail "case10: $ep inits before pinning"
done
echo "case 10 ok: every entrypoint pins before it inits"

echo "ok:openspec-pin"
