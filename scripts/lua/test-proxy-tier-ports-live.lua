-- @env PATH
-- @env HOME
-- @env XDG_RUNTIME_DIR
-- @trace spec:proxy-container, order:2041-i3nk
--
-- test-proxy-tier-ports-live.lua — the BUILT proxy image serves one port per
-- egress tier and holds each port to its tier by name.
--
-- Builds images/proxy under a throwaway tag, then:
--   0 PARSE    `squid -k parse` passes in the image with the generated include
--   1 ALLOW    on the assets port (3131), CONNECT fonts.googleapis.com with SNI
--              fonts.googleapis.com completes a TLS handshake (spliced)
--   2 OFFTIER  on the assets port, CONNECT pypi.org (registries) is refused
--   3 SNI-OFF  on the assets port, CONNECT fonts.googleapis.com carrying SNI
--              pypi.org is refused: the SNI is not in the tier
--   4 DST-OFF  on the assets port, CONNECT pypi.org carrying SNI
--              fonts.googleapis.com is refused: the target is not in the tier
--   5 NOSNI    on the assets port, with NO SNI squid judges the CONNECT target:
--              no-SNI to fonts.googleapis.com passes, no-SNI to pypi.org is
--              refused (measured: --client-requested falls back to the target)
--   6 TIER2    on the registries port (3130), CONNECT pypi.org completes
--   7 UNION    port 3128 still serves the union: pypi.org and
--              fonts.googleapis.com both complete
-- Arms 3 and 4 are the two directions of a name mismatch. Whether the SNI
-- RESOLVES to the CONNECT address is 2041-8azp, not this test.
--
-- Network: it connects only to allowlisted hosts (fonts.googleapis.com,
-- pypi.org) and the deliberate refusals above. It uses no credentials: the CA
-- is generated for this run and deleted after it. Operator consent (standing,
-- 2026-11-08, via coordinator macuahuitl-fedora): throwaway proxy test
-- containers on lenovinha for the per-tier tests.
-- Cleanup removes ONLY the container this run started (by ID) and the image
-- tag it built (by exact name).
--
-- Usage: tillandsias-plan script run scripts/lua/test-proxy-tier-ports-live.lua
-- Verdict: ok:proxy-tier-ports-live:8 arms | violation:proxy-tier-ports-live:<n>-failed
--          | could-not-run:proxy-tier-ports-live:<why>

local NAME = "proxy-tier-ports-live"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
for _, tool in ipairs({ "podman", "openssl" }) do
    if proc.run({ argv = { tool, "--version" } }).code ~= 0 and proc.run({ argv = { tool, "version" } }).code ~= 0 then
        verdict.could_not_run(NAME, tool .. " is not on this host")
    end
end

local STAMP = tostring(time.now_ms())
local TAG = "localhost/tillandsias-proxy:tier-ports-test-" .. STAMP
local REL = "target/plan-scratch/proxy-tier-ports-" .. STAMP
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local cid = ""
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else out.line("FAIL: " .. name .. " — got: " .. tostring(got)); failed[#failed + 1] = name end
end
local function cleanup()
    if cid ~= "" then proc.run({ argv = { "podman", "rm", "-f", "-t", "2", cid }, timeout_ms = 60000 }) end
    proc.run({ argv = { "podman", "rmi", TAG }, timeout_ms = 60000 })
    proc.run({ argv = { "rm", "-rf", ABS } })
end
local function bail(why) cleanup(); verdict.could_not_run(NAME, why) end

-- a throwaway CA for this run only
fs.mkdir(REL)
local ca = proc.run({ argv = { "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-subj", "/CN=tillandsias-tier-ports-test-ca", "-addext", "basicConstraints=critical,CA:TRUE",
    "-addext", "keyUsage=critical,keyCertSign,cRLSign",
    "-keyout", ABS .. "/ca.key", "-out", ABS .. "/ca.crt" }, timeout_ms = 60000 })
if ca.code ~= 0 then bail("openssl could not make a throwaway CA: " .. (ca.stderr or "")) end
proc.run({ argv = { "chmod", "0644", ABS .. "/ca.key", ABS .. "/ca.crt" } })

-- build
local b = proc.run({ argv = { "podman", "build", "-q", "-t", TAG, "-f", ROOT .. "/images/proxy/Containerfile",
    ROOT .. "/images/proxy" }, timeout_ms = 900000 })
if b.code ~= 0 then bail("podman build failed: " .. (b.stderr or ""):sub(-400)) end

-- 0 PARSE (standalone, before the run: the generated include must load)
local parse = proc.run({ argv = { "podman", "run", "--rm", "--entrypoint", "sh",
    "-v", ABS .. "/ca.crt:/etc/squid/certs/intermediate.crt:ro,Z",
    "-v", ABS .. "/ca.key:/etc/squid/certs/intermediate.key:ro,Z",
    TAG, "-c", "squid -k parse 2>&1; echo rc=$?" }, timeout_ms = 120000 })
local ptxt = (parse.stdout or "") .. (parse.stderr or "")
arm("0 PARSE squid -k parse accepts squid.conf with the generated tier-ports include",
    ptxt:find("rc=0", 1, true) ~= nil and ptxt:find("FATAL", 1, true) == nil
        and ptxt:find("tier-ports.conf", 1, true) ~= nil,
    ptxt:sub(-600))

-- run (ports on 127.0.0.1 only)
local runv = { "podman", "run", "-d", "--rm",
    "-v", ABS .. "/ca.crt:/run/secrets/tillandsias-ca-cert:ro,Z",
    "-v", ABS .. "/ca.key:/run/secrets/tillandsias-ca-key:ro,Z" }
local PORTS = { 3128, 3130, 3131 }
local HOSTPORT = {}
for i, p in ipairs(PORTS) do
    HOSTPORT[p] = 43000 + (tonumber(STAMP:sub(-3)) % 500) * 4 + i
    runv[#runv + 1] = "-p"
    runv[#runv + 1] = "127.0.0.1:" .. HOSTPORT[p] .. ":" .. p
end
runv[#runv + 1] = TAG
local r = proc.run({ argv = runv, timeout_ms = 120000 })
cid = text.trim(r.stdout or "")
if r.code ~= 0 or cid == "" then bail("podman run failed: " .. (r.stderr or "")) end
-- wait for squid on the tier port
local up = false
for _ = 1, 60 do
    local lg = proc.run({ argv = { "podman", "logs", cid }, timeout_ms = 10000 })
    local all = (lg.stdout or "") .. (lg.stderr or "")
    if all:find("Accepting SSL bumped HTTP Socket connections at conn%d+ local=%[::%]:3131")
        or all:find("Accepting SSL bumped HTTP Socket connections at.-3131") then up = true; break end
    if all:find("FATAL", 1, true) then bail("squid FATAL at start: " .. all:sub(-600)) end
    proc.run({ argv = { "sleep", "1" } })
end
if not up then
    local lg = proc.run({ argv = { "podman", "logs", cid }, timeout_ms = 10000 })
    bail("squid never listened on 3131: " .. ((lg.stdout or "") .. (lg.stderr or "")):sub(-600))
end

-- one handshake through the proxy. It counts as OK only when a certificate
-- came back that the PROXY did not mint: a refusal must never look like a
-- handshake, and a bumped error page is signed by the run's own test CA.
local function hs(port, target, sni)
    local argv = { "openssl", "s_client", "-proxy", "127.0.0.1:" .. HOSTPORT[port],
        "-connect", target .. ":443", "-brief" }
    if sni then argv[#argv + 1] = "-servername"; argv[#argv + 1] = sni else argv[#argv + 1] = "-noservername" end
    local s = proc.run({ argv = argv, stdin = "", timeout_ms = 30000 })
    local txt = (s.stdout or "") .. (s.stderr or "")
    local ok = (txt:find("Peer certificate:", 1, true) ~= nil or txt:find("CONNECTION ESTABLISHED", 1, true) ~= nil)
        and txt:find("tillandsias-tier-ports-test-ca", 1, true) == nil
    return ok, txt:gsub("\n", " | "):sub(1, 300)
end

-- Readiness: squid logs its listening sockets before the first bumped
-- connection can be served (measured: the very first handshake came back
-- empty). Probe the UNION port, not the arm under test, up to 20s, so no arm
-- is retried and a real refusal cannot be hidden by a retry.
local ready = false
for _ = 1, 10 do
    if hs(3128, "fonts.googleapis.com", "fonts.googleapis.com") then ready = true; break end
    proc.run({ argv = { "sleep", "2" } })
end
if not ready then bail("the proxy never served a handshake on 3128 within 20s") end

local ok, txt = hs(3131, "fonts.googleapis.com", "fonts.googleapis.com")
arm("1 ALLOW assets port: CONNECT fonts.googleapis.com with its own SNI completes", ok, txt)
ok, txt = hs(3131, "pypi.org", "pypi.org")
arm("2 OFFTIER assets port: CONNECT pypi.org (registries tier) is refused", not ok, txt)
ok, txt = hs(3131, "fonts.googleapis.com", "pypi.org")
arm("3 SNI-OFF assets port: an allowed target carrying off-tier SNI pypi.org is refused", not ok, txt)
ok, txt = hs(3131, "pypi.org", "fonts.googleapis.com")
arm("4 DST-OFF assets port: off-tier target pypi.org carrying an allowed SNI is refused", not ok, txt)
local okn1, tn1 = hs(3131, "fonts.googleapis.com", nil)
local okn2, tn2 = hs(3131, "pypi.org", nil)
arm("5 NOSNI assets port, no SNI: an in-tier target passes and an off-tier target is refused",
    okn1 and not okn2, tn1 .. " || " .. tn2)
ok, txt = hs(3130, "pypi.org", "pypi.org")
arm("6 TIER2 registries port: CONNECT pypi.org completes", ok, txt)
local ok1, t1 = hs(3128, "pypi.org", "pypi.org")
local ok2, t2 = hs(3128, "fonts.googleapis.com", "fonts.googleapis.com")
arm("7 UNION port 3128 still serves the union (pypi.org and fonts.googleapis.com)", ok1 and ok2, t1 .. " || " .. t2)

cleanup()
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
