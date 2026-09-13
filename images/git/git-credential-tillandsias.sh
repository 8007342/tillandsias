#!/bin/sh
# @trace spec:tillandsias-vault, spec:git-mirror-service, spec:secrets-management
#
# Git credential helper for the mirror's upstream push (order 424).
#
# WHY THIS EXISTS. relay-refs.sh used to build
#     PUSH_URL="https://oauth2:${TOKEN}@github.com/..."
# and pass it as an ARGV element to `git push` / `git fetch`. That puts the
# GitHub token in /proc/<pid>/cmdline, readable by anything sharing the
# namespace, and it contradicts an invariant this repository states explicitly
# elsewhere:
#
#   vault-cli.sh:        "Read the secret value from stdin so it never appears
#                         in process argv or an environment variable."
#   provider-device-auth: "Flows on stdin; never argv or env."
#
# The relay was the hottest path in the system and the one place that broke the
# rule. Git's credential protocol exists precisely for this: git asks on stdin,
# the helper answers on stdout, and the URL stays clean.
#
# Protocol (gitcredentials(7)): invoked as `<helper> get`, reads key=value
# lines on stdin, writes `username=` / `password=` on stdout. Any other
# operation (store/erase) is a no-op — the credential is owned by Vault, not
# cached by git.

set -eu

case "${1:-}" in
    get) ;;
    store|erase) exit 0 ;;   # Vault owns the credential; nothing to cache.
    *) echo "usage: $0 get|store|erase" >&2; exit 1 ;;
esac

# ORDER 1118-bscs — THE HOST IS VALIDATED BEFORE ANY TOKEN IS RETURNED.
#
# This block used to drain stdin and deliberately not branch on it: "this helper
# is wired per-invocation by the relay for one specific remote, so answering
# unconditionally is correct". That reasoning is about how the helper is CALLED
# TODAY, and a credential helper must not rest on an assumption about its
# caller. Anything that reaches this script — a misconfigured remote, a URL an
# attacker influenced, a second caller added later by someone who did not read
# that comment — received a live GitHub token for an arbitrary host.
#
# The stated cost of checking was "parsing a format we would then have to keep
# in sync". The format is git's documented credential protocol: `key=value`
# lines terminated by a blank line. It has been stable for the life of the
# helper, and `host=` is the one field needed here.
#
# FAIL CLOSED. An absent host, an unparseable host, or any host outside the
# allowlist REFUSES. The failure mode of guessing here is handing a push token
# to whoever asked, so silence is not an option and neither is a default-allow.
_cred_host=""
_cred_protocol=""
while IFS= read -r _line; do
    [ -n "$_line" ] || break
    case "$_line" in
        host=*)     _cred_host="${_line#host=}" ;;
        protocol=*) _cred_protocol="${_line#protocol=}" ;;
    esac
done

# HTTPS ONLY. A token handed over cleartext http is disclosed in transit, and
# git will happily ask for one if a remote says so.
if [ -n "$_cred_protocol" ] && [ "$_cred_protocol" != "https" ]; then
    echo "git-credential-tillandsias: refusing to supply a token over '${_cred_protocol}' (https only, 1118-bscs)" >&2
    exit 1
fi

# The allowlist is GitHub's credential-bearing hosts and nothing else. Compared
# WHOLE, never by suffix: a suffix test would accept `evil-github.com` and
# `github.com.attacker.net`, which is the exact shape this check exists to
# refuse. Port suffixes are stripped first because git may send `host=h:443`.
case "$_cred_host" in
    *:*) _cred_host="${_cred_host%:*}" ;;
esac
case "$_cred_host" in
    github.com|api.github.com) ;;
    "")
        echo "git-credential-tillandsias: no host= in the credential request; refusing (1118-bscs)" >&2
        exit 1
        ;;
    *)
        echo "git-credential-tillandsias: refusing to supply the GitHub token to host '${_cred_host}' (1118-bscs)" >&2
        exit 1
        ;;
esac

command -v vault-cli >/dev/null 2>&1 || {
    echo "git-credential-tillandsias: vault-cli unavailable" >&2
    exit 1
}

TOKEN="$(vault-cli read -field=token secret/github/token 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
    echo "git-credential-tillandsias: no upstream token available from Vault" >&2
    exit 1
fi

# oauth2 as the username is GitHub's documented form for token-as-password.
printf 'username=oauth2\n'
printf 'password=%s\n' "$TOKEN"
