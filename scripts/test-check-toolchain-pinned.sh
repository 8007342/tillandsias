#!/usr/bin/env bash
# Fixture for scripts/lua/check-toolchain-pinned.lua (order 1562-tc7p).
#
# The live tree passes, and each way the toolchain can float is refused on a
# COPY: a workflow back on `stable`, a hand-copied version, a channel that is
# not X.Y.Z, a missing pin file, the flake back on `stable.latest`, a build
# script that stops reading the pin. One negative control: a COMMENT that
# says `toolchain: stable` is not a toolchain input and must not refuse, or the
# guard would push people to delete the history that explains the pin.
#
# Hermetic: every mutation happens under TMPDIR. The live tree is never written.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ] || ! grep -qx script <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:toolchain-pinned-fixture:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
LUA="$ROOT/scripts/lua/check-toolchain-pinned.lua"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-pinned.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0
passes=0

expect() {
    # expect <name> <want-verdict-prefix> <want-exit> <root> [<want-line-substring>]
    local name="$1" want="$2" want_rc="$3" dir="$4" want_line="${5:-}" got rc
    got="$(TILLANDSIAS_TOOLCHAIN_PIN_ROOT="$dir" "$PLAN" script run "$LUA" 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        echo "FAIL: $name — exit $rc, want $want_rc; output: $got" >&2
        fails=$((fails + 1)); return
    fi
    case "$(printf '%s\n' "$got" | tail -n 1)" in
        "$want"*) ;;
        *) echo "FAIL: $name — verdict '$(printf '%s\n' "$got" | tail -n 1)', want '${want}*'" >&2
           fails=$((fails + 1)); return ;;
    esac
    if [ -n "$want_line" ] && ! grep -qF -- "$want_line" <<<"$got"; then
        echo "FAIL: $name — no line naming '$want_line'; output: $got" >&2
        fails=$((fails + 1)); return
    fi
    echo "ok:   $name"
    passes=$((passes + 1))
}

seed() {
    local d="$TMP/$1"
    mkdir -p "$d/.github/workflows" "$d/scripts"
    cp "$ROOT/rust-toolchain.toml" "$ROOT/flake.nix" "$d/"
    cp "$ROOT/.github/workflows/"*.yml "$d/.github/workflows/"
    cp "$ROOT/scripts/build-macos-tray.sh" "$ROOT/scripts/build-windows-tray.ps1" "$d/scripts/"
    printf '%s' "$d"
}
# In-place text substitution on a copy, portable across BSD and GNU (no sed -i).
subst() {
    local file="$1" from="$2" to="$3" tmp
    tmp="$(mktemp "$TMP/subst.XXXXXX")"
    FROM="$from" TO="$to" awk '{ i = index($0, ENVIRON["FROM"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])); print }' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
PIN_EXPR='${{ steps.rust-pin.outputs.channel }}'

# 1. The live tree passes.
expect "live-tree-passes" "ok:toolchain-pinned:" 0 "$ROOT"

# 2. A workflow back on `stable` is refused, naming the line.
d="$(seed stable)"; subst "$d/.github/workflows/release.yml" "toolchain: $PIN_EXPR" "toolchain: stable"
expect "workflow-stable-refused" "violation:toolchain-floats:" 1 "$d" "release.yml:"

# 3. A hand-copied version drifts the moment the pin moves: refused.
d="$(seed copied)"; subst "$d/.github/workflows/release.yml" "toolchain: $PIN_EXPR" "toolchain: 1.99.0"
expect "workflow-copied-version-refused" "violation:toolchain-floats:" 1 "$d" "toolchain '1.99.0'"

# 4. A channel that floats is refused.
d="$(seed channel)"; subst "$d/rust-toolchain.toml" 'channel = "' 'channel = "stable" # was "'
expect "channel-stable-refused" "violation:toolchain-floats:" 1 "$d" "channel 'stable' floats"

# 5. No pin file: refused, not silently ok.
d="$(seed nofile)"; rm -f "$d/rust-toolchain.toml"
expect "pin-file-missing-refused" "violation:toolchain-floats:" 1 "$d" "rust-toolchain.toml:0:missing"

# 6. The flake back on `stable.latest`: refused.
d="$(seed flake)"; subst "$d/flake.nix" 'pkgs.rust-bin.stable.${rustPin}.default' 'pkgs.rust-bin.stable.latest.default'
expect "flake-latest-refused" "violation:toolchain-floats:" 1 "$d" "flake.nix:"

# 7. A build script that stops reading the pin: refused.
d="$(seed script)"; subst "$d/scripts/build-macos-tray.sh" "rust-toolchain.toml" "some-other-file"
expect "build-script-unpinned-refused" "violation:toolchain-floats:" 1 "$d" "build-macos-tray.sh:0"

# 8. NEGATIVE CONTROL: a comment mentioning `toolchain: stable` is history, not
#    an input. (The live release.yml carries exactly such a comment.)
d="$(seed comment)"; printf '      # toolchain: stable  (the old float, 1562-tc7p)\n' >> "$d/.github/workflows/release.yml"
expect "comment-is-not-an-input" "ok:toolchain-pinned:" 0 "$d"

echo "test-check-toolchain-pinned: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
