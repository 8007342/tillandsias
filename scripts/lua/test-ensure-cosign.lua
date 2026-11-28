-- @env PATH http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY SSL_CERT_FILE CURL_CA_BUNDLE
-- @trace order:1324-ujvb, order:2360-ud6i, spec:ci-release
--
-- test-ensure-cosign.lua — POSITIVE CONTROL FIRST, then the negatives: a verifier that
-- says "Verified OK" tells you nothing until you have watched it say anything else. If a
-- negative arm verifies, every downstream cosign:verified is worthless while it still reads
-- as proof. Needs the network and the transparency log; a host that cannot reach them
-- SKIPS by name, which is could-not-run and never a pass. Ported from the .sh (2360-ud6i).
--
--   0 the pin is complete and read key-anchored, not as a substring of its own prose
--   1 POSITIVE: the manifest and the binary match the pin, and cosign verifies its release
--   2-4 NEGATIVE: a tampered blob, a wrong identity and a wrong OIDC issuer are rejected
--   5 a host that is not this one reports could-not-run, never verification-failed: a
--     platform with no pinned row, and a binary that will not execute here
--   6 ensure-cosign.sh prints exactly one line, in its grammar
--
-- Verdict: ok:ensure-cosign-fixture:<n> | violation:ensure-cosign-fixture:<n>-failed
--        | skip:ensure-cosign-fixture:no-network | :unsupported-platform:<os>/<arch>

local fixture = require "common.fixture"
local T = fixture.new("ensure-cosign-fixture")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
local FIN = { ok = function(n) return "ok:ensure-cosign-fixture:" .. n end }

-- The runner hands a child a base env: a forge's proxy must reach curl and cosign.
local NET = {}
for _, k in ipairs{ "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY", "SSL_CERT_FILE", "CURL_CA_BUNDLE" } do
    local v = env.get(k)
    if v and v ~= "" then NET[k] = v end
end
local function with(t) for k, v in pairs(NET) do if t[k] == nil then t[k] = v end end return t end
local function tool(argv)
    argv.env, argv.timeout_ms = with({}), 600000
    return T:run(argv)
end

local pin, assets = {}, {}
for l in (fs.read("scripts/cosign-release.pin") .. "\n"):gmatch("([^\n]*)\n") do
    local plat, a = l:match("^platform=([^=]*)=(.*)$")
    if plat then assets[plat] = assets[plat] or a
    else
        local k, v = l:match("^([%w_]+)=(.*)$")
        if k and pin[k] == nil then pin[k] = v end
    end
end
local missing = {}
for _, k in ipairs{ "version", "checksums", "checksums_sha256", "certificate_identity", "certificate_oidc_issuer" } do
    if (pin[k] or "") == "" then missing[#missing + 1] = k end
end
T:arm("0 all five pin fields are present", #missing == 0, table.concat(missing, " "))
local sum = pin.checksums_sha256 or ""
T:arm("0 checksums_sha256 is a 64-hex digest, not a comment", #sum == 64 and sum:find("^[0-9a-f]+$"), sum)
if #missing > 0 then T:finish(FIN) end

local function uname(flag) return text.trim(T:run{ "uname", flag }.stdout or ""):lower() end
local os_, arch = uname("-s"), uname("-m")
local asset = assets[os_ .. "/" .. arch]
if not asset then T:skip("unsupported-platform:" .. os_ .. "/" .. arch) end
local BASE = "https://github.com/sigstore/cosign/releases/download/" .. pin.version .. "/"
local function fetch(name, to) return tool{ "curl", "--proto", "=https", "--tlsv1.2", "-sSfL", BASE .. name, "-o", W.abs .. "/" .. to }.code == 0 end
if not (fetch(asset, "c") and fetch(asset .. ".sigstore.json", "c.json")) then T:skip("no-network") end

fetch(pin.checksums, "sums")
local function sha(f)
    local r = T:run{ SH, "-s", "--", W.abs .. "/" .. f, stdin = 'if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi\n' }
    return (r.stdout or ""):match("^%x+") or ""
end
local got = sha("sums")
if not T:arm("1 the signed manifest matches the pinned checksums_sha256", got == sum, "expected " .. sum .. ", got " .. got) then T:finish(FIN) end
local want
for l in (fs.read(W.rel .. "/sums") .. "\n"):gmatch("([^\n]*)\n") do
    local h, f = l:match("^(%x+)%s+(%S+)$") -- the whole name: not -kms, not .sbom.json
    if f == asset then want = want or h end
end
got = sha("c")
if not T:arm("1 " .. asset .. " matches the hash the manifest gives it", want == got, "manifest " .. tostring(want) .. ", got " .. got) then T:finish(FIN) end
T:must{ "chmod", "+x", W.abs .. "/c" }
local function verify(blob, id, issuer)
    local r = tool{ W.abs .. "/c", "verify-blob", W.abs .. "/" .. blob, "--bundle", W.abs .. "/c.json", "--certificate-identity", id, "--certificate-oidc-issuer", issuer }
    return r.code, r.stderr
end
local ID, ISS = pin.certificate_identity, pin.certificate_oidc_issuer
local rc, err = verify("c", ID, ISS)
T:arm("1 POSITIVE cosign verifies its OWN release", rc == 0, err)
T:must{ SH, "-s", "--", W.abs .. "/c", W.abs .. "/tampered", stdin = 'cp "$1" "$2" && printf X >> "$2"\n' }
-- A negative counts only if cosign RAN and said no: an unspawnable one is nil.
local function rejected(name, code) T:arm(name, code ~= nil and code ~= 0, "rc=" .. tostring(code) .. ": it verified, or never ran") end
rejected("2 a mutated binary is rejected", (verify("tampered", ID, ISS)))
rejected("3 a wrong certificate identity is rejected", (verify("c", "attacker@example.com", ISS)))
rejected("4 a wrong OIDC issuer is rejected", (verify("c", ID, "https://token.actions.githubusercontent.com")))

local function ensure(cache, sysname, machine)
    local path = env.get("PATH")
    if sysname then
        fs.mkdir(W.rel .. "/shim-" .. cache)
        fs.write(W.rel .. "/shim-" .. cache .. "/uname", '#!/usr/bin/env bash\ncase "${1:-}" in -m) echo ' .. machine .. " ;; *) echo " .. sysname .. " ;; esac\n")
        T:must{ "chmod", "+x", W.abs .. "/shim-" .. cache .. "/uname" }
        path = W.abs .. "/shim-" .. cache .. ":" .. path
    end
    local r = T:run{ SH, "scripts/ensure-cosign.sh", cwd = ROOT, timeout_ms = 600000, env_unset = { "TILLANDSIAS_*" },
        env = with{ PATH = path, TILLANDSIAS_COSIGN_CACHE = W.abs .. "/cache-" .. cache } }
    return r.code, text.trim(r.stdout or "")
end
local o
rc, o = ensure("a", "SunOS", "sparc64")
T:arm("5 an unpinned platform is could-not-run:unsupported-platform", o:find("^cosign:could%-not%-run:unsupported%-platform:"), o)
T:arm("5 and exits 0: it is not a failure", rc == 0, "rc=" .. tostring(rc))
rc, o = ensure("b", "Darwin", "arm64")
if os_ == "darwin" then -- the shim describes the truth here
    T:arm("5 a native darwin verifies", o == "cosign:verified:1/1" or o == "cosign:already-verified:1/1", o)
else
    T:arm("5 a darwin binary here is could-not-run, never verification-failed", o == "cosign:could-not-run:binary-not-executable-here", o)
    T:arm("5 and exits 0", rc == 0, "rc=" .. tostring(rc))
end
_, o = ensure("c")
T:arm("6 ensure-cosign.sh prints one line", o ~= "" and not o:find("\n", 1, true), o)
T:arm("6 the line is in its grammar", o == "cosign:verified:1/1" or o == "cosign:already-verified:1/1" or o:find("^cosign:could%-not%-run:"), o)
T:finish(FIN)
