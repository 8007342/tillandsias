-- @trace order:1462-qvxj, spec:command-policies, order:2350-psb7
-- @env PATH HOME
--
-- test-smoke-skill-reset-env-matches-policy.lua — the two smoke skills tell an agent to set
-- exactly the env the consent engine honours (1443-9f5w), and the Bash-tool bridge agrees
-- with `policy eval` under it. Doc-vs-code: the variables are EXTRACTED from each skill's
-- text, never restated here. Ported from the .sh of the same name (2350-psb7); same nine arms.
--
--   1 each smoke SKILL.md carries exactly one prefix line
--     `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=<its own dir name>`; "unset or"
--     appears in neither, nor "unset or 1" in methodology.yaml; `=0` stays the opt-out
--   2 the run door under the extracted env runs the reset (consent_source=env); an
--     unregistered skill asks. The argv is a STUB tillandsias by absolute path, so an
--     allowed run never resets anything (1764-ca9x)
--   3 the bridge (`policy classify-bash`) allows the reset as prefix and as hook env;
--     without TILLANDSIAS_DESTRUCTIVE_RESET_OK it asks
--   4 hard reset is untouched: `wsl --unregister x` is consent:policy:hard-reset and an ask
-- Arms 2-4 need a host that is not a forge; in a forge they are a named skip.
--
-- GRAMMAR ok:smoke-skill-reset-env:9 arms | violation:smoke-skill-reset-env:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("smoke-skill-reset-env")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch()
fs.mkdir(W.rel .. "/cwd"); fs.mkdir(W.rel .. "/bin")
local CWD = W.abs .. "/cwd"
local BASE = { TILLANDSIAS_CONSENT_DIR = W.abs .. "/consent", TILLANDSIAS_POLICY_AUDIT_LOG = W.abs .. "/audit.jsonl" }
local UNSET = { "TILLANDSIAS_SKILL", "TILLANDSIAS_DESTRUCTIVE_RESET_OK", "TILLANDSIAS_HOST_KIND", "TILLANDSIAS_PRETOOLUSE_HOOK" }
local SKILLS = { "smoke-curl-install-and-test-e2e", "build-install-and-smoke-test-e2e" }

local function count(s, pat) local n = 0; for _ in s:gmatch(pat) do n = n + 1 end; return n end

-- 1
local PREFIX = {}
for _, s in ipairs(SKILLS) do
    local md = fs.read("skills/" .. s .. "/SKILL.md")
    local found = {}
    for m in md:gmatch("TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=[%w_%-]*") do found[#found + 1] = m end
    local want = "TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=" .. s
    local ok = #found == 1 and found[1] == want and not text.contains(md, "unset or") and text.contains(md, "TILLANDSIAS_DESTRUCTIVE_RESET_OK=0")
    if ok then PREFIX[s] = found[1] end
    T:arm("1 " .. s .. " prescribes [" .. want .. "]; no 'unset or'; =0 opt-out documented", ok,
        "pair_lines=" .. #found .. " found=[" .. table.concat(found, ",") .. "] unset_or=" .. count(md, "unset or"))
end
T:arm("1 methodology.yaml no longer says 'unset or 1'", not text.contains(fs.read("methodology.yaml"), "unset or 1"), "still present")

local function plan(args, extra)
    local argv = { PLAN }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = CWD, e, UNSET, 60000
    local r = T:run(argv)
    return r.code, text.trim(r.stdout or "")
end
local function jf(filter, s)
    fs.write(W.rel .. "/j.json", s)
    return text.trim(T:run{ PLAN, "json", "get", "-r", filter, W.abs .. "/j.json", timeout_ms = 30000 }.stdout or "")
end

-- PREMISE (1764-ca9x): the stub argv is still a soft reset, or arm 2 would be judged on an
-- argv the policy simply allows.
local STUB = W.abs .. "/bin/tillandsias"
fs.write(W.rel .. "/bin/tillandsias", '#!/bin/sh\necho "STUB-tillandsias $*"\n')
T:must{ "chmod", "+x", STUB }
-- 2418-q7rv: on Windows the run door spawns natively, and a #!/bin/sh stub is not an executable
-- there (os error 193). CreateProcess tries <path>.exe for an extensionless path, so a native
-- stub beside it, Git's true.exe (exits 0 whatever its args), runs under the SAME argv the policy
-- judges. Unix never looks for the .exe.
if fixture.posix_shell() ~= "bash" then
    local t = T:run{ fixture.posix_shell(), "-s", "--", W.abs .. "/bin/tillandsias.exe", stdin = 'cp /usr/bin/true.exe "$1"\n' }
    if t.code ~= 0 then T:refuse("no-native-stub", "could not copy Git's true.exe as the stub") end
end
local _, pe = plan{ "policy", "eval", "--", STUB, "--reset-state" }
if pe ~= "consent:policy:soft-reset" then T:refuse("premise", "the stub argv left the soft-reset class ([" .. pe .. "])") end

-- A forge is a container whose image carries the root-owned forge marker (the policy's own
-- evidence since 2354-5biy; the image name alone no longer is). The marker is outside fs's scope,
-- so cat reads it.
local rec = T:run{ "cat", "/etc/tillandsias/forge", timeout_ms = 10000 }
if rec.code == 0 and ("\n" .. (rec.stdout or "")):match("\nkind=forge\n") then
    out.line("skip: 2, 3, 4 the container record names the forge image; run on bare metal")
    T:finish()
end
for _, s in ipairs(SKILLS) do
    local pfx = PREFIX[s]
    if not pfx then
        T:arm("2-4 " .. s .. " has an extracted prefix", false, "arm 1 failed")
    else
        local k1, v1, k2, v2 = pfx:match("^(%S+)=(%S+) (%S+)=(%S+)$")
        local pair = { [k1] = v1, [k2] = v2 }
        -- 2
        local rc, r = plan({ "run", "--json", "--", STUB, "--reset-state" }, pair)
        local audit = fs.exists(W.rel .. "/audit.jsonl") and fs.read(W.rel .. "/audit.jsonl") or ""
        local last = audit:match("([^\n]+)\n?$") or ""
        local src = last ~= "" and jf(".consent_source", last) or ""
        local rcu, ru = plan({ "run", "--json", "--", STUB, "--reset-state" }, { [k1] = v1, TILLANDSIAS_SKILL = "not-a-smoke-skill" })
        T:arm("2 " .. s .. " env runs the reset at the run door (consent_source=env); an unregistered skill asks",
            rc == 0 and jf(".status", r) == "exited" and src == "env" and rcu == 4 and jf(".policy.rule_id", ru) == "soft-reset",
            "run rc=" .. tostring(rc) .. " [" .. r .. "] src=[" .. src .. "]; unregistered rc=" .. tostring(rcu) .. " [" .. ru .. "]")
        -- 3
        local rp = plan{ "policy", "classify-bash", "--command", pfx .. " tillandsias --reset-state", "--cwd", CWD }
        local re = plan({ "policy", "classify-bash", "--command", "tillandsias --reset-state", "--cwd", CWD }, pair)
        local rn = plan{ "policy", "classify-bash", "--command", k2 .. "=" .. v2 .. " tillandsias --reset-state", "--cwd", CWD }
        T:arm("3 " .. s .. " the bridge allows the prescribed reset (prefix and hook env); without RESET_OK it asks",
            rp == 0 and re == 0 and rn == 4, "prefix rc=" .. tostring(rp) .. " env rc=" .. tostring(re) .. " no-reset-ok rc=" .. tostring(rn) .. " (0 allow, 4 ask)")
        -- 4
        local rch, outh = plan({ "policy", "eval", "--", "wsl", "--unregister", "x" }, pair)
        local rbh = plan{ "policy", "classify-bash", "--command", pfx .. " wsl --unregister x", "--cwd", CWD }
        T:arm("4 " .. s .. " hard reset stays consent:policy:hard-reset (eval) and an ask (bridge)",
            rch == 4 and outh == "consent:policy:hard-reset" and rbh == 4, "eval [" .. outh .. "] rc=" .. tostring(rch) .. " bridge rc=" .. tostring(rbh))
    end
end

T:finish()
