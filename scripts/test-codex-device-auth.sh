#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/images/default/codex-device-auth.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for vault_helper in \
    "$ROOT/images/git/vault-cli.sh" \
    "$ROOT/images/default/vault-cli.sh"; do
    grep -Fq 'write-stdin' "$vault_helper"
    grep -Fq -- '--cacert "$VAULT_CACERT"' "$vault_helper"
    grep -Fq -- '--header "@$header_file"' "$vault_helper"
done

mkdir -p "$TMP/bin" "$TMP/home/.codex"

cat >"$TMP/lib-common.sh" <<'EOF'
require_codex() {
    printf 'require_codex\n' >>"$REQUIRE_LOG"
    CX_BIN="$REQUIRE_CODEX_BIN"
}
ensure_forge_harnesses() {
    echo "full harness updater must not run in the Codex login one-shot" >&2
    exit 97
}
EOF

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
export REQUIRE_LOG="$TMP/require.log"
export REQUIRE_CODEX_BIN="$TMP/bin/codex-ok"
export TILLANDSIAS_LIB_COMMON="$TMP/lib-common.sh"

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

[[ ! -e "$REQUIRE_LOG" ]]
rm -f "$HOME/.codex/auth.json" "$VAULT_CAPTURE"
bash "$SCRIPT" >/dev/null
[[ "$(cat "$REQUIRE_LOG")" == require_codex ]]
[[ -s "$HOME/.codex/auth.json" ]]
if grep -Fq ensure_forge_harnesses "$SCRIPT"; then
    echo "Codex login one-shot still calls the full harness updater" >&2
    exit 1
fi

echo "PASS: Codex device auth command, require-only install, opaque schema, and fail-loud probe"
