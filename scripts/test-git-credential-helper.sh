#!/usr/bin/env bash
# @trace spec:tillandsias-vault, spec:git-mirror-service, spec:secrets-management
#
# Fixture for git-credential-tillandsias (order 424).
#
# The relay used to interpolate the GitHub token into PUSH_URL and pass it as an
# ARGV element to git push/fetch, putting it in /proc/<pid>/cmdline. That
# contradicted this repo's own stated invariant ("never appears in process
# argv", vault-cli.sh). Git's credential protocol hands the token over on stdin
# instead. This fixture pins the protocol behaviour hermetically, with a stub
# vault-cli — no real Vault required.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/images/git/git-credential-tillandsias.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$HELPER" ] || fail "helper not executable: $HELPER"

mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"

stub_vault() {  # stub_vault <token-or-empty>
    cat > "$WORK/bin/vault-cli" <<EOF
#!/bin/sh
[ "\$1" = "read" ] || exit 1
printf '%s' "$1"
EOF
    chmod +x "$WORK/bin/vault-cli"
}

# --- case 1: get returns the documented username/password pair --------------
stub_vault "ghp_example_token"
OUT="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>/dev/null)"
printf '%s' "$OUT" | grep -qx 'username=oauth2' || fail "case1: missing username=oauth2; got: $OUT"
printf '%s' "$OUT" | grep -qx 'password=ghp_example_token' || fail "case1: missing password; got: $OUT"
echo "case 1 ok: get returns username=oauth2 and the vault token"

# --- case 2: an ABSENT token fails loud, never emits an empty password ------
# An empty password would make git attempt an anonymous push that fails with a
# confusing 403 instead of naming the real cause.
stub_vault ""
if OUT2="$(printf 'protocol=https\nhost=github.com\n\n' | "$HELPER" get 2>/dev/null)"; then
    fail "case2: helper must exit non-zero when no token is available"
fi
printf '%s' "${OUT2:-}" | grep -q 'password=' \
    && fail "case2: must NOT emit an empty password; got: ${OUT2:-}"
echo "case 2 ok: absent token fails loud with no empty password"

# --- case 3: store/erase are no-ops (Vault owns the credential) -------------
stub_vault "ghp_example_token"
printf 'protocol=https\n\n' | "$HELPER" store >/dev/null 2>&1 || fail "case3: store must be a no-op"
printf 'protocol=https\n\n' | "$HELPER" erase >/dev/null 2>&1 || fail "case3: erase must be a no-op"
echo "case 3 ok: store/erase are no-ops, nothing cached by git"

# --- case 4: the token never reaches argv ----------------------------------
# The whole point. Assert the helper is not invoked with the secret and that the
# relay builds a clean URL.
grep -q 'oauth2:\${\?TOKEN' "$ROOT/images/git/relay-refs.sh" \
    && fail "case4: relay still interpolates the token into a URL"
grep -Fq 'PUSH_URL="$(echo "$REMOTE_URL"' "$ROOT/images/git/relay-refs.sh" \
    || fail "case4: relay no longer builds a bare push URL"
echo "case 4 ok: relay builds a clean URL; token never enters argv"

echo "PASS: git credential helper fixture (order 424)"
