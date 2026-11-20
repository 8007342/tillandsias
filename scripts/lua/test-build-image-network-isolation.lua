-- @trace order:2080-zcur
--
-- test-build-image-network-isolation.lua (1955-chrn) — a podman build argv never pairs
-- --isolation chroot with a network other than host. podman refuses that pair
-- outright ("cannot set --network other than host with --isolation chroot"),
-- and chroot is build-image.sh's default, so 1955-hq7k's unconditional
-- --network=private failed every image build (v56.11.3.1 release gate).
--   ARM 1  chroot -> build_network_args prints nothing
--   ARM 2  oci    -> build_network_args prints --network=private (the 1955-hq7k fix kept)
--   ARM 3  STATIC -> build-image.sh adds no --network of its own outside the
--          helper, and resolves BUILD_ISOLATION before it asks the helper
-- Ported from scripts/test-build-image-network-isolation.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-image-network-isolation.lua
-- Verdict: ok:build-image-network-isolation:<n> arms | violation:build-image-network-isolation:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("build-image-network-isolation")
local ROOT = fixture.repo_root()
local W = T:scratch()
-- The driver: source the helper library, print what it gives for one isolation mode.
fs.write(W.rel .. "/drive.sh", '. "$1" || exit 3\ndeclare -F build_network_args >/dev/null || exit 4\nbuild_network_args "$2"\n')

local function ask(mode)
    local r = T:run{ "bash", W.abs .. "/drive.sh", ROOT .. "/scripts/lib/build-network.sh", mode }
    return r.code, text.trim(r.stdout or "")
end
local rc, out = ask("chroot")
T:arm("ARM 1: chroot builds carry no --network", rc == 0 and out == "", "rc=" .. tostring(rc) .. " '" .. out .. "'")
rc, out = ask("oci")
T:arm("ARM 2: oci builds keep --network=private", rc == 0 and out == "--network=private", "rc=" .. tostring(rc) .. " '" .. out .. "'")

local iso, use, raw = nil, nil, {}
for i, l in ipairs(text.lines(fs.read("scripts/build-image.sh") or "")) do
    if not iso and l:find("^BUILD_ISOLATION=") then iso = i end
    if not use and l:find('build_network_args "$BUILD_ISOLATION"', 1, true) then use = i end
    if l:find("--network", 1, true) and not l:find("^%s*#") then raw[#raw + 1] = i .. ":" .. l end
end
T:arm("ARM 3: build-image.sh takes its build network only from the helper, after BUILD_ISOLATION",
    iso and use and iso < use and #raw == 0,
    "iso=" .. tostring(iso) .. " use=" .. tostring(use) .. " raw=" .. (#raw > 0 and table.concat(raw, " | ") or "none"))

T:finish()
