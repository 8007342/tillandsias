-- @trace order:601-462g, order:2292-62a5, spec:ci-release
--
-- test-resolve-open-pr.lua — the open-PR resolver (601-462g). Ported from the
-- .sh (2292-62a5).
--
-- The breach shape, reproduced with a stub gh: with NO open PR,
-- `gh pr list --json number --jq '.[0].number'` prints the literal `null` and
-- exits 0, so the runbook's emptiness test was false and it announced `PR #null`.
-- Hermetic: every arm injects the stub through $GH; nothing touches GitHub.
--
-- Arm 4 matters most: the others assert refusals, and a resolver that refused
-- everything would satisfy them all.
--
-- Verdict: ok:open-pr-resolver:<n> | violation:open-pr-resolver:<n>

local fixture = require "common.fixture"
local T = fixture.new("open-pr-resolver")
local W = T:scratch()
local SH = fixture.posix_shell()
local RESOLVER = fixture.repo_root() .. "/scripts/resolve-open-pr.sh"

local function resolve(text_out, code)
    fs.write(W.rel .. "/gh.out", text_out)
    fs.write(W.rel .. "/gh", "#!/usr/bin/env bash\n[ \"$*\" = \"pr list --base main --head linux-next --state open --json number --jq .[0].number\" ] || { echo \"unexpected: $*\"; exit 9; }\ncat \"${0%/*}/gh.out\"\nexit " .. code .. "\n")
    T:must{ "chmod", "+x", W.abs .. "/gh" }
    local r = T:run{ SH, RESOLVER, "main", "linux-next", env = { GH = W.abs .. "/gh" }, timeout_ms = 30000 }
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end
local function arm(name, out_text, gh_rc, want_rc, want)
    local rc, o = resolve(out_text, gh_rc)
    T:arm(name, rc == want_rc and o == want, "rc=" .. tostring(rc) .. " [" .. o .. "] want rc=" .. want_rc .. " [" .. want .. "]")
end
arm("1 NULL no open PR printed as the literal null is refused", "null", 0, 1, "blocked:open-pr:none-open:linux-next->main")
arm("2 EMPTY the same absence as nothing at all is refused identically", "", 0, 1, "blocked:open-pr:none-open:linux-next->main")
arm("3 GH-FAILED gh failing is a different fact from gh having nothing to say", "", 1, 1, "blocked:open-pr:gh-failed:linux-next->main")
arm("4 RESOLVES a real PR number resolves", "81", 0, 0, "ok:open-pr:81")
-- A bare newline is stripped by $( ) itself and proves nothing (the .sh's arm 5).
arm("5 SPACE surrounding whitespace, a CR included, does not defeat resolution", " 81\r\n", 0, 0, "ok:open-pr:81")
T:finish()
