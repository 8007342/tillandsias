#!/usr/bin/env bash
# release-preflight.sh — every release gate that does NOT need cloud minutes.
# @trace spec:versioning, spec:methodology-accountability
# @cheatsheet concurrent-git/plan-discipline.md
#
# WHY THIS EXISTS
#
# Operator directive, 2026-08-03: "ONLY the actual release needs to run in the
# cloud, since it uses github secrets for signing some binaries, everything else
# runs locally." A validation that can run on our own hardware for the price of
# electricity has no business consuming paid CI minutes — and a gate that only
# fires AFTER the cloud build has already run is the worst of both worlds: it
# spends the minutes and then tells you the release was never valid.
#
# So these gates moved OUT of .github/workflows/release.yml and into here. They
# run before a release is triggered, on local hardware, and they refuse early.
#
# WHAT DELIBERATELY STAYS IN THE CLOUD
#
#   * Cosign signing — keyless Sigstore signing binds the artifact to a GitHub
#     OIDC identity. That identity IS the provenance; minting it locally would
#     defeat the purpose, not save money.
#   * Native platform builds and the GitHub Release upload — macOS artifacts must
#     be built and signed on macOS, Windows on Windows, and publishing needs the
#     GitHub API.
#
# VERDICT GRAMMAR (one line on stdout, nothing else):
#   ok:release-preflight
#   blocked:<reason>
#
# Exit 0 on ok, non-zero on blocked. Detail goes to stderr so the verdict line
# stays machine-greppable.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "blocked:not-a-git-repo"
    exit 2
}
cd "$REPO_ROOT" || { echo "blocked:cannot-enter-repo-root"; exit 2; }

verbose=false
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && verbose=true

note() { [[ "$verbose" == true ]] && echo "  $*" >&2; return 0; }
fail() { echo "$*" >&2; }

# ── Gate 1: VERSION monotonicity ───────────────────────────────────────────────
# Pure git + VERSION arithmetic. Was `bash scripts/verify-version-monotonic.sh`
# in release.yml; nothing about it needed a runner.
if [[ -x scripts/verify-version-monotonic.sh || -f scripts/verify-version-monotonic.sh ]]; then
    if ! out="$(bash scripts/verify-version-monotonic.sh 2>&1)"; then
        fail "VERSION monotonicity FAILED:"
        fail "$out"
        echo "blocked:version-not-monotonic"
        exit 1
    fi
    note "version monotonic"
else
    echo "blocked:version-monotonic-script-missing"
    exit 1
fi

# ── Gate 2: retired setup/secrets flags are gone from the CLI ──────────────────
# release.yml ran this against the freshly built release artifact. We build
# locally anyway, so run the SAME check here against a local binary.
#
# Honesty about modes: the binary check is the real one. When no binary is
# present we fall back to a source-level check, and SAY SO rather than reporting
# a pass we did not earn. The two are not equivalent — a source grep cannot see
# what the built help text actually renders.
RETIRED_RE='(^|[^a-z-])--(install|without-vault|legacy-keyring-secrets)([^a-z-]|$)'
bin=""
for candidate in \
    target/x86_64-unknown-linux-musl/release/tillandsias \
    target/release/tillandsias \
    target/aarch64-unknown-linux-musl/release/tillandsias; do
    [[ -x "$candidate" ]] && { bin="$candidate"; break; }
done

if [[ -n "$bin" ]]; then
    help_out="$("$bin" --help 2>&1 || true)"
    if grep -qE -- "$RETIRED_RE" <<<"$help_out"; then
        fail "binary $bin still advertises a retired flag in --help:"
        grep -oE -- "$RETIRED_RE" <<<"$help_out" | sort -u | sed 's/^/    /' >&2
        echo "blocked:retired-flag-advertised"
        exit 1
    fi
    note "retired flags absent from $bin --help (binary mode)"
else
    # --init is a SUPPORTED, spec-mandated flag (tillandsias-vault
    # linux.only-secret-store@v3: "tillandsias --init SHALL ALWAYS bootstrap
    # Vault"). Only the v0.3-retired flags are banned. A guard that also banned
    # --init blocked every release after v0.3.260608.4; do not reintroduce it.
    # The help text is emitted from main.rs. Match only lines that would RENDER a
    # flag into --help output, not the rejection handler that names the retired
    # flags in order to refuse them (main.rs:617-620) — that code is the guard
    # working, and matching it would make this gate permanently red.
    if grep -nE '^\s*(println!|eprintln!|writeln!|\s+")' crates/tillandsias-headless/src/main.rs 2>/dev/null \
        | grep -E -- '--without-vault|--legacy-keyring-secrets' \
        | grep -vqiE 'REMOVED|retired|no longer|error'; then
        fail "a retired flag appears in help-rendering source in main.rs"
        echo "blocked:retired-flag-in-usage-text"
        exit 1
    fi
    note "no local binary found — retired-flag check ran in SOURCE mode (weaker)"
    note "build first for the real check: ./build.sh --release"
fi

# ── Gate 3: plan ledger integrity ──────────────────────────────────────────────
# A release whose ledger does not parse cannot have a trustworthy provenance
# trail. Cheap, local, and already compiled.
if [[ -x target/release/tillandsias-plan ]]; then
    if ! out="$(target/release/tillandsias-plan check 2>&1)"; then
        fail "plan ledger check FAILED:"
        fail "$out"
        echo "blocked:plan-ledger-invalid"
        exit 1
    fi
    note "plan ledger sound"
else
    note "tillandsias-plan not built — ledger gate SKIPPED (build.sh --check covers it)"
fi

# ── Gate 4: GitHub Actions budget ──────────────────────────────────────────────
# Operator directive, 2026-08-03. release.yml is the ONLY sanctioned workflow.
#
# This checks the WORKING TREE. It is deliberately not the whole story: cron
# workflows are scheduled from the DEFAULT BRANCH, so a file absent here can
# still be burning minutes from main. That is exactly how nix-cache-warm.yml
# kept firing for two days after the purge. litmus:github-actions-budget owns
# the cross-branch check; this one owns "do not reintroduce it here".
if [[ -d .github/workflows ]]; then
    unexpected="$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
        ! -name 'release.yml' -printf '%f\n' 2>/dev/null | sort)"
    if [[ -n "$unexpected" ]]; then
        fail "unsanctioned workflow(s) present — only release.yml may consume cloud minutes:"
        sed 's/^/    /' <<<"$unexpected" >&2
        echo "blocked:unsanctioned-workflow"
        exit 1
    fi
    note "actions budget clean (release.yml only)"
fi

echo "ok:release-preflight"
exit 0
