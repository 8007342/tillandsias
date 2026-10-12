-- @trace order:1512-3afc, order:1628-re39
-- @env TILLANDSIAS_STEP_PREFIX_TRUNK TILLANDSIAS_GATE_DIFF_BASE TILLANDSIAS_STEP_PREFIX_REFS TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS
--
-- Refuse a NEWLY ADDED gate step whose numeric prefix another host already
-- holds, on trunk or on any other unlanded work ref, before it costs a relaunch.
--
-- WHY. An author picks "the next free number" from their own ref's view, which
-- cannot see other hosts' unlanded origin/work/* refs. MEASURED 2026-09-30:
-- three collisions in one day (1266-dh2d vs 1494-kkbi, 1494-kkbi vs 815-yace,
-- 1508-7s4w vs 1504-4tty), each a rename and a relaunch. allocate-gate-step-
-- prefix.sh (1162-qbrx) reallocates at LAND time against the refs that land
-- integrated; it cannot see refs queued for later lands.
--
-- WHAT IT READS. It reads remote-tracking refs as fetched; it does not fetch.
-- git runs in the caller's cwd, so a fixture judges its own scratch clone.
--   added    scripts/gate-steps.d/NNN-*.step in HEAD and absent from TRUNK
--   holders  every step file on TRUNK, plus on each origin/work/* ref that
--            (a) was committed to within WINDOW days, (b) is NOT already in
--            TRUNK, and (c) is NOT already in HEAD (a ref this land carries
--            is the same step, not a rival).
-- The window keeps abandoned refs from pinning numbers forever (386 work refs
-- existed on 2026-09-30, most long landed or dead).
--
-- VERDICTS (stdout, last line):
--   ok:gate-step-prefix-across-refs:<n> added, <m> refs scanned
--   ok:gate-step-prefix-across-refs:no-new-steps
--   refused:gate-step-prefix-across-refs:<file>:<holder-ref>:<holder-file>
--   skip:gate-step-prefix-across-refs:no-trunk-ref (the trunk ref is not fetched here)
--
-- Seams: TILLANDSIAS_STEP_PREFIX_TRUNK (default origin/linux-next, or
-- TILLANDSIAS_GATE_DIFF_BASE when set), TILLANDSIAS_STEP_PREFIX_REFS (default
-- refs/remotes/origin/work/), TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS (default 14).
--
-- PORTED from check-gate-step-prefix-across-refs.sh (1628-re39), quirks kept:
--   * the suggested free prefix is computed the way bash's $(( )) read the
--     prefix: a leading zero makes it OCTAL, so a collision on 020 suggests 20,
--     not 30;
--   * prefixes compare as STRINGS (awk's q == p), so 010 and 10 are different;
--   * the "used" set is the raw prefix text, checked by exact match (grep -x).
--   * a collision on a leading-zero prefix holding an 8 or a 9 (08x, 09x)
--     PASSES: bash's octal $(( )) fails, the error aborts the loop, and the
--     .sh prints ok with the steps counted so far. That is a false negative,
--     recorded on 1628-re39 and kept here, not fixed.

local function env_or(name, default)
    local v = env.get(name)
    if v == nil or v == "" then return default end
    return v
end
local TRUNK = env_or("TILLANDSIAS_STEP_PREFIX_TRUNK", env_or("TILLANDSIAS_GATE_DIFF_BASE", "origin/linux-next"))
local REFS = env_or("TILLANDSIAS_STEP_PREFIX_REFS", "refs/remotes/origin/work/")
local WINDOW = tonumber(env_or("TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS", "14")) or 0
local DIR = "scripts/gate-steps.d"
local NAME = "gate-step-prefix-across-refs"

local function git(args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return r.status == "exited" and r.code == 0, r.stdout or ""
end
local function basename(p) return p:match("[^/]*$") end

if not git({ "rev-parse", "-q", "--verify", TRUNK .. "^{commit}" }) then
    verdict.emit("skip:" .. NAME .. ":no-trunk-ref (" .. TRUNK .. " is not fetched here, so there is nothing to compare against)", 0)
end

local added = {}
do
    local _, out = git({ "diff", "--no-renames", "--name-only", "--diff-filter=A", TRUNK, "HEAD", "--", DIR .. "/" })
    for _, l in ipairs(text.lines(out)) do
        if text.is_match(l, "^" .. DIR .. "/[0-9]+-[^/]*\\.step$") then added[#added + 1] = l end
    end
end
if #added == 0 then verdict.emit("ok:" .. NAME .. ":no-new-steps", 0) end

-- holders: { ref, file basename }
local holders = {}
local function hold(ref)
    local _, out = git({ "ls-tree", "--name-only", ref, DIR .. "/" })
    for _, l in ipairs(text.lines(out)) do
        if l ~= "" then holders[#holders + 1] = { ref, basename(l) } end
    end
end
hold(TRUNK)
local cutoff = os.time() - WINDOW * 86400
local n_refs = 0
do
    local _, out = git({ "for-each-ref", "--format=%(committerdate:unix) %(refname:short)", REFS })
    for _, l in ipairs(text.lines(out)) do
        local ts, ref = l:match("^(%S*) (.*)$")
        if ref and ref ~= "" and (tonumber(ts) or 0) >= cutoff
            and not git({ "merge-base", "--is-ancestor", ref, TRUNK })
            and not git({ "merge-base", "--is-ancestor", ref, "HEAD" }) then
            n_refs = n_refs + 1
            hold(ref)
        end
    end
end

local used = {}
for _, h in ipairs(holders) do
    local p = h[2]:match("^[0-9]+")
    if p then used[p] = true end
end
for _, f in ipairs(added) do
    local p = basename(f):match("^[0-9]+")
    if p then used[p] = true end
end

-- bash's $(( pfx )): a leading zero reads octal; 8 or 9 in an octal literal is
-- an error (nil here).
local function bash_int(s)
    if #s > 1 and s:sub(1, 1) == "0" then
        if s:find("[89]") then return nil end
        return tonumber(s, 8)
    end
    return tonumber(s)
end

local n_added = 0
for _, f in ipairs(added) do
    local base = basename(f)
    local pfx = base:match("^[^-]*")
    n_added = n_added + 1
    local hit
    for _, h in ipairs(holders) do
        local q = h[2]:gsub("%-.*", "")
        if q == pfx and h[2] ~= base then hit = h; break end
    end
    if hit then
        local holder_ref, holder_file = hit[1], hit[2]
        local n = bash_int(pfx)
        if not n then
            -- KEPT QUIRK (1628-re39): bash's $(( 08x / 10 )) is an expansion
            -- error that aborts the whole while loop, after which the .sh goes
            -- on to print ok with the steps counted so far. A collision on an
            -- 08x or 09x prefix therefore PASSES. Measured, recorded on the
            -- row, kept rather than fixed in the port.
            log.raw("check-gate-step-prefix-across-refs.sh: " .. pfx .. ": value too great for base (error token is \"" .. pfx .. "\")")
            break
        end
        local free = (n // 10 + 1) * 10
        while used[tostring(free)] do free = free + 10 end
        local remedy = "rename it to a free prefix, e.g. git mv " .. f .. " " .. DIR .. "/" .. free .. "-" .. base:gsub("^[^-]*%-", "", 1)
            .. " (checked against " .. TRUNK .. " and " .. n_refs .. " unlanded work refs)"
        local detail = { NAME .. ": " .. base .. " takes prefix " .. pfx .. ", which " .. holder_ref .. " already holds as " .. holder_file }
        detail[#detail + 1] = "  why: two steps sharing one prefix collide when both land, and the loser pays a rename and a relaunch"
        detail[#detail + 1] = "  remedy: " .. remedy
        verdict.emit("refused:" .. NAME .. ":" .. base .. ":" .. holder_ref .. ":" .. holder_file, 1, table.concat(detail, "\n"))
    end
end

verdict.emit("ok:" .. NAME .. ":" .. n_added .. " added, " .. n_refs .. " refs scanned", 0)
