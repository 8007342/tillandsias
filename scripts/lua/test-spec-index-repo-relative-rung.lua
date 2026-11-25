-- @trace order:931-p26p, order:760-hzi4, spec:forge-environment-discoverability, order:2348-psb6
-- @env PATH HOME
--
-- test-spec-index-repo-relative-rung.lua — the repo-relative rung (4) must fix the Windows
-- lane WITHOUT moving any host that already works. Ported from the .sh of the same name
-- (2348-psb6); same six arms.
--
-- WHY THE NEGATIVE ARMS ARE THE POINT. The rung exists to make two userlands on one machine
-- agree; its risk is the opposite bug, capturing resolution on hosts whose earlier rungs are
-- right today. Arms 1-3 assert an earlier rung still wins; only arm 4 asserts the new rung.
-- If you find yourself relaxing 1-3 to make something pass, the change is wrong.
--
-- Arms run the EXTRACTED shell block (scripts/spec-index-ensure.sh, between its 801-a2by
-- BEGIN/END markers) under `env -i`, so this cannot drift into testing a paraphrase.
--
--   1 NEGATIVE an explicit FORGE_SPEC_INDEX_ROOT wins
--   2 NEGATIVE a podman volume (stubbed) wins on a Linux-shaped host
--   3 NEGATIVE a non-writable checkout falls through to XDG (a skip where the bit is not representable)
--   4 POSITIVE no podman, no explicit root: the rung anchors to the checkout
--   5 THE BUG  two HOMEs resolve to ONE root
--   6 CONTROL  the old HOME-derived rung DOES diverge for those two HOMEs
--
-- GRAMMAR ok:spec-index-repo-relative-rung:6 arms | violation:spec-index-repo-relative-rung:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("spec-index-repo-relative-rung")
local PATHV = env.get("PATH") or "/usr/bin:/bin"

local blk, on = {}, false
for l in (fs.read("scripts/spec-index-ensure.sh") .. "\n"):gmatch("([^\n]*)\n") do
    if l:find("# >>> BEGIN spec-index resolution (801-a2by)", 1, true) == 1 then on = true end
    if on then blk[#blk + 1] = l end
    if on and l:find("# <<< END spec-index resolution (801-a2by)", 1, true) == 1 then break end
end
if #blk < 2 then T:refuse("block-not-extracted", "no 801-a2by block in scripts/spec-index-ensure.sh") end

local W = T:scratch()
fs.write(W.rel .. "/block.sh", table.concat(blk, "\n") .. "\n")
local CO = W.abs .. "/checkout"
fs.mkdir(W.rel .. "/checkout/plan"); fs.write(W.rel .. "/checkout/plan/index.yaml", "")

-- root(dir, vars): resolve from inside dir under `env -i`; the first path printed.
local function root(dir, vars, path)
    local argv = { "env", "-i", "HOME=" .. W.abs .. "/home", "PATH=" .. (path or PATHV), "PWD=" .. dir }
    for _, v in ipairs(vars or {}) do argv[#argv + 1] = v end
    argv[#argv + 1] = "sh"; argv[#argv + 1] = "-s"
    argv.cwd, argv.timeout_ms = dir, 30000
    argv.stdin = ". '" .. W.abs .. "/block.sh'\n_tillandsias_spec_index_paths\n"
    local r = T:run(argv)
    return (r.stdout or ""):match("^([^\n]*)") or ""
end

local got = root(CO, { "FORGE_SPEC_INDEX_ROOT=/tmp/explicit", "TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1" })
T:arm("1 NEGATIVE an explicit FORGE_SPEC_INDEX_ROOT wins over the repo rung", got == "/tmp/explicit", got)

local VOL = W.abs .. "/volume"
fs.mkdir(W.rel .. "/volume"); fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/bin/podman", '#!/usr/bin/env bash\necho "' .. VOL .. '"\n')
T:must{ "chmod", "+x", W.abs .. "/bin/podman" }
got = root(CO, {}, W.abs .. "/bin:" .. PATHV)
T:arm("2 NEGATIVE a podman volume still wins on a Linux-shaped host", got == VOL, "got '" .. got .. "' want '" .. VOL .. "'")

local RO = W.abs .. "/readonly"
fs.mkdir(W.rel .. "/readonly/plan"); fs.mkdir(W.rel .. "/readonly/.cache"); fs.write(W.rel .. "/readonly/plan/index.yaml", "")
T:run{ "chmod", "-w", RO .. "/.cache" }
local writable = T:run{ "test", "-w", RO .. "/.cache" }.code == 0
if writable then
    -- chmod is a no-op on some filesystems (drvfs, core.fileMode=false): say so, never a pass.
    out.line("skip: 3 the read-only bit is not representable here")
else
    got = root(RO, { "XDG_CACHE_HOME=" .. W.abs .. "/xdg", "TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1" })
    T:arm("3 NEGATIVE a read-only checkout falls through to XDG", got == W.abs .. "/xdg/tillandsias/spec-index", got)
end
T:run{ "chmod", "+w", RO .. "/.cache" }

got = root(CO, { "XDG_CACHE_HOME=" .. W.abs .. "/xdg", "TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1" })
T:arm("4 POSITIVE with no podman and no explicit root the rung anchors to the checkout", got == CO .. "/.cache/spec-index", got)

-- 5 — 931-p26p in its essence: producer and reader differ only in $HOME.
local function home(h)
    local r = T:run{ "env", "-i", "HOME=" .. W.abs .. "/" .. h, "PATH=" .. PATHV, "PWD=" .. CO, "TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1",
        "sh", "-s", cwd = CO, timeout_ms = 30000, stdin = ". '" .. W.abs .. "/block.sh'\n_tillandsias_spec_index_paths\n" }
    return (r.stdout or ""):match("^([^\n]*)") or ""
end
local a, b = home("home-a"), home("home-b")
T:arm("5 two HOMEs resolve to ONE root", a ~= "" and a == b, "HOME-a -> '" .. a .. "', HOME-b -> '" .. b .. "'")

-- 6 — CONTROL: the old rung, ${XDG_CACHE_HOME:-$HOME/.cache}, for the same two HOMEs.
local function old(h)
    local r = T:run{ "env", "-i", "HOME=" .. W.abs .. "/" .. h, "PATH=" .. PATHV, "sh", "-s", timeout_ms = 30000,
        stdin = 'echo "${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/spec-index"\n' }
    return text.trim(r.stdout or "")
end
a, b = old("home-a"), old("home-b")
T:arm("6 CONTROL the old HOME-derived rung really does diverge", a ~= "" and a ~= b, a .. " vs " .. b)

T:finish()
