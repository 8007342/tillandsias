-- @env PATH HOME
-- @trace order:814-75yf
--
-- check-test-host-paths.lua — a Rust test does not read a Linux-only host path (/proc, /sys, /dev)
-- or build a host-reading sampler, unless the test is gated to the OS that has the path or says
-- why it is portable anyway.
--
-- WHY (814-75yf). `sampler::tests::sample_disk_io_returns_empty_on_first_call` built its sampler
-- with MetricsSampler::new(), which reads the real /proc/diskstats, so it could only pass where
-- /proc exists. ./build.sh --check runs the workspace suite on Linux on every host (the Windows
-- gate re-execs into WSL2), so a Linux-only test is indistinguishable from a portable one there,
-- and it was red only natively on Windows and macOS (found 2026-08-18; fixed in 71496d6e5).
-- This catches that SHAPE. Host preconditions in shell or litmus (806-6y3h, the core.symlinks
-- litmus) are a different remedy, declared and skipped, and are not this check's.
--
-- What is scanned: every crates/**/*.rs. Test code is a file under tests/, or the item that
-- follows #[cfg(test)]. A line inside an item that follows a #[cfg(...target_os...)],
-- #[cfg(...unix...)] or #[cfg(...windows...)] attribute is gated, and allowed. Flagged, in
-- ungated test code: a read call (read_to_string, File::open, read_dir, read_link, metadata,
-- canonicalize, fs::read) of a "/proc/", "/sys/" or "/dev/" literal, and MetricsSampler::new().
-- A comment line is never flagged; `// host-path: <reason>` on the line or the one above allows it.
--
-- Usage: tillandsias-plan script run scripts/lua/check-test-host-paths.lua [-- <file>...]
-- Verdict: ok:test-host-paths:<n> files | violation:test-host-paths:<n>

local NAME = "test-host-paths"
local files = {}
if arg and #arg > 0 then
    for _, a in ipairs(arg) do files[#files + 1] = a end
else
    local r = proc.run{ argv = { "git", "ls-files", "--", "crates/*.rs", "crates/**/*.rs" }, timeout_ms = 30000 }
    if r.status ~= "exited" or r.code ~= 0 then verdict.could_not_run(NAME, "git ls-files failed") end
    for f in (r.stdout or ""):gmatch("[^\n]+") do files[#files + 1] = f end
end

local READ = { "read_to_string", "File::open", "read_dir", "read_link", "metadata", "canonicalize", "fs::read" }
local function host_read(l)
    for _, fn in ipairs(READ) do
        local i = l:find(fn .. "(", 1, true)
        if i and l:sub(i):match('^[%w_:]+%(%s*"/[ps][ry][os]?[cs]?/') then
            local p = l:sub(i):match('^[%w_:]+%(%s*"(/[^/"]+)/')
            if p == "/proc" or p == "/sys" or p == "/dev" then return true end
        end
    end
    return l:find("MetricsSampler::new()", 1, true) ~= nil
end

local bad = {}
for _, f in ipairs(files) do
    local ok, body = pcall(fs.read, f)
    if ok and body then
        local whole = f:find("/tests/", 1, true) ~= nil
        -- A stack of open regions: each records the brace depth it opened at and its kind.
        local depth, regions, pending = 0, {}, {}
        local prev = ""
        local n = 0
        for l in (body .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            local code = l:gsub("//.*$", "")
            if l:match("^%s*#%[cfg%(test%)%]") then pending.test = true end
            if l:match("^%s*#%[cfg%(.*target_os") or l:match("^%s*#%[cfg%(.*unix") or l:match("^%s*#%[cfg%(.*windows") then pending.gate = true end
            local intest, gated = whole, false
            for _, r in ipairs(regions) do
                if r.test then intest = true end
                if r.gate then gated = true end
            end
            if intest and not gated and not l:match("^%s*//") and host_read(code)
                and not l:find("host-path:", 1, true) and not prev:find("host-path:", 1, true) then
                bad[#bad + 1] = f .. ":" .. n .. ": " .. (l:gsub("^%s+", ""))
            end
            -- Braces on this line; a pending attribute binds to the first `{` that opens an item.
            for ch in code:gmatch("[{}]") do
                if ch == "{" then
                    depth = depth + 1
                    if pending.test or pending.gate then
                        regions[#regions + 1] = { at = depth, test = pending.test, gate = pending.gate }
                        pending = {}
                    end
                else
                    while #regions > 0 and regions[#regions].at == depth do table.remove(regions) end
                    depth = depth - 1
                end
            end
            -- An attribute that bound to a one-line item (no `{`) lapses at its `;`.
            if (pending.test or pending.gate) and code:find(";", 1, true) and not l:match("^%s*#") then pending = {} end
            prev = l
        end
    end
end
for _, b in ipairs(bad) do out.line("REFUSED: " .. b) end
if #bad > 0 then
    out.line("  why: this test reads a Linux-only host path; ./build.sh --check runs the suite on Linux on every host, so it is green there and red natively on Windows and macOS (814-75yf)")
    out.line("  remedy: inject the path (the with_proc_paths + tempdir fixture pattern), gate the test with #[cfg(target_os = \"linux\")], or say why it is portable: // host-path: <reason>")
    verdict.emit("violation:" .. NAME .. ":" .. #bad, 1)
end
verdict.ok(NAME, #files .. " files")
