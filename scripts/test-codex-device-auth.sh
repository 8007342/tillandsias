#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/images/default/codex-device-auth.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cmp "$ROOT/images/git/vault-cli.sh" "$ROOT/images/default/vault-cli.sh"

mkdir -p "$TMP/bin" "$TMP/home/.codex"

cat >"$TMP/bin/codex-ok" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == --help ]]; then
    echo 'Usage: codex login [--device-auth]'
elif [[ "${1:-}" == login && "${2:-}" == --device-auth ]]; then
    mkdir -p "$HOME/.codex"
    printf '{"access_token":"fixture","refresh_token":"refresh"}\n' >"$HOME/.codex/auth.json"
else
    exit 64
fi
EOF

cat >"$TMP/bin/codex-no-device" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == --help ]]; then
    echo 'Usage: codex login'
else
    echo 'device login must not run after a failed feature probe' >&2
    exit 99
fi
EOF

cat >"$TMP/bin/vault-cli.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$VAULT_ARGV_LOG"
printf '\n' >>"$VAULT_ARGV_LOG"
case "${1:-}" in
    write-stdin)
        [[ "$2" == secret/codex/oauth ]]
        [[ "$3" == credentials_b64 ]]
        cat >"$VAULT_CAPTURE"
        ;;
    read)
        cat "$VAULT_CAPTURE"
        ;;
    *) exit 64 ;;
esac
EOF
chmod 755 "$TMP/bin/"*

export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export VAULT_CAPTURE="$TMP/vault-value"
export VAULT_ARGV_LOG="$TMP/vault-argv.log"

TILLANDSIAS_CODEX_BIN="$TMP/bin/codex-ok" bash "$SCRIPT" >/dev/null
base64 -d <"$VAULT_CAPTURE" >"$TMP/restored.json"
cmp "$HOME/.codex/auth.json" "$TMP/restored.json"
encoded_fixture="$(base64 -w0 <"$HOME/.codex/auth.json")"
if grep -Fq "$encoded_fixture" "$VAULT_ARGV_LOG"; then
    echo "credential leaked into vault helper argv" >&2
    exit 1
fi

set +e
output="$(TILLANDSIAS_CODEX_BIN="$TMP/bin/codex-no-device" bash "$SCRIPT" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]]
grep -Fq "does not support 'codex login --device-auth'" <<<"$output"
grep -Fq 'refusing browser or paste-token fallback' <<<"$output"

echo "PASS: Codex device auth command, opaque schema, and fail-loud probe"
