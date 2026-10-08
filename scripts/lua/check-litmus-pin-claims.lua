-- @trace order:1528-ekri, spec:ci-release, plan 721-77yu
-- @env TILLANDSIAS_PIN_SCAN_DIR TILLANDSIAS_LITMUS_DIR TILLANDSIAS_LITMUS_BINDINGS
-- @read-env TILLANDSIAS_PIN_SCAN_DIR TILLANDSIAS_LITMUS_DIR TILLANDSIAS_LITMUS_BINDINGS
--
-- check-litmus-pin-claims.lua — PORTED from check-litmus-pin-claims.sh, byte
-- for byte. Refuse a script that claims a litmus pin which cannot execute.
-- See the .sh's header (kept in git history) for why an unverified attestation
-- is worse than none, and the SIGPIPE-under-pipefail race (792-ksr8) that used
-- to make this guard's verdict a function of machine load — replaced here by
-- a plain Lua table membership test, which has no pipe to race.
--
-- RUNS ON EVERY PUSH (pre-push hook / relay-preflight / build.sh fast
-- refusal): this port's parity proof is therefore run against several real
-- recent diffs, not only the clean tree (see the task report).
--
-- DISCLOSED DEVIATION: directory/file EXISTENCE is tested with
-- `proc.run{argv={"test","-d"|"-f",...}}` rather than `fs.exists`/`fs.list` —
-- those two verbs are rooted to the repository ONLY and are never widened by
-- `-- @read-env`, so they would refuse (not merely answer false) on the
-- fixture's directories outside the repo. `test` run through proc.run has no
-- such restriction, exactly like the `git` invocations other ports use.
--
-- Grammar (one line on stdout, unchanged legacy):
--   ok:litmus-pin-claims:<n> checked               exit 0
--   violation:litmus-pin-unresolvable:<n>           exit 1
--   violation:litmus-pin-unbound:<n>                exit 1
--
-- Pinned by litmus:added-fragment-parse-gate-shape (which this file's own
-- claim is then checked against — the check applies to itself).

local function env_or(name, default)
    local v = env.get(name)
    return (v and v ~= "") and v or default
end

local SCAN_DIR = env_or("TILLANDSIAS_PIN_SCAN_DIR", "scripts")
local LITMUS_DIR = env_or("TILLANDSIAS_LITMUS_DIR", "openspec/litmus-tests")
local BINDINGS = env_or("TILLANDSIAS_LITMUS_BINDINGS", "openspec/litmus-bindings.yaml")

local function is_dir(p)
    return proc.run({ argv = { "test", "-d", p } }).ok
end
local function is_file(p)
    return proc.run({ argv = { "test", "-f", p } }).ok
end

if not is_dir(SCAN_DIR) or not is_dir(LITMUS_DIR) then
    log.raw("  note: nothing to check (" .. SCAN_DIR .. " or " .. LITMUS_DIR .. " absent)")
    verdict.emit("ok:litmus-pin-claims:0 checked", 0)
end

-- Non-recursive listing of "<dir>/*.yaml" or "<dir>/*.sh"/"<dir>/*.c",
-- matching the shell globs/`find` exactly: fs.walk recurses, so results are
-- filtered down to direct children (litmus-dir case) or kept recursive
-- (scan-dir case, matching `find $SCAN_DIR -type f`).
local function direct_children(dir, suffix)
    local ok_w, walked = pcall(fs.walk, dir, { suffix = suffix })
    walked = (ok_w and walked) or {}
    local prefix = dir:gsub("/$", "") .. "/"
    local out = {}
    for _, f in ipairs(walked) do
        local rel = f:sub(#prefix + 1)
        if not rel:find("/") then out[#out + 1] = f end
    end
    return out
end

-- ── existing: every `name: litmus:<x>` declared in LITMUS_DIR/*.yaml ───────
local existing_set = {}
for _, f in ipairs(direct_children(LITMUS_DIR, ".yaml")) do
    local ok_r, content = pcall(fs.read, f)
    if ok_r then
        for _, line in ipairs(text.lines(content)) do
            local st, en = text.find(line, "^name: litmus:")
            if st then
                existing_set[line:sub(en + 1)] = true
            end
        end
    end
end

-- ── bound: every `- litmus:<x>` declared in BINDINGS ────────────────────────
local bound_set = {}
local bound_n = 0
if is_file(BINDINGS) then
    local ok_r, content = pcall(fs.read, BINDINGS)
    if ok_r then
        for _, tok in ipairs(text.captures_all(content, [==[(?m)^[ \t]*-[ \t]+litmus:([a-z0-9-]+)]==])) do
            if not bound_set[tok] then
                bound_set[tok] = true
                bound_n = bound_n + 1
            end
        end
    end
end

-- ── THE CORPUS IS SELECTED BY FILENAME (order 885-92iu): *.sh and *.c under
-- SCAN_DIR, recursively, sorted LC_ALL=C (byte order, same as fs.walk's own
-- sort — merged here since two suffix-filtered walks are each sorted alone).
local scan_files = {}
do
    local ok1, a = pcall(fs.walk, SCAN_DIR, { suffix = ".sh" })
    local ok2, b = pcall(fs.walk, SCAN_DIR, { suffix = ".c" })
    if ok1 then for _, v in ipairs(a) do scan_files[#scan_files + 1] = v end end
    if ok2 then for _, v in ipairs(b) do scan_files[#scan_files + 1] = v end end
    table.sort(scan_files)
end

local checked, unresolvable, unbound, wrapped = 0, 0, 0, 0
local CLAIM = "litmus:[a-z0-9-]+"
local TOKEN_CAP = [==[litmus:([a-z0-9-]+)]==]

for _, f in ipairs(scan_files) do
    local ok_r, content = pcall(fs.read, f)
    if ok_r then
        for _, line in ipairs(text.lines(content)) do
            if text.is_match(line, CLAIM) then
                for _, tok in ipairs(text.captures_all(line, TOKEN_CAP)) do
                    -- A token flush against end-of-line ending in '-' is wrapped prose.
                    local needle = "litmus:" .. tok
                    local is_wrapped = (line:sub(-#needle) == needle) and (tok:sub(-1) == "-")
                    if is_wrapped then
                        wrapped = wrapped + 1
                    else
                        checked = checked + 1
                        if not existing_set[tok] then
                            unresolvable = unresolvable + 1
                            log.raw("REFUSED: " .. f .. " claims litmus:" .. tok .. " — no litmus test declares that name.")
                            log.raw("         The claim reads as verification and supplies none.")
                        elseif bound_n > 0 and not bound_set[tok] then
                            unbound = unbound + 1
                            log.raw("REFUSED: " .. f .. " claims litmus:" .. tok .. " — the test exists but no spec binds it in")
                            log.raw("         " .. BINDINGS .. ", so it executes in no suite. Add it to a spec's litmus_tests.")
                        end
                    end
                end
            end
        end
    end
end

if wrapped > 0 then
    log.raw("  note: " .. wrapped .. " line-wrapped token(s) skipped (not claims)")
end

if unresolvable > 0 then
    verdict.emit("violation:litmus-pin-unresolvable:" .. unresolvable, 1)
end
if unbound > 0 then
    verdict.emit("violation:litmus-pin-unbound:" .. unbound, 1)
end
verdict.emit("ok:litmus-pin-claims:" .. checked .. " checked", 0)
