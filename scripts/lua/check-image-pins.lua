-- @trace order:1716-t2gi, order:1637-5765
-- @env TILLANDSIAS_IMAGE_PINS_SCAN_ROOT
-- @read-env TILLANDSIAS_IMAGE_PINS_SCAN_ROOT
--
-- check-image-pins.lua — every `FROM …@sha256:` pin under images/ and
-- observatorium/ must be a MULTI-ARCH INDEX digest that carries linux/amd64
-- and linux/arm64, as recorded in images/image-pins.yaml.
--
-- WHY. A single-platform digest builds the wrong architecture and nothing
-- fails. Measured 2026-10-14 in the macOS tray VM (aarch64 Fedora): images/
-- flutter pinned debian:bookworm-slim@sha256:a4672c0cb26f…, the AMD64 entry
-- of the bookworm-slim index. `podman build --arch arm64` returned 0 and the
-- image was labelled arm64, but `uname -m` inside it said x86_64: every RUN
-- went through the guest's qemu-x86_64 binfmt handler. An index digest makes
-- the build pick the native entry.
--
-- WHY A COMMITTED RECORD (1716-t2gi option (a)). A gate guard must not need
-- the network, and a digest alone does not say whether it names an index. So
-- scripts/lua/refresh-image-pins.lua (network) reads each pin's manifest from
-- its registry and writes images/image-pins.yaml (media type, platforms), and
-- this guard checks every FROM digest against that record OFFLINE: it spawns
-- nothing and opens no socket. Option (b), a build-time native-arch assertion,
-- would also catch an emulated TAG-only base; it is a guest-builder change and
-- is left as a follow-up.
--
-- Every FROM line is enumerated and classified, never skipped:
--   pinned  an @sha256: digest: checked against the record
--   tag     a tag only: counted (whether to digest-pin those is a separate
--           supply-chain question, out of this guard's scope)
--   arg     an ARG-substituted image: resolved from the file's own
--           `ARG NAME=default` when it has one (then classified as above),
--           otherwise NAMED on stderr
--   stage   a previous build stage's name (multi-stage)
--
-- Verdict grammar (stdout, one line):
--   ok:image-pins:from=<n> pinned=<p> tag=<t> arg=<a> stage=<s>       exit 0
--   refused:image-pins:<k> refusal(s) (stderr: one per pin)           exit 1
--   blocked:image-pins:no-record   images/image-pins.yaml unreadable  exit 2
-- Each stderr refusal names the file, the line, the pin, why it was
-- refused, and what makes it not a refusal:
--   refused:image-pin-single-platform:<file>:<line>:<ref>@<digest>
--   refused:image-pin-missing-arch:<file>:<line>:<ref>@<digest>:<arch>
--   refused:image-pin-unrecorded:<file>:<line>:<ref>@<digest>
--
-- `-- --census` prints one `pin <ref> <digest>` line per pinned FROM and the
-- verdict `ok:image-pins:census pins=<n>` (the runtime has no os.exit; the
-- verdict line ends the run). refresh-image-pins.lua reads it, so the FROM
-- parser lives here only.
--
-- TILLANDSIAS_IMAGE_PINS_SCAN_ROOT is a TEST SEAM: a fixture tree holding
-- its own images/, observatorium/ and images/image-pins.yaml.

local scan_env = env.get("TILLANDSIAS_IMAGE_PINS_SCAN_ROOT")
local ROOT = (scan_env and scan_env ~= "") and scan_env or nil
local function rooted(rel)
    if ROOT then return ROOT .. "/" .. rel end
    return rel
end

local CENSUS = false
for _, a in ipairs(arg or {}) do
    if a == "--census" then CENSUS = true end
end

local RECORD = "images/image-pins.yaml"
local SCAN_DIRS = { "images", "observatorium" }

local INDEX_TYPES = {
    ["application/vnd.oci.image.index.v1+json"] = true,
    ["application/vnd.docker.distribution.manifest.list.v2+json"] = true,
}
-- The fleet's two architectures: the Linux and Windows hosts' amd64 and the
-- macOS guest's arm64. An index without either still builds emulated there.
local REQUIRED_ARCHES = { "linux/amd64", "linux/arm64" }

local function is_containerfile(path)
    local base = path:match("([^/]+)$") or path
    return base:match("^Containerfile") or base:match("^Dockerfile")
        or base:match("%.Containerfile$") or base:match("%.Dockerfile$")
end

-- Every Containerfile/Dockerfile under the scan dirs, sorted, as display
-- paths relative to the root.
local files = {}
for _, d in ipairs(SCAN_DIRS) do
    local dir_path = rooted(d)
    local ok_walk, walked = pcall(fs.walk, dir_path)
    if ok_walk then
        for _, f in ipairs(walked) do
            local rel = f:sub(#dir_path + 2)
            if is_containerfile(rel) then files[#files + 1] = d .. "/" .. rel end
        end
    end
end
table.sort(files)

-- Substitute ${NAME} / $NAME from the file's own ARG defaults. Returns the
-- substituted image, or nil when a variable has no default here.
local function substitute(image, args)
    local unresolved = false
    local out = image:gsub("%${([%w_]+)}", function(n)
        if args[n] then return args[n] end
        unresolved = true
        return ""
    end)
    out = out:gsub("%$([%w_]+)", function(n)
        if args[n] then return args[n] end
        unresolved = true
        return ""
    end)
    if unresolved then return nil end
    return out
end

-- Parse every FROM line: { file, line, image, kind, ref, digest }.
local froms = {}
for _, disp in ipairs(files) do
    local ok_r, content = pcall(fs.read, rooted(disp))
    if ok_r then
        local args, stages = {}, {}
        for n, raw in ipairs(text.lines(content)) do
            local line = raw:gsub("^%s+", "")
            local argname, argval = line:match("^[Aa][Rr][Gg]%s+([%w_]+)=(%S+)")
            if argname then args[argname] = argval:gsub('^"(.*)"$', "%1") end
            local rest = line:match("^[Ff][Rr][Oo][Mm]%s+(.+)$")
            if rest then
                local toks = {}
                for t in rest:gmatch("%S+") do toks[#toks + 1] = t end
                local i = 1
                while toks[i] and toks[i]:match("^%-%-") do i = i + 1 end
                local image = toks[i] or ""
                if toks[i + 1] and toks[i + 1]:lower() == "as" and toks[i + 2] then
                    stages[toks[i + 2]:lower()] = true
                end
                local f = { file = disp, line = n, image = image }
                local resolved = image
                if image:find("%$") then
                    resolved = substitute(image, args)
                    f.arg = true
                end
                if resolved == nil then
                    f.kind = "arg"
                elseif stages[resolved:lower()] then
                    f.kind = "stage"
                else
                    local ref, digest = resolved:match("^(.-)@(sha256:%x+)$")
                    if ref then
                        f.kind, f.ref, f.digest = "pinned", ref, digest
                    else
                        f.kind = "tag"
                    end
                end
                froms[#froms + 1] = f
            end
        end
    end
end

if CENSUS then
    local n = 0
    for _, f in ipairs(froms) do
        if f.kind == "pinned" then
            n = n + 1
            io.stdout:write("pin " .. f.ref .. " " .. f.digest .. "\n")
        end
    end
    verdict.emit("ok:image-pins:census pins=" .. n, 0)
end

-- The record: digest -> { media_type, platforms[] }.
local ok_m, mtext = pcall(fs.read, rooted(RECORD))
local ok_y, rec = false, nil
if ok_m then ok_y, rec = pcall(yaml.parse, mtext) end
if not (ok_m and ok_y and type(rec) == "table" and type(rec.pins) == "table") then
    io.stderr:write("[check-image-pins] cannot read " .. RECORD ..
        "; run `tillandsias-plan script run scripts/lua/refresh-image-pins.lua` with network to write it\n")
    verdict.emit("blocked:image-pins:no-record", 2)
end
local by_digest = {}
for _, p in ipairs(rec.pins) do
    if type(p) == "table" and p.digest then by_digest[p.digest] = p end
end

-- Repository part of a ref: drop a trailing :tag (not a registry :port).
local function repo_of(ref)
    return (ref:gsub(":[^/:]+$", ""))
end

local counts = { pinned = 0, tag = 0, arg = 0, stage = 0 }
local refusals = {}
local function refuse(kind, f, extra, remedy)
    local id = "refused:" .. kind .. ":" .. f.file .. ":" .. f.line .. ":" .. f.ref .. "@" .. f.digest
    if extra then id = id .. ":" .. extra end
    refusals[#refusals + 1] = id .. "  (" .. remedy .. ")"
end

for _, f in ipairs(froms) do
    counts[f.kind] = counts[f.kind] + 1
    if f.kind == "arg" then
        io.stderr:write("note:image-pins:arg-from:" .. f.file .. ":" .. f.line .. ":" .. f.image ..
            " (no ARG default in this file; the image it names is built and checked elsewhere)\n")
    elseif f.arg then
        io.stderr:write("note:image-pins:arg-from-resolved:" .. f.file .. ":" .. f.line .. ":" .. f.image ..
            " -> " .. (f.ref and (f.ref .. "@" .. f.digest) or f.kind) .. "\n")
    end
    if f.kind == "pinned" then
        local r = by_digest[f.digest]
        if r == nil or (r.ref and repo_of(r.ref) ~= repo_of(f.ref)) then
            refuse("image-pin-unrecorded", f, nil,
                "not in " .. RECORD .. "; run scripts/lua/refresh-image-pins.lua with network to record it")
        elseif not INDEX_TYPES[r.media_type or ""] then
            refuse("image-pin-single-platform", f, nil,
                "recorded as " .. tostring(r.media_type) ..
                ", one platform's manifest; pin the multi-arch INDEX digest of " .. f.ref .. " instead")
        else
            local have = {}
            for _, pl in ipairs(r.platforms or {}) do have[#have + 1] = tostring(pl) end
            for _, want in ipairs(REQUIRED_ARCHES) do
                local found = false
                for _, pl in ipairs(have) do
                    if pl == want or pl:sub(1, #want + 1) == want .. "/" then found = true end
                end
                if not found then
                    refuse("image-pin-missing-arch", f, want,
                        "the index has no " .. want .. " entry, so that host builds it emulated; pick a base that publishes it")
                end
            end
        end
    end
end

if #refusals > 0 then
    for _, line in ipairs(refusals) do io.stderr:write(line .. "\n") end
    verdict.emit("refused:image-pins:" .. #refusals .. " refusal(s)", 1)
end
verdict.emit(string.format("ok:image-pins:from=%d pinned=%d tag=%d arg=%d stage=%d",
    #froms, counts.pinned, counts.tag, counts.arg, counts.stage), 0)
