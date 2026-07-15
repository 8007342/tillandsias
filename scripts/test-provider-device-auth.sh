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
    [ "$(stat -c %a "$TMP/home/.claude/.credentials.json")" = "600" ] \
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
grep -q "provider-oauth-vault restore" "$IMG/entrypoint-forge-antigravity.sh" \
    && ok "antigravity entrypoint restores from vault" || bad "antigravity restore not wired"
grep -q "agy-token.env" "$IMG/entrypoint-forge-antigravity.sh" \
    && ok "antigravity sources the token env channel" || bad "antigravity env channel not sourced"
grep -q "ANTHROPIC_API_KEY" "$IMG/entrypoint-forge-claude.sh" \
    && ok "claude API-key launches skip OAuth restore" || bad "claude API-key guard missing"
grep -q "GEMINI_API_KEY" "$IMG/entrypoint-forge-antigravity.sh" \
    && ok "antigravity API-key launches skip OAuth restore" || bad "antigravity API-key guard missing"

echo
echo "provider-device-auth fixture: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ] && { echo "PASS: provider device-auth + oauth-vault contract shape"; exit 0; }
echo "FAIL: provider device-auth fixture"; exit 1
