-- @env PATH HOME
-- @trace spec:default-image, order:966-rq7f, order:667-se87, order:2313-gbza
--
-- test-brew-shim-reentrancy.lua — ported from the .sh of the same name (2313-gbza). `brew` is
-- a Ruby program and `ruby` is a tool we shim: `brew install ruby` runs brew, which resolves
-- ruby through PATH, finds the shim, which runs `brew install ruby`. MEASURED on pirria
-- 2026-09-02 from one ./build.sh --check: 3663 live processes and nothing installed.
--
-- SAFE: no real brew, network or install. A FAKE brew stands in with its own hard depth stop,
-- so arm 4, which reproduces the UNGUARDED behaviour, terminates. It also filters its
-- environment as real brew does (HOMEBREW_* and basics only): a fake that passed everything
-- through let a TILLANDSIAS_-named marker survive here and never in production (667-se87).
--
-- Usage: tillandsias-plan script run scripts/lua/test-brew-shim-reentrancy.lua
-- Verdict: ok:brew-shim-reentrancy:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("brew-shim-reentrancy")
local SH = fixture.posix_shell()
local HARD_STOP = 25
local FAKE_BREW = [==[
#!/usr/bin/env bash
W="${0%/prefix/bin/brew}"
echo "brew-invoked" >> "$W/installs.log"
depth=$(wc -l < "$W/installs.log")
if [ "$depth" -ge @STOP@ ]; then
    echo "fake-brew: hard stop at depth $depth" >&2
    exit 1
fi
filtered=(PATH="$PATH" HOME="$HOME")
while IFS='=' read -r k _; do
    case "$k" in HOMEBREW_*) filtered+=("$k=${!k}") ;; esac
done < <(env)
for k in TILLANDSIAS_BREW_AUTOINSTALL TILLANDSIAS_BREW_PREFIX TILLANDSIAS_BREW_ALLOWLIST TILLANDSIAS_PROJECT_CACHE TILLANDSIAS_BREW_INSTALL_TIMEOUT; do
    [ -n "${!k:-}" ] && filtered+=("$k=${!k}")   # fixture plumbing only, not the marker
done
if [ -f "$W/drop-marker" ]; then
    env -i "${filtered[@]}" env -u HOMEBREW_TILLANDSIAS_SHIM_INSTALLING faketool --version >> "$W/nested.txt" 2>&1
else
    env -i "${filtered[@]}" faketool --version >> "$W/nested.txt" 2>&1
fi
exit 1
]==]
local SHIM = fs.read("images/default/brew-shim-exec.sh")

-- One world per probe. `installed`: faketool already in the prefix; `drop`: the fake brew
-- drops the marker, which is the pre-fix behaviour without editing the shim.
local function probe(o)
    local d = T:scratch()
    for _, p in ipairs{ "prefix/bin", "shims" } do fs.mkdir(d.rel .. "/" .. p) end
    local function put(f, body) fs.write(d.rel .. "/" .. f, body) end
    put("allowlist.txt", "faketool fakeform\n"); put("installs.log", ""); put("nested.txt", "")
    put("shim.sh", SHIM)
    put("prefix/bin/brew", (FAKE_BREW:gsub("@STOP@", tostring(HARD_STOP))))
    put("shims/faketool", '#!/usr/bin/env bash\nexec bash "' .. d.abs .. '/shim.sh" faketool fakeform "$@"\n')
    if o.installed then put("prefix/bin/faketool", "#!/usr/bin/env bash\necho fake-installed-ok\n") end
    if o.drop then put("drop-marker", "") end
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_BREW_AUTOINSTALL = o.auto or "1",
        TILLANDSIAS_BREW_PREFIX = d.abs .. "/prefix", TILLANDSIAS_BREW_ALLOWLIST = d.abs .. "/allowlist.txt",
        TILLANDSIAS_PROJECT_CACHE = d.abs .. "/cache", TILLANDSIAS_BREW_INSTALL_TIMEOUT = "10",
        TILLANDSIAS_BREW_SHIM_INSTALLING = o.marker }
    -- PATH is prefixed in the shell, which spells it the way the shims will search it.
    local r = T:run{ SH, "-s", cwd = d.abs, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000,
        stdin = 'unset HOMEBREW_TILLANDSIAS_SHIM_INSTALLING\nchmod +x prefix/bin/* shims/*\nexport PATH="$PWD/shims:$PATH"\nexec shims/faketool --version </dev/null\n' }
    local _, n = fs.read(d.rel .. "/installs.log"):gsub("brew%-invoked", "")
    return { n = n, nested = fs.read(d.rel .. "/nested.txt"), out = text.trim((r.stdout or "") .. (r.stderr or "")), rc = r.code }
end

local g = probe{}
T:arm("1 the install path runs exactly once", g.n == 1, g.n .. " invocations; " .. g.out)
T:arm("2 the nested probe names the re-entrancy guard and the formula in flight",
    text.contains(g.nested, "re-entrancy guard") and text.contains(g.nested, "already inside an install of 'fakeform'"), g.nested)
T:arm("3 the nested probe degrades to the standard not-installed hint",
    text.contains(g.nested, "Install it in userspace with: brew install fakeform"), g.nested)
local u = probe{ drop = true }
T:arm("4 MUTATION with the marker dropped the same probe re-enters, bounded", u.n > 1 and u.n <= HARD_STOP, u.n .. " invocations")
local i = probe{ installed = true, marker = "somethingelse" }
T:arm("5 an already-installed tool execs normally even inside an install", i.out == "fake-installed-ok" and i.n == 0, i.out)
local z = probe{ auto = "0" }
T:arm("6 AUTOINSTALL=0 hints without invoking brew", z.n == 0 and z.rc == 127 and text.contains(z.out, "is not installed"), tostring(z.rc) .. " " .. z.out)
local m = probe{ marker = "somethingelse" }
T:arm("7 an inherited TILLANDSIAS_ marker alone still refuses the install", m.n == 0 and text.contains(m.out, "already inside an install of 'somethingelse'"), m.n .. " " .. m.out)
T:finish()
