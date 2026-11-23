-- @trace order:1807-shtg, order:1840-2p9v, order:2145-fexh, order:2230-iqyu
-- @env TILLANDSIAS_SHARED_TARGET_WAIT
--
-- test-shared-target.lua — PORTED from test-shared-target.sh (2230-iqyu), same
-- arms, same `ok: armN` / `FAIL: armN` lines (the litmus reads `ok: arm8`).
-- Closure for 1807-shtg. Fixture: a two-file cargo crate in a scratch repo
-- with a linked worktree (never network, never the real workspace). The
-- subject, scripts/shared-target.sh, is a bash library build.sh sources, so
-- each arm is a bash script FILE run by Git's bash (never a bare name: a
-- native Windows child resolves `bash` to WSL's; 2218-x4s3, step 888).
-- ARM 1 LOCK    a second shared_target_enter on a held dir REFUSES, naming the
--               last owner. PRE-FIX: FAILS (no script, no lock).
-- ARM 2 NAIVE   one CARGO_TARGET_DIR, B's source older than A's build: B's
--               `cargo run` prints A's code. Documents the defect the guard
--               exists for; it must show A, else the fixture proves nothing.
-- ARM 3 GUARD   same sequence through shared_target_enter: B prints B.
--               PRE-FIX: FAILS (identical to arm 2).
-- ARM 4 SAME    re-entering from the same checkout and index does NOT touch.
-- ARM 6 NESTED  a child entering the same checkout while the parent holds the
--               lock is admitted; a different checkout is still refused.
-- ARM 7 ORPHAN  a lock held only by orphans of a dead builder does not block.
-- ARM 8 NOFLOCK no flock(1) on PATH (stock macOS) turns the shared dir off, rc 0.
-- ARM 5 PATH    worktree and main checkout share one canonical dir.
-- ARM 9 NOLINK  (2230-iqyu) when the probe crate cannot LINK (yoga's bare host
--               has no cc), arms 2 and 3 are could-not-run:no-linker, never
--               FAIL: a missing linker is a host fact, not the 1807-shtg
--               defect. Proven with a linker that does not exist
--               (RUSTFLAGS=-C linker=...), so it runs on every host.
--               PRE-FIX: the .sh read that as `FAIL: arm2` / `FAIL: arm3`.
--
-- Verdict: ok:test-shared-target:<passed> (could-not-run arms named above it)
-- or violation:test-shared-target:<failed>.

local BASH = require("common.fixture").posix_shell("/bin/bash") -- Git's bash on native Windows (2246-fkea)
local rel = "target/plan-scratch/shared-target-" .. tostring(time.now_ms())
fs.mkdir(rel)
-- A script FILE, not bash -c: the scratch holds a whole repo and its worktree,
-- both inside the scratch, so nothing in THIS repo needs pruning.
fs.write(rel .. "/cleanup.sh", 'rm -rf -- "$1"\n')
local function cleanup() proc.run{ argv = { BASH, rel .. "/cleanup.sh", rel }, timeout_ms = 60000 } end

-- The world every arm sources: the .sh's setup, verbatim in effect.
-- ORDER 2145-fexh: it builds its own shared-target world, so it must not
-- inherit the caller's (a gate has already entered one).
fs.write(rel .. "/world.sh", ([==[
unset CARGO_TARGET_DIR TILLANDSIAS_SHARED_TARGET_HELD TILLANDSIAS_SHARED_TARGET
ROOT="$(pwd -P)"
W="$ROOT/@REL@"
. "$ROOT/scripts/shared-target.sh"
A="$W/a"; B="$W/b"; CANON="$A/target"
ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; }
run() { (cd "$1" && env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$CANON" cargo run -q --offline 2>&1); }
hour_ago() {
    local t
    t="$(date -d '1 hour ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v-1H +%Y%m%d%H%M.%S)"
    touch -t "$t" "$1"
}
]==]):gsub("@REL@", function() return rel end))

local function arm(name, body)
    fs.write(rel .. "/" .. name .. ".sh", ". \"$(pwd -P)/" .. rel .. "/world.sh\"\n" .. body)
    local p = proc.run{ argv = { BASH, rel .. "/" .. name .. ".sh" }, timeout_ms = 300000 }
    return (p.stdout or "") .. (p.stderr or ""), p.code
end

local passed, failed, skipped = 0, 0, {}
local function report(o)
    for _, l in ipairs(text.lines(o)) do
        if l:find("^ok: ") then out.line(l); passed = passed + 1
        elseif l:find("^FAIL: ") then log.raw(l); failed = failed + 1
        elseif l:find("^skip:") or l:find("^could%-not%-run:") then out.line(l) end
    end
end

-- SETUP
local o = arm("setup", [==[
mkdir -p "$A/src" "$A/target"
git -C "$A" init -q -b main
git -C "$A" config user.email t@t; git -C "$A" config user.name t
printf '[package]\nname="probe"\nversion="0.0.0"\nedition="2021"\n[workspace]\n' > "$A/Cargo.toml"
printf 'fn main(){println!("code-from-A {}", env!("CARGO_MANIFEST_DIR"));}\n' > "$A/src/main.rs"
printf '/target/\n' > "$A/.gitignore"
git -C "$A" add -A; git -C "$A" commit -qm a
git -C "$A" worktree add -q -b wb "$B"
sed 's/code-from-A/code-from-B/' "$B/src/main.rs" > "$B/src/main.rs.new" && mv "$B/src/main.rs.new" "$B/src/main.rs"
echo setup-done
]==])
if not o:find("setup-done", 1, true) then
    cleanup()
    log.raw("FAIL: setup: " .. o)
    verdict.emit("violation:test-shared-target:setup", 1)
end

-- 2230-iqyu: a link failure is the HOST's, not the guard's. The phrase is
-- rustc's own when the linker binary is absent (error: linker `cc` not found).
local function no_linker(text_out) return text_out:find("error: linker `[^`]+` not found") ~= nil end

-- ARM 5
report(arm("arm5", [==[
[ "$(shared_target_canon "$B")" = "$CANON" ] && [ "$(shared_target_canon "$A")" = "$CANON" ] \
  && ok "arm5 worktree and main share one canonical dir" || bad "arm5 canonical dirs differ: $(shared_target_canon "$B")"
]==]))

local has_flock = arm("flock", 'command -v flock >/dev/null 2>&1 && echo yes\n'):find("yes", 1, true)
if has_flock then
    -- ARM 1
    report(arm("arm1", [==[
( TILLANDSIAS_SHARED_TARGET_WAIT=1 shared_target_enter "$A" ) >/dev/null 2>&1
( shared_target_enter "$A" >/dev/null 2>&1; sleep 4 ) &
holder=$!; sleep 1
cat > "$W/second.sh" <<EOF
. '$ROOT/scripts/shared-target.sh'
shared_target_enter '$B'
EOF
if out="$(TILLANDSIAS_SHARED_TARGET_WAIT=1 bash "$W/second.sh" 2>&1)"; then
  bad "arm1 second enter was admitted while the dir was held"
else case "$out" in *REFUSED*locked*"last owner"*) ok "arm1 lock refuses and names the owner";; *) bad "arm1 refusal unnamed: $out";; esac; fi
wait "$holder" 2>/dev/null
]==]))

    -- ARMS 2 + 3, unless the probe cannot link.
    local probe = arm("probe", 'command -v cargo >/dev/null 2>&1 || { echo "no-cargo-on-path"; exit 0; }; run "$A"\n')
    if probe:find("no-cargo-on-path", 1, true) then
        out.line("could-not-run:test-shared-target:arm2,arm3:no-cargo — no cargo on PATH here; run them where cargo is (2230-iqyu)")
        skipped[#skipped + 1] = "arm2,arm3:no-cargo"
    elseif no_linker(probe) then
        local l = "could-not-run:test-shared-target:arm2,arm3:no-linker — the probe crate cannot link on this host ("
            .. (probe:match("error: linker `[^`]+` not found") or "") .. "); install a C linker (cc) to run them (2230-iqyu)"
        out.line(l); skipped[#skipped + 1] = "arm2,arm3:no-linker"
    else
        report(arm("arm23", [==[
run "$A" >/dev/null; hour_ago "$B/src/main.rs"
naive="$(run "$B")"
case "$naive" in code-from-A*) ok "arm2 naive shared dir ran A's code in B (the defect reproduces)";;
  *) bad "arm2 naive run did not show A: $naive";; esac
hour_ago "$B/src/main.rs"
( shared_target_enter "$B" >/dev/null 2>&1; run "$B" ) > "$W/g.out" 2>&1
guard="$(cat "$W/g.out")"
case "$guard" in code-from-B*"$B"*) ok "arm3 guarded run built B's code and baked B's manifest dir";;
  *) bad "arm3 guarded run did not show B: $guard";; esac
]==]))
    end

    -- ARM 4
    report(arm("arm4", [==[
touch "$W/marker"; sleep 1; hour_ago "$B/src/main.rs"
( shared_target_enter "$B" >/dev/null 2>&1 )
[ ! "$B/src/main.rs" -nt "$W/marker" ] && ok "arm4 same checkout re-entered without touching" || bad "arm4 touched on an unchanged owner"
]==]))

    -- ARM 6: script files, not bash -c strings (a trailing bash -c is
    -- exec-optimised and would drop the parent's fd).
    report(arm("arm6", [==[
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
]==]))

    -- ARM 7: the builder died but an orphan holds fd 9; a dead holder must
    -- not block entry. PRE-FIX: enter waits, then REFUSED.
    report(arm("arm7", [==[
cat > "$W/orphan.sh" <<EOF
exec 9>>"$CANON/.shared-target.lock"
flock -n 9 || exit 9
printf 'pid 999999 bash dead-builder\n' > "$CANON/.shared-target-holder"
echo \$\$ > "$W/orphan.pid"
sleep 30
EOF
( bash "$W/orphan.sh" ) >/dev/null 2>&1 &
sleep 1
cat > "$W/enter-a.sh" <<EOF
. '$ROOT/scripts/shared-target.sh'
shared_target_enter '$A'
EOF
o7="$(TILLANDSIAS_SHARED_TARGET_WAIT=3 bash "$W/enter-a.sh" 2>&1)"; rc7=$?
[ $rc7 -eq 0 ] && ok "arm7 a lock held only by orphans of a dead builder does not block entry" \
  || bad "arm7 dead-holder lock blocked entry (rc=$rc7): $o7"
[ -f "$W/orphan.pid" ] && kill "$(cat "$W/orphan.pid")" 2>/dev/null
true
]==]))
else
    out.line("skip:test-shared-target:arms-1-4,6,7:no-flock — sharing is off on this regime by design; ARM 8 covers it (1840-2p9v)")
    skipped[#skipped + 1] = "arms-1-4,6,7:no-flock"
end

-- ARM 8 (1840-2p9v) NO FLOCK: a PATH without flock(1) turns the shared dir
-- OFF (rc 0, CARGO_TARGET_DIR untouched); it must not refuse.
report(arm("arm8", [==[
NB="$W/noflock-bin"; mkdir -p "$NB"
for t in bash git dirname cat sed head printf; do
    tp="$(command -v "$t" 2>/dev/null)" && [ "${tp#/}" != "$tp" ] && ln -sf "$tp" "$NB/$t"
done
cat > "$W/enter-noflock.sh" <<EOF
. '$ROOT/scripts/shared-target.sh'; shared_target_enter '$A'; echo rc=\$? ctd=\${CARGO_TARGET_DIR:-unset}
EOF
o8="$(env -u CARGO_TARGET_DIR -u TILLANDSIAS_SHARED_TARGET_HELD PATH="$NB" "$NB/bash" "$W/enter-noflock.sh" 2>&1)"
case "$o8" in
    *"shared-target: off (no flock"*"rc=0 ctd=unset"*) ok "arm8 no flock on PATH turns the shared dir off without refusing" ;;
    *) bad "arm8 no-flock host refused or exported a shared dir: $o8" ;;
esac
]==]))

-- ARM 9 (2230-iqyu) NO LINKER, on every host: a linker that does not exist
-- makes the probe fail exactly as yoga's bare host did, and the classifier
-- must call it no-linker. CONTROL: the classifier does not fire on a run that
-- linked (or failed for another reason).
local nl = arm("arm9", 'RUSTFLAGS="-C linker=tillandsias-no-such-linker-2230" run "$A"\n')
if no_linker(nl) then
    out.line("ok: arm9 a probe that cannot link reads as could-not-run:no-linker, never as a FAIL of arms 2/3")
    passed = passed + 1
else
    log.raw("FAIL: arm9 a missing linker was not recognised (arms 2/3 would read it as the defect): " .. nl)
    failed = failed + 1
end
if not no_linker("code-from-A /x\n") and not no_linker("error: could not compile `probe`") then
    out.line("ok: arm9 control: the no-linker classifier does not fire on a linked run or another build error")
    passed = passed + 1
else
    log.raw("FAIL: arm9 control: the no-linker classifier fires on output that is not a missing linker")
    failed = failed + 1
end

cleanup()
if failed > 0 then verdict.emit("violation:test-shared-target:" .. failed, 1) end
verdict.emit("ok:test-shared-target:" .. passed .. (#skipped > 0 and (":could-not-run:" .. table.concat(skipped, ";")) or ""), 0)
