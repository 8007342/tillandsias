-- @trace order:2007-uvtl
-- @env PATH
--
-- test-tillandsias-trust.lua — the forge's trust refresh after an enclave CA
-- rotation (images/default/cli/tillandsias-trust), on the host, with a real
-- READ-ONLY bind made in a rootless user+mount namespace (unshare -rm):
--   1 CURRENT  the bundle already trusts the mounted CA: ok:trust-current, unchanged
--   2 REFRESH  the mount holds a new CA: ok:trust-refreshed:<old>-><new>, and the
--              bundle is now vendor roots plus the new CA only
--   3 PLANTED  a forge-WRITABLE directory holding a valid CA is offered as the
--              mount: refused ca_trust_mount_writable, the bundle is unchanged
--   4 ABSENT   no mount: refused ca_trust_mount_absent, naming the remedy
--   5 NOT-CA   a leaf (CA:FALSE) in the mount: refused ca_trust_invalid, kept
--   6 EXPIRED  an expired CA in the mount: refused ca_trust_invalid, kept
--   7 GARBAGE  an unparsable file in the mount: refused ca_trust_invalid, kept
-- Red before 2007-uvtl: the tool did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-trust.lua

local TOOL = "images/default/cli/tillandsias-trust"
if not fs.exists(TOOL) then
    verdict.emit("violation:tillandsias-trust:no-subject", 1, TOOL .. " does not exist")
end
local PATHV = env.get("PATH") or "/usr/bin:/bin"
local function run(argv, extra)
    local e = { PATH = PATHV }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run({ argv = argv, env = e, timeout_ms = 60000 })
    return r.code, r.stdout or "", r.stderr or "", r.status
end
local c0, _, _, st = run({ "unshare", "-rm", "true" })
if st ~= "exited" or c0 ~= 0 then
    verdict.could_not_run("tillandsias-trust", "unshare -rm (a rootless mount namespace) is not available here")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/tt" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
for _, d in ipairs({ "a", "b", "leaf", "old", "junk", "mnt", "run" }) do fs.mkdir(REL .. "/" .. d) end

local function mint(dir, extra)
    local argv = { "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-nodes", "-keyout", DIR .. "/" .. dir .. "/k", "-out", DIR .. "/" .. dir .. "/intermediate.crt",
        "-subj", "/O=Tillandsias/CN=Tillandsias CA" }
    for _, a in ipairs(extra) do argv[#argv + 1] = a end
    local c, o, e = run(argv)
    if c ~= 0 then verdict.could_not_run("tillandsias-trust", "openssl req failed: " .. e) end
    proc.run({ argv = { "rm", "-f", DIR .. "/" .. dir .. "/k" }, timeout_ms = 10000 })
end
mint("a", { "-days", "30", "-addext", "basicConstraints=critical,CA:TRUE" })
mint("b", { "-days", "30", "-addext", "basicConstraints=critical,CA:TRUE" })
mint("leaf", { "-days", "30", "-addext", "basicConstraints=critical,CA:FALSE" })
mint("old", { "-not_before", "20200101000000Z", "-not_after", "20200102000000Z",
    "-addext", "basicConstraints=critical,CA:TRUE" })
fs.write(REL .. "/junk/intermediate.crt", "-----BEGIN CERTIFICATE-----\nnot a cert\n-----END CERTIFICATE-----\n")

local VENDOR = "-----BEGIN CERTIFICATE-----\nVENDOR ROOTS STAND-IN\n-----END CERTIFICATE-----\n"
fs.write(REL .. "/vendor.crt", VENDOR)
local A = fs.read(REL .. "/a/intermediate.crt")
local B = fs.read(REL .. "/b/intermediate.crt")
local function reset_bundle() fs.write(REL .. "/run/ca-bundle.crt", VENDOR .. A) end
local ENV = { TILLANDSIAS_TRUST_MOUNT = DIR .. "/mnt", TILLANDSIAS_TRUST_BUNDLE = DIR .. "/run/ca-bundle.crt",
    TILLANDSIAS_TRUST_VENDOR = DIR .. "/vendor.crt" }

-- `check` with `src` bound READ-ONLY at the mount path, inside a private mount ns.
local function check_ro(src)
    local script = "mount --bind -o ro '" .. DIR .. "/" .. src .. "' '" .. DIR .. "/mnt' && exec python3 '"
        .. ROOT .. "/" .. TOOL .. "' check"
    return run({ "unshare", "-rm", "sh", "-c", script }, ENV)
end
local function check_plain(mount)
    local e = {}
    for k, v in pairs(ENV) do e[k] = v end
    e.TILLANDSIAS_TRUST_MOUNT = mount
    return run({ "python3", ROOT .. "/" .. TOOL, "check" }, e)
end
local function bundle() return fs.read(REL .. "/run/ca-bundle.crt") end
local function has(s, n) return (s or ""):find(n, 1, true) ~= nil end

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

reset_bundle()
local c, o, e = check_ro("a")
arm("1 CURRENT the bundle already trusts the mounted CA", c == 0 and has(o, "ok:trust-current:")
    and bundle() == VENDOR .. A, c .. " " .. o .. e)

c, o, e = check_ro("b")
arm("2 REFRESH a new CA re-composes the bundle", c == 0 and has(o, "ok:trust-refreshed:")
    and has(o, "->") and bundle() == VENDOR .. B, c .. " " .. o .. e)

reset_bundle()
c, o, e = check_plain(DIR .. "/b")
arm("3 PLANTED a forge-writable dir is never a trust source", c == 2
    and has(e, "refused:tillandsias-trust:ca_trust_mount_writable") and bundle() == VENDOR .. A, c .. " " .. e)

c, o, e = check_plain(DIR .. "/nowhere")
arm("4 ABSENT no mount is named with its remedy", c == 2
    and has(e, "ca_trust_mount_absent") and has(e, "relaunch the forge") and bundle() == VENDOR .. A, c .. " " .. e)

for _, t in ipairs({ { "5 NOT-CA", "leaf", "not a CA" }, { "6 EXPIRED", "old", "expired" },
    { "7 GARBAGE", "junk", "does not parse" } }) do
    reset_bundle()
    c, o, e = check_ro(t[2])
    arm(t[1] .. " is refused and the old bundle kept", c == 2 and has(e, "ca_trust_invalid")
        and has(e, t[3]) and bundle() == VENDOR .. A, c .. " " .. e)
end

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-trust:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-trust", passed .. " arms")
