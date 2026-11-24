-- @trace order:601-462g, order:2312-psb3, spec:ci-release
--
-- test-resolve-open-pr.lua — the open-PR resolver (scripts/resolve-open-pr.sh)
-- with a stub gh injected through $GH. With NO open PR, `gh pr list --jq
-- '.[0].number'` prints the literal `null` and exits 0; the runbook once read
-- that as a PR number and announced `PR #null`. Hermetic: nothing touches
-- GitHub. Ported from test-resolve-open-pr.sh (2312-psb3).
--
--   1 no-pr-null-output          `null`, rc 0 -> blocked:open-pr:none-open
--   2 no-pr-empty-output         "", rc 0     -> blocked:open-pr:none-open
--   3 gh-failed                  "", rc 1     -> blocked:open-pr:gh-failed (retryable, apart)
--   4 pr-resolves                POSITIVE CONTROL: 81 -> ok:open-pr:81
--   5 trailing-newline-tolerated "81\n"       -> ok:open-pr:81
--
-- GRAMMAR ok:open-pr-resolver:5 arms | violation:open-pr-resolver:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("open-pr-resolver")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
fs.write(W.rel .. "/gh", "#!/usr/bin/env bash\ncat \"$STUB_OUT\"\nexit \"$STUB_RC\"\n")
T:must{ "chmod", "+x", W.abs .. "/gh" }

local function case(name, out, rc, want_rc, want)
    fs.write(W.rel .. "/out", out)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/resolve-open-pr.sh", "main", "linux-next" }, timeout_ms = 30000,
        env = { GH = W.abs .. "/gh", STUB_OUT = W.abs .. "/out", STUB_RC = tostring(rc) } }
    local got = text.trim((r.stdout or "") .. (r.stderr or ""))
    local code = (r.status == "exited") and r.code or -1
    T:arm(name, code == want_rc and got == want, "exit=" .. code .. " expected=" .. want_rc .. " out='" .. got .. "'")
end

case("1 no-pr-null-output", "null", 0, 1, "blocked:open-pr:none-open:linux-next->main")
case("2 no-pr-empty-output", "", 0, 1, "blocked:open-pr:none-open:linux-next->main")
case("3 gh-failed", "", 1, 1, "blocked:open-pr:gh-failed:linux-next->main")
case("4 pr-resolves", "81", 0, 0, "ok:open-pr:81")
case("5 trailing-newline-tolerated", "81\n", 0, 0, "ok:open-pr:81")
T:finish()
