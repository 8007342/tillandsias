-- @env PATH HOME
-- @trace order:1176-9vqn, order:1422-fvce, order:1124-7f3u, order:2160-mhsm, order:2245-scgt, order:2404-grd6
--
-- test-pre-push-honours-a-live-freeze.lua — a release freeze is a marker on origin that the
-- pre-push hook consults for CODE pushes to the branch the marker names, and plan-only pushes
-- stay admitted (1176-9vqn). Ported from test-pre-push-honours-a-live-freeze.sh (2404-grd6):
-- the same 21 checks, in its order.
--
-- Hermetic: a bare remote plus a working copy in kit scratch, with the REAL hook installed as
-- the scratch copy's .git/hooks/pre-push (core.hooksPath pinned to it), so each arm exercises
-- the path git actually drives. Nothing is pushed anywhere but the scratch bare remote.
--
-- WHY EACH ARM MINTS A GATE STAMP FIRST (GATE_STAMP_REQUIRE_TOKEN=0, the sanctioned off-switch
-- for the guard that stops a RED gate from stamping). The freeze check sits AFTER the gate-stamp
-- dispatch: a code push with no valid stamp is already refused for the stamp, so the freeze
-- check exists to hold pushes that would otherwise be ADMITTED. Without a stamp every code arm
-- would refuse for the stamp and pass while testing nothing; ARM 2's PRECONDITION pins that.
--
--   1  the freeze tool's round-trip: status / set / status / set-again / one marker (5 checks)
--   2  PRECONDITION fresh stamp; a CODE push to the frozen branch is REFUSED and names the
--      marker and the branch; MUTANT (content-built, in the scratch copy) proves teeth
--   3  NEGATIVE CONTROL plan-only pushes are admitted: with a stamp (exempt paths), and with
--      none (the plan-only lane, which exits before the freeze check; named skip when no
--      current validator resolves — host state, 2160-mhsm)
--   4  NEGATIVE CONTROL a code push to a branch the marker does not name is admitted
--   5  an unreachable remote WARNS and ADMITS, naming the check
--   6  clear / unfrozen / clear-again 0 / push lands after clear / --bogus / a slashed branch /
--      a branch the remote lacks (7 checks)
--   7  1422-fvce: set with the remote tip AHEAD of this clone marks that tip; a marker push the
--      remote refuses names git's own reason
--
-- The shell steps run as script files through fixture.posix_shell(); every assertion is here.
--
-- GRAMMAR ok:pre-push-honours-a-live-freeze:<n> arms | violation:pre-push-honours-a-live-freeze:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("pre-push-honours-a-live-freeze")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()

local GUARD = "scripts/hooks/pre-push-local-gate.sh"
local FREEZE = "scripts/release-freeze.sh"
for _, f in ipairs{ GUARD, FREEZE, "scripts/gate-stamp.sh" } do
    if not fs.exists(f) then T:refuse("subject-missing", f) end
end

local Wd = T:scratch("w")
local W = Wd.abs
local WC = W .. "/wc"

-- THE PLAN-ONLY LANE IS STAMP-FREE BUT NOT VALIDATOR-FREE (1124-7f3u), and ARM 3b is the only arm
-- that depends on it. The validator is resolved HERE, from the checkout, and handed to the hook
-- explicitly: a scratch repo has no target/, so the probe would otherwise reach whatever
-- tillandsias-plan sits on PATH — the undeclared candidate that once made this green on one host
-- and red on another. TILLANDSIAS_SURFACE_ROOT names the checkout the binary is measured against.
local VALIDATOR = fixture.plan_binary()
local ENV = { GIT_TERMINAL_PROMPT = "0", W = W, ROOT = ROOT, TILLANDSIAS_SURFACE_ROOT = ROOT }
if VALIDATOR ~= "" then ENV.TILLANDSIAS_PLAN_BIN = VALIDATOR end
local UNSET = { "TILLANDSIAS_*", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_PREFIX", "GATE_STAMP_*", "CONTAINER_HOST" }

local PRELUDE = table.concat({
    "unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX",
    'G() { git -c user.email=t@t -c user.name=t "$@"; }',
    'freeze() { bash scripts/release-freeze.sh "$@"; }',
    -- the token guard exists so a RED gate cannot stamp; a fixture minting a stamp is its sanctioned off-switch
    "stamp() { GATE_STAMP_REQUIRE_TOKEN=0 bash scripts/gate-stamp.sh write >/dev/null 2>&1; }",
    'tip() { git ls-remote "$W/bare.git" "refs/heads/$1" | cut -f1; }',
    "",
}, "\n")

local seq = 0
-- sh(body, cwd): run body (with the prelude) as a script file; code, stdout, stderr.
local function sh(body, cwd)
    seq = seq + 1
    local rel = Wd.rel .. "/step-" .. seq .. ".sh"
    fs.write(rel, PRELUDE .. body .. "\n")
    local r = T:run{ SH, W .. "/step-" .. seq .. ".sh", cwd = cwd or WC, env = ENV, env_unset = UNSET,
        timeout_ms = 180000 }
    return r.code, r.stdout or "", r.stderr or ""
end
local function last(s) local ls = text.lines(text.trim(s)); return ls[#ls] or "" end
local function kv(s, k) return (s:match("\n" .. k .. "=([^\n]*)") or ("\n" .. s):match("\n" .. k .. "=([^\n]*)")) end

-- Setup: the scratch remote and working copy, the real hook and its helpers copied in.
local rc, o, e = sh([[
set -e
git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc"
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
git config core.autocrlf false
mkdir -p scripts/hooks plan/index.d crates/demo
cp "$ROOT/scripts/hooks/pre-push-local-gate.sh" scripts/hooks/pre-push-local-gate.sh
cp "$ROOT/scripts/release-freeze.sh" scripts/release-freeze.sh
# lib-freeze-paths.sh: the shared freeze predicate both scripts source (1255-s4im).
for f in gate-stamp.sh plan-binary-probe.sh common.sh lib-freeze-paths.sh; do cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true; done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null || true
printf 'packets: []\n' > plan/index.yaml
printf 'fn main() {}\n' > crates/demo/main.rs
printf 'base\n' > README.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next
git push -q origin linux-next:windows-next
printf '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
echo setup-ok
]], W)
if rc ~= 0 or not text.contains(o, "setup-ok") then T:refuse("setup-failed", "rc=" .. tostring(rc) .. " " .. e:sub(1, 400)) end

-- ── ARM 1: the freeze tool's round-trip ───────────────────────────────────────
local _, o1 = sh("freeze status linux-next 2>/dev/null")
T:arm("ARM 1: status on an unfrozen branch reads ok:freeze-none", last(o1) == "ok:freeze-none:linux-next", last(o1))
local _, o2 = sh('freeze set linux-next "the v0.0.0 cut" 2>/dev/null')
local set1 = last(o2)
T:arm("ARM 1: set mints refs/tillandsias/freeze/<branch>/<host>/<epoch> on the remote",
    set1:match("^ok:freeze%-set:refs/tillandsias/freeze/linux%-next/[^/]+/[^/]+$") ~= nil, set1)
local MARKER = set1:gsub("^ok:freeze%-set:", "")
local _, o3 = sh("freeze status linux-next 2>/dev/null")
T:arm("ARM 1: status reports frozen with who and how long",
    last(o3):match("^frozen:linux%-next:by=.*:since=.*:age=.*s$") ~= nil, last(o3))
local _, o4 = sh("freeze set linux-next 2>/dev/null")
T:arm("ARM 1: setting a live freeze again is ok:freeze-already, not a second marker",
    last(o4):match("^ok:freeze%-already:") ~= nil, last(o4))
local _, o5 = sh([[git ls-remote "$W/bare.git" 'refs/tillandsias/freeze/*' > "$W/markers.txt"; echo "n=$(grep -c . "$W/markers.txt")"]])
T:arm("ARM 1: exactly one marker exists on the remote", kv(o5, "n") == "1", o5)

-- ── ARM 2: a CODE push to the frozen branch is REFUSED ────────────────────────
local _, o6 = sh([[
printf 'fn main() { /* code */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code under a freeze"
stamp
echo "verify=$(bash scripts/gate-stamp.sh verify 2>/dev/null)"
echo "before=$(tip linux-next)"
]])
T:arm("ARM 2 PRECONDITION: the scratch holds a fresh full-scope stamp, so the push reaches the freeze check rather than refusing for the stamp",
    kv(o6, "verify") == "ok:gate-fresh", o6)
local before = kv(o6, "before") or ""
local prc, po, pe = sh("G push origin linux-next")
local _, o7 = sh('echo "after=$(tip linux-next)"')
local pall = po .. pe
T:arm("ARM 2: the code push is refused, the branch does not move, and the refusal NAMES the marker and the branch",
    prc ~= 0 and kv(o7, "after") == before and MARKER ~= "" and text.contains(pall, MARKER)
        and text.contains(pall, "'linux-next' is FROZEN"),
    "rc=" .. tostring(prc) .. " moved=" .. tostring(kv(o7, "after") ~= before) .. " " .. pall:sub(1, 300))
-- MUTANT, built from CONTENT in the scratch copy: drop the call site and the same push lands.
local hook = fs.read(Wd.rel .. "/wc/" .. GUARD) or ""
local CALL = '\nenforce_release_freeze "$_freeze_remote"\n'
if not text.contains(hook, CALL) then
    T:arm("ARM 2 MUTANT: without the call the identical push lands under the live freeze — the check has teeth",
        false, "setup: the call site no longer matches, so the mutant is a no-op")
else
    local s, f = hook:find(CALL, 1, true)
    fs.write(Wd.rel .. "/mutant.sh", hook:sub(1, s) .. hook:sub(f + 1))
    local mrc, mo = sh([[
cp scripts/hooks/pre-push-local-gate.sh "$W/hook.swap"
cp "$W/mutant.sh" scripts/hooks/pre-push-local-gate.sh
stamp
rc=0; G push -q origin linux-next >/dev/null 2>&1 || rc=$?
cp "$W/hook.swap" scripts/hooks/pre-push-local-gate.sh
echo "rc=$rc"
echo "after=$(tip linux-next)"
]])
    local landed = kv(mo, "rc") == "0" and kv(mo, "after") ~= before
    T:arm("ARM 2 MUTANT: without the call the identical push lands under the live freeze — the check has teeth",
        landed, mo)
    if landed then sh('G push -q origin "+' .. before .. ':refs/heads/linux-next" >/dev/null 2>&1') end  -- restore
end

-- ── ARM 3: NEGATIVE CONTROL — plan-only pushes are admitted, both paths ───────
local _, o8 = sh([[
G reset -q --hard origin/linux-next
printf 'packets: []\n' > plan/index.d/20200101t000000z-fixture.yaml
G add -A >/dev/null; G commit -q -m "plan(fixture): a ledger record during the freeze"
stamp
b="$(tip linux-next)"
rc=0; G push origin linux-next >"$W/p3a.out" 2>&1 || rc=$?
echo "rc=$rc"; echo "moved=$([ "$(tip linux-next)" != "$b" ] && echo yes || echo no)"
]])
T:arm("ARM 3 (negative control): a plan-only push WITH a fresh stamp is admitted under the live freeze — the exempt-path logic",
    kv(o8, "rc") == "0" and kv(o8, "moved") == "yes", o8 .. (fs.read(Wd.rel .. "/p3a.out") or ""):sub(1, 300))
sh([[
printf 'packets: []\n' > plan/index.d/20200101t000001z-fixture.yaml
G add -A >/dev/null; G commit -q -m "plan(fixture): a second ledger record, no stamp"
rm -f "$(git rev-parse --absolute-git-dir)/tillandsias-gate-stamp"
]])
-- 2160-mhsm: a stale validator is host state, not a property of the change.
local stale = ""
if VALIDATOR ~= "" then
    local vr = T:run{ VALIDATOR, "validator-surface-hash", "--check", cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local vs = (vr.stdout or "") .. (vr.stderr or "")
    if vs:match("^stale:validator%-surface") then stale = text.lines(vs)[1] end
end
if VALIDATOR == "" then
    out.line("skip: ARM 3b: no runnable tillandsias-plan on this host — the plan-only lane is stamp-free, NOT validator-free (1124-7f3u). Build one: cargo build --release -p tillandsias-plan")
elseif stale ~= "" then
    out.line("skip: ARM 3b: the resolved tillandsias-plan (" .. VALIDATOR .. ") is stale for this tree (" .. stale
        .. ") — host state, not this change (2160-mhsm). Rebuild: cargo build --release -p tillandsias-plan")
else
    local _, o9 = sh([[
b="$(tip linux-next)"
rc=0; G push origin linux-next >"$W/p3b.out" 2>&1 || rc=$?
echo "rc=$rc"; echo "moved=$([ "$(tip linux-next)" != "$b" ] && echo yes || echo no)"
]])
    T:arm("ARM 3 (negative control): a plan-only push with NO stamp but WITH a resolvable validator is admitted under the live freeze — the lane exits before the freeze check",
        kv(o9, "rc") == "0" and kv(o9, "moved") == "yes", o9 .. (fs.read(Wd.rel .. "/p3b.out") or ""):sub(1, 400))
end

-- ── ARM 4: NEGATIVE CONTROL — a branch the marker does not name ───────────────
local _, o10 = sh([[
G checkout -q -B windows-next origin/windows-next
printf 'fn main() { /* platform code */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code on a branch no marker names"
stamp
b="$(tip windows-next)"
rc=0; G push origin windows-next >"$W/p4.out" 2>&1 || rc=$?
echo "rc=$rc"; echo "moved=$([ "$(tip windows-next)" != "$b" ] && echo yes || echo no)"
]])
T:arm("ARM 4 (negative control): a code push to a branch the marker does not name is admitted",
    kv(o10, "rc") == "0" and kv(o10, "moved") == "yes", o10 .. (fs.read(Wd.rel .. "/p4.out") or ""):sub(1, 300))

-- ── ARM 5: the fetch-failure trade — warn and ADMIT, never block ──────────────
-- The ref line is fed the way git feeds it, with origin pointed at a path that does not exist.
local _, o11 = sh([[
G checkout -q linux-next 2>/dev/null || G checkout -q -B linux-next origin/linux-next
printf 'fn main() { /* code, unreachable remote */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code while origin is unreachable"
stamp
git remote set-url origin "$W/does-not-exist.git"
printf 'refs/heads/linux-next %s refs/heads/linux-next %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD~1)" > "$W/refline"
rc=0; bash scripts/hooks/pre-push-local-gate.sh origin "$W/does-not-exist.git" < "$W/refline" > "$W/p5.out" 2>&1 || rc=$?
git remote set-url origin "$W/bare.git"
echo "rc=$rc"
]])
local p5 = fs.read(Wd.rel .. "/p5.out") or ""
T:arm("ARM 5: an unreachable remote WARNS and admits, naming the check — the push's own failure is the backstop, and an offline host is not stranded",
    kv(o11, "rc") == "0" and text.contains(p5, "release-freeze check could not reach"), o11 .. p5:sub(1, 300))

-- ── ARM 6: clearing, and the tool's refusals ──────────────────────────────────
local _, a = sh("freeze clear linux-next 2>/dev/null")
T:arm("ARM 6: clear removes the marker", last(a) == "ok:freeze-cleared:1", last(a))
_, a = sh("freeze status linux-next 2>/dev/null")
T:arm("ARM 6: the branch reads unfrozen again", last(a) == "ok:freeze-none:linux-next", last(a))
_, a = sh("freeze clear linux-next 2>/dev/null")
T:arm("ARM 6: clearing an unfrozen branch is 0, not an error", last(a) == "ok:freeze-cleared:0", last(a))
_, a = sh([[
G reset -q --hard origin/linux-next; stamp
b="$(tip linux-next)"
printf 'fn main() { /* code after the all-clear */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: code after the all-clear"; stamp
rc=0; G push -q origin linux-next >/dev/null 2>&1 || rc=$?
echo "rc=$rc"; echo "moved=$([ "$(tip linux-next)" != "$b" ] && echo yes || echo no)"
]])
T:arm("ARM 6: with the freeze cleared the same code push lands — the marker's lifetime is the freeze's lifetime",
    kv(a, "rc") == "0" and kv(a, "moved") == "yes", a)
local frc, fo = sh("freeze --bogus 2>/dev/null")
T:arm("ARM 6: an unknown flag is refused with exit 2", frc == 2 and last(fo) == "refused:freeze:usage:--bogus",
    "rc=" .. tostring(frc) .. " '" .. last(fo) .. "'")
frc, fo = sh("freeze set work/1176-9vqn 2>/dev/null")
T:arm("ARM 6: a branch name with a slash is refused rather than mis-parsed back out of the ref",
    frc == 2 and last(fo):match("^refused:freeze:usage:branch") ~= nil, "rc=" .. tostring(frc) .. " '" .. last(fo) .. "'")
_, fo = sh("freeze set no-such-branch 2>/dev/null")
T:arm("ARM 6: freezing a branch the remote does not have is refused",
    last(fo) == "refused:freeze:no-such-branch:no-such-branch", last(fo))

-- ── ARM 7: 1422-fvce — the remote tip is AHEAD of this clone ──────────────────
local _, o12 = sh([[
git clone -q "$W/bare.git" "$W/other" 2>/dev/null
( cd "$W/other" && git checkout -q linux-next && printf 'ahead\n' >> README.md \
    && G commit -q -am "ahead of wc" && git push -q --no-verify origin linux-next ) >/dev/null 2>&1
A="$(tip linux-next)"
echo "ahead=$A"
if git cat-file -e "$A^{commit}" 2>/dev/null; then echo "local=yes"; else echo "local=no"; fi
]])
local AHEAD = kv(o12, "ahead") or ""
if kv(o12, "local") ~= "no" then
    T:arm("ARM 7: set succeeds when the remote tip is ahead of this clone, and marks that tip", false,
        "setup: the remote tip " .. AHEAD .. " is already local, so the arm would test nothing")
else
    local _, so = sh("freeze set linux-next 2>/dev/null")
    local s7 = last(so)
    local mk = s7:gsub("^ok:freeze%-set:", "")
    local _, mo = sh('echo "at=$(git ls-remote "$W/bare.git" "' .. mk .. '" | cut -f1)"')
    T:arm("ARM 7: set succeeds when the remote tip is ahead of this clone, and marks that tip",
        s7:match("^ok:freeze%-set:refs/tillandsias/freeze/linux%-next/[^/]+/[^/]+$") ~= nil and kv(mo, "at") == AHEAD,
        s7 .. " marker-at=" .. tostring(kv(mo, "at")) .. " ahead=" .. AHEAD)
    sh("freeze clear linux-next >/dev/null 2>&1")
end
-- A refusal names git's reason: the remote rejects marker refs by hook. The scratch remote is
-- pinned to its OWN hooks: a global core.hooksPath would otherwise make it ignore hooks/.
local _, r7 = sh([[
printf '#!/bin/sh\nwhile read o n r; do case "$r" in refs/tillandsias/*) echo "fixture-hook: markers refused here"; exit 1 ;; esac; done\n' > "$W/bare.git/hooks/pre-receive"
chmod +x "$W/bare.git/hooks/pre-receive"
git -C "$W/bare.git" config core.hooksPath "$W/bare.git/hooks"
freeze set linux-next 2>/dev/null > "$W/p7.out"
rm -f "$W/bare.git/hooks/pre-receive"
git -C "$W/bare.git" config --unset core.hooksPath
echo done
]])
local p7 = last(fs.read(Wd.rel .. "/p7.out") or "")
T:arm("ARM 7: a refused marker push names the remote's own reason",
    p7:find("^refused:freeze:unreachable:could not push the marker to origin:") ~= nil
        and text.contains(p7, "fixture-hook: markers refused here"), p7 .. " " .. r7)

-- ── ARMS 8-9: what the hook deliberately does not hold under a live freeze ────
-- Both run with linux-next frozen again, from the scratch clone, against the scratch remote.
local _, f8 = sh([[
git -C "$W/bare.git" config --unset core.hooksPath 2>/dev/null
G checkout -q linux-next 2>/dev/null; G fetch -q origin; G reset -q --hard origin/linux-next
echo "set=$(freeze set linux-next 2>/dev/null | tail -1)"
]])
-- ARM 8 (pins the freeze loop's deletion skip, H9): a deletion of a branch other than the
-- frozen one is accepted. A DELETION-ONLY push never reaches the freeze check (the hook's
-- deletion-only early exit, 1427-r2d2), so the deletion rides with a new branch in ONE push,
-- which reaches the loop. The deleted branch is made by ANOTHER clone and never fetched here, so
-- its tip is not a local object: without the skip the loop cannot prove the deletion plan-only,
-- treats it as code, and finds the marker planted under the deleted branch's name.
local _, o13 = sh([[
( cd "$W/other" && git fetch -q origin && git checkout -q -B scratch-del origin/linux-next \
    && printf 'gone\n' > gone.txt && G add gone.txt && G commit -q -m "a branch to delete" \
    && git push -q --no-verify origin scratch-del ) >/dev/null 2>&1
# A marker under the deleted branch's own name: the freeze state a deletion must not consult.
git push -q --no-verify "$W/bare.git" "$(tip linux-next):refs/tillandsias/freeze/scratch-del/fixture/1700000000" >/dev/null 2>&1
echo "present=$([ -n "$(tip scratch-del)" ] && echo yes || echo no)"
echo "local=$(git cat-file -e "$(tip scratch-del)^{commit}" 2>/dev/null && echo yes || echo no)"
stamp
rc=0; G push origin :refs/heads/scratch-del HEAD:refs/heads/side-ok >"$W/p8.out" 2>&1 || rc=$?
echo "rc=$rc"; echo "gone=$([ -z "$(tip scratch-del)" ] && echo yes || echo no)"
echo "frozen=$(grep -c "is FROZEN" "$W/p8.out")"
git push -q --no-verify "$W/bare.git" --delete refs/tillandsias/freeze/scratch-del/fixture/1700000000 >/dev/null 2>&1
]])
T:arm("ARM 8: under a live freeze a branch DELETION is not held by the freeze (the hook skips deletion pushes)",
    kv(f8, "set") and kv(f8, "set"):match("^ok:freeze%-set:") ~= nil and kv(o13, "present") == "yes"
        and kv(o13, "local") == "no" and kv(o13, "rc") == "0" and kv(o13, "gone") == "yes"
        and kv(o13, "frozen") == "0",
    f8 .. o13 .. (fs.read(Wd.rel .. "/p8.out") or ""):sub(1, 400))
-- ARM 9 (pins the hook's slashed-branch skip, H10): work refs keep moving during a freeze. A
-- marker shaped like one for the slashed branch is planted directly (the tool refuses to make
-- one), so only the skip stands between it and a refusal.
local _, o14 = sh([[
git push -q --no-verify "$W/bare.git" "$(tip linux-next):refs/tillandsias/freeze/work/1234-abcd/fixture/1700000000" >/dev/null 2>&1
G checkout -q -B work/1234-abcd origin/linux-next
printf 'fn main() { /* work ref under a freeze */ }\n' > crates/demo/main.rs
G add -A >/dev/null; G commit -q -m "feat: work ref under a freeze"
stamp
rc=0; G push origin work/1234-abcd >"$W/p9.out" 2>&1 || rc=$?
echo "rc=$rc"; echo "landed=$([ "$(tip work/1234-abcd)" = "$(git rev-parse HEAD)" ] && echo yes || echo no)"
echo "frozen=$(grep -c "is FROZEN" "$W/p9.out")"
git push -q --no-verify "$W/bare.git" --delete refs/tillandsias/freeze/work/1234-abcd/fixture/1700000000 >/dev/null 2>&1
freeze clear linux-next >/dev/null 2>&1
]])
T:arm("ARM 9: under a live freeze a code push to a slashed work ref is accepted — work refs keep moving",
    kv(o14, "rc") == "0" and kv(o14, "landed") == "yes" and kv(o14, "frozen") == "0",
    o14 .. (fs.read(Wd.rel .. "/p9.out") or ""):sub(1, 400))

T:finish()
