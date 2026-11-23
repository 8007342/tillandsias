-- @trace order:2239-rmun
-- @env TILLANDSIAS_PROBE_GH
-- @env TILLANDSIAS_PROBE_GIT
-- @env TILLANDSIAS_PROBE_TIMEOUT_MS
--
-- probe-remote-reachable.lua — can THIS host push code to the remote? One
-- shared answer for the loop skills, the preflight door and the pre-push lane.
--
-- WHY (2239-rmun, the user's direction 2026-11-22): a host whose gh token went
-- bad kept merging and porting locally for ~25 minutes, because every symptom
-- read as network flakiness ("Failed to connect to github.com:443", "graphql:
-- i/o timeout"). Work that cannot reach origin is not work. The answer is to
-- STOP, not to retry with backoff: this probe asks once per check, each under
-- a bounded timeout, and never retries.
--
-- It only READS. It never runs `gh auth login` or `gh auth refresh`: restoring
-- access is a human's step on this host.
--
--   ok:remote-reachable
--   blocked:remote-unreachable:<cause>   (rc 1; why/remedy on stderr)
--     cause: no-gh | gh-timeout | gh-auth | ls-remote-timeout | ls-remote-auth | ls-remote-failed
--
-- Seams (the fixture's): TILLANDSIAS_PROBE_GH, TILLANDSIAS_PROBE_GIT name the
-- binaries (a path ending .sh runs under Git's bash, so a stub works on a
-- native Windows host too); TILLANDSIAS_PROBE_TIMEOUT_MS bounds each check
-- (default 20000).

local GH = env.get("TILLANDSIAS_PROBE_GH") or "gh"
local GIT = env.get("TILLANDSIAS_PROBE_GIT") or "git"
local T = tonumber(env.get("TILLANDSIAS_PROBE_TIMEOUT_MS") or "") or 20000
local BASH = require("common.fixture").posix_shell("/bin/bash") -- Git's bash on native Windows (2246-fkea)
local function argv_of(bin, ...)
    local a = bin:find("%.sh$") and { BASH, bin } or { bin }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return a
end

local function blocked(cause, why, remedy)
    log.raw("  why: " .. why)
    log.raw("  remedy: " .. remedy .. " Then re-run this probe. Until it answers ok, SUSPEND work on this host:"
        .. " no retries, no backoff, no further local work (2239-rmun).")
    verdict.emit("blocked:remote-unreachable:" .. cause, 1)
end

-- 1. gh's own login state (it validates the token against the API) — only
-- when origin is GitHub: a scratch repo's local origin (every fixture that
-- drives the hook or the door) has no login to judge.
local url = text.trim(proc.run{ argv = argv_of(GIT, "remote", "get-url", "origin"), timeout_ms = T }.stdout or "")
local on_github = url:find("github%.com") ~= nil
local g = on_github and proc.run{ argv = argv_of(GH, "auth", "status"), timeout_ms = T } or { ok = true, code = 0 }
if g.status == "timed_out" or (g.code == nil and not g.ok) then
    if g.status == "timed_out" then
        -- The known cause on Silverblue: gh reads its token from the desktop
        -- keyring, and a LOCKED keyring (or no session bus) blocks the read
        -- with no error at all.
        blocked("gh-timeout", "`gh auth status` did not answer within " .. T .. " ms. gh reads its token from the"
            .. " desktop keyring (Secret Service); a LOCKED keyring, or no session bus, blocks that read silently"
            .. " (known on Silverblue). A network stall also does this",
            "a HUMAN unlocks this host's login keyring (log in to the desktop session, or unlock it in Passwords and"
            .. " Keys / seahorse), then checks `gh auth status` answers promptly; a session never unlocks or re-logs it.")
    end
    blocked("no-gh", "`gh` could not be run on this host (" .. tostring(g.stderr or g.status) .. ")",
        "install gh, or run from a host that has it.")
end
if g.code ~= 0 then
    local said = text.trim(((g.stdout or "") .. "\n" .. (g.stderr or "")):gsub("\n+", " "))
    blocked("gh-auth", "`gh auth status` reports this host is not logged in or its token is invalid: " .. said:sub(1, 200),
        "a HUMAN re-authenticates gh on this host (`gh auth login`, or refreshing the keyring token); a session never runs it.")
end

-- 2. Can git itself reach origin? (credential helper, network, remote url)
local r = proc.run{ argv = argv_of(GIT, "ls-remote", "--exit-code", "origin", "HEAD"), timeout_ms = T,
    env = { GIT_TERMINAL_PROMPT = "0" } }
if r.status == "timed_out" or (r.code == nil and not r.ok) then
    blocked("ls-remote-timeout", "`git ls-remote origin` did not answer within " .. T .. " ms",
        "check this host's network to the remote; do not loop on it.")
end
if r.code ~= 0 then
    local err = r.stderr or ""
    if err:find("[Aa]uthentication") or err:find("403") or err:find("401") or err:find("could not read Username") then
        blocked("ls-remote-auth", "git's credentials for origin are refused: " .. text.trim(err):sub(1, 200),
            "a HUMAN fixes this host's git credential (the gh credential helper follows `gh auth status`).")
    end
    blocked("ls-remote-failed", "`git ls-remote origin` failed (rc=" .. tostring(r.code) .. "): " .. text.trim(err):sub(1, 200),
        "check the remote url (`git remote -v`) and the network.")
end

verdict.emit("ok:remote-reachable", 0)
