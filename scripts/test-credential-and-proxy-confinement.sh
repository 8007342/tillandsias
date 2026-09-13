#!/usr/bin/env bash
# ORDER 1118-bscs. A push token goes to GitHub over https, or nowhere; and the
# permissive proxy port is not reachable from the enclave.
#
# TWO CONFINEMENTS, one row, because they are the same failure: a capability
# left open on the reasoning that nothing currently uses it.
#
#   * images/git/git-credential-tillandsias.sh drained stdin and deliberately
#     did NOT branch on it — "wired per-invocation by the relay for one specific
#     remote, so answering unconditionally is correct". That is an assumption
#     about the CALLER, and a credential helper must not rest on one. Any caller
#     received a live GitHub token for an arbitrary host.
#   * images/proxy/squid.conf declared `http_port 3129` with no bind address and
#     `http_access allow build_port` with no source ACL and no allowlist, so any
#     container sharing the enclave network could dial it and egress anywhere,
#     bypassing the 3128 allowlist entirely. The file's header correctly says
#     nothing ROUTES there; routing and reachability are different questions.
#
# REGIME. The credential arms EXECUTE the real helper with a stubbed vault-cli
# and a stubbed PATH, so no real token is ever involved and no arm depends on
# this host holding credentials. The proxy arms read the shipped config, because
# a bind address is a static property of the artifact and starting squid to
# observe it would test the runtime rather than what we ship.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

HELPER="images/git/git-credential-tillandsias.sh"
CONF="images/proxy/squid.conf"
for f in "$HELPER" "$CONF"; do
    [ -f "$f" ] || { bad "$f is missing"; echo "credential-and-proxy-confinement: $pass passed, $fail failed"; exit 1; }
done

W="$(mktemp -d "${TMPDIR:-/tmp}/cred-confine.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
mkdir -p "$W/bin"
# A vault-cli that hands back a marker, never a real secret. If an arm ever
# prints this marker for a host it should have refused, the test has caught an
# exfiltration path rather than a formatting difference.
cat > "$W/bin/vault-cli" <<'STUB'
#!/bin/sh
echo "TOKEN-MARKER-1118-bscs"
STUB
chmod +x "$W/bin/vault-cli"

# ask <host> [protocol] -> helper stdout
ask() {
    _h="$1"; _p="${2:-https}"
    printf 'protocol=%s\nhost=%s\npath=x.git\n\n' "$_p" "$_h" \
        | PATH="$W/bin:$PATH" bash "$HELPER" get 2>/dev/null
}

# ── 1. THE LEGITIMATE CASE STILL WORKS. Without this the others pass on a
#      helper that refuses everything, which would break every push.
out="$(ask github.com)"
if printf '%s' "$out" | grep -q 'TOKEN-MARKER-1118-bscs'; then
    ok "github.com over https still receives the token"
else
    bad "github.com was REFUSED — the confinement broke the only path that must work"
fi

# ── 2. THE DEFECT: an arbitrary host must get nothing. ─────────────────────
out="$(ask evil.example.com)"
if printf '%s' "$out" | grep -q 'TOKEN-MARKER'; then
    bad "an arbitrary host received the GitHub token — this is the exfiltration path (1118-bscs)"
else
    ok "an arbitrary host receives no token"
fi

# ── 3. SUFFIX ATTACKS, the reason the comparison is whole-string. A suffix or
#      substring test accepts both of these, and both are trivially registrable.
for h in evil-github.com github.com.attacker.net notgithub.com; do
    out="$(ask "$h")"
    if printf '%s' "$out" | grep -q 'TOKEN-MARKER'; then
        bad "'$h' received the token — the host test is matching by suffix or substring, not whole-string"
    else
        ok "'$h' receives no token (whole-string match holds)"
    fi
done

# ── 4. NO HOST AT ALL must fail closed, not fall through to a default. ─────
out="$(printf 'protocol=https\npath=x.git\n\n' | PATH="$W/bin:$PATH" bash "$HELPER" get 2>/dev/null)"
if printf '%s' "$out" | grep -q 'TOKEN-MARKER'; then
    bad "a request with NO host= received the token — the helper defaults to allow"
else
    ok "a request with no host= is refused (fails closed)"
fi

# ── 5. CLEARTEXT: a token handed over http is disclosed in transit. ────────
out="$(ask github.com http)"
if printf '%s' "$out" | grep -q 'TOKEN-MARKER'; then
    bad "the token was supplied over http — it would be disclosed in transit"
else
    ok "http is refused; the token is https-only"
fi

# ── 6. THE PERMISSIVE PROXY PORT IS LOOPBACK-BOUND. ───────────────────────
_ports="$(grep -vE '^[[:space:]]*#' "$CONF" | grep -E '^http_port')"
if printf '%s' "$_ports" | grep -qE '^http_port[[:space:]]+127\.0\.0\.1:3129'; then
    ok "the permissive port 3129 is bound to loopback, unreachable from the enclave network"
else
    bad "3129 is not loopback-bound: $(printf '%s' "$_ports" | grep 3129 || echo '(no 3129 listener found)') — any enclave container can dial it and egress past the allowlist"
fi

# ── 7. NEGATIVE CONTROL: the STRICT port must NOT be loopback-bound. The
#      enclave reaches 3128 across the container network by design; "fixing"
#      this file by narrowing both listeners would silence arm 6 and break
#      every runtime container, which is a worse outcome than the defect.
if printf '%s' "$_ports" | grep -qE '^http_port[[:space:]]+3128'; then
    ok "CONTROL: the strict port 3128 still binds for the enclave (confinement did not break the allowlisted path)"
else
    bad "CONTROL: 3128 is no longer bound for the enclave — runtime containers cannot reach the allowlisted proxy at all"
fi

echo "credential-and-proxy-confinement: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
