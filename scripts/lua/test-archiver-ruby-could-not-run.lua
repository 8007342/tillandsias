-- @env PATH HOME XDG_RUNTIME_DIR TOOLBOX_PATH container
-- @trace order:965-sxec, order:2186-niam, order:2367-wtse
--
-- test-archiver-ruby-could-not-run.lua — an absent or unusable ruby makes archive-plan-packets.sh
-- say COULD NOT RUN (exit 3), never a claim about the ready set. Ported from the .sh of the same
-- name (2367-wtse). The unusable ruby is the forge's brew shim: it exits 127 having installed
-- nothing. The positive control runs a one-row ledger in a scratch repository.
--
--   1 exit 3            2 no ready-set claim        3 the instrument and a remedy are named
--   4 CONTROL a host with ruby passes (or says it has none)
--   5 the refusal leaves nothing in this worktree
--
-- Usage: tillandsias-plan script run scripts/lua/test-archiver-ruby-could-not-run.lua
-- Verdict: ok:archiver-ruby-could-not-run:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("archiver-ruby-could-not-run")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local E = { TILLANDSIAS_ARCHIVER_BACKEND = "ruby" }
for _, k in ipairs{ "PATH", "HOME", "XDG_RUNTIME_DIR", "TOOLBOX_PATH", "container" } do E[k] = env.get(k) end
local function dirt()
    return (T:run{ "git", "status", "--porcelain", "--untracked-files=all", "--", "plan_tmp", "plan_tmp_bak", "scripts/archive-plan-packets-check.rb", "toolbox", cwd = ROOT }).stdout or ""
end
local before = dirt()
local stub = T:scratch()
fs.write(stub.rel .. "/ruby", "#!/usr/bin/env bash\necho \"tillandsias: brew install ruby failed (attestation verification is REQUIRED).\" >&2\necho \"tillandsias: 'ruby' is not installed.\" >&2\nexit 127\n")
fs.write(stub.rel .. "/toolbox", "#!/usr/bin/env bash\nexit 1\n")
local r = proc.run{ argv = { SH, "-s", "--", stub.abs }, cwd = ROOT, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000,
    stdin = 'chmod +x "$1"/ruby "$1"/toolbox\nPATH="$1:$PATH"\nexec ./scripts/archive-plan-packets.sh --check </dev/null 2>&1\n' }
local o = (r.stdout or "") .. (r.stderr or "")
local why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 500)
T:arm("1 an unusable ruby is could-not-run, exit 3", r.code == 3, why)
T:arm("2 and claims nothing about the ready set", not text.contains(o, "would CHANGE THE READY SET"), why)
T:arm("3 it names the instrument and a remedy", text.contains(o, "no usable ruby in this locus") and text.contains(o, "Remedy:"), why)

local g = T:git_repo()
T:must{ "cp", "-R", ROOT .. "/scripts", g.abs .. "/scripts" }
fs.mkdir(g.rel .. "/plan/index.d"); fs.mkdir(g.rel .. "/plan/archive")
fs.write(g.rel .. "/plan/index.yaml", "packets:\n  - packet_id: a-one-row-fixture-ledger\n    order: 9999-aaaa\n    status: ready\n    title: one row\n")
E.TILLANDSIAS_ARCHIVER_SKIP_ANSWERABILITY = "1"
if PLAN ~= "" then E.TILLANDSIAS_PLAN_BIN = PLAN end
r = proc.run{ argv = { SH, "scripts/archive-plan-packets.sh", "--check" }, cwd = g.abs, env = E, env_unset = { "TILLANDSIAS_*" }, stdin = "", timeout_ms = 300000 }
o = (r.stdout or "") .. (r.stderr or "")
why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 600)
if r.code == 3 and text.contains(o, "no usable ruby") then
    out.line("skip: 4 this host has no usable ruby in either lane, so the positive control cannot run here")
else
    T:arm("4 CONTROL with a ruby the one-row ledger passes, naming the skipped part", r.code == 0 and text.contains(o, "skip:archiver:answerability:fixture-knob"), why)
end
local after = dirt()
-- State that was there before is not the refusal's doing.
T:arm("5 the refusal leaves nothing in this worktree", after == "" or after == before, before .. " -> " .. after)
T:finish()
