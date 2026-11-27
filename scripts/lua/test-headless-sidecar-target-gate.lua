-- @env PATH HOME CARGO_TARGET_DIR CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN
-- @trace order:1269-6fcn, order:2354-5biy
-- inputs: .github/workflows/release.yml crates/tillandsias-embed/build.rs crates/tillandsias-embed/src/collect.rs
--
-- test-headless-sidecar-target-gate.lua — the router sidecar (a LINUX musl container artifact)
-- is required only when building tillandsias-headless for a Linux TARGET. v56.9.19.1's Windows
-- release job died in build.rs because the Windows host build refused without it.
-- Ported from scripts/test-headless-sidecar-target-gate.sh (2354-5biy, the shell-to-lua item
-- that change carried).
--
-- HERMETIC WITH RESPECT TO THIS CHECKOUT: the sidecar is untracked, so a fresh detached
-- worktree in scratch lacks it exactly as a fresh runner does. Nothing in this checkout is
-- moved or deleted; the scratch worktree is removed before the verdict.
--
--   1 WINDOWS  x86_64-pc-windows-gnu `cargo check` with the sidecar ABSENT succeeds
--              (pre-fix: rc=101, "required runtime asset missing")
--   2 LINUX    (negative control) the host Linux target with the sidecar ABSENT still REFUSES
--              with the named remedy, so the container lane can never get an empty embed
--   3 RELEASE  the Windows job maps runner.arch to the sidecar arch and fails by name when the
--              arch-matched asset is absent
-- Arms 1 and 2 are NAMED skips, never passes, where the toolchain cannot judge them.
--
-- Usage: tillandsias-plan script run scripts/lua/test-headless-sidecar-target-gate.lua
-- Verdict: ok:headless-sidecar-target-gate:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("headless-sidecar-target-gate")
local ROOT = fixture.repo_root()

-- ── ARM 3 first: it needs no toolchain ──────────────────────────────────────
local wf = fs.read(".github/workflows/release.yml") or ""
T:arm("3 the Windows job selects the sidecar by runner.arch and fails by name when it is absent",
    text.contains(wf, "X64) sidecar_arch=x86_64") and text.contains(wf, "ARM64) sidecar_arch=aarch64")
        and text.contains(wf, "release has no tillandsias-router-sidecar"),
    "release.yml does not map runner.arch to the sidecar arch with a named failure")

local function skip(msg) out.line("skip: " .. msg .. " (named skip, not a pass)") end

local CARGO = fixture.which("cargo")
if not CARGO then
    skip("1, 2 no cargo on PATH")
    T:finish()
end

-- The child sees only what cargo and rustup need; CARGO_TARGET_DIR is the caller's (a shared
-- target keeps the check incremental), else this checkout's target/.
local function getenv(k)
    local v = env.get(k)
    if v and v ~= "" then return v end
    return nil
end
local cenv = { PATH = getenv("PATH"), HOME = getenv("HOME"), CARGO_HOME = getenv("CARGO_HOME"),
    RUSTUP_HOME = getenv("RUSTUP_HOME"), RUSTUP_TOOLCHAIN = getenv("RUSTUP_TOOLCHAIN"),
    CARGO_TARGET_DIR = getenv("CARGO_TARGET_DIR") or (ROOT .. "/target") }

local sc = T:scratch("wt")
local wt = sc.abs .. "/wt"
local wtrel = sc.rel .. "/wt"
local function remove_worktree()
    proc.run{ argv = { "git", "-C", ROOT, "worktree", "remove", "--force", wt }, timeout_ms = 60000 }
end
local function finish() remove_worktree(); T:finish() end

local add = T:run{ "git", "-C", ROOT, "worktree", "add", "-q", "--detach", wt, "HEAD" }
if add.code ~= 0 then T:refuse("setup-failed", "could not create a scratch worktree: " .. tostring(add.stderr)) end
-- Carry this tree's uncommitted build.rs and collect.rs, so the fixture tests what is on disk.
for _, p in ipairs{ "crates/tillandsias-embed/build.rs", "crates/tillandsias-embed/src/collect.rs" } do
    fs.write(wtrel .. "/" .. p, fs.read(p))
end
if fs.exists(wtrel .. "/images/router/tillandsias-router-sidecar") then
    remove_worktree()
    T:refuse("setup-failed", "scratch worktree unexpectedly has a sidecar")
end

local function check(...)
    local argv = { CARGO, "check", "-q", "-p", "tillandsias-headless", "--bin", "tillandsias", ... }
    -- No env_unset: the gate's runner does not take it; CARGO_TARGET_DIR is set in env, which wins.
    local r = proc.run{ argv = argv, cwd = wt, env = cenv,
        timeout_ms = 1800000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function first(o, pat)
    for l in (o .. "\n"):gmatch("([^\n]*)\n") do if l:match(pat) then return l end end
    return ""
end

-- ── ARM 1 ────────────────────────────────────────────────────────────────
-- "Target installed" is not "target buildable" (yolanda 2026-09-29): ring's build script
-- compiles C, so a host with the rustup target but no MinGW C compiler fails in ring, which says
-- nothing about this build.rs. Judge ONLY on the sidecar panic; any other failure is a named
-- toolchain skip, never a pass and never this gate's failure.
local rustup = fixture.which("rustup")
local targets = ""
if rustup then
    targets = proc.run{ argv = { rustup, "target", "list", "--installed" }, env = cenv, timeout_ms = 60000 }.stdout or ""
end
if not text.contains("\n" .. targets, "\nx86_64-pc-windows-gnu\n") then
    skip("1 target x86_64-pc-windows-gnu not installed")
elseif not fixture.which("x86_64-w64-mingw32-gcc") then
    skip("1 no x86_64-w64-mingw32-gcc: C dependencies (ring) cannot build for the target here")
else
    local rc, o = check("--target", "x86_64-pc-windows-gnu")
    if rc == 0 then
        T:arm("1 a Windows-target check succeeds with the sidecar absent", true)
    elseif text.contains(o, "required runtime asset missing") then
        T:arm("1 a Windows-target check succeeds with the sidecar absent", false,
            "refused for want of the Linux-only sidecar: " .. first(o, "required runtime asset missing"))
    else
        skip("1 the target toolchain failed before build.rs could be judged: " .. first(o, "^error"))
    end
end

-- ── ARM 2 ────────────────────────────────────────────────────────────────
-- The negative control needs a LINUX host target: on a Windows or macOS host the host build is
-- itself non-Linux and correctly does not refuse.
local rustc = fixture.which("rustc")
local host = ""
if rustc then
    local v = proc.run{ argv = { rustc, "-vV" }, env = cenv, timeout_ms = 60000 }.stdout or ""
    host = (("\n" .. v):match("\nhost: ([^\n]*)")) or ""
end
if text.contains(host, "-linux-") then
    local rc, o = check()
    T:arm("2 negative control: a Linux-target build still refuses without the sidecar, naming the remedy",
        rc ~= 0 and text.contains(o, "required runtime asset missing") and text.contains(o, "BUILD ARTIFACT"),
        "rc=" .. tostring(rc) .. " did not refuse by name")
else
    skip("2 host target is " .. (host ~= "" and host or "unknown") .. ", not Linux: the Linux refusal cannot be exercised here")
end

finish()
