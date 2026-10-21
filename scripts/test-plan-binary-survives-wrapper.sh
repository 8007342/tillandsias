#!/usr/bin/env bash
# @trace order:1804-sccl
# Land run 185 (#590): the gate died at "no fresh tillandsias-plan resolves" with
# RUSTC_WRAPPER=scripts/sccache-wrapper.sh in the environment. ensure_fresh_plan_binary
# rebuilds a stale plan binary with its output sent to /dev/null, so ANY failure of the
# ambient compiler wrapper surfaced as "no fresh binary". A cache must never red a gate.
# ARM 1 (control)  stub cargo that fails whenever RUSTC_WRAPPER is set proves the
#                  stub models the failure (fails with the wrapper, builds without)
# ARM 2            stale binary + failing wrapper: ensure_fresh_plan_binary still
#                  returns a fresh binary (rebuild retried without the wrapper)
# ARM 3            no wrapper set: unchanged, rc 0 on the first build
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export R=release; W="$(mktemp -d /tmp/pbsw.XXXXXX)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts" "$W/bin" "$W/crates/tillandsias-plan/src" "$W/target/release"
cp "$ROOT/scripts/plan-binary-probe.sh" "$W/scripts/"
: > "$W/Cargo.lock"; echo x > "$W/crates/tillandsias-plan/src/lib.rs"
cat > "$W/bin/cargo" <<'STUB'
#!/bin/sh
# models a build that fails only under a compiler wrapper
if [ -n "${RUSTC_WRAPPER:-}" ]; then echo "sccache: encountered fatal error" >&2; exit 101; fi
printf '#!/bin/sh\nexit 0\n' > target/$R/tillandsias-plan; chmod +x target/$R/tillandsias-plan
STUB
chmod +x "$W/bin/cargo"
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
stale() { printf '#!/bin/sh\nexit 0\n' > "$W/target/$R/tillandsias-plan"; chmod +x "$W/target/$R/tillandsias-plan"
          touch -d '2020-01-01' "$W/target/$R/tillandsias-plan"; touch "$W/crates/tillandsias-plan/src/lib.rs"; }
run() { ( cd "$W" && env -u CARGO_TARGET_DIR -u TILLANDSIAS_PLAN_BIN PATH="$W/bin:$PATH" "$@" bash -c '. scripts/plan-binary-probe.sh; ensure_fresh_plan_binary' ); }
( cd "$W" && PATH="$W/bin:$PATH" RUSTC_WRAPPER=/bin/true cargo build >/dev/null 2>&1 ) \
  && bad "arm1 stub cargo did not fail under a wrapper" || ok "arm1 stub cargo fails under a wrapper"
stale; out="$(run RUSTC_WRAPPER=/bin/true 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then ok "arm2 failing wrapper does not red the plan binary refresh"; else bad "arm2 rc=$rc out=[$out]: a wrapper failure became 'no fresh tillandsias-plan'"; fi
stale; out="$(run A=1 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then ok "arm3 no wrapper: unchanged"; else bad "arm3 rc=$rc"; fi
exit $fail
