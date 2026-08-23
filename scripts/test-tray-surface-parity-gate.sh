#!/usr/bin/env bash
# Fixture for order 628-r2vk: the NEW-surface parity railguard.
#
# Pins `tillandsias-policy parity-surfaces` in both directions, hermetically:
# a fake repo-root under mktemp carries the three pinned source files and a
# tiny matrix, so the fixture never reads the real tree and cannot go red on
# real-tree drift (the real tree is the LIVE gate's job, litmus step 1).
#
# Cases:
#   A  clean fixture (all ids claimed)                          → PASS line
#   B  NEW menu id, no claiming row                             → MISSING ROW names it + the columns
#   C  pattern hit with no parity-surface annotation            → UNANNOTATED SURFACE names file:line
#   D  baseline entry whose surface no longer exists            → STALE BASELINE names it
#   E  B's id claimed by a row (the fix the message prescribes) → PASS again
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

. "$ROOT/scripts/plan-binary-probe.sh"
# BUILD IN THE EXECUTING LOCUS FIRST, then resolve — the 851-cduu rule, and
# this fixture found the cross-locus variant on its first gate run: inside
# the WSL gate lane, resolve-first found the checkout's Windows .exe (binfmt
# interop makes `--help` succeed) and handed it a WSL-internal mktemp path
# the Windows process cannot see — every case answered rc=2. A locus-native
# build (incremental no-op when warm; honours CARGO_TARGET_DIR) guarantees
# the probed binary and the fixture's paths live in the same world.
if command -v cargo >/dev/null 2>&1; then
    cargo build -q --release -p tillandsias-policy || exit 2
fi
POLICY="$(resolve_target_binary tillandsias-policy release "$ROOT")" || exit 2

pass=0; fail=0
ck() { # ck <description> <expected-substring-or-empty> <haystack> <want-rc> <got-rc>
    local desc="$1" want="$2" hay="$3" wrc="$4" grc="$5"
    if [ "$wrc" != "$grc" ]; then
        printf '  FAIL %s (expected rc=%s, got rc=%s)\n' "$desc" "$wrc" "$grc"; fail=$((fail+1)); return
    fi
    if [ -n "$want" ] && ! printf '%s' "$hay" | grep -qF "$want"; then
        printf '  FAIL %s (output lacks: %s)\n' "$desc" "$want"; fail=$((fail+1)); return
    fi
    printf '  ok   %s\n' "$desc"; pass=$((pass+1))
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tray-surface-parity.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

mkdir -p "$TMPD/crates/tillandsias-host-shell/src" \
         "$TMPD/crates/tillandsias-windows-tray/src" \
         "$TMPD/crates/tillandsias-macos-tray/src"

write_menu_source() { # $1 = extra const line (may be empty)
    {
        echo 'pub mod ids {'
        echo '    pub const STATUS: &str = "status";'
        echo '    pub const SEPARATOR: &str = "---";'
        echo '    pub const LABEL_COPY: &str = "Not An Id — UI copy";'
        [ -n "$1" ] && echo "$1"
        echo '}'
    } > "$TMPD/crates/tillandsias-host-shell/src/menu_state.rs"
}

write_windows_source() { # $1 = "annotated" | "unannotated"
    {
        if [ "$1" = "annotated" ]; then
            echo '    // parity-surface: notification.fixture-toast'
        fi
        echo '    hwnd.balloon('
        echo '    // parity-surface: tooltip.fixture-tooltip'
        echo 'fn compose_tooltip(version: &str) -> String {'
    } > "$TMPD/crates/tillandsias-windows-tray/src/notify_icon.rs"
}

write_macos_source() {
    {
        echo '// parity-surface: notification.fixture-crash'
        echo 'fn notify_crash_loop(reason: &str) {'
    } > "$TMPD/crates/tillandsias-macos-tray/src/action_host.rs"
}

write_matrix() { # $1 = extra row block (may be empty), $2 = extra baseline entry (may be empty)
    {
        echo 'features:'
        echo '  - capability: "Fixture toast"'
        echo '    class: "notification"'
        echo '    surfaces: ["notification.fixture-toast", "notification.fixture-crash", "tooltip.fixture-tooltip"]'
        echo '    linux: "n/a"'
        echo '    macos: "unknown"'
        echo '    windows: "done"'
        echo '    parity: "platform-specific"'
        [ -n "$1" ] && printf '%s\n' "$1"
        echo 'surface_baseline:'
        echo '  - "menu.status"'
        [ -n "$2" ] && echo "  - \"$2\""
    } > "$TMPD/matrix.yaml"
}

run_gate() {
    "$POLICY" parity-surfaces --matrix "$TMPD/matrix.yaml" --repo-root "$TMPD" 2>&1
}

# ── case A: clean fixture passes; the label copy constant is NOT a surface ───
write_menu_source ""
write_windows_source annotated
write_macos_source
write_matrix "" ""
out="$(run_gate)"; rc=$?
ck "clean fixture passes" "Tray surfaces:" "$out" 0 "$rc"
ck "label-copy constant is not extracted as a surface" "" "$out" 0 "$rc"

# ── case B: a NEW menu id with no claiming row fails, naming id + columns ────
write_menu_source '    pub const NEW_THING: &str = "new-thing";'
out="$(run_gate)"; rc=$?
ck "new unclaimed menu id fails" "MISSING ROW: surface 'menu.new-thing'" "$out" 1 "$rc"
ck "failure names the columns to fill" "linux/macos/windows columns" "$out" 1 "$rc"

# ── case C: an unannotated declaration site fails, naming file:line ──────────
write_menu_source ""
write_windows_source unannotated
out="$(run_gate)"; rc=$?
ck "unannotated declaration site fails" "UNANNOTATED SURFACE: crates/tillandsias-windows-tray/src/notify_icon.rs:1" "$out" 1 "$rc"
write_windows_source annotated

# ── case D: a baseline entry whose surface is gone fails as stale ────────────
write_matrix "" "menu.retired-thing"
out="$(run_gate)"; rc=$?
ck "stale baseline entry fails" "STALE BASELINE: 'menu.retired-thing'" "$out" 1 "$rc"

# ── case E: claiming B's id by a row (the prescribed fix) passes again ───────
write_menu_source '    pub const NEW_THING: &str = "new-thing";'
write_matrix '  - capability: "Fixture new thing"
    class: "menu"
    surfaces: ["menu.new-thing"]
    linux: "todo"
    macos: "todo"
    windows: "done"
    parity: "platform-specific"' ""
out="$(run_gate)"; rc=$?
ck "claiming row makes the same surface pass" "Tray surfaces:" "$out" 0 "$rc"

printf 'tray-surface-parity-gate: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "ok:tray-surface-parity-gate:$pass"
    exit 0
fi
exit 1
