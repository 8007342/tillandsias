#!/usr/bin/env bash
# @trace spec:forge-git-identity-anonymization, order:1453-7rzd
#
# test-forge-git-identity-source.sh — the forge's git identity comes from the
# GitHub App login plus the host and a per-forge tillandsia name, is WRITTEN as
# git config, is never exported as GIT_AUTHOR_*/GIT_COMMITTER_*, and every
# commit carries a Tillandsias-Host trailer the fleet's host attribution reads.
#
# Operator 2026-09-28, relayed by macuahuitl-forge: "now that we login with a
# GitHub app we should have access to the user's name and email. We just need
# to juggle host names, and append some tillandsias names for randomness".
#
# Everything runs in a scratch HOME and a scratch repository; no real
# gitconfig, keyring or Vault is read. The shell functions under test are
# EXTRACTED from the real images/default/lib-common.sh, never the whole file
# (its top level runs the forge's start-up side effects).
#
# Arms:
#   1 LAUNCHER  the forge arg builders in the headless binary pass no GIT_* and
#               never read the host gitconfig (source scan, with a negative
#               control that plants the old line and must be caught). The unit
#               tests forge_identity_comes_from_the_app_user_never_the_host_gitconfig
#               and no_app_login_yields_a_project_scoped_identity cover the
#               composed values.
#   2 CONFIG    configure_git_identity with the App user writes
#               user.name "App User (<host> · tillandsia-<species>)" and
#               user.email 7+appuser@users.noreply.github.com as git config.
#   3 SCRATCH   in that same shell, `git -c user.name=fixture -c user.email=f@x
#               commit` authors as fixture <f@x>, even though an older launcher
#               had exported GIT_AUTHOR_NAME.
#   4 TRAILER   a commit made through the installed prepare-commit-msg hook
#               carries Tillandsias-Host: <host>, and fleet-activity.sh
#               attributes it to that host despite the noreply email.
#   5 NEGATIVE  with no identity passed, nothing is configured and nothing from
#               an exported host identity survives into the shell.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
MAIN="$ROOT/crates/tillandsias-headless/src/main.rs"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
command -v git >/dev/null 2>&1 || { echo "blocked:no-git"; exit 2; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/forge-git-identity.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

extract() {   # <name>: print a function (or array) definition from lib-common.sh
    awk -v n="$1" '
        $0 ~ "^"n"\\(\\) \\{" || $0 ~ "^"n"=\\(" { p = 1 }
        p { print }
        p && (/^}$/ || /^\)$/) { exit }' "$LIB"
}

# ── ARM 1: the launcher passes no GIT_* and never reads the host gitconfig ──
builders_clean() {   # <main.rs>: 0 when no forge arg builder exports GIT_* identity
    # Captured first, never piped into grep -q: under pipefail an early-exiting
    # grep can SIGPIPE the producer and turn a match into a failure (792-ksr8).
    local bodies
    bodies="$(awk '
        /^fn append_git_identity_env_args\(/ || /^fn forge_git_identity_env\(/ ||
        /^pub\(crate\) fn forge_git_identity_env\(/ { p = 1 }
        p { print }
        p && /^}/ { p = 0 }' "$1")"
    grep -qE '"GIT_(AUTHOR|COMMITTER)_|read_git_identity_defaults' <<<"$bodies" && return 1
    grep -qE '^fn append_git_identity_env_args\(args: &mut Vec<String>, project_name: &str\)' "$1" || return 1
    return 0
}
if builders_clean "$MAIN"; then
    ok "ARM1 the forge identity carrier passes TILLANDSIAS_GIT_* only and reads no host gitconfig"
else bad "ARM1 a forge arg builder still exports GIT_* or reads read_git_identity_defaults"; fi
mutant="$scratch/main.mutant.rs"
sed 's/("TILLANDSIAS_GIT_NAME", name),/("GIT_AUTHOR_NAME", name),/' "$MAIN" >"$mutant"
if builders_clean "$mutant"; then
    bad "ARM1 NEGATIVE CONTROL: a builder planting GIT_AUTHOR_NAME was NOT caught"
else ok "ARM1 negative control: planting GIT_AUTHOR_NAME in the carrier is caught"; fi

# The functions under test, with lib-common's helpers stubbed.
trace_lifecycle() { :; }
ensure_forge_git_index() { :; }
_install_expert_refresh_hook() { :; }
eval "$(extract TILLANDSIA_SPECIES)"
eval "$(extract forge_tillandsia_species)"
eval "$(extract _install_agent_trailer_hook)"
eval "$(extract configure_git_identity)"
declare -F configure_git_identity >/dev/null || { echo "FAIL: configure_git_identity not found"; exit 1; }

export GIT_CONFIG_NOSYSTEM=1

# ── ARMS 2–4: App user, in a scratch HOME ───────────────────────────────────
(
    export HOME="$scratch/home-app"; mkdir -p "$HOME"
    # An OLDER launcher's exported identity: must not survive.
    export GIT_AUTHOR_NAME="Host Person" GIT_AUTHOR_EMAIL="host@example.test"
    export GIT_COMMITTER_NAME="Host Person" GIT_COMMITTER_EMAIL="host@example.test"
    export TILLANDSIAS_GIT_NAME="App User" TILLANDSIAS_GIT_EMAIL="7+appuser@users.noreply.github.com"
    export TILLANDSIAS_GIT_HOST="lenovinha" TILLANDSIAS_GIT_IDENTITY_SOURCE="github-app"
    configure_git_identity

    name="$(git config --global user.name)"; email="$(git config --global user.email)"
    case "$name" in
        "App User (lenovinha · tillandsia-"*")") ok "ARM2 user.name is config: $name" ;;
        *) bad "ARM2 user.name = '$name'" ;;
    esac
    [ "$email" = "7+appuser@users.noreply.github.com" ] && ok "ARM2 user.email is config: $email" \
        || bad "ARM2 user.email = '$email'"
    [ -z "${GIT_AUTHOR_NAME:-}${GIT_COMMITTER_NAME:-}" ] && ok "ARM2 no GIT_* identity left exported" \
        || bad "ARM2 GIT_AUTHOR_NAME='${GIT_AUTHOR_NAME:-}' survived"
    species1="$(forge_tillandsia_species)"; species2="$(forge_tillandsia_species)"
    [ -n "$species1" ] && [ "$species1" = "$species2" ] && ok "ARM2 the species is stable for the forge's life ($species1)" \
        || bad "ARM2 species changed: $species1 -> $species2"

    repo="$scratch/repo"; git init -q "$repo"; cd "$repo" || exit 1
    echo a >a; git add a
    git -c user.name=fixture -c user.email=f@x commit -q -m "scratch" 2>/dev/null
    author="$(git log -1 --format='%an <%ae>')"
    [ "$author" = "fixture <f@x>" ] && ok "ARM3 a scratch repo's own -c identity wins: $author" \
        || bad "ARM3 scratch commit authored as '$author'"

    echo b >b; git add b; git commit -q -m "through the hook" 2>/dev/null
    trailer="$(git log -1 --format='%(trailers:key=Tillandsias-Host,valueonly)' | tr -d '[:space:]')"
    [ "$trailer" = "lenovinha" ] && ok "ARM4 the hook wrote Tillandsias-Host: $trailer" \
        || bad "ARM4 Tillandsias-Host trailer = '$trailer'"
    mkdir -p scripts; cp "$ROOT/scripts/fleet-activity.sh" scripts/
    report="$(bash scripts/fleet-activity.sh --ref HEAD --since '1.day' 2>&1)"
    if grep -qE '^[[:space:]]*lenovinha[[:space:]]' <<<"$report"; then
        ok "ARM4 fleet-activity.sh attributes the noreply commit to lenovinha"
    else bad "ARM4 fleet-activity.sh did not attribute it to lenovinha: $(printf '%s' "$report" | tr '\n' '|')"; fi
    exit "$FAIL"
) || FAIL=1

# ── ARM 5: NEGATIVE CONTROL, no identity passed ─────────────────────────────
(
    export HOME="$scratch/home-none"; mkdir -p "$HOME"
    export GIT_AUTHOR_NAME="Host Person" GIT_AUTHOR_EMAIL="host@example.test"
    unset TILLANDSIAS_GIT_NAME TILLANDSIAS_GIT_EMAIL TILLANDSIAS_GIT_HOST
    configure_git_identity
    name="$(git config --global user.name 2>/dev/null)"
    if [ -z "$name" ] && [ -z "${GIT_AUTHOR_NAME:-}" ]; then
        ok "ARM5 with no identity passed, nothing is configured and the exported host identity is gone"
    else bad "ARM5 user.name='$name' GIT_AUTHOR_NAME='${GIT_AUTHOR_NAME:-}'"; fi
    exit "$FAIL"
) || FAIL=1

[ "$FAIL" -eq 0 ] && { echo "PASS: forge-git-identity-source (1453-7rzd)"; exit 0; }
echo "FAILED: forge-git-identity-source (1453-7rzd)"; exit 1
