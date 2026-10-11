-- @trace order:1590-j20f
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-manifest-dir-env.lua — the shared-target defect, and its guard.
--
-- Arms 1-4 run scripts/lua/check-manifest-dir-env.lua on CONSTRUCTED scratch
-- roots (TILLANDSIAS_REPO_ROOT):
--   1 COUNT    one test site at its floor, plus one non-test site and one
--              comment line: ok:manifest-dir-env:scanned=2:test=1:floor=1:non-test=1:files=1.
--              The population is counted, and the comment line is not a site.
--   2 NEW      the mutation: one more site in a tests/ file that has no floor
--              line is refused as new-site:<path>:1>floor:0, exit 1.
--   3 STALE    a floor above the count is refused as stale-floor, so the floor
--              only falls.
--   4 EMPTY    no crates/ at all is could-not-run, exit 3, never a green.
-- Arm 5 is the defect itself, on a real cargo (exit criterion 1 of 1590-j20f):
--   5 SHARED   two copies A and B of one tiny crate share a CARGO_TARGET_DIR,
--              and each has its own fixture.txt. The test is built and run in
--              A, then run in B with B's sources unchanged. The runtime read,
--              std::env::var("CARGO_MANIFEST_DIR"), follows B's file. In the
--              SAME run the compile-time env!() read still follows A's file:
--              that is the control showing this cargo still reuses A's binary.
--              If the control flips, cargo has started tracking the variable;
--              the arm fails by name so the guard's premise is re-measured, not
--              silently kept.
--
-- PRE-GUARD CODE FAILS IT: with no check-manifest-dir-env.lua the fixture
-- refuses, never a skip.
--
-- Usage: tillandsias-plan script run scripts/lua/test-manifest-dir-env.lua [-- --plan <bin>]

local SUBJECT_REL = "scripts/lua/check-manifest-dir-env.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:manifest-dir-env-fixture:no-subject", 1,
        "scripts/lua/check-manifest-dir-env.lua does not exist (1590-j20f)")
end

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("manifest-dir-env-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local SUBJECT = ROOT .. "/" .. SUBJECT_REL

-- Scratch roots under target/plan-scratch, never /tmp or the checkout proper.
local REL = "target/plan-scratch/manifest-dir-env-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))

local SITE = 'env!("CARGO_MANIFEST_DIR")'
local LIB = table.concat({
    "pub fn root() -> &'static str { " .. SITE .. " }",
    "// a comment naming " .. SITE .. " is not a site",
    "#[cfg(test)]",
    "mod tests {",
    "    fn p() -> &'static str { " .. SITE .. " }",
    "}",
    "",
}, "\n")

local function tree(name, floor, extra_test)
    local r = REL .. "/" .. name
    fs.mkdir(r .. "/crates/a/src")
    fs.mkdir(r .. "/crates/a/tests")
    fs.mkdir(r .. "/scripts/portability")
    fs.write(r .. "/crates/a/src/lib.rs", LIB)
    if extra_test then fs.write(r .. "/crates/a/tests/x.rs", "fn q() -> &'static str { " .. SITE .. " }\n") end
    fs.write(r .. "/scripts/portability/manifest-dir-env-floor.txt", "# floor\n" .. floor)
    return r
end

local function subject(rel)
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT,
        env = { TILLANDSIAS_REPO_ROOT = ROOT .. "/" .. rel }, timeout_ms = 60000 })
    return (r.status == "exited" and r.code or -1), text.trim(r.stdout or "")
end

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

local rc, o = subject(tree("count", "crates/a/src/lib.rs 1\n", false))
arm("1 COUNT the population is counted and a comment is not a site",
    rc == 0 and o == "ok:manifest-dir-env:scanned=2:test=1:floor=1:non-test=1:files=1", rc .. " " .. o)

rc, o = subject(tree("new", "crates/a/src/lib.rs 1\n", true))
arm("2 NEW a new test site with no floor line is refused",
    rc == 1 and o:find("violation:manifest-dir-env:new-site:crates/a/tests/x.rs:1>floor:0", 1, true) ~= nil, rc .. " " .. o)

rc, o = subject(tree("stale", "crates/a/src/lib.rs 2\n", false))
arm("3 STALE a floor above the count is refused",
    rc == 1 and o:find("violation:manifest-dir-env:stale-floor:crates/a/src/lib.rs:1<floor:2", 1, true) ~= nil, rc .. " " .. o)

fs.mkdir(REL .. "/empty/scripts")
rc, o = subject(REL .. "/empty")
arm("4 EMPTY no crates/ is could-not-run",
    rc == 3 and o:find("could-not-run:manifest-dir-env:empty-population", 1, true) ~= nil, rc .. " " .. o)

-- ── 5 SHARED: the defect on a real cargo ───────────────────────────────────
local MAIN = table.concat({
    "#[test]",
    "fn reads() {",
    "    let compile = std::fs::read_to_string(std::path::Path::new(" .. SITE .. ").join(\"fixture.txt\")).unwrap();",
    "    let dir = std::env::var(\"CARGO_MANIFEST_DIR\").unwrap();",
    "    let runtime = std::fs::read_to_string(std::path::Path::new(&dir).join(\"fixture.txt\")).unwrap();",
    "    println!(\"compile={} runtime={}\", compile.trim(), runtime.trim());",
    "}",
    "",
}, "\n")
-- `[workspace]` keeps cargo from adopting the repo's own workspace above it.
local TOML = "[package]\nname = \"j20fprobe\"\nversion = \"0.1.0\"\nedition = \"2021\"\n[workspace]\n"
for _, copy in ipairs({ "A", "B" }) do
    fs.mkdir(REL .. "/shared/" .. copy .. "/src")
    fs.write(REL .. "/shared/" .. copy .. "/Cargo.toml", TOML)
    fs.write(REL .. "/shared/" .. copy .. "/src/lib.rs", MAIN)
    fs.write(REL .. "/shared/" .. copy .. "/fixture.txt", "from-" .. copy .. "\n")
end
local function cargo_test(copy)
    local r = proc.run({ argv = { "cargo", "test", "-q", "--", "--nocapture" },
        cwd = ROOT .. "/" .. REL .. "/shared/" .. copy,
        env = { CARGO_TARGET_DIR = ROOT .. "/" .. REL .. "/shared/target", CARGO_NET_OFFLINE = "true" },
        timeout_ms = 240000 })
    local line = (r.stdout or ""):match("(compile=%S+ runtime=%S+)") or ""
    return (r.status == "exited" and r.code or -1), line, text.trim(r.stderr or "")
end
local rc_a, line_a, err_a = cargo_test("A")
if rc_a ~= 0 or line_a == "" then
    arm("5 SHARED the probe crate builds and runs in A", false, rc_a .. " " .. line_a .. " " .. err_a:sub(1, 300))
else
    local rc_b, line_b, err_b = cargo_test("B")
    arm("5 SHARED in B the runtime read follows B's file",
        rc_b == 0 and line_b:find("runtime=from-B", 1, true) ~= nil, rc_b .. " " .. line_b .. " " .. err_b:sub(1, 300))
    arm("5 SHARED control: the compile-time read in B still follows A's file (cargo reused A's binary)",
        line_b:find("compile=from-A", 1, true) ~= nil,
        line_b .. " — if compile=from-B, cargo now rebuilds on a checkout move: re-measure 1590-j20f's premise")
end

if #failed > 0 then
    verdict.emit("violation:manifest-dir-env-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("manifest-dir-env-fixture", "6 arms")
