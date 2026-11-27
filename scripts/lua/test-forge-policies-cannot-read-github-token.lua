-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace spec:tillandsias-vault, order:2357-5quw
--
-- test-forge-policies-cannot-read-github-token.lua — no forge lane's vault policy reaches the
-- GitHub token. A real vault answers: `vault server -dev` in one throwaway container with no
-- network, its own fixture secrets, and this tree's images/vault/policies. The host's vault is
-- never asked and nothing is written to it.
--
-- The unit test beside Policy::Forge reads the TEXT of forge.hcl, so a `secret/*` read path,
-- which names no token, passes it; arm 6 is that policy.
--
--   1 PREMISE every policy in the tree was asked      2 every forge lane: read is denied
--   3 so are its metadata and an overwrite            4 CONTROL git-mirror reads it
--   5 CONTROL forge reads proxy-cert (the denial is path-specific)
--   6 RED a planted policy granting secret/* reads it 7 RED one granting the path does
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-policies-cannot-read-github-token.lua
-- Verdict: ok:forge-policies-cannot-read-github-token:<n> arms | violation:... | skip:...:no-vault-image

local fixture = require "common.fixture"
local T = fixture.new("forge-policies-cannot-read-github-token")
local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
local function podman(stdin, ...)
    return proc.run{ argv = { "podman", ... }, stdin = stdin, env = E, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
end
local imgs = podman("", "images", "--format", "{{.Repository}}:{{.Tag}}")
-- A podman that does not answer is not an absent image.
if imgs.code ~= 0 then T:refuse("podman-did-not-answer", "rc=" .. tostring(imgs.code) .. " " .. (imgs.stderr or "")) end
local list = "\n" .. (imgs.stdout or "")
local IMG = list:match("\n(localhost/tillandsias%-vault:v[^\n]*)") or list:match("\n(docker%.io/hashicorp/vault:[^\n]*)")
if not IMG then T:skip("no-vault-image") end
out.line("image: " .. IMG)

local d = T:scratch()
fs.mkdir(d.rel .. "/p")
local names, lanes = {}, {}
for _, f in ipairs(fs.list("images/vault/policies")) do
    local n = f:match("([^/]+)%.hcl$")
    if n then
        fs.write(d.rel .. "/p/" .. n .. ".hcl", fs.read("images/vault/policies/" .. n .. ".hcl"))
        names[#names + 1] = n
        if n == "forge" or n:match("%-forge$") then lanes[#lanes + 1] = n end
    end
end
table.sort(lanes)
local function planted(n, body) fs.write(d.rel .. "/p/" .. n .. ".hcl", body) end
planted("planted-wildcard", 'path "secret/*" {\n  capabilities = ["read"]\n}\n')
planted("planted-path", 'path "secret/data/github/token" {\n  capabilities = ["read"]\n}\n')
local ASK = [==[
export HOME=/tmp VAULT_ADDR=http://127.0.0.1:8200 VAULT_DEV_ROOT_TOKEN_ID=fixture-root
vault server -dev -dev-no-store-token -dev-listen-address=127.0.0.1:8200 >/tmp/server.log 2>&1 &
i=0; until vault status >/dev/null 2>&1; do i=$((i + 1)); [ $i -lt 100 ] || { echo no-server; tail -n 5 /tmp/server.log; exit 9; }; sleep 0.2; done
export VAULT_TOKEN=fixture-root
vault kv put secret/github/token value=FIXTURE >/dev/null && vault kv put secret/ca/proxy-cert value=FIXTURE >/dev/null || { echo no-fixture; exit 9; }
# denied only when vault says so; any other failure is "other"
say() { if [ "$3" = 0 ]; then a=allowed; elif grep -q 'permission denied' /tmp/o; then a=denied; else a=other; fi; echo "$1 $2 $a"; }
for f in /p/*.hcl; do
    n="${f##*/}"; n="${n%.hcl}"
    vault policy write "fx-$n" "$f" >/dev/null || { echo "$n policy other"; continue; }
    t="$(vault token create -policy="fx-$n" -no-default-policy -ttl=300s -field=token)" || { echo "$n token other"; continue; }
    VAULT_TOKEN="$t" vault read secret/data/github/token >/tmp/o 2>&1; say "$n" read $?
    VAULT_TOKEN="$t" vault read secret/metadata/github/token >/tmp/o 2>&1; say "$n" metadata $?
    VAULT_TOKEN="$t" vault write secret/data/github/token - >/tmp/o 2>&1 <<J
{"data":{"value":"FIXTURE"}}
J
    say "$n" write $?
    VAULT_TOKEN="$t" vault read secret/data/ca/proxy-cert >/tmp/o 2>&1; say "$n" cert $?
done
echo asked-all
]==]
local r = podman(ASK, "run", "--rm", "-i", "--network", "none", "-v", d.abs .. "/p:/p:ro,z", "--entrypoint", "sh", IMG, "-s")
local o = (r.stdout or ""):gsub("\r", "")
if r.code ~= 0 or not text.contains(o, "asked-all") then T:refuse("vault-did-not-answer", "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400) .. (r.stderr or ""):sub(1, 400)) end
local got = {}
for n, what, a in o:gmatch("(%S+) (%S+) (%S+)\n") do got[n .. " " .. what] = a end
local function is(n, what, want) return got[n .. " " .. what] == want end
local unasked, reads, others = {}, {}, {}
for _, n in ipairs(names) do
    if got[n .. " read"] == nil or got[n .. " read"] == "other" then unasked[#unasked + 1] = n end
end
for _, n in ipairs(lanes) do
    if not is(n, "read", "denied") then reads[#reads + 1] = n .. "=" .. tostring(got[n .. " read"]) end
    for _, w in ipairs{ "metadata", "write" } do
        if not is(n, w, "denied") then others[#others + 1] = n .. " " .. w .. "=" .. tostring(got[n .. " " .. w]) end
    end
end
T:arm("1 PREMISE every policy in the tree was asked, and forge lanes are among them", #unasked == 0 and #lanes >= 2 and #names > #lanes, table.concat(unasked, " ") .. " lanes=" .. #lanes .. " of " .. #names)
T:arm("2 no forge lane reads the GitHub token", #reads == 0, table.concat(reads, " "))
T:arm("3 nor its metadata, nor overwrites it", #others == 0, table.concat(others, " "))
T:arm("4 CONTROL git-mirror reads it", is("git-mirror", "read", "allowed"), tostring(got["git-mirror read"]))
T:arm("5 CONTROL forge reads proxy-cert", is("forge", "cert", "allowed"), tostring(got["forge cert"]))
T:arm("6 RED a planted secret/* read policy is seen reading it", is("planted-wildcard", "read", "allowed"), tostring(got["planted-wildcard read"]))
T:arm("7 RED a planted policy on the path is seen reading it", is("planted-path", "read", "allowed"), tostring(got["planted-path read"]))
out.line("lanes: " .. table.concat(lanes, " "))
T:finish()
