#!/usr/bin/env bash
# @trace order:1312-i6da, spec:git-mirror-service
#
# check-bare-metal-host-initialized.sh — is THIS bare-metal host's own enclave
# and per-project git mirror up? NON-MUTATING: it starts nothing, stops
# nothing, and writes nothing. It only reports, and names the command that
# would fix what it found.
#
# WHY A CHECKER AND NOT JUST THE SKILL. The skill's two commands are
# ensure-shaped, so running them is the remedy for almost everything. That is
# exactly why a separate READ is needed: without it "did it work?" is answered
# by running the remedy again, which cannot distinguish a healthy host from one
# that is repaired on every check and broken in between.
#
# VERDICTS, one line on stdout:
#   ok:bare-metal-host:<host>:enclave=up mirror=up router=up inference=up github=<seeded|not-seeded>
#   todo:initialize-bare-metal-host:<component>:<command that fixes it>   exit 1
#   skip:bare-metal-host:<reason>                                          exit 0
#
# github= is reported ONLY on the ok: path, where the mirror is up and can be
# asked. A host whose mirror is down gets a todo: about the mirror and no
# github claim at all — saying "not-seeded" when the question could not be put
# is the confident-wrong verdict shape this tree keeps paying for (894-scxy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

PROJECT="${TILLANDSIAS_PROJECT:-tillandsias}"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
MIRROR="tillandsias-git-${PROJECT}"
ENSURE_CMD="tillandsias --ensure-enclave"
# ORDER 1356-u6xe. THE LANE COMMAND NAMES A PATH, NOT A PROJECT NAME. This
# line used to interpolate the bare ${PROJECT}, and a reader who ran the
# todo: verbatim got `Error: Project not found: tillandsias` and rc=1 — the
# binary resolves a CHECKOUT PATH here. The skill's own §6.1 already records
# the distinction ("a bare name had been passed where a path was wanted")
# while this line, which is what a worker actually copies, did not: an
# affordance a reader cannot paste is worse than no affordance, because it
# spends the cycle it was written to save. Both values are derived from this
# checkout rather than hardcoded to $HOME/claudia, so the printed command is
# the one THIS host should run.
LANE_CMD="TILLANDSIAS_HOST_PROJECT_ROOT=$(dirname "$ROOT") tillandsias --bash ${ROOT}"

command -v podman >/dev/null 2>&1 || { echo "skip:bare-metal-host:no-podman"; exit 0; }

# CAPTURE THEN MATCH (795-imz3). `podman ps | grep -q` under the pipefail above
# reports failure ON A MATCH, which would invert every probe below.
_ps="$(podman ps --format '{{.Names}}' 2>/dev/null)"

_running() {
    case $'\n'"$_ps"$'\n' in
        *$'\n'"$1"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

# ORDER MATTERS AND IS NOT COSMETIC: vault before proxy before mirror. The
# mirror's Vault Agent cannot authenticate without vault, so reporting the
# mirror first would send a reader to restart a container whose dependency is
# the actual fault.
_running tillandsias-vault || {
    echo "todo:initialize-bare-metal-host:vault:${ENSURE_CMD}"; exit 1; }
_running tillandsias-proxy || {
    echo "todo:initialize-bare-metal-host:proxy:${ENSURE_CMD}"; exit 1; }
_running "$MIRROR" || {
    echo "todo:initialize-bare-metal-host:mirror:${LANE_CMD}"; exit 1; }
_running tillandsias-router || {
    echo "todo:initialize-bare-metal-host:router:${LANE_CMD}"; exit 1; }
_running tillandsias-inference || {
    echo "todo:initialize-bare-metal-host:inference:${LANE_CMD}"; exit 1; }

# THE GITHUB FIELD IS A READ, NEVER A SEED. This asks the mirror's OWN Vault
# Agent token whether secret/github/token is readable and non-empty. It never
# prints the value, never writes, and never prompts. Seeding is the operator's
# act (`tillandsias --github-login --with-token`, stdin) and no checker or
# skill performs it on their behalf: every host that seeds ends holding a copy
# of one credential, where revoking one revokes all.
_gh="not-seeded"
_len="$(podman exec "$MIRROR" sh -c '
    T="$(cat /tmp/tillandsias-vault-token 2>/dev/null)"
    [ -n "$T" ] || exit 0
    curl -s --cacert /etc/tillandsias/ca.crt -H "X-Vault-Token: $T" \
        https://vault:8200/v1/secret/data/github/token 2>/dev/null \
      | jq -r "(.data.data.token // \"\") | length" 2>/dev/null
' 2>/dev/null)"
case "$_len" in
    ''|0|null) _gh="not-seeded" ;;
    *[!0-9]*)  _gh="not-seeded" ;;
    *)         [ "$_len" -gt 0 ] && _gh="seeded" ;;
esac

# ORDER 1313-prin. THE LANE FIELD, because a green that is TRUE AND ADJACENT
# gets read as coverage. This verdict said nothing about the ssh push lane, so a
# host could read ok:bare-metal-host:... and believe the lane was proven. It is
# not: the lane is proven ONLY by the three acceptance legs (skill section 6).
# This field reports what can be READ, so the checker stays non-mutating — it
# mints no certificate and starts nothing.
_lane="off"
_lane_flag="$(podman exec "$MIRROR" sh -c 'echo "${TILLANDSIAS_MIRROR_SSHD:-0}"' 2>/dev/null | tr -d '\r\n ')"
if [ "$_lane_flag" = "1" ]; then
    _sshd_up=0
    # NOT pgrep: sshd RETITLES itself to "sshd: /usr/sbin/sshd ... [listener]",
    # so 'pgrep -x sshd' misses it and reports a WIRED lane as unwired —
    # measured here, and it would have been wrong on every host.
    # And NOT 'pgrep -f sshd' either: that pattern matches this very probe's own
    # command line, the self-matching-instrument shape of 1287-myx8. The pid
    # file is written by sshd itself and needs no pattern at all.
    podman exec "$MIRROR" sh -c 'p=$(cat /tmp/tillandsias-sshd/sshd.pid 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null' 2>/dev/null && _sshd_up=1
    if [ "$_sshd_up" -ne 1 ]; then
        _lane="unwired:sshd-not-running"
    else
        _princ="$(podman exec "$MIRROR" sh -c 'grep -h "^til:host-push:" /tmp/tillandsias-sshd/authorized_principals 2>/dev/null | head -1' 2>/dev/null | tr -d '\r\n ')"
        if [ -n "$_princ" ]; then
            _lane="wired:$_princ"
        else
            _lane="unwired:no-host-principal"
        fi
    fi
fi

echo "ok:bare-metal-host:${HOSTNAME_SHORT}:enclave=up mirror=up router=up inference=up github=${_gh} lane=${_lane}"
exit 0
