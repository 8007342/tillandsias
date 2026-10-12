-- @trace order:1004-inkc, order:1616-njfd
-- @env TILLANDSIAS_EXPECT_NONE_SCAN_ROOT
--
-- check-enclave-expect-none-is-fixture-only.lua — the expect option given the
-- value none disables the absent detection, so only the fixture may pass it.
-- (This header avoids spelling the token itself: this file is in the scan, and
-- the .sh's one self-mention, its refusal text, is what its count pinned.) Ported from
-- scripts/check-enclave-expect-none-is-fixture-only.sh (the shell-to-lua
-- carried obligation paid by 1616-njfd), with its grammar unchanged.
--
-- WHY THIS EXISTS. 1004-inkc fixed a check that `podman rm` could satisfy: with
-- a required service DELETED it printed ok:...:absent=0, because the expected
-- set came from the caller and the bare invocation supplied none. The fix moved
-- the default into the check, and introduced `none` as an explicit
-- enumeration-only opt-out. It is needed because an empty value now means "use
-- the default", and three legacy fixture arms model a vault without a proxy
-- while testing something else entirely.
--
-- That opt-out is a door back into the defect. A production caller passing
-- `none` gets exactly the old behaviour: a health check that cannot fail on a
-- missing service. So the escape hatch is confined to the fixture, and the
-- confinement is CHECKED rather than commented.
--
-- WHY A LINT AND NOT A RUNTIME GUARD. Accepting `none` only when some
-- TILLANDSIAS_*_TEST variable is set moves the hole rather than closing it,
-- because that variable is settable from production too. A lint over the tree
-- needs nothing to be true at runtime.
--
-- A CALLER is a line, in scripts/, images/, crates/ or openspec/, that PASSES
-- the token: the expect option followed by `none` (with a space or `=`), or
-- TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES assigned a literal none (bare or quoted).
-- Lines whose first non-space character is `#` are prose, not callers.
-- TILLANDSIAS_EXPECT_NONE_SCAN_ROOT (a directory inside the repo) replaces the
-- repo root for the scan, so a fixture can plant cases outside this checkout's
-- tracked tree.
--
-- GRAMMAR (one line on stdout)
--   ok:expect-none-fixture-only:<n> caller(s) checked                 exit 0
--   violation:expect-none-fixture-only:<count>                        exit 1

local root = env.get("TILLANDSIAS_EXPECT_NONE_SCAN_ROOT") or ""
local prefix = (root ~= "" and (root:gsub("/+$", "") .. "/")) or ""

-- The one file allowed to pass it, and the checks that define it.
local ALLOWED = {
    ["scripts/test-enclave-service-health.sh"] = true,
    ["scripts/check-enclave-service-health.sh"] = true,
    ["scripts/lua/check-enclave-expect-none-is-fixture-only.lua"] = true,
}

local function passes_token(l)
    if l:find("%-%-expect[= ]+none") then return true end
    if l:find("TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES=[\"']?none") then return true end
    return false
end

local files = {}
for _, d in ipairs({ "scripts", "images", "crates", "openspec" }) do
    local ok, got = pcall(fs.walk, prefix .. d)
    if ok then for _, f in ipairs(got) do files[#files + 1] = f end end
end
table.sort(files)

local checked, violations = 0, {}
for _, f in ipairs(files) do
    local okr, body = pcall(fs.read, f)
    if okr and body then
        local rel = f:sub(#prefix + 1)
        local n = 0
        for l in (body .. "\n"):gmatch("(.-)\n") do
            n = n + 1
            if not l:match("^%s*#") and passes_token(l) then
                checked = checked + 1
                if not ALLOWED[rel] then violations[#violations + 1] = "  " .. rel .. ":" .. n .. ":" .. l end
            end
        end
    end
end

if #violations == 0 then
    verdict.ok("expect-none-fixture-only", checked .. " caller(s) checked")
end
for _, v in ipairs(violations) do out.line(v) end
out.line("      `--expect none` disables the absent detection (1004-inkc). A production")
out.line("      caller passing it restores a health check that cannot fail on a DELETED")
out.line("      service, the defect that order removed. Only the fixture may pass it.")
verdict.emit("violation:expect-none-fixture-only:" .. #violations, 1)
