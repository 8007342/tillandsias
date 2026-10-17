-- @trace order:1750-a4re
-- @env PATH
--
-- test-forge-plan-bin-staging.lua — how the forge's Bash policy decider is
-- staged when it cannot be built, in a scratch tree with a stub cargo and NO
-- musl toolchain (no musl-gcc, no cargo-zigbuild, the podman arm disabled):
--   1 LOUD      build-forge-plan-bin.sh refuses: exit 6, refused:forge-plan-bin:no-musl-toolchain
--               (an image built without the decider refuses every Bash call)
--   2 SKIP      with TILLANDSIAS_FORGE_PLAN_OPTIONAL=1 it is a NAMED skip: exit 0,
--               skip:forge-plan-bin:no-musl-toolchain, nothing staged
--   3 DECOUPLED build-sidecar.sh still stages the router sidecar when the
--               decider fails, then exits 6 naming the decider (pre-fix: under
--               set -e the decider's failure skipped the sidecar, and every
--               cargo build panicked in tillandsias-headless/build.rs)
--   4 LANES     build.sh is strict (optional=0) for --install, --release and
--               --ci-full, and passes the flag to build-sidecar.sh
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-plan-bin-staging.lua

local NAME = "forge-plan-bin-staging-fixture"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local REL = "target/plan-scratch/forge-plan-bin-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- The scratch tree: the two scripts under test and the inputs they hash.
fs.mkdir(REL .. "/tree/scripts")
fs.mkdir(REL .. "/tree/images/router")
fs.mkdir(REL .. "/tree/images/default/policy-bin")
for _, f in ipairs({ "scripts/build-sidecar.sh", "scripts/build-forge-plan-bin.sh", "rust-toolchain.toml" }) do
    fs.write(REL .. "/tree/" .. f, fs.read(f))
end
for _, c in ipairs({ "tillandsias-router-sidecar", "tillandsias-otp", "tillandsias-control-wire", "tillandsias-plan" }) do
    fs.mkdir(REL .. "/tree/crates/" .. c .. "/src")
    fs.write(REL .. "/tree/crates/" .. c .. "/src/lib.rs", "pub fn x() {}\n")
end
fs.write(REL .. "/tree/Cargo.toml", "[workspace]\n")
fs.write(REL .. "/tree/Cargo.lock", "version = 4\n")
fs.write(REL .. "/tree/VERSION", "0.0.0.1\n")

-- A stub cargo that "builds" the sidecar as a minimal x86-64 ELF (the scripts
-- assert the format with file(1)), and a no-op strip. No rustup, musl-gcc or
-- cargo-zigbuild on this PATH, and the podman arm is disabled below.
fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/cargo", table.concat({
    "#!/bin/bash",
    'for out in "${CARGO_TARGET_DIR}/release/tillandsias-router-sidecar" "${CARGO_TARGET_DIR}/x86_64-unknown-linux-musl/release/tillandsias-router-sidecar"; do',
    '  mkdir -p "$(dirname "$out")"',
    "  printf '\\177ELF\\002\\001\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000\\076\\000\\001\\000\\000\\000stub\\n' > \"$out\"",
    "done",
    "exit 0", "" }, "\n"))
fs.write(REL .. "/bin/strip", "#!/bin/bash\nexit 0\n")
proc.run({ argv = { "chmod", "+x", W .. "/bin/cargo", W .. "/bin/strip" }, timeout_ms = 10000 })

local function run(script, optional)
    local e = { PATH = W .. "/bin:/usr/bin:/bin", HOME = W .. "/home", TILLANDSIAS_FORGE_PLAN_NO_CONTAINER = "1",
        TILLANDSIAS_SIDECAR_TARGET = "x86_64-unknown-linux-musl" }
    if optional then e.TILLANDSIAS_FORGE_PLAN_OPTIONAL = "1" end
    local r = proc.run({ argv = { "bash", W .. "/tree/scripts/" .. script }, cwd = W .. "/tree", env = e, timeout_ms = 60000 })
    return r.code or -1, (r.stdout or "") .. (r.stderr or "")
end

local rc, o = run("build-forge-plan-bin.sh", false)
arm("1 LOUD with no musl toolchain the decider build refuses (exit 6, named)",
    rc == 6 and o:find("refused:forge-plan-bin:no-musl-toolchain", 1, true) ~= nil, rc .. " " .. o)

rc, o = run("build-forge-plan-bin.sh", true)
arm("2 SKIP a compile-only lane gets a named skip (exit 0), and nothing is staged",
    rc == 0 and o:find("skip:forge-plan-bin:no-musl-toolchain", 1, true) ~= nil
    and not fs.exists(REL .. "/tree/images/default/policy-bin/tillandsias-plan"), rc .. " " .. o)

rc, o = run("build-sidecar.sh", false)
arm("3 DECOUPLED the sidecar is staged although the decider failed, and the script still exits 6 naming it",
    rc == 6 and fs.exists(REL .. "/tree/images/router/tillandsias-router-sidecar")
    and o:find("refused:build-sidecar:forge-plan-bin-failed:rc=6", 1, true) ~= nil, rc .. " " .. o)

local b = fs.read("build.sh")
local fn = b:match("\n_stage_router_sidecar%(%) {(.-)\n}") or ""
arm("4 LANES build.sh is strict for --install, --release and --ci-full and passes the flag to build-sidecar.sh",
    fn:find('FLAG_INSTALL', 1, true) ~= nil and fn:find('FLAG_RELEASE', 1, true) ~= nil
    and fn:find('FLAG_CI_FULL', 1, true) ~= nil and fn:find("optional=0", 1, true) ~= nil
    and fn:find('TILLANDSIAS_FORGE_PLAN_OPTIONAL="$optional" bash', 1, true) ~= nil, fn:sub(1, 300))

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
if #failed > 0 then verdict.emit("refused:" .. NAME .. ":" .. #failed .. "-of-4", 1) end
verdict.emit("ok:" .. NAME .. ":4", 0)
