-- @env PATH HOME
-- @trace order:995-srbf, order:2378-hcxg
--
-- test-credential-verdict-script.lua — the credential verdict script embedded in remote_projects.rs
-- tells a refused token from an unreachable API. Ported from the .sh of the same name (2378-hcxg). The
-- script is cut from the Rust source; vault-cli and gh are stubs.
--
-- Usage: tillandsias-plan script run scripts/lua/test-credential-verdict-script.lua
-- Verdict: ok:credential-verdict-script:<n> arms | violation:...

local fixture = require "common.fixture"
local bus = require "common.privatebus"
local T = fixture.new("credential-verdict-script")
local SH = fixture.posix_shell()
local body = ("\n" .. fs.read("crates/tillandsias-headless/src/remote_projects.rs"):gsub("\r", "")):match('\nconst CREDENTIAL_VERDICT_SCRIPT[^\n]*\n(.-)\n"#;')
if not body or body == "" then T:refuse("script-not-found") end
local function verdict_(vrc, token, grc, login, err)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin")
    fs.write(d.rel .. "/verdict.sh", body .. "\n")
    fs.write(d.rel .. "/bin/vault-cli", "#!/bin/sh\nprintf '%s' '" .. token .. "'\nexit " .. vrc .. "\n")
    fs.write(d.rel .. "/bin/gh", "#!/bin/sh\nprintf '%s\\n' '" .. login .. "'\nprintf '%s\\n' '" .. err .. "' >&2\nexit " .. grc .. "\n")
    T:must{ "chmod", "+x", d.abs .. "/bin/vault-cli", d.abs .. "/bin/gh" }
    local r = proc.run{ argv = { SH, "-s", "--", d.abs }, cwd = d.abs, stdin = 'export PATH="$1/bin:$PATH"\nexec sh "$1/verdict.sh" </dev/null\n', env = bus.env{ HOME = d.abs }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    return (r.stdout or ""):match("verdict=([a-z]+)"), (r.stdout or "") .. (r.stderr or "")
end
for _, c in ipairs{ { "a token the API accepts", "valid", 0, "ghp_live", 0, "octocat", "" }, { "a 401", "invalid", 0, "ghp_expired", 1, "", "gh: HTTP 401: Bad credentials (https://api.github.com/user)" },
    { "a 403", "invalid", 0, "ghp_blocked", 1, "", "gh: HTTP 403: Forbidden" }, { "an empty token", "invalid", 0, "", 0, "octocat", "" },
    { "a network failure", "unreachable", 0, "ghp_live", 1, "", "dial tcp: lookup api.github.com: no such host" }, { "a vault read failure", "unreachable", 1, "", 0, "octocat", "" }, { "an empty login", "unreachable", 0, "ghp_live", 0, "", "" } } do
    local got, why = verdict_(table.unpack(c, 3))
    T:arm(c[1] .. " is " .. c[2], got == c[2], tostring(got) .. " " .. why:sub(1, 300))
end
T:finish()
