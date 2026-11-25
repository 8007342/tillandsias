-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_DNS_FIXTURE_NET
-- @trace spec:git-mirror-service, order:659-8faj, order:2368-efqj
--
-- test-git-mirror-dns-identity.lua — two projects' mirrors have two DNS identities. Before
-- 659-8faj every mirror took the same two network aliases, and podman's resolver answered
-- either: cross-project, non-deterministic routing. Two plain containers carry the
-- product's exact name, hostname and alias args; DNS is the whole mechanism. Ported from
-- the .sh (2368-efqj).
--
--   1 each git-<project> returns exactly ONE address, and the two differ
--   2 the retired shared aliases (tillandsias-git git-service) do not resolve
-- Probed with getent ahostsv4, NEVER the BIND lookup tool: that one fails against the
-- podman resolver with "Message too large", which reads as NXDOMAIN. A pre-659 mirror still
-- attached to the default network moves the run to a dedicated one.
--
-- Usage: script run scripts/lua/test-git-mirror-dns-identity.lua [-- <image>]
-- Verdict: ok:git-mirror-dns-identity:<n> arms | violation:git-mirror-dns-identity:<n>-failed
--        | refused:git-mirror-dns-identity:<why>

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-dns-identity")
local IMAGE = (arg or {})[1] or "localhost/tillandsias-git:v" .. text.trim(fs.read("VERSION"))
local NET = env.get("TILLANDSIAS_DNS_FIXTURE_NET")
if not NET or NET == "" then NET = "tillandsias-enclave" end
local A, B = "dnsfixa", "dnsfixb"
local created
if not fixture.which("podman") then T:refuse("no-podman") end
if T:run{ "podman", "image", "exists", IMAGE }.code ~= 0 then T:refuse("no-image", IMAGE) end

local function remove() T:run{ "podman", "rm", "-f", "tillandsias-git-" .. A, "tillandsias-git-" .. B } end
local function close()
    remove()
    if created then T:run{ "podman", "network", "rm", created } end
end
local function need_net()
    if T:run{ "podman", "network", "exists", NET }.code == 0 then return end
    if T:run{ "podman", "network", "create", "--internal", NET }.code ~= 0 then close(); T:refuse("no-network", NET) end
    created = NET
end
local function resolve(name)
    local r = T:run{ "podman", "run", "--rm", "--network", NET, "--entrypoint", "/usr/bin/getent", IMAGE, "ahostsv4", name }
    if r.code == 125 or r.code == 126 or r.code == 127 or r.code == nil then
        close()
        T:refuse("probe-did-not-run", "rc=" .. tostring(r.code) .. " " .. (r.stderr or ""))
    end
    local seen, list = {}, {}
    for a in (r.stdout or ""):gmatch("(%S+)[^\n]*") do if not seen[a] then seen[a] = true; list[#list + 1] = a end end
    return list
end
local SHARED = { "tillandsias-git", "git-service" }

need_net()
if #resolve(SHARED[1]) + #resolve(SHARED[2]) > 0 then
    out.line("note: a pre-659 shared mirror alias already resolves on " .. NET .. " (a stale container); using a dedicated network")
    NET = "tillandsias-git-dns-fixture"
    need_net()
end
remove()
for _, p in ipairs{ A, B } do
    local r = T:run{ "podman", "run", "-d", "--rm", "--name", "tillandsias-git-" .. p, "--hostname", "git-" .. p, "--network-alias", "git-" .. p,
        "--network", NET, "--entrypoint", "/bin/sleep", IMAGE, "300" }
    if r.code ~= 0 then close(); T:refuse("mirror-did-not-start", r.stderr) end
end
local a, b = resolve("git-" .. A), resolve("git-" .. B)
local s1, s2 = resolve(SHARED[1]), resolve(SHARED[2])
close()
T:arm("1 git-" .. A .. " has exactly one address", #a == 1, table.concat(a, " "))
T:arm("1 git-" .. B .. " has exactly one address", #b == 1, table.concat(b, " "))
T:arm("1 the two projects resolve to different addresses", a[1] and b[1] and a[1] ~= b[1], tostring(a[1]) .. " / " .. tostring(b[1]))
T:arm("2 the retired shared alias tillandsias-git does not resolve", #s1 == 0, table.concat(s1, " "))
T:arm("2 the retired shared alias git-service does not resolve", #s2 == 0, table.concat(s2, " "))
T:finish()
