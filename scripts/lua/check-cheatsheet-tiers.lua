-- @trace spec:cheatsheets-license-tiered, order:1005-m6rz, order:1142-wn2k
-- @env HOME CARGO_HOME CARGO_TARGET_DIR
-- preflight: serial — cargo-builds the tillandsias-policy binary into the shared target/ that other guards execute
--
-- check-cheatsheet-tiers.lua — PORTED from check-cheatsheet-tiers.sh: tier-aware
-- validation of cheatsheet frontmatter and pull-on-demand stub completeness,
-- run by the tillandsias-policy binary (`check-cheatsheet-tiers`), which this
-- builds and then hands the tree to. Same verdicts, same exit codes:
--
--   usage: ... [--quiet] [--strict] [--require-fingerprints] exit 2 (bad flag)
--   ERROR: cheatsheets/ directory not found at <dir>       exit 1
--   skip:cheatsheet-tiers:cargo-absent (...)               exit 0
--   skip:policy-binary-not-host-executable (...)           exit 0
--   otherwise the policy binary's own output and exit status
--
-- Usage: tillandsias-plan script run scripts/lua/check-cheatsheet-tiers.lua [-- --quiet] [-- --strict] [-- --require-fingerprints]
--
-- COULD-NOT-RUN IS NOT A VIOLATION (1005-m6rz): a host with no toolchain gets
-- a named skip, never a bare `cargo: command not found` under an ERROR
-- heading. Cargo resolves through lib/lua/common/cargosites.lua (1005-m6rz): on
-- PATH, else $CARGO_HOME/bin, else $HOME/.cargo/bin (an unset CARGO_HOME is
-- never read as /bin).
--
-- RUN-DON'T-STAT (672-4nts, 770-ifeg, 1142-wn2k): the policy binary is the
-- first candidate that RUNS — locus-native first, $CARGO_TARGET_DIR/debug then
-- target/debug, each bare then .exe — as plan-binary-probe.sh
-- resolve_target_binary does; rc 126/127 (cannot execute) is not a candidate.

local quiet, strict, fingerprints = false, false, false
for _, a in ipairs(arg or {}) do
    if a == "--quiet" then quiet = true
    elseif a == "--strict" then strict = true
    elseif a == "--require-fingerprints" then fingerprints = true -- 588-8mh8
    else
        log.raw("usage: check-cheatsheet-tiers [--quiet] [--strict] [--require-fingerprints]")
        verdict.emit("usage:check-cheatsheet-tiers:unknown-flag:" .. a, 2)
    end
end

local top = proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }
local ROOT = text.trim(top.stdout or "")
if not top.ok or ROOT == "" then ROOT = "." end -- outside git: the runner's own cwd

if not fs.exists("cheatsheets") then
    log.raw("ERROR: cheatsheets/ directory not found at " .. ROOT .. "/cheatsheets")
    verdict.emit("refused:cheatsheet-tiers:no-cheatsheets-dir", 1,
        "  why: the validator judges cheatsheets/, and this tree has none\n  remedy: run from the repository root")
end

-- 1005-m6rz: the shared resolver.
local function runs(bin, a) local p = proc.run{ argv = { bin, a }, timeout_ms = 60000 }; return p.code ~= nil and p.code ~= 126 and p.code ~= 127, p end
local cargo = require("common.cargosites").resolve(function(bin) return (runs(bin, "--version")) end)
if not cargo then
    verdict.emit("skip:cheatsheet-tiers:cargo-absent (no toolchain on this host; check not run)", 0)
end

local b = proc.run{ argv = { cargo, "build", "--quiet", "--manifest-path", ROOT .. "/Cargo.toml", "-p", "tillandsias-policy" },
    timeout_ms = 1800000 }
if not b.ok then
    log.raw(b.stderr or "")
    -- cargo exits 101; a verdict code is 0-3.
    verdict.emit("refused:cheatsheet-tiers:policy-build-failed", 1,
        "  why: cargo could not build tillandsias-policy, so no cheatsheet was judged\n  remedy: fix the build error above")
end

-- resolve_target_binary tillandsias-policy debug ROOT
local ctd = env.get("CARGO_TARGET_DIR") or ""
if ctd ~= "" and not ctd:find("^/") and not ctd:find("^%a:") then ctd = ROOT .. "/" .. ctd end
local dirs = {}
if ctd ~= "" then dirs[#dirs + 1] = ctd .. "/debug" end
dirs[#dirs + 1] = ROOT .. "/target/debug"
local POLICY = nil
for _, d in ipairs(dirs) do
    for _, c in ipairs({ d .. "/tillandsias-policy", d .. "/tillandsias-policy.exe" }) do
        -- A missing file never spawns (code nil): no `test -f` spawn needed.
        if select(1, runs(c, "--help")) then POLICY = c; break end
    end
    if POLICY then break end
end
if not POLICY then
    verdict.emit("skip:policy-binary-not-host-executable (no runnable tillandsias-policy under target/debug or CARGO_TARGET_DIR)", 0)
end

local argv = { POLICY, "check-cheatsheet-tiers", "--repo-root", ROOT }
if quiet then argv[#argv + 1] = "--quiet" end
if strict then argv[#argv + 1] = "--strict" end
if fingerprints then argv[#argv + 1] = "--require-fingerprints" end
local p = proc.run{ argv = argv, timeout_ms = 600000 }
log.raw(p.stderr or "")
for _, l in ipairs(text.lines(p.stdout or "")) do out.line(l) end
if p.ok then verdict.emit("ok:cheatsheet-tiers", 0) end
verdict.emit("violation:cheatsheet-tiers:policy-rc-" .. tostring(p.code), p.code or 1,
    "  why: the tier validator above refused this tree (spec:cheatsheets-license-tiered)\n"
    .. "  remedy: fix each cheatsheet the ERROR lines name" .. (strict and " (and, under --strict, each WARN)" or ""))
