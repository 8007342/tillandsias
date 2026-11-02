#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# Offline fixture for the generic provider device-auth + oauth-vault helpers
# (Claude/Antigravity; Codex has its own verified fixture). No network, no
# real vault, no real provider CLIs — stubs prove the contract shape:
#   1. device-auth scripts refuse fallbacks loudly (probe-gated)
#   2. credentials flow stdin-only into vault (never argv/env)
#   3. restore materializes the credential file 0600 (+ agy env channel)
#   4. entrypoints wire restore + rotation-harvest session
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$ROOT/images/default"
PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[1] syntax + shape"
bash -n "$IMG/provider-device-auth.sh" && bash -n "$IMG/provider-oauth-vault.sh" \
    && ok "scripts parse" || bad "syntax error"
grep -q -- "--claudeai" "$IMG/provider-device-auth.sh" \
    && ok "claude probe pins operator command (--claudeai)" || bad "claude --claudeai probe missing"
grep -q "refusing browser or paste-token fallback" "$IMG/provider-device-auth.sh" \
    && ok "fail-loud fallback refusal present" || bad "fallback refusal missing"
grep -q "write-stdin" "$IMG/provider-device-auth.sh" \
    && ok "vault write is stdin-only" || bad "vault write not stdin-only"
if grep -E 'vault-cli.sh write.*\$TOKEN|vault-cli.sh write.*credentials_b64=[^ ]' "$IMG/provider-device-auth.sh" >/dev/null; then
    bad "credential appears in argv"
else
    ok "no credential in argv"
fi
grep -q "ANTIGRAVITY_TOKEN" "$IMG/provider-oauth-vault.sh" \
    && ok "agy env channel present (upstream #479)" || bad "ANTIGRAVITY_TOKEN channel missing"
# Operator repro 2026-07-15: the login container starts WITHOUT agy — the
# script must install it (shared lib-common installer), never assume it.
grep -q "require_antigravity" "$IMG/provider-device-auth.sh" \
    && ok "agy login installs agy on demand" || bad "agy login assumes pre-installed agy"
grep -q "^require_antigravity()" "$IMG/lib-common.sh" \
    && ok "require_antigravity shared in lib-common" || bad "require_antigravity not in lib-common"

echo "[2] stubbed restore round-trip (claude)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
DOC='{"claudeAiOauth":{"accessToken":"fixture","refreshToken":"fixture"}}'
cat > "$TMP/bin/vault-cli.sh" <<STUB
#!/usr/bin/env bash
case "\$1" in
  read) printf '%s' '$(printf '%s' "$DOC" | base64 -w0)' ;;
  write-stdin) cat >/dev/null ;;
esac
STUB
chmod +x "$TMP/bin/vault-cli.sh"
if PATH="$TMP/bin:$PATH" HOME="$TMP/home" TILLANDSIAS_OAUTH_PROVIDER=claude \
     bash "$IMG/provider-oauth-vault.sh" restore; then
    [ -s "$TMP/home/.claude/.credentials.json" ] \
        && ok "restore materializes credential file" || bad "credential file missing"
    [ "$(stat -c %a "$TMP/home/.claude/.credentials.json" 2>/dev/null || stat -f %Lp "$TMP/home/.claude/.credentials.json")" = "600" ] \
        && ok "credential file is 0600" || bad "credential file mode wrong"
    diff <(printf '%s' "$DOC") "$TMP/home/.claude/.credentials.json" >/dev/null \
        && ok "opaque document byte-identical" || bad "document corrupted"
else
    bad "claude restore failed"
fi

echo "[3] stubbed restore emits agy env channel"
if PATH="$TMP/bin:$PATH" HOME="$TMP/home" TILLANDSIAS_OAUTH_PROVIDER=antigravity \
     TILLANDSIAS_AGY_TOKEN_ENV_FILE="$TMP/agy-token.env" \
     bash "$IMG/provider-oauth-vault.sh" restore; then
    grep -q "^export ANTIGRAVITY_TOKEN=" "$TMP/agy-token.env" \
        && ok "ANTIGRAVITY_TOKEN env file emitted" || bad "env file missing export"
else
    bad "antigravity restore failed"
fi

echo "[4] entrypoint wiring"
grep -q "provider-oauth-vault restore" "$IMG/entrypoint-forge-claude.sh" \
    && ok "claude entrypoint restores from vault" || bad "claude restore not wired"
grep -q "codex-oauth-session -- " "$IMG/entrypoint-forge-claude.sh" \
    && ok "claude rotation-harvest session wired" || bad "claude session wrapper missing"
# The session wrapper must NOT background the interactive agent (backgrounding
# detaches stdin from the tty -> "stdin is not a terminal"; operator repro
# 2026-07-15). Foreground model: harvest via EXIT trap, agent runs in fg.
if grep -vE '^\s*#' "$IMG/codex-oauth-session.sh" | grep -qE '"\$@"\s*&'; then
    bad "session wrapper backgrounds the interactive agent (breaks tty)"
else
    ok "session wrapper runs agent in foreground (tty preserved)"
fi
grep -qE "trap [a-z_]+ EXIT" "$IMG/codex-oauth-session.sh" \
    && ok "harvest on EXIT trap" || bad "harvest-on-exit trap missing"
grep -q "provider-oauth-vault restore" "$IMG/entrypoint-forge-antigravity.sh" \
    && ok "antigravity entrypoint restores from vault" || bad "antigravity restore not wired"
grep -q "agy-token.env" "$IMG/entrypoint-forge-antigravity.sh" \
    && ok "antigravity sources the token env channel" || bad "antigravity env channel not sourced"
grep -q "ANTHROPIC_API_KEY" "$IMG/entrypoint-forge-claude.sh" \
    && ok "claude API-key launches skip OAuth restore" || bad "claude API-key guard missing"
grep -q "GEMINI_API_KEY" "$IMG/entrypoint-forge-antigravity.sh" \
    && ok "antigravity API-key launches skip OAuth restore" || bad "antigravity API-key guard missing"

echo "[5] negative control: agy probe rejects 'auth' and succeeds end-to-end (1496-x76p)"
TMP_AGY="$(mktemp -d "${TMPDIR:-/tmp}/provider-device-auth-agy.XXXXXX")"; trap 'rm -rf "$TMP" "$TMP_AGY"' EXIT
mkdir -p "$TMP_AGY/bin" "$TMP_AGY/home"
cat > "$TMP_AGY/bin/agy" <<'FAKE_AGY'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "--help" ]]; then
        cat <<'HELP'
Usage of agy:
Available subcommands:
  mcp             Manage MCP servers
  update          Update CLI
HELP
        exit 0
    fi
done
if [[ "${1:-}" == "auth" ]]; then
    echo 'Error: unexpected argument "auth".' >&2
    exit 2
fi
# Default interactive login creates the token file
mkdir -p "$HOME/.gemini/antigravity-cli"
echo "fixture-token-secret" > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
exit 0
FAKE_AGY
chmod +x "$TMP_AGY/bin/agy"

cat > "$TMP_AGY/bin/vault-cli.sh" <<'FAKE_VAULT'
#!/usr/bin/env bash
case "$1" in
  read) exit 0 ;;
  write-stdin) cat >/dev/null ;;
esac
FAKE_VAULT
chmod +x "$TMP_AGY/bin/vault-cli.sh"

cat > "$TMP_AGY/lib-common.sh" <<'FAKE_LC'
#!/usr/bin/env bash
require_antigravity() { return 0; }
FAKE_LC

if PATH="$TMP_AGY/bin:$PATH" HOME="$TMP_AGY/home" \
     TILLANDSIAS_LIB_COMMON="$TMP_AGY/lib-common.sh" \
     bash "$IMG/provider-device-auth.sh" antigravity >/dev/null 2>&1; then
    ok "agy negative control avoids 'auth' and stores token in Vault"
else
    bad "agy negative control failed"
fi

echo "[6] negative control: decoy token file is never harvested"
mkdir -p "$TMP_AGY/home/.gemini/decoy" "$TMP_AGY/home/.config/antigravity"
echo "decoy-token-data" > "$TMP_AGY/home/.gemini/decoy/other-token"
echo "decoy-token-data" > "$TMP_AGY/home/.config/antigravity/token.json"
rm -f "$TMP_AGY/home/.gemini/antigravity-cli/antigravity-oauth-token"
cat > "$TMP_AGY/bin/agy" <<'FAKE_AGY_DECOY'
#!/usr/bin/env bash
for arg in "$@"; do
    [[ "$arg" == "--help" ]] && { echo "Usage: agy"; exit 0; }
done
exit 1
FAKE_AGY_DECOY
chmod +x "$TMP_AGY/bin/agy"

if PATH="$TMP_AGY/bin:$PATH" HOME="$TMP_AGY/home" \
     TILLANDSIAS_LIB_COMMON="$TMP_AGY/lib-common.sh" \
     TILLANDSIAS_AGY_AUTH_FILE="$TMP_AGY/home/vault-target-token" \
     bash "$IMG/provider-device-auth.sh" antigravity >/dev/null 2>&1; then
    bad "decoy token was harvested"
else
    [ ! -f "$TMP_AGY/home/vault-target-token" ] \
        && ok "decoy token is never harvested" \
        || bad "target file created from decoy"
fi

echo "[7] the backgrounded agy reads the person's keystrokes, not /dev/null (1925-agin)"
# agy's interactive sign-in is started in the background so the script can
# watch for its token file. A non-interactive bash gives a background job
# /dev/null as stdin unless it is redirected explicitly, so the sign-in screen
# drew but ignored every key (operator, macOS, 2026-11-01). This fake agy
# writes the token ONLY after it reads a keystroke line from stdin.
rm -f "$TMP_AGY/home/.gemini/antigravity-cli/antigravity-oauth-token" "$TMP_AGY/home/vault-target-token"
cat > "$TMP_AGY/bin/agy" <<'FAKE_AGY_KEYS'
#!/usr/bin/env bash
for arg in "$@"; do
    [[ "$arg" == "--help" ]] && { printf 'Usage of agy:\nAvailable subcommands:\n  update  Update CLI\n'; exit 0; }
done
IFS= read -r key || exit 1
[[ "$key" == "select-sign-in" ]] || exit 1
mkdir -p "$HOME/.gemini/antigravity-cli"
echo "fixture-token-from-keys" > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
sleep 30
FAKE_AGY_KEYS
chmod +x "$TMP_AGY/bin/agy"
if printf 'select-sign-in\n' | PATH="$TMP_AGY/bin:$PATH" HOME="$TMP_AGY/home" \
     TILLANDSIAS_LIB_COMMON="$TMP_AGY/lib-common.sh" \
     bash "$IMG/provider-device-auth.sh" antigravity >/dev/null 2>&1; then
    ok "the backgrounded agy receives stdin and its token reaches Vault"
else
    bad "the backgrounded agy never saw a keystroke (stdin was /dev/null)"
fi

echo
echo "provider-device-auth fixture: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ] && { echo "PASS: provider device-auth + oauth-vault contract shape"; exit 0; }
echo "FAIL: provider device-auth fixture"; exit 1
