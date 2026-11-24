-- @env PATH
-- @trace spec:install-progress, spec:linux-native-portable-executable, order:2316-6kzg
--
-- test-install-path.lua — the installer's PATH setup, through install.sh's test mode, with
-- HOME in scratch: nothing is installed. Ported from the .sh of the same name (2316-6kzg).
--
--   1 PROFILE  bash: two runs leave one block and one export line in .profile and .bashrc
--   2 USERBIN  a safe user bin already on PATH is the install dir
--   3 DEFAULT  with none on PATH the install dir is ~/.local/bin (new: 2's control)
--   4 FISH     fish: two runs leave one block and one set line
--
-- Usage: tillandsias-plan script run scripts/lua/test-install-path.lua
-- Verdict: ok:install-path:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("install-path")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local MARK = "# >>> tillandsias PATH >>>"

-- Runs `body` with install.sh sourced; home is $PWD as the shell spells it.
local function run(shell, body)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/.config/fish")
    local r = T:run{ SH, "-s", "--", ROOT, cwd = d.abs, env = { PATH = env.get("PATH") }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000,
        stdin = 'set -euo pipefail\nR=$1; shift\nunset XDG_BIN_HOME\nexport TILLANDSIAS_INSTALL_TEST_MODE=1 HOME="$PWD" PATH="/usr/bin:/bin" SHELL="' .. shell .. '"\n'
            .. body:gsub("@SOURCE@", '. "$R/scripts/install.sh" </dev/null\n') }
    local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or "" end
    -- install.sh prints its channel when sourced; the last line is the answer.
    return r.code, text.trim(r.stdout or ""):match("([^\n]*)$"), read, "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or "")
end
-- How many lines of s contain the needle.
local function count(s, needle)
    local n = 0
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do if text.contains(l, needle) then n = n + 1 end end
    return n
end
local TWICE = '@SOURCE@INSTALL_DIR="$HOME/.local/bin"\npersist_path_setup\npersist_path_setup\necho "dir=$INSTALL_DIR"\n'

local rc, o, read, why = run("/bin/bash", TWICE)
local dir, got = o:match("^dir=(.+)$") or "?", {}
for _, f in ipairs{ ".profile", ".bashrc" } do
    got[#got + 1] = count(read(f), MARK) .. "/" .. count(read(f), 'export PATH="' .. dir .. ':$PATH"')
end
T:arm("1 PROFILE two runs leave one block and one export line in .profile and .bashrc", rc == 0 and table.concat(got, " ") == "1/1 1/1", table.concat(got, " ") .. " " .. why)
rc, o, read, why = run("/bin/bash", 'mkdir other\nPATH="$HOME/other:$HOME/bin:$PATH"\n@SOURCE@[ "$(resolve_install_dir)" = "$HOME/bin" ] && echo userbin || resolve_install_dir\n')
T:arm("2 USERBIN a safe user bin on PATH is the install dir, ahead of an earlier dir", rc == 0 and o == "userbin", why)
rc, o, read, why = run("/bin/bash", '@SOURCE@[ "$(resolve_install_dir)" = "$HOME/.local/bin" ] && echo default || resolve_install_dir\n')
T:arm("3 DEFAULT with none on PATH the install dir is ~/.local/bin", rc == 0 and o == "default", why)
rc, o, read, why = run("/usr/bin/fish", TWICE)
dir = o:match("^dir=(.+)$") or "?"
local fish = read(".config/fish/conf.d/tillandsias.fish")
T:arm("4 FISH two runs leave one block and one set line", rc == 0 and count(fish, MARK) == 1 and count(fish, 'set -gx PATH "' .. dir .. '" $PATH') == 1, fish .. " " .. why)
T:finish()
