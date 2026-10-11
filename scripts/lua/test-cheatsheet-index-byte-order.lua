-- @trace order:1459-b5fh, order:1585-hb8w, spec:cheatsheet-tooling
--
-- test-cheatsheet-index-byte-order.lua — PORTED from
-- test-cheatsheet-index-byte-order.sh (carried obligation shell->lua,
-- 1585-hb8w), arms and verdict lines unchanged.
--
-- The cheatsheet INDEX is generated and COMMITTED, so its bytes must not
-- depend on the host. They did: the generator delegated collation to the
-- platform's `sort`, so glibc en_US, the MSYS/Cygwin runtime and a C locale
-- each produced a different order (and on Windows a bare `sort` even ran
-- System32's sort.exe). It now sorts in Rust by byte order.
--
--   1  under LC_ALL=C the committed INDEX is current (--check exits 0)
--   2  under LC_ALL=en_US.UTF-8 it is current too: the locale changes nothing
--   3  the pinned pair: podman-control-plane.md precedes podman.md ('-' 0x2D
--      sorts before '.' 0x2E), the pair glibc and Cygwin disagree on
--
-- proc.run children get LC_ALL=C by default; each arm sets its own locale
-- explicitly, which the per-call env overrides.
--
-- Verdicts (last line), unchanged:
--   ok:cheatsheet-index-byte-order:<pass>
--   violation:cheatsheet-index-byte-order:<pass>/<total>        exit 1
--   skip:cheatsheet-index-byte-order:absent | no-cargo

local REGEN = "scripts/regenerate-cheatsheet-index.sh"
local IDX = "cheatsheets/INDEX.md"
if not fs.exists(REGEN) or not fs.exists(IDX) then
    verdict.emit("skip:cheatsheet-index-byte-order:absent", 0)
end
local cargo = proc.run({ argv = { "cargo", "--version" } })
if cargo.status ~= "exited" or cargo.code ~= 0 then
    verdict.emit("skip:cheatsheet-index-byte-order:no-cargo", 0)
end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

for _, loc in ipairs({ "C", "en_US.UTF-8" }) do
    local r = proc.run({ argv = { "bash", REGEN, "--check" }, env = { LC_ALL = loc }, timeout_ms = 600000 })
    local rc = (r.status == "exited") and r.code or -1
    if rc == 0 then
        ok("the committed INDEX is current under LC_ALL=" .. loc)
    else
        local lines = text.lines((r.stdout or "") .. (r.stderr or ""))
        local tail = {}
        for k = math.max(1, #lines - 1), #lines do tail[#tail + 1] = lines[k] end
        bad("under LC_ALL=" .. loc .. " the INDEX would change (rc=" .. rc .. "): " .. table.concat(tail, ";"))
    end
end

local a, b
for n, l in ipairs(text.lines(fs.read(IDX))) do
    if a == nil and l:sub(1, 26) == "- podman-control-plane.md " then a = n end
    if b == nil and l:sub(1, 12) == "- podman.md " then b = n end
end
if a and b and a < b then
    ok("podman-control-plane.md (line " .. a .. ") precedes podman.md (line " .. b .. "): byte order")
else
    bad("pinned pair out of byte order or missing: podman-control-plane.md=" .. (a or "absent")
        .. " podman.md=" .. (b or "absent"))
end

if fail == 0 then verdict.emit("ok:cheatsheet-index-byte-order:" .. pass, 0) end
verdict.emit("violation:cheatsheet-index-byte-order:" .. pass .. "/" .. (pass + fail), 1)
