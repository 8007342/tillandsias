-- @env PATH
-- @trace order:2027-e2cf, spec:default-image
--
-- test-forge-opencode-is-pinned.lua — the forge installs the LATEST opencode
-- from its upstream GitHub release: it resolves the latest release from the API,
-- verifies the tarball against the release's PUBLISHED sha256 digest and fails
-- closed on a mismatch or a missing digest, records a version that passes the
-- health probe as last-good, and rolls back to last-good when a fresh version
-- fails. Each lane refreshes only its own harness.
--
-- WHY (2027-e2cf). Cold Linux lanes died with "EPROTO: The TLS handshake
-- failed" from 2026-10-31. The forge installed opencode-ai@latest from npm, and
-- npm's opencode-ai stopped at 1.19.5 (2026-10-28) while upstream shipped 2.x as
-- GitHub release tarballs. Operator rulings 2026-11-08: drop npm for opencode;
-- latest on every launch, like the other harnesses, with digest verification
-- and the order-284 last-good rollback; and a lane must not refresh other
-- lanes' harnesses (a claude lane installed agy on every launch).
--
-- Runs the REAL functions cut from images/default/lib-common.sh. A stub curl
-- answers the releases/latest API with $FAKE_JSON and serves $FAKE_TGZ for the
-- asset download; harness_probe is stubbed (FAKE_PROBE_FAIL=1 fails it):
--   1 LATEST    a fresh forge resolves upstream's latest (v1.9.10), downloads
--               its x64 asset, verifies it, installs it and records last-good
--   2 BASELINE  a CPU without avx2 downloads and verifies the -baseline asset
--   3 TAMPER    an asset whose sha256 is not the published digest is REFUSED;
--               last-good stays and is what runs
--   4 NODIGEST  a release asset with no published digest is refused before download
--   5 ROLLBACK  a verified latest that fails the health probe rolls back to
--               last-good, and last-good is not moved
--   6 CURRENT   last-good already is latest: the API is asked, nothing is downloaded
--   7 TTL       a check within the TTL does no network at all
--   8 OFFLINE   the API cannot be reached: last-good runs
--   9 LANE      a claude lane's refresh leaves no antigravity (agy) or codex
--               install; an antigravity lane does run agy (negative control)
--  10 UNPINNED  an npm harness with no pin installs @latest and the trace says so
--  11 WIRED     require_opencode goes through the release installer, not npm
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-opencode-is-pinned.lua
--  12 MARKER  the release upstream MARKS latest installs (operator ruling
--               2026-11-08), even when a higher v1 exists; the list is not read
--  13 V2      a marked release outside the v1 line (a v2, a prerelease, a
--               draft, process-daemon-v*) is refused BEFORE download and the v1
--               last-good runs, until the v2 migration row 2042-44v9 closes
-- Verdict: ok:forge-opencode-is-pinned:13 arms | violation:forge-opencode-is-pinned:<n>-failed

local NAME = "forge-opencode-is-pinned"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
if proc.run({ argv = { "jq", "--version" } }).code ~= 0 then verdict.could_not_run(NAME, "jq is not on this host (the forge base has it)") end
local LIB = ROOT .. "/images/default/lib-common.sh"

local REL = "target/plan-scratch/opencode-latest-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else out.line("FAIL: " .. name .. " — got: " .. tostring(got)); failed[#failed + 1] = name end
end
local lib = fs.read("images/default/lib-common.sh") or ""
local LATEST = "1.9.10"

fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/uname", "#!/usr/bin/env bash\necho x86_64\n")
fs.write(REL .. "/bin/curl", table.concat({
    "#!/usr/bin/env bash",
    'o=""; u=""',
    'while [ $# -gt 0 ]; do case "$1" in (-o) o="$2"; shift 2 ;; (-H) shift 2 ;; (http*) u="$1"; shift ;; (*) shift ;; esac; done',
    'printf "%s\\n" "$u" >> "$CURL_LOG"',
    'case "$u" in',
    '    (*api.github.com*) [ "${FAKE_API_FAIL:-}" = 1 ] && exit 22; cat "$FAKE_JSON" ;;',
    '    (*) cp "$FAKE_TGZ" "$o" ;;',
    'esac',
}, "\n") .. "\n")
local HAVE_SHA = proc.run({ argv = { "test", "-x", "/usr/bin/sha256sum" } }).code == 0
    or proc.run({ argv = { "test", "-x", "/bin/sha256sum" } }).code == 0
if not HAVE_SHA then
    fs.write(REL .. "/bin/sha256sum", '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n')
end
fs.write(REL .. "/bin/npm", table.concat({
    "#!/usr/bin/env bash",
    'printf "%s\\n" "$*" >> "$NPM_LOG"',
    'mkdir -p "$NPM_CONFIG_PREFIX/bin"; printf "#!/usr/bin/env bash\\necho 0.0.1\\n" > "$NPM_CONFIG_PREFIX/bin/fooharness"',
    'chmod +x "$NPM_CONFIG_PREFIX/bin/fooharness"',
}, "\n") .. "\n")
-- driver: stub the helpers, cut the real functions, run one mode.
fs.write(REL .. "/drive.sh", table.concat({
    "#!/usr/bin/env bash",
    'lib="$1"; mode="$2"; shift 2',
    'trace_lifecycle() { printf "trace:%s:%s\\n" "$1" "$2" >&2; }',
    "_clear_stale_npm_staging() { :; }",
    "harness_record_last_good() { :; }",
    'for f in harness_pin harness_release_asset _require_release_harness _require_harness ensure_forge_harnesses; do eval "$(sed -n "/^$f()/,/^}/p" "$lib")"; done',
    'harness_probe() { [ "${FAKE_PROBE_FAIL:-}" != 1 ]; }',
    'harness_last_good_file() { echo "$HOME/lg-$1"; }',
    'openspec_pin_marker() { echo "$HOME/no-pin"; }',
    'curl_install_claude() { echo "LANE:claude" >> "$LANE_LOG"; }',
    'require_antigravity() { echo "LANE:agy" >> "$LANE_LOG"; }',
    'case "$mode" in',
    '    (npm) _require_harness "$@" ;;',
    '    (lane) ensure_forge_harnesses "$@" ;;',
    '    (*) _require_release_harness "$@" ;;',
    'esac',
}, "\n") .. "\n")
local chm = { "chmod", "+x", ABS .. "/bin/uname", ABS .. "/bin/curl", ABS .. "/bin/npm", ABS .. "/drive.sh" }
if not HAVE_SHA then chm[#chm + 1] = ABS .. "/bin/sha256sum" end
proc.run({ argv = chm })

-- the fake release tarball, its digest, and the API answers
fs.mkdir(REL .. "/tgz")
fs.write(REL .. "/tgz/opencode", "#!/usr/bin/env bash\necho opencode v" .. LATEST .. "\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/tgz/opencode" } })
proc.run({ argv = { "tar", "-czf", ABS .. "/fake.tgz", "-C", ABS .. "/tgz", "opencode" } })
local sumr = proc.run({ argv = HAVE_SHA and { "sha256sum", ABS .. "/fake.tgz" } or { "shasum", "-a", "256", ABS .. "/fake.tgz" } })
local FAKE = (sumr.stdout or ""):match("^(%x+)") or ""
-- The releases/latest answer: ONE release object (upstream's own marker).
local function api(x64, base, tag, pre, draft)
    local function a(name, dg)
        if dg == nil then return '{"name":"' .. name .. '"}' end
        return '{"name":"' .. name .. '","digest":"sha256:' .. dg .. '"}'
    end
    return '{"tag_name":"' .. (tag or ("v" .. LATEST)) .. '","prerelease":' .. tostring(pre == true)
        .. ',"draft":' .. tostring(draft == true) .. ',"assets":['
        .. a("opencode-linux-x64.tar.gz", x64) .. "," .. a("opencode-linux-x64-baseline.tar.gz", base) .. "]}"
end
fs.write(REL .. "/api-good.json", api(FAKE, FAKE))
fs.write(REL .. "/api-bad.json", api(string.rep("0", 64), string.rep("0", 64)))
fs.write(REL .. "/api-nodigest.json", api(nil, nil))
fs.write(REL .. "/avx2", "flags : fpu sse2 avx avx2\n")
fs.write(REL .. "/noavx2", "flags : fpu sse2 avx\n")

local n = 0
-- a case dir; `lg` installs a verified last-good at that version.
local function case_dir(lg, fresh_stamp)
    n = n + 1
    local rel = REL .. "/c" .. n
    fs.mkdir(rel .. "/rel/opencode")
    if lg then
        fs.mkdir(rel .. "/rel/opencode/" .. lg)
        fs.write(rel .. "/rel/opencode/" .. lg .. "/opencode", "#!/usr/bin/env bash\necho opencode v" .. lg .. "\n")
        proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. rel .. "/rel/opencode/" .. lg .. "/opencode" } })
        fs.write(rel .. "/rel/opencode/last-good", lg .. "\n")
        fs.write(rel .. "/rel/opencode/checked", "")
        if not fresh_stamp then
            proc.run({ argv = { "touch", "-d", "2020-01-01", ROOT .. "/" .. rel .. "/rel/opencode/checked" } })
        end
    end
    return ROOT .. "/" .. rel
end
local function run(dd, mode, args, extra)
    local env = { PATH = ABS .. "/bin:/usr/bin:/bin", HOME = dd,
                  TILLANDSIAS_HARNESS_RELEASE_DIR = dd .. "/rel", TILLANDSIAS_CPUINFO = ABS .. "/avx2",
                  CURL_LOG = dd .. "/curl.log", FAKE_TGZ = ABS .. "/fake.tgz", FAKE_JSON = ABS .. "/api-good.json",
                  NPM_LOG = dd .. "/npm.log", NPM_CONFIG_PREFIX = dd .. "/prefix", LANE_LOG = dd .. "/lane.log",
                  TILLANDSIAS_HARNESS_FALLBACK_DIR = dd .. "/fallback" }
    for k, v in pairs(extra or {}) do env[k] = v end
    local argv = { "bash", ABS .. "/drive.sh", LIB, mode }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = env, timeout_ms = 60000 })
    local curl = proc.run({ argv = { "cat", dd .. "/curl.log" } }).stdout or ""
    return r, curl
end
local function ver_of(path)
    local r = proc.run({ argv = { path, "--version" } })
    return r.code == 0 and text.trim(r.stdout or "") or ("<not runnable: " .. path .. ">")
end
local function lg_of(dd) return text.trim(proc.run({ argv = { "cat", dd .. "/rel/opencode/last-good" } }).stdout or "") end
local function downloads(curl) local c = 0; for _ in curl:gmatch("/releases/download/") do c = c + 1 end; return c end
local OC = { "opencode", "opencode", "anomalyco/opencode", "1" }

-- 1 LATEST
local d = case_dir(nil)
local r, curl = run(d, "release", OC)
local path = text.trim(r.stdout or "")
arm("1 LATEST a fresh forge resolves, verifies, installs and records the latest release",
    curl:find("api.github.com/repos/anomalyco/opencode/releases/latest", 1, true) ~= nil
        and curl:find("/releases/download/v" .. LATEST .. "/opencode-linux-x64.tar.gz", 1, true) ~= nil
        and ver_of(path) == "opencode v" .. LATEST and lg_of(d) == LATEST,
    "curl=" .. curl .. " path=" .. path .. " lg=" .. lg_of(d) .. " " .. (r.stderr or ""))

-- 2 BASELINE
d = case_dir(nil)
r, curl = run(d, "release", OC, { TILLANDSIAS_CPUINFO = ABS .. "/noavx2" })
path = text.trim(r.stdout or "")
arm("2 BASELINE a CPU without avx2 downloads and verifies the -baseline asset",
    curl:find("opencode-linux-x64-baseline.tar.gz", 1, true) ~= nil and ver_of(path) == "opencode v" .. LATEST,
    curl .. (r.stderr or ""))

-- 3 TAMPER
d = case_dir("1.0.0")
r, curl = run(d, "release", OC, { FAKE_JSON = ABS .. "/api-bad.json" })
path = text.trim(r.stdout or "")
arm("3 TAMPER a digest mismatch is refused; last-good stays and runs",
    (r.stderr or ""):find("refused:harness-release:opencode:digest-mismatch", 1, true) ~= nil
        and ver_of(path) == "opencode v1.0.0" and lg_of(d) == "1.0.0"
        and proc.run({ argv = { "test", "-e", d .. "/rel/opencode/" .. LATEST .. "/opencode" } }).code ~= 0,
    "now=" .. ver_of(path) .. " lg=" .. lg_of(d) .. " " .. (r.stderr or ""))

-- 4 NODIGEST
d = case_dir(nil)
r, curl = run(d, "release", OC, { FAKE_JSON = ABS .. "/api-nodigest.json" })
path = text.trim(r.stdout or "")
arm("4 NODIGEST an asset with no published digest is refused before any download",
    downloads(curl) == 0 and (r.stderr or ""):find("refused:harness-release:opencode:no-published-digest", 1, true) ~= nil
        and proc.run({ argv = { "test", "-x", path } }).code ~= 0,
    curl .. (r.stderr or ""))

-- 5 ROLLBACK
d = case_dir("1.0.0")
r, curl = run(d, "release", OC, { FAKE_PROBE_FAIL = "1" })
path = text.trim(r.stdout or "")
arm("5 ROLLBACK a latest that fails its probe rolls back to last-good, which is not moved",
    downloads(curl) == 1 and ver_of(path) == "opencode v1.0.0" and lg_of(d) == "1.0.0"
        and (r.stderr or ""):find("FAILED health probe", 1, true) ~= nil,
    "now=" .. ver_of(path) .. " lg=" .. lg_of(d) .. " " .. (r.stderr or ""))

-- 6 CURRENT
d = case_dir(LATEST)
r, curl = run(d, "release", OC)
path = text.trim(r.stdout or "")
arm("6 CURRENT last-good is already latest: the API is asked, nothing is downloaded",
    curl:find("api.github.com", 1, true) ~= nil and downloads(curl) == 0 and ver_of(path) == "opencode v" .. LATEST,
    curl)

-- 7 TTL
d = case_dir("1.0.0", true)
r, curl = run(d, "release", OC)
path = text.trim(r.stdout or "")
arm("7 TTL a check within the TTL does no network", curl == "" and ver_of(path) == "opencode v1.0.0", curl)

-- 8 OFFLINE
d = case_dir("1.0.0")
r, curl = run(d, "release", OC, { FAKE_API_FAIL = "1" })
path = text.trim(r.stdout or "")
arm("8 OFFLINE the API cannot be reached: last-good runs", ver_of(path) == "opencode v1.0.0" and downloads(curl) == 0,
    "now=" .. ver_of(path) .. " " .. (r.stderr or ""))

-- 9 LANE (ensure_forge_harnesses takes its lock under the tool cache)
d = case_dir(nil)
fs.mkdir(REL .. "/c" .. n .. "/.cache/tillandsias-project")
r = run(d, "lane", { "claude" })
local lane = proc.run({ argv = { "cat", d .. "/lane.log" } }).stdout or ""
local npm = proc.run({ argv = { "cat", d .. "/npm.log" } }).stdout or ""
local d2 = case_dir(nil)
fs.mkdir(REL .. "/c" .. n .. "/.cache/tillandsias-project")
run(d2, "lane", { "antigravity" })
local lane2 = proc.run({ argv = { "cat", d2 .. "/lane.log" } }).stdout or ""
arm("9 LANE a claude lane refreshes claude only (no agy, no codex); an antigravity lane runs agy",
    lane:find("LANE:claude", 1, true) ~= nil and lane:find("LANE:agy", 1, true) == nil
        and npm:find("@openai/codex", 1, true) == nil and lane2:find("LANE:agy", 1, true) ~= nil,
    "claude-lane=" .. lane .. " npm=" .. npm .. " agy-lane=" .. lane2)

-- 12 MARKER: upstream's marked release is what installs, even when a higher v1
-- exists: only /releases/latest is asked, never the release list.
fs.write(REL .. "/api-marker.json", api(FAKE, FAKE, "v1.9.9"))
d = case_dir(nil)
r, curl = run(d, "release", OC, { FAKE_JSON = ABS .. "/api-marker.json" })
local picked = curl:match("/releases/download/([^/]+)/") or ""
arm("12 MARKER the release upstream marks latest (v1.9.9) installs; the release list is never consulted",
    picked == "v1.9.9" and curl:find("/releases/latest", 1, true) ~= nil and curl:find("releases?", 1, true) == nil
        and lg_of(d) == "1.9.9",
    "picked=" .. picked .. " lg=" .. lg_of(d) .. " " .. curl)

-- 13 V2: a marked release outside the v1 line is refused BEFORE download, and
-- the v1 last-good keeps running. Cases: a marked v2.2.6, a marked v1
-- prerelease, a marked draft, a marked process-daemon-v1.99.0.
local v2_ok, v2_got = true, {}
for i, c in ipairs({ { "v2.2.6" }, { "v1.20.0", true }, { "v1.21.0", false, true }, { "process-daemon-v1.99.0" } }) do
    fs.write(REL .. "/api-out" .. i .. ".json", api(FAKE, FAKE, c[1], c[2], c[3]))
    d = case_dir("1.0.0")
    r, curl = run(d, "release", OC, { FAKE_JSON = ABS .. "/api-out" .. i .. ".json" })
    path = text.trim(r.stdout or "")
    local ok = downloads(curl) == 0 and ver_of(path) == "opencode v1.0.0" and lg_of(d) == "1.0.0"
        and (r.stderr or ""):find("refused:harness-release:opencode:marked-latest-not-v1:" .. c[1], 1, true) ~= nil
    if not ok then v2_ok = false end
    v2_got[#v2_got + 1] = c[1] .. "=" .. tostring(ok)
end
arm("13 V2 a marked v2, prerelease, draft or other tag family is refused before download; the v1 last-good runs",
    v2_ok, table.concat(v2_got, " "))

-- 10 UNPINNED
d = case_dir(nil)
r = run(d, "npm", { "fooharness", "foo-harness", "fooharness" })
npm = proc.run({ argv = { "cat", d .. "/npm.log" } }).stdout or ""
arm("10 UNPINNED an npm harness with no pin installs @latest and the trace says it is unpinned",
    npm:find("foo-harness@latest", 1, true) ~= nil and (r.stderr or ""):find("unpinned", 1, true) ~= nil,
    npm .. (r.stderr or ""))

-- 11 WIRED
local body = lib:match("\nrequire_opencode%(%)%s*{(.-)\n}") or ""
arm("11 WIRED require_opencode installs through _require_release_harness, not npm",
    body:find("_require_release_harness opencode opencode anomalyco/opencode 1", 1, true) ~= nil and body:find("_require_harness opencode", 1, true) == nil,
    body:sub(1, 200))

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
