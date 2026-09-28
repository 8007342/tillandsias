#!/usr/bin/env bash
# @trace order:1235-rfub, spec:ci-release
#
# Fixture for scripts/check-native-lint-attested.sh and scripts/attest-native-lint.sh
# (order 1235-rfub), over scratch repos whose origin/linux-next is the base.
# The change under test is the incident's own: a `format!("{e}")` (clippy
# useless_format) added to a macOS-tray source.
#
#   1. the change with NO attestation is REFUSED, naming the accountable host;
#   2. attest with a clippy that FAILS: no commit is written, still refused;
#   3. attest with a clippy that PASSES: it ran `clippy -p <pkg> --all-targets
#      -- -D warnings` (criterion 2), and the relay check admits it while saying
#      it was attested, NOT re-run here;
#   4. edit the crate AFTER attesting: REFUSED as stale (bound to content);
#   5. a hand-written trailer for the wrong platform does not count;
#   6. NEGATIVE CONTROL: a change outside the gated crates is not in scope;
#   7. land-on-platform-branch.sh runs the check after its integrate (wired);
#   8. NO HOST AVAILABLE: a named TILLANDSIAS_NATIVE_LINT_UNATTESTED reason
#      admits as override:… carrying the reason; an EMPTY one does not.
#
# PRE-FIX RESULT: FAILS — neither script existed, and the relay landed
# d44909353 with the clippy error (trunk red for macOS for hours).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=8
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

for s in check-native-lint-attested.sh attest-native-lint.sh; do
    [ -f "$ROOT/scripts/$s" ] || { echo "fail:native-lint-attested-fixture:0/$total ($s missing)"; exit 1; }
done
command -v git >/dev/null 2>&1 || { echo "skip:native-lint-attested-fixture:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/native-lint.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export TILLANDSIAS_NATIVE_LINT_PLATFORM=darwin   # the fixture runs on every gate host
GC=(-c user.email=f@x -c user.name=f)

# A stub cargo: records its argv, exits $STUB_RC.
mkdir -p "$W/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/cargo.argv"\nexit "${STUB_RC:-0}"\n' "$W" > "$W/bin/cargo"
chmod +x "$W/bin/cargo"

repo() { # repo <name> -> a scratch repo with a tray crate and a linux crate at base
    local r="$W/$1"
    mkdir -p "$r/scripts" "$r/crates/tillandsias-macos-tray/src" "$r/crates/linux-only/src"
    cp "$ROOT/scripts/check-native-lint-attested.sh" "$ROOT/scripts/attest-native-lint.sh" "$r/scripts/"
    printf 'pub fn f() -> Result<(), String> { Ok(()) }\n' > "$r/crates/tillandsias-macos-tray/src/action_host.rs"
    printf 'pub fn g() {}\n' > "$r/crates/linux-only/src/lib.rs"
    git -C "$r" init -q && git -C "$r" "${GC[@]}" add -A && git -C "$r" "${GC[@]}" commit -qm base
    git -C "$r" update-ref refs/remotes/origin/linux-next HEAD
    echo "$r"
}
incident() { # the 690-w94k line, committed
    printf 'pub fn f() -> Result<(), String> { std::fs::read("x").map_err(|e| format!("{e}"))?; Ok(()) }\n' \
        > "$1/crates/tillandsias-macos-tray/src/action_host.rs"
    git -C "$1" "${GC[@]}" commit -qam "tray: map_err"
}
check()  { OUT="$(cd "$1" && bash scripts/check-native-lint-attested.sh 2>&1)"; RC=$?; }
attest() { AOUT="$(cd "$1" && PATH="$W/bin:$PATH" STUB_RC="$2" bash scripts/attest-native-lint.sh 2>&1)"; ARC=$?; }
commits() { git -C "$1" rev-list --count HEAD; }

# 1 — unattested.
R="$(repo a)"; incident "$R"; check "$R"
if [ "$RC" -eq 1 ] && grep -q '^refused:native-lint:unattested:tillandsias-macos-tray$' <<<"$OUT" \
   && grep -q 'accountable: the AUTHORING darwin host' <<<"$OUT"; then
    ok "arm 1: the incident's change with no attestation is refused, naming the accountable host"
else
    bad "arm 1: rc=$RC [$OUT]"
fi

# 2 — a failing clippy writes nothing.
n0="$(commits "$R")"; attest "$R" 1; check "$R"
if [ "$ARC" -eq 1 ] && grep -q '^failed:attest-native-lint:tillandsias-macos-tray:rc=1$' <<<"$AOUT" \
   && [ "$(commits "$R")" = "$n0" ] && [ "$RC" -eq 1 ]; then
    ok "arm 2: a failing native clippy writes no attestation; the relay still refuses"
else
    bad "arm 2: arc=$ARC commits $n0->$(commits "$R") rc=$RC [$AOUT]"
fi

# 3 — a passing clippy attests; the check admits and names the limitation.
rm -f "$W/cargo.argv"; attest "$R" 0; check "$R"
argv="$(cat "$W/cargo.argv" 2>/dev/null)"
if [ "$ARC" -eq 0 ] && [ "$argv" = "clippy -p tillandsias-macos-tray --all-targets -- -D warnings" ] \
   && [ "$RC" -eq 0 ] && grep -q '^ok:native-lint:attested:tillandsias-macos-tray@' <<<"$OUT" \
   && grep -q 'NOT re-run here' <<<"$OUT"; then
    ok "arm 3: clippy --all-targets -D warnings ran, attested; admitted as attested-not-re-run"
else
    bad "arm 3: arc=$ARC argv=[$argv] rc=$RC [$OUT]"
fi

# 4 — edited after the attestation: stale.
printf '// later\n' >> "$R/crates/tillandsias-macos-tray/src/action_host.rs"
git -C "$R" "${GC[@]}" commit -qam "tray: later edit"; check "$R"
[ "$RC" -eq 1 ] && grep -q '^refused:native-lint:stale:tillandsias-macos-tray$' <<<"$OUT" \
    && ok "arm 4: an edit after attesting makes the attestation stale — refused" \
    || bad "arm 4: rc=$RC [$OUT]"

# 5 — a hand-written trailer naming the wrong platform does not count.
R="$(repo b)"; incident "$R"
tree="$(git -C "$R" rev-parse HEAD:crates/tillandsias-macos-tray)"
git -C "$R" "${GC[@]}" commit -q --allow-empty -m x --trailer "Native-Lint: h linux crates/tillandsias-macos-tray=$tree clippy"
check "$R"
[ "$RC" -eq 1 ] && grep -q '^refused:native-lint:unattested:' <<<"$OUT" \
    && ok "arm 5: a linux attestation of a darwin crate does not count" \
    || bad "arm 5: rc=$RC [$OUT]"

# 6 — NEGATIVE CONTROL: outside the gated crates.
R="$(repo c)"
printf 'pub fn g() { let _ = format!("{}", 1); }\n' > "$R/crates/linux-only/src/lib.rs"
git -C "$R" "${GC[@]}" commit -qam linux; check "$R"
[ "$RC" -eq 0 ] && grep -q '^ok:native-lint:not-in-scope$' <<<"$OUT" \
    && ok "arm 6: a change outside the gated crates needs no attestation" \
    || bad "arm 6: rc=$RC [$OUT]"

# 7 — wired into the relay, after the integrate and before the gate.
L="$ROOT/scripts/land-on-platform-branch.sh"
ln_alloc="$(grep -n 'allocate-gate-step-prefix.sh --base' "$L" | head -1)"; ln_alloc="${ln_alloc%%:*}"
ln_nl="$(grep -n 'bash scripts/check-native-lint-attested.sh --base' "$L" | head -1)"; ln_nl="${ln_nl%%:*}"
ln_gate="$(grep -n 'build.sh --check' "$L" | grep -v '#' | head -1)"; ln_gate="${ln_gate%%:*}"
if [ -n "$ln_nl" ] && [ -n "$ln_alloc" ] && [ -n "$ln_gate" ] && [ "$ln_alloc" -lt "$ln_nl" ] && [ "$ln_nl" -lt "$ln_gate" ] \
   && grep -q 'refused:land:native-lint' "$L"; then
    ok "arm 7: land-on-platform-branch.sh runs the check after the integrate, before the gate (line $ln_nl)"
else
    bad "arm 7: alloc=$ln_alloc native-lint=$ln_nl gate=$ln_gate"
fi

# 8 — the named override, and an empty one.
R="$(repo d)"; incident "$R"
OUT="$(cd "$R" && TILLANDSIAS_NATIVE_LINT_UNATTESTED="no mac awake; tray refactor" bash scripts/check-native-lint-attested.sh 2>&1)"; RC=$?
OUT2="$(cd "$R" && TILLANDSIAS_NATIVE_LINT_UNATTESTED="" bash scripts/check-native-lint-attested.sh 2>&1)"; RC2=$?
if [ "$RC" -eq 0 ] && grep -q '^override:native-lint:unattested:tillandsias-macos-tray:no mac awake; tray refactor$' <<<"$OUT" \
   && [ "$RC2" -eq 1 ] && grep -q 'the land WAITS' <<<"$OUT2" && grep -q 'Native-Lint-Unattested:' "$L"; then
    ok "arm 8: a named override lands as recorded debt; an empty one waits"
else
    bad "arm 8: rc=$RC [$OUT] / empty rc=$RC2"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:native-lint-attested-fixture:$pass/$total"
    exit 0
fi
echo "fail:native-lint-attested-fixture:$pass/$total"
exit 1
