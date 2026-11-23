-- @env PATH HOME
-- @trace order:1320-44rs, order:2248-jihs
--
-- test-no-fixture-writes-live-ledger.lua — the checker flags a fixture that
-- writes the checkout's OWN plan/index.d or plan/loop_status.d, and accepts the
-- scaffold idioms. Ported from scripts/test-no-fixture-writes-live-ledger.sh
-- (order 2248-jihs pays the carried shell-to-lua item); same arms, same
-- samples, same verdict line.
--
--   1  the shapes it must FLAG: `"$ROOT/$PEND"` with PEND a relative ledger path
--      (the pre-fix pending-capability fixture), a relative write after
--      `cd "$ROOT"`, the `ROOT="$(cd ...)"; cd "$ROOT"` one-liner (the pre-fix
--      archiver-memo fixture), `"$REPO_ROOT/plan/loop_status.d/x.md"`, a `tee`
--   2  the idioms it must ACCEPT: `"$W/plan/index.d/x.yaml"`, a relative write
--      after `cd "$W/wc"` or `cd "$wt"`, a same-line subshell
--      `( cd "$S" && ... > plan/index.d/a.yaml )`, a read (`cat plan/index.d/x`)
--   3  the real corpus is clean: ok:fixtures-write-scaffolds-only
--
-- The samples spell the ledger dirs as __LED__ / __LSD__ and are expanded only
-- when written to scratch, so no literal live-ledger write sits in this file.
--
-- Usage: tillandsias-plan script run scripts/lua/test-no-fixture-writes-live-ledger.lua
-- Verdict: PASS: no-fixture-writes-live-ledger <n>/<n> (1320-44rs) then ok:no-fixture-writes-live-ledger:<n>/<n>
--          or FAIL: ... then violation:no-fixture-writes-live-ledger:<n>-failed

local fixture = require "common.fixture"
local root = fixture.repo_root()
local C = root .. "/scripts/check-no-fixture-writes-live-ledger.sh"
local REL = "target/plan-scratch/no-fixture-live-ledger-" .. tostring(time.now_ms())
local W = root .. "/" .. REL
local E = { PATH = env.get("PATH"), HOME = env.get("HOME") }
fs.mkdir(REL)
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end
local function finish()
    proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 60000 })
    local total = pass + fail
    if fail == 0 then
        out.line("PASS: no-fixture-writes-live-ledger " .. pass .. "/" .. total .. " (1320-44rs)")
        verdict.emit("ok:no-fixture-writes-live-ledger:" .. pass .. "/" .. total, 0)
    end
    out.line("FAIL: no-fixture-writes-live-ledger " .. pass .. "/" .. total .. " (1320-44rs)")
    verdict.emit("violation:no-fixture-writes-live-ledger:" .. fail .. "-failed", 1)
end
if not fs.read("scripts/check-no-fixture-writes-live-ledger.sh") then
    bad("arm 1: " .. C .. " does not exist"); finish()
end

-- flags(name, body) -> true when the checker flags it
local function flags(name, body)
    body = body:gsub("__LED__", "plan/index.d"):gsub("__LSD__", "plan/loop_status.d")
    fs.write(REL .. "/" .. name .. ".sh", body .. "\n")
    local r = proc.run({ argv = { fixture.posix_shell(), C, W .. "/" .. name .. ".sh" }, env = E, timeout_ms = 60000 })
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code ~= 0 and o:find("violation:fixture-writes-live-ledger:" .. REL .. "/" .. name .. ".sh:", 1, true) ~= nil
end

-- 1
local missed = ""
if not flags("a", 'ROOT="$(cd "$(dirname "$0")/.." && pwd)"\nPEND="__LED__/20990101t000000z-probe.yaml"\ncat > "$ROOT/$PEND" <<Y\nx: 1\nY') then missed = missed .. " $ROOT/$PEND" end
if not flags("b", 'ROOT=/x\ncd "$ROOT" || exit 1\nprintf "x\\n" > __LED__/zz-probe.yaml') then missed = missed .. " cd-ROOT-relative" end
if not flags("c", 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"\nprintf "x\\n" > __LED__/zz-probe.yaml') then missed = missed .. " one-liner-cd" end
if not flags("d", 'echo x > "$REPO_ROOT/__LSD__/20990101-x.md"') then missed = missed .. " REPO_ROOT-loop_status" end
if not flags("e", 'cd "$ROOT"\necho x | tee __LED__/zz.yaml >/dev/null') then missed = missed .. " tee" end
if missed == "" then ok("arm 1: all five live-write shapes are flagged") else bad("arm 1: missed:" .. missed) end

-- 2
local wrongly = ""
if flags("f", 'cat > "$W/__LED__/x.yaml" <<Y\nx: 1\nY') then wrongly = wrongly .. " $W-prefix" end
if flags("g", 'cd "$ROOT"\ncd "$W/wc" || exit 2\nprintf x > __LED__/a.yaml') then wrongly = wrongly .. " cd-scaffold" end
if flags("h", 'cd "$ROOT"\n( cd "$S" && printf x > __LED__/a.yaml )') then wrongly = wrongly .. " same-line-subshell" end
if flags("i", 'cd "$ROOT"\nn=$(cat __LED__/x.yaml | wc -l)') then wrongly = wrongly .. " read" end
if flags("j", 'cd "$ROOT"\ngit worktree add --detach -q "$wt" HEAD\ncd "$wt" || exit 1\necho x > __LED__/probe.yaml') then wrongly = wrongly .. " worktree" end
if wrongly == "" then ok("arm 2: the scaffold idioms and a read are accepted") else bad("arm 2: wrongly flagged:" .. wrongly) end

-- 3
local r = proc.run({ argv = { fixture.posix_shell(), C }, env = E, timeout_ms = 120000 })
local o = text.trim((r.stdout or "") .. (r.stderr or ""))
local last = o:match("([^\n]*)$") or ""
if r.code == 0 and last:match("^ok:fixtures%-write%-scaffolds%-only:%d+ checked$") then
    ok("arm 3: the real corpus is clean (" .. last .. ")")
else
    bad("arm 3: rc=" .. tostring(r.code) .. " [" .. o .. "]")
end
finish()
