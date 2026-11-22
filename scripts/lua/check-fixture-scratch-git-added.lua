-- @trace order:2245-scgt, order:2244-crgd, spec:methodology-accountability
-- @env TILLANDSIAS_SCRATCH_GIT_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-fixture-scratch-git-added.lua — a fixture line this change ADDS that
-- runs `git -C "$VAR"` on a scratch repo must use scratch_git instead
-- (scripts/test-support/scratch-git.sh).
--
-- WHY (2244-crgd, 2245-scgt): `git -C ""` is the cwd. When a fixture's scratch
-- path comes back empty (a killed `$(...)`, a trap that resumed after TERM with
-- the scratch gone), a bare `git -C "$D" remote set-url origin ...` rewrites the
-- REAL checkout. It did, on calmecacpilli, twice on 2026-11-22. scratch_git
-- refuses an empty path or one that resolves to the real git dir.
--
-- DIFF-SCOPED: added lines in scripts/test-*.sh only. Not judged:
--   * `git -C "$ROOT"`, `"$REAL_ROOT"`, `"$REPO_ROOT"`: those name the real repo on purpose, to READ it
--   * comment lines
--   * a line carrying `scratch-git-ok: <why>` (the reason is required)
--
--   ok:fixture-scratch-git-added:<n> checked
--   ok:fixture-scratch-git-added:base-unavailable
--   violation:fixture-scratch-git-added:<n>      (rc 1; each site on stderr)

local REAL = { ROOT = true, REAL_ROOT = true, REPO_ROOT = true }

local function lines_of(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end
local function git(...)
    local p = proc.run{ argv = { "git", ... }, timeout_ms = 120000 }
    return p.ok, p.stdout or ""
end

-- The first scratch variable a line hands `git -C`, or nil.
local function bare_site(l)
    if l:match("^%s*#") then return nil end
    if text.is_match(l, [[scratch-git-ok:\s*\S]]) then return nil end
    for v in l:gmatch('git%s+%-C%s+"%${?([%a_][%w_]*)') do
        if not REAL[v] then return v end
    end
    return nil
end

local base = env.get("TILLANDSIAS_SCRATCH_GIT_BASE") or env.get("TILLANDSIAS_GATE_DIFF_BASE") or "origin/linux-next"
if not select(1, git("rev-parse", "--verify", "--quiet", base)) then
    verdict.emit("ok:fixture-scratch-git-added:base-unavailable", 0,
        "  note: base ref '" .. base .. "' unavailable — added-line enforcement skipped")
end

local set, files = {}, {}
local _, d = git("diff", "--name-only", "--diff-filter=AM", base, "--", "scripts/test-*.sh")
local _, u = git("ls-files", "--others", "--exclude-standard", "--", "scripts/test-*.sh")
for _, f in ipairs(lines_of(d .. "\n" .. u)) do
    -- Top-level fixtures only: git's pathspec `*` crosses `/`, and
    -- scripts/test-support/ (the helper itself) is not a fixture.
    if f:match("^scripts/test%-[^/]+%.sh$") and not set[f] then set[f] = true; files[#files + 1] = f end
end
table.sort(files)

local checked, bad = 0, 0
for _, f in ipairs(files) do
    if fs.exists(f) then
        checked = checked + 1
        local L = lines_of(fs.read(f))
        local added = {}
        if select(1, git("ls-files", "--error-unmatch", "--", f)) then
            local _, diff = git("diff", "-U0", base, "--", f)
            local n = 0
            for _, l in ipairs(lines_of(diff)) do
                local h = l:match("^@@ %S+ %+(%d+)")
                if h then n = tonumber(h)
                elseif l:sub(1, 3) == "+++" then -- header
                elseif l:sub(1, 1) == "+" then added[#added + 1] = n; n = n + 1 end
            end
        else
            for i = 1, #L do added[#added + 1] = i end
        end
        for _, ln in ipairs(added) do
            local v = bare_site(L[ln] or "")
            if v then
                bad = bad + 1
                log.raw("REFUSED: " .. f .. ":" .. ln .. " adds `git -C \"$" .. v .. "\"` on a scratch repo:\n"
                    .. "    " .. ((L[ln] or ""):match("^%s*(.*)$")) .. "\n"
                    .. "  why: an empty or stale scratch path makes `git -C` act on the cwd, the REAL checkout\n"
                    .. "       (2244-crgd: origin was rewritten that way, twice, on 2026-11-22).\n"
                    .. "  remedy: source scripts/test-support/scratch-git.sh and write `scratch_git \"$" .. v .. "\" ...`;\n"
                    .. "       if the line reads the real repo on purpose, name it $ROOT, or mark it\n"
                    .. "       # scratch-git-ok: <why this path can never be empty or the checkout>")
            end
        end
    end
end

if bad > 0 then
    verdict.emit("violation:fixture-scratch-git-added:" .. bad, 1,
        "  why: each site above can reach the real checkout through an empty scratch path (2245-scgt)\n"
        .. "  remedy: apply the remedy each REFUSED block names, then re-run this check")
end
verdict.emit("ok:fixture-scratch-git-added:" .. checked .. " checked", 0)
