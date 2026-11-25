-- @env PATH HOME
-- @trace order:764-sunk, spec:dev-build, order:2344-64wz
--
-- test-wsl2-builder-shell-options.lua — sourcing scripts/with-wsl2-builder.sh hands the caller back
-- exactly the shell options it entered with. Ported from the .sh of the same name. An
-- unconditional `set -euo pipefail` re-armed errexit in local-ci.sh, which runs without it on
-- purpose (the 731-pc5r leak). The restore may only REMOVE what the caller lacked.
--
-- uname is stubbed, so every host drives all three sourced return sites: the uname guard, --floor
-- and TILLANDSIAS_SKIP_WSL2. The .sh reached only the one its own host takes.
--
-- Usage: tillandsias-plan script run scripts/lua/test-wsl2-builder-shell-options.lua
-- Verdict: ok:wsl2-builder-shell-options:<n> arms | violation:wsl2-builder-shell-options:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("wsl2-builder-shell-options")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local WRAPPER = "scripts/with-wsl2-builder.sh"
if not fs.exists(WRAPPER) then T:refuse("wrapper-missing", WRAPPER) end
local W = T:scratch()

local SITES = {
    { "uname guard", "Linux", "", "" },
    { "--floor", "MINGW64_NT", "", " --floor" },
    { "skip", "MINGW64_NT", "export TILLANDSIAS_SKIP_WSL2=1\n", "" },
}
-- What the caller has after sourcing: "<e?><u?><p?> <leaked bookkeeping>", "-" for an option off.
local function after(site, set, wrapper)
    local r = T:run{ SH, "-s", cwd = ROOT, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, stdin = 'uname() { echo "' .. site[2] .. '"; }\n' .. site[3]
        .. set .. "\nsource ./" .. (wrapper or WRAPPER) .. site[4] .. " </dev/null\n"
        .. 'F="$-"; P=-; [[ -o pipefail ]] && P=p\nL="${_W2_CALLER_FLAGS:+leak}${_W2_CALLER_PIPEFAIL:+leak}"\n'
        .. 'set +eu\nE=-; [[ "$F" == *e* ]] && E=e\nU=-; [[ "$F" == *u* ]] && U=u\necho "after:$E$U$P:$L"\n' }
    return (r.stdout or ""):match("after:(%S*)") or ("rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end
local CALLERS = {
    { "a caller with none keeps none", "set +e; set +u; set +o pipefail", "---:" },
    { "a caller with all keeps all", "set -e; set -u; set -o pipefail", "eup:" },
    { "a caller with -e only keeps -e only", "set -e; set +u; set +o pipefail", "e--:" },
    { "a caller with pipefail only keeps it only", "set +e; set +u; set -o pipefail", "--p:" },
}
for _, site in ipairs(SITES) do
    for _, c in ipairs(CALLERS) do
        local got = after(site, c[2])
        T:arm(site[1] .. ": " .. c[1] .. ", nothing leaks", got == c[3], got)
    end
end

-- MUTATION: without the restore calls the caller is left with the helper's own options.
local src = fs.read(WRAPPER):gsub("\r\n", "\n")
local mutant, n = src:gsub("|| _w2_restore_caller_opts\n", "|| :\n")
if n ~= #SITES then T:refuse("mutation-anchor-count", tostring(n) .. " restore calls, " .. #SITES .. " sites") end
fs.write(W.rel .. "/wrapper.sh", mutant)
for _, site in ipairs(SITES) do
    local got = after(site, CALLERS[1][2], W.rel .. "/wrapper.sh")
    T:arm("MUTATION " .. site[1] .. ": without its restore the caller ends up strict", got == "eup:leakleak", got)
end

T:finish()
