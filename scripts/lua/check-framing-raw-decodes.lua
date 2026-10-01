-- @trace order:1527-v7cy, order:795-5itp, spec:vsock-transport
--
-- check-framing-raw-decodes.lua — PORTED from check-framing-raw-decodes.sh,
-- byte for byte. A ratchet, not an end-state assertion: the scan over
-- crates/ counting RAW frame-length decodes (`u32::from_be_bytes` outside a
-- comment) is refused the moment a NEW hand-rolled copy appears, and equally
-- refused when scripts/framing-raw-decode-baseline.tsv is left stale after a
-- slice lands — see the .sh's header for why "at most one" would fail on day
-- one and protect nothing.
--
-- WHAT THE PORT DROPS AS UNREACHABLE: the .sh's `blocked:framing-ratchet-not-
-- a-git-repo` branch guarded a `cd` to a BASH_SOURCE-derived repo root, which
-- cannot fail under this runner (always invoked repo-rooted by
-- `tillandsias-plan script run`); no fixture or litmus arm exercises it
-- (openspec/litmus-tests/litmus-one-length-delimited-framing-impl.yaml has
-- five arms: ok, new-site, regressed, stale, no-baseline). Dropped rather
-- than faked.
--
-- A decode is a LINE matching `u32::from_be_bytes` whose trimmed text does
-- not start with "//" or "*" (the .sh's `grep -c` line-count, not an
-- occurrence count, filtered the same way as check-state-root-literals.lua).
--
-- Verdict grammar (unchanged, legacy):
--   ok:framing-ratchet:sites=<n>:files=<n>
--   blocked:framing-ratchet-new-site:<path>
--   blocked:framing-ratchet-regressed:<path>:<actual>>:<baseline>
--   blocked:framing-ratchet-stale:<path>:<actual><:<baseline>
--   blocked:framing-ratchet-no-baseline
local BASELINE_FILE = "scripts/framing-raw-decode-baseline.tsv"

local ok_base, baseline_src = pcall(fs.read, BASELINE_FILE)
if not ok_base then
    verdict.emit("blocked:framing-ratchet-no-baseline", 1)
end

-- Parse the TSV: comment/blank lines (leading "#" or empty) are skipped, kept
-- both as a lookup (first occurrence wins — the live baseline has no
-- duplicate path, so this is unobservable) and in FILE ORDER for the second
-- (stale-entry) pass.
local baseline_lookup = {}
local baseline_rows = {}
for _, l in ipairs(text.lines(baseline_src)) do
    local lead = l:match("^(%S*)")
    if lead ~= "" and lead:sub(1, 1) ~= "#" then
        local bcount, bpath = l:match("^([^\t]*)\t([^\t]*)")
        if bcount and bpath then
            if baseline_lookup[bpath] == nil then baseline_lookup[bpath] = bcount end
            baseline_rows[#baseline_rows + 1] = { count = bcount, path = bpath }
        end
    end
end

local DECODE = "u32::from_be_bytes"

local actual = {}       -- path -> count, for files with count > 0
local actual_order = {} -- sorted file order (fs.walk is already lexical)
local total_sites = 0
local total_files = 0

local ok_walk, files = pcall(fs.walk, "crates", { suffix = ".rs" })
if ok_walk then
    for _, f in ipairs(files) do
        local ok_r, content = pcall(fs.read, f)
        if ok_r then
            local c = 0
            for _, line in ipairs(text.lines(content)) do
                if text.contains(line, DECODE) then
                    local trimmed = line:match("^%s*(.*)$")
                    if not (trimmed:sub(1, 2) == "//" or trimmed:sub(1, 1) == "*") then
                        c = c + 1
                    end
                end
            end
            if c > 0 then
                actual[f] = c
                actual_order[#actual_order + 1] = f
            end
        end
    end
end

-- (1) every scanned file must be in the baseline, and must not exceed it.
for _, f in ipairs(actual_order) do
    local count = actual[f]
    total_sites = total_sites + count
    total_files = total_files + 1
    local base = baseline_lookup[f]
    if base == nil then
        verdict.emit("blocked:framing-ratchet-new-site:" .. f, 1)
    end
    local base_n = tonumber(base) or 0
    if count > base_n then
        verdict.emit("blocked:framing-ratchet-regressed:" .. f .. ":" .. count .. ">" .. base, 1)
    end
    if count < base_n then
        verdict.emit("blocked:framing-ratchet-stale:" .. f .. ":" .. count .. "<" .. base, 1)
    end
end

-- (2) a baseline entry whose file no longer has any site is also stale.
for _, row in ipairs(baseline_rows) do
    if actual[row.path] == nil then
        verdict.emit("blocked:framing-ratchet-stale:" .. row.path .. ":0<" .. row.count, 1)
    end
end

verdict.emit("ok:framing-ratchet:sites=" .. total_sites .. ":files=" .. total_files, 0)
