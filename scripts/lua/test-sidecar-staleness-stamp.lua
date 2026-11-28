-- @trace spec:opencode-web-session-otp, spec:methodology-accountability, order:765-5efu, order:2380-psba
-- @env PATH HOME
--
-- test-sidecar-staleness-stamp.lua — hermetic fixture for build-sidecar.sh's
-- content-addressed staleness stamp. Ported from test-sidecar-staleness-stamp.sh
-- (2380-psba); same eleven scenarios, plus the four stamp/stage checks the .sh made
-- under scenario 1 without an ok line (here 1a-1d).
--
-- A STUB cargo, not a real build: the subject is the staleness DECISION (does the script
-- invoke a build at all), not the compiler. The stub appends to a counter file and writes
-- an arch-correct minimal ELF (723-ji4v refuses arch-less artifacts) at every candidate
-- output path, so the fixture does not depend on whether the musl target is installed.
-- NON-VACUITY: build-expected scenarios assert the counter INCREMENTS, so a stamp that
-- skipped everything fails them, and a script that never read the stamp fails the skips.
-- The subject runs with TILLANDSIAS_* and CARGO_TARGET_DIR stripped: a gate's exported
-- CARGO_TARGET_DIR would point the stub's writes at the shared target dir.
--
--   1  cold build with nothing staged (1a staged a binary, 1b wrote the stamp,
--      1c stamp carries inputs=, 1d stamp carries output=)
--   2  unchanged inputs skip the build
--   3  mtime churn on identical content skips the build (the packet's case)
--   4  a real source change rebuilds
--   5  a VERSION bump rebuilds
--   6  a new source file rebuilds
--   7  a tampered staged artifact is rebuilt, not trusted
--   8  a missing stamp rebuilds
--   9  an unreadable stamp rebuilds
--  10  TILLANDSIAS_SIDECAR_FORCE_REBUILD=1 bypasses the stamp
--  11  the run after a forced rebuild skips again
--
-- GRAMMAR ok:sidecar-staleness-stamp:<n> arms | violation:sidecar-staleness-stamp:<n>-failed
--       | refused:sidecar-staleness-stamp:setup-failed

local fixture = require "common.fixture"
local T = fixture.new("sidecar-staleness-stamp")
local SH = fixture.posix_shell()
local SB = T:scratch()
local R = { rel = SB.rel .. "/repo", abs = SB.abs .. "/repo" }
for _, d in ipairs({ "/crates/tillandsias-router-sidecar/src", "/crates/tillandsias-otp/src",
    "/crates/tillandsias-control-wire/src", "/images/router", "/scripts" }) do fs.mkdir(R.rel .. d) end
fs.mkdir(SB.rel .. "/bin")
local function put(rel, body) fs.write(R.rel .. "/" .. rel, body) end
put("crates/tillandsias-router-sidecar/src/main.rs", "fn main() {}\n")
-- build-sidecar.sh refuses a tree without the crate manifest (2118-ywk7)
put("crates/tillandsias-router-sidecar/Cargo.toml", '[package]\nname = "tillandsias-router-sidecar"\nversion = "0.0.0"\n')
put("crates/tillandsias-otp/src/lib.rs", "pub fn otp() {}\n")
put("crates/tillandsias-control-wire/src/lib.rs", "pub fn wire() {}\n")
put("Cargo.toml", "[workspace]\n")
put("Cargo.lock", "version = 4\n")
put("VERSION", "0.4.260817.1\n")
put("scripts/build-sidecar.sh", fs.read("scripts/build-sidecar.sh"))
local COUNTER = SB.abs .. "/cargo-invocations"
fs.write(SB.rel .. "/cargo-invocations", "")
fs.write(SB.rel .. "/bin/cargo", [=[#!/usr/bin/env bash
echo "build" >> "$CARGO_INVOCATION_COUNTER"
payload="${STUB_CARGO_PAYLOAD:-default}"
case "$(uname -m)" in
    arm64|aarch64) _em='\267' ;;
    *)             _em='\076' ;;
esac
for out in \
    "${CARGO_TARGET_DIR}/release/tillandsias-router-sidecar" \
    "${CARGO_TARGET_DIR}/x86_64-unknown-linux-musl/release/tillandsias-router-sidecar" \
    "${CARGO_TARGET_DIR}/aarch64-unknown-linux-musl/release/tillandsias-router-sidecar"; do
    mkdir -p "$(dirname "$out")"
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000'"$_em"'\000\001\000\000\000stub-sidecar-%s\n' "$payload" > "$out"
done
exit 0
]=])
fs.write(SB.rel .. "/bin/strip", "#!/usr/bin/env bash\nexit 0\n")
-- fs.write drops the exec bit
T:must{ "chmod", "+x", SB.abs .. "/bin/cargo", SB.abs .. "/bin/strip", R.abs .. "/scripts/build-sidecar.sh" }

local PATH = SB.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin")
local function builds() return text.count_lines(fs.read(SB.rel .. "/cargo-invocations"), "^") end
local function run_sidecar(extra)
    local e = { PATH = PATH, CARGO_INVOCATION_COUNTER = COUNTER }
    for k, v in pairs(extra or {}) do e[k] = v end
    T:run{ SH, R.abs .. "/scripts/build-sidecar.sh", cwd = R.abs, env = e,
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, timeout_ms = 120000 }
end
local function expect_build(label, before)
    local after = builds()
    T:arm(label, after > before, "expected a build, counter stayed at " .. after)
end
local function expect_skip(label, before)
    local after = builds()
    T:arm(label, after == before, "expected NO build, counter went " .. before .. " -> " .. after)
end
local STAMP = R.rel .. "/images/router/.sidecar.stamp"
local DEST = R.abs .. "/images/router/tillandsias-router-sidecar"

-- 1. Cold: nothing staged -> must build, and must leave a stamp.
local b = builds(); run_sidecar(); expect_build("1 cold build with nothing staged", b)
T:arm("1a cold build staged a binary", fs.exists(R.rel .. "/images/router/tillandsias-router-sidecar"), "no " .. DEST)
local st = fs.exists(STAMP) and fs.read(STAMP) or nil
T:arm("1b cold build wrote the evaluation stamp", st ~= nil, "no stamp")
T:arm("1c stamp carries an inputs= digest", st ~= nil and text.is_match(st, "(?m)^inputs="), st)
T:arm("1d stamp carries an output= digest", st ~= nil and text.is_match(st, "(?m)^output="), st)

-- 2. Unchanged inputs -> skip.
b = builds(); run_sidecar(); expect_skip("2 unchanged inputs skip the build", b)

-- 3. THE PACKET'S CASE: a git merge/checkout rewrites mtimes on byte-identical files;
--    the old `find -newer` probe rebuilt for that alone.
T:must{ "touch", R.abs .. "/crates/tillandsias-router-sidecar/src/main.rs", R.abs .. "/Cargo.lock",
    R.abs .. "/Cargo.toml", R.abs .. "/VERSION", R.abs .. "/crates/tillandsias-otp/src/lib.rs" }
b = builds(); run_sidecar(); expect_skip("3 mtime churn on identical content skips the build", b)

-- 4. NEGATIVE: a real content change must rebuild.
put("crates/tillandsias-router-sidecar/src/main.rs", "fn main() { /* changed */ }\n")
b = builds(); run_sidecar(); expect_build("4 a real source change rebuilds", b)

-- 5. NEGATIVE: VERSION content change must rebuild (710-w9kc version-matching).
put("VERSION", "0.4.260817.2\n")
b = builds(); run_sidecar(); expect_build("5 a VERSION bump rebuilds", b)

-- 6. NEGATIVE: a file ADDED to the input set must rebuild (the manifest covers paths).
put("crates/tillandsias-otp/src/extra.rs", "pub fn extra() {}\n")
b = builds(); run_sidecar(); expect_build("6 a new source file rebuilds", b)

-- 7. A tampered staged artifact must not be trusted: mtime says nothing about WHICH bytes
--    are staged (723-b9cn). Appended by a shell so the artifact's mode is kept.
T:must{ SH, "-s", "--", DEST, stdin = 'printf TAMPERED >> "$1"\n' }
b = builds(); run_sidecar(); expect_build("7 a tampered staged artifact is rebuilt, not trusted", b)

-- 8. A missing stamp must rebuild (fresh checkout / CI / release lane).
T:must{ "rm", "-f", SB.abs .. "/repo/images/router/.sidecar.stamp" }
b = builds(); run_sidecar(); expect_build("8 a missing stamp rebuilds", b)

-- 9. A truncated/garbage stamp must rebuild, never be half-trusted.
fs.write(STAMP, "inputs=\n")
b = builds(); run_sidecar(); expect_build("9 an unreadable stamp rebuilds", b)

-- 10. The operator override forces a rebuild even when everything matches.
b = builds(); run_sidecar({ TILLANDSIAS_SIDECAR_FORCE_REBUILD = "1" })
expect_build("10 TILLANDSIAS_SIDECAR_FORCE_REBUILD=1 bypasses the stamp", b)

-- 11. ...and unset again, the next run skips: 10 forced the build, the tree was not dirty.
b = builds(); run_sidecar(); expect_skip("11 the run after a forced rebuild skips again", b)

T:finish()
