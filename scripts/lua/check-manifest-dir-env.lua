-- @trace order:1590-j20f
--
-- check-manifest-dir-env.lua — refuse a NEW compile-time
-- `env!("CARGO_MANIFEST_DIR")` in Rust test code, and count the standing ones.
--
-- WHY (MEASURED 2026-10-11, cargo 1.99.0). rustc records an `env!()` read as
-- `# env-dep:NAME=value` in its dep-info, and cargo keeps those in the
-- fingerprint, EXCEPT the variables cargo itself sets for rustc:
-- `J20F_PROBE` was kept and a change to it rebuilt, while
-- `CARGO_MANIFEST_DIR` was dropped. So with one CARGO_TARGET_DIR shared by
-- several worktrees, a test binary compiled in worktree A is reused unchanged
-- by `cargo test` in worktree B, and every fixture path it built with
-- `env!("CARGO_MANIFEST_DIR")` still names A's files. B's gate then measures A's
-- tree, or reads NotFound once A is removed. Policy's
-- parity_matrix_accepts_committed_repo_matrix_for_linux_column passed in B
-- over a matrix broken only in B. On one host, 74 of 532 cached executables
-- embedded a checkout other than the one being gated.
--
-- THE REMEDY a refusal names: read the variable at RUNTIME,
-- `std::env::var("CARGO_MANIFEST_DIR")`. cargo sets it for every
-- `cargo test`/`cargo run`, per invocation, to the package's directory in the
-- INVOKING checkout.
--
-- POPULATION: every crates/**/*.rs. A site is TEST CODE when its file is under a
-- `tests/` directory, or it comes at or after the file's first `#[cfg(test)]`
-- line. Comment lines (`//`) are not sites. Non-test sites are counted and
-- printed but never refused: a binary that embeds its build checkout on purpose
-- is another question (non-test=<n> on the ok line).
--
-- THE FLOOR IS PINNED DATA, PER FILE: scripts/portability/manifest-dir-env-floor.txt,
-- `<path> <n>` lines, test sites only. A file above its floor, or absent from it
-- with a nonzero count, is NEW. A floor ABOVE the count is refused too, so a
-- change that converts sites lowers the floor in the same commit, and the floor
-- only falls. `--dump-floor` prints the floor the tree has now.
--
-- Verdicts:
--   ok:manifest-dir-env:scanned=<all>:test=<t>:floor=<f>:non-test=<n>:files=<k>   exit 0
--   violation:manifest-dir-env:new-site:<path>:<n>>floor:<f>                       exit 1
--   violation:manifest-dir-env:stale-floor:<path>:<n><floor:<f>                    exit 1
--   could-not-run:manifest-dir-env:empty-population                               exit 3

local FLOOR_FILE = "scripts/portability/manifest-dir-env-floor.txt"
local SITE = 'env!("CARGO_MANIFEST_DIR")'

local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end
local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; return t end

local ok_walk, files = pcall(fs.walk, "crates", { suffix = ".rs" })
if not ok_walk then files = {} end
table.sort(files)
if #files == 0 then
    verdict.emit("could-not-run:manifest-dir-env:empty-population", 3,
        "no crates/**/*.rs was found: nothing was counted, so nothing is vouched for")
end

-- ── counting ───────────────────────────────────────────────────────────────
local scanned, non_test = 0, 0
local test_count = {} -- path -> test sites
for _, f in ipairs(files) do
    local in_test = f:find("/tests/", 1, true) ~= nil
    for _, l in ipairs(lines(read(f))) do
        if l:match("^%s*#%[cfg%(test%)%]") then in_test = true end
        if not l:match("^%s*//") then
            local start, n = 1, 0
            while true do
                local i = l:find(SITE, start, true)
                if not i then break end
                n = n + 1
                start = i + #SITE
            end
            if n > 0 then
                scanned = scanned + n
                if in_test then test_count[f] = (test_count[f] or 0) + n else non_test = non_test + n end
            end
        end
    end
end

local test_total, test_files = 0, {}
for f, n in pairs(test_count) do test_total = test_total + n; test_files[#test_files + 1] = f end
table.sort(test_files)

if arg[1] == "--dump-floor" then
    out.line("# Per-file compile-time env!(\"CARGO_MANIFEST_DIR\") sites in Rust test code (1590-j20f).")
    out.line("# May only DESCEND: convert a site to std::env::var(\"CARGO_MANIFEST_DIR\") and lower its line.")
    for _, f in ipairs(test_files) do out.line(f .. " " .. test_count[f]) end
    verdict.ok("manifest-dir-env-floor-dumped", tostring(#test_files))
end

-- ── judging against the floor ──────────────────────────────────────────────
local floor, floor_total = {}, 0
for _, l in ipairs(lines(read(FLOOR_FILE))) do
    local f, n = l:match("^%s*(%S+)%s+(%d+)%s*$")
    if f and not f:find("^#") then floor[f] = tonumber(n); floor_total = floor_total + tonumber(n) end
end

local violations = {}
for _, f in ipairs(test_files) do
    local n, fl = test_count[f], floor[f] or 0
    if n > fl then
        violations[#violations + 1] = "violation:manifest-dir-env:new-site:" .. f .. ":" .. n .. ">floor:" .. fl
    end
end
local floor_files = {}
for f, _ in pairs(floor) do floor_files[#floor_files + 1] = f end
table.sort(floor_files)
for _, f in ipairs(floor_files) do
    local n = test_count[f] or 0
    if n < floor[f] then
        violations[#violations + 1] = "violation:manifest-dir-env:stale-floor:" .. f .. ":" .. n .. "<floor:" .. floor[f]
    end
end

if #violations > 0 then
    for i = 1, #violations - 1 do out.line(violations[i]) end
    log.raw("[check-manifest-dir-env] a test that builds a path from compile-time env!(\"CARGO_MANIFEST_DIR\") reads the")
    log.raw("  checkout that COMPILED it: with a shared CARGO_TARGET_DIR cargo reuses that binary from another")
    log.raw("  worktree (cargo drops the env-dep it set itself; 1590-j20f). Read it at runtime instead:")
    log.raw("  std::path::PathBuf::from(std::env::var(\"CARGO_MANIFEST_DIR\").expect(\"cargo sets CARGO_MANIFEST_DIR\"))")
    log.raw("  A stale-floor line means sites were removed: lower " .. FLOOR_FILE .. " (--dump-floor prints it).")
    verdict.emit(violations[#violations], 1)
end

verdict.ok("manifest-dir-env", "scanned=" .. scanned, "test=" .. test_total, "floor=" .. floor_total,
    "non-test=" .. non_test, "files=" .. #test_files)
