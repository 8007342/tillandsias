-- @env PATH
-- @trace order:2063-nfag, order:2027-e2cf, spec:default-image
--
-- test-forge-copilot-harness.lua — the copilot lane installs GitHub's official
-- copilot CLI from its upstream release at LATEST, verified twice: against
-- the asset's PUBLISHED API digest and against the release's SHA256SUMS.txt.
-- Either missing or disagreeing fails closed. A probe-passing version is
-- recorded last-good, and the CLI is never baked into an image (operator
-- ruling 2026-11-08: the GitHub Copilot CLI License allows redistribution only
-- bundled, so the forge fetches it at launch). Only the copilot lane fetches it.
--
-- Runs the REAL functions cut from images/default/lib-common.sh, with a stub
-- curl that serves the releases/latest API ($FAKE_JSON), the tarball
-- ($FAKE_TGZ) and SHA256SUMS.txt ($FAKE_SUMS):
--   1 LATEST     digest and sums agree: installed, recorded last-good
--   2 SUMS-BAD   the API digest matches but SHA256SUMS.txt names another
--                sha256: REFUSED, nothing installed
--   3 SUMS-NONE  the release ships no SHA256SUMS.txt: REFUSED before download
--   4 NOAVX2     a CPU without avx2 still takes copilot-linux-x64.tar.gz
--                (copilot ships no -baseline build)
--   5 LANE       the shared refresh never fetches copilot (claude lane, and
--                the copilot lane's own background refresh), while the
--                foreground require_copilot does (negative control)
--   6 WIRED      require_copilot installs through the release installer with
--                SHA256SUMS.txt required, on the v1 line
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-copilot-harness.lua
-- Verdict: ok:forge-copilot-harness:6 arms | violation:forge-copilot-harness:<n>-failed

local NAME = "forge-copilot-harness"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
if proc.run({ argv = { "jq", "--version" } }).code ~= 0 then verdict.could_not_run(NAME, "jq is not on this host (the forge base has it)") end
local LIB = ROOT .. "/images/default/lib-common.sh"

local REL = "target/plan-scratch/copilot-harness-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else out.line("FAIL: " .. name .. " — got: " .. tostring(got)); failed[#failed + 1] = name end
end
local lib = fs.read("images/default/lib-common.sh") or ""
local LATEST = "1.0.108"

fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/uname", "#!/usr/bin/env bash\necho x86_64\n")
fs.write(REL .. "/bin/curl", table.concat({
    "#!/usr/bin/env bash",
    'o=""; u=""',
    'while [ $# -gt 0 ]; do case "$1" in (-o) o="$2"; shift 2 ;; (-H) shift 2 ;; (http*) u="$1"; shift ;; (*) shift ;; esac; done',
    'printf "%s\\n" "$u" >> "$CURL_LOG"',
    'case "$u" in',
    '    (*api.github.com*) cat "$FAKE_JSON" ;;',
    '    (*/SHA256SUMS.txt) if [ -n "${o}" ]; then cp "$FAKE_SUMS" "$o"; else cat "$FAKE_SUMS"; fi ;;',
    '    (*) cp "$FAKE_TGZ" "$o" ;;',
    'esac',
}, "\n") .. "\n")
fs.write(REL .. "/bin/npm", '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$NPM_LOG"\n')
fs.write(REL .. "/drive.sh", table.concat({
    "#!/usr/bin/env bash",
    'lib="$1"; mode="$2"; shift 2',
    'trace_lifecycle() { printf "trace:%s:%s\\n" "$1" "$2" >&2; }',
    "_clear_stale_npm_staging() { :; }",
    "harness_record_last_good() { :; }",
    'for f in harness_pin harness_release_asset _require_release_harness _require_harness ensure_forge_harnesses require_copilot; do eval "$(sed -n "/^$f()/,/^}/p" "$lib")"; done',
    'harness_probe() { :; }',
    'harness_last_good_file() { echo "$HOME/lg-$1"; }',
    'openspec_pin_marker() { echo "$HOME/no-pin"; }',
    'curl_install_claude() { echo "LANE:claude" >> "$LANE_LOG"; }',
    'require_antigravity() { echo "LANE:agy" >> "$LANE_LOG"; }',
    'case "$mode" in',
    '    (lane) ensure_forge_harnesses "$@" ;;',
    '    (copilot) require_copilot; echo "COPILOT_BIN=${COPILOT_BIN:-}" ;;',
    '    (*) _require_release_harness "$@" ;;',
    'esac',
}, "\n") .. "\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/bin/uname", ABS .. "/bin/curl", ABS .. "/bin/npm", ABS .. "/drive.sh" } })

fs.mkdir(REL .. "/tgz")
fs.write(REL .. "/tgz/copilot", "#!/usr/bin/env bash\necho GitHub Copilot CLI " .. LATEST .. ".\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/tgz/copilot" } })
proc.run({ argv = { "tar", "-czf", ABS .. "/fake.tgz", "-C", ABS .. "/tgz", "copilot" } })
local FAKE = ((proc.run({ argv = { "sha256sum", ABS .. "/fake.tgz" } }).stdout) or ""):match("^(%x+)") or ""
local OTHER = string.rep("a", 64)
local function api(sums)
    local assets = '{"name":"copilot-linux-x64.tar.gz","digest":"sha256:' .. FAKE .. '"},'
        .. '{"name":"copilot-linux-arm64.tar.gz","digest":"sha256:' .. FAKE .. '"}'
    if sums then assets = assets .. ',{"name":"SHA256SUMS.txt","digest":"sha256:' .. OTHER .. '"}' end
    return '{"tag_name":"v' .. LATEST .. '","prerelease":false,"draft":false,"assets":[' .. assets .. ']}'
end
fs.write(REL .. "/api-sums.json", api(true))
fs.write(REL .. "/api-nosums.json", api(false))
fs.write(REL .. "/sums-good.txt", FAKE .. "  copilot-linux-x64.tar.gz\n" .. FAKE .. "  copilot-linux-arm64.tar.gz\n")
fs.write(REL .. "/sums-bad.txt", OTHER .. "  copilot-linux-x64.tar.gz\n" .. OTHER .. "  copilot-linux-arm64.tar.gz\n")
fs.write(REL .. "/avx2", "flags : fpu sse2 avx avx2\n")
fs.write(REL .. "/noavx2", "flags : fpu sse2 avx\n")

local n = 0
local function run(mode, args, json, sums, cpu)
    n = n + 1
    local rel = REL .. "/c" .. n
    fs.mkdir(rel .. "/home")
    local argv = { "env",
        "PATH=" .. ABS .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
        "HOME=" .. ROOT .. "/" .. rel .. "/home",
        "TILLANDSIAS_HARNESS_RELEASE_DIR=" .. ROOT .. "/" .. rel .. "/rel",
        "NPM_CONFIG_PREFIX=" .. ROOT .. "/" .. rel .. "/npm",
        "CURL_LOG=" .. ROOT .. "/" .. rel .. "/curl.log",
        "NPM_LOG=" .. ROOT .. "/" .. rel .. "/npm.log",
        "LANE_LOG=" .. ROOT .. "/" .. rel .. "/lane.log",
        "FAKE_JSON=" .. ABS .. "/" .. (json or "api-sums.json"),
        "FAKE_SUMS=" .. ABS .. "/" .. (sums or "sums-good.txt"),
        "FAKE_TGZ=" .. ABS .. "/fake.tgz",
        "TILLANDSIAS_CPUINFO=" .. ABS .. "/" .. (cpu or "avx2"),
        "bash", ABS .. "/drive.sh", LIB, mode }
    for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    local function rd(f) local ok, s = pcall(fs.read, rel .. "/" .. f); return ok and (s or "") or "" end
    return {
        out = text.trim(r.stdout or ""), err = r.stderr or "",
        curl = rd("curl.log"), npm = rd("npm.log"), lane = rd("lane.log"),
        lg = text.trim(rd("rel/copilot/last-good")),
        installed = proc.run({ argv = { "test", "-x", ROOT .. "/" .. rel .. "/rel/copilot/" .. LATEST .. "/copilot" } }).code == 0,
    }
end
local REQ = { "copilot", "copilot", "github/copilot-cli", "1", "sums" }

local r1 = run("release", REQ)
arm("1 LATEST digest and SHA256SUMS.txt agree: installed and recorded last-good",
    r1.installed and r1.lg == LATEST and r1.curl:find("SHA256SUMS.txt", 1, true) ~= nil, r1.err)

local r2 = run("release", REQ, "api-sums.json", "sums-bad.txt")
arm("2 SUMS-BAD a SHA256SUMS.txt that disagrees with the digest is refused, nothing installed",
    not r2.installed and r2.lg == "" and r2.err:find("refused:harness-release:copilot:sums-mismatch", 1, true) ~= nil, r2.err)

local r3 = run("release", REQ, "api-nosums.json")
arm("3 SUMS-NONE a release with no SHA256SUMS.txt is refused before download",
    not r3.installed and r3.err:find("refused:harness-release:copilot:no-sums-file", 1, true) ~= nil
        and r3.curl:find("copilot-linux-x64.tar.gz", 1, true) == nil, r3.err)

local r4 = run("release", REQ, nil, nil, "noavx2")
arm("4 NOAVX2 a CPU without avx2 still takes copilot-linux-x64.tar.gz",
    r4.installed and r4.curl:find("/copilot-linux-x64.tar.gz", 1, true) ~= nil and r4.curl:find("baseline", 1, true) == nil, r4.curl)

local r5c = run("lane", { "claude" })
local r5p = run("lane", { "copilot" })
local r5f = run("copilot", {})
arm("5 LANE the shared refresh never fetches copilot; the copilot lane runs no other harness; require_copilot does fetch",
    r5c.curl:find("copilot-cli", 1, true) == nil and r5p.curl:find("copilot-cli", 1, true) == nil
        and r5p.lane == "" and r5p.npm:find("codex", 1, true) == nil
        and r5f.curl:find("github/copilot-cli", 1, true) ~= nil and r5f.out:find("COPILOT_BIN=.+/copilot") ~= nil,
    "claude-lane curl=[" .. r5c.curl .. "] copilot-lane lane=[" .. r5p.lane .. "] npm=[" .. r5p.npm .. "] fg out=[" .. r5f.out .. "]")

local body = lib:match("\nrequire_copilot%(%) {(.-)\n}") or ""
arm("6 WIRED require_copilot goes through the release installer with SHA256SUMS.txt required, v1 line",
    body:find("_require_release_harness copilot copilot github/copilot-cli 1 sums", 1, true) ~= nil, body)

proc.run({ argv = { "find", ABS, "-delete" } })
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
