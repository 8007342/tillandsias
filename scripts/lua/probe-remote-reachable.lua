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
--     cause: network | gh-timeout | gh-auth | ls-remote-timeout | ls-remote-auth | ls-remote-failed
--
-- `network` is still blocked: a host that cannot push stops, whatever the cause.
-- What it changes is the remedy. gh says "The token in keyring is invalid" for
-- any check that fails other than by a timeout, so its words alone cannot tell a
-- cut network from a bad token (2328-a2x2). When gh fails, git's own connection
-- to origin is asked once as well.
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

-- git's connection to origin, asked at most once and shared by both checks.
local asked
local function ls_remote()
    asked = asked or proc.run{ argv = argv_of(GIT, "ls-remote", "--exit-code", "origin", "HEAD"), timeout_ms = T,
        env = { GIT_TERMINAL_PROMPT = "0", LANGUAGE = "en" } }  -- git's words are matched below (2281-amjg)
    return asked
end
local NET = { "Failed to connect", "Could not connect", "Couldn't connect", "Could not resolve", "Connection timed out",
    "Connection refused", "Connection reset", "Operation timed out", "Network is unreachable", "No route to host" }
local function cut(p)
    for _, w in ipairs(NET) do if (p.stderr or ""):find(w, 1, true) then return true end end
    return false
end
local function network(what)
    blocked("network", what .. ". This is a network failure; it says nothing about this host's login",
        "check this host's network to the remote, IPv4 included (GitHub may have no IPv6 address, so other sites can"
        .. " still answer); a login or a new token does not fix it.")
end

-- 1. gh's own login state (it validates the token against the API) — only
-- when origin is GitHub: a scratch repo's local origin (every fixture that
-- drives the hook or the door) has no login to judge.
local url = text.trim(proc.run{ argv = argv_of(GIT, "remote", "get-url", "origin"), timeout_ms = T }.stdout or "")
local on_github = url:find("github%.com") ~= nil
local g = on_github and proc.run{ argv = argv_of(GH, "auth", "status"), timeout_ms = T } or { ok = true, code = 0 }
if g.status == "timed_out" or (g.code == nil and not g.ok) then
    if g.status == "timed_out" then
        if cut(ls_remote()) then
            network("`gh auth status` did not answer and git cannot connect: " .. text.trim(ls_remote().stderr):sub(1, 200))
        end
        -- The known cause on Silverblue: gh reads its token from the desktop
        -- keyring, and a LOCKED keyring (or no session bus) blocks the read
        -- with no error at all.
        blocked("gh-timeout", "`gh auth status` did not answer within " .. T .. " ms. gh reads its token from the"
            .. " desktop keyring (Secret Service); a LOCKED keyring, or no session bus, blocks that read silently"
            .. " (known on Silverblue). A network stall also does this",
            "a HUMAN unlocks this host's login keyring (log in to the desktop session, or unlock it in Passwords and"
            .. " Keys / seahorse), then checks `gh auth status` answers promptly; a session never unlocks or re-logs it.")
    end
    -- A host (or toolbox) without gh is not unreachable: git's own probe below
    -- still judges the remote. Say so, and skip only the gh half.
    log.raw("note:remote-probe:no-gh — `gh` could not be run here (" .. tostring(g.stderr or g.status)
        .. "); its login state is not judged, git ls-remote still is (2239-rmun)")
    g = { ok = true, code = 0 }
end
if g.code ~= 0 then
    local said = text.trim(((g.stdout or "") .. "\n" .. (g.stderr or "")):gsub("\n+", " "))
    if said:find("Timeout trying to log in", 1, true) then network("gh timed out reaching GitHub: " .. said:sub(1, 200)) end
    if not said:find("not logged in", 1, true) then
        local l = ls_remote()
        if l.status == "timed_out" or cut(l) then
            network("`gh auth status` failed and git cannot connect either: " .. text.trim(l.stderr or ""):sub(1, 200))
        end
    end
    blocked("gh-auth", "`gh auth status` reports this host is not logged in or its token is invalid: " .. said:sub(1, 200),
        "a HUMAN re-authenticates gh on this host (`gh auth login`, or refreshing the keyring token); a session never runs it.")
end

-- 2. Can git itself reach origin? (credential helper, network, remote url)
local r = ls_remote()
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
    if cut(r) then network("git cannot connect to origin: " .. text.trim(err):sub(1, 200)) end
    blocked("ls-remote-failed", "`git ls-remote origin` failed (rc=" .. tostring(r.code) .. "): " .. text.trim(err):sub(1, 200),
        "check the remote url (`git remote -v`) and the network.")
end

verdict.emit("ok:remote-reachable", 0)
