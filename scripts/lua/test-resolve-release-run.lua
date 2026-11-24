-- @trace order:601-462g, order:2312-psb3, spec:ci-release
--
-- test-resolve-release-run.lua — the release-run resolver
-- (scripts/resolve-release-run.sh) with a stub gh injected through $GH. A
-- workflow that never started makes `gh run list` print nothing and exit 0;
-- the runbook once walked into `gh run watch ""`. Hermetic: nothing touches
-- GitHub. Ported from test-resolve-release-run.sh (2312-psb3).
--
--   1 no-run-empty-output        "", rc 0   -> blocked:release-run:no-run-for-tag
--   2 no-run-null-output         `null`     -> blocked:release-run:no-run-for-tag
--   3 gh-failed                  "", rc 1   -> blocked:release-run:gh-failed (apart)
--   4 run-resolves               POSITIVE CONTROL -> ok:release-run:<id>
--   5 trailing-newline-tolerated "<id>\n"   -> ok:release-run:<id>
--   6 no-tag-given               no argument -> blocked:release-run:no-tag-given, non-zero
--
-- GRAMMAR ok:release-run-resolver:7 arms | violation:release-run-resolver:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("release-run-resolver")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
local TAG = "v0.4.260813.1"
fs.write(W.rel .. "/gh", "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" > \"$STUB_ARGV\"\ncat \"$STUB_OUT\"\nexit \"$STUB_RC\"\n")
T:must{ "chmod", "+x", W.abs .. "/gh" }

local function resolve(out, rc, ...)
    fs.write(W.rel .. "/out", out)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/resolve-release-run.sh", ... }, timeout_ms = 30000,
        env = { GH = W.abs .. "/gh", STUB_OUT = W.abs .. "/out", STUB_RC = tostring(rc), STUB_ARGV = W.abs .. "/argv" } }
    return (r.status == "exited") and r.code or -1, text.trim((r.stdout or "") .. (r.stderr or ""))
end
local function case(name, out, rc, want_rc, want)
    local code, got = resolve(out, rc, TAG)
    T:arm(name, code == want_rc and got == want, "exit=" .. code .. " expected=" .. want_rc .. " out='" .. got .. "'")
end

case("1 no-run-empty-output", "", 0, 1, "blocked:release-run:no-run-for-tag:" .. TAG)
case("2 no-run-null-output", "null", 0, 1, "blocked:release-run:no-run-for-tag:" .. TAG)
case("3 gh-failed", "", 1, 1, "blocked:release-run:gh-failed:" .. TAG)
case("4 run-resolves", "17482930571", 0, 0, "ok:release-run:17482930571")
-- 5: $(...) already strips a trailing LF, so "id\n" passed with the tr removed (2292-62a5's note on
-- the open-PR twin). Leading space and CR survive the substitution: only tr clears them.
case("5 surrounding-whitespace-tolerated", " 17482930571\r\n", 0, 0, "ok:release-run:17482930571")
local argv = fs.read(W.rel .. "/argv") or ""
T:arm("7 the stub was asked for release.yml workflow_dispatch runs on main",
    text.contains(argv, "--workflow=release.yml") and text.contains(argv, "--event=workflow_dispatch")
        and text.contains(argv, "--branch=main"), "argv=" .. argv)
local code, got = resolve("", 0)
T:arm("6 no-tag-given", code ~= 0 and got == "blocked:release-run:no-tag-given", "exit=" .. code .. " out='" .. got .. "'")
T:finish()
