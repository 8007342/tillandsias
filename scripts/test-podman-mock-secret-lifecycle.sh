#!/usr/bin/env bash
# @trace order:813-frih, spec:litmus-framework
#
# test-podman-mock-secret-lifecycle.sh — the podman mock's `secret rm` and
# `secret inspect` act on the secret NAMED, at its real argv position. Before
# 813-frih both read $2 (the sub-subcommand): rm deleted a file named "rm" and
# exited 0 with the secret still on disk, and inspect always answered absent.
# A create -> inspect -> rm -> re-inspect lifecycle, so a no-op removal cannot pass:
#   1 inspect finds a created secret (also with --format X before the name)
#   2 rm removes it: rc 0 AND the file is gone
#   3 re-inspect answers absent
#   4 rm of a missing secret fails like podman; --ignore tolerates it
#   5 rm takes several names; --all removes everything
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK="${TILLANDSIAS_TEST_MOCK:-$ROOT/scripts/test-support/podman-mock.sh}"
W="$(mktemp -d "${TMPDIR:-/tmp}/mock-secret.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export LITMUS_PODMAN_STATE_DIR="$W"
m() { bash "$MOCK" "$@"; }
pass=0; fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
SD="$W/secrets"

printf 'hunter2' | m secret create my-secret - >/dev/null
m secret inspect my-secret >/dev/null 2>&1; r1=$?
m secret inspect --format '{{.Name}}' my-secret >/dev/null 2>&1; r1b=$?
[ "$r1" = 0 ] && [ "$r1b" = 0 ] && ok "1: inspect finds the created secret (plain and with --format)" \
    || bad "1: inspect of an existing secret answered rc=$r1 / --format rc=$r1b"

m secret rm my-secret >/dev/null 2>&1; r2=$?
[ "$r2" = 0 ] && [ ! -e "$SD/my-secret" ] && ok "2: rm removes it (rc 0 and the file is gone)" \
    || bad "2: rm answered rc=$r2 and the file $( [ -e "$SD/my-secret" ] && echo SURVIVES || echo is gone)"

m secret inspect my-secret >/dev/null 2>&1; r3=$?
[ "$r3" != 0 ] && ok "3: re-inspect after rm answers absent" || bad "3: re-inspect still finds the removed secret"

m secret rm my-secret >/dev/null 2>&1; r4=$?
m secret rm --ignore my-secret >/dev/null 2>&1; r4b=$?
[ "$r4" != 0 ] && [ "$r4b" = 0 ] && ok "4: rm of a missing secret fails; --ignore tolerates it" \
    || bad "4: rm missing rc=$r4 (want non-zero), --ignore rc=$r4b (want 0)"

printf a | m secret create s1 - >/dev/null; printf b | m secret create s2 - >/dev/null; printf c | m secret create s3 - >/dev/null
m secret rm s1 s2 >/dev/null 2>&1; r5=$?
left="$(ls "$SD" | tr '\n' ' ')"
m secret rm --all >/dev/null 2>&1; r5b=$?
left2="$(ls "$SD" | wc -l)"
[ "$r5" = 0 ] && [ "$left" = "s3 " ] && [ "$r5b" = 0 ] && [ "$left2" = 0 ] \
    && ok "5: rm takes several names; --all removes the rest" || bad "5: multi rm rc=$r5 left=[$left]; --all rc=$r5b left=$left2"

if [ "$fail" -eq 0 ]; then echo "PASS: podman-mock-secret-lifecycle $pass/$((pass + fail))"; exit 0; fi
echo "FAIL: podman-mock-secret-lifecycle $pass/$((pass + fail))"; exit 1
