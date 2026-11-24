-- @env PATH HOME
-- @trace order:1562-tc7p, order:2301-4bgh
--
-- test-check-toolchain-pinned.lua — fixture for check-toolchain-pinned.lua (1562-tc7p).
-- Ported from the .sh of the same name (2301-4bgh); same eight arms.
--
-- The live tree passes, and each way the toolchain can float is refused on a COPY. Arm 8 is
-- the negative control: a COMMENT saying `toolchain: stable` is history, not an input.
-- Every mutation must change its file, or the fixture refuses: a substitution that no
-- longer matches would leave the copy clean and the arm about nothing.
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-toolchain-pinned.lua
-- Verdict: ok:check-toolchain-pinned:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-toolchain-pinned")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end

local FILES = { "rust-toolchain.toml", "flake.nix", "scripts/build-macos-tray.sh", "scripts/build-windows-tray.ps1" }
for _, f in ipairs(fs.walk(".github/workflows", { suffix = ".yml" })) do FILES[#FILES + 1] = f end

local function guard(root)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_TOOLCHAIN_PIN_ROOT = root }
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-toolchain-pinned.lua" }, cwd = ROOT, env = e, timeout_ms = 60000 }
    return r.code, (r.stdout or ""):gsub("\r", "")
end
local function seed(tag)
    local d = T:scratch(tag)
    for _, f in ipairs(FILES) do
        local dir = f:match("^(.*)/")
        if dir then fs.mkdir(d.rel .. "/" .. dir) end
        fs.write(d.rel .. "/" .. f, fs.read(f))
    end
    return d
end
-- The first occurrence on each line, as the .sh's awk did.
local function subst(d, f, from, to)
    local src = fs.read(d.rel .. "/" .. f)
    local changed = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do
        local i, j = line:find(from, 1, true)
        changed[#changed + 1] = i and line:sub(1, i - 1) .. to .. line:sub(j + 1) or line
    end
    local new = table.concat(changed, "\n")
    if new == src .. "" or new == src:gsub("\n$", "") then T:refuse("mutation-did-not-apply", f .. ": " .. from) end
    fs.write(d.rel .. "/" .. f, new)
end
local function expect(name, want, want_rc, root, want_line)
    local rc, o = guard(root)
    local last = text.trim(o):match("([^\n]*)$") or ""
    T:arm(name, rc == want_rc and last:sub(1, #want) == want and (not want_line or text.contains(o, want_line)),
        "rc=" .. tostring(rc) .. " " .. o:sub(1, 400))
end
local PIN = "toolchain: ${{ steps.rust-pin.outputs.channel }}"
local RELEASE = ".github/workflows/release.yml"
local FLOATS = "violation:toolchain-floats:"

expect("1 the live tree passes", "ok:toolchain-pinned:", 0, ROOT)
local d = seed("stable"); subst(d, RELEASE, PIN, "toolchain: stable")
expect("2 a workflow back on stable is refused, naming the file", FLOATS, 1, d.abs, "release.yml:")
d = seed("copied"); subst(d, RELEASE, PIN, "toolchain: 1.99.0")
expect("3 a hand-copied version is refused", FLOATS, 1, d.abs, "toolchain '1.99.0'")
d = seed("channel"); subst(d, "rust-toolchain.toml", 'channel = "', 'channel = "stable" # was "')
expect("4 a channel that floats is refused", FLOATS, 1, d.abs, "channel 'stable' floats")
d = seed("nofile"); T:must{ "rm", "-f", d.abs .. "/rust-toolchain.toml" }
expect("5 no pin file is refused, not silently ok", FLOATS, 1, d.abs, "rust-toolchain.toml:0:missing")
d = seed("flake"); subst(d, "flake.nix", "pkgs.rust-bin.stable.${rustPin}.default", "pkgs.rust-bin.stable.latest.default")
expect("6 the flake back on stable.latest is refused", FLOATS, 1, d.abs, "flake.nix:")
d = seed("script"); subst(d, "scripts/build-macos-tray.sh", "rust-toolchain.toml", "some-other-file")
expect("7 a build script that stops reading the pin is refused", FLOATS, 1, d.abs, "build-macos-tray.sh:0")
d = seed("comment")
fs.write(d.rel .. "/" .. RELEASE, fs.read(RELEASE) .. "      # toolchain: stable  (the old float, 1562-tc7p)\n")
expect("8 CONTROL a comment is not an input", "ok:toolchain-pinned:", 0, d.abs)
T:finish()
