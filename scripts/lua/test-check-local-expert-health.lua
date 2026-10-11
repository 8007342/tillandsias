-- @trace order:1584-ik5v
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN PATH
--
-- test-check-local-expert-health.lua — the Lua port of the local-expert health
-- probe answers EXACTLY as the .sh did, line and exit code, on the four inputs
-- that decide it. The endpoint is a stub `curl` first on PATH (no Ollama, no
-- network): it answers by URL, in the mode TILLANDSIAS_FAKE_OLLAMA names.
--
--   mode        expected line                                      rc
--   down        down:local-experts-ollama-unreachable              1
--   nomodel     degraded:local-experts-model-missing:qwen2.5:0.5b  0
--   infail      degraded:local-experts-inference-failed:qwen2.5:0.5b 0
--   healthy     ok:local-experts-healthy                           0
--
-- PARITY: the pre-port .sh (from git: the deletion commit's parent, else the
-- last commit that touched it) runs against the SAME stub and must print the
-- same line with the same exit code in every mode. The stub is a shell script,
-- which native Windows cannot exec by bare name, so on a native Windows host
-- this fixture skips by name; the gate runs it in the Linux builder.

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("local-expert-health-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local u = run({ "uname", "-s" })
local uname = (u.status == "exited" and u.stdout or "")
if u.status ~= "exited" or text.contains(uname, "MINGW") or text.contains(uname, "MSYS") or text.contains(uname, "CYGWIN") then
    verdict.emit("skip:local-expert-health-fixture:native-windows-cannot-exec-a-shell-stub-by-name", 0)
end

local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local REL = "target/plan-scratch/lexp-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/curl", [[#!/bin/sh
# Stub curl for test-check-local-expert-health.lua: the last argument that
# looks like a URL decides the answer, the mode decides which one.
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$TILLANDSIAS_FAKE_OLLAMA" in down) exit 7 ;; esac
case "$url" in
  */api/tags)
    case "$TILLANDSIAS_FAKE_OLLAMA" in
      nomodel) printf '{"models":[{"name":"llama3:8b"}]}\n' ;;
      *) printf '{"models":[{"name":"llama3:8b"},{"name":"qwen2.5:0.5b"}]}\n' ;;
    esac ;;
  */api/generate)
    case "$TILLANDSIAS_FAKE_OLLAMA" in
      infail) exit 22 ;;
      *) printf '{"response":"OK"}\n' ;;
    esac ;;
  *) exit 6 ;;
esac
]])
run({ "chmod", "+x", W .. "/bin/curl" })
local PATHV = W .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin")

-- The pre-port .sh, if this clone's history has it.
local function pinned_sha()
    local d = text.trim(run({ "git", "log", "-n", "1", "--format=%H", "--diff-filter=D", "--", "scripts/check-local-expert-health.sh" }).stdout or "")
    if d ~= "" then return d .. "^" end
    local m = text.trim(run({ "git", "log", "-n", "1", "--format=%H", "--", "scripts/check-local-expert-health.sh" }).stdout or "")
    if m ~= "" then return m end
    return nil
end
local SH
local sha = pinned_sha()
if sha then
    local r = run({ "git", "show", sha .. ":scripts/check-local-expert-health.sh" })
    if r.status == "exited" and r.code == 0 then
        fs.write(REL .. "/pinned.sh", r.stdout)
        SH = W .. "/pinned.sh"
    end
end

local function one_line(s)
    local last = ""
    for _, l in ipairs(text.lines(s or "")) do if l ~= "" then last = l end end
    return last
end
local function probe(argv, mode)
    local r = run(argv, { cwd = ROOT, env = {
        PATH = PATHV, TILLANDSIAS_FAKE_OLLAMA = mode,
        TILLANDSIAS_INFERENCE_ENDPOINT = "http://127.0.0.1:11434",
        TILLANDSIAS_INFERENCE_MODEL = "qwen2.5:0.5b",
    } })
    return one_line(r.stdout), (r.status == "exited" and r.code or -1)
end

local CASES = {
    { "down", "down:local-experts-ollama-unreachable", 1 },
    { "nomodel", "degraded:local-experts-model-missing:qwen2.5:0.5b", 0 },
    { "infail", "degraded:local-experts-inference-failed:qwen2.5:0.5b", 0 },
    { "healthy", "ok:local-experts-healthy", 0 },
}
local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
for _, c in ipairs(CASES) do
    local mode, want, wrc = c[1], c[2], c[3]
    local line, rc = probe({ PLAN, "script", "run", ROOT .. "/scripts/lua/check-local-expert-health.lua" }, mode)
    check("port " .. mode .. ": " .. want .. " rc=" .. wrc, line == want and rc == wrc,
        "got [" .. line .. "] rc=" .. rc)
    if SH then
        local sline, src = probe({ "bash", SH }, mode)
        check("parity " .. mode .. ": the .sh answers the same", sline == line and src == rc,
            ".sh [" .. sline .. "] rc=" .. src .. " vs port [" .. line .. "] rc=" .. rc)
    end
end
if not SH then out.line("note: the pre-port .sh is not in this clone's history; parity arms not run") end

run({ "rm", "-rf", W })
if failed > 0 then
    verdict.emit("refused:local-expert-health-fixture:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:local-expert-health-fixture:" .. passed .. " arms", 0)
