-- @trace order:1527-v7cy, order:245, spec:enclave-network
-- @env TILLANDSIAS_ENCLAVE_SPEC TILLANDSIAS_ENCLAVE_SRC_ROOT
-- @read-env TILLANDSIAS_ENCLAVE_SPEC TILLANDSIAS_ENCLAVE_SRC_ROOT
--
-- check-enclave-membership-documented.lua — PORTED from
-- check-enclave-membership-documented.sh, byte for byte. ORDER 245 §5 P8:
-- openspec/specs/enclave-network/spec.md's membership list must agree, in
-- both directions, with the code that actually attaches a container to the
-- enclave (ENCLAVE_NET / ENCLAVE_ONLY_NET / ENCLAVE_EGRESS_NETS). See the
-- .sh's header for the 2026-08-30 defect this exists for.
--
-- TILLANDSIAS_ENCLAVE_SPEC / TILLANDSIAS_ENCLAVE_SRC_ROOT are test seams
-- (openspec/litmus-tests/litmus-enclave-membership-documented.yaml points them
-- at a fixture built with `mktemp -d`, outside the repo); -- @read-env widens
-- fs.read/fs.walk under each. fs.exists is NOT widened by @read-env (only
-- read and walk are), so the "$SRC_ROOT is a directory" precondition is
-- tested the same way attach_functions() itself needs the directory to
-- exist: by walking it and treating a walk failure as missing, rather than a
-- separate fs.exists call that would raise on an out-of-repo fixture path.
--
-- Only TOP-LEVEL functions are tracked (`fn` at column 0, exactly the .sh's
-- awk state machine, ported line for line) — a nested helper or a
-- #[cfg(test)] fn is excluded because it is never at column 0, not by a
-- separate textual cut of the cfg(test) region (the .sh's header mentions
-- such a cut; the actual awk has none, and the SCOPE CONTROL litmus arm
-- passes because the nested/test fn's ENCLAVE_NET usage re-attributes to
-- the last TOP-LEVEL fn seen, which is already a documented member — not
-- because the fixture is excised. Ported as the code behaves, not as the
-- prose claims it does).
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh's population is first
-- `grep -rl` filtered to files containing any of the three constants, then
-- re-scanned line by line for the same constants. This port runs the
-- line-by-line state machine over every *.rs file directly — a file with no
-- occurrence simply contributes nothing, so the outcome is identical and the
-- pre-filter pass is redundant work this port does not repeat.
--
-- Verdict grammar (unchanged, legacy):
--   ok:enclave-membership:<n> attach site(s) documented      exit 0
--   violation:enclave-membership:undocumented=<n>:stale=<n>  exit 1
--   blocked:spec-unreadable:<spec>                           exit 2
--   blocked:src-root-missing:<root>                           exit 2
--   blocked:no-attach-sites-parsed                            exit 2
--   blocked:spec-names-no-attach-functions                    exit 2
local spec_env = env.get("TILLANDSIAS_ENCLAVE_SPEC")
local SPEC = (spec_env and spec_env ~= "") and spec_env or "openspec/specs/enclave-network/spec.md"
local src_env = env.get("TILLANDSIAS_ENCLAVE_SRC_ROOT")
local SRC_ROOT = (src_env and src_env ~= "") and src_env or "crates"

local ok_spec, spec_src = pcall(fs.read, SPEC)
if not ok_spec then
    verdict.emit("blocked:spec-unreadable:" .. SPEC, 2)
end

local ok_src, rs_files = pcall(fs.walk, SRC_ROOT, { suffix = ".rs" })
if not ok_src then
    verdict.emit("blocked:src-root-missing:" .. SRC_ROOT, 2)
end

local FN_TRIGGER = [[^(pub |pub\(crate\) |async |pub async )?fn [a-z_]+]]
local FN_NAME = [[fn ([a-z_]+)]]
local ENCLAVE_MARK = [[ENCLAVE_NET|ENCLAVE_ONLY_NET|ENCLAVE_EGRESS_NETS]]
local BUILD_LAUNCH = [[^(build|launch)_]]

local found = {}
for _, f in ipairs(rs_files) do
    local ok_r, content = pcall(fs.read, f)
    if ok_r then
        local fname = nil
        for _, line in ipairs(text.lines(content)) do
            if text.is_match(line, FN_TRIGGER) then
                local caps = text.captures_all(line, FN_NAME)
                if caps[1] then fname = caps[1] end
            elseif text.is_match(line, ENCLAVE_MARK) then
                if fname and text.is_match(fname, BUILD_LAUNCH) then
                    found[#found + 1] = fname
                end
            end
        end
    end
end

local function sorted_unique(list)
    local set = {}
    for _, v in ipairs(list) do set[v] = true end
    local out = {}
    for v in pairs(set) do out[#out + 1] = v end
    table.sort(out)
    return out
end

local actual = sorted_unique(found)

local listed_raw = {}
for _, name in ipairs(text.captures_all(spec_src, [[`fn ([a-z_]+)`]])) do
    listed_raw[#listed_raw + 1] = name
end
local listed = sorted_unique(listed_raw)

if #actual == 0 then
    verdict.emit("blocked:no-attach-sites-parsed", 2)
end
if #listed == 0 then
    verdict.emit("blocked:spec-names-no-attach-functions", 2)
end

local listed_set, actual_set = {}, {}
for _, v in ipairs(listed) do listed_set[v] = true end
for _, v in ipairs(actual) do actual_set[v] = true end

local undocumented, stale = {}, {}
for _, v in ipairs(actual) do
    if not listed_set[v] then undocumented[#undocumented + 1] = v end
end
for _, v in ipairs(listed) do
    if not actual_set[v] then stale[#stale + 1] = v end
end

if #undocumented ~= 0 or #stale ~= 0 then
    if #undocumented ~= 0 then
        log.raw("  Functions that attach to the enclave and are NOT named in " .. SPEC .. ":")
        for _, v in ipairs(undocumented) do log.raw("    undocumented: " .. v) end
    end
    if #stale ~= 0 then
        log.raw("  Functions " .. SPEC .. " names that no longer attach to the enclave:")
        for _, v in ipairs(stale) do log.raw("    stale:        " .. v) end
    end
    log.raw("  The membership list is symbol-anchored precisely so this cannot drift")
    log.raw("  in silence: a prose list went stale by five members before this guard")
    log.raw("  existed (order 245 P8). Add or remove the bullet in the SAME commit as")
    log.raw("  the attach change.")
    verdict.emit("violation:enclave-membership:undocumented=" .. #undocumented .. ":stale=" .. #stale, 1)
end

verdict.emit("ok:enclave-membership:" .. #actual .. " attach site(s) documented", 0)
