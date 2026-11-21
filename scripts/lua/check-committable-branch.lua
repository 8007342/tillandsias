-- @env PWD
-- @trace spec:meta-orchestration, order:476, order:1247-cbg7, order:1005-m6rz, order:1781-wves
--
-- check-committable-branch.lua — the executable Committable Branch Guard.
-- (Ported from the shell checker of the same name, the shell-to-lua item
-- order 2100-vkpg carried; history in `git log -- scripts/` for that file.)
--
-- Makes the "Release: `main` through PR only" rule a verifiable check instead
-- of advisory prose. Breach record: commit 34e60965 — a forge cycle running ON
-- `main` pushed a ~42k-line plan/index.yaml reserialization straight to
-- origin/main; reverted via PR #81 (plan/issues/main-branch-direct-push-guard-2026-07-24.md).
--
-- The checkout is committable when HEAD is on a named branch that is not
-- `main`. Detached HEAD, a non-repo directory, and a host that cannot author a
-- commit all fail closed: a committable cycle needs a branch it can push and an
-- identity to commit with. Read-only cycles on `main` stay allowed; callers
-- consult the verdict before claiming, committing or pushing, not before reading.
--
-- Exactly one line on stdout, matching
--   ^(ok:branch-[A-Za-z0-9._/-]+|blocked:(committable-cycle-on-main|detached-head|not-a-git-repo|no-git-identity))$
-- Exit 0 (committable) or 1 (blocked), exactly as the .sh. The .sh had no
-- could-not-run word; the runner itself failing is exit 3 from the runtime
-- (no plan binary with `script run`), reported by the caller.
--
-- It judges the CURRENT DIRECTORY's repository (the .sh did too): run it from
-- the checkout in question. why/remedy go to stderr so stdout stays the one
-- verdict line. A git that cannot be spawned reads as not-a-git-repo, as in
-- the .sh (the host-tools prover hides git and expects that word).
--
-- Branch detection is `git symbolic-ref --quiet --short HEAD`: it resolves the
-- name even on an unborn branch, and exits non-zero on a detached HEAD.
-- Identity is `git var GIT_AUTHOR_IDENT`: git's own resolution, failing
-- exactly when a commit would (1005-m6rz: a `.(none)` hostname host).
--
-- DIFFERENCE FROM THE .sh, by the runtime's design (child_env.rs): a child does
-- not inherit GIT_AUTHOR_*/GIT_COMMITTER_*/EMAIL or GIT_DIR/GIT_CONFIG_*, so an
-- identity supplied ONLY through those variables is not seen here; a repo or
-- global config identity is.

local function git(...)
    return proc.run({ argv = { "git", ... }, timeout_ms = 30000 })
end

local function afford(why, remedy)
    log.raw("  why: " .. why)
    log.raw("  remedy: " .. remedy)
end

local function ran_ok(r) return r.status == "exited" and r.code == 0 end

if not ran_ok(git("rev-parse", "--git-dir")) then
    local cwd = env.get("PWD") or "the current directory"
    afford("a committable cycle commits and pushes, and " .. cwd .. " is not inside a git checkout",
        "cd into the checkout you mean to commit in (git clone it first if there is none), then re-run this guard")
    verdict.emit("blocked:not-a-git-repo", 1)
end

local b = git("symbolic-ref", "--quiet", "--short", "HEAD")
local branch = ran_ok(b) and text.trim(b.stdout or "") or ""
if branch == "" then
    afford("HEAD is detached, so a commit made here belongs to no branch and there is nothing to push",
        "git switch <branch> to work on an existing one, or git switch -c <topic> to keep this commit on a new one, then re-run")
    verdict.emit("blocked:detached-head", 1)
end

if branch == "main" then
    afford("main advances only through a reviewed PR merge (breach 34e60965, order 476), so no cycle commits on it directly",
        "git switch -c <topic> (or switch to this project's integration branch: see the forge's branch rules, or git branch -r), commit there, and land on main through a PR")
    verdict.emit("blocked:committable-cycle-on-main", 1)
end

if not ran_ok(git("var", "GIT_AUTHOR_IDENT")) then
    log.raw("  This host cannot author a commit, so it cannot claim or push.")
    log.raw("  Set an identity for this checkout (repo-local, not --global):")
    log.raw("    git config user.name  \"<name>\"")
    log.raw("    git config user.email \"<email>\"")
    log.raw("  Then re-run this guard; it is the same check git makes at commit time.")
    verdict.emit("blocked:no-git-identity", 1)
end

verdict.emit("ok:branch-" .. branch, 0)
