-- @trace order:1762-bano
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-enclave-ca-not-host-trusted.lua — scripts/lua/check-enclave-ca-not-host-trusted.lua:
--   1 LIVE      this tree installs no CA into a host trust store
--   2 MUTATION  a host script that adds the enclave CA to the user's NSS db is
--               refused, naming the file and line
--   3 RUST      a Command running update-ca-trust in crates/ is refused
--   4 MARKED    the same NSS add with `host-trust-ok: <the preview CA>` passes
--               (1761-bvyn's constrained CA is the one allowed host anchor)
--   5 COMMENT   a comment that mentions update-ca-trust is not a site
--               (NEGATIVE CONTROL for arm 2's matcher)
--
-- Usage: tillandsias-plan script run scripts/lua/test-enclave-ca-not-host-trusted.lua

local SUBJECT = "scripts/lua/check-enclave-ca-not-host-trusted.lua"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("enclave-ca-not-host-trusted-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("enclave-ca-not-host-trusted-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/host-trust-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function run(scan)
    local e = {}
    if scan then e.TILLANDSIAS_HOST_TRUST_SCAN = scan end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT, env = e, timeout_ms = 120000 })
    return r.code or -1, text.trim(r.stdout or "")
end
local function tree(name, file, body)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/" .. (file:match("^(.*)/[^/]+$") or ""))
    fs.write(d .. "/" .. file, body)
    return d
end

local rc, o = run(nil)
arm("1 LIVE this tree installs no CA into a host trust store",
    rc == 0 and o:find("^ok:enclave%-ca%-not%-host%-trusted:files=%d+") ~= nil, rc .. " " .. o)

local NSS = 'certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n tillandsias -i "$CA/intermediate.crt"\n'
local d = tree("mutation", "scripts/trust-ca.sh", "#!/bin/bash\nset -eu\n" .. NSS)
rc, o = run(d)
arm("2 MUTATION adding the enclave CA to the user's NSS db is refused, naming file and line",
    rc == 1 and o:find("violation:enclave-ca-not-host-trusted:sites=1", 1, true) ~= nil
    and o:find("site: " .. d .. "/scripts/trust-ca.sh:3:", 1, true) ~= nil, rc .. " " .. o)

d = tree("rust", "crates/x/src/lib.rs", 'fn f() { let _ = std::process::Command::new("update-ca-trust").status(); }\n')
rc, o = run(d)
arm("3 RUST a Command running update-ca-trust in crates/ is refused",
    rc == 1 and o:find("sites=1", 1, true) ~= nil, rc .. " " .. o)

d = tree("marked", "scripts/trust-preview.sh", "#!/bin/bash\n# host-trust-ok: 1761-bvyn preview CA, name-constrained to .localhost\n" .. NSS)
rc, o = run(d)
arm("4 MARKED the constrained preview CA's add, marked host-trust-ok, passes",
    rc == 0 and o:find(":allowed=1", 1, true) ~= nil, rc .. " " .. o)

d = tree("comment", "scripts/notes.sh", "#!/bin/bash\n# never run update-ca-trust on the host\necho ok\n")
rc, o = run(d)
arm("5 COMMENT a comment mentioning update-ca-trust is not a site",
    rc == 0 and o:find(":allowed=0", 1, true) ~= nil, rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then verdict.emit("refused:enclave-ca-not-host-trusted-fixture:" .. #failed .. "-of-5", 1) end
verdict.emit("ok:enclave-ca-not-host-trusted-fixture:5", 0)
