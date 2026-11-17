-- @env PATH
-- @trace order:2055-grzz
--
-- check-audio-studio-bundle.lua — no release artefact carries a rubberband or
-- sox binary. Both are GPL tools the operator approved for the audio studio
-- CONTAINER only (images/audio-studio/Containerfile): built on the host from
-- that recipe, never shipped.
--
-- What it lists, for each artefact named (a file, a directory walked, or a
-- .tar.gz unpacked into target/plan-scratch and walked):
--   NAME     a file called rubberband, sox, soxi, play or rec, or a
--            librubberband / libsox library, anywhere in the bundle
--   CONTENT  bytes only the real binaries carry, measured 2026-11-08 in the
--            audio-studio image (Debian bookworm): the C++ class name
--            RubberBandStretcher (in /usr/bin/rubberband and
--            librubberband.so.2) and libSoX (in /usr/bin/sox and libsox.so.3).
--            The tray embeds its assets raw (check-embedded-elf-arch.lua finds
--            embedded ELF images by header), so an embedded copy is seen too.
--            Our own text (the Containerfile, audio-tool.py, this file) says
--            "rubberband" and "sox" but never these markers; this file builds
--            them from halves so it cannot match itself.
--
-- Usage: tillandsias-plan script run scripts/lua/check-audio-studio-bundle.lua -- <artefact>...
--   paths are repo-relative (release.yml's release-artifacts/, or target/release/tillandsias)
-- Verdicts:
--   ok:audio-studio-bundle:files=<n>                         exit 0
--   violation:audio-studio-bundle:<path>:<why>               exit 1 (first finding; every one is listed above it)
--   could-not-run:audio-studio-bundle:<why>                  exit 3 (also when nothing was inspected:
--                                                            a zero count is not a pass)

local NAME = "audio-studio-bundle"
local MARKERS = { "RubberBand" .. "Stretcher", "lib" .. "SoX" }
local BANNED = { "rubberband", "sox", "soxi", "play", "rec" }

local paths = {}
for _, a in ipairs(arg or {}) do if a ~= "" then paths[#paths + 1] = a end end
if #paths == 0 then verdict.could_not_run(NAME, "usage: -- <artefact>... (repo-relative)") end

local function banned_name(base)
    for _, b in ipairs(BANNED) do if base == b then return b end end
    local lib = base:match("^(librubberband)[%.%-]") or base:match("^(libsox)[%.%-]")
    return lib
end

local files, findings = {}, {}
local scratch = nil
local function add_file(p) files[#files + 1] = p end

local function walk(p)
    local ok, list = pcall(fs.walk, p)
    if ok and type(list) == "table" and #list > 0 then
        for _, f in ipairs(list) do add_file(f) end
        return true
    end
    return false
end

for _, p in ipairs(paths) do
    if not fs.exists(p) then verdict.could_not_run(NAME, p .. " does not exist") end
    if p:match("%.tar%.gz$") or p:match("%.tgz$") then
        scratch = scratch or ("target/plan-scratch/audio-studio-bundle-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. math.random(100000, 999999))
        local dir = scratch .. "/" .. tostring(#files) .. "-" .. (p:match("([^/]+)$") or "a")
        fs.mkdir(dir)
        local r = proc.run{ argv = { "tar", "-xzf", p, "-C", dir }, timeout_ms = 600000 }
        if not r.ok then verdict.could_not_run(NAME, "tar -xzf " .. p .. ": " .. text.trim(r.stderr or "")) end
        if not walk(dir) then verdict.could_not_run(NAME, p .. " unpacked to nothing") end
    elseif not walk(p) then
        add_file(p)
    end
end

for _, f in ipairs(files) do
    local base = f:match("([^/]+)$") or f
    local b = banned_name(base)
    if b then findings[#findings + 1] = { f, "named-" .. b } end
    local ok, body = pcall(fs.read, f)
    if not ok or body == nil then verdict.could_not_run(NAME, "cannot read " .. f) end
    for _, m in ipairs(MARKERS) do
        if body:find(m, 1, true) then findings[#findings + 1] = { f, "carries-" .. m } end
    end
end

if #files == 0 then verdict.could_not_run(NAME, "no file was inspected") end
if #findings > 0 then
    for _, x in ipairs(findings) do out.line("refused:" .. x[1] .. ":" .. x[2]) end
    io.stderr:write("  why: rubberband and sox are GPL tools approved for the audio studio container only (2055-grzz), never a release artefact\n"
        .. "  remedy: remove them from the bundle; the audio studio image is built on the host from images/audio-studio/Containerfile\n")
    verdict.emit("violation:" .. NAME .. ":" .. findings[1][1] .. ":" .. findings[1][2], 1)
end
verdict.emit("ok:" .. NAME .. ":files=" .. #files, 0)
