#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:tillandsias-vault
# Order-414/424 fixture: the relay must DISTINGUISH an unavailable Vault Agent
# client-token sink from a genuinely-absent GitHub token. Before this, an
# expired mirror token surfaced as "run GitHub Login" — a false
# error that sent operators to fix a GitHub credential that was actually fine
# (blocker-git-mirror-relay-token-expiry-2026-07-18).
#
# The discriminator is `vault-cli lookup-self`: if the current sink token
# cannot look itself up, Agent is re-authenticating (or its AppRole material
# failed), not the GitHub credential.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export HOME="$WORK/home"
mkdir -p "$HOME"

# Hermetic git config: no system/global hooks, insteadOf rewrites, or
# credential helpers may leak into the fixture.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$WORK/gitconfig"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A stub `vault-cli` whose per-verb behavior is driven by env vars, so each
# scenario can simulate an expired vs. valid mirror token independently of a
# real Vault server. Exit 2 == HTTP failure (matches the real shim's 403 path).
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/vault-cli" <<'STUB'
#!/bin/sh
case "$1" in
    renew-self)  exit "${STUB_RENEW_RC:-0}" ;;
    lookup-self) exit "${STUB_LOOKUP_RC:-0}" ;;
    read)        exit "${STUB_READ_RC:-0}" ;;
    *)           exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/vault-cli"
export PATH="$STUB_BIN:$PATH"

# Point the relay's mounted-token check at a temp file that exists (the token
# file being present is what makes the relay attempt the vault-cli path at all).
export VAULT_TOKEN_FILE="$WORK/vault-token"
printf 'stub-approle-token' > "$VAULT_TOKEN_FILE"

RELAY="$WORK/tillandsias-relay-refs"
cp "$ROOT/images/git/relay-refs.sh" "$RELAY"
chmod +x "$RELAY"

# A mirror repo with an HTTPS upstream so the relay enters the token-injection
# branch. The relay rejects (exit 1) at the credential check BEFORE any network
# push, so github.example.invalid is never contacted.
MIRROR="$WORK/mirror.git"
git init -q --bare "$MIRROR"
git -C "$MIRROR" config core.hooksPath "$MIRROR/hooks"
git -C "$MIRROR" remote add origin https://github.example.invalid/org/repo.git

DUMMY_SHA="1111111111111111111111111111111111111111"
RECORD="0000000000000000000000000000000000000000 $DUMMY_SHA refs/heads/main"

run_relay() {
    # Run the relay from inside the mirror repo with a synthetic receive record.
    printf '%s\n' "$RECORD" | ( cd "$MIRROR" && "$RELAY" ) 2>&1
}

# ---------------------------------------------------------------------------
# Case 1: Vault Agent sink token EXPIRED. read + lookup-self both 403.
# Expect the honest auto-auth diagnosis, NOT "run GitHub Login".
# ---------------------------------------------------------------------------
export STUB_READ_RC=2 STUB_LOOKUP_RC=2 STUB_RENEW_RC=2
if OUT="$(run_relay)"; then
    fail "case 1: relay returned success with an expired mirror token"
fi
echo "$OUT" | grep -Fq "expired or unavailable" \
    || fail "case 1: relay did not emit the expired-mirror-token diagnosis. Got: $OUT"
# The false-error path emits "HTTPS upstream credential is unavailable"; the
# honest path must not (its own text says "do NOT run GitHub Login").
if echo "$OUT" | grep -Fq "HTTPS upstream credential is unavailable"; then
    fail "case 1: relay FALSELY reported a missing GitHub credential on an expired MIRROR token. Got: $OUT"
fi
echo "case 1 ok: expired Agent sink → honest auto-auth diagnosis, no false GitHub Login"

# ---------------------------------------------------------------------------
# Case 2: mirror token VALID (lookup-self ok) but the GitHub token read fails.
# This is the genuine "absent GitHub credential" case → run GitHub Login.
# ---------------------------------------------------------------------------
export STUB_READ_RC=2 STUB_LOOKUP_RC=0 STUB_RENEW_RC=0
if OUT="$(run_relay)"; then
    fail "case 2: relay returned success with no GitHub token"
fi
echo "$OUT" | grep -Fq "HTTPS upstream credential is unavailable" \
    || fail "case 2: relay did not emit the GitHub-Login guidance for an absent GitHub token. Got: $OUT"
if echo "$OUT" | grep -Fq "expired or unavailable"; then
    fail "case 2: relay misreported a valid mirror token as expired. Got: $OUT"
fi
echo "case 2 ok: valid mirror token + absent GitHub token → run GitHub Login"

# ---------------------------------------------------------------------------
# Case 3: vault-cli routes the new subcommands (not "unknown subcommand").
# Guards against a case-arm regression in vault-cli.sh.
# ---------------------------------------------------------------------------
VC="$ROOT/images/git/vault-cli.sh"
for verb in renew-self lookup-self; do
    OUT="$(VAULT_TOKEN_FILE=/nonexistent/path sh "$VC" "$verb" 2>&1 || true)"
    if echo "$OUT" | grep -Fq "unknown subcommand"; then
        fail "case 3: vault-cli does not recognize '$verb' subcommand"
    fi
done
echo "case 3 ok: vault-cli routes renew-self and lookup-self"

echo "PASS: git-mirror relay distinguishes expired mirror token from absent GitHub token (order 414)"
