-- @trace order:1570-25iq, order:599-4wzr, order:1087-h2z9, order:831-ezea
--
-- audit-guard-activation.lua — "a guard nobody can prove is running is not a
-- guard" (599-4wzr criterion 2). PORTED from audit-guard-activation.sh
-- (1570-25iq). Enumerate every scripts/check-*.sh guard and prove each is
-- referenced by at least one ACTIVATION SURFACE. A guard with no invoker is an
-- ORPHAN: it exists in the tree, fails silently, and looks exactly like a
-- passing one (the 599-w5jd failure class).
--
-- Output: one line per guard (`active:  <name> <- <invoker>` or
-- `ORPHAN:  <name> (no invoker …)`), then `orphans: <names>` when any, then the
-- verdict:
--   ok:guard-activation:population=N total=N active=N orphan=0 verdict=ok                       exit 0
--   violation:guard-activation:population=N total=N active=N orphan=K verdict=orphans-found      exit 1
--   violation:guard-activation:population=0 total=0 active=0 orphan=0 verdict=unavailable:no-guards-enumerated  exit 1
-- The numbers are the .sh's; only the house prefix is new (the runner refuses
-- an unprefixed verdict line).
--
-- AN EMPTY POPULATION IS A REFUSAL, NOT AN OK (831-ezea). Measured 2026-08-19:
-- the .sh copied into a tree whose glob matched nothing printed `verdict=ok`
-- and exited 0 — the auditor declared every guard active having enumerated
-- none. Zero guards in a repo that ships dozens is a broken checkout, a moved
-- scripts/ dir, or a renamed prefix.
--
-- WHAT IT CANNOT SEE, stated so a green run is not over-read:
--   * it proves a guard is WIRED on this checkout, not that hooks are
--     INSTALLED (per 599-4wzr criterion 3 each platform runs this itself);
--   * activation is "the basename appears in a surface file" — a mention in a
--     comment counts, which is why the surface list is explicit and short
--     rather than the transitive closure of every script (that would trade a
--     loud false ORPHAN for a silent false ACTIVE);
--   * the population is scripts/check-*.sh ONLY — a Lua decider is not
--     audited here. Every shell-to-Lua port therefore removes a guard from this
--     audit; 1577-ct29 widens the population. Kept identical to the .sh here
--     so this commit is a pure port.
--
-- THE SYMLINK HISTORY, and why this walker does not need to follow links. The
-- runtime skill dirs (.claude/skills, .opencode, .codex, .gemini, .github) are
-- SYMLINK FARMS onto the canonical skills/ tree. `grep -r` did not follow them
-- (801-qasc, 2026-08-17: five wired guards reported orphan); `grep -R` fixed it
-- on GNU only, and BSD grep does not descend symlinked SUBDIRECTORIES, so the
-- same false accusation recurred on macOS (1087-h2z9, 2026-09-12), hidden by
-- hosts that carried ugrep as `grep` on the interactive PATH. The .sh then used
-- `find -L`. fs.walk never follows links on any platform, and the CANONICAL
-- skills/ tree is itself a surface, listed BEFORE .claude/skills: every
-- reference reachable through a link is found in the real file first, so the
-- answer no longer depends on the walker, the grep or the PATH.
--
-- DETERMINISTIC INVOKER. The .sh printed the first hit in `find` traversal
-- order (directory order). This reports the first hit in surface order, then
-- byte order within a surface, so two hosts print the same invoker.
--
-- No env, no spawn: pure reads over repo-relative paths.

-- Activation surfaces, in order. A missing one is skipped, not fatal. Every
-- entry after the first few was added because a WIRED guard was reported an
-- orphan through a door the list could not see:
local SURFACES = {
    "build.sh",
    -- 1072-b7eq moved gate steps into data files naming their script literally
    -- (STEP_SCRIPT / STEP_LUA); check-plan-binary-current.sh was reported an
    -- orphan while bound this way (2026-09-06).
    "scripts/gate-steps.d",
    "scripts/local-ci.sh",
    "scripts/run-litmus-test.sh",
    "scripts/mo-full-attest.sh",
    "openspec/litmus-tests",
    ".github/workflows",
    "scripts/install-hooks.sh",
    -- skills/ is the CANONICAL tree of real files; .claude/skills is a symlink
    -- farm onto it (and on Windows, 40-byte text files: core.symlinks=false).
    "skills",
    ".claude/skills",
    "methodology.yaml",
    "methodology",
    -- SECOND-LEVEL INVOKERS, listed explicitly ON PURPOSE (see the header):
    -- check-archive-answerability.sh <- archive-plan-packets.sh (2026-08-21)
    "scripts/archive-plan-packets.sh",
    -- 1194-davi: an advisory run from the LAND path, which a land that adopts
    -- a valid stamp (1174-u5wp) reaches without any gate.
    "scripts/land-on-platform-branch.sh",
    -- 1218-25z3: an advisory run from the RELEASE path, the one point every cut
    -- passes through.
    "scripts/release-preflight.sh",
    -- 1261-bn7v: a guard run from the pre-push hook's plan-only lane, the only
    -- surface that sees a plan-only push and has already fetched origin.
    "scripts/hooks/pre-push-local-gate.sh",
    -- 861-n7f5: check-engine-cpu-dispatch.sh via a $(dirname)-relative path.
    "scripts/bench-inference-floor.sh",
    -- 1129-xm5z: check-host-tools.sh's SPEC table names each <prover>, which
    -- test-host-tools.sh then runs from a variable (invisible to a name scan).
    "scripts/check-host-tools.sh",
    -- 1049-s35z / 823-u5zf: guards invoked by fixtures that are themselves
    -- bound as gate steps, one hop further than the list reached; reported as
    -- orphans for a day while actively guarding (and "fixing" that by wiring
    -- them again would have double-run them).
    "scripts/test-jq-multiline-capture.sh",
    "scripts/test-wt-reparse-scan.sh",
}

local function ends_with(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end

-- Files of a surface, byte-ordered; a file surface is itself. Cached.
local surface_files = {}
local content_of = {}
local function files_of(s)
    if surface_files[s] then return surface_files[s] end
    local list = {}
    if fs.exists(s) then
        local ok_w, walked = pcall(fs.walk, s)
        if ok_w and #walked > 0 then
            for _, p in ipairs(walked) do list[#list + 1] = p end
            table.sort(list)
        else
            list[1] = s -- a file surface (fs.walk of a file lists nothing)
        end
    end
    surface_files[s] = list
    return list
end
local function read(p)
    if content_of[p] == nil then
        local ok_r, c = pcall(fs.read, p)
        content_of[p] = ok_r and c or false
    end
    return content_of[p]
end

-- A guard referencing its OWN name, and this auditor (either form), never
-- count as an invoker.
local function find_invoker(name)
    for _, s in ipairs(SURFACES) do
        for _, p in ipairs(files_of(s)) do
            if not (ends_with(p, "scripts/" .. name) or ends_with(p, "scripts/audit-guard-activation.sh")
                    or ends_with(p, "scripts/lua/audit-guard-activation.lua")) then
                local c = read(p)
                if c and c:find(name, 1, true) then return p end
            end
        end
    end
    return nil
end

-- The population: scripts/check-*.sh, direct children, byte-ordered.
local population = {}
do
    local ok_w, walked = pcall(fs.walk, "scripts")
    if ok_w then
        for _, p in ipairs(walked) do
            local rel = p:sub(#"scripts/" + 1)
            if not rel:find("/", 1, true) and rel:match("^check%-.*%.sh$") then population[#population + 1] = rel end
        end
    end
    table.sort(population)
end

local total, active, orphan = #population, 0, 0
local orphans = {}
for _, name in ipairs(population) do
    local inv = find_invoker(name)
    if inv then
        active = active + 1
        out.line(string.format("active:  %-45s <- %s", name, inv))
    else
        orphan = orphan + 1
        orphans[#orphans + 1] = name
        out.line(string.format("ORPHAN:  %-45s (no invoker on any activation surface)", name))
    end
end

if total == 0 then
    verdict.emit("violation:guard-activation:population=0 total=0 active=0 orphan=0 verdict=unavailable:no-guards-enumerated", 1,
        "scripts/check-*.sh matched no files — the audit proved nothing. Zero guards in a repo that ships dozens means a broken checkout, a moved scripts/ directory, or a renamed guard prefix; it does not mean every guard is active.")
end
local counts = string.format("population=%d total=%d active=%d orphan=%d", total, total, active, orphan)
if orphan == 0 then
    verdict.emit("ok:guard-activation:" .. counts .. " verdict=ok", 0)
end
out.line("orphans: " .. table.concat(orphans, " "))
verdict.emit("violation:guard-activation:" .. counts .. " verdict=orphans-found", 1)
