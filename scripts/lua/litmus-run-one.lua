-- @trace order:2096-y7sx, order:956-llei
-- @env-profile podman
--
-- litmus-run-one.lua — run ONE litmus file through the real runner, by path.
-- Ported from scripts/litmus-run-one.sh (family B, operator ruling 2026-11-17:
-- the unreferenced shell scripts go; Lua first).
--
-- The runner selects by SPEC (the positional filter resolves through
-- openspec/litmus-bindings.yaml), so a single test cannot be asked for by
-- name, an unbound test cannot be run at all, and a test bound under an
-- obsolete spec is unreachable. This builds a scratch project root under
-- target/ (the top level of the tree symlinked in, a one-entry bindings file,
-- the one test) and runs the real runner there, so the verdict is the
-- runner's verdict, not a hand re-execution of the step commands.
--
-- USAGE
--   tillandsias-plan script run scripts/lua/litmus-run-one.lua --timeout 60m \
--       -- openspec/litmus-tests/litmus-foo.yaml [runner args...]
-- Phase defaults to the file's own `phase:` unless --phase is passed, so a
-- retired test asked for by path still runs (that is the explicit ask).
--
-- GRAMMAR (last line on stdout; the runner's own output is printed above it)
--   ok:litmus-run-one:<name>                      exit 0  the runner passed
--   violation:litmus-run-one:<name>:rc=<n>        exit 1  the runner failed
--   blocked:litmus-run-one:usage|no-name-spec     exit 2  nothing was run
--   could-not-run:litmus-run-one:<step>           exit 3  scratch root not built

local function run(argv, cwd, timeout_ms)
    return proc.run({ argv = argv, cwd = cwd, timeout_ms = timeout_ms or 30000 })
end

local function must(step, argv, cwd)
    local r = run(argv, cwd)
    if r.status ~= "exited" or r.code ~= 0 then
        io.stderr:write(step .. ": " .. (r.stderr or "") .. "\n")
        verdict.emit("could-not-run:litmus-run-one:" .. step, 3)
    end
    return (r.stdout or ""):gsub("%s+$", "")
end

local file = arg and arg[1]
if not file or file == "" then
    io.stderr:write("usage: litmus-run-one.lua -- <litmus-file.yaml> [runner args...]\n")
    verdict.emit("blocked:litmus-run-one:usage", 2)
end

local root = must("repo-root", { "git", "rev-parse", "--show-toplevel" })
local ok_read, src = pcall(fs.read, file)
if not ok_read or not src then
    io.stderr:write("usage: " .. file .. " is not a readable file in this repository\n")
    verdict.emit("blocked:litmus-run-one:usage", 2)
end
local doc = yaml.parse(src) or {}
local name, spec, phase = doc.name, doc.spec, doc.phase
if type(name) ~= "string" or type(spec) ~= "string" or name == "" or spec == "" then
    io.stderr:write("refused: " .. file .. " declares no name:/spec:\n")
    verdict.emit("blocked:litmus-run-one:no-name-spec", 2)
end

fs.mkdir("target")
local tmp = must("mktemp", { "mktemp", "-d", root .. "/target/litmus-run-one.XXXXXX" })
local function cleanup() run({ "rm", "-rf", "--", tmp }) end

local function ls(dir)
    local names = {}
    for b in must("list:" .. dir, { "ls", "-A", root .. "/" .. dir }):gmatch("[^\n]+") do
        names[#names + 1] = b
    end
    return names
end

local function link(src_path, dst)
    run({ "ln", "-s", src_path, dst })
end

must("mkdir", { "mkdir", "-p", tmp .. "/openspec/litmus-tests", tmp .. "/methodology", tmp .. "/target" })
-- Steps run with the scratch root as cwd; relative paths in step commands must
-- still reach the real tree, so mirror the top level (dotfiles included).
local skip_top = { scripts = true, methodology = true, openspec = true, target = true }
for _, b in ipairs(ls(".")) do
    if not skip_top[b] then
        link(root .. "/" .. b, tmp .. "/" .. b)
    end
end
link(root .. "/scripts", tmp .. "/scripts")
for _, b in ipairs(ls("openspec")) do
    if b ~= "litmus-tests" and b ~= "litmus-bindings.yaml" then
        link(root .. "/openspec/" .. b, tmp .. "/openspec/" .. b)
    end
end
for _, b in ipairs(ls("methodology")) do
    link(root .. "/methodology/" .. b, tmp .. "/methodology/" .. b)
end

local rel_tmp = tmp:sub(#root + 2)
fs.write(rel_tmp .. "/openspec/litmus-tests/" .. path.basename(file), src)
fs.write(rel_tmp .. "/openspec/litmus-bindings.yaml", table.concat({
    "specs:",
    "  - spec_id: " .. spec,
    "    status: active",
    "    litmus_tests:",
    "      - " .. name,
    "",
}, "\n"))

local argv = { "bash", tmp .. "/scripts/run-litmus-test.sh", spec }
local has_phase = false
for i = 2, #arg do
    argv[#argv + 1] = arg[i]
    if arg[i] == "--phase" then has_phase = true end
end
if not has_phase and type(phase) == "string" and phase ~= "" then
    argv[#argv + 1] = "--phase"
    argv[#argv + 1] = phase
end
io.stderr:write("litmus-run-one: " .. name .. " (spec " .. spec .. ", phase "
    .. tostring(phase or "unset") .. ") via " .. tmp .. "\n")

local r = run(argv, tmp, 4 * 3600 * 1000)
io.stdout:write(r.stdout or "")
io.stderr:write(r.stderr or "")
cleanup()
if r.status == "exited" and r.code == 0 then
    verdict.ok("litmus-run-one", name)
end
verdict.emit("violation:litmus-run-one:" .. name .. ":rc=" .. tostring(r.code or r.status), 1)
