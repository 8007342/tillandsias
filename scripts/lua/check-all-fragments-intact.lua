-- @trace order:1527-v7cy, order:1500-gu5r, order:846-idhn, order:746-htj9
-- @env TILLANDSIAS_FRAGMENT_SCAN_ROOT
-- @read-env TILLANDSIAS_FRAGMENT_SCAN_ROOT
--
-- check-all-fragments-intact.lua — PORTED from check-all-fragments-intact.sh,
-- byte for byte. Every ledger fragment on disk parses AND carries no conflict
-- markers (whole overlay, not just the outgoing diff) — see the .sh's header
-- for the 2026-08-23 incident this exists for and why parseability alone is
-- not integrity (a marker indented inside a `summary: |` block scalar is
-- valid YAML).
--
-- TILLANDSIAS_FRAGMENT_SCAN_ROOT is a TEST SEAM
-- (scripts/test-all-fragments-intact.sh points it at an external
-- `mktemp -d` fixture); -- @read-env widens fs.read/fs.walk under it. The
-- repository's YAML validator (scripts/tillandsias-policy) is resolved
-- against the REAL repo root always, never the scan root, exactly as the
-- .sh's POLICY="$ROOT/..." (built from BASH_SOURCE) differs from
-- SCAN_ROOT — only the validator's CWD follows the scan root, so its
-- relative file arguments resolve the same way they did for the shell's own
-- `cd "$SCAN_ROOT"`. fs.exists is not @read-env-widened, which is fine here:
-- the validator's existence is checked at the real repo root, never under an
-- out-of-repo scan root.
--
-- ORDER 1500-gu5r (door-deadline speed-up, inherited unchanged): this guard
-- is timed against the preflight door's 5 s deadline. The .sh already does
-- two bulk passes instead of a per-fragment spawn; this port does the marker
-- test and the YAML parse entirely in-process except for ONE proc.run call
-- into the policy binary for every surviving .yaml candidate, in place of the
-- .sh's xargs-batched grep AND validate-yaml spawns.
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh's population is the shell
-- glob "$d"/* (one level, never recursive, and `-f` follows a symlink to a
-- regular file); this port's fs.walk is recursive, so results are filtered to
-- direct children only (unobservable: no fragment directory nests a
-- subdirectory today), and a symlinked fragment is excluded rather than
-- followed (none exist today either).
--
-- Verdict grammar (unchanged, legacy):
--   ok:all-fragments-intact:<n> checked       exit 0
--   blocked:all-fragments-intact:<n> damaged  exit 1
--   blocked:all-fragments-intact:no-yaml-validator  exit 2
local scan_env = env.get("TILLANDSIAS_FRAGMENT_SCAN_ROOT")
local SCAN_ROOT = (scan_env and scan_env ~= "") and scan_env or nil

local function rooted(rel)
    if SCAN_ROOT then return SCAN_ROOT .. "/" .. rel end
    return rel
end

if not fs.exists("scripts/tillandsias-policy") then
    verdict.emit("blocked:all-fragments-intact:no-yaml-validator", 2)
end

-- The validator binary is always resolved from the REAL repo root. Under the
-- default (no scan-root override) that is simply a repo-relative argv[0],
-- spawned with the default cwd (the repo root). Under the test seam, the
-- repo root and the scan root differ, so an absolute policy path is needed —
-- fetched once via `pwd` at the default cwd, never under the scan root.
local POLICY = "scripts/tillandsias-policy"
if SCAN_ROOT then
    local pw = proc.run({ argv = { "pwd" } })
    if not (pw.status == "exited" and pw.ok) then
        verdict.emit("blocked:all-fragments-intact:no-yaml-validator", 2)
    end
    POLICY = text.trim(pw.stdout) .. "/scripts/tillandsias-policy"
end

local FRAG_DIRS = { "plan/index.d", "plan/loop_status.d", "plan/mo-full-attestations.d" }

-- Two parallel paths per file: `read_path` (rooted under SCAN_ROOT, used only
-- for fs.read — needs the @read-env-widened absolute form to reach outside
-- the repo) and `disp_path` (always SCAN_ROOT-relative, e.g.
-- "plan/index.d/foo.yaml"). The .sh `cd`s into SCAN_ROOT before it ever names
-- a file, so every diagnostic line and every argument it hands the validator
-- is relative; disp_path reproduces that, read_path is this port's own seam.
local files = {}       -- ordered list of disp_path
local read_path = {}   -- disp_path -> read_path

for _, d in ipairs(FRAG_DIRS) do
    local dir_path = rooted(d)
    local ok_walk, walked = pcall(fs.walk, dir_path)
    if ok_walk then
        local direct = {}
        for _, f in ipairs(walked) do
            local rel = f:sub(#dir_path + 2)
            if not rel:find("/", 1, true) and rel ~= "README.md" then
                direct[#direct + 1] = rel
            end
        end
        table.sort(direct)
        for _, rel in ipairs(direct) do
            local disp = d .. "/" .. rel
            files[#files + 1] = disp
            read_path[disp] = dir_path .. "/" .. rel
        end
    end
end

-- Leading whitespace allowed is the whole point: a marker indented inside a
-- `summary: |` block scalar parses as valid YAML and is invisible to a
-- column-0 grep.
local MARKER = [=[^[[:space:]]*(<{7}|={7}|>{7})( |$)]=]

local checked = 0
local reason = {}          -- disp_path -> "marker" | "parse"
local yaml_candidates = {}

for _, disp in ipairs(files) do
    checked = checked + 1
    local ok_r, content = pcall(fs.read, read_path[disp])
    local has_marker = false
    if ok_r then
        for _, line in ipairs(text.lines(content)) do
            if text.is_match(line, MARKER) then
                has_marker = true
                break
            end
        end
    end
    if has_marker then
        reason[disp] = "marker"
    elseif disp:match("%.yaml$") then
        yaml_candidates[#yaml_candidates + 1] = disp
    end
end

if #yaml_candidates > 0 then
    local argv = { POLICY, "validate-yaml" }
    for _, disp in ipairs(yaml_candidates) do argv[#argv + 1] = disp end
    local res = proc.run({ argv = argv, cwd = SCAN_ROOT })
    local parsed = {}
    if res.status == "exited" then
        for _, l in ipairs(text.lines(res.stdout)) do
            local p = l:match("^ok: (.+)$")
            if p then parsed[p] = true end
        end
    end
    for _, disp in ipairs(yaml_candidates) do
        if not parsed[disp] then reason[disp] = "parse" end
    end
end

local damaged = 0
for _, disp in ipairs(files) do
    local r = reason[disp]
    if r == "marker" then
        damaged = damaged + 1
        log.raw("  damaged: " .. disp .. " — carries a conflict marker")
    elseif r == "parse" then
        damaged = damaged + 1
        log.raw("  damaged: " .. disp .. " — does not parse as YAML")
    end
end

if damaged > 0 then
    log.raw("  A ledger fragment is APPEND-ONLY and IMMUTABLE; damage here is not a")
    log.raw("  merge to resolve but a file to restore from its authoring commit.")
    log.raw("  If this appeared after merging a platform branch, suspect git rename")
    log.raw("  detection pairing two hosts' set-field fragments (2026-08-23).")
    verdict.emit("blocked:all-fragments-intact:" .. damaged .. " damaged", 1)
end

verdict.emit("ok:all-fragments-intact:" .. checked .. " checked", 0)
