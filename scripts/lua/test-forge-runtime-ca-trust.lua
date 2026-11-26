-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_FORGE_IMAGE
-- @trace spec:transparent-https-caching, order:1495-p7ek, order:2368-efqj
--
-- test-forge-runtime-ca-trust.lua — a rootless forge trusts the runtime proxy CA through
-- the SYSTEM defaults: curl, git and node reach a TLS server signed by it with no per-tool
-- CA override. A malformed CA fails startup by name; with none the stock bundle stands.
-- Ported from the .sh (2368-efqj). Host tools only: openssl, gcc, git, curl; node runs in
-- the forge.
--
-- Verdict: ok:forge-runtime-ca-trust:<n> arms | violation:forge-runtime-ca-trust:<n>-failed
--        | refused:forge-runtime-ca-trust:<why>

local fixture = require "common.fixture"
local forge = require "common.forge_image"
local T = fixture.new("forge-runtime-ca-trust")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local IMAGE = forge.pick(T)
if not IMAGE then T:refuse("no-forge-image", "no tillandsias-forge image available (need one build first)") end
for _, c in ipairs{ "openssl", "gcc", "git", "curl", "ss" } do if not fixture.which(c) then T:refuse("host-command-absent", c) end end
local W = T:scratch()
local D = W.abs
for _, p in ipairs{ "seed", "web", "home" } do fs.mkdir(W.rel .. "/" .. p) end

T:must{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=Tillandsias Runtime Test CA",
    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", D .. "/ca.key", "-out", D .. "/ca.crt" }
T:must{ "openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1", "-keyout", D .. "/server.key", "-out", D .. "/server.csr" }
fs.write(W.rel .. "/server.ext", "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n")
T:must{ "openssl", "x509", "-req", "-days", "1", "-in", D .. "/server.csr", "-CA", D .. "/ca.crt", "-CAkey", D .. "/ca.key", "-CAcreateserial",
    "-extfile", D .. "/server.ext", "-out", D .. "/server.crt" }
local function git(...)
    local argv = { "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.env, argv.env_unset = { HOME = D .. "/home", GIT_CONFIG_NOSYSTEM = "1" }, { "GIT_*" }
    return T:must(argv)
end
git("init", "-q", D .. "/seed")
fs.write(W.rel .. "/seed/README", "runtime trust\n")
git("-C", D .. "/seed", "add", "README"); git("-C", D .. "/seed", "commit", "-qm", "initial")
git("clone", "-q", "--bare", D .. "/seed", D .. "/web/upstream.git")
git("--git-dir=" .. D .. "/web/upstream.git", "update-server-info")
T:must{ "gcc", "-O2", "-o", D .. "/tls-server", ROOT .. "/scripts/tls-test-server.c", "-lssl", "-lcrypto" }

-- ss exits 0 when nothing matches, so the OUTPUT says whether a port is free.
local port
for p = 49152, 65535 do
    local r = T:run{ "ss", "-tlnH", "sport = :" .. p }
    if r.code == 0 and text.trim(r.stdout or "") == "" then port = p; break end
end
if not port then T:refuse("no-free-port") end

local PROBE = [[
source /usr/local/lib/tillandsias/lib-common.sh
for name in GIT_SSL_CAINFO SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS; do
    if test -n "${!name:-}"; then echo "override=$name"; fi
done
echo "node_system_ca=${NODE_USE_SYSTEM_CA:-}"
echo "certs=$(grep -c "BEGIN CERTIFICATE" /etc/ssl/cert.pem)"
url="https://127.0.0.1:$PORT"
if curl -fsS "$url/upstream.git/HEAD" >/dev/null; then echo curl=ok; fi
if git ls-remote "$url/upstream.git" HEAD >/dev/null; then echo git=ok; fi
if command -v node >/dev/null; then echo has_node=yes; fi
if node -e "fetch(process.argv[1]).then(r => { if (!r.ok) throw Error(String(r.status)); return r.text(); }).catch(e => { console.error(e); process.exit(1); })" "$url/upstream.git/HEAD"; then echo node=ok; fi
]]
-- The server lives exactly as long as this one shell, which runs the container beside it.
local argv = { SH, D .. "/serve.sh", "podman", "run", "--rm", "--network=host" }
for _, a in ipairs(forge.HARDENED) do argv[#argv + 1] = a end
for _, a in ipairs{ "--env", "HTTP_PROXY=", "--env", "HTTPS_PROXY=", "--env", "ALL_PROXY=", "--env", "NO_PROXY=127.0.0.1,localhost", "--env", "PORT=" .. port,
    "--mount", "type=bind,source=" .. D .. "/ca.crt,target=/run/tillandsias/ca-chain.crt,readonly=true", "--entrypoint", "/bin/bash", IMAGE, "-euc", PROBE } do argv[#argv + 1] = a end
fs.write(W.rel .. "/serve.sh", [[
"$D/tls-server" "$D/web" "$D/server.crt" "$D/server.key" "$PORT" >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null; wait "$server" 2>/dev/null' EXIT
i=0
until curl --noproxy '*' --cacert "$D/ca.crt" -fsS "https://127.0.0.1:$PORT/upstream.git/HEAD" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 40 ] || { echo "ready=no"; exit 3; }
    sleep 0.1
done
"$@"
]])
argv.env, argv.timeout_ms = { D = D, PORT = tostring(port) }, 180000
local r = T:run(argv)
local f = {}
for k, v in (r.stdout or ""):gmatch("([%w_]+)=([^\n]*)\n") do f[k] = v end
if f.ready == "no" then T:refuse("tls-server-not-ready") end
local raw = "rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):gsub("\n", " | ")
T:arm("no per-tool CA override is set", r.code ~= nil and f.certs ~= nil and f.override == nil, raw)
T:arm("node is told to use the system CA", f.node_system_ca == "1", raw)
T:arm("the system bundle holds the stock certificates", (tonumber(f.certs or "") or 0) > 2, raw)
T:arm("curl reaches the server through the system bundle", f.curl == "ok", raw)
T:arm("git reaches the server through the system bundle", f.git == "ok", raw)
T:arm("the forge image carries node (1495-p7ek)", f.has_node == "yes", raw)
T:arm("node reaches the server through the system bundle", f.node == "ok", raw)

fs.write(W.rel .. "/malformed-ca.crt", "not a certificate\n")
r = forge.run(T, IMAGE, { "--mount", "type=bind,source=" .. D .. "/malformed-ca.crt,target=/run/tillandsias/ca-chain.crt,readonly=true" }, "source /usr/local/lib/tillandsias/lib-common.sh")
local o = (r.stdout or "") .. (r.stderr or "")
T:arm("a malformed runtime CA fails startup by name", r.code ~= 0 and o:find("[trust] ERROR: runtime proxy CA is not a PEM certificate", 1, true), "rc=" .. tostring(r.code) .. " " .. o)
r = forge.run(T, IMAGE, {}, 'source /usr/local/lib/tillandsias/lib-common.sh\ntest "$(grep -c "BEGIN CERTIFICATE" /etc/ssl/cert.pem)" -gt 2')
T:arm("with no runtime CA the stock bundle stands", r.code == 0, "rc=" .. tostring(r.code) .. " " .. (r.stderr or ""))
T:finish()
