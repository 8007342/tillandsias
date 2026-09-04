#!/usr/bin/env bash
# @trace order:995-srbf, spec:github-credential-health
#
# The verdict script is what distinguishes "this credential is bad" from "I
# could not ask" — the distinction the whole fix rests on. It lives as a shell
# literal inside remote_projects.rs, so it is EXTRACTED from that source rather
# than copied here: a copy would keep passing after the real script changed.
#
# `gh` and `vault-cli` are stubbed on PATH, so this runs anywhere, in seconds,
# with no podman, no vault and no network.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/crates/tillandsias-headless/src/remote_projects.rs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Extract the script literal between the r#" and "# that follow the constant.
awk '/^const CREDENTIAL_VERDICT_SCRIPT/{grab=1;next} grab&&/^"#;/{exit} grab{print}' \
    "$src" > "$work/verdict.sh"
[ -s "$work/verdict.sh" ] || { echo "fail: could not extract the verdict script from $src" >&2; exit 1; }

mkdir -p "$work/bin"
PATH="$work/bin:$PATH"

stub_vault() { # $1: exit code, $2: token to print
    printf '#!/bin/sh\nprintf "%%s" "%s"\nexit %s\n' "$2" "$1" > "$work/bin/vault-cli"
    chmod +x "$work/bin/vault-cli"
}
stub_gh() { # $1: exit code, $2: stdout, $3: stderr
    { printf '#!/bin/sh\n'
      printf 'printf "%%s\\n" "%s"\n' "$2"
      printf 'printf "%%s\\n" "%s" >&2\n' "$3"
      printf 'exit %s\n' "$1"
    } > "$work/bin/gh"
    chmod +x "$work/bin/gh"
}

fails=0
expect() { # $1: case name, $2: expected verdict token
    local out
    out="$(sh "$work/verdict.sh" 2>/dev/null || true)"
    local got
    got="$(printf '%s\n' "$out" | grep -o 'verdict=[a-z]*' | head -1)"
    if [ "$got" = "verdict=$2" ]; then
        echo "ok: $1 -> $got"
    else
        echo "FAIL: $1 expected verdict=$2, got '${got:-<none>}' (raw: $out)" >&2
        fails=$((fails + 1))
    fi
}

# A working credential.
stub_vault 0 "ghp_live"; stub_gh 0 "octocat" ""
expect "a token the API accepts is valid" valid

# THE CASE THE WHOLE PACKET IS ABOUT: a token that is present and refused.
stub_vault 0 "ghp_expired"; stub_gh 1 "" "gh: HTTP 401: Bad credentials (https://api.github.com/user)"
expect "a present-but-refused token is invalid" invalid

# 403 is also a refusal of this credential.
stub_vault 0 "ghp_blocked"; stub_gh 1 "" "gh: HTTP 403: Forbidden"
expect "a 403 is invalid" invalid

# NO TOKEN AT ALL is invalid, not unreachable: Vault answered.
stub_vault 0 ""; stub_gh 0 "octocat" ""
expect "an empty token is invalid" invalid

# THE FALSE-DEMOTION GUARD. A network failure must never read as invalid.
stub_vault 0 "ghp_live"; stub_gh 1 "" "dial tcp: lookup api.github.com: no such host"
expect "a network failure is unreachable" unreachable

# Vault itself down: unreachable, and specifically NOT "no token in vault".
stub_vault 1 ""; stub_gh 0 "octocat" ""
expect "a vault read failure is unreachable" unreachable

# gh succeeds but says nothing — an answer we did not get.
stub_vault 0 "ghp_live"; stub_gh 0 "" ""
expect "an empty login is unreachable" unreachable

if [ "$fails" -ne 0 ]; then
    echo "FAILED: $fails case(s)" >&2
    exit 1
fi
echo "ok:credential-verdict-script:7/7"
