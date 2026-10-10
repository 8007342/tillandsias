-- @trace order:1570-qutp, order:660-ryhn, order:1304-wbb2, order:958-b36m, order:1356-vv5m, spec:ci-release
-- @env LITMUS_BINDINGS_ROOT TILLANDSIAS_LITMUS_BIND_BASE
-- @read-env LITMUS_BINDINGS_ROOT
--
-- check-litmus-bindings.lua — a litmus file that is not bound never runs, and
-- nothing said so. PORTED from check-litmus-bindings.sh (1570-qutp); every
-- pass below is that script's, in its order, with its reason.
--
-- WHY (660-ryhn). The runner resolves tests through openspec/litmus-
-- bindings.yaml; a file absent from it is invisible and the suite prints PASS
-- while its assertions have never executed. 26 files were in that state when
-- the packet was filed. This makes the gap a CREATION-TIME refusal.
--
-- THE RATCHET, not a blind binding: a `phase: retired` file is intentionally
-- unbound and exempt; one listed in unbound-grandfathered.txt is a KNOWN
-- historical stray (shrink the list in batches); anything else unbound is a NEW
-- stray and refuses. A registered name with no file behind it (dangling)
-- refuses the other way.
--
-- Grammar (exactly one line on stdout; details on stderr):
--   ok:litmus-bindings:files=<n> bound=<n> retired=<n> grandfathered=<n> spec_ids=<n> resolved=<n> spec-grandfathered=<n>   exit 0
--   violation:unbound-litmus:<name>[,<name>...]                exit 1
--   violation:dangling-binding:<name>[,<name>...]              exit 1
--   violation:binding-spec-mismatch:<name>(declared=..,bound-under=..)[,...]   exit 1
--   violation:bound-but-unrunnable:<name>[,...]                exit 1
--   violation:litmus-bindings-spec-population-empty            exit 1
--   violation:binding-names-absent-spec:<id>[,<id>...]         exit 1
--   violation:bindings-tree-missing                            exit 2
-- (the last two refusals printed only on stderr before the port; they now
-- carry a stdout verdict line like every other refusal.)
--
-- WHAT THE PORT CHANGES. The .sh read the registry and the corpus with grep,
-- awk and sed — including BRE patterns whose `\+` BSD sed reads as a literal
-- plus, so the added-bindings extraction returned NOTHING on macOS and the
-- gate reported ok over a newly-bound unrunnable file. Here every pattern is a
-- Rust regex (same answer on every platform), git's output is read as data
-- through proc.run (argv), and a missing base ref is a NAMED skip on stderr,
-- never silence. A file named by `name: <id>` is chosen deterministically
-- (byte order) where the .sh took grep's traversal order.
--
-- Seam: LITMUS_BINDINGS_ROOT points the scan at a fixture tree laid out as
-- <root>/openspec/litmus-tests + <root>/openspec/litmus-bindings.yaml.

local root_env = env.get("LITMUS_BINDINGS_ROOT")
local ROOT = (root_env and root_env ~= "") and root_env or nil
local function at(rel) if ROOT then return ROOT .. "/" .. rel end return rel end
local GIT_ROOT = ROOT or "."
local TESTS_DIR = "openspec/litmus-tests"
local BINDINGS = "openspec/litmus-bindings.yaml"
local GRANDFATHERED = TESTS_DIR .. "/unbound-grandfathered.txt"
local UNRESOLVED_GF = TESTS_DIR .. "/unresolved-grandfathered.txt"

local function read(rel)
    local ok_r, c = pcall(fs.read, at(rel))
    if ok_r then return c end
    return nil
end
local function set_of(list) local s = {} for _, v in ipairs(list) do s[v] = true end return s end
local function sorted_unique(list)
    local seen, out = {}, {}
    for _, v in ipairs(list) do if not seen[v] then seen[v] = true; out[#out + 1] = v end end
    table.sort(out)
    return out
end

-- The corpus: every file under the tests dir (the .sh's `grep -r` scope), and
-- the litmus-*.yaml direct children (its glob), each byte-ordered.
local all_files, litmus_files = {}, {}
do
    local base = at(TESTS_DIR)
    local ok_w, walked = pcall(fs.walk, base)
    if ok_w then
        for _, p in ipairs(walked) do
            local rel = TESTS_DIR .. "/" .. p:sub(#base + 2)
            all_files[#all_files + 1] = rel
            local leaf = p:sub(#base + 2)
            if not leaf:find("/", 1, true) and leaf:match("^litmus%-.*%.yaml$") then litmus_files[#litmus_files + 1] = rel end
        end
    end
    table.sort(all_files)
    table.sort(litmus_files)
end
local bindings_text = read(BINDINGS)
if #all_files == 0 or not bindings_text then
    verdict.emit("violation:bindings-tree-missing", 2,
        "  expected " .. at(TESTS_DIR) .. "/ and " .. at(BINDINGS))
end

-- Every `litmus:<id>` token anywhere in the registry (the .sh's grep -o).
local bound = {}
for _, m in ipairs(text.captures_all(bindings_text, [[(litmus:[a-z0-9._-]+)]])) do
    bound[#bound + 1] = (type(m) == "table" and (m[1] or m[0])) or m
end
bound = sorted_unique(bound)
local bound_set = set_of(bound)

local grand = {}
do
    local g = read(GRANDFATHERED)
    if g then
        for _, l in ipairs(text.lines(g)) do
            if l ~= "" and l:sub(1, 1) ~= "#" then grand[#grand + 1] = l end
        end
    end
end
local grand_set = set_of(grand)

-- ── 660-ryhn: every litmus file is bound, retired, or grandfathered ────────
local files, bound_n, retired, grandfathered = 0, 0, 0, 0
local unbound, on_disk = {}, {}
for _, f in ipairs(litmus_files) do
    local c = read(f) or ""
    local name, is_retired = nil, false
    for _, l in ipairs(text.lines(c)) do
        if name == nil then
            local v = l:match("^name:(.*)$")
            if v then name = v:gsub(" ", "") end
        end
        if text.is_match(l, [[^phase: *retired *$]]) then is_retired = true end
    end
    if name and name ~= "" then
        files = files + 1
        on_disk[name] = true
        if bound_set[name] then
            bound_n = bound_n + 1
        elseif is_retired then
            retired = retired + 1
        elseif #grand > 0 and grand_set[name] then
            grandfathered = grandfathered + 1
        else
            unbound[#unbound + 1] = name
        end
    end
end
if #unbound > 0 then
    verdict.emit("violation:unbound-litmus:" .. table.concat(unbound, ","), 1,
        "each name above is an executable assertion NOTHING has ever run (660-ryhn).\n" ..
        "Bind it to its spec in openspec/litmus-bindings.yaml and RUN it, mark it\n" ..
        "'phase: retired' if intentionally shelved, or — for a historical stray\n" ..
        "only, never new work — add it to " .. at(GRANDFATHERED))
end

local dangling = {}
for _, b in ipairs(bound) do if not on_disk[b] then dangling[#dangling + 1] = b end end
if #dangling > 0 then
    verdict.emit("violation:dangling-binding:" .. table.concat(dangling, ","), 1,
        "each name above is registered in litmus-bindings.yaml with NO file behind it — the suite claims coverage that cannot execute")
end

-- The file that declares `name: <id>` (substring, as the .sh's grep -rlF),
-- first in byte order.
local function file_named(nm)
    local needle = "name: " .. nm
    for _, f in ipairs(all_files) do
        local c = read(f)
        if c and c:find(needle, 1, true) then return f end
    end
    return nil
end

-- ── the base ref, and the bindings ADDED since it (data, not a pipeline) ───
local BASE = env.get("TILLANDSIAS_LITMUS_BIND_BASE")
if not BASE or BASE == "" then BASE = "origin/linux-next" end
local function git(args)
    local argv = { "git", "-C", GIT_ROOT }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, timeout_ms = 120000 })
end
local base_ok
do
    local r = git({ "rev-parse", "--verify", BASE })
    base_ok = r.status == "exited" and r.code == 0
end
local added = {}
if base_ok then
    local r = git({ "diff", "-U0", BASE, "--", BINDINGS })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local caps = text.captures_all(l, [[^\+\s*-\s*(litmus:[A-Za-z0-9._-]+)]])
        local m = caps[1]
        if m then added[#added + 1] = (type(m) == "table" and (m[1] or m[0])) or m end
    end
    added = sorted_unique(added)
else
    log.raw("  skip:litmus-bindings:no-base-ref:" .. BASE .. " — the misbound and newly-bound-unrunnable checks need it; they did NOT run")
end

-- ── 1304-wbb2: a NEW binding sits under a spec its file declares ───────────
-- MEMBERSHIP, NOT EQUALITY (`spec:` is a comma list in some files) and AT
-- LEAST ONCE (a name may be bound under several blocks by design). Static, so
-- NOT gated on the runner. DIFF-SCOPED: 69 standing mismatches are per-file
-- cleanup, new ones refuse.
if base_ok then
    local pairs_list, blk = {}, nil -- (litmus id, block) in registry order
    for _, l in ipairs(text.lines(bindings_text)) do
        local s = l:match("^%- spec_id: (%S+)")
        if s then blk = s end
        local id = l:match("^  %- (litmus:%S+)")
        if id and blk then pairs_list[#pairs_list + 1] = { id, blk } end
    end
    local misbound = {}
    for _, nm in ipairs(added) do
        local f = file_named(nm)
        local declared
        if f then
            for _, l in ipairs(text.lines(read(f) or "")) do
                local v = l:match("^spec:%s*(.*)$")
                if v then declared = v; break end
            end
        end
        if declared and declared ~= "" then
            local dset, dlist = {}, {}
            for part in (declared .. ","):gmatch("([^,]*),") do
                local t = text.trim(part)
                if t ~= "" then dset[t] = true; dlist[#dlist + 1] = t end
            end
            for _, p in ipairs(pairs_list) do
                if p[1] == nm and not dset[p[2]] then
                    misbound[#misbound + 1] = nm .. "(declared=" .. table.concat(dlist, "|") .. ",bound-under=" .. p[2] .. ")"
                end
            end
        end
    end
    if #misbound > 0 then
        verdict.emit("violation:binding-spec-mismatch:" .. table.concat(misbound, ","), 1,
            "each name above is newly bound under a block that is NOT among the specs its own\n" ..
            "file declares (1304-wbb2). It will RUN and be credited to the wrong spec, while the\n" ..
            "spec it names reads covered with nothing behind it. Fix the binding, or fix the\n" ..
            "file's spec: line if the binding is the correct one — a reader has to decide which.")
    end
end

-- ── 958-b36m: BOUND IS NOT RUNNABLE. Ask the runner, never imitate it ──────
local RUNNER = at("scripts/run-litmus-test.sh")
local runner_ok = false
if base_ok and read("scripts/run-litmus-test.sh") then
    local r = proc.run({ argv = { "test", "-x", RUNNER } })
    runner_ok = r.status == "exited" and r.code == 0
end
local function parses(f)
    local r = proc.run({ argv = { RUNNER, "--parse-only", at(f) }, timeout_ms = 120000 })
    return r.status == "exited" and r.code == 0
end
if base_ok and runner_ok then
    local unrunnable = {}
    for _, nm in ipairs(added) do
        local f = file_named(nm)
        if f and not parses(f) then unrunnable[#unrunnable + 1] = nm end
    end
    if #unrunnable > 0 then
        verdict.emit("violation:bound-but-unrunnable:" .. table.concat(unrunnable, ","), 1,
            "each name above is newly bound and the RUNNER cannot extract its steps (958-b36m).\n" ..
            "Being valid YAML and correctly bound is not being runnable. Reproduce with:\n" ..
            "  scripts/run-litmus-test.sh --parse-only <file>")
    end
    -- ADVISORY over the whole bound corpus, never a refusal (699-dycj), and
    -- only when the corpus could have moved (~36 s otherwise paid every gate).
    local touched = git({ "diff", "--name-only", BASE, "--", BINDINGS, TESTS_DIR })
    if text.trim(touched.stdout or "") ~= "" then
        local bad = 0
        for _, b in ipairs(bound) do
            local f = file_named(b)
            if f then
                local is_retired = false
                for _, l in ipairs(text.lines(read(f) or "")) do
                    if text.is_match(l, [=[^phase:[[:space:]]*retired[[:space:]]*$]=]) then is_retired = true; break end
                end
                -- a retired file is deliberately never executed (946-pdpi)
                if not is_retired and not parses(f) then bad = bad + 1 end
            end
        end
        if bad > 0 then
            log.raw("advisory:bound-but-unrunnable-existing=" .. bad .. " (not gating; find them with scripts/run-litmus-test.sh --parse-only)")
        end
    end
end

-- ── 1356-vv5m: every spec_id the registry NAMES resolves to a spec.md ──────
-- To spec.md, not the directory (a husk satisfies -d). The population of THIS
-- check is asserted: zero spec_ids is a broken read, never ok:0. The ratchet
-- is kept: unresolved-grandfathered.txt lists declared exceptions.
local spec_ids = {}
for _, l in ipairs(text.lines(bindings_text)) do
    local v = l:match("^%- spec_id:%s*(.*)$")
    if v then
        v = v:gsub("[\"']", ""):gsub("%s+$", "")
        if v ~= "" then spec_ids[#spec_ids + 1] = v end
    end
end
local ugf = {}
do
    local g = read(UNRESOLVED_GF)
    if g then for _, l in ipairs(text.lines(g)) do ugf[l] = true end end
end
local spec_gf, unresolved = 0, {}
for _, sid in ipairs(spec_ids) do
    if not read("openspec/specs/" .. sid .. "/spec.md") then
        if ugf[sid] then spec_gf = spec_gf + 1 else unresolved[#unresolved + 1] = sid end
    end
end
if #spec_ids == 0 then
    verdict.emit("violation:litmus-bindings-spec-population-empty", 1,
        "violation:litmus-bindings-spec-population-empty: parsed ZERO spec_ids from " .. at(BINDINGS) ..
        " — a registry with no spec_ids is a broken read, not a clean tree")
end
if #unresolved > 0 then
    local d = {}
    for _, sid in ipairs(unresolved) do
        d[#d + 1] = "violation:binding-names-absent-spec:" .. sid .. " — openspec/specs/" .. sid ..
            "/spec.md does not exist, so every litmus bound under it points at nothing"
    end
    d[#d + 1] = "  Add the spec, correct the spec_id, or declare it in unresolved-grandfathered.txt."
    verdict.emit("violation:binding-names-absent-spec:" .. table.concat(unresolved, ","), 1, table.concat(d, "\n"))
end

verdict.emit(string.format("ok:litmus-bindings:files=%d bound=%d retired=%d grandfathered=%d spec_ids=%d resolved=%d spec-grandfathered=%d",
    files, bound_n, retired, grandfathered, #spec_ids, #spec_ids - spec_gf, spec_gf), 0)
