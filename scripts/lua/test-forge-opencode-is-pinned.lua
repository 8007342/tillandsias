-- @env PATH
-- @trace order:2027-e2cf, spec:default-image
--
-- test-forge-opencode-is-pinned.lua — the forge installs a PINNED opencode from
-- its upstream release tarball, verifies the tarball against a sha256 pinned in
-- the tree and fails closed on a mismatch; it replaces a cached copy at any other
-- version, and an npm harness with no pin says so.
--
-- WHY (2027-e2cf). Cold Linux lanes died on their model request with
-- "EPROTO: The TLS handshake failed" in 5 of 6 runs since 2026-10-31. The forge
-- installed `opencode-ai@latest` from npm, so the client changed under every lane
-- with no commit. Worse, npm's opencode-ai stopped at 1.19.5 (2026-10-28) while
-- upstream shipped 2.x as GitHub release tarballs (v2.2.6, 2026-11-06), so npm
-- also held every forge on an old line. The operator asked for the latest
-- opencode, off npm (2026-11-08); yoga and lenovinha agreed on the
-- release tarball, verified by sha256 and failing closed.
--
-- Runs the REAL functions cut from images/default/lib-common.sh with stub curl
-- and uname on PATH. The stub curl logs each URL and serves a fake release
-- tarball holding an `opencode` that prints "opencode v<version>":
--   1 FRESH     no cache: fetches v<pin>/opencode-linux-x64.tar.gz and installs the pin
--   2 BASELINE  a CPU without avx2 fetches the -baseline asset (no SIGILL)
--   3 TAMPER    a tarball whose sha256 is not the pinned one is REFUSED: nothing installed
--   4 KEEP      a cached binary at the pin is kept: curl is not called
--   5 DRIFT     a cached binary at another version is reinstalled at the pin
--   6 NODIGEST  an asset with no pinned digest is refused before any download
--   7 PINS      the tree's digest table pins a 64-hex sha256 for both x64 assets
--               at the pin
--   8 UNPINNED  an npm harness with no pin still installs @latest, and the trace
--               says it is unpinned
--   9 WIRED     require_opencode goes through the release installer, not npm
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-opencode-is-pinned.lua
-- Verdict: ok:forge-opencode-is-pinned:9 arms | violation:forge-opencode-is-pinned:<n>-failed

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

local lib = fs.read("images/default/lib-common.sh") or ""
-- The pin the tree declares. Pre-fix there is no harness_release_pin, so the
-- expected pin falls back to the agreed one and arm 1 fails.
local PIN = lib:match('opencode%)%s*echo%s+"?([0-9]+%.[0-9]+%.[0-9]+)"?') or "2.2.6"

fs.mkdir(REL .. "/bin")
-- stub uname: always x86_64, so the asset choice is decided by cpuinfo alone.
fs.write(REL .. "/bin/uname", "#!/usr/bin/env bash\necho x86_64\n")
-- stub curl: log the URL and copy $FAKE_TGZ to the -o target.
fs.write(REL .. "/bin/curl", table.concat({
    "#!/usr/bin/env bash",
    'o=""; u=""',
    'while [ $# -gt 0 ]; do case "$1" in (-o) o="$2"; shift 2 ;; (http*) u="$1"; shift ;; (*) shift ;; esac; done',
    'printf "%s\\n" "$u" >> "$CURL_LOG"',
    'cp "$FAKE_TGZ" "$o"',
}, "\n") .. "\n")
-- A host without sha256sum (macOS) gets a shasum shim; the comparison under
-- test is the lib's own.
local HAVE_SHA = proc.run({ argv = { "test", "-x", "/usr/bin/sha256sum" } }).code == 0
    or proc.run({ argv = { "test", "-x", "/bin/sha256sum" } }).code == 0
if not HAVE_SHA then
    fs.write(REL .. "/bin/sha256sum", '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n')
end
-- stub npm, for the UNPINNED arm
fs.write(REL .. "/bin/npm", table.concat({
    "#!/usr/bin/env bash",
    'printf "%s\\n" "$*" >> "$NPM_LOG"',
    'mkdir -p "$NPM_CONFIG_PREFIX/bin"; printf "#!/usr/bin/env bash\\necho 0.0.1\\n" > "$NPM_CONFIG_PREFIX/bin/fooharness"',
    'chmod +x "$NPM_CONFIG_PREFIX/bin/fooharness"',
}, "\n") .. "\n")
-- driver: stub the helpers, cut the real functions, run one.
-- FAKE_SHA, when set, replaces the pinned digest table (the fake tarball is
-- not the real release); mode "pins" calls the REAL table instead.
fs.write(REL .. "/drive.sh", table.concat({
    "#!/usr/bin/env bash",
    'lib="$1"; mode="$2"; shift 2',
    'trace_lifecycle() { printf "trace:%s:%s\\n" "$1" "$2" >&2; }',
    "_clear_stale_npm_staging() { :; }",
    "harness_record_last_good() { :; }",
    'for f in harness_pin harness_release_pin harness_release_sha256 harness_release_asset _require_release_harness _require_harness; do eval "$(sed -n "/^$f()/,/^}/p" "$lib")"; done',
    'if [ "$mode" = pins ]; then harness_release_sha256 "$@"; exit $?; fi',
    'if [ -n "${FAKE_SHA:-}" ]; then harness_release_sha256() { [ "$FAKE_SHA" = none ] && return 1; echo "$FAKE_SHA"; }; fi',
    'if [ "$mode" = npm ]; then _require_harness "$@"; else _require_release_harness "$@"; fi',
}, "\n") .. "\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/bin/uname", ABS .. "/bin/curl", ABS .. "/bin/npm", ABS .. "/drive.sh" } })
if not HAVE_SHA then proc.run({ argv = { "chmod", "+x", ABS .. "/bin/sha256sum" } }) end

-- the fake release tarball and its digest
fs.mkdir(REL .. "/tgz")
fs.write(REL .. "/tgz/opencode", "#!/usr/bin/env bash\necho opencode v" .. PIN .. "\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/tgz/opencode" } })
proc.run({ argv = { "tar", "-czf", ABS .. "/fake.tgz", "-C", ABS .. "/tgz", "opencode" } })
local sumr = proc.run({ argv = HAVE_SHA and { "sha256sum", ABS .. "/fake.tgz" } or { "shasum", "-a", "256", ABS .. "/fake.tgz" } })
local FAKE = (sumr.stdout or ""):match("^(%x+)") or ""

fs.write(REL .. "/avx2", "flags : fpu sse2 avx avx2\n")
fs.write(REL .. "/noavx2", "flags : fpu sse2 avx\n")

local n = 0
local function case_dir(cached)
    n = n + 1
    local rel = REL .. "/c" .. n
    fs.mkdir(rel .. "/rel/opencode/" .. PIN)
    if cached then
        fs.write(rel .. "/rel/opencode/" .. PIN .. "/opencode", "#!/usr/bin/env bash\necho opencode v" .. cached .. "\n")
        proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. rel .. "/rel/opencode/" .. PIN .. "/opencode" } })
    end
    return ROOT .. "/" .. rel
end
local function run(d, mode, args, extra)
    local env = { PATH = ABS .. "/bin:/usr/bin:/bin", HOME = d,
                  TILLANDSIAS_HARNESS_RELEASE_DIR = d .. "/rel", TILLANDSIAS_CPUINFO = ABS .. "/avx2",
                  CURL_LOG = d .. "/curl.log", FAKE_TGZ = ABS .. "/fake.tgz", FAKE_SHA = FAKE,
                  NPM_LOG = d .. "/npm.log", NPM_CONFIG_PREFIX = d .. "/prefix",
                  TILLANDSIAS_HARNESS_FALLBACK_DIR = d .. "/fallback" }
    for k, v in pairs(extra or {}) do env[k] = v end
    local argv = { "bash", ABS .. "/drive.sh", LIB, mode }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = env, timeout_ms = 60000 })
    local curl = proc.run({ argv = { "cat", d .. "/curl.log" } }).stdout or ""
    return r, curl
end
local function ver_of(path)
    local r = proc.run({ argv = { path, "--version" } })
    return r.code == 0 and text.trim(r.stdout or "") or ("<not runnable: " .. path .. ">")
end
local OC = { "opencode", "opencode", "anomalyco/opencode" }

-- 1 FRESH
local d = case_dir(nil)
local r, curl = run(d, "release", OC)
local path = text.trim(r.stdout or "")
arm("1 FRESH a fresh forge installs opencode " .. PIN .. " from the release asset",
    curl:find("/releases/download/v" .. PIN .. "/opencode-linux-x64.tar.gz", 1, true) ~= nil
        and ver_of(path) == "opencode v" .. PIN,
    "curl=" .. curl .. " path=" .. path .. " " .. (r.stderr or ""))

-- 2 BASELINE
d = case_dir(nil)
r, curl = run(d, "release", OC, { TILLANDSIAS_CPUINFO = ABS .. "/noavx2" })
arm("2 BASELINE a CPU without avx2 fetches the -baseline asset",
    curl:find("opencode-linux-x64-baseline.tar.gz", 1, true) ~= nil, curl .. (r.stderr or ""))

-- 3 TAMPER
d = case_dir(nil)
r, curl = run(d, "release", OC, { FAKE_SHA = string.rep("0", 64) })
path = text.trim(r.stdout or "")
local exists = proc.run({ argv = { "test", "-x", path } }).code == 0
arm("3 TAMPER a tarball whose sha256 is not the pinned one is refused and nothing is installed",
    not exists and (r.stderr or ""):find("refused:harness-release:opencode:digest-mismatch", 1, true) ~= nil,
    "installed=" .. tostring(exists) .. " " .. (r.stderr or ""))

-- 4 KEEP
d = case_dir(PIN)
r, curl = run(d, "release", OC)
path = text.trim(r.stdout or "")
arm("4 KEEP a cached opencode at the pin is kept and returned (curl not called)",
    curl == "" and ver_of(path) == "opencode v" .. PIN, "curl=" .. curl .. " path=" .. path)

-- 5 DRIFT
d = case_dir("1.19.5")
r, curl = run(d, "release", OC)
path = text.trim(r.stdout or "")
arm("5 DRIFT a cached opencode at 1.19.5 is reinstalled at " .. PIN,
    curl ~= "" and ver_of(path) == "opencode v" .. PIN, "now=" .. ver_of(path) .. " " .. (r.stderr or ""))

-- 6 NODIGEST
d = case_dir(nil)
r, curl = run(d, "release", OC, { FAKE_SHA = "none" })
arm("6 NODIGEST an asset with no pinned digest is refused before any download",
    curl == "" and (r.stderr or ""):find("refused:harness-release:opencode:no-pinned-digest", 1, true) ~= nil,
    curl .. (r.stderr or ""))

-- 7 PINS (the real table)
local pins_ok, pins_got = true, {}
for _, asset in ipairs({ "opencode-linux-x64.tar.gz", "opencode-linux-x64-baseline.tar.gz" }) do
    local pr = proc.run({ argv = { "bash", ABS .. "/drive.sh", LIB, "pins", "opencode", PIN, asset },
        env = { PATH = "/usr/bin:/bin" } })
    local h = text.trim(pr.stdout or "")
    pins_got[#pins_got + 1] = asset .. "=" .. h
    if pr.code ~= 0 or not h:match("^" .. string.rep("%x", 64) .. "$") then pins_ok = false end
end
arm("7 PINS the tree pins a sha256 for both x64 assets at " .. PIN, pins_ok, table.concat(pins_got, " "))

-- 8 UNPINNED
d = case_dir(nil)
r = run(d, "npm", { "fooharness", "foo-harness", "fooharness" })
local npm = proc.run({ argv = { "cat", d .. "/npm.log" } }).stdout or ""
arm("8 UNPINNED an npm harness with no pin installs @latest and the trace says it is unpinned",
    npm:find("foo-harness@latest", 1, true) ~= nil and (r.stderr or ""):find("unpinned", 1, true) ~= nil,
    npm .. (r.stderr or ""))

-- 9 WIRED
local body = lib:match("\nrequire_opencode%(%)%s*{(.-)\n}") or ""
arm("9 WIRED require_opencode installs through _require_release_harness, not npm",
    body:find("_require_release_harness opencode", 1, true) ~= nil and body:find("_require_harness opencode", 1, true) == nil,
    body:sub(1, 200))

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
