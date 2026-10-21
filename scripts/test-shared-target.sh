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
# ARM 6 NESTED a child process (build.sh re-exec in the toolbox, fixtures) entering
#               the same checkout while the parent holds the lock is admitted;
#               a different checkout is still refused. PRE-FIX: child REFUSED.
# ARM 5 PATH    the canonical dir of a worktree and of its main checkout are
#               the same absolute path (what sccache keys on).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/scripts/shared-target.sh" ] || { echo "FAIL: scripts/shared-target.sh absent"; exit 1; }
# shellcheck source=shared-target.sh
. "$ROOT/scripts/shared-target.sh"
mkdir -p "$ROOT/target"; W="$(mktemp -d "$ROOT/target/test-shared-target.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
A="$W/a"; B="$W/b"
mkdir -p "$A/src" "$A/target"
git -C "$A" init -q -b main
git -C "$A" config user.email t@t; git -C "$A" config user.name t
printf '[package]\nname="probe"\nversion="0.0.0"\nedition="2021"\n[workspace]\n' > "$A/Cargo.toml"
printf 'fn main(){println!("code-from-A {}", env!("CARGO_MANIFEST_DIR"));}\n' > "$A/src/main.rs"
printf '/target/\n' > "$A/.gitignore"
git -C "$A" add -A; git -C "$A" commit -qm a
git -C "$A" worktree add -q -b wb "$B"
sed 's/code-from-A/code-from-B/' "$B/src/main.rs" > "$B/src/main.rs.new" && mv "$B/src/main.rs.new" "$B/src/main.rs"
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
else case "$out" in *REFUSED*locked*"last owner"*) ok "arm1 lock refuses and names the owner";; *) bad "arm1 refusal unnamed: $out";; esac; fi
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
touch "$W/marker"; sleep 1; touch -d "1 hour ago" "$B/src/main.rs"
( shared_target_enter "$B" >/dev/null 2>&1 )
[ ! "$B/src/main.rs" -nt "$W/marker" ] && ok "arm4 same checkout re-entered without touching" || bad "arm4 touched on an unchanged owner"

# ARM 6 nested enter: parent holds the lock, child (separate process, fresh open) enters.
# Script files, not bash -c strings: a trailing bash -c is exec-optimised and would drop the parent's fd.
cat > "$W/child.sh" <<EOF
. '$ROOT/scripts/shared-target.sh'
shared_target_enter "\$1"
EOF
cat > "$W/parent.sh" <<EOF
. '$ROOT/scripts/shared-target.sh'
shared_target_enter '$A' >/dev/null 2>&1 || exit 7
bash '$W/child.sh' "\$1"; rc=\$?
: done; exit \$rc
EOF
nested="$(TILLANDSIAS_SHARED_TARGET_WAIT=2 bash "$W/parent.sh" "$A" 2>&1)"; nrc=$?
[ $nrc -eq 0 ] && ok "arm6 nested enter inherited the held lock" || bad "arm6 nested enter refused/deadlocked (rc=$nrc): $nested"
other="$(TILLANDSIAS_SHARED_TARGET_WAIT=1 bash "$W/parent.sh" "$B" 2>&1)"; orc=$?
[ $orc -ne 0 ] && ok "arm6 nested enter from a different checkout still refused" || bad "arm6 different checkout admitted under a held lock"

# ARM 7 orphan-held lock: the builder died, but a stray child (a pty shell a test left
# behind) inherited fd 9 and still holds the flock. Profile run 2 waited 1800 s on such a
# lock whose recorded holder pid was long dead. A dead holder must not block entry.
# PRE-FIX: FAILS (enter waits out TILLANDSIAS_SHARED_TARGET_WAIT, then REFUSED).
cat > "$W/orphan.sh" <<EOF
exec 9>>"$CANON/.shared-target.lock"
flock -n 9 || exit 9
printf 'pid 999999 bash dead-builder\n' > "$CANON/.shared-target-holder"
echo \$\$ > "$W/orphan.pid"
sleep 30
EOF
( bash "$W/orphan.sh" ) >/dev/null 2>&1 &
sleep 1
o7="$(TILLANDSIAS_SHARED_TARGET_WAIT=3 bash -c ". '$ROOT/scripts/shared-target.sh'; shared_target_enter '$A'" 2>&1)"; rc7=$?
[ $rc7 -eq 0 ] && ok "arm7 a lock held only by orphans of a dead builder does not block entry" \
  || bad "arm7 dead-holder lock blocked entry (rc=$rc7): $o7"
[ -f "$W/orphan.pid" ] && kill "$(cat "$W/orphan.pid")" 2>/dev/null
exit $fail
