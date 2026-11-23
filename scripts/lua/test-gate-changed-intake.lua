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
--   7b LINT-WINDOWS the same graph with cargo's native-Windows C:\...\Cargo.toml
--                  paths still matches (2253-j2at)
--   8 LINT-MISS    an edge cargo has and the derived graph lacks is refused
--   9 LINT-EXTRA   an edge the derived graph has alone is refused
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

-- 7b (2253-j2at, yolanda msys): cargo metadata on native Windows prints
-- C:\...\Cargo.toml. The same live graph, every path rewritten to that form
-- through the lint's metadata seam, must still match (it read missing=46:extra=46
-- when "/Cargo.toml" was stripped before the separators were normalised).
do
    local mr = proc.run{ argv = { "cargo", "metadata", "--format-version", "1", "--no-deps",
        "--manifest-path", ROOT .. "/Cargo.toml" }, cwd = ROOT, timeout_ms = 300000 }
    local meta = mr.stdout or ""
    local root_s = ROOT:gsub("%%", "%%%%")
    local win = meta:gsub(root_s:gsub("[%-%.%+%[%]%(%)%$%^%?%*]", "%%%0"), "C:\\\\x\\\\repo")
    -- forward slashes inside the rewritten paths become escaped backslashes
    win = win:gsub('("C:\\\\x\\\\repo)([^"]*)"', function(a, b) return a .. b:gsub("/", "\\\\") .. '"' end)
    fs.write(S.rel .. "/meta-windows.json", win)
    local wrc, wo = lint({ TILLANDSIAS_CRATE_GRAPH_METADATA = S.abs .. "/meta-windows.json" })
    T:arm("7b LINT-WINDOWS cargo's C:\\...\\Cargo.toml paths match the derived graph",
        wrc == 0 and text.starts_with(wo, "ok:gate-changed-crate-graph:"), "rc=" .. wrc .. " out=" .. wo)
end

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

T:finish()
