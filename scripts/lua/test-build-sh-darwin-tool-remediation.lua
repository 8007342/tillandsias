-- @env PATH
-- @trace order:851-gpb5, order:2105-mlua, spec:dev-build
--
-- test-build-sh-darwin-tool-remediation.lua — _require_host_build_tools gives
-- per-OS remediation (order 851-gpb5). Ported from
-- scripts/test-build-sh-darwin-tool-remediation.sh (2105-mlua), same 14 checks.
--
-- WHAT WAS BROKEN. The function requires pkg-config (among others) and, on any
-- failure, told EVERY host to "Install the Fedora build dependencies": the
-- first macOS host's very first `./build.sh --check` ended in remediation
-- advice for a distribution it does not run.
--
-- HOW THIS TESTS IT. The function is cut from build.sh by name (a copy would
-- drift) and run against a shim PATH holding every required tool EXCEPT
-- pkg-config, with a shim `uname` whose output the scenario controls, so the
-- Darwin branch runs on every host in the fleet.
--
-- MUTATION CONTROL. A mutant with the Darwin test neutered must turn exactly
-- the Darwin scenario red (Fedora advice on a Mac) while Linux stays green.
-- The mutation is verified to have changed bytes; a substitution that matched
-- nothing removes nothing and certifies everything.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-build-sh-darwin-tool-remediation.lua
-- GRAMMAR (last line on stdout)
--   ok:build-sh-darwin-tool-remediation-fixture:14   exit 0
--   refused:build-sh-darwin-tool-remediation-fixture exit 1

local NAME = "build-sh-darwin-tool-remediation-fixture"
local fail = false
local function check(name, cond)
    if cond then out.line("PASS  " .. name) else out.line("FAIL  " .. name); fail = true end
end

if not fs.exists("build.sh") then verdict.refused(NAME, "no build.sh") end
local build = fs.read("build.sh")

local bash_bin = text.trim(proc.run{ argv = { "which", "bash" } }.stdout or "")
if bash_bin == "" then verdict.could_not_run(NAME, "no bash on PATH") end

check("build-sh-parses", proc.run{ argv = { bash_bin, "-n", "build.sh" }, timeout_ms = 60000 }.code == 0)

-- The function under test, from the real bytes: `_require_host_build_tools() {` to the first `}` line.
local buf, inside = {}, false
for _, l in ipairs(text.lines(build)) do
    if not inside and l == "_require_host_build_tools() {" then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
local fn = table.concat(buf, "\n") .. "\n"
check("function-extracted", text.contains(fn, "_require_host_build_tools"))

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/darwin-tool-remediation-" .. tostring(time.now_ms())
local ABS = root .. "/" .. REL
fs.mkdir(REL .. "/shims")
for _, t in ipairs({ "cargo", "rustc", "rustfmt", "clippy-driver", "gcc" }) do
    fs.write(REL .. "/shims/" .. t, "#!/bin/sh\nexit 0\n")
end
fs.write(REL .. "/shims/uname", '#!/bin/sh\necho "${UNAME_FLAVOR:-Linux}"\n')
proc.run{ argv = { "chmod", "+x", ABS .. "/shims/cargo", ABS .. "/shims/rustc", ABS .. "/shims/rustfmt",
    ABS .. "/shims/clippy-driver", ABS .. "/shims/gcc", ABS .. "/shims/uname" } }

local mutant = fn:gsub('"%$%(uname %-s%)" == "Darwin"', '"NEVER" == "Darwin"')
fs.write(REL .. "/fn.sh", fn)
fs.write(REL .. "/fn-mutant.sh", mutant)

-- The driver is a FILE, not an inline -c script: stub _error, source the cut, call it.
fs.write(REL .. "/drive.sh", table.concat({
    '_error() { printf "%s\\n" "$*"; }',
    "FLAG_INSTALL=false",
    '. "$1"',
    "_require_host_build_tools",
}, "\n") .. "\n")

local function run_fn(flavor, file)
    local r = proc.run{ argv = { bash_bin, ABS .. "/drive.sh", ABS .. "/" .. file }, timeout_ms = 60000,
        env = { PATH = ABS .. "/shims", UNAME_FLAVOR = flavor } }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end

-- Darwin: macOS remediation, not Fedora.
local o, rc = run_fn("Darwin", "fn.sh")
check("darwin-missing-tool-still-refuses", rc ~= 0)
check("darwin-names-the-missing-tool", text.contains(o, "Missing host build tools: pkg-config"))
check("darwin-remediation-names-xcode-clt", text.contains(o, "xcode-select --install"))
check("darwin-remediation-names-homebrew", text.contains(o, "brew install pkg-config"))
check("darwin-remediation-is-not-fedora", not text.contains(o, "Fedora"))

-- Linux (NEGATIVE CONTROL): Fedora advice survives, no macOS advice.
o, rc = run_fn("Linux", "fn.sh")
check("linux-missing-tool-still-refuses", rc ~= 0)
check("linux-remediation-still-fedora", text.contains(o, "Fedora build dependencies"))
check("linux-remediation-is-not-macos", not text.contains(o, "xcode-select"))

-- MUTATION CONTROL.
if mutant == fn then
    out.line("FAIL  mutation-applied: the substitution changed nothing; the control proves nothing")
    fail = true
else
    out.line("PASS  mutation-applied")
end
o = run_fn("Darwin", "fn-mutant.sh")
check("mutation-control-neutered-branch-gives-fedora-on-darwin", text.contains(o, "Fedora"))
o = run_fn("Linux", "fn-mutant.sh")
check("mutation-control-linux-path-unchanged", text.contains(o, "Fedora build dependencies"))

-- Docs pin (851-gpb5 defect 4): the meta-orchestration skill names the macOS build path.
local SKILL = "skills/meta-orchestration/SKILL.md"
if fs.exists(SKILL) then
    check("skill-names-the-macos-build-path", text.contains(fs.read(SKILL), "scripts/build-macos-tray.sh"))
else
    out.line("PASS  skill-pin-skipped (no " .. SKILL .. " here)")
end

proc.run{ argv = { "rm", "-rf", "--", ABS } }
if fail then verdict.refused(NAME, "a check failed (FAIL lines above)") end
verdict.ok(NAME, "14")
