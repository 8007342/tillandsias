-- @trace order:1637-cnxq
-- @class observing
-- @env TILLANDSIAS_SCRATCH_LOCATION_BASE TILLANDSIAS_GATE_DIFF_BASE TILLANDSIAS_SCRATCH_EXCEPTIONS
--
-- check-scratch-location-added.lua — refuse a NEWLY ADDED shell line that makes
-- scratch OUTSIDE the checkout, unless the line names a recorded exception.
-- (The Lua form of the guard: a new .sh decider is refused by
-- scripts/lua/check-shell-ratchet.lua, 1384-bxhk, and this is its remedy.)
--
-- THE RULE (operator direction 2026-10-12, order 1637-cnxq; methodology
-- multi-host-development.yaml -> single_checkout_branching): in the DEVELOPMENT
-- runtime every disposable thing a script makes (temp trees, logs, private
-- podman stores, any worktree) lives under <checkout>/scratch/, the one ignored
-- dir, reached through scripts/scratch-dir.sh. A recursive rm outside the
-- workspace asks the operator for consent (1443-we89), and a bypass-mode session
-- waiting on that prompt halts the fleet. User runtime (inside a forge) is
-- exempt by design and says so with the `user-runtime` key.
--
-- WHAT IS A SITE, on an ADDED, non-comment line of scripts/**/*.sh:
--   mktemp     — `mktemp` in command position (start of line, or after `$(`,
--                `(`, a backtick, `;`, `&&`, `||`, `|`) whose arguments do not
--                route through scratch (`scratch-dir.sh`, `/scratch/`,
--                `$SCRATCH`, `TILLANDSIAS_SCRATCH`).
--   tmp        — a literal `/tmp/`, `/var/tmp/`, `$TMPDIR` or `${TMPDIR` on a
--                line that does not also route through scratch.
--   worktree   — `git worktree add <target>` with a target outside scratch.
--   parent     — a write that climbs out of the checkout: mkdir, mktemp, cp,
--                mv, tee, rsync, git clone or a `>` redirect naming `../`.
--                `cd "$(dirname "$0")/.."` is a resolution, not a write, and
--                is not a site.
-- A line carrying `# scratch-exception:<key>` is exempt when <key> is listed
-- in scripts/portability/scratch-exceptions.txt, and a VIOLATION when it is
-- not: an exception is always a recorded one.
--
-- DIFF-SCOPED BY CONSTRUCTION. 728 of the tree's 731 mktemp sites make
-- scratch outside the checkout today (measured 2026-10-12); the corpus is
-- migrated by the rows that own it, not by this guard. The population is the
-- change, INCLUDING untracked files (1391-8ikx: `git diff --name-only` never
-- lists a brand-new script). The population is shell, so this file is not in
-- it; its fixture (a .sh that plants every token refused here) is excluded by
-- EXACT path, because a pattern over a set containing itself reports itself.
--
-- git runs in the caller's cwd and files resolve against the repository root
-- (TILLANDSIAS_REPO_ROOT, else the nearest .git above the cwd), so a fixture
-- judges its own scratch clone by pinning both.
--
-- Verdicts (stdout; why/remedy on stderr):
--   ok:scratch-location-added:files=<n>:sites=<m>:exempt=<k>    exit 0
--   violation:scratch-location-added:<count>                    exit 1
--     preceded by one violation:scratch-location-added:<rule>:<path>:<line>
--     per site, rule in {mktemp,tmp,worktree,parent,unrecorded-exception}
--   refused:scratch-location-added:no-base:<ref>                exit 2
--
-- Env: TILLANDSIAS_SCRATCH_LOCATION_BASE, else TILLANDSIAS_GATE_DIFF_BASE,
-- else origin/linux-next; TILLANDSIAS_SCRATCH_EXCEPTIONS names the key file.

local function nonempty(s) return s ~= nil and s ~= "" end

local base_ref = env.get("TILLANDSIAS_SCRATCH_LOCATION_BASE")
if not nonempty(base_ref) then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not nonempty(base_ref) then base_ref = "origin/linux-next" end
local EXC_FILE = env.get("TILLANDSIAS_SCRATCH_EXCEPTIONS")
if not nonempty(EXC_FILE) then EXC_FILE = "scripts/portability/scratch-exceptions.txt" end
local SELF_FIXTURE = "scripts/test-check-scratch-location-added.sh"
local REMEDY = 'route the site through the checkout: tmp="$(mktemp -d "$(scripts/scratch-dir.sh fixtures)/<name>.XXXXXX")" — or, for a measured reason, append `# scratch-exception:<key>` with a key from scripts/portability/scratch-exceptions.txt'

local function afford(why, remedy)
    log.raw("  why: " .. why)
    log.raw("  remedy: " .. remedy)
end

local function git(args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return (r.status == "exited" and r.code == 0), (r.stdout or "")
end

if not git({ "rev-parse", "--verify", "--quiet", base_ref .. "^{commit}" }) then
    afford("the diff base does not resolve, so the set of added lines is unknown and nothing was checked",
        "git fetch origin, or point TILLANDSIAS_SCRATCH_LOCATION_BASE at a commit")
    verdict.emit("refused:scratch-location-added:no-base:" .. base_ref, 2)
end

-- Is <key> recorded? The key file is data: a line `<key> <why...>`.
local recorded = {}
if fs.exists(EXC_FILE) then
    for _, l in ipairs(text.lines(fs.read(EXC_FILE))) do
        local t = text.trim(l)
        if t ~= "" and t:sub(1, 1) ~= "#" then
            local k = t:match("^(%S+)")
            if k then recorded[k] = true end
        end
    end
end

-- Added lines of one file as { n = <new-line-number>, text = <text> }. A
-- tracked file is diffed against the base with no context, so every `+` line
-- is an addition and its number follows the hunk header; an untracked file is
-- wholly new.
local function in_base(f)
    if not git({ "ls-files", "--error-unmatch", "--", f }) then return false end
    return (git({ "cat-file", "-e", base_ref .. ":" .. f }))
end
local function added_lines(f)
    local out = {}
    if in_base(f) then
        local _, diff = git({ "diff", "-U0", base_ref, "--", f })
        local n = 0
        for _, l in ipairs(text.lines(diff)) do
            if l:sub(1, 2) == "@@" then
                n = tonumber(l:match("^@@ %-[%d,]+ %+(%d+)")) or 0
            elseif l:sub(1, 3) == "+++" then
                -- the file header, not an addition
            elseif l:sub(1, 1) == "+" then
                out[#out + 1] = { n = n, text = l:sub(2) }
                n = n + 1
            end
        end
    else
        local i = 0
        for _, l in ipairs(text.lines(fs.read(f))) do
            i = i + 1
            out[#out + 1] = { n = i, text = l }
        end
    end
    return out
end

local function has(s, lit) return s:find(lit, 1, true) ~= nil end
local function routes_through_scratch(s)
    return has(s, "scratch-dir.sh") or has(s, "/scratch/") or has(s, "$SCRATCH")
        or has(s, "${SCRATCH") or has(s, "TILLANDSIAS_SCRATCH")
end

-- mktemp in command position; a write naming ../ (a `cd ..` resolution is not one).
local MKTEMP_RE = [=[(^|\$\(|\(|`|;|&&|\|\||\|)\s*mktemp(\s|$)]=]
local PARENT_RE = [=[(mkdir|mktemp|cp|mv|tee|rsync|git clone|git worktree add)[^|;&]*[\s"']\.\./|>+\s*"?\.\./]=]
local WHY = {
    mktemp = "a new mktemp makes scratch outside the checkout; deleting it later asks the operator for consent (1443-we89), which halts a bypass-mode session",
    tmp = "a new /tmp or $TMPDIR path makes scratch outside the checkout; deleting it later asks the operator for consent (1443-we89)",
    worktree = "a new worktree outside scratch/ is outside the session's workspace (single_checkout_branching); its removal needs operator consent",
    parent = "a write that climbs to ../ leaves the checkout; nothing inside the workspace may delete it without a consent prompt",
}

-- The population: every scripts/**/*.sh the change touches, tracked or not.
local _, changed = git({ "diff", "--name-only", base_ref, "--", "scripts/*.sh", "scripts/**/*.sh" })
local _, untracked = git({ "ls-files", "--others", "--exclude-standard", "--", "scripts/*.sh", "scripts/**/*.sh" })
local pop, seen = {}, {}
for _, f in ipairs(text.lines(changed .. "\n" .. untracked)) do
    f = text.trim(f)
    if f ~= "" and not seen[f] then seen[f] = true; pop[#pop + 1] = f end
end
table.sort(pop)

local files, sites, exempt, violations = 0, 0, 0, {}
for _, f in ipairs(pop) do
    if f ~= SELF_FIXTURE and fs.exists(f) then   -- deleted in this change: nothing added
        files = files + 1
        for _, rec in ipairs(added_lines(f)) do
            local line = rec.text
            local trimmed = text.trim(line)
            if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then   -- a comment is not a site
                local at = line:find("# scratch-exception:", 1, true)
                if at then
                    local key = line:sub(at + #"# scratch-exception:"):match("^(%S*)") or ""
                    if recorded[key] then
                        exempt = exempt + 1
                    else
                        violations[#violations + 1] = "violation:scratch-location-added:unrecorded-exception:" .. f .. ":" .. rec.n
                        afford("the line claims scratch-exception:" .. key .. ", and " .. EXC_FILE .. " does not list that key, so the exception is nobody's decision",
                            "use a listed key (user-runtime, podman-runroot, matcher, preflight-door), or record the new one in " .. EXC_FILE .. " with the measurement that forces it")
                    end
                else
                    local rule
                    if text.is_match(line, MKTEMP_RE) and not routes_through_scratch(line) then rule = "mktemp" end
                    if not rule and (has(line, "/tmp/") or has(line, "/var/tmp/") or has(line, "$TMPDIR") or has(line, "${TMPDIR"))
                        and not routes_through_scratch(line) then rule = "tmp" end
                    if not rule and has(line, "git worktree add") and not routes_through_scratch(line) then rule = "worktree" end
                    if not rule and text.is_match(line, PARENT_RE) then rule = "parent" end
                    if rule then
                        violations[#violations + 1] = "violation:scratch-location-added:" .. rule .. ":" .. f .. ":" .. rec.n
                        afford(WHY[rule], REMEDY)
                    elseif has(line, "mktemp") or has(line, "git worktree add") then
                        sites = sites + 1
                    end
                end
            end
        end
    end
end

if #violations > 0 then
    for _, v in ipairs(violations) do out.line(v) end
    afford(#violations .. " added line(s) make scratch outside <checkout>/scratch/ (listed above with path:line); this guard is diff-scoped and never flags the existing corpus", REMEDY)
    verdict.emit("violation:scratch-location-added:" .. #violations, 1)
end
verdict.emit(("ok:scratch-location-added:files=%d:sites=%d:exempt=%d"):format(files, sites, exempt), 0)
