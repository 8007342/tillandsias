#!/usr/bin/env bash
# =============================================================================
# check-no-tracked-binaries.sh — refuse tracked build artifacts (order 723-ydmk)
#
# 710-w9kc removed ONE committed binary; this repo's history holds at least
# three separate leaks (target-musl/**, images/default/tillandsias-mcp-browser,
# images/router/tillandsias-router-sidecar). The enabling mechanism — an
# artifact matching .gitignore but ALREADY TRACKED, so the ignore is inert —
# is what this guard closes: it fails loud on its own instead of N callers
# each remembering.
#
# Detection is git's OWN binary classification: `git diff --numstat
# <empty-tree> HEAD` reports `-<TAB>-<TAB><path>` for blobs git treats as
# binary. Deliberately NOT file(1): a tracked markdown in plan/archive/
# carries a stray NUL and file(1) calls it data — a permanent false positive
# (packet 723-ydmk exit criterion 1). A second lane refuses tracked paths with
# executable/linkable EXTENSIONS even when git classifies them text (a
# zero-byte or stub .so is still a leak).
#
# Allowlist: image/icon asset PATH PREFIXES only, enumerated below with their
# contents at adoption time. Executable/linkable artifacts are never
# allowlistable — a new prefix requires editing this file, in review.
# (The packet estimated "five icon/image assets"; the empirical set at
# adoption is 38 blobs — the SVG icon families are git-binary-classified —
# under exactly these four prefixes.)
#
# Verdict grammar (single line, falsifiable):
#   ok:no-tracked-binaries:<N> binary-classified <M> allowlisted
#   blocked:tracked-binaries:<path>[,<path>...]
# Exit 0 on ok, 1 on blocked. `fixture` subcommand runs the hermetic
# scenarios (litmus:no-tracked-binaries-shape).
# =============================================================================
set -euo pipefail

ALLOW_PREFIXES=(
    "assets/icons/"                            # SVG species icon families (git-binary-classified)
    "crates/tillandsias-macos-tray/assets/"    # icon.icns, icon.png, tray-icon.png
    "crates/tillandsias-windows-tray/assets/"  # tillandsias.ico
    "images/dmg/"                              # dmg-background.png/.svg
)

# Extensions refused even when git classifies the blob as text.
EXT_RE='\.(so|dylib|dll|exe|a|o|rlib|wasm|pdb)$'

scan() {
    local empty_tree offenders=() allowed=0 classified=0 p pre ok
    empty_tree="$(git hash-object -t tree /dev/null)"

    while IFS= read -r p; do
        [ -n "$p" ] || continue
        classified=$((classified + 1))
        ok=0
        for pre in "${ALLOW_PREFIXES[@]}"; do
            [[ "$p" == "$pre"* ]] && { ok=1; break; }
        done
        if [ "$ok" -eq 1 ]; then
            allowed=$((allowed + 1))
        else
            offenders+=("$p")
        fi
    done < <(git diff --numstat "$empty_tree" HEAD | awk -F'\t' '$1=="-" && $2=="-" {print $3}')

    # Extension lane: never allowlisted, even under an allowed prefix.
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case " ${offenders[*]+"${offenders[@]}"} " in
            *" $p "*) : ;;
            *) offenders+=("$p") ;;
        esac
    done < <(git ls-files | grep -iE "$EXT_RE" || true)

    if [ "${#offenders[@]}" -gt 0 ]; then
        local joined
        joined="$(IFS=,; echo "${offenders[*]}")"
        printf 'blocked:tracked-binaries:%s\n' "$joined"
        return 1
    fi
    printf 'ok:no-tracked-binaries:%d binary-classified %d allowlisted\n' "$classified" "$allowed"
    return 0
}

# ── Hermetic fixtures ───────────────────────────────────────────────────────
# Each scenario builds a throwaway repo and runs THIS script inside it, so the
# fixtures exercise the real detection lanes, not a re-derivation of them.
fixture() {
    local self fail=0 tdir
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    tdir="$(mktemp -d)"
    # Expand at trap-set time: tdir is function-local and out of scope when the
    # EXIT trap fires after fixture() returns (set -u would abort the exit).
    # shellcheck disable=SC2064
    trap "rm -rf '$tdir'" EXIT

    _mkrepo() {
        local d="$1"
        mkdir -p "$d" && git -C "$d" init -q
        git -C "$d" config user.email fixture@localhost
        git -C "$d" config user.name fixture
    }

    # 1. NEGATIVE CONTROL: a text-only repo must pass — otherwise "refuse
    #    everything" would satisfy every positive case below.
    _mkrepo "$tdir/clean"
    printf 'just text\n' > "$tdir/clean/README.md"
    git -C "$tdir/clean" add -A && git -C "$tdir/clean" commit -qm text
    if (cd "$tdir/clean" && bash "$self" | grep -q '^ok:no-tracked-binaries:0 '); then
        echo "ok: NEGATIVE text-only repo passes"
    else
        echo "FIXTURE-FAIL: text-only repo did not pass"; fail=1
    fi

    # 2. A tracked ELF-magic blob (no extension) is refused via the numstat lane.
    _mkrepo "$tdir/elf"
    printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00binary\x00payload\n' > "$tdir/elf/sneaky-artifact"
    git -C "$tdir/elf" add -A && git -C "$tdir/elf" commit -qm elf
    if (cd "$tdir/elf" && ! bash "$self" >/dev/null 2>&1) && \
       (cd "$tdir/elf" && bash "$self" 2>/dev/null || true) | grep -q '^blocked:tracked-binaries:sneaky-artifact$'; then
        echo "ok: tracked ELF blob refused (numstat lane)"
    else
        echo "FIXTURE-FAIL: tracked ELF blob not refused"; fail=1
    fi

    # 3. A zero-byte .so — git classifies it TEXT, the extension lane must
    #    still refuse it.
    _mkrepo "$tdir/ext"
    : > "$tdir/ext/libstub.so"
    printf 'text\n' > "$tdir/ext/ok.txt"
    git -C "$tdir/ext" add -A && git -C "$tdir/ext" commit -qm ext
    if (cd "$tdir/ext" && bash "$self" 2>/dev/null || true) | grep -q '^blocked:tracked-binaries:libstub.so$'; then
        echo "ok: zero-byte .so refused (extension lane)"
    else
        echo "FIXTURE-FAIL: zero-byte .so not refused"; fail=1
    fi

    # 4. A binary under an allowlisted prefix passes — and the verdict counts it.
    _mkrepo "$tdir/allow"
    mkdir -p "$tdir/allow/assets/icons"
    printf 'PNG\x00\x00fake\x00image\n' > "$tdir/allow/assets/icons/icon.png"
    git -C "$tdir/allow" add -A && git -C "$tdir/allow" commit -qm allow
    if (cd "$tdir/allow" && bash "$self" | grep -q '^ok:no-tracked-binaries:1 binary-classified 1 allowlisted$'); then
        echo "ok: allowlisted-prefix image passes"
    else
        echo "FIXTURE-FAIL: allowlisted image did not pass"; fail=1
    fi

    # 5. An executable extension under an ALLOWED prefix is still refused —
    #    the allowlist covers images, never the executable class.
    _mkrepo "$tdir/trojan"
    mkdir -p "$tdir/trojan/assets/icons"
    printf '\x7fELF\x02trojan\x00\n' > "$tdir/trojan/assets/icons/helper.so"
    git -C "$tdir/trojan" add -A && git -C "$tdir/trojan" commit -qm trojan
    if (cd "$tdir/trojan" && bash "$self" 2>/dev/null || true) | grep -q '^blocked:tracked-binaries:.*helper\.so'; then
        echo "ok: executable extension inside allowed prefix still refused"
    else
        echo "FIXTURE-FAIL: .so under allowed prefix not refused"; fail=1
    fi

    if [ "$fail" -eq 0 ]; then
        echo "ok: all no-tracked-binaries scenarios passed"
        return 0
    fi
    echo "fail: no-tracked-binaries fixture scenarios failed"
    return 1
}

if [ "${1:-}" = "fixture" ]; then
    fixture
    exit $?
fi

scan
