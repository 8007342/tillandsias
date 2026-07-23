#!/usr/bin/env bash
# Deterministic transport-security fixture for the default-image Vault shim.
# It uses the git-mirror shim as the established shared-semantics oracle while
# exercising only read, write, and write-stdin (not mirror lifecycle verbs).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CLI="$ROOT/images/default/vault-cli.sh"
GIT_CLI="$ROOT/images/git/vault-cli.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$DEFAULT_CLI" "$GIT_CLI"; do
    [[ -r "$path" ]] || fail "fixture input missing: $path"
done

mkdir -p "$WORK/bin" "$WORK/default" "$WORK/git"
printf '%s\n' 'fixture-ca' >"$WORK/ca.crt"
printf '%s\n' 'token-that-must-never-enter-curl-argv' >"$WORK/vault-token"
EXPECTED_HEADER_SHA="$(
    printf '%s\n' 'X-Vault-Token: token-that-must-never-enter-curl-argv' \
        | sha256sum \
        | awk '{print $1}'
)"
export EXPECTED_HEADER_SHA

cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

label=unknown
url=
cacert=
header_arg=
data_binary=
args_log="$CAPTURE_DIR/curl.argv"

while (($#)); do
    case "$1" in
        --cacert)
            cacert="${2:-}"
            printf '%s\n%s\n' "$1" "$cacert" >>"$args_log"
            shift 2
            ;;
        --header)
            header_arg="${2:-}"
            printf '%s\n%s\n' "$1" "$header_arg" >>"$args_log"
            shift 2
            ;;
        --data-binary)
            data_binary="${2:-}"
            printf '%s\n%s\n' "$1" "$data_binary" >>"$args_log"
            shift 2
            ;;
        -*)
            printf '%s\n' "$1" >>"$args_log"
            shift
            ;;
        *)
            url="$1"
            printf '%s\n' "$1" >>"$args_log"
            shift
            ;;
    esac
done

case "$url" in
    */v1/secret/data/shared-read) label=read ;;
    */v1/secret/data/shared-write) label=write ;;
    */v1/secret/data/shared-stdin) label=write-stdin ;;
    */v1/sys/health*) label=health ;;
    *) exit 66 ;;
esac

[[ "$cacert" == "$EXPECTED_CACERT" ]] || exit 67
if [[ "$label" == health ]]; then
    [[ -z "$header_arg" ]] || exit 68
else
    [[ "$header_arg" == @* ]] || exit 69
    header_file="${header_arg#@}"
    [[ -r "$header_file" ]] || exit 70
    [[ "$(stat -c '%a' "$header_file")" == 600 ]] || exit 71
    header_sha="$(sha256sum "$header_file" | awk '{print $1}')"
    [[ "$header_sha" == "$EXPECTED_HEADER_SHA" ]] || exit 72
    printf '%s\n' ok >>"$CAPTURE_DIR/header-checks"
fi

case "$label" in
    read)
        [[ -z "$data_binary" ]] || exit 73
        printf '{"data":{"data":{"token":"shared-read-result"}}}\n'
        ;;
    write|write-stdin)
        [[ "$data_binary" == @- ]] || exit 74
        cat >"$CAPTURE_DIR/$label.body"
        printf '{"data":{"version":1}}\n'
        ;;
    health)
        printf '{"initialized":true,"sealed":false}\n'
        ;;
esac
STUB
chmod 755 "$WORK/bin/curl"

run_shared_operations() {
    local cli="$1"
    local capture_dir="$2"
    mkdir -p "$capture_dir"
    : >"$capture_dir/curl.argv"
    : >"$capture_dir/header-checks"

    PATH="$WORK/bin:$PATH" \
        CAPTURE_DIR="$capture_dir" \
        EXPECTED_CACERT="$WORK/ca.crt" \
        VAULT_ADDR=https://vault.fixture.invalid:8200 \
        VAULT_CACERT="$WORK/ca.crt" \
        VAULT_TOKEN_FILE="$WORK/vault-token" \
        "$cli" read -field=token secret/shared-read \
        >"$capture_dir/read.out" 2>"$capture_dir/read.err"

    PATH="$WORK/bin:$PATH" \
        CAPTURE_DIR="$capture_dir" \
        EXPECTED_CACERT="$WORK/ca.crt" \
        VAULT_ADDR=https://vault.fixture.invalid:8200 \
        VAULT_CACERT="$WORK/ca.crt" \
        VAULT_TOKEN_FILE="$WORK/vault-token" \
        "$cli" write secret/shared-write username=alice password='opaque write value' \
        >"$capture_dir/write.out" 2>"$capture_dir/write.err"

    printf '%s' 'opaque stdin value' \
        | PATH="$WORK/bin:$PATH" \
            CAPTURE_DIR="$capture_dir" \
            EXPECTED_CACERT="$WORK/ca.crt" \
            VAULT_ADDR=https://vault.fixture.invalid:8200 \
            VAULT_CACERT="$WORK/ca.crt" \
            VAULT_TOKEN_FILE="$WORK/vault-token" \
            "$cli" write-stdin secret/shared-stdin credentials_b64 \
            >"$capture_dir/write-stdin.out" 2>"$capture_dir/write-stdin.err"
}

# Network-touching commands must fail closed before curl when no CA is
# readable. The sentinel curl invocation directory therefore stays absent.
set +e
missing_ca_output="$(
    PATH="$WORK/bin:$PATH" \
        CAPTURE_DIR="$WORK/missing-ca-curl-must-not-run" \
        VAULT_CACERT="$WORK/not-present.crt" \
        VAULT_TOKEN_FILE="$WORK/vault-token" \
        "$DEFAULT_CLI" read secret/shared-read 2>&1
)"
missing_ca_status=$?
set -e
[[ "$missing_ca_status" -eq 2 ]] \
    || fail "missing CA returned $missing_ca_status instead of 2"
grep -Fq 'CA bundle not readable' <<<"$missing_ca_output" \
    || fail "missing CA did not report the fail-closed reason"
[[ ! -e "$WORK/missing-ca-curl-must-not-run" ]] \
    || fail "curl ran even though the CA bundle was unreadable"

# Exercise both production CA shapes without setting VAULT_CACERT or
# CURL_CA_BUNDLE: provider-login prefers its /etc mount, while a resident forge
# falls back to the composed /run bundle.
printf '%s\n' 'login-ca' >"$WORK/login-ca.crt"
printf '%s\n' 'runtime-ca' >"$WORK/runtime-ca.crt"
for shape in login resident; do
    capture="$WORK/no-override-$shape"
    mkdir -p "$capture"
    : >"$capture/curl.argv"
    : >"$capture/header-checks"
    if [[ "$shape" == login ]]; then
        login_candidate="$WORK/login-ca.crt"
        expected_candidate="$WORK/login-ca.crt"
    else
        login_candidate="$WORK/missing-login-ca.crt"
        expected_candidate="$WORK/runtime-ca.crt"
    fi
    env -u VAULT_CACERT -u CURL_CA_BUNDLE \
        PATH="$WORK/bin:$PATH" \
        CAPTURE_DIR="$capture" \
        EXPECTED_CACERT="$expected_candidate" \
        TILLANDSIAS_VAULT_LOGIN_CACERT="$login_candidate" \
        TILLANDSIAS_VAULT_RUNTIME_CACERT="$WORK/runtime-ca.crt" \
        VAULT_ADDR=https://vault.fixture.invalid:8200 \
        VAULT_TOKEN_FILE="$WORK/vault-token" \
        "$DEFAULT_CLI" read -field=token secret/shared-read \
        >"$capture/read.out" 2>"$capture/read.err"
done

# The default helper keeps its existing command surface. Vault Agent lifecycle
# verbs remain owned by the git-mirror helper.
for mirror_only_verb in renew-self lookup-self revoke-self; do
    set +e
    mirror_only_output="$("$DEFAULT_CLI" "$mirror_only_verb" 2>&1)"
    mirror_only_status=$?
    set -e
    [[ "$mirror_only_status" -eq 4 ]] \
        || fail "$mirror_only_verb unexpectedly entered the default helper"
    grep -Fq 'unknown subcommand' <<<"$mirror_only_output" \
        || fail "$mirror_only_verb did not use the default unknown-command path"
done

run_shared_operations "$DEFAULT_CLI" "$WORK/default"
run_shared_operations "$GIT_CLI" "$WORK/git"

for artifact in read.out write.out write-stdin.out write.body write-stdin.body; do
    cmp "$WORK/default/$artifact" "$WORK/git/$artifact" \
        || fail "default and git Vault shims disagree for $artifact"
done

[[ "$(<"$WORK/default/read.out")" == shared-read-result ]] \
    || fail "read field semantics changed"
jq -e '.data.username == "alice" and .data.password == "opaque write value"' \
    "$WORK/default/write.body" >/dev/null \
    || fail "write did not send the KV-v2 request body on stdin"
jq -e '.data.credentials_b64 == "opaque stdin value"' \
    "$WORK/default/write-stdin.body" >/dev/null \
    || fail "write-stdin did not send its opaque value in the stdin body"
[[ "$(wc -l <"$WORK/default/header-checks")" -eq 3 ]] \
    || fail "not every authenticated request used the temporary header file"
grep -Fxq -- '--cacert' "$WORK/default/curl.argv" \
    || fail "curl was not passed --cacert"

if grep -R -Fq 'token-that-must-never-enter-curl-argv' \
    "$WORK/default/curl.argv" \
    "$WORK/default/"*.out \
    "$WORK/default/"*.err; then
    fail "Vault token leaked into curl argv or command output"
fi
if grep -Fq 'opaque stdin value' "$WORK/default/curl.argv"; then
    fail "write-stdin body leaked into curl argv"
fi
if grep -Fq 'opaque write value' "$WORK/default/curl.argv"; then
    fail "write body leaked into curl argv"
fi

PATH="$WORK/bin:$PATH" \
    CAPTURE_DIR="$WORK/default" \
    EXPECTED_CACERT="$WORK/ca.crt" \
    VAULT_ADDR=https://vault.fixture.invalid:8200 \
    VAULT_CACERT="$WORK/ca.crt" \
    VAULT_TOKEN_FILE="$WORK/vault-token" \
    "$DEFAULT_CLI" health >"$WORK/default/health.out"

echo "PASS: default Vault CLI CA selection, Vault-token curl-argv secrecy, stdin bodies, and shared semantics"
