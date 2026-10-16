-- @trace spec:cheatsheet-source-layer, order:1637-cnxq
-- @env CARGO_TARGET_DIR
-- preflight: serial — cargo-builds the tillandsias-policy binary into the shared target/ that other guards execute
--
-- check-cheatsheet-sources.lua — validate cheatsheet ↔ verbatim-source binding.
-- Ported from scripts/check-cheatsheet-sources.sh (the shell-to-lua item the
-- 1637-cnxq change carried; its history is in
-- `git log -- scripts/check-cheatsheet-sources.sh`). The validation logic is
-- the Rust `tillandsias-policy check-cheatsheet-sources` subcommand
-- (crates/tillandsias-policy, per the no-Python-runtime policy); this decider
-- builds that binary, probes it by execution, asks it, and relays its lines.
--
-- Usage:
--   tillandsias-plan script run scripts/lua/check-cheatsheet-sources.lua -- [--no-sha]
--
-- Checks (per §5 of docs/strategy/cheatsheet-source-layer-plan.md; the shape
-- litmus greps these four lines, so they stay as written):
--   1. For every cheatsheet's ## Provenance URL: must be in INDEX.json
--      (WARNING if unfetched — not yet blocking).
--   2. For every local: path in ## Provenance: file exists OR sidecar has
--      redistribution: do-not-bundle / manual-review-required.
--   3. Orphan detection: every INDEX.json entry must be cited by at least
--      one cheatsheet (WARNING, not ERROR — new fetches may not be cited yet).
--   4. SHA-check: re-hash present files, compare to INDEX.json manifest
--      (skip with --no-sha for speed in pre-commit contexts).
--
-- Since the 2026-08-23 retirement of the verbatim layer (tombstone
-- cheatsheet-sources/.gitkeep-tombstone, superseded by cheatsheets-license-tiered)
-- the binary answers ok:cheatsheet-sources-retired on every tree; the check
-- stays for the three-release retention window (888-jfsz owns its removal).
--
-- REDIRECTED TARGET DIRS: proc.run children start from a scrubbed environment,
-- so CARGO_TARGET_DIR is passed to cargo as --target-dir and to the probe
-- explicitly (the same seam as check-no-python-scripts.lua).
--
-- RUN-DON'T-STAT (order 770-ifeg): the binary is found by
-- scripts/plan-binary-probe.sh's resolve_target_binary, which returns a
-- candidate only when it executes (a shared Windows/WSL checkout can hold the
-- other platform's artifact at the extensionless path).
--
-- GRAMMAR. The binary's own stdout lines are relayed above the verdict and its
-- stderr lines verbatim; the exit code is the binary's, as the .sh exec'd it.
--   ok:cheatsheet-sources                                   exit 0
--   violation:cheatsheet-sources:<rc>                       exit <rc>  (ERROR-level findings)
--   refused:cheatsheet-sources:unknown-argument:<arg>       exit 2     (the .sh's usage error, same code)
--   refused:no-runnable-tillandsias-policy                  exit 1
--   could-not-run:cheatsheet-sources:build-failed           exit 3
--   could-not-run:cheatsheet-sources                        exit 3     (no repo root; reason on stderr)

-- Validate flags first, before any build, so a usage error stays as cheap and
-- as shaped as the historical script's.
local pass = {}
for i = 1, #arg do
    local a = arg[i]
    if a == "--no-sha" then
        pass[#pass + 1] = a
    else
        log.raw("error: unknown argument: " .. a)
        log.raw("usage: check-cheatsheet-sources.lua [--no-sha]")
        verdict.emit("refused:cheatsheet-sources:unknown-argument:" .. a, 2)
    end
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("cheatsheet-sources", "git rev-parse --show-toplevel did not answer")
end
local target_dir = env.get("CARGO_TARGET_DIR") or ""

local argv = { "cargo", "build", "--quiet", "-p", "tillandsias-policy" }
if target_dir ~= "" then
    argv[#argv + 1] = "--target-dir"
    argv[#argv + 1] = target_dir
end
local b = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 1800000 })
if b.status ~= "exited" or b.code ~= 0 then
    for _, l in ipairs(text.lines((b.stderr or "") .. "\n" .. (b.stdout or ""))) do
        if text.is_match(l, "^error|^  --> |could not compile") then log.raw(l) end
    end
    verdict.emit("could-not-run:cheatsheet-sources:build-failed", 3,
        "cargo build -p tillandsias-policy did not succeed, so the question was never asked")
end

local penv = {}
if target_dir ~= "" then penv.CARGO_TARGET_DIR = target_dir end
local probe = proc.run({ argv = { "bash", "-s" }, cwd = ROOT, env = penv, timeout_ms = 60000,
    stdin = '. scripts/plan-binary-probe.sh\nresolve_target_binary tillandsias-policy debug "$PWD"\n' })
local bin = text.trim(probe.stdout or "")
if probe.status ~= "exited" or probe.code ~= 0 or bin == "" then
    verdict.emit("refused:no-runnable-tillandsias-policy", 1,
        "probed target/debug and CARGO_TARGET_DIR by execution and nothing ran")
end

local run = { bin, "check-cheatsheet-sources", "--repo-root", ROOT }
for _, a in ipairs(pass) do run[#run + 1] = a end
local r = proc.run({ argv = run, cwd = ROOT, timeout_ms = 300000 })
for _, l in ipairs(text.lines(r.stdout or "")) do if l ~= "" then out.line(l) end end
for _, l in ipairs(text.lines(r.stderr or "")) do if l ~= "" then log.raw(l) end end
if r.status == "exited" and r.code == 0 then
    verdict.emit("ok:cheatsheet-sources", 0)
end
local rc = (r.status == "exited" and r.code >= 1 and r.code <= 3) and r.code or 1
verdict.emit("violation:cheatsheet-sources:" .. tostring(rc), rc)
