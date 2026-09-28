#!/usr/bin/env bash
# Fixture for 1437-5czv: exactly one crate-wide ENV_LOCK/ENV_LOCK2 mutex
# definition may exist under crates/tillandsias-headless/src, and it must
# live in test_support.rs. Two independent mutexes do not serialize
# anything against each other, which is why `local_projects`,
# `remote_projects`, `tray::mod` (two: ENV_LOCK/ENV_LOCK2) and
# `vault_bootstrap` each kept their own for years while
# `resource_lock::tests::is_held_reflects_lock_lifecycle` — which took none
# of them — failed only in a full parallel run (1242-4x53).
#
# Arm 1 (structural): count static ENV_LOCK/ENV_LOCK2 DEFINITIONS; must be
# exactly one, in test_support.rs.
# Arm 2 (stress): the exact test/feature/thread shape that failed once on
# macuahuitl's full parallel run passes 10/10 rounds.
#
# Grammar: prints ok:headless-env-lock:<count> and exits 0 only when BOTH
# arms pass; violation:headless-env-lock:<count> and exits 1 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

sites="$(grep -rnE 'static[[:space:]]+ENV_LOCK2?[[:space:]]*:' crates/tillandsias-headless/src --include='*.rs' 2>/dev/null || true)"
count="$(printf '%s\n' "$sites" | grep -c . || true)"
[ -z "$sites" ] && count=0

arm1_ok=0
if [ "$count" -eq 1 ] && grep -q '^crates/tillandsias-headless/src/test_support\.rs:' <<<"$sites"; then
  arm1_ok=1
  printf 'arm 1 ok: exactly one ENV_LOCK definition, in test_support.rs\n' >&2
else
  printf 'arm 1 FAILED: %s ENV_LOCK/ENV_LOCK2 definition(s), not the required single test_support.rs one:\n' "$count" >&2
  printf '%s\n' "$sites" >&2
fi

# Opt out of the stress round with TILLANDSIAS_SKIP_STRESS=1 for a quick
# structural-only run.
arm2_ok=0
if [ "${TILLANDSIAS_SKIP_STRESS:-0}" = "1" ]; then
  printf 'skip:headless-env-lock-stress:TILLANDSIAS_SKIP_STRESS=1\n' >&2
  arm2_ok=1
else
  rounds=10
  ok_rounds=0
  for i in $(seq 1 "$rounds"); do
    log="$(mktemp)"
    if cargo test --quiet -p tillandsias-headless --features tray,listen-vsock \
      mcp_connection_serves_browser_family_over_the_socket -- --test-threads=8 \
      >"$log" 2>&1; then
      ok_rounds=$((ok_rounds + 1))
    else
      printf 'round %d FAILED:\n' "$i" >&2
      tail -30 "$log" >&2
    fi
    rm -f "$log"
  done
  if [ "$ok_rounds" -eq "$rounds" ]; then
    arm2_ok=1
    printf 'arm 2 ok: %d/%d stress rounds passed\n' "$ok_rounds" "$rounds" >&2
  else
    printf 'arm 2 FAILED: %d/%d stress rounds passed\n' "$ok_rounds" "$rounds" >&2
  fi
fi

if [ "$arm1_ok" -eq 1 ] && [ "$arm2_ok" -eq 1 ]; then
  printf 'ok:headless-env-lock:%d\n' "$count"
  exit 0
fi
printf 'violation:headless-env-lock:%d\n' "$count"
exit 1
