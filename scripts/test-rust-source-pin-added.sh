#!/usr/bin/env bash
# @trace order:1473-scdq, spec:ci-release
#
# Fixture for scripts/check-rust-source-pin-added.sh (1473-scdq), over scratch
# repos whose origin/linux-next is the base. Each arm adds one Rust test:
#
#   1. `let src = include_str!("lib.rs"); assert!(src.contains("…"))` is REFUSED,
#      naming file:line;
#   2. a pin on a WINDOW cut from that source (`let w = src.split(…)`) is refused
#      too — the vz.rs fetch-unit shape that kept 1472-3d29 green;
#   3. an ABSENCE assertion (`!src.contains(…)`) is admitted;
#   4. a test naming a NEGATIVE CONTROL is admitted;
#   5. `// source-pin-ok: <reason>` admits it, and an EMPTY marker does not;
#   6. `.contains` on a BUILT value (not source text) is not a pin;
#   7. NEGATIVE CONTROL: a pin already in the base is not re-litigated.
#
# PRE-FIX RESULT: FAILS — no guard covered Rust include_str! pins (827-d3dc:
# 92 of them, four of the ten costliest).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-rust-source-pin-added.sh"
pass=0; total=7
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

[ -f "$GUARD" ] || { echo "fail:rust-source-pin-added-fixture:0/$total (guard missing)"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip:rust-source-pin-added-fixture:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/rust-source-pin.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
GC=(-c user.email=f@x -c user.name=f)

# repo <name> [base test body]: crates/c/src/lib.rs with a tests module
repo() {
    local r="$W/$1"
    mkdir -p "$r/scripts" "$r/crates/c/src"
    cp "$GUARD" "$r/scripts/"
    printf 'pub fn f() -> u8 { 1 }\n#[cfg(test)]\nmod tests {\n%s}\n' "${2:-}" > "$r/crates/c/src/lib.rs"
    git -C "$r" init -q && git -C "$r" "${GC[@]}" add -A && git -C "$r" "${GC[@]}" commit -qm base
    git -C "$r" update-ref refs/remotes/origin/linux-next HEAD
    echo "$r"
}
put() { printf 'pub fn f() -> u8 { 1 }\n#[cfg(test)]\nmod tests {\n%s}\n' "$2" > "$1/crates/c/src/lib.rs"; }
run() { OUT="$(cd "$1" && bash scripts/check-rust-source-pin-added.sh 2>&1)"; RC=$?; }

# 1 — a direct include_str! pin.
R="$(repo one)"
put "$R" '    #[test]
    fn pins_source() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
    }
'
run "$R"
[ "$RC" -eq 1 ] && grep -q '^violation:rust-source-pin-added:1$' <<<"$OUT" && grep -q 'crates/c/src/lib.rs:7' <<<"$OUT" \
    && ok "arm 1: a direct include_str! pin is refused, naming crates/c/src/lib.rs:7" \
    || bad "arm 1: rc=$RC [$OUT]"

# 2 — a pin on a window cut from the source.
R="$(repo two)"
put "$R" '    #[test]
    fn pins_a_window() {
        let source = include_str!("lib.rs");
        let unit = source.split("mod tests").next().expect("window");
        assert!(unit.contains("-> u8"));
    }
'
run "$R"
[ "$RC" -eq 1 ] && grep -q '^violation:rust-source-pin-added:1$' <<<"$OUT" \
    && ok "arm 2: a pin on a window cut from include_str! source is refused" \
    || bad "arm 2: rc=$RC [$OUT]"

# 3 — absence is admitted.
R="$(repo three)"
put "$R" '    #[test]
    fn bans_a_pattern() {
        let src = include_str!("lib.rs");
        assert!(!src.contains("std::thread::sleep"));
    }
'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 3: an absence assertion (!src.contains) is admitted" || bad "arm 3: rc=$RC [$OUT]"

# 4 — a negative control in the test admits it.
R="$(repo four)"
put "$R" '    /// NEGATIVE CONTROL: the mutated text below must FAIL this check.
    #[test]
    fn pins_with_control() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
        assert!(!"pub fn g()".contains("pub fn f() -> u8"));
    }
'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 4: a pin in a test that names a negative control is admitted" || bad "arm 4: rc=$RC [$OUT]"

# 5 — a reasoned marker admits; an empty one does not.
R="$(repo five)"
put "$R" '    #[test]
    fn pins_a_contract() {
        let src = include_str!("lib.rs");
        // source-pin-ok: the public signature text IS the documented contract
        assert!(src.contains("pub fn f() -> u8"));
    }
'
run "$R"; rc_reason=$RC
put "$R" '    #[test]
    fn pins_a_contract() {
        let src = include_str!("lib.rs");
        // source-pin-ok:
        assert!(src.contains("pub fn f() -> u8"));
    }
'
run "$R"; rc_empty=$RC
[ "$rc_reason" -eq 0 ] && [ "$rc_empty" -eq 1 ] \
    && ok "arm 5: source-pin-ok with a reason admits; an empty marker does not" \
    || bad "arm 5: reason rc=$rc_reason, empty rc=$rc_empty"

# 6 — .contains on a built value is not a pin.
R="$(repo six)"
put "$R" '    #[test]
    fn checks_a_built_value() {
        let rendered = format!("{} units", super::f());
        assert!(rendered.contains("1 units"));
    }
'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 6: .contains on a BUILT value is not a source pin" || bad "arm 6: rc=$RC [$OUT]"

# 7 — NEGATIVE CONTROL: a pin already in the base is not re-litigated.
R="$(repo seven '    #[test]
    fn old_pin() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
    }
')"
put "$R" '    #[test]
    fn old_pin() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
    }
    #[test]
    fn unrelated() { assert_eq!(super::f(), 1); }
'
run "$R"
[ "$RC" -eq 0 ] && ok "arm 7: a pin already in the base is not re-litigated (diff-scoped)" \
    || bad "arm 7: rc=$RC [$OUT]"

if [ "$pass" -eq "$total" ]; then
    echo "ok:rust-source-pin-added-fixture:$pass/$total"
    exit 0
fi
echo "fail:rust-source-pin-added-fixture:$pass/$total"
exit 1
