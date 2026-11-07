-- @env PATH
-- @trace order:2027-e2cf, spec:default-image
--
-- test-forge-opencode-is-pinned.lua — the forge installs a PINNED opencode-ai,
-- replaces a cached copy at any other version, and says so when a harness is
-- installed at an unpinned @latest.
--
-- WHY (2027-e2cf). Cold Linux lanes died on their model request with
-- "EPROTO: The TLS handshake failed" in 5 of 6 runs since 2026-10-31. Nothing in
-- the proxy or forge network path changed between v56.10.30.1 and v56.10.31.1;
-- the forge installed `opencode-ai@latest`, and npm published 1.19.5 on
-- 2026-10-28T06:17Z, so the agent's client changed under every lane with no
-- commit. Whatever the A/B concludes, a client that moves with no commit cannot
-- be bisected; the pin makes the version a one-line, reviewable change.
--
-- Runs the REAL _require_harness (cut from images/default/lib-common.sh) with a
-- stub npm on PATH that records its argv and installs a stub binary reporting
-- the version it was asked for:
--   1 FRESH     no cached opencode: npm installs opencode-ai@<pin>   (pre-fix: @latest)
--   2 DRIFT     a cached opencode at another version is reinstalled at the pin
--   3 KEEP      a cached opencode AT the pin is kept: npm is not called
--   4 UNPINNED  a harness with no pin still installs @latest, and the trace
--               names it as unpinned (reported, not silent)
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-opencode-is-pinned.lua
-- Verdict: ok:forge-opencode-is-pinned:4 arms | violation:forge-opencode-is-pinned:<n>-failed

local NAME = "forge-opencode-is-pinned"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local LIB = ROOT .. "/images/default/lib-common.sh"

local REL = "target/plan-scratch/opencode-pin-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else out.line("FAIL: " .. name .. " — got: " .. tostring(got)); failed[#failed + 1] = name end
end

-- The pin the tree declares. Pre-fix there is no harness_pin, so the expected
-- pin falls back to the one this row chose; arm 1 then fails on @latest.
local lib = fs.read("images/default/lib-common.sh") or ""
local PIN = lib:match('opencode%-ai%)%s*echo%s+"?([0-9]+%.[0-9]+%.[0-9]+)"?') or "1.19.4"

fs.mkdir(REL .. "/bin")
-- stub npm: record argv; `install -g ... <pkg>@<spec>` makes <prefix>/bin/<bin>
-- that prints <spec> for --version.
fs.write(REL .. "/bin/npm", table.concat({
    "#!/usr/bin/env bash",
    'printf "%s\\n" "$*" >> "$NPM_LOG"',
    'spec="${@: -1}"; ver="${spec##*@}"',
    'case "$spec" in opencode-ai@*) b=opencode ;; *) b=fooharness ;; esac',
    'mkdir -p "$NPM_CONFIG_PREFIX/bin"',
    'printf "#!/usr/bin/env bash\\necho %s\\n" "$ver" > "$NPM_CONFIG_PREFIX/bin/$b"',
    'chmod +x "$NPM_CONFIG_PREFIX/bin/$b"',
}, "\n") .. "\n")
-- driver: stub the helpers _require_harness calls, cut the real functions, run it.
fs.write(REL .. "/drive.sh", table.concat({
    "#!/usr/bin/env bash",
    'lib="$1"; shift',
    'trace_lifecycle() { printf "trace:%s:%s\\n" "$1" "$2" >&2; }',
    "_clear_stale_npm_staging() { :; }",
    "harness_record_last_good() { :; }",
    'for f in harness_pin _require_harness; do eval "$(sed -n "/^$f()/,/^}/p" "$lib")"; done',
    '_require_harness "$@"',
}, "\n") .. "\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/bin/npm", ABS .. "/drive.sh" } })

local n = 0
local function case_dir(cached)
    n = n + 1
    local d = ABS .. "/c" .. n
    fs.mkdir(REL .. "/c" .. n .. "/prefix/bin")
    fs.mkdir(REL .. "/c" .. n .. "/fallback")
    if cached then
        fs.write(REL .. "/c" .. n .. "/prefix/bin/opencode", "#!/usr/bin/env bash\necho " .. cached .. "\n")
        proc.run({ argv = { "chmod", "+x", d .. "/prefix/bin/opencode" } })
    end
    return d
end
local function run(d, name, pkg, bin)
    local r = proc.run({ argv = { "bash", ABS .. "/drive.sh", LIB, name, pkg, bin },
        env = { PATH = ABS .. "/bin:/usr/bin:/bin", NPM_CONFIG_PREFIX = d .. "/prefix",
                TILLANDSIAS_HARNESS_FALLBACK_DIR = d .. "/fallback", NPM_LOG = d .. "/npm.log",
                HOME = d },
        timeout_ms = 60000 })
    local log = proc.run({ argv = { "cat", d .. "/npm.log" } }).stdout or ""
    return r, log
end

-- 1 FRESH
local d = case_dir(nil)
local r, log = run(d, "opencode", "opencode-ai", "opencode")
arm("1 FRESH a fresh forge installs opencode-ai@" .. PIN .. ", not @latest",
    log:find("opencode-ai@" .. PIN, 1, true) ~= nil and log:find("@latest", 1, true) == nil, log .. (r.stderr or ""))

-- 2 DRIFT
d = case_dir("1.19.5")
r, log = run(d, "opencode", "opencode-ai", "opencode")
local now = text.trim(proc.run({ argv = { d .. "/prefix/bin/opencode" } }).stdout or "")
arm("2 DRIFT a cached opencode at 1.19.5 is reinstalled at " .. PIN,
    PIN ~= "1.19.5" and log:find("opencode-ai@" .. PIN, 1, true) ~= nil and now == PIN,
    "now=" .. now .. " npm=" .. log .. (r.stderr or ""))

-- 3 KEEP
d = case_dir(PIN)
r, log = run(d, "opencode", "opencode-ai", "opencode")
arm("3 KEEP a cached opencode at the pin is kept (npm not called)", log == "", log)

-- 4 UNPINNED
d = case_dir(nil)
r, log = run(d, "fooharness", "foo-harness", "fooharness")
arm("4 UNPINNED a harness with no pin installs @latest and the trace names it unpinned",
    log:find("foo-harness@latest", 1, true) ~= nil and (r.stderr or ""):find("unpinned", 1, true) ~= nil,
    log .. (r.stderr or ""))

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
