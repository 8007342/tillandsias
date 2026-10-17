-- @trace order:1756-z3kz, order:1269-6fcn, order:1750-a4re
--
-- check-embedded-elf-arch.lua — every ELF image EMBEDDED in a release binary
-- has the outer binary's machine.
--
-- WHY (1756-z3kz). tillandsias-headless include_bytes!s Linux binaries that run
-- in containers: the router sidecar (images/router/) and, since 1750-a4re, the
-- forge's tillandsias-plan (images/default/policy-bin/). flake.nix staged the
-- x86_64 sidecar into the aarch64 headless too, so an aarch64 host's router
-- container hits an exec-format error. release.yml `file`d only the OUTER
-- binary, which was aarch64 and passed.
--
-- An embedded image is found by its ELF header, not by name: \127ELF followed
-- by a valid ident (EI_CLASS 1|2, EI_DATA 1|2, EI_VERSION 1) and a valid
-- header (e_type EXEC|DYN, e_version 1), so a stray "\127ELF" constant in code
-- or data is not counted. The outer binary is the ELF at offset 0.
--
-- Usage: tillandsias-plan script run scripts/lua/check-embedded-elf-arch.lua -- <binary> [<min-embedded>]
--   <min-embedded>  refuse when fewer embedded images are found (default 1),
--                   so a binary that embeds nothing cannot pass by omission
--
-- Verdicts:
--   ok:embedded-elf-arch:<file>:<arch>:embedded=<n>                       exit 0
--   violation:embedded-elf-arch:<file>:<arch>:mismatch=<n>:<arch>@<off>,…  exit 1
--   violation:embedded-elf-arch:<file>:<arch>:embedded=<n><min=<m>        exit 1
--   could-not-run:embedded-elf-arch:<why>                                 exit 3

local NAME = "embedded-elf-arch"
local path = arg and arg[1] or nil
local min_embedded = tonumber(arg and arg[2] or "1") or 1
if not path or path == "" then
    verdict.could_not_run(NAME, "usage: -- <binary> [<min-embedded>]")
end
local ok, bin = pcall(fs.read, path)
if not ok or not bin then
    verdict.could_not_run(NAME, "cannot read " .. path)
end

local MACHINES = { [0x3E] = "x86_64", [0xB7] = "aarch64", [0x28] = "arm", [0x03] = "x86", [0xF3] = "riscv" }

local function u16(s, i, le)
    local a, b = s:byte(i, i + 1)
    if not a or not b then return nil end
    if le then return a + b * 256 end
    return a * 256 + b
end
local function u32(s, i, le)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    if le then return a + b * 256 + c * 65536 + d * 16777216 end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- header_at(pos) -> machine name or nil when pos (1-based) is not a valid ELF header
local function header_at(pos)
    if bin:sub(pos, pos + 3) ~= "\127ELF" then return nil end
    local class, data, ver = bin:byte(pos + 4, pos + 6)
    if (class ~= 1 and class ~= 2) or (data ~= 1 and data ~= 2) or ver ~= 1 then return nil end
    local le = data == 1
    local e_type = u16(bin, pos + 16, le)
    local e_machine = u16(bin, pos + 18, le)
    local e_version = u32(bin, pos + 20, le)
    if (e_type ~= 2 and e_type ~= 3) or e_version ~= 1 or not e_machine then return nil end
    return MACHINES[e_machine] or string.format("machine-0x%x", e_machine)
end

local outer = header_at(1)
if not outer then
    verdict.could_not_run(NAME, path .. " is not an ELF executable")
end

local embedded, mismatched = 0, {}
local pos = 2
while true do
    local s = bin:find("\127ELF", pos, true)
    if not s then break end
    local m = header_at(s)
    if m then
        embedded = embedded + 1
        if m ~= outer then mismatched[#mismatched + 1] = m .. "@" .. (s - 1) end
    end
    pos = s + 4
end

local base = path:match("([^/]+)$") or path
if #mismatched > 0 then
    out.line("why: " .. base .. " is " .. outer .. ", but it embeds " .. #mismatched
        .. " ELF image(s) for another machine; a container it starts from that image fails with an exec-format error")
    out.line("remedy: stage the embedded artifacts for the binary's own target (flake.nix preBuild: stageRouterSidecar / stagePlanBin for the matching arch)")
    verdict.emit("violation:" .. NAME .. ":" .. base .. ":" .. outer .. ":mismatch=" .. #mismatched .. ":" .. table.concat(mismatched, ","), 1)
end
if embedded < min_embedded then
    verdict.emit("violation:" .. NAME .. ":" .. base .. ":" .. outer .. ":embedded=" .. embedded .. "<min=" .. min_embedded, 1)
end
verdict.emit("ok:" .. NAME .. ":" .. base .. ":" .. outer .. ":embedded=" .. embedded, 0)
