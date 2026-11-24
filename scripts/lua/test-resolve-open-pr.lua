-- @env PATH
-- @trace order:601-462g, order:2298-ifpm, spec:ci-release
--
-- test-resolve-open-pr.lua — the open-PR resolver, ported from the .sh of the same name
-- (2298-ifpm). The breach: with NO open PR, `gh pr list … --jq '.[0].number'` prints the
-- literal `null` and exits 0, so the runbook's emptiness test passed it on as a PR number.
-- Hermetic: a stub gh through $GH; nothing here touches GitHub.
--
--   1 NULL    the literal null refuses as none-open
--   2 EMPTY   an empty answer refuses identically
--   3 FAILED  gh failing is a different fact, named apart
--   4 RESOLVE a real number resolves (positive control)
--   5 SPACE   whitespace around a real number does not defeat it
--   6 ASKED   gh is asked for open PRs of exactly this head into this base
--
-- Usage: tillandsias-plan script run scripts/lua/test-resolve-open-pr.lua
-- Verdict: ok:resolve-open-pr:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("resolve-open-pr")
local SH = fixture.posix_shell()
local RESOLVER = fixture.repo_root() .. "/scripts/resolve-open-pr.sh"
local S = T:scratch()
local function resolve(answer, code)
    fs.write(S.rel .. "/answer", answer)
    fs.write(S.rel .. "/gh", "#!/bin/sh\necho \"$*\" > '" .. S.abs .. "/argv'\ncat '" .. S.abs .. "/answer'\nexit " .. code .. "\n")
    T:must{ "chmod", "+x", S.abs .. "/gh" }
    local r = proc.run{ argv = { SH, RESOLVER, "main", "linux-next" }, timeout_ms = 30000, env = { PATH = env.get("PATH"), GH = S.abs .. "/gh" } }
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end
local function arm(name, answer, code, want_rc, want)
    local c, o = resolve(answer, code)
    T:arm(name, c == want_rc and o == want, "rc=" .. tostring(c) .. " " .. o)
end
local NONE = "blocked:open-pr:none-open:linux-next->main"
arm("1 NULL the literal null refuses as none-open", "null", 0, 1, NONE)
arm("2 EMPTY an empty answer refuses identically", "", 0, 1, NONE)
arm("3 FAILED gh failing is named apart", "", 1, 1, "blocked:open-pr:gh-failed:linux-next->main")
arm("4 RESOLVE a real number resolves", "81", 0, 0, "ok:open-pr:81")
arm("5 SPACE whitespace around a real number does not defeat it", " 81\n", 0, 0, "ok:open-pr:81")
local argv = fs.read(S.rel .. "/argv")
T:arm("6 ASKED gh is asked for open PRs of this head into this base",
    text.contains(argv, "pr list --base main --head linux-next --state open"), argv)
T:finish()
