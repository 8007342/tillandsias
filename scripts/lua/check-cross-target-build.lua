-- @env TILLANDSIAS_CROSS_TARGET CARGO_TARGET_DIR
-- @trace spec:ci-release, order:656-spux, order:958-w4kq
--
-- check-cross-target-build.lua — PORTED from check-cross-target-build.sh
-- (656-spux), verdict lines kept, with two changes order 958-w4kq makes.
--
-- THE GAP 656-spux CLOSED. Every host compiles for ITSELF and nothing else,
-- so platform-gated code is verified by exactly the platform that cannot
-- exercise the other arms. Its first run against x86_64-pc-windows-gnu found
-- a `#[cfg(unix)]` definition with three unguarded callers sitting on trunk.
--
-- WHAT 958-w4kq CHANGES, AND WHY.
--   (1) `cargo clippy --all-targets -- -D warnings`, not `cargo check`. The
--       gate's clippy runs for the gate host's own target, so a LINT in a
--       cfg(windows) file was invisible to every Linux gate: native-Windows
--       clippy was red on windows-next while `./build.sh --check` was green
--       (yolanda 2026-09-02, e399c888a). A check that only type-checks saw
--       none of it, and without --all-targets it saw no test code either.
--       Measured when this landed: the Windows-target clippy found three
--       errors no gate had seen (a unix-only API in a vm-layer test, and two
--       items dead on every non-unix/non-linux target).
--   (2) the std for the target FOLLOWS THE PIN. rust-toolchain.toml pins the
--       channel (1562-tc7p), and a `rustup target add` run anywhere but this
--       checkout lands on the DEFAULT toolchain, so every gate since the pin
--       printed skip:cross-target:target-not-installed (yolanda's gate logs:
--       3 of 3) and nothing refused. The C cross-toolchain is the opt-in: a
--       host that has it gets the target added for the pinned toolchain here,
--       as rustup itself installs the pinned toolchain on first use.
--
-- VERDICT GRAMMAR, one line on stdout. The .sh printed fail:cross-target on
-- the red path; the runner accepts only ok:/skip:/refused:/blocked:/
-- could-not-run:/violation:, so that one line is refused: now. build.sh
-- branches on the exit code alone, which is unchanged (1).
--   ok:cross-target:<target>      the workspace lints clean for <target>
--   refused:cross-target:<target> it does not — exit 1 (errors on stderr)
--   skip:cross-target:<reason>    this host cannot run it — exit 0
--
-- SKIPPING IS NOT FAILING, as in the .sh: a host without the C cross-toolchain
-- (ring's build script wants x86_64-w64-mingw32-gcc) says so and exits 0.
-- The Windows builder distro and the Linux builder toolbox both provision it
-- (scripts/with-wsl2-builder.sh, scripts/with-tillandsias-builder.sh). Enable
-- elsewhere with `sudo dnf install -y mingw64-gcc mingw64-binutils`.
--
-- COST, measured on yolanda's builder distro: the first run compiles every
-- dependency for the target (~2 min); a warm run with one changed crate ~19 s.

local TARGET = env.get("TILLANDSIAS_CROSS_TARGET") or "x86_64-pc-windows-gnu"

-- The C cross-compiler each target needs for native build scripts.
local CC_TOOLS = {
    ["x86_64-pc-windows-gnu"] = "x86_64-w64-mingw32-gcc",
    ["aarch64-pc-windows-gnu"] = "aarch64-w64-mingw32-gcc",
}
local CC_TOOL = CC_TOOLS[TARGET]

local cargo = proc.run({ argv = { "cargo", "--version" } })
if cargo.status ~= "exited" or cargo.code ~= 0 then
    verdict.emit("skip:cross-target:no-cargo", 0)
end

if CC_TOOL ~= nil then
    local cc = proc.run({ argv = { CC_TOOL, "--version" } })
    if cc.status ~= "exited" or cc.code ~= 0 then
        -- Named explicitly: the fix is one dnf install, and a reader told WHICH
        -- binary is absent need not reproduce the ring failure to find out.
        verdict.emit("skip:cross-target:no-c-toolchain:" .. CC_TOOL, 0)
    end
end

local function target_installed()
    local r = proc.run({ argv = { "rustup", "target", "list", "--installed" } })
    if r.status ~= "exited" or r.code ~= 0 then return false end
    for _, l in ipairs(text.lines(r.stdout)) do
        if text.trim(l) == TARGET then return true end
    end
    return false
end

if not target_installed() then
    -- Run from the checkout, so rustup resolves the PINNED toolchain.
    proc.run({ argv = { "rustup", "target", "add", TARGET }, timeout_ms = 600000 })
    if not target_installed() then
        verdict.emit("skip:cross-target:target-not-installed:" .. TARGET, 0)
    end
end

-- THE GATE'S TARGET DIR, PASSED EXPLICITLY. proc.run children start from a
-- scrubbed environment (1551-nyzb: PATH, HOME, TILLANDSIAS_* and a fixed few),
-- so CARGO_TARGET_DIR never reaches cargo. Measured on yolanda before this
-- line: the cross build went into the CHECKOUT's target/ (1.4 GB over 9p on a
-- Windows host) instead of the distro-native dir the gate exports, a second
-- dependency tree on every host. --target-dir keeps it beside the gate's own.
local argv = { "cargo", "clippy", "--workspace", "--all-targets", "--target", TARGET }
local target_dir = env.get("CARGO_TARGET_DIR")
if target_dir ~= nil and target_dir ~= "" then
    argv[#argv + 1] = "--target-dir"
    argv[#argv + 1] = target_dir
end
for _, a in ipairs({ "--", "-D", "warnings" }) do argv[#argv + 1] = a end

local r = proc.run({ argv = argv, timeout_ms = 1800000 })
if r.status == "exited" and r.code == 0 then
    verdict.emit("ok:cross-target:" .. TARGET, 0)
end

-- Only the errors: a full cargo log buries the lines that matter.
local shown = 0
for _, l in ipairs(text.lines((r.stderr or "") .. "\n" .. (r.stdout or ""))) do
    if shown < 40 and (text.is_match(l, "^error|^  --> |configured out|could not compile")) then
        log.raw(l)
        shown = shown + 1
    end
end
if r.status ~= "exited" then
    log.raw("cargo clippy did not finish: " .. tostring(r.status))
end
verdict.emit("refused:cross-target:" .. TARGET, 1)
