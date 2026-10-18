#!/usr/bin/env bash
# @trace spec:default-image, spec:tillandsias-vault, spec:podman-secrets-integration
#
# Order 431: prove OpenCode consumes a Vault-derived OPENCODE_AUTH_CONTENT
# document while auth.json stays absent. (The curl-cache last-good rollback
# arm retired with the opencode curl lane, 2026-08-31 — the npm on-demand
# channel is the only delivery path and carries its own last-good record.)

set -euo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

trace_lifecycle() {
    TRACE_LOG="${TRACE_LOG:-} $*"
}

[ -r "$LIB" ] || fail "cannot read $LIB"

# Source only the credential/probe functions. Sourcing all of
# lib-common would run forge-container setup on the build host.
eval "$(
    sed -n \
        '/^opencode_auth_file_path()/,/^}/p
         /^opencode_remove_stale_auth_file()/,/^}/p
         /^prepare_opencode_vault_auth()/,/^}/p
         /^opencode_auth_contract_ok()/,/^}/p
         /^opencode_actual_auth_ok()/,/^}/p
         /^harness_contract_help_cmd()/,/^}/p
         /^harness_contract_flags()/,/^}/p
         /^harness_contract_ok()/,/^}/p
         /^harness_probe()/,/^}/p
         /^opencode_render_contract_ok()/,/^}/p
         /^opencode_render_contract_cached()/,/^}/p' \
        "$LIB"
)"
# The two render-contract functions are extracted because harness_probe()
# calls opencode_render_contract_cached on the opencode branch
# (images/default/lib-common.sh:2101). Extracting a function without its
# callees gives a fixture that loads fine and then dies at
# "command not found" the moment that branch is taken — which is exactly how
# this fixture broke: it reported line 223 of a 169-line file, because the
# line number belongs to the eval'd text, not to the script on disk. The
# sibling fixture scripts/test-opencode-render-probe.sh extracts both for the
# same reason; keep the two lists in step when lib-common's call graph moves.

for function_name in \
    prepare_opencode_vault_auth \
    opencode_auth_contract_ok \
    opencode_actual_auth_ok; do
    declare -F "$function_name" >/dev/null \
        || fail "could not load $function_name from lib-common.sh"
done

# Secret-construction shape: the Gemini value must flow to jq over stdin,
# never through `--arg` (which would expose it in jq's process argv).
PREPARE_SOURCE="$(sed -n '/^prepare_opencode_vault_auth()/,/^}/p' "$LIB")"
printf '%s' "$PREPARE_SOURCE" | grep -qF "jq -Rsc" \
    || fail "Gemini auth JSON is not assembled from stdin"
if printf '%s' "$PREPARE_SOURCE" | grep -Eq 'jq .*--arg .*gemini'; then
    fail "Gemini credential is exposed through jq argv"
fi

export HOME="$WORK/home"
export XDG_DATA_HOME="$WORK/data"
export XDG_STATE_HOME="$WORK/state"
mkdir -p "$HOME" "$XDG_DATA_HOME/opencode" "$XDG_STATE_HOME"

# Credential-absent regression: free Zen/local OpenCode stays valid, ambient
# non-Vault content is discarded, and even an empty stale auth.json is removed.
: >"$XDG_DATA_HOME/opencode/auth.json"
OPENCODE_AUTH_CONTENT="ambient-$RANDOM-$$"
export OPENCODE_AUTH_CONTENT
unset TILLANDSIAS_OPENCODE_AUTH_EXPECTED
prepare_opencode_vault_auth || fail "credential-free preparation failed"
[ -z "${OPENCODE_AUTH_CONTENT+x}" ] \
    || fail "credential-free lane retained ambient non-Vault auth content"
[ ! -e "$XDG_DATA_HOME/opencode/auth.json" ] \
    || fail "credential-free lane retained stale auth.json"

# Configured regression: the existing Gemini Vault producer is adapted to the
# exact OpenCode `google` auth record in memory. The runtime key is generated
# here; no credential literal lives in this committed fixture.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/vault-cli.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$*" != "read -field=key secret/gemini/api-key" ]; then
    exit 64
fi
printf '%s' "${TEST_GEMINI_KEY:?}"
STUB
chmod +x "$WORK/bin/vault-cli.sh"
export PATH="$WORK/bin:$PATH"
export TEST_GEMINI_KEY="runtime-gemini-$RANDOM-$$-$(date +%s%N)" # gnu-date: ok (uniqueness seed; BSD's literal-N output is still unique)
export TILLANDSIAS_OPENCODE_AUTH_EXPECTED=1
OPENCODE_AUTH_CONTENT="ambient-must-not-win-$RANDOM-$$"
export OPENCODE_AUTH_CONTENT
prepare_opencode_vault_auth || fail "Vault-backed preparation failed"
printf '%s' "$OPENCODE_AUTH_CONTENT" \
    | "$JQ" -e \
        'keys == ["google"] and .google == {type:"api", key:env.TEST_GEMINI_KEY}' \
        >/dev/null \
    || fail "Vault Gemini key was not adapted to the OpenCode google record"
[ ! -e "$XDG_DATA_HOME/opencode/auth.json" ] \
    || fail "Vault-backed preparation created auth.json"

# NEGATIVE CONTROL for the contract probe itself (1787-i2ir): a binary that
# IGNORES OPENCODE_AUTH_CONTENT must be refused, and one that honours it must
# pass, so a probe that stopped asking cannot go green. The ignoring stub
# answers exactly what opencode 2.0.25 (Homebrew) answered on lenovinha
# 2026-10-18; the honouring one answers what opencode-ai 1.19.3 (npm) did.
mkdir -p "$WORK/stub"
cat >"$WORK/stub/opencode-ignores" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "auth list" ] || exit 64
echo "No authenticated integrations"
STUB
cat >"$WORK/stub/opencode-honours" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "auth list" ] || exit 64
name="$(printf '%s' "${OPENCODE_AUTH_CONTENT:-}" | jq -r 'keys[0] // empty' 2>/dev/null)"
[ -n "$name" ] || { echo "No authenticated integrations"; exit 0; }
printf '%s\n' "●  $name api" "└  1 credentials"
STUB
chmod +x "$WORK/stub/opencode-ignores" "$WORK/stub/opencode-honours"
if opencode_auth_contract_ok "$WORK/stub/opencode-ignores"; then
    fail "the contract probe accepted an opencode that ignores OPENCODE_AUTH_CONTENT"
fi
opencode_auth_contract_ok "$WORK/stub/opencode-honours" \
    || fail "the contract probe refused an opencode that honours OPENCODE_AUTH_CONTENT"

# The installed-binary arm judges the opencode a FORGE runs, never whatever is
# first on this host's PATH (1787-i2ir). Forges install opencode-ai from npm
# (_require_harness opencode opencode-ai), so a PATH binary from another
# channel says nothing about them. Measured on lenovinha 2026-10-18: Homebrew's
# opencode 2.0.25 ignores OPENCODE_AUTH_CONTENT and reddened this arm, while a
# fresh forge installed npm opencode-ai 1.19.3, which honours it.
# TILLANDSIAS_FORGE_OPENCODE_BIN names one explicitly (a forge, a scratch npm
# prefix, or a stub). Otherwise a PATH opencode counts only when it resolves
# into an npm opencode-ai package. Any other one is skipped by name.
REAL_OPENCODE="${TILLANDSIAS_FORGE_OPENCODE_BIN:-}"
if [ -z "$REAL_OPENCODE" ]; then
    _path_opencode="$(command -v opencode 2>/dev/null || true)"
    _real_path="$(readlink -f "$_path_opencode" 2>/dev/null || printf '%s' "$_path_opencode")"
    case "$_real_path" in
        */node_modules/opencode-ai/*) REAL_OPENCODE="$_path_opencode" ;;
        "") ;;
        *) echo "SKIP: PATH opencode $_path_opencode resolves to $_real_path, not an npm opencode-ai package; forges install opencode-ai from npm, so this binary is not what they run (set TILLANDSIAS_FORGE_OPENCODE_BIN to judge one)" ;;
    esac
fi
if [ -n "$REAL_OPENCODE" ] && [ -x "$REAL_OPENCODE" ]; then
    opencode_auth_contract_ok "$REAL_OPENCODE" \
        || fail "installed OpenCode rejected the isolated sentinel contract"
    opencode_actual_auth_ok "$REAL_OPENCODE" \
        || fail "installed OpenCode did not report the injected Vault credential"
    if grep -R -a -F -f <(printf '%s' "$TEST_GEMINI_KEY") \
        "$XDG_DATA_HOME" "$XDG_STATE_HOME" >/dev/null 2>&1; then
        fail "installed OpenCode persisted the runtime credential in test state"
    fi
    REAL_VERSION="$("$REAL_OPENCODE" --version 2>/dev/null || echo unknown)"
    echo "installed OpenCode evidence: version=$REAL_VERSION provider=google count=1 auth.json=absent"
elif [ -n "${TILLANDSIAS_FORGE_OPENCODE_BIN:-}" ]; then
    fail "TILLANDSIAS_FORGE_OPENCODE_BIN=$TILLANDSIAS_FORGE_OPENCODE_BIN is not an executable"
else
    echo "SKIP: no forge OpenCode (npm opencode-ai) on this host; hermetic contract coverage continues"
fi

# Rollback regression. Both harnesses are generated in isolated test state.

unset OPENCODE_AUTH_CONTENT TEST_GEMINI_KEY
echo "PASS: OpenCode Vault auth content and no-file assertion"
