-- @env PATH
-- @trace order:424, order:2080-zcur
--
-- test-git-credential-helper.lua — the git mirror's credential helper
-- (images/git/git-credential-tillandsias.sh) hands git the Vault token on
-- `get` and nothing else, and the relay never puts the token in a URL.
--   case 1  get returns username=oauth2 and the vault token
--   case 2  absent token fails loud with no empty password
--   case 3  store/erase are no-ops, nothing cached by git
--   case 4  relay builds a clean URL; token never enters argv
-- A stub vault-cli on PATH answers `read` with a fixed token (or nothing).
-- Ported from scripts/test-git-credential-helper.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-credential-helper.lua
-- Verdict: ok:git-credential-helper:<n> arms | violation:git-credential-helper:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("git-credential-helper")
local HELPER = fixture.repo_root() .. "/images/git/git-credential-tillandsias.sh"
local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
local PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin")
local REQ = "protocol=https\nhost=github.com\n\n"

local function stub_vault(token)
    fs.write(W.rel .. "/bin/vault-cli", '[ "$1" = "read" ] || exit 1\nprintf \'%s\' "' .. token .. '"\n')
    T:must{ "chmod", "+x", W.abs .. "/bin/vault-cli" }
end
local function helper(verb, stdin)
    return T:run{ HELPER, verb, stdin = stdin, env = { PATH = PATH } }
end
local function has_line(s, l)
    for _, x in ipairs(text.lines(s or "")) do if x == l then return true end end
    return false
end

stub_vault("ghp_example_token")
local r = helper("get", REQ)
T:arm("case 1: get returns username=oauth2 and the vault token",
    has_line(r.stdout, "username=oauth2") and has_line(r.stdout, "password=ghp_example_token"), r.stdout)
stub_vault("")
r = helper("get", REQ)
T:arm("case 2: absent token fails loud with no empty password",
    r.code ~= 0 and not (r.stdout or ""):find("password=", 1, true), "rc=" .. tostring(r.code) .. " " .. tostring(r.stdout))
stub_vault("ghp_example_token")
local s, e = helper("store", "protocol=https\n\n"), helper("erase", "protocol=https\n\n")
T:arm("case 3: store/erase are no-ops, nothing cached by git", s.code == 0 and e.code == 0,
    "store rc=" .. tostring(s.code) .. " erase rc=" .. tostring(e.code))
local relay = fs.read("images/git/relay-refs.sh") or ""
T:arm("case 4: relay builds a clean URL; token never enters argv",
    not text.is_match(relay, [[oauth2:\$\{?TOKEN]]) and relay:find('PUSH_URL="$(echo "$REMOTE_URL"', 1, true) ~= nil,
    "relay interpolates the token or no longer builds a bare push URL")
T:finish()
