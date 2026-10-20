#!/usr/bin/env bash
# @trace order:1807-shtg
#
# test-shared-target.sh — closure for 1807-shtg. Fixture: a two-file cargo
# crate in a scratch repo with a linked worktree (never network, never the
# real workspace).
# ARM 1 LOCK    a second shared_target_enter on a held dir REFUSES, naming the
#               last owner. PRE-FIX: FAILS (no script, no lock).
# ARM 2 NAIVE   one CARGO_TARGET_DIR, B's source older than A's build: B's
#               `cargo run` prints A's code. Documents the defect the guard
#               exists for; it must show A, else the fixture proves nothing.
# ARM 3 GUARD   same sequence through shared_target_enter: B prints B.
#               PRE-FIX: FAILS (identical to arm 2).
# ARM 4 SAME    re-entering from the same checkout and index does NOT touch
#               (no needless rebuilds). NEGATIVE CONTROL for arm 3.
# ARM 5 PATH    the canonical dir of a worktree and of its main checkout are
#               the same absolute path (what sccache keys on).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/scripts/shared-target.sh" ] || { echo "FAIL: scripts/shared-target.sh absent"; exit 1; }
# shellcheck source=shared-target.sh
. "$ROOT/scripts/shared-target.sh"
W="$(mktemp -d "$ROOT/target/test-shared-target.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$W"' EXIT
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
A="$W/a"; B="$W/b"
mkdir -p "$A/src" "$A/target"
git -C "$A" init -q -b main
git -C "$A" config user.email t@t; git -C "$A" config user.name t
printf '[package]\nname="probe"\nversion="0.0.0"\nedition="2021"\n' > "$A/Cargo.toml"
printf 'fn main(){println!("code-from-A {}", env!("CARGO_MANIFEST_DIR"));}\n' > "$A/src/main.rs"
printf '/target/\n' > "$A/.gitignore"
git -C "$A" add -A; git -C "$A" commit -qm a
git -C "$A" worktree add -q -b wb "$B"
sed -i 's/code-from-A/code-from-B/' "$B/src/main.rs"
CANON="$A/target"
run() { (cd "$1" && env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$CANON" cargo run -q --offline 2>&1); }

# ARM 5
[ "$(shared_target_canon "$B")" = "$CANON" ] && [ "$(shared_target_canon "$A")" = "$CANON" ] \
  && ok "arm5 worktree and main share one canonical dir" || bad "arm5 canonical dirs differ: $(shared_target_canon "$B")"

# ARM 1
( TILLANDSIAS_SHARED_TARGET_WAIT=1 shared_target_enter "$A" ) >/dev/null 2>&1
( shared_target_enter "$A" >/dev/null 2>&1; sleep 4 ) &
holder=$!; sleep 1
if out="$(TILLANDSIAS_SHARED_TARGET_WAIT=1 bash -c ". '$ROOT/scripts/shared-target.sh'; shared_target_enter '$B'" 2>&1)"; then
  bad "arm1 second enter was admitted while the dir was held"
else echo "$out" | grep -q "REFUSED.*locked.*last owner" && ok "arm1 lock refuses and names the owner" || bad "arm1 refusal unnamed: $out"; fi
wait "$holder" 2>/dev/null

# ARM 2 naive: A builds, then B's file is made OLDER than A's build
run "$A" >/dev/null; touch -d '1 hour ago' "$B/src/main.rs"
naive="$(run "$B")"
case "$naive" in code-from-A*) ok "arm2 naive shared dir ran A's code in B (the defect reproduces)";;
  *) bad "arm2 naive run did not show A: $naive";; esac

# ARM 3 guard: same sequence, through enter
touch -d '1 hour ago' "$B/src/main.rs"
( shared_target_enter "$B" >/dev/null 2>&1; run "$B" ) > "$W/g.out" 2>&1
guard="$(cat "$W/g.out")"
case "$guard" in code-from-B*"$B"*) ok "arm3 guarded run built B's code and baked B's manifest dir";;
  *) bad "arm3 guarded run did not show B: $guard";; esac

# ARM 4 same owner: no touch
m1="$(stat -c %Y "$B/src/main.rs")"; sleep 1
( shared_target_enter "$B" >/dev/null 2>&1 )
m2="$(stat -c %Y "$B/src/main.rs")"
[ "$m1" = "$m2" ] && ok "arm4 same checkout re-entered without touching" || bad "arm4 touched on an unchanged owner"
exit $fail
