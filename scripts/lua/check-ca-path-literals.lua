-- @env TILLANDSIAS_CA_PATH_LITERAL_BASELINE
-- @trace order:998-qrwu, order:975-rsgm, order:1526-gv3t
--
-- check-ca-path-literals.lua — PORTED from check-ca-path-literals.sh, byte for
-- byte. The `/tmp/tillandsias-ca` literal count may not GROW. It is now a
-- REGRESSION PIN against the old path coming back, not a ratchet over pending
-- debt: 998-qrwu single-sourced the path and 998-3z6g moved it off /tmp, and
-- both have landed.
--
-- WHAT THIS GUARD DOES NOT WATCH: its subject is the PRE-migration literal
-- `/tmp/tillandsias-ca`. It has never watched the post-migration CA directory,
-- and it has never watched the state ROOT those paths share (that guard is
-- check-state-root-literals.sh / 1027-539s). Do not read a green verdict here
-- as coverage of either.
--
-- THE SURVIVING OCCURRENCE is not debt: it is in
-- images/default/cheatsheets/runtime/low-end-cpu-inference-floor.md, where the
-- sentence explicitly says the cause is PAST.
--
-- COUNT OCCURRENCES, NOT LINES: a line can carry the literal twice, and the
-- unit that matters is the number of SITES that must move. text.captures_all
-- is used with a capturing group around the whole literal so repeated matches
-- on one line are each counted, the same as the .sh's `grep -o ... | wc -l`.
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh's `grep -r` traverses
-- crates/, scripts/, images/ in OS directory order and silently skips a file
-- it cannot decode as text (grep calls it binary and skips it); this port's
-- fs.walk is lexically sorted and a file fs.read cannot decode as UTF-8 is
-- skipped the same way (pcall), so the SET and COUNT are identical, only file
-- visitation order can differ — unobservable here since only a total count is
-- reported, never a per-file list.
--
-- Grammar (one line on stdout, unchanged):
--   ^(ok:ca-path-literals:[0-9]+ of [0-9]+|violation:ca-path-literals-grew:[0-9]+ of [0-9]+)$
local baseline_env = env.get("TILLANDSIAS_CA_PATH_LITERAL_BASELINE")
local BASELINE = tonumber(baseline_env) or 1

local LITERAL = "/tmp/tillandsias-ca"
local PATTERN = "(" .. text.escape(LITERAL) .. ")"

local EXCLUDE = {
    ["check-ca-path-literals.lua"] = true,
    ["ca_path.rs"] = true,
    ["ca-path.txt"] = true,
    ["lib-ca-path.sh"] = true,
}

local count = 0
for _, dir in ipairs({ "crates", "scripts", "images" }) do
    local ok_walk, files = pcall(fs.walk, dir)
    if ok_walk then
        for _, f in ipairs(files) do
            local base = f:match("([^/]+)$")
            if not EXCLUDE[base] then
                local ok_read, content = pcall(fs.read, f)
                if ok_read then
                    -- A file fs.read cannot hand back as valid UTF-8 (binary
                    -- content) cannot be matched by the regex engine either;
                    -- skip it, the same as grep classifying it binary.
                    local ok_count, hits = pcall(text.captures_all, content, PATTERN)
                    if ok_count then
                        count = count + #hits
                    end
                end
            end
        end
    end
end

if count > BASELINE then
    log.raw("  A new literal '/tmp/tillandsias-ca' was added. That path is being")
    log.raw("  single-sourced (998-qrwu) so it can be moved off /tmp (998-3z6g),")
    log.raw("  and every literal is a site that must move with it — a missed one")
    log.raw("  points at a directory that is not there, on a recovery path that")
    log.raw("  only runs when something is already wrong.")
    log.raw("  Read the path from the shared declaration instead of restating it.")
    verdict.emit("violation:ca-path-literals-grew:" .. count .. " of " .. BASELINE, 1)
end

verdict.emit("ok:ca-path-literals:" .. count .. " of " .. BASELINE, 0)
