-- @trace order:1473-scdq, spec:ci-release, order:2385-psbb
-- @env PATH HOME
--
-- test-rust-source-pin-added.lua — fixture for scripts/lua/check-rust-source-pin-added.lua
-- (1473-scdq; guard ported 2242-rspn), over scratch repos whose origin/linux-next is the base.
-- Ported from test-rust-source-pin-added.sh (2385-psbb); same eight arms. Each adds one Rust test:
--
--   1  a direct `include_str!` + `src.contains` pin is REFUSED, naming crates/c/src/lib.rs:7
--   2  a pin on a WINDOW cut from that source is refused (the vz.rs shape that kept 1472-3d29 green)
--   3  an ABSENCE assertion (`!src.contains`) is admitted
--   4  a test naming a NEGATIVE CONTROL is admitted
--   5  `// source-pin-ok: <reason>` admits it; an EMPTY marker does not
--   6  `.contains` on a BUILT value is not a pin
--   7  NEGATIVE CONTROL: a pin already in the base is not re-litigated (diff-scoped)
--   8  a bogus 40-hex base is named base-unavailable, not a silent 0 checked (2241-f8jg)
--
-- The child runs with TILLANDSIAS_* stripped (1592-idmu: the gate's frozen
-- TILLANDSIAS_GATE_DIFF_BASE names the gated checkout, not this scratch repo) and
-- TILLANDSIAS_REPO_ROOT pinned to the scratch repo. No build.sh child: gate_inherit n/a.
--
-- GRAMMAR ok:rust-source-pin-added-fixture:<n> arms | violation:rust-source-pin-added-fixture:<n>-failed
--       | refused:rust-source-pin-added-fixture:<reason>

local fixture = require "common.fixture"
local T = fixture.new("rust-source-pin-added-fixture")
local ROOT = fixture.repo_root()
local GUARD_REL = "scripts/lua/check-rust-source-pin-added.lua"
if not fs.exists(GUARD_REL) then T:refuse("guard-missing", ROOT .. "/" .. GUARD_REL) end
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "cargo build --release -p tillandsias-plan") end
local GUARD_SRC = fs.read(GUARD_REL)

local W = T:scratch()
local function body(tests)
    return "pub fn f() -> u8 { 1 }\n#[cfg(test)]\nmod tests {\n" .. (tests or "") .. "}\n"
end
local function git(r, ...)
    return T:must{ "git", "-C", r.abs, "-c", "user.email=f@x", "-c", "user.name=f",
        "-c", "commit.gpgsign=false", ... }
end
-- repo(name, base_tests): crates/c/src/lib.rs with a tests module, committed; origin/linux-next = HEAD.
local function repo(name, base)
    local r = { rel = W.rel .. "/" .. name, abs = W.abs .. "/" .. name }
    fs.mkdir(r.rel .. "/scripts/lua"); fs.mkdir(r.rel .. "/crates/c/src")
    fs.write(r.rel .. "/" .. GUARD_REL, GUARD_SRC)
    fs.write(r.rel .. "/crates/c/src/lib.rs", body(base))
    T:must{ "git", "init", "-q", r.abs }
    git(r, "add", "-A"); git(r, "commit", "-qm", "base")
    git(r, "update-ref", "refs/remotes/origin/linux-next", "HEAD")
    return r
end
local function put(r, tests) fs.write(r.rel .. "/crates/c/src/lib.rs", body(tests)) end
local function run(r, extra)
    local e = { TILLANDSIAS_REPO_ROOT = r.abs }
    for k, v in pairs(extra or {}) do e[k] = v end
    local res = T:run{ PLAN, "script", "run", GUARD_REL, cwd = r.abs, env = e,
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (res.stdout or "") .. (res.stderr or "")
    return res.code, o
end
local function has_line(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end
local function got(rc, o) return "rc=" .. tostring(rc) .. " [" .. o .. "]" end

local PIN = [[
    #[test]
    fn pins_source() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
    }
]]

-- 1
local R = repo("one"); put(R, PIN)
local rc, o = run(R)
T:arm("arm 1: a direct include_str! pin is refused, naming crates/c/src/lib.rs:7",
    rc == 1 and has_line(o, "violation:rust-source-pin-added:1") and text.contains(o, "crates/c/src/lib.rs:7"), got(rc, o))

-- 2
R = repo("two"); put(R, [[
    #[test]
    fn pins_a_window() {
        let source = include_str!("lib.rs");
        let unit = source.split("mod tests").next().expect("window");
        assert!(unit.contains("-> u8"));
    }
]])
rc, o = run(R)
T:arm("arm 2: a pin on a window cut from include_str! source is refused",
    rc == 1 and has_line(o, "violation:rust-source-pin-added:1"), got(rc, o))

-- 3
R = repo("three"); put(R, [[
    #[test]
    fn bans_a_pattern() {
        let src = include_str!("lib.rs");
        assert!(!src.contains("std::thread::sleep"));
    }
]])
rc, o = run(R)
T:arm("arm 3: an absence assertion (!src.contains) is admitted", rc == 0, got(rc, o))

-- 4
R = repo("four"); put(R, [[
    /// NEGATIVE CONTROL: the mutated text below must FAIL this check.
    #[test]
    fn pins_with_control() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
        assert!(!"pub fn g()".contains("pub fn f() -> u8"));
    }
]])
rc, o = run(R)
T:arm("arm 4: a pin in a test that names a negative control is admitted", rc == 0, got(rc, o))

-- 5
R = repo("five"); put(R, [[
    #[test]
    fn pins_a_contract() {
        let src = include_str!("lib.rs");
        // source-pin-ok: the public signature text IS the documented contract
        assert!(src.contains("pub fn f() -> u8"));
    }
]])
local rc_reason = run(R)
put(R, [[
    #[test]
    fn pins_a_contract() {
        let src = include_str!("lib.rs");
        // source-pin-ok:
        assert!(src.contains("pub fn f() -> u8"));
    }
]])
local rc_empty = run(R)
T:arm("arm 5: source-pin-ok with a reason admits; an empty marker does not",
    rc_reason == 0 and rc_empty == 1, "reason rc=" .. tostring(rc_reason) .. ", empty rc=" .. tostring(rc_empty))

-- 6
R = repo("six"); put(R, [[
    #[test]
    fn checks_a_built_value() {
        let rendered = format!("{} units", super::f());
        assert!(rendered.contains("1 units"));
    }
]])
rc, o = run(R)
T:arm("arm 6: .contains on a BUILT value is not a source pin", rc == 0, got(rc, o))

-- 7 NEGATIVE CONTROL
local OLD = [[
    #[test]
    fn old_pin() {
        let src = include_str!("lib.rs");
        assert!(src.contains("pub fn f() -> u8"));
    }
]]
R = repo("seven", OLD); put(R, OLD .. [[
    #[test]
    fn unrelated() { assert_eq!(super::f(), 1); }
]])
rc, o = run(R)
T:arm("arm 7: a pin already in the base is not re-litigated (diff-scoped)", rc == 0, got(rc, o))

-- 8 (2241-f8jg)
R = repo("eight"); put(R, PIN)
rc, o = run(R, { TILLANDSIAS_RUST_PIN_BASE = "0123456789abcdef0123456789abcdef01234567" })
T:arm("arm 8: a bogus 40-hex base is named base-unavailable, not a silent 0 checked",
    rc == 0 and has_line(o, "ok:rust-source-pin-added:base-unavailable"), got(rc, o))

T:finish()
