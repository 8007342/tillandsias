-- @env PATH HOME
-- @trace order:814-75yf
--
-- test-check-test-host-paths.lua — check-test-host-paths.lua refuses a test reading a Linux-only
-- host path, and only that. Arm 1 is the real defect: instance 1's sampler.rs as it was before
-- 71496d6e5, read from git, is refused naming MetricsSampler::new().
--   1 instance 1 pre-fix (from git) is refused   2 today's sampler.rs passes
--   3 a /proc read in #[cfg(test)] is refused    4 the same under #[cfg(target_os = "linux")] passes
--   5 a comment naming /proc passes              6 `// host-path:` allows it
--   7 the same read outside test code passes     8 a file under tests/ is test code
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-test-host-paths.lua
-- Verdict: ok:check-test-host-paths:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-test-host-paths")
local CHECK = "scripts/lua/check-test-host-paths.lua"
local d = T:scratch()
local function run(rel) return T:run{ fixture.plan_binary(), "script", "run", CHECK, "--", rel, timeout_ms = 60000, refusal_ok = true } end
local function refused(r) return text.contains(r.stdout or "", "violation:test-host-paths:") end
local function passed(r) return text.contains(r.stdout or "", "ok:test-host-paths:") end
local function put(name, body) fs.write(d.rel .. "/" .. name, body); return d.rel .. "/" .. name end

local g = proc.run{ argv = { "git", "show", "71496d6e5^:crates/tillandsias-metrics/src/sampler.rs" }, timeout_ms = 30000 }
T:arm("1 premise: instance 1's pre-fix sampler.rs is in git", g.code == 0 and #(g.stdout or "") > 1000, tostring(g.code))
local r = run(put("pre.rs", g.stdout or ""))
T:arm("1 instance 1 pre-fix is refused, naming MetricsSampler::new()", refused(r) and text.contains(r.stdout, "MetricsSampler::new()"), (r.stdout or ""):sub(1, 300))
r = run("crates/tillandsias-metrics/src/sampler.rs")
T:arm("2 today's sampler.rs passes", passed(r), (r.stdout or ""):sub(1, 300))
local READ = '        let s = std::fs::read_to_string("/proc/diskstats").unwrap();\n'
r = run(put("a.rs", "fn f() {}\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn t() {\n" .. READ .. "    }\n}\n"))
T:arm("3 a /proc read in #[cfg(test)] is refused", refused(r), r.stdout or "")
r = run(put("b.rs", "#[cfg(test)]\nmod tests {\n    #[cfg(target_os = \"linux\")]\n    #[test]\n    fn t() {\n" .. READ .. "    }\n}\n"))
T:arm("4 gated by target_os it passes", passed(r), r.stdout or "")
r = run(put("c.rs", "#[cfg(test)]\nmod tests {\n    // read_to_string(\"/proc/diskstats\") is what the old test did\n}\n"))
T:arm("5 a comment passes", passed(r), r.stdout or "")
r = run(put("e.rs", "#[cfg(test)]\nmod tests {\n    fn t() {\n        // host-path: degrades with .ok()\n" .. READ .. "    }\n}\n"))
T:arm("6 host-path: allows it", passed(r), r.stdout or "")
r = run(put("f.rs", "fn live() {\n" .. READ .. "}\n#[cfg(test)]\nmod tests {}\n"))
T:arm("7 outside test code passes", passed(r), r.stdout or "")
fs.mkdir(d.rel .. "/tests")
r = run(put("tests/g.rs", "fn t() {\n" .. READ .. "}\n"))
T:arm("8 a file under tests/ is test code", refused(r), r.stdout or "")
T:finish()
