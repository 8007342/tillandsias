#!/usr/bin/env bash
# @trace order:1235-rfub, spec:ci-release
#
# check-native-lint-attested.sh — a relay may not land a change to a cfg-gated
# platform crate that no host has LINTED NATIVELY for that exact content.
#
# THE DEFECT (1235-rfub, 2026-09-16/17). A relayed macOS-only change carrying a
# clippy hard error (useless_format) landed on trunk at d44909353, and trunk was
# red for every macOS build for hours. The relaying Linux gate compiles STUBS
# for the cfg-gated tray modules (739-6r6n), so it never parsed the line; the
# author's own checks (`cargo test --bins`, a Linux musl zigbuild) never linted
# it either. The lane macOS work MUST use was the lane least able to verify it.
#
# WHY AN ATTESTATION AND NOT A RE-RUN (coordinator ruling, 2026-09-28). The
# first choice was to lint darwin ON LINUX. MEASURED on lenovinha 2026-09-28:
# `cargo clippy -p tillandsias-macos-tray --target aarch64-apple-darwin` fails
# rc=101 in ring's build script (GNU cc rejects -arch / -mmacosx-version-min),
# and the builder has no clang to try otherwise. So the gate cannot re-run the
# lint, and this check can only require that SOME host did. It says so in its
# verdict: an attestation is the author's word, bound to content, not a run.
# If the builder later lints darwin, replace this with a real clippy arm in
# scripts/check-cross-target-build.sh (656-spux).
#
# THE ATTESTATION is a commit trailer written ONLY by scripts/attest-native-lint.sh,
# after its clippy run exits 0:
#     Native-Lint: <host> <platform> <crate-path>=<tree-sha> clippy-all-targets-D-warnings
# <tree-sha> is `git rev-parse <commit>:<crate-path>` — the LINTED content. A
# later edit to the crate changes the subtree, and the attestation goes stale.
#
# SCOPE: a gated crate is in scope when its subtree differs between the base and
# HEAD. An attestation in base..HEAD must name that crate at HEAD's subtree.
# KNOWN LIMIT: path dependencies (tillandsias-core, -host-shell) are not bound;
# a change that only touches a dependency is not asked for a native lint.
#
#   ok:native-lint:not-in-scope                       no gated crate changed
#   ok:native-lint:attested:<crate>@<host>[,...]      attested — NOT re-run here
#   refused:native-lint:unattested:<crate>            (rc 1)
#   refused:native-lint:stale:<crate>                 (rc 1) attested content != HEAD
#   ok:native-lint:base-unavailable                   no base ref; nothing judged
#   override:native-lint:unattested:<pkg>:<reason>    (rc 0) see NO HOST AVAILABLE
#
# NO HOST AVAILABLE (coordinator, 2026-09-28). A crate may have to move with no
# host of its platform awake, e.g. a Linux-side refactor touching the tray.
# Then TILLANDSIAS_NATIVE_LINT_UNATTESTED="<reason>" lets it land UNLINTED, as
# a NAMED DEBT and never silently: the verdict carries the reason, and
# land-on-platform-branch.sh records it as a `Native-Lint-Unattested:` trailer
# on the landed history, so the next attestation on that platform pays it. An
# empty value is not an override. Without it, the land waits.
#
# Usage: check-native-lint-attested.sh [--base REF]    (default origin/linux-next)
#        check-native-lint-attested.sh --list          print the gated crates
set -uo pipefail

# <crate path>:<package>:<platform whose native lint is required>
GATED_CRATES="crates/tillandsias-macos-tray:tillandsias-macos-tray:darwin"

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' $GATED_CRATES
    exit 0
fi

base="${TILLANDSIAS_NATIVE_LINT_BASE:-origin/linux-next}"
if [ "${1:-}" = "--base" ]; then base="${2:?--base needs a ref}"; fi

if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
    echo "ok:native-lint:base-unavailable"
    echo "  note: base ref '$base' unavailable — nothing judged" >&2
    exit 0
fi

trailers="$(git log --format='%(trailers:key=Native-Lint,valueonly)' "$base..HEAD" 2>/dev/null)"

attested=""; refused=0; in_scope=0
for entry in $GATED_CRATES; do
    path="${entry%%:*}"; rest="${entry#*:}"; pkg="${rest%%:*}"; platform="${rest#*:}"
    head_tree="$(git rev-parse --verify --quiet "HEAD:$path" 2>/dev/null)" || continue
    base_tree="$(git rev-parse --verify --quiet "$base:$path" 2>/dev/null)" || base_tree=""
    [ "$head_tree" = "$base_tree" ] && continue
    in_scope=$((in_scope + 1))

    match=""; seen=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        # <host> <platform> <path>=<tree> <what>
        set -- $t
        [ "$#" -ge 3 ] || continue
        [ "$2" = "$platform" ] || continue
        case "$3" in "$path="*) ;; *) continue ;; esac
        seen="$1"
        if [ "${3#"$path="}" = "$head_tree" ]; then match="$1"; break; fi
    done <<EOF
$trailers
EOF

    if [ -n "$match" ]; then
        attested="${attested:+$attested,}$pkg@$match"
    elif [ -n "$seen" ]; then
        refused=1
        echo "refused:native-lint:stale:$pkg"
        {
            echo "  why: $seen attested a native $platform lint of $path, but not of the content being"
            echo "  landed: the crate changed after the attestation ($path=$head_tree now)."
            echo "  remedy: on a $platform host, re-run scripts/attest-native-lint.sh on this ref."
            echo "  no $platform host available? the land WAITS, or set"
            echo "  TILLANDSIAS_NATIVE_LINT_UNATTESTED=\"<reason>\" to land it as recorded debt."
        } >&2
    else
        refused=1
        echo "refused:native-lint:unattested:$pkg"
        {
            echo "  why: this change touches $path, a cfg-gated crate this gate compiles as STUBS and"
            echo "  cannot lint (1235-rfub: a useless_format landed that way and reddened trunk)."
            echo "  accountable: the AUTHORING $platform host. remedy: on that host run"
            echo "  scripts/attest-native-lint.sh, which lints natively and records the result."
            echo "  no $platform host available? the land WAITS, or set"
            echo "  TILLANDSIAS_NATIVE_LINT_UNATTESTED=\"<reason>\" to land it as recorded debt."
        } >&2
    fi
done

if [ "$refused" -ne 0 ]; then
    reason="${TILLANDSIAS_NATIVE_LINT_UNATTESTED:-}"
    if [ -n "$reason" ]; then
        for entry in $GATED_CRATES; do
            rest="${entry#*:}"
            echo "override:native-lint:unattested:${rest%%:*}:$reason"
        done
        echo "  DEBT: landing an UNLINTED cfg-gated crate on the operator's named reason; recorded, not excused" >&2
        exit 0
    fi
    exit 1
fi
if [ "$in_scope" -eq 0 ]; then
    echo "ok:native-lint:not-in-scope"
else
    echo "ok:native-lint:attested:$attested"
    echo "  note: attested by the named host, NOT re-run here — this gate cannot lint $platform" >&2
fi
exit 0
