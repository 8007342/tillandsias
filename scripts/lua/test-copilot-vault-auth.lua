-- @env PATH
-- @env TILLANDSIAS_COPILOT_AUTH_SRC
-- @trace order:2063-nfag, spec:tillandsias-vault
--
-- test-copilot-vault-auth.lua — the copilot lane's sign-in reaches Vault and
-- comes back without a plaintext file on disk (operator ruling 2026-11-08,
-- option B). `copilot login --device-code` runs with COPILOT_HOME in RAM; the
-- credential files are archived as one opaque document into
-- secret/copilot/oauth, and the copilot forge restores them into its RAM
-- COPILOT_HOME. Runs the REAL images/default/provider-oauth-vault.sh and
-- provider-device-auth.sh with a file-backed stub vault-cli.sh, a stub
-- lib-common (require_copilot) and a stub copilot CLI:
--   1 ROUNDTRIP     harvest then restore brings back copilot's credential file;
--                   session-state, logs and pkg are not archived
--   2 DIGEST        the digest moves when the credential changes and ignores
--                   session-state churn
--   3 RESTORE-FAIL  an empty Vault fails the restore, naming --copilot-login
--   4 NO-TOKEN      a login that stored no token fails and writes NOTHING to Vault
--   5 LOGIN-OK      a login that stored a token puts it in Vault, and the login
--                   wrote nothing outside its COPILOT_HOME
-- Red before 2063-nfag: both scripts refuse the copilot provider (exit 64).
--
-- Usage: tillandsias-plan script run scripts/lua/test-copilot-vault-auth.lua
-- Verdict: ok:copilot-vault-auth:5 arms | violation:copilot-vault-auth:<n>-failed

local NAME = "copilot-vault-auth"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local SRC = env.get("TILLANDSIAS_COPILOT_AUTH_SRC") or (ROOT .. "/images/default")

local REL = "target/plan-scratch/copilot-vault-auth-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else out.line("FAIL: " .. name .. " — got: " .. tostring(got)); failed[#failed + 1] = name end
end
-- A fake token: the shape copilot stores, never a real one.
local TOKEN = "gho_" .. string.rep("F1x7", 9)

fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/vault-cli.sh", table.concat({
    "#!/usr/bin/env bash",
    'store="$VAULT_STORE/$(printf %s "${@: -2:1}" | tr / _)"',
    'case "$1" in',
    '    (read) f="$VAULT_STORE/$(printf %s "${@: -1}" | tr / _)"; [ -s "$f" ] || exit 2; cat "$f" ;;',
    '    (write-stdin) cat > "$VAULT_STORE/$(printf %s "$2" | tr / _)" ;;',
    '    (*) exit 64 ;;',
    'esac',
}, "\n") .. "\n")
fs.write(REL .. "/bin/copilot", table.concat({
    "#!/usr/bin/env bash",
    '[ "$1 $2" = "login --device-code" ] || exit 64',
    'printf "%s\\n" "$*" >> "$COPILOT_LOG"',
    'mkdir -p "$COPILOT_HOME/session-state"; echo s > "$COPILOT_HOME/session-state/x"',
    '[ "${FAKE_NO_TOKEN:-}" = 1 ] && { echo "{}" > "$COPILOT_HOME/config.json"; exit 0; }',
    'printf "{\\"copilotTokens\\":{\\"github.com\\":\\"%s\\"}}\\n" "$FAKE_TOKEN" > "$COPILOT_HOME/config.json"',
}, "\n") .. "\n")
fs.write(REL .. "/lib-common.sh", 'require_copilot() { COPILOT_BIN="' .. ABS .. '/bin/copilot"; }\n'
    .. 'ensure_forge_harnesses() { :; }\n')
proc.run({ argv = { "chmod", "+x", ABS .. "/bin/vault-cli.sh", ABS .. "/bin/copilot" } })
-- reads an archive from Vault: its member list, or its config.json
fs.write(REL .. "/peek.sh", table.concat({
    "#!/usr/bin/env bash",
    'case "$1" in',
    '    (list) base64 -d "$2" | tar -tzf - ;;',
    '    (config) base64 -d "$2" | tar -xzOf - ./config.json ;;',
    'esac',
}, "\n") .. "\n")

local n = 0
local function run(script, args, extra)
    n = n + 1
    local rel = REL .. "/c" .. n
    fs.mkdir(rel .. "/vault")
    fs.mkdir(rel .. "/home")
    local argv = { "env",
        "PATH=" .. ABS .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
        "HOME=" .. ROOT .. "/" .. rel .. "/home",
        "VAULT_STORE=" .. ROOT .. "/" .. rel .. "/vault",
        "COPILOT_LOG=" .. ROOT .. "/" .. rel .. "/copilot.log",
        "FAKE_TOKEN=" .. TOKEN,
        "TILLANDSIAS_LIB_COMMON=" .. ABS .. "/lib-common.sh",
        "TILLANDSIAS_OAUTH_PROVIDER=copilot",
        "COPILOT_HOME=" .. ROOT .. "/" .. rel .. "/forge-home",
        "TILLANDSIAS_COPILOT_LOGIN_HOME=" .. ROOT .. "/" .. rel .. "/shm/login-home" }
    for _, e in ipairs(extra or {}) do argv[#argv + 1] = e end
    argv[#argv + 1] = "bash"
    argv[#argv + 1] = SRC .. "/" .. script
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return r, rel
end
local function rd(p) local ok, s = pcall(fs.read, p); return ok and (s or "") or "" end
local function vault_doc(rel) return rd(rel .. "/vault/secret_copilot_oauth") end
-- what an archive in Vault holds: its member names and whether it carries the token
local function members(rel)
    local doc = vault_doc(rel)
    if doc == "" then return "", false end
    fs.write(rel .. "/doc.b64", doc)
    local l = proc.run({ argv = { "bash", ABS .. "/peek.sh", "list", ROOT .. "/" .. rel .. "/doc.b64" } })
    local t = proc.run({ argv = { "bash", ABS .. "/peek.sh", "config", ROOT .. "/" .. rel .. "/doc.b64" } })
    return l.stdout or "", (t.stdout or ""):find(TOKEN, 1, true) ~= nil
end

-- 1 ROUNDTRIP: a forge COPILOT_HOME holding copilot's file plus volatile state
local r1, c1 = run("provider-oauth-vault.sh", { "harvest" })
-- seed after the dirs exist, then harvest again into the same case
fs.mkdir(c1 .. "/forge-home/session-state")
fs.mkdir(c1 .. "/forge-home/logs")
fs.write(c1 .. "/forge-home/config.json", '{"copilotTokens":{"github.com":"' .. TOKEN .. '"}}\n')
fs.write(c1 .. "/forge-home/session-state/s1", "x\n")
fs.write(c1 .. "/forge-home/logs/l1", "x\n")
local function in_case(rel, script, args)
    return proc.run({ argv = { "env",
        "PATH=" .. ABS .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
        "VAULT_STORE=" .. ROOT .. "/" .. rel .. "/vault",
        "TILLANDSIAS_OAUTH_PROVIDER=copilot",
        "COPILOT_HOME=" .. ROOT .. "/" .. rel .. "/" .. (args.home or "forge-home"),
        "bash", SRC .. "/" .. script, args[1] }, timeout_ms = 60000 })
end
local h1 = in_case(c1, "provider-oauth-vault.sh", { "harvest" })
local m1, tok1 = members(c1)
local rs = in_case(c1, "provider-oauth-vault.sh", { "restore", home = "restored-home" })
local back = rd(c1 .. "/restored-home/config.json")
arm("1 ROUNDTRIP harvest archives copilot's file (not session-state/logs) and restore brings it back",
    h1.code == 0 and tok1 and m1:find("session-state", 1, true) == nil and m1:find("logs/", 1, true) == nil
        and rs.code == 0 and back:find(TOKEN, 1, true) ~= nil,
    "harvest=" .. tostring(h1.code) .. " members=[" .. m1 .. "] restore=" .. tostring(rs.code) .. " " .. (rs.stderr or "") .. (h1.stderr or "") .. (r1.stderr or ""))

-- 2 DIGEST
local d0 = text.trim(in_case(c1, "provider-oauth-vault.sh", { "digest" }).stdout or "")
fs.write(c1 .. "/forge-home/session-state/s2", "churn\n")
local d1 = text.trim(in_case(c1, "provider-oauth-vault.sh", { "digest" }).stdout or "")
fs.write(c1 .. "/forge-home/config.json", '{"copilotTokens":{"github.com":"' .. TOKEN .. 'R"}}\n')
local d2 = text.trim(in_case(c1, "provider-oauth-vault.sh", { "digest" }).stdout or "")
arm("2 DIGEST moves on a credential change and ignores session-state churn",
    d0 ~= "" and d0 ~= "missing" and d0 == d1 and d1 ~= d2, d0 .. " / " .. d1 .. " / " .. d2)

-- 3 RESTORE-FAIL
local r3 = run("provider-oauth-vault.sh", { "restore" })
arm("3 RESTORE-FAIL an empty Vault fails the restore and names tillandsias --copilot-login",
    r3.code ~= 0 and (r3.stderr or ""):find("tillandsias --copilot-login", 1, true) ~= nil, tostring(r3.code) .. " " .. (r3.stderr or ""))

-- 4 NO-TOKEN
local r4, c4 = run("provider-device-auth.sh", { "copilot" }, { "FAKE_NO_TOKEN=1" })
arm("4 NO-TOKEN a login that stored no token fails and writes nothing to Vault",
    r4.code ~= 0 and vault_doc(c4) == "" and rd(c4 .. "/copilot.log"):find("login --device-code", 1, true) ~= nil,
    tostring(r4.code) .. " vault=[" .. vault_doc(c4) .. "] " .. (r4.stderr or ""))

-- 5 LOGIN-OK
local r5, c5 = run("provider-device-auth.sh", { "copilot" })
local m5, tok5 = members(c5)
local strays = proc.run({ argv = { "find", ROOT .. "/" .. c5 .. "/home", "-type", "f" } })
arm("5 LOGIN-OK the token reaches Vault as an archive, and nothing was written to HOME",
    r5.code == 0 and tok5 and m5:find("session-state", 1, true) == nil and text.trim(strays.stdout or "") == "",
    tostring(r5.code) .. " members=[" .. m5 .. "] home-files=[" .. (strays.stdout or "") .. "] " .. (r5.stderr or ""))

proc.run({ argv = { "find", ABS, "-delete" } })
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
