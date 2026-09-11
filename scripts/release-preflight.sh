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
# Run-don't-stat (order 770-ifeg): `-x` passes for the OTHER platform's
# artifact on a shared Windows/WSL checkout, and an un-execable candidate
# would silently produce an EMPTY --help below — a pass we did not earn.
# Probe by execution; custom-triple dirs stay listed explicitly because
# resolve_target_binary only walks target/<profile>/.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
bin=""
for candidate in \
    target/x86_64-unknown-linux-musl/release/tillandsias \
    target/release/tillandsias.exe \
    target/release/tillandsias \
    target/aarch64-unknown-linux-musl/release/tillandsias; do
    target_binary_runs "$candidate" && { bin="$candidate"; break; }
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
# Order 721-nyev: `-x` is a claim, running the binary is evidence. On a shared
# Windows/WSL checkout the -x test passes on a Linux ELF that cannot execute,
# so this gate reported on a check it never ran.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
_plan_bin="$(resolve_plan_binary || true)"
if [[ -n "$_plan_bin" ]]; then
    # ORDER 796-4ydb. --strict-fragments HERE, and deliberately not in
    # build.sh. A fragment the fold cannot read makes every count drawn from
    # the ledger — burndown, the centicolon signature, the release evidence
    # bundle — a count over less than the plan, and a release is fixed forward:
    # the wrong number ships permanently and is superseded, never repaired. A
    # release cut is also ONE host at ONE moment, so refusing here blocks a
    # deliberate act rather than every sibling's build (699-dycj).
    out="$("$_plan_bin" check --strict-fragments 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 3 ]]; then
        fail "plan ledger is INCOMPLETE — the fold could not read part of the corpus:"
        fail "$out"
        fail "repair the fragment before cutting; a release records counts over the whole plan"
        echo "blocked:plan-ledger-incomplete"
        exit 1
    fi
    if [[ $rc -ne 0 ]]; then
        fail "plan ledger check FAILED:"
        fail "$out"
        echo "blocked:plan-ledger-invalid"
        exit 1
    fi
    # LEGACY BACKSTOP, same reasoning as the pre-push lane: a binary predating
    # 796-4ydb ignores the unknown flag and exits 0, so the refusal above never
    # fires. A current binary cannot reach here with a skipped fragment.
    if printf '%s' "$out" | grep -q 'does not parse and was SKIPPED'; then
        fail "plan ledger is INCOMPLETE and this binary predates --strict-fragments:"
        printf '%s' "$out" | grep 'does not parse and was SKIPPED' >&2
        echo "blocked:plan-ledger-incomplete"
        exit 1
    fi
    note "plan ledger sound and complete"
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

# ── Gate 5: the stable tag agrees with the release page (order 1061-zd83) ─────
#
# refs/tags/stable is a PUBLIC claim, and nothing compared it to the releases
# page. Found by the operator's tillandsias.org session 2026-09-05 while pinning
# the site's "stable" definition, not by any gate here: the tag peeled to
# 341ab0010 (v0.4.260826.1, tagged 2026-08-25) while the latest non-prerelease
# release was v56.9.2.1 at d6d3e3ed9. The site derives stable from
# /releases/latest and only warns; the tag had been wrong for eleven days.
#
# ADVISORY, NOT BLOCKING, and the distinction is deliberate. Moving a public
# force-pushed tag is the operator's call (1061-zd83 routes it there), so a
# release-time refusal would block releases on a condition the runner is not
# permitted to fix. Naming it every preflight is what turns "nobody noticed for
# eleven days" into "everybody sees it".
#
# COULD-NOT-RUN IS NOT DISAGREEMENT (923-ws3r). gh may be unauthenticated — it
# is on this host right now, answering 401 — and a network read may simply fail.
# Reporting "the tag is wrong" when the question could not be asked is how three
# hosts diagnosed the wrong subsystem from one string (894-scxy). So the
# unauthenticated path says so and moves on.
_stable_remote="$(git ls-remote origin 'refs/tags/stable^{}' 2>/dev/null | awk '{print $1}' | head -1)"
if [[ -z "$_stable_remote" ]]; then
    note "stable-vs-latest: could not read refs/tags/stable from origin — not checked"
elif ! command -v gh >/dev/null 2>&1; then
    note "stable-vs-latest: gh absent — not checked"
else
    _latest_tag="$(gh api 'repos/{owner}/{repo}/releases/latest' --jq .tag_name 2>/dev/null)" || _latest_tag=""
    if [[ -z "$_latest_tag" ]]; then
        note "stable-vs-latest: /releases/latest unreadable (gh unauthenticated or offline) — NOT a disagreement, the check could not run"
    else
        _latest_commit="$(git ls-remote origin "refs/tags/${_latest_tag}^{}" 2>/dev/null | awk '{print $1}' | head -1)"
        if [[ -z "$_latest_commit" ]]; then
            note "stable-vs-latest: origin has no peeled tag for $_latest_tag — not checked"
        elif [[ "$_stable_remote" != "$_latest_commit" ]]; then
            echo "  WARNING stable-tag-disagrees-with-latest (1061-zd83):" >&2
            echo "    refs/tags/stable  -> $_stable_remote" >&2
            echo "    $_latest_tag (latest) -> $_latest_commit" >&2
            echo "    The public 'stable' tag does not name the latest release." >&2
            echo "    Moving it is the OPERATOR's call (a public force-pushed tag)." >&2
            echo "    Remedy, on the operator's word:" >&2
            echo "      git tag -f -a stable -m 'Stable channel: $_latest_tag' $_latest_commit" >&2
            echo "      git push origin refs/tags/stable --force" >&2
        else
            note "stable-vs-latest: stable == $_latest_tag ($_stable_remote)"
        fi
    fi
fi

echo "ok:release-preflight"
exit 0
