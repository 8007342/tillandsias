-- @env TILLANDSIAS_SECURE_WIRE_READER_BASELINE
-- @trace order:972-umik, order:1526-gv3t
--
-- check-secure-wire-single-reader.lua — PORTED from
-- check-secure-wire-single-reader.sh, byte for byte.
-- TILLANDSIAS_SECURE_CONTROL_WIRE has ONE reader, and this ratchets the number
-- of files that name it down, never up. BASELINE is 0 today: every reader was
-- converted (972-umik commit B), so the ratchet is now effectively a refusal.
--
-- Count FILES, not occurrences: the unit that matters is the number of places
-- that decide, and one file deciding twice is still one decision site. A log
-- line or doc comment naming the variable is not a reader, so match only a
-- std::env read of it.
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh's population came from
-- `grep -rl`, whose directory traversal order is OS-dependent, piped through
-- `LC_ALL=C sort`; this port's population comes from `fs.walk`, which is
-- already lexically sorted (byte order), the same ordering LC_ALL=C sort
-- produces. The SET, COUNT and verdict token are identical on every input.
--
-- Grammar (one line on stdout, unchanged):
--   ok:secure-wire-single-reader:<n> of <baseline>
--   violation:secure-wire-readers-grew:<n> of <baseline>
local baseline_env = env.get("TILLANDSIAS_SECURE_WIRE_READER_BASELINE")
local BASELINE = tonumber(baseline_env) or 0

local ENV_NAME = "TILLANDSIAS_SECURE_CONTROL_WIRE"
local OWNER = "crates/tillandsias-control-wire/src/secure_wire_mode.rs"

local PATTERN = [[env::var\("]] .. text.escape(ENV_NAME) .. [["\)|env::var\(]] .. text.escape(ENV_NAME) .. [[\)]]

local readers = {}
for _, f in ipairs(fs.walk("crates", { suffix = ".rs" })) do
    if f ~= OWNER then
        local ok, content = pcall(fs.read, f)
        if ok and text.is_match(content, PATTERN) then
            readers[#readers + 1] = f
        end
    end
end

local count = #readers

if count > BASELINE then
    log.raw("  A new file reads " .. ENV_NAME .. " directly. It has ONE reader:")
    log.raw("  tillandsias_control_wire::secure_wire_mode. Six copies with three")
    log.raw("  behaviours shipped a plaintext client to anyone who capitalised a")
    log.raw("  word (972-umik); a seventh would reopen that.")
    log.raw("  AND THE DEFAULT IS NOW ON: a reader with its own parser defaults")
    log.raw("  to PLAINTEXT against a server that refuses it, which is not a")
    log.raw("  silent insecurity but the e6a80609f OUTAGE. Call")
    log.raw("  tillandsias_control_wire::secure_wire_mode::secure_wire_mode().")
    log.raw("  Readers found:")
    for _, r in ipairs(readers) do log.raw("    " .. r) end
    verdict.emit("violation:secure-wire-readers-grew:" .. count .. " of " .. BASELINE, 1)
end

if count > 0 and count <= BASELINE then
    log.raw("  " .. count .. " reader(s) remain under a raised baseline of " .. BASELINE .. ":")
    for _, r in ipairs(readers) do log.raw("    " .. r) end
end

verdict.emit("ok:secure-wire-single-reader:" .. count .. " of " .. BASELINE, 0)
