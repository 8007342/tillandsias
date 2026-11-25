-- @trace order:2207-v7x2, order:2232-k8jc, order:2304-hubj
--
-- test-live-vault-fixture-is-opt-in.lua — the live vault-shutdown fixture never
-- touches a container unless TILLANDSIAS_LIVE_VAULT_FIXTURE=1 is set, and the
-- changed-fixture guard skips it by name. A land gate's changed-fixture pass
-- ran it on yoga 2026-11-21 and left the host's live vault stopped.
-- Ported from test-live-vault-fixture-is-opt-in.sh (2232-k8jc).
--
--   1 SKIP     without the opt-in: a named skip:, exit 3, and ZERO podman calls
--              (a podman stub first on PATH logs every call; it is never run).
--   2 LIVE     the live vault's container ID and state are byte-identical
--              before and after arm 1 (read-only inspect; skipped when this
--              host has no podman or no vault).
--   3 OPT-IN   with the opt-in the fixture DOES reach podman (the stub is
--              called; it answers "no such container", so nothing real is
--              stopped). Without this, a fixture that never runs scores arm 1.
--   4 GUARD    preflight-fixtures-default-target.sh skips a fixture carrying
--              `# @live-fixture` by name, and the vault fixture carries it.
--
-- The opt-in variables are TILLANDSIAS_* and so pass through proc.run's scrub;
-- every run sets them explicitly ("" is unset for the fixture's tests).
--
-- Verdict: ok:live-vault-fixture-is-opt-in:4 | violation:live-vault-fixture-is-opt-in:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("live-vault-fixture-is-opt-in")
local root = fixture.repo_root()
local FX = "scripts/test-vault-shutdown-forwards-sigterm.sh"
local pass, failn = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local W = T:scratch()
local rel = W.rel
fs.mkdir(rel .. "/bin")
fs.write(rel .. "/bin/podman", "#!/usr/bin/env bash\necho \"$*\" >> \"" .. W.abs .. "/podman.calls\"\nexit 1\n")
T:must{ "chmod", "+x", W.abs .. "/bin/podman" }

-- The stub directory is put first INSIDE the shell. An inherited PATH is not
-- enough on msys: Git's bash.exe prepends its own directories, and C:/ splits a
-- colon-separated PATH at the drive. The inner `bash` inherits it as set.
local function run_fixture(env)
    return T:run{ fixture.posix_shell(), "-s", "--", W.abs .. "/bin", FX, cwd = root, env = env,
        stdin = 'd="$1"\nif command -v cygpath >/dev/null 2>&1; then d="$(cygpath -u -- "$d")"; fi\n'
            .. 'export PATH="$d:$PATH"\nexec bash "$2"\n' }
end
local function calls()
    if not fs.exists(rel .. "/podman.calls") then return 0 end
    local _, n = fs.read(rel .. "/podman.calls"):gsub("\n", "")
    return n
end

-- the REAL vault's id and state, read-only; empty when none
-- (proc.run resolves `podman` on the unstubbed PATH; no podman at all is a
-- run with no exit code, read as "no vault".)
local function live()
    local r = proc.run{ argv = { "podman", "inspect", "tillandsias-vault", "--format",
        "{{.Id}} {{.State.Status}} {{.State.StartedAt}}" }, timeout_ms = 30000 }
    -- stdout whatever the rc, as the .sh's `… 2>/dev/null || true` kept it: an
    -- inspect that matches a non-container object prints its id and exits 125,
    -- and that id still has to be the same before and after.
    return text.trim(r.stdout or "")
end
local before = live()

-- 1
local r = run_fixture{ TILLANDSIAS_LIVE_VAULT_FIXTURE = "", TILLANDSIAS_VAULT_FIXTURE_LIB = "" }
local said = (r.stdout or "") .. (r.stderr or "")
local n = calls()
if r.code == 3 and n == 0 and said:find("skip:vault-shutdown:live-fixture-not-opted-in", 1, true) then
    ok("1 SKIP without the opt-in: named skip, rc 3, no podman call")
else
    local head = table.concat({ text.lines(said)[1] or "", text.lines(said)[2] or "" }, "|")
    bad("1 SKIP wanted rc 3, 0 podman calls and skip:vault-shutdown:live-fixture-not-opted-in; got rc="
        .. tostring(r.code) .. " calls=" .. n .. ": " .. head)
end

-- 2
local after = live()
if before == "" then
    ok("2 LIVE skip: no live tillandsias-vault on this host to compare")
elseif before == after then
    ok("2 LIVE the live vault's id and state are unchanged (" .. before .. ")")
else
    bad("2 LIVE the live vault changed: before=[" .. before .. "] after=[" .. after .. "]")
end

-- 3
if fs.exists(rel .. "/podman.calls") then fs.write(rel .. "/podman.calls", "") end
run_fixture{ TILLANDSIAS_LIVE_VAULT_FIXTURE = "1", TILLANDSIAS_VAULT_FIXTURE_LIB = "",
    TILLANDSIAS_VAULT_CONTAINER = "no-such-container-2207-v7x2" }
n = calls()
if n > 0 then ok("3 OPT-IN with the opt-in the fixture reaches podman (" .. n .. " stub calls)")
else bad("3 OPT-IN with the opt-in the fixture never reached podman — arm 1 would pass a fixture that never runs") end

-- 4
local fx = fs.read(FX)
local guard = fs.read("scripts/preflight-fixtures-default-target.sh")
if fx:find("\n# @live-fixture ", 1, true)
    and guard:find("grep -qE '^(#|--) @live-fixture '", 1, true) then
    ok("4 GUARD the vault fixture is marked @live-fixture and the changed-fixture guard skips that marker")
else
    bad("4 GUARD the @live-fixture marker or the guard's skip for it is missing")
end

T:cleanup()
out.line("live-vault-fixture-is-opt-in: " .. pass .. " passed, " .. failn .. " failed")
if failn == 0 then verdict.ok("live-vault-fixture-is-opt-in:" .. pass) end
verdict.emit("violation:live-vault-fixture-is-opt-in:" .. failn .. "-failed", 1)
