-- @env PATH
-- @trace order:1968-psy9, order:441, order:1922-rann, spec:git-mirror-service
--
-- test-git-mirror-ready-before-retry-push.lua — the git mirror sends READY
-- right after its seed fetch, and the per-ref startup retry-push runs after it,
-- in the background, and not at all without an upstream credential (1968-psy9).
--
-- MEASURED on yoga 2026-11-02: READY waited for a per-ref push of all 1489
-- refs, every one refused "HTTPS upstream credential is unavailable", for
-- 49.3 s of every warm forge launch.
--
-- The run arms EXECUTE the real functions, cut out of images/git/entrypoint.sh
-- by name (not a reimplementation), over a scratch mirror with 40 refs and a
-- mock relay helper (RELAY_REF) that records every call:
--   1 NO CREDENTIAL  (no vault-cli on PATH): ONE "SKIPPED" line, zero relay
--                    calls (pre-fix: 40 calls, 40 STRANDED lines, and READY
--                    held for all of them)
--   2 CREDENTIAL     (a stub vault-cli that reads a token): per-ref relay as
--                    before (40 calls; a stranded ref is named) — 441 kept
--   3 ORDER (static) READY is sent before the backgrounded retry-push, and no
--                    relay call remains in the sweep before READY
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-ready-before-retry-push.lua
-- Verdict: ok:git-mirror-ready-before-retry-push:<n> arms | violation:git-mirror-ready-before-retry-push:<n>-failed

local NAME = "git-mirror-ready-before-retry-push"
local ENTRY = "images/git/entrypoint.sh"
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function readf(p) return fs.exists(p) and (fs.read(p) or "") or "" end

local src = fs.read(ENTRY) or ""
local lines = text.lines(src)

-- cut a top-level shell function out of the entrypoint by name
local function cut(fname)
    local buf, inside = {}, false
    for _, l in ipairs(lines) do
        if not inside and l:find("^" .. fname:gsub("%-", "%%-") .. "%(%)%s*{") then inside = true end
        if inside then
            buf[#buf + 1] = l
            if l == "}" then break end
        end
    end
    return table.concat(buf, "\n")
end
local fns = cut("_startup_upstream_credential") .. "\n" .. cut("startup_retry_push") .. "\n"

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/mirror-ready-" .. tostring(time.now_ms())
local ABS = root .. "/" .. REL
fs.mkdir(REL .. "/bin")
fs.write(REL .. "/fns.sh", fns)
-- the mock relay: one line per call; refs containing "stranded" are refused
fs.write(REL .. "/relay", table.concat({
    "#!/usr/bin/env bash",
    "while IFS= read -r line; do",
    '  ref="${line##* }"; echo "$ref" >> "' .. ABS .. '/relay-calls"',
    '  case "$ref" in *stranded*) echo "refusing non-fast-forward: $ref" >&2; exit 1 ;; esac',
    "done",
}, "\n") .. "\n")
fs.write(REL .. "/bin/vault-cli", "#!/usr/bin/env bash\necho tok\n")
fs.write(REL .. "/token", "x\n")
proc.run{ argv = { "chmod", "+x", ABS .. "/relay", ABS .. "/bin/vault-cli" } }

-- a mirror with 39 heads plus one stranded head, and an https origin
fs.write(REL .. "/mk.sh", table.concat({
    "set -e",
    "export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@example.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@example.invalid GIT_CONFIG_NOSYSTEM=1 HOME=" .. ABS,
    "git init -q --bare " .. ABS .. "/mirror.git",
    "git init -q " .. ABS .. "/work",
    "git -C " .. ABS .. "/work commit -q --allow-empty -m base",
    "for i in $(seq 1 39); do git -C " .. ABS .. "/work push -q " .. ABS .. "/mirror.git HEAD:refs/heads/b$i; done",
    "git -C " .. ABS .. "/work push -q " .. ABS .. "/mirror.git HEAD:refs/heads/stranded",
    "git -C " .. ABS .. "/mirror.git remote add origin https://github.invalid/x/y.git",
}, "\n") .. "\n")
proc.run{ argv = { "bash", ABS .. "/mk.sh" }, timeout_ms = 60000 }

local function sweep(path_prefix)
    proc.run{ argv = { "rm", "-f", ABS .. "/relay-calls", ABS .. "/sweep.log" } }
    fs.write(REL .. "/run.sh", table.concat({
        'retry_msg() { echo "$*" >> "' .. ABS .. '/sweep.log"; }',
        ". " .. ABS .. "/fns.sh",
        "export RELAY_REF=" .. ABS .. "/relay VAULT_TOKEN_FILE=" .. ABS .. "/token",
        'startup_retry_push "' .. ABS .. '/mirror.git" https://github.invalid/x/y.git 40',
    }, "\n") .. "\n")
    local r = proc.run{ argv = { "bash", ABS .. "/run.sh" }, timeout_ms = 120000,
        env = { PATH = path_prefix .. "/usr/bin:/bin" } }
    local calls = 0
    for _ in readf(REL .. "/relay-calls"):gmatch("[^\n]+") do calls = calls + 1 end
    return r, calls, readf(REL .. "/sweep.log")
end

arm("0 premise: both functions were cut from the entrypoint",
    fns:find("startup_retry_push%(%)") ~= nil and fns:find("_startup_upstream_credential%(%)") ~= nil, #fns)

local r, calls, log = sweep("")
local _, skipped = log:gsub("Startup retry%-push SKIPPED", "")
arm("1 NO CREDENTIAL: one SKIPPED line and zero relay calls",
    r.code == 0 and calls == 0 and skipped == 1 and not log:find("STRANDED", 1, true),
    "rc=" .. tostring(r.code) .. " calls=" .. calls .. " log=" .. log:sub(1, 200))

r, calls, log = sweep(ABS .. "/bin:")
arm("2 CREDENTIAL: per-ref relay of all 40 refs, the stranded one named",
    calls == 40 and log:find("STRANDED (logged by name): refs/heads/stranded", 1, true) ~= nil
        and log:find("Startup retry-push OK: refs/heads/b1", 1, true) ~= nil,
    "calls=" .. calls .. " log=" .. log:sub(1, 200))

-- 3 static ordering in the real entrypoint
local ready_at, bg_at, relay_before = nil, nil, false
local in_fn = false
for i, l in ipairs(lines) do
    if l:find("^startup_retry_push%(%)") or l:find("^_startup_upstream_credential%(%)") then in_fn = true end
    if in_fn and l == "}" then in_fn = false end
    if not ready_at and l:find('notify_ready "mirror seeded', 1, true) then ready_at = i end
    if not bg_at and l:find('startup_retry_push "$_m"', 1, true) then bg_at = i end
    if not in_fn and not ready_at and l:find('"${RELAY_REF}"', 1, true) and not l:match("^%s*#") then relay_before = true end
end
arm("3 ORDER: READY precedes the backgrounded retry-push, and no relay runs before READY",
    ready_at ~= nil and bg_at ~= nil and ready_at < bg_at and not relay_before and src:find("%) &\nfi") ~= nil,
    "ready=" .. tostring(ready_at) .. " bg=" .. tostring(bg_at) .. " relay_before=" .. tostring(relay_before))

proc.run{ argv = { "rm", "-rf", ABS } }
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
