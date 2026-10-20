-- @trace order:1802-fbld
-- @env TILLANDSIAS_FAST_BUILD_ROOT
--
-- build-root-placement.lua (build.sh strips the runner-required ok: prefix) — where does this checkout's target/ live, and is
-- it on the host's fast build root? build.sh prints the ONE stdout line and
-- never changes a path or refuses: a placement report, not a gate.
--
--   ok:build-root: target=<path> (<fstype>, <raid>, <free> free) fast=yes
--   ok:build-root: target=<path> fast=no
-- When the fast root is a mountpoint but target/ resolves onto another device
-- the line is fast=no and a warning with the bind-mount remedy goes to stderr.
-- A host with no fast root prints fast=no and nothing else.
--
-- Inputs: --target DIR (default target) and env TILLANDSIAS_FAST_BUILD_ROOT
-- (default /srv/fastbuild). Fixture seam, all four together or none:
--   --seam-mounted yes|no  --seam-root-dev N  --seam-target-dev N
--   --seam-info "xfs, raid0 md127, 913G free"

local TARGET = "target"
local SEAM = {}
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--target" then TARGET = arg[i + 1] or TARGET
    elseif a == "--seam-mounted" then SEAM.mounted = arg[i + 1]
    elseif a == "--seam-root-dev" then SEAM.rdev = arg[i + 1]
    elseif a == "--seam-target-dev" then SEAM.tdev = arg[i + 1]
    elseif a == "--seam-info" then SEAM.info = arg[i + 1]
    else verdict.emit("blocked:build-root-placement:usage", 2) end
    i = i + 2
end

local ROOT = env.get("TILLANDSIAS_FAST_BUILD_ROOT")
if not ROOT or ROOT == "" then ROOT = "/srv/fastbuild" end

local function run(argv)
    local r = proc.run({ argv = argv, timeout_ms = 15000 })
    if r.status == "exited" and r.code == 0 then return text.trim(r.stdout or "") end
    return nil
end

local mounted, rdev, tdev, info
if SEAM.mounted then
    mounted, rdev, tdev, info = (SEAM.mounted == "yes"), SEAM.rdev, SEAM.tdev, SEAM.info
else
    mounted = run({ "findmnt", "-n", "-M", ROOT }) ~= nil
    if mounted then
        rdev = run({ "stat", "-L", "-c", "%d", ROOT })
        local fs_, src = (run({ "findmnt", "-no", "FSTYPE,SOURCE", "-M", ROOT }) or ""):match("^(%S+)%s+(%S+)")
        local parts = { fs_ or "?" }
        local base = src and src:match("([^/]+)$")
        local lvl = base and run({ "cat", "/sys/block/" .. base .. "/md/level" })
        if lvl and base then parts[#parts + 1] = lvl .. " " .. base end
        parts[#parts + 1] = (run({ "df", "-h", "--output=avail", ROOT }) or ""):gsub("^Avail%s*", ""):gsub("%s+", "") .. " free"
        info = table.concat(parts, ", ")
    end
end
tdev = tdev or run({ "stat", "-L", "-c", "%d", TARGET })
local tpath = run({ "realpath", TARGET }) or TARGET

if not mounted then
    verdict.emit("ok:build-root: target=" .. tpath .. " fast=no", 0)
end
if rdev ~= nil and rdev == tdev then
    verdict.emit("ok:build-root: target=" .. tpath .. " (" .. (info or "?") .. ") fast=yes", 0)
end
log.raw("[build] WARNING: fast build root " .. ROOT .. " is mounted but target/ is not on it. "
    .. "Remedy: mkdir -p " .. ROOT .. "/tillandsias/target, then add to /etc/fstab "
    .. ROOT .. "/tillandsias/target <checkout>/target none bind,nofail 0 0 and run mount <checkout>/target")
verdict.emit("ok:build-root: target=" .. tpath .. " fast=no", 0)
