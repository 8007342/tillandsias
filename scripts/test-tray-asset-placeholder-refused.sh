#!/usr/bin/env bash
# @trace order:1059-ry6t
#
# Fixture: a windows-tray build that would embed a ZERO-BYTE guest binary must
# say so — a cargo warning at build time, a refusal at package time — and must
# stay quiet when the asset is real.
#
# WHAT WENT WRONG. crates/tillandsias-windows-tray/src/wsl_lifecycle.rs embeds
# the Linux guest with include_bytes! and injects it at provision time.
# build.rs writes an EMPTY placeholder when that asset is absent so
# `cargo check` compiles on a host that will never package — a deliberate
# accommodation, and the same one render_msix_logos makes for the MSIX logos.
# The logos' comment already states the rule this asset never got: "the
# packaging step is where absence becomes an error, because that is where it
# actually matters."
#
# So `scripts\build-windows-tray.ps1` printed `Built: …` and exited 0 with a
# 0-byte guest compiled in, and the tray's guest injection was a SILENT NO-OP.
# It does not fail at build; it fails later, in a guest that behaves like an
# older release for no visible reason.
#
# MEASURED 2026-09-05: 0 bytes on esmeraldinha since 2026-08-23 and on yolanda
# since 2026-08-22 — TWO OF TWO Windows hosts checked. build.rs creates the
# placeholder on first build and nothing replaces it, so this is the DEFAULT
# state of a Windows dev checkout rather than one stale machine.
#
# ARM 2 IS THE NEGATIVE CONTROL AND IT IS THE SCORABLE HALF. A guard that
# refused unconditionally would pass arm 1 and make the tray unbuildable. The
# real asset case must stay silent, and that is the arm that separates a check
# from a blockade.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS1="$ROOT/scripts/build-windows-tray.ps1"
BUILD_RS="$ROOT/crates/tillandsias-windows-tray/build.rs"
SKILL="$ROOT/skills/build-windows-tray/SKILL.md"
[ -f "$PS1" ] || { echo "SKIP: build-windows-tray.ps1 not present" >&2; exit 0; }

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

echo "== 1059-ry6t: a placeholder guest asset must not build a silent no-op tray"

# ---- ARMS 1 and 2: the packaging predicate, EXECUTED ------------------------
# Run the same emptiness test the script applies, against a 0-byte asset and a
# real one. Executed rather than pattern-matched: the question is whether the
# condition discriminates, and only running it answers that.
#
# THE PROBE IS CHECKED BEFORE ITS ANSWER IS TRUSTED (order 1059-ry6t, learned
# the hard way here). The first version guarded on `command -v powershell.exe`,
# which is TRUE inside the WSL distro the gate re-execs into — via interop —
# while the path translation these arms need is not available there. The arms
# then compared an EMPTY STRING against "missing" and reported two failures on
# a correct tree. An empty result is not a verdict; it is the absence of one,
# and treating absence as a value is the family this whole packet belongs to.
#
# So: probe first, and SKIP loudly if the probe cannot answer. A fixture that
# cannot run its own arm must say so rather than fail the tree.
_ps_usable=no
if command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    if [ "$(powershell.exe -NoProfile -Command "'probe-ok'" 2>/dev/null | tr -d '\r\n ')" = "probe-ok" ]; then
        _ps_usable=yes
    fi
fi

if [ "$_ps_usable" = yes ]; then
    W="$(mktemp -d)"
    : > "$W/placeholder"
    printf 'ELF-ish real bytes' > "$W/real"
    verdict() { # name -> missing|ok|<empty means the probe broke>
        local win
        win="$(cygpath -w "$W/$1")"
        powershell.exe -NoProfile -Command "
            \$a = '$win'
            if ((-not (Test-Path \$a)) -or ((Get-Item \$a).Length -eq 0)) { 'missing' } else { 'ok' }
        " 2>/dev/null | tr -d '\r\n '
    }
    v_placeholder="$(verdict placeholder)"
    v_real="$(verdict real)"
    if [ -z "$v_placeholder" ] || [ -z "$v_real" ]; then
        echo "  SKIP arms 1-2: powershell probed usable but returned nothing; not scoring an absent answer" >&2
    else
        _result "arm1-a-zero-byte-asset-is-detected" "missing" "$v_placeholder"
        _result "arm2-NEGATIVE-CONTROL-a-real-asset-is-not-flagged" "ok" "$v_real"
    fi
    rm -rf "$W"
else
    echo "  SKIP arms 1-2: no usable powershell+cygpath here (the gate re-execs into WSL); not asserting the predicate from prose" >&2
fi

# ---- ARM 3: the packaging script actually REFUSES on that condition ---------
# Comments are stripped: this script explains the placeholder policy in prose
# right above the guard, and a scan that matched the explanation would pass on a
# file that had lost the guard (the 1055-6yp8 lesson).
ps_code="$(sed 's/^[[:space:]]*#.*//' "$PS1")"
case "$ps_code" in
    *"guest asset is a placeholder"*) refuses=yes ;;
    *) refuses=no ;;
esac
_result "arm3-packaging-refuses-on-a-placeholder" "yes" "$refuses"

case "$ps_code" in
    *'(Get-Item $asset).Length -eq 0'*) tests_len=yes ;;
    *) tests_len=no ;;
esac
_result "arm3-scope-control-the-refusal-tests-the-LENGTH" "yes" "$tests_len"

# The refusal must come BEFORE the success line, or the operator is told the
# build succeeded and then told it did not.
before="$(printf '%s' "$ps_code" | grep -n 'guest asset is a placeholder' | head -1 | cut -d: -f1)"
built="$(printf '%s' "$ps_code" | grep -n 'Built: \$exe' | head -1 | cut -d: -f1)"
if [ -n "$before" ] && [ -n "$built" ] && [ "$before" -lt "$built" ]; then order=ok; else order="refusal=$before built=$built"; fi
_result "arm3-the-refusal-precedes-the-Built-line" "ok" "$order"

# ---- ARM 4: build.rs warns on the zero-byte CONDITION, not only on creation --
# The placeholder persists, so a host that generated it in August would never be
# told again if the warning fired only when the file was created.
rs_code="$(sed 's|^[[:space:]]*//.*||' "$BUILD_RS")"
case "$rs_code" in
    *"cargo:warning=tillandsias-windows-tray"*) warns=yes ;;
    *) warns=no ;;
esac
_result "arm4-build-rs-emits-a-cargo-warning" "yes" "$warns"
case "$rs_code" in
    *"m.len() == 0"*) on_condition=yes ;;
    *) on_condition=no ;;
esac
_result "arm4-the-warning-fires-on-the-zero-byte-CONDITION" "yes" "$on_condition"

# ---- ARM 5: the documented path names the staging step ----------------------
# The skill's own description is "Build + install the windows-tray release
# binary on the local Windows host", and before this order it did not mention
# the asset, musl, or embedding at all.
if [ -f "$SKILL" ]; then
    n="$(grep -ciE 'musl|include_bytes|placeholder' "$SKILL")"
    if [ "$n" -gt 0 ]; then names=yes; else names=no; fi
    _result "arm5-the-skill-names-the-staging-step" "yes" "$names"
fi

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:tray-asset-placeholder:$fail arm(s) failed"
    exit 1
fi
echo "ok:tray-asset-placeholder:$pass arm(s)"
