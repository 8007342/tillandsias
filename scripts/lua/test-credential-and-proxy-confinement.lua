-- @env PATH HOME
-- @trace order:1118-bscs, order:2320-b5vv
--
-- test-credential-and-proxy-confinement.lua — a push token goes to GitHub over https or
-- nowhere, and the permissive proxy port is not reachable from the enclave. Ported from the
-- .sh of the same name (2320-b5vv). The helper answered any host, on an assumption about its
-- caller; 3129 had no bind address and no ACL.
--
-- The credential arms EXECUTE the helper with a stubbed vault-cli, so no real token is
-- involved. The proxy arms read the shipped config: a bind address is static.
--
-- Usage: tillandsias-plan script run scripts/lua/test-credential-and-proxy-confinement.lua
-- Verdict: ok:credential-and-proxy-confinement:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("credential-and-proxy-confinement")
local SH = fixture.posix_shell()
local d = T:scratch()
local MARK = "TOKEN-MARKER-1118-bscs"
fs.mkdir(d.rel .. "/bin")
fs.write(d.rel .. "/bin/vault-cli", "#!/bin/sh\necho " .. MARK .. "\n")
fs.write(d.rel .. "/helper.sh", fs.read("images/git/git-credential-tillandsias.sh"))
fs.write(d.rel .. "/run.sh", 'chmod +x bin/vault-cli\nPATH="$PWD/bin:$PATH"\nexec bash helper.sh get\n')

-- A request as git sends it; a nil host sends no host= line at all.
local function ask(host, protocol)
    local req = "protocol=" .. (protocol or "https") .. "\n" .. (host and "host=" .. host .. "\n" or "") .. "path=x.git\n\n"
    local r = T:run{ SH, d.abs .. "/run.sh", cwd = d.abs, stdin = req, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    return r.code, (r.stdout or ""), "rc=" .. tostring(r.code) .. " [" .. (r.stdout or "") .. "] " .. (r.stderr or "")
end
local function served(name, host)
    local rc, o, why = ask(host)
    T:arm(name, rc == 0 and text.contains(o, "password=" .. MARK), why)
end
-- Refused BY THE HELPER, naming its rule: an empty answer alone could be a helper that died.
local function refused(name, host, protocol)
    local rc, o, why = ask(host, protocol)
    T:arm(name, rc == 1 and o == "" and text.contains(why, "1118-bscs"), why)
end
served("1 github.com over https still receives the token", "github.com")
refused("2 an arbitrary host receives nothing", "evil.example.com")
for _, h in ipairs{ "evil-github.com", "github.com.attacker.net", "notgithub.com" } do
    refused("3 " .. h .. " receives nothing: the match is whole-string", h)
end
refused("4 a request with no host= fails closed", nil)
refused("5 the token is https-only", "github.com", "http")

local ports = {}
for l in (fs.read("images/proxy/squid.conf") .. "\n"):gmatch("([^\n]*)\n") do
    if l:find("^http_port") then ports[#ports + 1] = l end
end
local all, open3129, loop, strict = table.concat(ports, " | "), 0, 0, 0
for _, l in ipairs(ports) do
    if l:find("^http_port%s+127%.0%.0%.1:3129%f[%D]") then loop = loop + 1
    elseif l:find("3129") then open3129 = open3129 + 1 end
    if l:find("^http_port%s+3128%f[%D]") then strict = strict + 1 end
end
T:arm("6 the permissive port 3129 is bound to loopback and nowhere else", loop == 1 and open3129 == 0, all)
T:arm("7 CONTROL the strict port 3128 still binds for the enclave", strict == 1, all)
T:finish()
