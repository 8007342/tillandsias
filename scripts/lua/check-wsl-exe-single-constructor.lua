-- @trace order:1525-c6jm, order:795-jjw3
--
-- check-wsl-exe-single-constructor.lua — PORTED from
-- check-wsl-exe-single-constructor.sh, byte for byte. Exactly ONE module in
-- the workspace may construct a `wsl.exe` child, so a policy about wsl.exe
-- (encoding, window flags, timeouts) is set once and cannot be forgotten N
-- times.
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh's population came from
-- `grep -rn`, whose multi-directory traversal order is the OS directory
-- order (unspecified, filesystem-dependent); this port's population comes
-- from `fs.walk`, which is lexically SORTED. When more than one file
-- violates, the per-violation line ORDER can differ between the two — the
-- SET of violations, the count, and the verdict token are identical on every
-- input, including the deliberately-violating one in the parity proof (kept
-- to a single violating file so ordering cannot be observed). On the live
-- tree (0 violations) this never differs.
--
-- Prints exactly one line matching
--   ^(ok:wsl-single-constructor:[0-9]+ scanned|violation:wsl-extra-constructor:.*)$
-- and exits 0 only when the sole constructor module owns every construction.
local OWNER = "crates/tillandsias-core/src/wsl.rs"

local ok_owner = pcall(fs.read, OWNER)
if not ok_owner then
    verdict.emit("violation:wsl-extra-constructor:owner-module-missing:" .. OWNER, 1)
end

local ANY_CTOR = [=[Command::new\(]=]
local WSL_CTOR = [=[Command::new\("wsl(\.exe)?"\)]=]
local COMMENT_LINE = [=[^//]=]

local files = fs.walk("crates", { suffix = ".rs" })
local scanned = 0
local violations = {}
for _, f in ipairs(files) do
    local ok, src = pcall(fs.read, f)
    if ok then
        if text.is_match(src, ANY_CTOR) then scanned = scanned + 1 end
        if f ~= OWNER then
            for _, l in ipairs(text.lines(src)) do
                if text.is_match(l, WSL_CTOR) then
                    local trimmed = l:match("^%s*(.*)$")
                    if not text.is_match(trimmed, COMMENT_LINE) then
                        violations[#violations + 1] = f
                    end
                end
            end
        end
    end
end

if #violations > 0 then
    for _, f in ipairs(violations) do out.line("violation:wsl-extra-constructor:" .. f) end
    verdict.emit(("violation:wsl-extra-constructor:%d site(s) outside %s"):format(#violations, OWNER), 1)
end

verdict.emit(("ok:wsl-single-constructor:%d scanned"):format(scanned), 0)
