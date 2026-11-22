-- @env PWD
-- @trace order:702-eusw, order:723-b9cn, order:831-ezea, order:702-pwhc
--
-- check-version-bump-isolation.lua — a build-number VERSION bump must NEVER be
-- swept into an unrelated commit. (Ported from
-- scripts/check-version-bump-isolation.sh, the shell-to-lua item carried by
-- order 2165-vcgh; history in `git log -- scripts/check-version-bump-isolation.sh`.)
--
-- WHY (702-eusw): commit dd8fd63f, a security fix, also carried a
-- `VERSION 0.4.260810.1 -> 0.4.260812.1` bump via `git add -A`; the mandated
-- linux-next merge imported that divergent VERSION and the mandated pre-push
-- gate refused every downstream platform push.
--
-- RULE: a NON-MERGE commit that changes VERSION together with any file outside
-- the version-companion set (VERSION, Cargo.lock, Cargo.toml, crates/*/Cargo.toml)
-- is refused. A VERSION+companions-only release bump passes (the negative
-- control). Merge commits are EXEMPT: inheriting VERSION is a catch-up (643-64bx).
--
-- SCOPE (723-b9cn): by default only commits THIS PUSH PUBLISHES FOR THE FIRST
-- TIME — reachable from HEAD and from no origin remote-tracking ref. A commit on
-- any origin ref was gate-checked at its own first push; re-policing it produced
-- a permanently unpushable osx-next (measured 2026-08-13). An EXPLICIT --range or
-- --commit is honoured literally. With no origin refs, fall back to the
-- upstream range (upstream..HEAD); with neither, nothing is examined and the verdict says so.
--
-- POPULATION (831-ezea): `violations=0` over an empty range is not evidence of
-- isolation, so the two empty paths carry their own verdict words. They stay
-- exit 0: nothing outgoing is the normal state of a clean tree, and build.sh
-- --check runs this on every gate.
--
-- Usage: tillandsias-plan script run scripts/lua/check-version-bump-isolation.lua [-- --range A..B | --commit SHA]
-- Summary line (unchanged from the .sh), then the typed verdict the runtime
-- requires (ok:/skip:/refused:/violation:version-bump-isolation:...):
--   version-bump-isolation: population=<n> commits=<n> version-touching=<n> violations=<n> \
--     verdict=(ok|ok:nothing-to-examine|ok:no-comparable-range|version-swept-with-unrelated-files)
-- Exit 0 clean; 1 a sweep was found; 2 a usage error (the .sh's codes).
-- Not a git repo: prints `not-a-git-repo` then skip:, exit 0 (the .sh exited 0).

-- The CALLER's directory, explicitly. The .sh judged `git rev-parse
-- --show-toplevel` from where it was run; under the litmus runner a child
-- spawned without a cwd ran in another repository and the guard examined
-- nothing (measured during this port: rev-list exit 128, unknown revision).
local CWD = env.get("PWD")
local function git(argv)
    local a = { "git" }
    for _, v in ipairs(argv) do a[#a + 1] = v end
    return proc.run({ argv = a, timeout_ms = 60000, cwd = (CWD ~= nil and CWD ~= "") and CWD or nil })
end
local function ok(r) return r.status == "exited" and r.code == 0 end
local function lines(s)
    local t = {}
    for l in (s or ""):gmatch("[^\n]+") do t[#t + 1] = l end
    return t
end

local top = git({ "rev-parse", "--show-toplevel" })
if not ok(top) then print("not-a-git-repo"); verdict.emit("skip:version-bump-isolation:not-a-git-repo", 0) end

local range = nil
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--range" and arg[i + 1] then range = arg[i + 1]; i = i + 2
    elseif a == "--commit" and arg[i + 1] then range = arg[i + 1] .. "~1.." .. arg[i + 1]; i = i + 2
    else
        log.raw("check-version-bump-isolation: unknown arg " .. tostring(a))
        verdict.emit("refused:version-bump-isolation:usage", 2,
            "usage: check-version-bump-isolation.lua [-- --range A..B | --commit SHA]")
    end
end

local function line(pop, commits, vt, viol, word)
    return string.format("version-bump-isolation: population=%d commits=%d version-touching=%d violations=%d verdict=%s",
        pop, commits, vt, viol, word)
end

local rev_args
if range then
    rev_args = { "rev-list", "--no-merges", range }
else
    local refs = git({ "for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes/origin" })
    if ok(refs) and text.trim(refs.stdout or "") ~= "" then
        rev_args = { "rev-list", "--no-merges", "HEAD", "--not", "--remotes=origin" }
    else
        local up = git({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })
        local u = ok(up) and text.trim(up.stdout or "") or ""
        if u ~= "" then
            rev_args = { "rev-list", "--no-merges", u .. "..HEAD" }
        else
            print(line(0, 0, 0, 0, "ok:no-comparable-range"))
            verdict.emit("ok:version-bump-isolation:no-comparable-range", 0)
        end
    end
end

local function is_companion(f)
    return f == "VERSION" or f == "Cargo.lock" or f == "Cargo.toml"
        or (f:match("^crates/.+/Cargo%.toml$") ~= nil)  -- the .sh case glob crates/*/Cargo.toml matched across slashes
end

-- An unresolvable range walks nothing, as `git rev-list ... 2>/dev/null` did.
local rl = git(rev_args)
local shas = ok(rl) and lines(rl.stdout) or {}

local commits, vtouch, violations = 0, 0, 0
for _, sha in ipairs(shas) do
    commits = commits + 1
    local dt = git({ "diff-tree", "--no-commit-id", "--name-only", "-r", sha })
    local files = ok(dt) and lines(dt.stdout) or {}
    local has_version = false
    for _, f in ipairs(files) do if f == "VERSION" then has_version = true; break end end
    if has_version then
        vtouch = vtouch + 1
        local offenders = {}
        for _, f in ipairs(files) do
            if not is_companion(f) then offenders[#offenders + 1] = f end
        end
        if #offenders > 0 then
            violations = violations + 1
            print("VIOLATION " .. sha:sub(1, 12) .. ": VERSION changed alongside non-companion file(s): " .. table.concat(offenders, " "))
        end
    end
end

if violations == 0 and commits == 0 then
    print(line(0, 0, 0, 0, "ok:nothing-to-examine"))
    verdict.emit("ok:version-bump-isolation:nothing-to-examine", 0)
elseif violations == 0 then
    print(line(commits, commits, vtouch, 0, "ok"))
    verdict.emit("ok:version-bump-isolation:" .. commits .. "-commits", 0)
end
print(line(commits, commits, vtouch, violations, "version-swept-with-unrelated-files"))
print("A build-number bump must land alone (VERSION + Cargo.lock/Cargo.toml/crates only), via a release/version-bump-* branch — never swept into an unrelated commit (702-eusw).")
verdict.emit("violation:version-bump-isolation:" .. violations, 1,
    "  why: a non-merge commit this push publishes changes VERSION with unrelated files (702-eusw)\n" ..
    "  remedy: move the bump to its own commit (VERSION + Cargo files only) on a release/version-bump-* branch")
