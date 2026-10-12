-- @trace order:1631-6w8z
-- @env CARGO_TARGET_DIR TILLANDSIAS_GATE_DIFF_BASE TILLANDSIAS_RUST_LINTS_BASE
-- preflight: own-deadline — cargo fmt takes ~5 s and a touched crate's clippy 10-60 s under taskpolicy -b, past the 5 s guard deadline, so the door runs these beside the roster against its whole budget
--
-- check-rust-lints.lua — the gate's cargo fmt and clippy refusals, asked at
-- the preflight door. The gate runs `cargo fmt --check --all` and two clippy
-- lines with -D warnings (build.sh's check path: the workspace, and
-- tillandsias-headless with listen-vsock) INLINE, as cargo commands, so no
-- script carried them into the door's roster. #340 then spent a full gate run
-- (~23 min) on clippy collapsible_if and #359 one on a fmt miss, after a
-- preflight that passed both.
--
--   fmt     `cargo fmt --check --all`. Needs no build. Unconditional.
--   clippy  the gate's clippy line SCOPED to the crates the change touches
--           (-p <package> per crates/<dir>/ touched, against the merge base
--           of TILLANDSIAS_GATE_DIFF_BASE, plus untracked files), and the
--           listen-vsock line when tillandsias-headless is touched. A touched
--           root Cargo.toml or Cargo.lock runs the unscoped workspace line.
--           A change that touches no crate runs no cargo at all.
--
-- WHAT THE SCOPE CANNOT SEE. `-p` resolves features for the selected
-- packages only, while the gate's workspace pass unifies them across every
-- member, so a lint behind a feature that only a dependent enables is the
-- gate's to find. This guard vouches for the touched crates as built alone.
--
-- THE DEADLINE IS THE DOOR'S, not this script's: it declares own-deadline,
-- and the door runs it beside the roster and kills it at the budget. A kill
-- is reported skipped-by-deadline, never refused.
--
-- GRAMMAR (detail lines above the verdict)
--   unformatted:<path>                                  one per file
--   lint:<package>:<lint>:<path>:<line>                 one per diagnostic
--   ok:rust-fmt                                         exit 0
--   refused:rust-fmt:<first path>[:+<n> more]           exit 1
--   ok:rust-clippy:<packages, comma-joined>[+listen-vsock]
--   note:rust-clippy:no-crate-touched — ..., then
--   skip:rust-clippy:no-crate-touched                   exit 0, ran no cargo
--   refused:rust-clippy:<package>:<lint>[:+<n> more]    exit 1
--   could-not-run:rust-lints:<why>                      exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/check-rust-lints.lua -- fmt|clippy [<root>]
--   <root> is a directory to judge instead of the checkout (the fixture's
--   scratch workspace); TILLANDSIAS_RUST_LINTS_BASE overrides the base ref.

local MODE = arg[1] or ""
if MODE ~= "fmt" and MODE ~= "clippy" then
    verdict.could_not_run("rust-lints", "usage: check-rust-lints.lua -- fmt|clippy [<root>] (got '" .. MODE .. "')")
end

local ROOT = arg[2]
if not ROOT or ROOT == "" then
    local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
    ROOT = text.trim(top.stdout or "")
    if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
        verdict.could_not_run("rust-lints", "git rev-parse --show-toplevel did not answer")
    end
end
local TARGET_DIR = env.get("CARGO_TARGET_DIR") or ""

local function rel(p)
    if p:sub(1, #ROOT + 1) == ROOT .. "/" then return p:sub(#ROOT + 2) end
    return p
end
local function more(n) return n > 1 and (":+" .. tostring(n - 1) .. " more") or "" end

-- ── fmt ─────────────────────────────────────────────────────────────────────
if MODE == "fmt" then
    local r = proc.run({ argv = { "cargo", "fmt", "--check", "--all" }, cwd = ROOT, timeout_ms = 1800000 })
    if r.status ~= "exited" then
        verdict.could_not_run("rust-lints", "cargo fmt did not exit (" .. tostring(r.status) .. ")")
    end
    if r.code == 0 then verdict.emit("ok:rust-fmt", 0) end
    -- rustfmt names each file as `Diff in <path>:<line>:` (older) or
    -- `Diff in <path> at line <n>:` (newer); both are read.
    local files, seen = {}, {}
    for _, l in ipairs(text.lines((r.stdout or "") .. "\n" .. (r.stderr or ""))) do
        local p = l:match("^Diff in (.-):%d+:%s*$") or l:match("^Diff in (.-) at line %d+:%s*$")
        if p and not seen[p] then
            seen[p] = true
            files[#files + 1] = rel(p)
        end
    end
    if #files == 0 then
        -- exit 1 with no Diff line is a parse or toolchain error, not a format verdict
        for _, l in ipairs(text.lines(r.stderr or "")) do if l ~= "" then log.raw(l) end end
        verdict.could_not_run("rust-lints", "cargo fmt --check exited " .. tostring(r.code) .. " without naming an unformatted file")
    end
    for _, f in ipairs(files) do out.line("unformatted:" .. f) end
    verdict.emit("refused:rust-fmt:" .. files[1] .. more(#files), 1,
        "the gate runs cargo fmt --check --all and refuses this; run cargo fmt --all and commit")
end

-- ── clippy ──────────────────────────────────────────────────────────────────
local function git(args)
    local argv = { "git", "-C", ROOT }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

local base_ref = env.get("TILLANDSIAS_RUST_LINTS_BASE") or env.get("TILLANDSIAS_GATE_DIFF_BASE") or "origin/linux-next"
local mb = git({ "merge-base", base_ref, "HEAD" })
if not mb or text.trim(mb) == "" then
    verdict.could_not_run("rust-lints", "no merge base between " .. base_ref .. " and HEAD, so the touched crates are unknown")
end
mb = text.trim(mb)

local touched = {}
for _, src in ipairs({ git({ "diff", "--name-only", mb }) or "", git({ "ls-files", "--others", "--exclude-standard" }) or "" }) do
    for _, l in ipairs(text.lines(src)) do if l ~= "" then touched[#touched + 1] = l end end
end

local whole, dirs, dir_seen = false, {}, {}
for _, p in ipairs(touched) do
    if p == "Cargo.toml" or p == "Cargo.lock" then whole = true end
    local d = p:match("^crates/([^/]+)/")
    if d and not dir_seen[d] then
        dir_seen[d] = true
        dirs[#dirs + 1] = d
    end
end
table.sort(dirs)

local pkgs, pkg_of_dir = {}, {}
for _, d in ipairs(dirs) do
    local ok, body = pcall(fs.read, ROOT .. "/crates/" .. d .. "/Cargo.toml")
    if ok and body then
        local name = body:match('%[package%][^%[]-\nname%s*=%s*"([^"]+)"')
        if name then
            pkgs[#pkgs + 1] = name
            pkg_of_dir[d] = name
        end
    end
end
if not whole and #pkgs == 0 then
    -- the door prints a passing guard's note: lines only, so the reader sees
    -- that no clippy ran rather than an unexplained pass
    out.line("note:rust-clippy:no-crate-touched — no cargo ran (merge base " .. mb:sub(1, 12) .. ")")
    verdict.emit("skip:rust-clippy:no-crate-touched", 0,
        "the change touches no crate and neither root Cargo file, so no clippy ran; the gate still runs its workspace pass")
end

local function package_of(file)
    local d = rel(file):match("^crates/([^/]+)/")
    return (d and pkg_of_dir[d]) or d or "workspace"
end

local function clippy(extra)
    local argv = { "cargo", "clippy", "--all-targets", "--message-format=json" }
    for _, a in ipairs(extra) do argv[#argv + 1] = a end
    if TARGET_DIR ~= "" then
        argv[#argv + 1] = "--target-dir"
        argv[#argv + 1] = TARGET_DIR
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = "-D"
    argv[#argv + 1] = "warnings"
    return proc.run({ argv = argv, cwd = ROOT, timeout_ms = 3600000 })
end

-- one diagnostic is reported once per target that compiles the file (lib and
-- its test harness both do), so a site is counted once
local hits, hit_seen = {}, {}
local function add_hit(h)
    local k = h.pkg .. "\0" .. h.lint .. "\0" .. h.file .. "\0" .. tostring(h.line)
    if hit_seen[k] then return end
    hit_seen[k] = true
    hits[#hits + 1] = h
end
local function run_line(extra, label)
    local r = clippy(extra)
    if r.status ~= "exited" then
        verdict.could_not_run("rust-lints", "cargo clippy (" .. label .. ") did not exit (" .. tostring(r.status) .. ")")
    end
    if r.code == 0 then return end
    local diags = 0
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l:sub(1, 1) == "{" then
            local ok, m = pcall(json.parse, l)
            if ok and type(m) == "table" and m.reason == "compiler-message" and type(m.message) == "table"
                and m.message.level == "error" then
                local code = type(m.message.code) == "table" and m.message.code.code or nil
                local file, line = "?", 0
                for _, s in ipairs(m.message.spans or {}) do
                    if s.is_primary then file, line = s.file_name or "?", s.line_start or 0; break end
                end
                diags = diags + 1
                if code then
                    add_hit({ pkg = package_of(file), lint = code, file = rel(file), line = line })
                elseif not (m.message.message or ""):match("^aborting due to") then
                    add_hit({ pkg = package_of(file), lint = "error", file = rel(file), line = line })
                end
            end
        end
    end
    if diags == 0 then
        for _, l in ipairs(text.lines(r.stderr or "")) do
            if text.is_match(l, "^error|^  --> |could not compile") then log.raw(l) end
        end
        verdict.could_not_run("rust-lints", "cargo clippy (" .. label .. ") exited " .. tostring(r.code) .. " without a compiler diagnostic")
    end
end

local label
if whole then
    run_line({}, "workspace")
    label = "workspace"
else
    local extra = {}
    for _, p in ipairs(pkgs) do
        extra[#extra + 1] = "-p"
        extra[#extra + 1] = p
    end
    run_line(extra, table.concat(pkgs, ","))
    label = table.concat(pkgs, ",")
end
local headless = whole or pkg_of_dir["tillandsias-headless"] ~= nil
if headless and fs.exists(ROOT .. "/crates/tillandsias-headless/Cargo.toml") then
    run_line({ "-p", "tillandsias-headless", "--features", "listen-vsock" }, "tillandsias-headless+listen-vsock")
    label = label .. "+listen-vsock"
end

if #hits == 0 then
    out.line("note:rust-clippy:clean:" .. label)
    verdict.emit("ok:rust-clippy:" .. label, 0)
end
for _, h in ipairs(hits) do
    out.line("lint:" .. h.pkg .. ":" .. h.lint .. ":" .. h.file .. ":" .. tostring(h.line))
end
verdict.emit("refused:rust-clippy:" .. hits[1].pkg .. ":" .. hits[1].lint .. more(#hits), 1,
    "the gate's clippy -D warnings refuses this; the lint lines above name each site")
