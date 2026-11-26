-- @trace order:1130-i6xj, order:1570-g4rx, order:2118-9awa, order:2400-prg4, spec:ci-release
--
-- test-portability-idioms.lua — the closure fixture for 1130-i6xj. Ported from
-- test-portability-idioms.sh (2400-prg4); same checks, in its order.
--
-- BOTH HALVES, and the second half is the one that makes it mean anything: the guard
-- catches the 2026-09-12 defects on the trees that CARRIED them (real blobs out of git,
-- never a synthetic corpus), and does not flag those same files once fixed. The closure
-- is PER-INSTANCE, not "zero on the fixed tree": the guard's first run found 35 genuine
-- unrelated pre-existing instances.
--
-- The advisory is scripts/lua/check-portability-idioms.lua on `script run`. Its stdout is
-- ONE line, the verdict; the entries and the limits note are on stderr. The PARITY arm runs
-- the pre-port .sh, pinned from git, and the port over one constructed corpus
-- (scripts/portability/idiom-parity-corpus.txt) and requires identical entries.
--
-- Idioms this file must not carry as literals (it is scanned like any other) are assembled
-- at runtime, as the .sh did.
--
-- GRAMMAR ok:portability-idioms:<n> arms | violation:portability-idioms:<n>-failed
--       | skip:portability-idioms:no-script-runner

local fixture = require "common.fixture"
local T = fixture.new("portability-idioms")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local GUARD = "scripts/lua/check-portability-idioms.lua"
local PINNED_SH_SHA = "152240b1332bbe675c83b283f908846345cb6ccd"
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-script-runner") end
-- is_abs: a native Windows drive path C:/x is absolute too (yolanda msys, #1627).
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local caps = T:run{ PLAN, "capabilities", cwd = ROOT, timeout_ms = 30000 }
if not ("\n" .. (caps.stdout or "") .. "\n"):find("\nscript\n", 1, true) then T:skip("no-script-runner") end

local W = T:scratch()
local UNSET = { "TILLANDSIAS_*", "PROJECT_ROOT" }
local function run_guard(port_root)
    local env = {}
    if port_root then env.TILLANDSIAS_PORTABILITY_ROOT = port_root end
    local r = T:run{ PLAN, "script", "run", GUARD, cwd = ROOT, env = env, env_unset = UNSET, timeout_ms = 300000 }
    return r.code, r.stdout or "", r.stderr or ""
end
local function has(s, plain) return s:find(plain, 1, true) ~= nil end
local function matches(s, pat) return s:find(pat) ~= nil end

local RC, VERDICT, ERR = run_guard()
local OUT = VERDICT .. ERR

-- the advisory contract: ALWAYS 0, and ONE stdout line, the counted verdict.
T:arm("advisory exits 0 (never a gate)", RC == 0, "rc=" .. tostring(RC))
local v = VERDICT:gsub("\n$", "")
T:arm("counted verdict, severity-split, silent class first",
    not has(v, "\n") and matches(v, "^portability%-idioms: silent%-degrade=.* loud%-fail=.* %(advisory%)$"),
    "[" .. VERDICT .. "]")

-- HALF 1: it catches the real defects on the trees that carried them. These pattern
-- arguments ARE the idioms; the guard counts them here, deliberately (see the .sh history).
local function pre_fix_has(commit, path, plain, label)
    local r = T:run{ "git", "show", commit .. "^:" .. path, cwd = ROOT, timeout_ms = 30000 }
    if r.code ~= 0 then T:arm(label .. " (skip: blob unavailable)", true, ""); return end
    local found = false
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local first = l:match("^%s*(%S)")
        if first and first ~= "#" and has(l, plain) then found = true; break end
    end
    T:arm(label, found, "the control this rests on is gone; re-pin the commit")
end
pre_fix_has("5b27fea61", "scripts/audit-guard-activation.sh", "grep -" .. "Rl",
    "HALF 1: pre-fix tree carried grep -Rl in CODE (1087-h2z9)")
pre_fix_has("737bd10c5", "scripts/test-plan-binary-freshness.sh", "touch -t " .. "202609120600",
    "HALF 1: pre-fix tree carried the literal that expired (1129-4su6)")
pre_fix_has("26d007bf4", "scripts/test-gate-stamp-does-not-memoize-guard-owned-paths.sh", "sed -" .. "i '/^plan_digest",
    "HALF 1: pre-fix tree carried GNU-only sed -i (1127-waxf)")
pre_fix_has("737bd10c5", "scripts/test-plan-binary-freshness.sh", "touch -t " .. "202609041215",
    "HALF 1: and carried legitimate OLD stamps alongside it")

-- HALF 2: it does not flag those same files now.
for _, f in ipairs{ "audit-guard-activation.sh", "check-cheatsheet-refs.sh", "test-plan-binary-freshness.sh" } do
    T:arm("HALF 2: " .. f .. " clean", not has(OUT, f), f .. " still flagged after its fix")
end

-- false-accusation arms: each was a REAL false positive in an earlier cut.
T:arm("NEGATIVE CONTROL: same-line fallback chains not flagged", not has(OUT, "diagnose-macos-provision.sh:159"),
    "flagged a correct same-line BSD-first fallback chain")
-- Anchored on file:line, not the bare name: every stat -c hit's ADVICE names litmus-stdlib.sh.
T:arm("NEGATIVE CONTROL: fallbacks across a line continuation not flagged",
    not matches(OUT, "litmus%-stdlib%.sh:%d+"), "flagged the repo's own GNU/BSD absorption layer")
local help_hit = false
for _, lang in ipairs{ "de", "es", "fr", "ja" } do if has(OUT, "help-" .. lang .. ".sh") then help_hit = true end end
T:arm("NEGATIVE CONTROL: usage lines not flagged", not help_hit, "flagged help TEXT as an rg invocation")
T:arm("DIALECT BRANCH: an idiom inside an explicit GNU/BSD branch is not flagged",
    not matches(OUT, "bump%-version%.sh:%d+"), "flagged an idiom whose file already branches on dialect")

-- the bounded window's control, CONSTRUCTED (a live witness got fixed, 1135-z8gn).
local _I = "i"
fs.mkdir(W.rel .. "/dialect/scripts")
fs.write(W.rel .. "/dialect/scripts/bare-idiom.sh", '#!/usr/bin/env bash\nsed -' .. _I .. ' "s/a/b/" "$1"\n')
local _, o1, e1 = run_guard(W.abs .. "/dialect")
T:arm("DIALECT BRANCH control: a bare idiom with no nearby probe IS still flagged (constructed tree)",
    matches(o1 .. e1, "bare%-idiom%.sh:%d+"), "the window is swallowing unguarded code")

-- COUNTERPART COMPLETENESS: `date -j` is the BSD parse form; an incomplete counterpart list
-- accuses working code.
local _D = "d"
local d_idiom = "date %-" .. _D
for _, cf in ipairs{ "manage-cache.sh", "pre-commit-openspec.sh" } do
    T:arm("COUNTERPART: " .. cf .. "'s GNU-first date chain is not flagged",
        not matches(OUT, cf:gsub("%p", "%%%0") .. ":%d+.*" .. d_idiom), "flagged a correct GNU-first date fallback")
end
-- and the control, planted, under a REPO-RELATIVE root (the .sh's form for this arm).
fs.mkdir(W.rel .. "/counterpart-control/scripts")
fs.write(W.rel .. "/counterpart-control/scripts/planted-bare-date.sh",
    '#!/usr/bin/env bash\nwhen="$(date -' .. _D .. ' yesterday +%Y)"\necho "$when"\n')
local _, o2, e2 = run_guard(W.rel .. "/counterpart-control")
T:arm("COUNTERPART control: a bare GNU date idiom IS still flagged", matches(o2 .. e2, "planted%-bare%-date%.sh:%d+"),
    "the date fallback rule is swallowing bare idioms")

-- REMOTE-CONTEXT CLASS, both directions.
T:arm("REMOTE CONTEXT: a remotely-dispatched string is not flagged", not matches(OUT, "with%-nix%-builder%.sh:%d+"),
    "flagged an idiom executed inside a Linux container")
T:arm("REMOTE CONTEXT control: a bare idiom outside a dispatch IS still flagged",
    matches(OUT, "plan%-binary%-probe%.sh:%d+"), "the remote-context rule is swallowing host code")

-- NEGATIVE CONTROL, CONSTRUCTED (2118-9awa): grep -r over canonical skills/ is not flagged;
-- over a dotted runtime dir (a symlink farm) it is.
fs.mkdir(W.rel .. "/skills-real/scripts"); fs.mkdir(W.rel .. "/skills-real/skills/a")
fs.mkdir(W.rel .. "/skills-farm/scripts"); fs.mkdir(W.rel .. "/skills-farm/.claude/skills/a")
fs.write(W.rel .. "/skills-real/scripts/scan-skills.sh", '#!/usr/bin/env bash\ngrep -rl "token" scripts/ skills/\n')
local farm_dir = ".cla" .. "ude/skills/"
fs.write(W.rel .. "/skills-farm/scripts/scan-skills.sh", '#!/usr/bin/env bash\ngrep -rl "token" scripts/ ' .. farm_dir .. "\n")
local _, o3, e3 = run_guard(W.abs .. "/skills-real")
local _, o4, e4 = run_guard(W.abs .. "/skills-farm")
local real_hit, farm_hit = has(o3 .. e3, "scan-skills.sh"), has(o4 .. e4, "scan-skills.sh")
T:arm("NEGATIVE CONTROL: grep -r over a real skills/ tree is not flagged, over a symlink farm it is (constructed)",
    not real_hit and farm_hit, "real-flagged=" .. tostring(real_hit) .. " farm-flagged=" .. tostring(farm_hit))

-- cost: an advisory that slow gets disabled (1009-gccx).
local t0 = time.now_ms(); run_guard(); local dt = (time.now_ms() - t0) // 1000
T:arm("advisory is cheap (" .. dt .. "s)", dt <= 45, "advisory took " .. dt .. "s")

-- PARITY with the pre-port .sh (1570-g4rx).
local pin = T:run{ "git", "cat-file", "-e", PINNED_SH_SHA .. ":scripts/check-portability-idioms.sh", cwd = ROOT }
if pin.code ~= 0 then
    T:arm("PARITY (skip: pinned .sh unreachable at " .. PINNED_SH_SHA .. " — shallow clone)", true, "")
else
    local corpus = fs.read("scripts/portability/idiom-parity-corpus.txt") or ""
    local cur
    local files = {}
    for _, l in ipairs(text.lines(corpus)) do
        local name = l:match("^=== (%S+)")
        if name then cur = name; files[cur] = files[cur] or {}
        elseif cur then table.insert(files[cur], l) end
    end
    for name, lines in pairs(files) do
        local dir = name:match("^(.*)/[^/]*$")
        if dir then fs.mkdir(W.rel .. "/corpus/" .. dir) else fs.mkdir(W.rel .. "/corpus") end
        fs.write(W.rel .. "/corpus/" .. name, table.concat(lines, "\n") .. "\n")
    end
    local pinned = T:must{ "git", "show", PINNED_SH_SHA .. ":scripts/check-portability-idioms.sh", cwd = ROOT }
    fs.write(W.rel .. "/pinned.sh", pinned.stdout or "")
    local shr = T:run{ SH, W.abs .. "/pinned.sh", cwd = ROOT, env = { TILLANDSIAS_PORTABILITY_ROOT = W.abs .. "/corpus" },
        env_unset = UNSET, timeout_ms = 300000 }
    local sh_out = (shr.stdout or "") .. (shr.stderr or "")
    local _, lua_out, lua_err = run_guard(W.abs .. "/corpus")
    local function entries(s)
        local e = {}
        for _, l in ipairs(text.lines(s)) do if l:sub(1, 4) == "    " then e[#e + 1] = l end end
        table.sort(e); return e
    end
    local se, le = entries(sh_out), entries(lua_err)
    local shv = ""
    for _, l in ipairs(text.lines(sh_out)) do if l:sub(1, 19) == "portability-idioms:" then shv = l; break end end
    local luav = lua_out:gsub("\n$", "")
    local same = #se == #le
    local diffs = {}
    for i = 1, math.max(#se, #le) do
        if se[i] ~= le[i] then same = false; diffs[#diffs + 1] = tostring(se[i]) .. " | " .. tostring(le[i]) end
    end
    local why
    if #se < 10 then why = "the pinned .sh named only " .. #se .. " corpus entries"
    elseif not same then why = "entries differ: " .. table.concat(diffs, " ; "):sub(1, 400)
    elseif luav ~= shv .. " (advisory)" then why = "counts differ — .sh [" .. shv .. "] vs port [" .. luav .. "]" end
    T:arm("PARITY: corpus entries identical to the pinned .sh, counts identical", why == nil, why or "")
end

T:finish()
