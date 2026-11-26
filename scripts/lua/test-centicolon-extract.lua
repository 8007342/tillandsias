-- @env PATH HOME
-- @trace order:1395-n7qd, order:2366-7zvv
--
-- test-centicolon-extract.lua — the CentiColon extractor (a cacheable predicate) counts one
-- obligation per scenario under a requirement with a req-id, refuses by name, and is
-- deterministic. Ported from the .sh of the same name (2366-7zvv).
--
--   1 an active spec: ids equal sha256(title)[:8], computed here; a fenced scenario is not one;
--     a numbered heading with no req-id is unkeyed; obsolete and unregistered specs are not counted
--   2 a requirement with no req-id is refused    3 a duplicate identity is
--   4 an empty population is blocked, never ok   5 gh-auth-script: 8 requirements, 21 obligations
--   6 the real corpus three times: byte-identical JSON
--
-- Usage: tillandsias-plan script run scripts/lua/test-centicolon-extract.lua
-- Verdict: ok:centicolon-extract:<n> arms | violation:... | skip:centicolon-extract:...

local fixture = require "common.fixture"
local T = fixture.new("centicolon-extract")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local caps = T:run{ PLAN, "capabilities" }
if not text.contains("\n" .. (caps.stdout or ""), "\npredicate\n") then T:skip("plan-binary-lacks-predicate-verb") end
local function sha8(s)
    local r = T:run{ SH, "-s", "--", s, stdin = "if command -v sha256sum >/dev/null 2>&1; then c=sha256sum; else c='shasum -a 256'; fi\nprintf '%s' \"$1\" | $c\n" }
    return ((r.stdout or ""):match("^%x+") or ""):sub(1, 8)
end
local function extract(root, dirs)
    local r = proc.run{ argv = { PLAN, "predicate", ROOT .. "/scripts/lua/centicolon-extract.lua", "--class", "cacheable", "--arg", dirs }, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_REPO_ROOT = root } }
    local e = ("\n" .. (r.stderr or ""):gsub("\r", "")):gsub("\n%[lua%-predicate%] ", "\n")
    local raw = e:match("\ncenticolon%-extract:([^\n]*)")
    return { rc = r.code, err = e, raw = raw, json = raw and json.parse(raw) or {}, why = "rc=" .. tostring(r.code) .. " " .. e:gsub("\ncenticolon%-extract:[^\n]*", ""):sub(1, 500) }
end
local function line(x, s) return text.contains(x.err .. "\n", "\n" .. s .. "\n") end
-- specs: { {id, status}, ... }; bodies: id -> spec.md
local function corpus(specs, bodies)
    local d = T:scratch()
    local b = "version: '1.0'\nspecs:\n"
    for _, s in ipairs(specs) do b = b .. "- spec_id: " .. s[1] .. "\n  status: " .. s[2] .. "\n  litmus_tests: []\n" end
    fs.mkdir(d.rel .. "/openspec")
    fs.write(d.rel .. "/openspec/litmus-bindings.yaml", b)
    for id, body in pairs(bodies) do
        fs.mkdir(d.rel .. "/openspec/specs/" .. id)
        fs.write(d.rel .. "/openspec/specs/" .. id .. "/spec.md", body)
    end
    return d.abs
end
local x = extract(corpus({ { "alpha", "active" }, { "beta", "obsolete" } }, {
    alpha = "\nstatus: active\n\n## Requirements\n\n### Requirement: The door opens\n<!-- req-id: aaaa0001 -->\nThe door MUST open.\n\n#### Scenario: Opened by a key\n- WHEN a key turns THEN it opens\n\n"
        .. "#### Scenario: Opened by a code\n- WHEN the code is right THEN it opens\n\n```markdown\n#### Scenario: Not a scenario, inside a fence\n```\n\n### Requirement: The door locks\n<!-- req-id: aaaa0002 -->\n\n"
        .. "#### Scenario: Locked at night\n- WHEN night falls THEN it locks\n\n### Requirement 3: The door chimes\n<!-- req-id: aaaa0003 -->\n\n#### Scenario: Chimes on open\n\n### Requirement 4: The door has no id yet\n\n#### Scenario: Not counted\n",
    beta = "\n## Status\n\nobsolete\n\n### Requirement: Gone\n<!-- req-id: bbbb0001 -->\n\n#### Scenario: Never counted\n",
    gamma = "\nstatus: active\n\n### Requirement: Unregistered\n<!-- req-id: cccc0001 -->\n\n#### Scenario: Not in the registry\n" }), "alpha,beta,gamma")
local got, want = {}, {}
for _, o in ipairs(x.json.obligations or {}) do got[#got + 1] = o.id end
for _, w in ipairs{ { "aaaa0001", "Opened by a key" }, { "aaaa0001", "Opened by a code" }, { "aaaa0002", "Locked at night" }, { "aaaa0003", "Chimes on open" } } do want[#want + 1] = "cc:" .. w[1] .. ":" .. sha8(w[2]) end
table.sort(got); table.sort(want)
T:arm("1a four obligations, ids matching sha256(title)[:8], the fenced scenario ignored", x.rc == 0 and table.concat(got, " ") == table.concat(want, " "), table.concat(got, " ") .. " " .. x.why)
T:arm("1b three requirements", x.json.requirements == 3, tostring(x.json.requirements))
T:arm("1c a numbered heading with no req-id is unkeyed, not counted", table.concat(x.json.unkeyed or {}, ",") == "alpha:The door has no id yet", table.concat(x.json.unkeyed or {}, ","))
T:arm("1d an obsolete spec is excluded and counts nothing", (x.json.excluded or {}).obsolete == 1 and x.raw ~= nil and not text.contains(x.raw, "bbbb0001"), tostring((x.json.excluded or {}).obsolete))
T:arm("1e an unregistered spec is named, not counted", table.concat(x.json.unregistered or {}, ",") == "gamma" and x.raw ~= nil and not text.contains(x.raw, "cccc0001"), table.concat(x.json.unregistered or {}, ","))
T:arm("1f the verdict line", text.contains(x.err, "\nok:centicolon-extract:obligations=4 "), x.why)
x = extract(corpus({ { "alpha", "active" } }, { alpha = "status: active\n\n### Requirement: Has an id\n<!-- req-id: aaaa0001 -->\n\n#### Scenario: Fine\n\n### Requirement: Lost its id\n\n#### Scenario: Orphaned\n" }), "alpha")
T:arm("2 a requirement with no req-id is refused by name", x.rc ~= 0 and line(x, "refused:centicolon-extract:requirement-without-req-id:alpha:Lost its id") and not text.contains(x.err, "\nok:"), x.why)
x = extract(corpus({ { "alpha", "active" } }, { alpha = "status: active\n\n### Requirement: Twice\n<!-- req-id: aaaa0001 -->\n\n#### Scenario: Same\n\n#### Scenario: Same\n" }), "alpha")
T:arm("3 a duplicate identity is refused by name", x.rc ~= 0 and line(x, "refused:centicolon-extract:duplicate-obligation-id:alpha:cc:aaaa0001:" .. sha8("Same")), x.why)
x = extract(corpus({ { "beta", "obsolete" } }, { beta = "## Status\n\nobsolete\n" }), "beta")
T:arm("4 an empty population is blocked, never ok", x.rc ~= 0 and line(x, "blocked:centicolon-extract:zero-population") and not text.contains(x.err, "\nok:"), x.why)
x = extract(ROOT, "gh-auth-script")
T:arm("5 gh-auth-script: 8 requirements, 21 obligations", x.rc == 0 and x.json.requirements == 8 and x.json.obligation_count == 21, tostring(x.json.requirements) .. "/" .. tostring(x.json.obligation_count) .. " " .. x.why)
local ls = T:run{ SH, "-s", cwd = ROOT, stdin = 'for d in openspec/specs/*/; do d="${d%/}"; printf "%s," "${d##*/}"; done\n' }
local dirs = text.trim(ls.stdout or "")
local a, b, c = extract(ROOT, dirs), extract(ROOT, dirs), extract(ROOT, dirs)
T:arm("6 the real corpus three times: byte-identical, and not empty", a.raw ~= nil and a.raw == b.raw and b.raw == c.raw and (a.json.obligation_count or 0) > 0, tostring(a.json.obligation_count) .. " " .. a.why)
T:finish()
