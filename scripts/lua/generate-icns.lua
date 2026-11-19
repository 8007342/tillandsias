-- @trace order:2096-y7sx
--
-- generate-icns.lua — regenerate crates/tillandsias-macos-tray/assets/icon.icns
-- from icon.png with sips and iconutil (macOS only; run by hand after the icon
-- changes). Ported from generate_icns.sh (family B, operator ruling
-- 2026-11-17), which had no shebang, no errexit, and ignored every failure.
--
-- USAGE   tillandsias-plan script run scripts/lua/generate-icns.lua
-- GRAMMAR (last line on stdout)
--   ok:generate-icns:<icns path>              exit 0
--   could-not-run:generate-icns:<step>        exit 3  (sips/iconutil missing or failed)

local ASSETS = "crates/tillandsias-macos-tray/assets"
local SRC = ASSETS .. "/icon.png"
local ICONSET = "target/icon.iconset"
local OUT = ASSETS .. "/icon.icns"

local function must(step, argv)
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then
        io.stderr:write(step .. ": " .. (r.stderr or tostring(r.status)) .. "\n")
        proc.run({ argv = { "rm", "-rf", "--", ICONSET } })
        verdict.emit("could-not-run:generate-icns:" .. step, 3)
    end
end

if not fs.exists(SRC) then
    verdict.emit("could-not-run:generate-icns:missing-" .. SRC, 3)
end
must("mkdir", { "mkdir", "-p", ICONSET })
for _, size in ipairs({ 16, 32, 64, 128, 256, 512 }) do
    local s, d = tostring(size), tostring(size * 2)
    must("sips-" .. s, { "sips", "-z", s, s, SRC, "--out", ICONSET .. "/icon_" .. s .. "x" .. s .. ".png" })
    must("sips-" .. s .. "@2x", { "sips", "-z", d, d, SRC, "--out", ICONSET .. "/icon_" .. s .. "x" .. s .. "@2x.png" })
end
must("iconutil", { "iconutil", "-c", "icns", ICONSET, "-o", OUT })
must("cleanup", { "rm", "-rf", "--", ICONSET })
verdict.ok("generate-icns", OUT)
