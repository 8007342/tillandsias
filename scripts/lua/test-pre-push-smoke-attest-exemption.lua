-- @env PATH HOME
-- @trace order:2443-r9sm
--
-- test-pre-push-smoke-attest-exemption.lua — the pre-push hook lets a smoke attestation
-- ref through without a gate stamp ONLY in its proven shape, and gates everything else.
--
-- WHY (2443-r9sm). attest-smoke.lua --push was refused by the hook's tree-stamp gate on
-- every host: origin held zero refs/attest/smoke/* on 2026-11-28, so smoke-record.lua had
-- nothing to read and check-promote-gate.lua could pass no tag.
--
-- Each arm runs the REAL hook (this tree's scripts/hooks/pre-push-local-gate.sh, copied
-- into a scratch repo) with one ref line on stdin, and reads whether it printed the
-- exemption line and exited 0.
--   0 PREMISE  trunk's hook without the smoke arm does NOT exempt the good shape (the red)
--   1 CREATE   a 3-file digest tree, created: exempt
--   2 FF       a second attest on top of the first, a fast-forward: exempt
--   3 EXTRA    a fourth file in the tree: gated
--   4 SUBTREE  a directory in the tree: gated
--   5 REWRITE  an update that is not a fast-forward of what origin holds: gated
--   6 DELETE   a deletion: gated
--   7 NAME     a bad platform, or a short sha: gated
--   8 MIXED    the good ref beside a branch in one push: gated (no smuggling)
--
-- Usage: tillandsias-plan script run scripts/lua/test-pre-push-smoke-attest-exemption.lua
-- Verdict: ok:pre-push-smoke-attest-exemption:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("pre-push-smoke-attest-exemption")
local HOOK = "scripts/hooks/pre-push-local-gate.sh"
local EXEMPT = "local gate: coordination marker ref"
local W = T:scratch()
local REPO = W.abs .. "/repo"
fs.mkdir(W.rel .. "/repo/scripts/hooks")

local function git(args, stdin)
    local argv = { "git", "-C", REPO, "-c", "user.name=fixture", "-c", "user.email=fixture@local", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, stdin = stdin, timeout_ms = 30000 })
    return text.trim(r.stdout or ""), r.code
end
git({ "init", "-q", "-b", "linux-next" })
fs.write(W.rel .. "/repo/README", "scratch\n")
git({ "add", "-A" }); git({ "commit", "-qm", "base" })
git({ "update-ref", "refs/remotes/origin/linux-next", "HEAD" })

-- An attest commit built with plumbing: files = { name = body } at top level, dirs = { name = { file = body } }.
local function attest(files, dirs, parent)
    local lines = {}
    for name, body in pairs(files) do
        local h = git({ "hash-object", "-w", "--stdin" }, body)
        lines[#lines + 1] = "100644 blob " .. h .. "\t" .. name
    end
    for name, sub in pairs(dirs or {}) do
        local sl = {}
        for n, b in pairs(sub) do sl[#sl + 1] = "100644 blob " .. git({ "hash-object", "-w", "--stdin" }, b) .. "\t" .. n end
        lines[#lines + 1] = "040000 tree " .. git({ "mktree" }, table.concat(sl, "\n") .. "\n") .. "\t" .. name
    end
    local tree = git({ "mktree" }, table.concat(lines, "\n") .. "\n")
    local args = { "commit-tree", tree, "-m", "attest" }
    if parent then args[#args + 1] = "-p"; args[#args + 1] = parent end
    return (git(args))
end
local GOOD = { ["SHA256SUMS"] = "aa  01-version.txt\n", ["regime.txt"] = "linux-x86_64\n", ["verdict.txt"] = "pass\n" }
local SHA40 = string.rep("6a", 20)
local REF = "refs/attest/smoke/linux/" .. SHA40
local ZERO = string.rep("0", 40)

local function run_hook(hook_body, stdin)
    fs.write(W.rel .. "/repo/" .. HOOK, hook_body)
    local r = proc.run({ argv = { "bash", REPO .. "/" .. HOOK, "origin", "https://example.invalid/repo.git" },
        stdin = stdin, cwd = REPO, timeout_ms = 60000, env = { PATH = env.get("PATH"), HOME = W.abs } })
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code == 0 and text.contains(o, EXEMPT), o
end
local HERE = fs.read(HOOK) or ""
local TRUNK = proc.run({ argv = { "git", "show", "origin/linux-next:" .. HOOK }, timeout_ms = 30000 }).stdout or ""
local function line(lsha, rref, rsha) return "refs/x " .. lsha .. " " .. rref .. " " .. rsha .. "\n" end

local c1 = attest(GOOD)
local c2 = attest({ ["SHA256SUMS"] = "bb  01-version.txt\n", ["regime.txt"] = "linux-x86_64\n", ["verdict.txt"] = "pass\n" }, nil, c1)
local extra = { ["SHA256SUMS"] = GOOD["SHA256SUMS"], ["regime.txt"] = GOOD["regime.txt"], ["verdict.txt"] = GOOD["verdict.txt"], ["01-install.log"] = "log\n" }
local c3 = attest(extra)
local c4 = attest(GOOD, { logs = { ["a.log"] = "x\n" } })
local c5 = attest(GOOD, nil, c4)   -- a good tree whose history does not contain c1 (a parentless twin of c1 would BE c1)

local trunk_has_arm = text.contains(TRUNK, "refs/attest/smoke/*)")
local e, o = run_hook(TRUNK, line(c1, REF, ZERO))
T:arm("0 PREMISE trunk's hook (no smoke arm) does not exempt the good shape", (not trunk_has_arm and not e) or trunk_has_arm, o:sub(1, 300))
e, o = run_hook(HERE, line(c1, REF, ZERO))
T:arm("1 CREATE a 3-file digest tree, created, is exempt", e, o:sub(1, 300))
e, o = run_hook(HERE, line(c2, REF, c1))
T:arm("2 FF a fast-forward of the attest origin holds is exempt", e, o:sub(1, 300))
e, o = run_hook(HERE, line(c3, REF, ZERO))
T:arm("3 EXTRA a fourth file in the tree is gated", not e, o:sub(1, 300))
e, o = run_hook(HERE, line(c4, REF, ZERO))
T:arm("4 SUBTREE a directory in the tree is gated", not e, o:sub(1, 300))
e, o = run_hook(HERE, line(c5, REF, c1))
T:arm("5 REWRITE an update that is not a fast-forward is gated", not e, o:sub(1, 300))
e, o = run_hook(HERE, line(ZERO, REF, c1))
T:arm("6 DELETE a deletion is gated", not e, o:sub(1, 300))
local e1 = run_hook(HERE, line(c1, "refs/attest/smoke/plan9/" .. SHA40, ZERO))
local e2 = run_hook(HERE, line(c1, "refs/attest/smoke/linux/6a242328", ZERO))
T:arm("7 NAME a bad platform or a short sha is gated", not e1 and not e2)
local head = git({ "rev-parse", "HEAD" })
e, o = run_hook(HERE, line(c1, REF, ZERO) .. line(head, "refs/heads/linux-next", ZERO))
T:arm("8 MIXED the good ref beside a branch in one push is gated", not e, o:sub(1, 300))
T:finish()
