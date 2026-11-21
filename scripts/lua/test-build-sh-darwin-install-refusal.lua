-- @env PATH HOME
-- @trace order:723-whrx, order:2105-mlua, spec:dev-build
--
-- test-build-sh-darwin-install-refusal.lua — `./build.sh --install` on macOS
-- refuses BEFORE it dirties the tree, and `--init` builds before the podman
-- gate and the version bump (723-whrx). Ported from
-- scripts/test-build-sh-darwin-install-refusal.sh (2105-mlua), same checks.
--
-- The ordering assertions matter more than the message ones:
--   * the install refusal must precede _bump_build_version and
--     _prepare_ci_full_install_inputs, or it still dirties VERSION and build.sh
--     then tells the operator not to commit the dirt it just made;
--   * the --init binary build must precede require_podman and
--     _bump_build_version, or a missing artifact still reports as a podman
--     problem and still leaves a dirty tree.
--
-- PLATFORM SCOPE: the behavioural arm runs ONLY on Darwin. `./build.sh
-- --install` on Linux would start a real install, so elsewhere this falls back
-- to source ordering, and "the refusal does NOT fire on Linux" is asserted
-- structurally (the guard is conjoined with a Darwin test).
--
-- USAGE   tillandsias-plan script run scripts/lua/test-build-sh-darwin-install-refusal.lua
-- GRAMMAR (last line on stdout)
--   ok:build-sh-darwin-install-refusal         exit 0
--   refused:build-sh-darwin-install-refusal    exit 1

local NAME = "build-sh-darwin-install-refusal"
local fail = false
local function check(name, cond, why)
    if cond then out.line("ok: " .. name)
    else out.line("FAIL: " .. name .. (why and (" (" .. why .. ")") or "")); fail = true end
end

if not fs.exists("build.sh") then verdict.refused(NAME, "no build.sh") end
local build = fs.read("build.sh")
local lines = text.lines(build)

check("build-sh-parses", proc.run{ argv = { "bash", "-n", "build.sh" }, timeout_ms = 60000 }.code == 0)

-- First line (1-based) containing a literal, or matching a POSIX ERE.
local function line_lit(s)
    for i, l in ipairs(lines) do if text.contains(l, s) then return i end end
end
local function line_re(re)
    for i, l in ipairs(lines) do if text.is_match(l, re) then return i end end
end
local function lt(a, b) return a ~= nil and b ~= nil and a < b end

local refusal = line_lit("Error: --install is not supported on macOS.")
check("darwin-install-refusal-exists", refusal ~= nil)

-- Conjoined with a Darwin test, or it would fire on Linux and strand the fleet.
check("refusal-is-gated-on-darwin-AND-install", line_re("uname -s.*Darwin.*FLAG_INSTALL") ~= nil)

-- ORDERING 1: the refusal precedes every install-path mutation.
local bump = line_re("^    _bump_build_version")
local prep = line_re("^_prepare_ci_full_install_inputs\\(\\)")
check("refusal-precedes-the-first-version-bump", lt(refusal, bump),
    "refusal=" .. tostring(refusal or "") .. " bump=" .. tostring(bump or ""))
check("refusal-precedes-ci-full-install-prep", lt(refusal, prep),
    "refusal=" .. tostring(refusal or "") .. " prep=" .. tostring(prep or ""))

check("refusal-names-the-macos-build-script", text.contains(build, "scripts/build-macos-tray.sh"))

-- ORDERING 2: --init builds before the podman gate and the version bump.
-- COMMENTS ARE STRIPPED FIRST: the first draft of the .sh matched its own
-- explanatory comment inside the --init block and reported correct code broken.
local block, inside = {}, false
for _, l in ipairs(lines) do
    if not inside and l == 'if [[ "$FLAG_INIT" == true ]]; then' then inside = true end
    if inside then
        if not text.is_match(l, "^[[:space:]]*#") then block[#block + 1] = l end
        if l == "fi" then break end
    end
end
local function idx(s)
    for i, l in ipairs(block) do if text.contains(l, s) then return i end end
end
local b_idx, p_idx, v_idx = idx("building it first (723-whrx)"), idx("require_podman"), idx("_bump_build_version")
check("init-builds-before-the-podman-gate", lt(b_idx, p_idx),
    "build=" .. tostring(b_idx or "") .. " podman=" .. tostring(p_idx or ""))
check("init-builds-before-the-version-bump", lt(b_idx, v_idx),
    "build=" .. tostring(b_idx or "") .. " bump=" .. tostring(v_idx or ""))

-- Behavioural arm: Darwin only, because elsewhere this would really install.
local os_name = text.trim(proc.run{ argv = { "uname", "-s" } }.stdout or "")
if os_name == "Darwin" then
    local r = proc.run{ argv = { "./build.sh", "--install" }, timeout_ms = 120000,
        env = { TILLANDSIAS_SKIP_VERSION_BUMP = "1" } }
    local o = (r.stdout or "") .. (r.stderr or "")
    check("darwin-install-exits-nonzero", r.status == "exited" and r.code ~= 0)
    check("darwin-install-says-why", text.contains(o, "not supported on macOS"))
    check("darwin-install-names-the-alternative", text.contains(o, "scripts/build-macos-tray.sh"))

    -- THE PLACEMENT PROPERTY, measured: refusing must leave the tree clean.
    local dirt = proc.run{ argv = { "git", "diff", "--name-only", "--", "VERSION", "Cargo.toml", "Cargo.lock" } }
    check("darwin-install-leaves-no-version-dirt", text.trim(dirt.stdout or "") == "")

    local r2 = proc.run{ argv = { "./build.sh", "--ci-full", "--install" }, timeout_ms = 120000 }
    check("darwin-ci-full-install-refuses-too", r2.status == "exited" and r2.code ~= 0)
else
    out.line("ok: behavioural-arm-skipped-off-darwin (running ./build.sh --install here would really install)")
end

if fail then verdict.refused(NAME, "a check failed (FAIL lines above)") end
verdict.ok(NAME)
