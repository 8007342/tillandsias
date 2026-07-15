#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/images/default/codex-oauth-vault.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/project"
printf '{"access_token":"fixture-access","refresh_token":"fixture-refresh"}\n' >"$TMP/expected.json"
base64 -w0 <"$TMP/expected.json" >"$TMP/vault-value"

cat >"$TMP/bin/vault-cli.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
[[ "$1" == read ]]
[[ "$2" == -field=credentials_b64 ]]
[[ "$3" == secret/codex/oauth ]]
cat "$VAULT_VALUE"
EOF

cat >"$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmp "$HOME/.codex/auth.json" "$EXPECTED_AUTH"
printf 'argv:' >>"$CALL_LOG"
printf ' %q' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
env | sort >>"$CALL_LOG"
EOF
chmod +x "$TMP/bin/"*

export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export VAULT_VALUE="$TMP/vault-value"
export EXPECTED_AUTH="$TMP/expected.json"
export CALL_LOG="$TMP/calls.log"

bash "$SCRIPT" restore
cmp "$EXPECTED_AUTH" "$HOME/.codex/auth.json"
[[ "$(stat -c %a "$HOME/.codex/auth.json")" == 600 ]]
"$TMP/bin/codex" --fixture

for secret in fixture-access fixture-refresh; do
    if grep -R -Fq "$secret" "$CALL_LOG" "$TMP/project"; then
        echo "credential leaked outside the private auth file" >&2
        exit 1
    fi
done

echo "PASS: Codex OAuth restored byte-identically with mode 0600 and no surface leak"
