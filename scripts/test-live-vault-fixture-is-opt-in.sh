#!/usr/bin/env bash
# @trace order:2207-v7x2
#
# test-live-vault-fixture-is-opt-in.sh — the live vault-shutdown fixture never
# touches a container unless TILLANDSIAS_LIVE_VAULT_FIXTURE=1 is set, and the
# changed-fixture guard skips it by name. A land gate's changed-fixture pass
# ran it on yoga 2026-11-21 and left the host's live vault stopped.
#
#   1 SKIP     without the opt-in: a named skip:, exit 3, and ZERO podman calls
#              (a podman stub first on PATH logs every call; it is never run).
#   2 LIVE     the live vault's container ID and state are byte-identical
#              before and after arm 1 (read-only inspect; skipped when this
#              host has no podman or no vault).
#   3 OPT-IN   with the opt-in the fixture DOES reach podman (the stub is
#              called; it answers "no such container", so nothing real is
#              stopped). Without this, a fixture that never runs scores arm 1.
#   4 GUARD    preflight-fixtures-default-target.sh skips a fixture carrying
#              `# @live-fixture` by name, and the vault fixture carries it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/scripts/test-vault-shutdown-forwards-sigterm.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/live-vault-optin.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/podman.calls"\nexit 1\n' "$W" > "$W/bin/podman"
chmod +x "$W/bin/podman"

live() { # the REAL vault's id and state, read-only; empty when none
    local real
    real="$(PATH="${PATH}" command -v podman 2>/dev/null)" || return 0
    "$real" inspect tillandsias-vault --format '{{.Id}} {{.State.Status}} {{.State.StartedAt}}' 2>/dev/null || true
}
before="$(live)"

# 1
out="$(env -u TILLANDSIAS_LIVE_VAULT_FIXTURE -u TILLANDSIAS_VAULT_FIXTURE_LIB PATH="$W/bin:$PATH" bash "$FX" 2>&1)"; rc=$?
calls=0; [ -f "$W/podman.calls" ] && calls="$(wc -l < "$W/podman.calls" | tr -d ' ')"
case "$rc:$calls:$out" in
    3:0:*skip:vault-shutdown:live-fixture-not-opted-in*) ok "1 SKIP without the opt-in: named skip, rc 3, no podman call" ;;
    *) bad "1 SKIP wanted rc 3, 0 podman calls and skip:vault-shutdown:live-fixture-not-opted-in; got rc=$rc calls=$calls: $(printf '%s' "$out" | head -2 | tr '\n' '|')" ;;
esac

# 2
after="$(live)"
if [ -z "$before" ]; then
    ok "2 LIVE skip: no live tillandsias-vault on this host to compare"
elif [ "$before" = "$after" ]; then
    ok "2 LIVE the live vault's id and state are unchanged ($before)"
else
    bad "2 LIVE the live vault changed: before=[$before] after=[$after]"
fi

# 3
rm -f "$W/podman.calls"
TILLANDSIAS_LIVE_VAULT_FIXTURE=1 TILLANDSIAS_VAULT_CONTAINER=no-such-container-2207-v7x2 \
    PATH="$W/bin:$PATH" bash "$FX" >/dev/null 2>&1
calls=0; [ -f "$W/podman.calls" ] && calls="$(wc -l < "$W/podman.calls" | tr -d ' ')"
[ "$calls" -gt 0 ] && ok "3 OPT-IN with the opt-in the fixture reaches podman ($calls stub calls)" \
    || bad "3 OPT-IN with the opt-in the fixture never reached podman — arm 1 would pass a fixture that never runs"

# 4
if grep -q '^# @live-fixture ' "$FX" \
    && grep -q "grep -q '^# @live-fixture '" "$ROOT/scripts/preflight-fixtures-default-target.sh"; then
    ok "4 GUARD the vault fixture is marked @live-fixture and the changed-fixture guard skips that marker"
else
    bad "4 GUARD the @live-fixture marker or the guard's skip for it is missing"
fi

echo "live-vault-fixture-is-opt-in: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && { echo "ok:live-vault-fixture-is-opt-in:$pass"; exit 0; }
echo "violation:live-vault-fixture-is-opt-in:$fail-failed"; exit 1
