-- @env PATH HOME
-- inputs: build.sh scripts/build-guest-binaries.sh scripts/check-plan-binary-current.sh scripts/check-stranded-in-progress.sh scripts/gate-stamp.sh scripts/hooks/pre-push-local-gate.sh scripts/lib-env-forward.sh scripts/lib-wsl-capture.sh scripts/local-ci.sh scripts/lua/check-cross-target-build.lua scripts/lua/test-wsl2-src-mirror-default.lua scripts/plan-binary-probe.sh scripts/run-litmus-test.sh scripts/with-tillandsias-builder.sh scripts/with-wsl2-builder.sh scripts/wsl2-build-memory-cap.sh scripts/wsl2-build-target-prune.sh scripts/wsl2-src-mirror.sh scripts/wsl-guest-session.sh VERSION lib/lua/common/ crates/tillandsias-plan/
-- @trace order:2415-gntr
--
-- test-wsl2-forward-relative-paths.lua — with-wsl2-builder.sh's two path-relating lines (_W2_SESSION,
-- SCRIPT_REL) yield RELATIVE paths when the cwd is spelled C:/... and the script dir /c/....
-- Before 2415-gntr realpath could not relate the spellings and returned an absolute /c/ path,
-- which the WSL2 guest cannot open (rc=127 on every build.sh forward).
--
--   1 _W2_SESSION is scripts/wsl-guest-session.sh      2 SCRIPT_REL is build.sh
--
-- msys only (the file is sourced only on Windows); elsewhere a named skip.
-- Usage: tillandsias-plan script run scripts/lua/test-wsl2-forward-relative-paths.lua
-- Verdict: ok:wsl2-forward-relative-paths:<n> arms | violation:...:<n>-failed | skip:...:not-msys

local fixture = require "common.fixture"
local T = fixture.new("wsl2-forward-relative-paths")
local SH = fixture.posix_shell()
if SH == "bash" then T:skip("not-msys") end
local ROOT = fixture.repo_root()
local W = T:scratch()

local src = fs.read("scripts/with-wsl2-builder.sh"):gsub("\r", "")
local function line(prefix)
    for l in (src .. "\n"):gmatch("([^\n]*)\n") do if l:sub(1, #prefix) == prefix then return l end end
    T:refuse("line-not-found:" .. prefix)
end
fs.mkdir(W.rel .. "/tree/scripts")
fs.write(W.rel .. "/tree/scripts/lines.sh", line("_W2_SESSION=") .. "\n" .. line("SCRIPT_REL=") .. "\n"
    .. 'printf "session=%s\nscript=%s\n" "$_W2_SESSION" "$SCRIPT_REL"\n')
fs.write(W.rel .. "/tree/build.sh", '. "$(dirname "$0")/scripts/lines.sh"\n')
-- The trigger, measured on doris: Git's bin/bash.exe wrapper, started from an msys shell, reports
-- pwd as C:/... while the script is reached as /c/.... So an msys shell (cd'd into the tree) runs
-- the wrapper on the script by its /c/ path, as a developer's `bash ./build.sh` does.
local r = T:run{ SH, "-s", "--", W.abs .. "/tree", SH, cwd = ROOT, stdin = [[
u="$(cygpath -u "$1")"; cd "$u" || exit 90
"$2" "$u/build.sh"
]] }
local o = r.stdout or ""
T:arm("1 _W2_SESSION is relative (scripts/wsl-guest-session.sh)", text.contains(o, "session=scripts/wsl-guest-session.sh\n"), o .. (r.stderr or ""))
T:arm("2 SCRIPT_REL is relative (build.sh)", text.contains(o, "script=build.sh\n"), o .. (r.stderr or ""))
T:finish()
