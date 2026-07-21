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

# Drain stdin (git sends protocol/host/path). We do not branch on it: this
# helper is wired per-invocation by the relay for one specific remote, so
# answering unconditionally is correct and avoids parsing a format we would
# then have to keep in sync.
while IFS= read -r _line; do
    [ -n "$_line" ] || break
done

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
