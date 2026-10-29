-- @trace order:1910-nb6m, spec:git-mirror-service
--
-- test-git-mirror-seed-retries-transport-failure.lua — the empty-mirror seed
-- survives a transient transport failure. Measured on macOS 2026-10-28: on a
-- cold enclave squid answered the seed's CONNECT github.com with 503 (its first
-- DNS lookups hung ~30 s, then the failure was negative-cached), the seed was
-- single-shot, and the next attempt was the reconciler 120 s later.
--
-- Drives images/git/seed-mirror.sh against a local upstream through a fake
-- `git` on PATH that fails the FIRST fetch with the measured error:
--   1 RETRY     with retries, the mirror ends seeded (exit 0, refs/heads/main)
--   2 CONTROL   with no retries (SEED_RETRY_DELAYS=""), the same upstream leaves
--               the mirror empty: the fixture can fail, and this is the
--               single-shot behaviour the fix replaced
--   3 AUTH      an auth refusal is not retried (exactly one fetch)
--   4 WIRED     entrypoint.sh seeds through $SEED_MIRROR and the image ships it
--
-- Terminal line: ok:git-mirror-seed-retries-transport-failure:<n> or
-- refused:git-mirror-seed-retries-transport-failure:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-seed-retries-transport-failure.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/seed-retry-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function finish()
    proc.run({ argv = { "rm", "-rf", S } })
    if failed == 0 then verdict.emit("ok:git-mirror-seed-retries-transport-failure:" .. passed, 0) end
    verdict.emit("refused:git-mirror-seed-retries-transport-failure:" .. failed, 1)
end

local SEED = fs.exists("images/git/seed-mirror.sh") and fs.read("images/git/seed-mirror.sh") or nil
if not SEED then
    bad("premise: images/git/seed-mirror.sh is absent (the seed is single-shot inside entrypoint.sh)")
    finish()
end
-- The real git is found on this PATH; the fake git sits in front of it.
local REAL_PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

fs.mkdir(REL .. "/bin")
fs.write(REL .. "/seed-mirror.sh", SEED)
-- The fake git: the first N `fetch` calls fail with FAKE_ERR; everything else
-- is the real git. N and the counter file come from the environment.
fs.write(REL .. "/bin/git", table.concat({
    "#!/bin/sh",
    'for a in "$@"; do',
    '  if [ "$a" = fetch ]; then',
    '    n=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_COUNT"',
    '    if [ "$n" -le "$FAKE_FAILS" ]; then echo "$FAKE_ERR" >&2; exit 128; fi',
    "    break",
    "  fi",
    "done",
    'PATH="$REAL_PATH" exec git "$@"',
    "",
}, "\n"))
proc.run({ argv = { "chmod", "+x", S .. "/bin/git" } })

local BASE = { GIT_CONFIG_NOSYSTEM = "1", HOME = S, REAL_PATH = REAL_PATH, PATH = REAL_PATH,
    GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid",
    GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid" }
local function git(dir, args)
    local argv = { "git", "-C", dir }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = BASE, timeout_ms = 30000 })
    return r.code == 0, text.trim(r.stdout or "")
end

-- case(name, fails, err, delays) -> exit code, output, fetch count, seeded?
local function case(name, fails, err, delays)
    local d = S .. "/" .. name
    fs.mkdir(REL .. "/" .. name)
    git(d, { "init", "-q", "-b", "main", "src" })
    fs.write(REL .. "/" .. name .. "/src/f", "c1\n")
    git(d .. "/src", { "add", "f" }); git(d .. "/src", { "commit", "-qm", "c1" })
    git(d, { "init", "-q", "--bare", "mirror.git" })
    git(d .. "/mirror.git", { "remote", "add", "origin", d .. "/src" })
    local env = {}
    for k, v in pairs(BASE) do env[k] = v end
    env.PATH = S .. "/bin:" .. REAL_PATH
    env.FAKE_COUNT, env.FAKE_FAILS, env.FAKE_ERR = d .. "/count", tostring(fails), err
    env.SEED_RETRY_DELAYS = delays
    local r = proc.run({ argv = { "sh", S .. "/seed-mirror.sh", d .. "/mirror.git" }, env = env, timeout_ms = 60000 })
    local count = tonumber(text.trim(fs.read(REL .. "/" .. name .. "/count") or "0")) or 0
    local seeded = git(d .. "/mirror.git", { "rev-parse", "--verify", "--quiet", "refs/heads/main" })
    return r.code, (r.stdout or "") .. (r.stderr or ""), count, seeded
end

local TLS = "fatal: unable to access 'https://github.com/o/r.git/': TLS connect error: error:0A00010B:SSL routines::wrong version number"

local c1, o1, n1, s1 = case("retry", 1, TLS, "0 0")
if c1 == 0 and s1 and n1 == 2 then ok("1: a transport failure is retried and the mirror ends seeded (2 fetches)")
else bad("1: exit=" .. tostring(c1) .. " fetches=" .. n1 .. " seeded=" .. tostring(s1) .. " out=" .. o1:sub(1, 300)) end

local c2, _, n2, s2 = case("control", 1, TLS, "")
if c2 ~= 0 and not s2 and n2 == 1 then ok("2: control: with no retries the same upstream leaves the mirror empty (the single-shot defect)")
else bad("2: control did not fail: exit=" .. tostring(c2) .. " fetches=" .. n2 .. " seeded=" .. tostring(s2)) end

local c3, o3, n3, s3 = case("auth", 9, "fatal: Authentication failed for 'https://github.com/o/r.git/'", "0 0 0")
if c3 ~= 0 and not s3 and n3 == 1 and has(o3, "Authentication failed") then ok("3: an auth refusal is not retried (1 fetch) and its text reaches the caller")
else bad("3: exit=" .. tostring(c3) .. " fetches=" .. n3 .. " out=" .. o3:sub(1, 200)) end

local ENTRY = fs.read("images/git/entrypoint.sh") or ""
local CF = fs.read("images/git/Containerfile") or ""
if has(ENTRY, 'FETCH_OUTPUT="$("$SEED_MIRROR" "$mirror" 2>&1)"')
    and has(CF, "COPY seed-mirror.sh /usr/local/share/git-service/seed-mirror")
    and has(CF, "/usr/local/share/git-service/seed-mirror\n") then
    ok("4: entrypoint.sh seeds through $SEED_MIRROR and the image ships it executable")
else bad("4: entrypoint.sh or the Containerfile does not wire seed-mirror") end

finish()
