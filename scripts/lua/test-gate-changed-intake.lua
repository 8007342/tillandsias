-- @trace order:2248-zcqh, order:1916-tsel
--
-- test-gate-changed-intake.lua — pins `scripts/gate-changed.sh --intake`, the
-- bundle-landing intake gate (operator-approved 2026-11-22), and the lint that
-- holds its crate graph to cargo's. Every arm feeds a changed-path list through
-- --files, so no arm depends on this ref's own diff.
--
--   1 DEFER-STAR   whole-tree readers (inputs "*") are deferred, named
--                  (whole-tree) on ONE deferred: line, and intake's run set
--                  plus its deferred set is exactly the legacy selection
--   2 DEFER-SLOW   a fixture declaring `preflight: gate-only — <reason>` is
--                  deferred (slow), not run
--   3 HEAVY-LIST   an unscopable change (a guard file) prints heavy:<reason>
--                  and no selection
--   4 HEAVY-RUN    with --run it exits 10 and runs nothing
--   5 LEGACY       without --intake the lines are today's: select:scoped /
--                  select:all, no deferred: and no heavy:
--   6 WORKSPACE    the derived graph resolves `{ workspace = true }` deps
--                  (podman -> core) and skips commented-out ones
--                  (host-shell -/-> vault-client). Before 2248-zcqh both were
--                  wrong: 13 of cargo's 46 edges missing, 1 extra
--   7 LINT-OK      check-gate-changed-crate-graph.lua passes on the live tree
--   8 LINT-MISS    an edge cargo has and the derived graph lacks is refused
--   9 LINT-EXTRA   an edge the derived graph has alone is refused
--  10 BUILD-BLOCK  (2250-gwfy) a build.sh diff that only adds a wired fixture
--                  block inside --check is scoped, not heavy, and selects the
--                  fixture it wires (because=build.sh-block)
--  11 BUILD-MACH   the same diff plus one non-block line (a variable) stays
--                  heavy:guard:build.sh
--  12 BUILD-LEGACY without --intake the block-only diff is still select:all
--  13 SERIAL       (2256-mvmy) in a scratch tree, two inline build.sh fixtures
--                  and a STEP_SERIAL step never overlap under --intake --run,
--                  and a phase:serial-fixtures line counts them (3)
--  14 POOL-CONTROL the same tree without --intake runs the inline pair side
--                  by side (NEGATIVE CONTROL: arm 13 can tell)
--  15 PLAN-LANE    a plan-only diff prints route:plan-lane and selects no
--                  fixture
--
-- Verdict: ok:gate-changed-intake:<n> arms | violation:gate-changed-intake:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-changed-intake")
local ROOT = fixture.repo_root()
local GC = ROOT .. "/scripts/gate-changed.sh"
local LINT = ROOT .. "/scripts/lua/check-gate-changed-crate-graph.lua"
-- Git's bash on native Windows (common.fixture.posix_shell() once 2246-fkea
-- lands; inline until then).
local SH = "bash"
do
    local ep = text.trim(proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }.stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then SH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) end
end
local probe = proc.run{ argv = { SH, "-s" }, cwd = ROOT, timeout_ms = 60000,
    stdin = '. scripts/plan-binary-probe.sh\np="$(resolve_plan_binary 2>/dev/null)" || p=""\nprintf "%s" "$p"\n' }
local PB = text.trim(probe.stdout or "")
if PB:sub(1, 2) == "./" then PB = ROOT .. "/" .. PB:sub(3) end
if PB == "" then T:refuse("no-plan-binary", "plan-binary-probe resolved nothing") end

local S = T:scratch("changes")
local function changes(tag, paths)
    fs.write(S.rel .. "/" .. tag, table.concat(paths, "\n") .. "\n")
    return S.abs .. "/" .. tag
end
local function gc(args)
    local argv = { SH, GC }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 600000 }
    return (r.status == "exited" and r.code or -1), (r.stdout or "")
end
local function first(out, prefix)
    for _, l in ipairs(text.lines(out)) do if text.starts_with(l, prefix) then return l end end
    return nil
end
local function count(out, prefix)
    local n = 0
    for _, l in ipairs(text.lines(out)) do if text.starts_with(l, prefix) then n = n + 1 end end
    return n
end

local ONE = changes("one", { "scripts/rank-refusal-hits.sh" })
local SLOW = changes("slow", { "scripts/test-token-instrument.sh" })
local GUARD = changes("guard", { "build.sh" })

-- 1
local rc, o = gc{ "--list", "--intake", "--files", ONE }
local _, legacy = gc{ "--list", "--files", ONE }
local def = first(o, "deferred:") or ""
local ndef = tonumber(def:match("^deferred: n=(%d+)") or "") or -1
local _, stars = def:gsub("%(whole%-tree%)", "")
local nlegacy = tonumber((first(legacy, "select:scoped") or ""):match("fixtures=(%d+)/") or "") or -2
local nrun = count(o, "select:fixture:")
T:arm("1 DEFER-STAR whole-tree readers are deferred on one line, and run + deferred = the legacy selection",
    rc == 0 and count(o, "deferred:") == 1 and stars > 0 and nrun + ndef == nlegacy,
    "rc=" .. rc .. " run=" .. nrun .. " deferred=" .. ndef .. " whole-tree=" .. stars .. " legacy=" .. nlegacy)

-- 2
rc, o = gc{ "--list", "--intake", "--files", SLOW }
def = first(o, "deferred:") or ""
T:arm("2 DEFER-SLOW a gate-only fixture is deferred (slow), not run",
    rc == 0 and def:find("scripts/test-token-instrument.sh(slow)", 1, true) ~= nil
        and not o:find("select:fixture:scripts/test-token-instrument.sh", 1, true),
    "rc=" .. rc .. " " .. def:sub(1, 300))

-- 3, 4
rc, o = gc{ "--list", "--intake", "--files", GUARD }
T:arm("3 HEAVY-LIST a guard-file change prints heavy:<reason> and no selection",
    rc == 0 and (first(o, "heavy:guard:build.sh") ~= nil) and count(o, "select:") == 0,
    "rc=" .. rc .. " out=" .. o:sub(1, 300))
rc, o = gc{ "--run", "--intake", "--files", GUARD }
T:arm("4 HEAVY-RUN with --run it exits 10 and runs nothing",
    rc == 10 and first(o, "heavy:") ~= nil and count(o, "ok:gate-changed") == 0 and count(o, "fail:gate-changed") == 0,
    "rc=" .. rc .. " out=" .. o:sub(1, 300))

-- 5
local _, lg = gc{ "--list", "--files", GUARD }
T:arm("5 LEGACY without --intake: select:scoped / select:all, never deferred: or heavy:",
    first(legacy, "select:scoped") ~= nil and count(legacy, "deferred:") == 0 and count(legacy, "select:intake") == 0
        and first(lg, "select:all reason=guard:build.sh") ~= nil and count(lg, "heavy:") == 0,
    "one=" .. (first(legacy, "select:") or "") .. " guard=" .. (first(lg, "") or ""))

-- 6
local _, graph = gc{ "--crate-graph" }
local has = {}
for _, l in ipairs(text.lines(graph)) do has[l] = true end
T:arm("6 WORKSPACE workspace-inherited deps resolve; commented-out ones do not",
    has["crates/tillandsias-podman\tcrates/tillandsias-core"] == true
        and has["crates/tillandsias-host-shell\tcrates/tillandsias-vault-client"] == nil,
    "podman->core=" .. tostring(has["crates/tillandsias-podman\tcrates/tillandsias-core"])
        .. " host-shell->vault-client=" .. tostring(has["crates/tillandsias-host-shell\tcrates/tillandsias-vault-client"]))

-- 7, 8, 9
local function lint(env)
    local r = proc.run{ argv = { PB, "script", "run", LINT }, cwd = ROOT, env = env, timeout_ms = 600000 }
    return (r.status == "exited" and r.code or -1), text.trim(r.stdout or "")
end
rc, o = lint({})
T:arm("7 LINT-OK the derived graph equals cargo's on the live tree",
    rc == 0 and text.starts_with(o, "ok:gate-changed-crate-graph:"), "rc=" .. rc .. " out=" .. o)

local lines = {}
for _, l in ipairs(text.lines(graph)) do if l ~= "" then lines[#lines + 1] = l end end
local short = {}
for i = 2, #lines do short[#short + 1] = lines[i] end
fs.write(S.rel .. "/graph-missing", table.concat(short, "\n") .. "\n")
rc, o = lint({ TILLANDSIAS_CRATE_GRAPH_DERIVED = S.abs .. "/graph-missing" })
T:arm("8 LINT-MISS an edge only cargo has is refused",
    rc == 1 and o == "violation:gate-changed-crate-graph:missing=1:extra=0", "rc=" .. rc .. " out=" .. o)

fs.write(S.rel .. "/graph-extra", table.concat(lines, "\n") .. "\ncrates/tillandsias-core\tcrates/tillandsias-headless\n")
rc, o = lint({ TILLANDSIAS_CRATE_GRAPH_DERIVED = S.abs .. "/graph-extra" })
T:arm("9 LINT-EXTRA an edge only the derived graph has is refused",
    rc == 1 and o == "violation:gate-changed-crate-graph:missing=0:extra=1", "rc=" .. rc .. " out=" .. o)

-- 10-12: a synthetic build.sh diff inserted at a line inside --check.
local lo, hi
for i, l in ipairs(text.lines(fs.read("build.sh") or "")) do
    if not lo and l == 'if [[ "$FLAG_CHECK" == true ]]; then' then lo = i end
    if lo and not hi and text.starts_with(l, 'elif [[ "$FLAG_TEST$FLAG_CHECK') then hi = i end
end
local at = lo and math.floor((lo + hi) / 2) or 0
local FX = "scripts/lua/test-gate-changed-intake.lua"
local block = {
    "+    # a wired block, the shape most build.sh edits take",
    '+    _step "Checking a planted block (2250-gwfy fixture)..."',
    '+    if ! _run_lua_decider "' .. FX .. '" 2>&1; then',
    '+        _error "planted block failed"',
    "+        exit 1",
    "+    fi",
    '+    _info "planted block passed"',
}
local function diff_file(tag, extra)
    local lines = { "diff --git a/build.sh b/build.sh", "--- a/build.sh", "+++ b/build.sh",
        "@@ -" .. at .. ",0 +" .. (at + 1) .. "," .. (#block + #extra) .. " @@" }
    for _, l in ipairs(block) do lines[#lines + 1] = l end
    for _, l in ipairs(extra) do lines[#lines + 1] = l end
    fs.write(S.rel .. "/" .. tag, table.concat(lines, "\n") .. "\n")
    return S.abs .. "/" .. tag
end
local function gc_env(args, env)
    local argv = { SH, GC }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 600000, env = env }
    return (r.status == "exited" and r.code or -1), (r.stdout or "")
end
local BONLY = changes("build-only", { "build.sh" })
rc, o = gc_env({ "--list", "--intake", "--files", BONLY }, { TILLANDSIAS_GATE_CHANGED_BUILD_DIFF = diff_file("bd-block", {}) })
T:arm("10 BUILD-BLOCK a block-only build.sh diff is scoped and selects the fixture it wires",
    rc == 0 and first(o, "select:intake") ~= nil and count(o, "heavy:") == 0
        and (o:find("select:fixture:" .. FX .. " because=", 1, true) ~= nil),
    "rc=" .. rc .. " at=" .. at .. " " .. (first(o, "select:") or first(o, "heavy:") or o:sub(1, 200)))
rc, o = gc_env({ "--list", "--intake", "--files", BONLY }, { TILLANDSIAS_GATE_CHANGED_BUILD_DIFF = diff_file("bd-mach", { "+    _planted_state=1" }) })
T:arm("11 BUILD-MACH one non-block line keeps build.sh a guard (heavy)",
    rc == 0 and first(o, "heavy:guard:build.sh") ~= nil, "rc=" .. rc .. " " .. (first(o, "") or ""))
rc, o = gc_env({ "--list", "--files", BONLY }, { TILLANDSIAS_GATE_CHANGED_BUILD_DIFF = diff_file("bd-legacy", {}) })
T:arm("12 BUILD-LEGACY without --intake a block-only build.sh diff is still select:all",
    rc == 0 and first(o, "select:all reason=guard:build.sh") ~= nil, "rc=" .. rc .. " " .. (first(o, "") or ""))

-- 13-14: a scratch tree whose fixtures log their own start/end.
do
    local X = T:scratch("serial-tree")
    local function w(rel, body) fs.write(X.rel .. "/" .. rel, body) end
    proc.run{ argv = { "mkdir", "-p", X.abs .. "/scripts/gate-steps.d" } }
    w("Cargo.toml", "[workspace]\nmembers = [\n]\n")
    w("scripts/shared.txt", "x\n")
    local function fx(name)
        w("scripts/test-" .. name .. ".sh", table.concat({
            "#!/usr/bin/env bash", 'cat "$(dirname "$0")/../scripts/shared.txt" >/dev/null',
            'echo "start ' .. name .. ' $(date +%s%N)" >> "$SERIAL_LOG"', "sleep 1",
            'echo "end ' .. name .. ' $(date +%s%N)" >> "$SERIAL_LOG"', "exit 0", "" }, "\n"))
    end
    for _, n in ipairs({ "a", "b", "c", "d" }) do fx(n) end
    local blk = {}
    for _, n in ipairs({ "a", "b" }) do
        blk[#blk + 1] = '    _step "Inline ' .. n .. '..."'
        blk[#blk + 1] = '    if ! _run bash "$SCRIPT_DIR/scripts/test-' .. n .. '.sh" 2>&1; then'
        blk[#blk + 1] = '        _error "' .. n .. '"'
        blk[#blk + 1] = "        exit 1"
        blk[#blk + 1] = "    fi"
    end
    w("build.sh", 'if [[ "$FLAG_CHECK" == true ]]; then\n' .. table.concat(blk, "\n")
        .. '\nelif [[ "$FLAG_TEST$FLAG_CHECK" == x ]]; then\n    :\nfi\n')
    w("scripts/gate-steps.d/100-c.step", 'STEP_DESC="c"\nSTEP_SCRIPT="scripts/test-c.sh"\nSTEP_SERIAL="planted serial step"\n')
    w("scripts/gate-steps.d/110-d.step", 'STEP_DESC="d"\nSTEP_SCRIPT="scripts/test-d.sh"\n')
    T:must{ "git", "init", "-q", X.abs }
    T:must{ "git", "-C", X.abs, "add", "-A" }
    T:must{ "git", "-C", X.abs, "-c", "user.email=f@f", "-c", "user.name=f", "-c", "commit.gpgsign=false", "commit", "-qm", "tree" }
    fs.write(S.rel .. "/serial-changed", "scripts/shared.txt\n")
    local function run_tree(intake, logname)
        fs.write(S.rel .. "/" .. logname, "")
        local argv = { SH, GC, "--run" }
        if intake then argv[#argv + 1] = "--intake" end
        argv[#argv + 1] = "--files"; argv[#argv + 1] = S.abs .. "/serial-changed"
        local r = proc.run{ argv = argv, cwd = X.abs, timeout_ms = 300000,
            env = { TILLANDSIAS_GATE_CHANGED_ROOT = X.abs, SERIAL_LOG = S.abs .. "/" .. logname, GATE_CHANGED_JOBS = "4" } }
        local iv = {}
        for _, l in ipairs(text.lines(fs.read(S.rel .. "/" .. logname) or "")) do
            local k, n, t = l:match("^(%a+) (%a) (%d+)$")
            if k then iv[n] = iv[n] or {}; iv[n][k] = tonumber(t) end
        end
        return r, iv
    end
    local function overlap(iv, a, b)
        local x, y = iv[a], iv[b]
        if not (x and y and x.start and x["end"] and y.start and y["end"]) then return nil end
        return x.start < y["end"] and y.start < x["end"]
    end
    local r13, iv13 = run_tree(true, "serial-intake.log")
    local o13 = (r13.stdout or "")
    local sline = first(o13, "phase:serial-fixtures") or ""
    T:arm("13 SERIAL inline fixtures and a STEP_SERIAL step never overlap at intake",
        overlap(iv13, "a", "b") == false and overlap(iv13, "a", "c") == false and overlap(iv13, "b", "c") == false
            and sline:find(" n=3", 1, true) ~= nil,
        "a/b=" .. tostring(overlap(iv13, "a", "b")) .. " a/c=" .. tostring(overlap(iv13, "a", "c"))
            .. " b/c=" .. tostring(overlap(iv13, "b", "c")) .. " " .. sline .. " out=" .. o13:sub(1, 300))
    local r14, iv14 = run_tree(false, "serial-legacy.log")
    T:arm("14 POOL-CONTROL without --intake the inline pair runs side by side",
        overlap(iv14, "a", "b") == true, "a/b=" .. tostring(overlap(iv14, "a", "b")) .. " out=" .. (r14.stdout or ""):sub(1, 300))
end

-- 15: a plan-only diff goes to the plan lane.
local PLANONLY = changes("plan-only", { "plan/index.d/README.md" })
rc, o = gc{ "--list", "--intake", "--files", PLANONLY }
local _, ro = gc_env({ "--run", "--intake", "--files", PLANONLY }, {})
T:arm("15 PLAN-LANE a plan-only diff routes to the plan lane and selects no fixture",
    first(ro, "route:plan-lane") ~= nil and count(ro, "ok:gate-changed:fixture:") == 0
        and (first(ro, "ok:gate-changed:intake:plan-lane") ~= nil or first(ro, "fail:gate-changed:intake:plan-lane") ~= nil),
    "out=" .. ro:sub(1, 400))

T:finish()
