-- @trace order:968-uhzg, order:2305-zm8j, spec:methodology-accountability
--
-- test-exact-version-literal-added.lua — drives
-- scripts/lua/check-exact-version-literal-added.lua over scratch repositories
-- whose origin/linux-next is their first commit. Ported from the .sh (2305-zm8j).
--
--   1 an ADDED `.schema_version == 2` (jq) is REFUSED, naming file:line
--   2 an added shell -eq and Rust != literal are refused too: the class, not one spelling
--   3 the same literal with an `exact-version: <reason>` marker is admitted
--   4 a floor (>=) and a NAMED constant are admitted
--   5 NEGATIVE CONTROL: a pin already in the base is not re-litigated
--   6 host-capability-probe.sh's own validation filter admits a BUMPED schema (4)
--     and still refuses one below its floor (1). An exact pin made the first bump
--     of the capability row unpublishable (lenovinha, 2026-09-02).
--
-- Verdict: ok:exact-version-literal-added-fixture:6/6 | violation:exact-version-literal-added-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("exact-version-literal-added-fixture")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local GUARD = ROOT .. "/scripts/lua/check-exact-version-literal-added.lua"
-- 1592-idmu: the gate's frozen base is a SHA of the gated checkout; the scratch
-- repository's base is its own origin/linux-next.
local DROP = { "TILLANDSIAS_GATE_DIFF_BASE", "TILLANDSIAS_EXACT_VERSION_BASE", "TILLANDSIAS_REPO_ROOT" }
local function repo(name, base)
    local d = T:git_repo(name)
    fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/crates/c/src")
    fs.write(d.rel .. "/scripts/v.sh", base)
    T:must{ "git", "-C", d.abs, "add", "-A" }
    T:must{ "git", "-C", d.abs, "commit", "-qm", "base" }
    T:must{ "git", "-C", d.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
    return d
end
local function guard(d)
    local r = T:run{ PLAN, "script", "run", GUARD, cwd = d.abs, env_unset = DROP, timeout_ms = 60000 }
    return r.code, "\n" .. (r.stdout or "") .. "\n" .. (r.stderr or "") .. "\n"
end
local function says(o, l) return o:find("\n" .. l .. "\n", 1, true) ~= nil end
local SH = "#!/bin/bash\n"
local PIN = SH .. 'jq -e ".schema_version == 2" doc.json\n'

local d = repo("one", SH)
fs.write(d.rel .. "/scripts/v.sh", PIN)
local rc, o = guard(d)
T:arm("1 an added .schema_version == 2 is refused, naming scripts/v.sh:2",
    rc == 1 and says(o, "violation:exact-version-literal-added:1") and o:find("scripts/v.sh:2", 1, true) ~= nil, "rc=" .. tostring(rc) .. o)

d = repo("two", SH)
fs.write(d.rel .. "/scripts/v.sh", SH .. '[ "$version" -eq 3 ] || exit 1\n')
fs.write(d.rel .. "/crates/c/src/lib.rs", "fn f(t: &T) -> bool {\n    if t.version != 1 {\n        return false;\n    }\n    true\n}\n")
rc, o = guard(d)
T:arm("2 shell -eq 3 and Rust != 1 are both refused", rc == 1 and says(o, "violation:exact-version-literal-added:2"), "rc=" .. tostring(rc) .. o)

d = repo("three", SH)
fs.write(d.rel .. "/scripts/v.sh", SH .. '# exact-version: the v2 on-disk header is the only layout this reader parses\n[ "$version" -eq 2 ] || exit 1\n')
rc, o = guard(d)
T:arm("3 an exact literal with an exact-version: reason is admitted", rc == 0 and says(o, "ok:exact-version-literal-added:1 checked"), "rc=" .. tostring(rc) .. o)

d = repo("four", SH)
fs.write(d.rel .. "/scripts/v.sh", SH .. 'jq -e ".schema_version >= 2" doc.json\n')
fs.write(d.rel .. "/crates/c/src/lib.rs", "fn f(t: &T) -> bool {\n    t.version == SCHEMA_VERSION\n}\n")
rc, o = guard(d)
T:arm("4 a floor and a named constant are admitted", rc == 0 and says(o, "ok:exact-version-literal-added:2 checked"), "rc=" .. tostring(rc) .. o)

d = repo("five", PIN)
fs.write(d.rel .. "/scripts/v.sh", PIN .. "echo unrelated addition\n")
rc, o = guard(d)
T:arm("5 NEGATIVE CONTROL a pre-existing pin is not re-litigated", rc == 0 and says(o, "ok:exact-version-literal-added:1 checked"), "rc=" .. tostring(rc) .. o)

-- The probe's own validation filter, cut from its source (first match).
local filter = fs.read("scripts/host-capability-probe.sh"):match("'(%.schema_version >= %d+[^'\n]*)'") or ""
local function judged(v)
    local r = T:run{ PLAN, "json", "get", "-e", filter, stdin = '{"schema_version":' .. v .. ',"host":{"host_id":"h"}}' }
    return r.code, text.trim(r.stdout or "")
end
local rb, bumped, rl = nil, "", nil
if filter ~= "" then rb, bumped = judged(4); rl = judged(1) end
T:arm("6 the capability probe's validator admits schema_version 4 and refuses 1",
    rb == 0 and bumped == "true" and rl ~= nil and rl ~= 0, "filter=[" .. filter .. "] bumped=[" .. bumped .. "] rc=" .. tostring(rb) .. " below rc=" .. tostring(rl))
T:finish({ ok = function(n) return "ok:exact-version-literal-added-fixture:" .. n .. "/" .. n end })
