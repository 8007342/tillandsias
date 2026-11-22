-- @trace order:804-bpke, spec:app-lifecycle, order:2109-umac
--
-- test-uninstall-preserves-vm.lua — fixture for the shipped uninstaller's
-- data-loss guard (order 804-bpke). Ported from
-- scripts/test-uninstall-preserves-vm.sh (2109-umac) onto the scratch.* door,
-- with the same seven assertions.
--
-- THE BREACH THIS PINS. On macOS three of uninstall.sh's six directories
-- collapse onto one path: LIB_DIR is a subdirectory of DATA_DIR, CONFIG_DIR is
-- byte-identical to it, and that same directory is vz.rs's image_root, where
-- rootfs.img lives. `rm -rf "$DATA_DIR"`, written for the Linux meaning of
-- DATA_DIR, therefore deleted the whole VM, outside the --wipe guard, and then
-- printed "Cache preserved". Measured on a macOS dev host 2026-08-17: DATA_DIR
-- 11.83 GiB against a CACHE_DIR of 8 KB.
--
-- Everything runs against a scratch HOME plus the uninstaller's fixture seams
-- (TILLANDSIAS_UNINSTALL_FAKE_UNAME, _INSTALL_DIR, _APPS_DIR, _TRAY_PROC), so
-- no real path is touched and the macOS arm is exercised from any host.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-uninstall-preserves-vm.lua
-- GRAMMAR ok:uninstall-preserves-vm:7 (exit 0) | violation:uninstall-preserves-vm:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("uninstall-preserves-vm")

local U_REL = "scripts/uninstall.sh"
if not fs.exists(U_REL) then T:refuse("no-uninstaller", "no " .. U_REL) end
local U = fixture.repo_root() .. "/" .. U_REL

local AS = "/Library/Application Support/tillandsias"

-- A scratch HOME that looks like a provisioned host. The VM image only exists
-- on the macOS layout.
local function sandbox(os, tag)
    local d = T:scratch(tag)
    local h = d.leaf
    if os == "darwin" then
        scratch.mkdir(h .. AS .. "/lib")
        scratch.mkdir(h .. "/Library/Logs/tillandsias")
        scratch.mkdir(h .. "/Library/Caches/tillandsias")
        scratch.write(h .. AS .. "/rootfs.img", "rootfs\n")
        scratch.write(h .. AS .. "/settings.json", "settings\n")
        scratch.write(h .. "/Library/Caches/tillandsias/blob", "cache\n")
    else
        for _, p in ipairs({ "/.local/share/tillandsias", "/.local/lib/tillandsias", "/.config/tillandsias",
                "/.local/state/tillandsias", "/.cache/tillandsias" }) do
            scratch.mkdir(h .. p)
        end
        scratch.write(h .. "/.local/share/tillandsias/flake.nix", "bundled\n")
    end
    scratch.mkdir(h .. "/fixture-bin")
    return d
end

-- Run the real uninstaller against a sandbox. Never touches a real path.
local function uninstall(d, os, extra)
    local argv = { "bash", U }
    for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
    argv[#argv + 1] = "--yes" -- 1437-evzi: uninstall asks first; --yes answers for the fixture
    local r = proc.run{ argv = argv, timeout_ms = 60000, env = {
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin",
        HOME = d.abs,
        TILLANDSIAS_UNINSTALL_APPS_DIR = d.abs .. "/Applications",
        TILLANDSIAS_UNINSTALL_TRAY_PROC = "nonce-tray-1401",
        TILLANDSIAS_UNINSTALL_FAKE_UNAME = (os == "darwin") and "Darwin" or "Linux",
        TILLANDSIAS_UNINSTALL_INSTALL_DIR = d.abs .. "/fixture-bin",
    } }
    return (r.stdout or "") .. (r.stderr or "")
end
local function preserved_line(o)
    for _, l in ipairs(text.lines(o)) do
        if l:lower():find("preserved", 1, true) then return l end
    end
    return "(no 'preserved' line)"
end

-- 1-2. THE REGRESSION ITSELF: macOS without --wipe keeps the VM image.
local d = sandbox("darwin", "mac")
local o = uninstall(d, "darwin")
T:arm("macos-default-preserves-the-vm-image", scratch.exists(d.leaf .. AS .. "/rootfs.img"), o)
T:arm("macos-default-still-removes-logs", not scratch.exists(d.leaf .. "/Library/Logs/tillandsias"), o)
-- 3-4. The message must not claim a preservation it did not perform, and the
-- preamble (the user's only notice) must not list the VM dir as removed.
T:arm("macos-default-message-names-the-vm", text.contains(o, "VM image, settings and cache preserved"),
    preserved_line(o))
T:arm("macos-default-preamble-does-not-list-the-vm-as-removed",
    not text.contains(o, "Application Support/tillandsias/ (app data"), o)

-- 5. --wipe still removes everything, or the escape hatch is a lie.
d = sandbox("darwin", "wipe")
o = uninstall(d, "darwin", { "--wipe" })
T:arm("macos-wipe-removes-the-vm-image", not scratch.exists(d.leaf .. AS .. "/rootfs.img"), o)

-- 6. NEGATIVE CONTROL: Linux behaviour is unchanged. A "fix" that preserved
-- DATA_DIR on both platforms would pass every arm above.
d = sandbox("linux", "linux")
o = uninstall(d, "linux")
T:arm("linux-default-still-removes-bundled-data", not scratch.exists(d.leaf .. "/.local/share/tillandsias/flake.nix"), o)

-- 7. 804-wfcu: a non-root Linux run removes no service home, so the original
-- closing line survives verbatim. (The root branch is not exercised: a fixture
-- that can be wrong about being root is one that can delete a real account.)
d = sandbox("linux", "linux2")
o = uninstall(d, "linux")
T:arm("linux-non-root-keeps-the-original-cache-preserved-line",
    text.contains(o, "Cache preserved. Use --wipe to remove everything."), preserved_line(o))

T:finish()
