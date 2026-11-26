-- @trace spec:forge-git-identity-anonymization, order:1453-7rzd, order:1668-8jmq, order:2344-zk8r
--
-- test-forge-git-identity-source.lua — the forge's git identity is the GitHub App login
-- plus the host and a per-forge tillandsia name, WRITTEN as git config, never exported
-- as GIT_AUTHOR_*/GIT_COMMITTER_*; every commit carries a Tillandsias-Host trailer the
-- fleet's host attribution reads. Ported from the .sh (2344-zk8r).
--
-- The functions under test are EXTRACTED from the real images/default/lib-common.sh
-- (its top level runs the forge's start-up), and run with a scratch HOME from a scratch
-- dir git cannot look above: run from the repo root, an earlier fixture wrote a host
-- identity into lenovinha's real .git/config and 37 trunk commits went out under it.
--
--   1 LAUNCHER  no forge arg builder passes GIT_* or reads the host gitconfig, with a
--               negative control. Rust unit tests cover the composed values
--   2 CONFIG    App user and host and species land as config; an older launcher's
--               exported identity is gone; the species is stable
--   3 SCRATCH   a scratch repo's own -c identity wins
--   4 TRAILER   the installed hook writes Tillandsias-Host; fleet-activity.sh reads it
--   5 NEGATIVE  no identity passed: nothing configured, no exported identity survives
--   6 the real checkout's local user.*/hooksPath config is unchanged
--   7 READ-ONLY ~/.gitconfig (the lanes bind-mount it): the identity still lands and the
--               mounted file is still read. A planted lock refuses the write as root too
--
-- Verdict: ok:forge-git-identity-source:<n> arms | violation:forge-git-identity-source:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-git-identity-source")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()

local function lines(s)
    local t = {}
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end

-- 1
local main = fs.read("crates/tillandsias-headless/src/main.rs")
local function builders_clean(src)
    local p, n, signature = false, 0, false
    for _, l in ipairs(lines(src)) do
        if l:find("^fn append_git_identity_env_args%(") or l:find("^fn forge_git_identity_env%(")
            or l:find("^pub%(crate%) fn forge_git_identity_env%(") then p = true; n = n + 1 end
        if l:find("fn append_git_identity_env_args(args: &mut Vec<String>, project_name: &str)", 1, true) == 1 then signature = true end
        if p and (l:find('"GIT_AUTHOR_', 1, true) or l:find('"GIT_COMMITTER_', 1, true) or l:find("read_git_identity_defaults", 1, true)) then return false end
        if l:find("^}") then p = false end
    end
    return signature and n == 2
end
T:arm("1 the identity carrier passes TILLANDSIAS_GIT_* only and reads no host gitconfig", builders_clean(main), "a forge arg builder exports GIT_*, reads read_git_identity_defaults, or moved")
local planted, np = main:gsub('%("TILLANDSIAS_GIT_NAME", name%),', '("GIT_AUTHOR_NAME", name),')
T:arm("1 NEGATIVE CONTROL planting GIT_AUTHOR_NAME in the carrier is caught", np > 0 and not builders_clean(planted), "planted " .. np)

-- The functions under test, with lib-common's helpers stubbed.
local lib = lines(fs.read("images/default/lib-common.sh"))
local prog = { "trace_lifecycle() { :; }", "ensure_forge_git_index() { :; }", "_install_expert_refresh_hook() { :; }" }
for _, name in ipairs{ "TILLANDSIA_SPECIES", "forge_tillandsia_species", "_install_agent_trailer_hook", "configure_git_identity" } do
    local p = false
    for _, l in ipairs(lib) do
        if l:sub(1, #name + 2) == name .. "=(" or l:sub(1, #name + 4) == name .. "() {" then p = true end
        if p then
            prog[#prog + 1] = l
            if l == "}" or l == ")" then break end
        end
    end
    if not p then T:refuse("no-subject", name .. " not found in images/default/lib-common.sh") end
end
prog = table.concat(prog, "\n") .. "\n"

local function facts(name, body, extra)
    fs.mkdir(W.rel .. "/home-" .. name)
    fs.write(W.rel .. "/" .. name .. ".sh", prog .. body)
    local e = { HOME = W.abs .. "/home-" .. name, GIT_CONFIG_NOSYSTEM = "1", GIT_CEILING_DIRECTORIES = W.abs:match("^(.*)/"), ROOT = ROOT, W = W.abs }
    for k, v in pairs(extra) do e[k] = v end
    local r = T:run{ SH, W.abs .. "/" .. name .. ".sh", cwd = W.abs, env = e, timeout_ms = 60000,
        env_unset = { "TILLANDSIAS_*", "XDG_CONFIG_HOME", "GIT_*" } }
    local f = { raw = "rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):gsub("\n", " | ") }
    for k, v in (r.stdout or ""):gmatch("([%w_]+)=([^\n]*)\n") do f[k] = v end
    return f
end
local function app(t)
    t.TILLANDSIAS_GIT_NAME = "App User"; t.TILLANDSIAS_GIT_EMAIL = "7+appuser@users.noreply.github.com"
    t.TILLANDSIAS_GIT_HOST = "lenovinha"; t.TILLANDSIAS_GIT_IDENTITY_SOURCE = "github-app"
    return t
end
local APP_NAME = "^App User %(lenovinha · tillandsia%-.+%)"
local function real_config()
    local r = T:run{ "git", "-C", ROOT, "config", "--local", "--list" }
    local keep = {}
    for _, l in ipairs(lines(r.stdout or "")) do if l:find("^user") or l:find("^core%.hookspath") then keep[#keep + 1] = l end end
    return table.concat(keep, "\n")
end
local before = real_config()

-- 2-4
local f = facts("app", [[
configure_git_identity
echo "name=$(git config --global user.name)"
echo "email=$(git config --global user.email)"
echo "left=${GIT_AUTHOR_NAME:-}${GIT_COMMITTER_NAME:-}${GIT_AUTHOR_EMAIL:-}${GIT_COMMITTER_EMAIL:-}"
echo "s1=$(forge_tillandsia_species)"
echo "s2=$(forge_tillandsia_species)"
git init -q "$W/repo" && cd "$W/repo" || exit 1
echo a >a; git add a; git -c user.name=fixture -c user.email=f@x commit -q -m scratch
echo "author=$(git log -1 --format='%an <%ae>')"
echo b >b; git add b; git commit -q -m "through the hook"
echo "trailer=$(git log -1 --format='%(trailers:key=Tillandsias-Host,valueonly)' | tr -d '[:space:]')"
mkdir -p scripts; cp "$ROOT/scripts/fleet-activity.sh" scripts/
echo "activity=$(bash scripts/fleet-activity.sh --ref HEAD --since '1.day' 2>&1 | tr '\n' '|')"
]], app{ GIT_AUTHOR_NAME = "Host Person", GIT_AUTHOR_EMAIL = "host@example.test", GIT_COMMITTER_NAME = "Host Person", GIT_COMMITTER_EMAIL = "host@example.test" })
T:arm("2 user.name is config, with host and species", (f.name or ""):find(APP_NAME .. "$"), f.raw)
T:arm("2 user.email is config", f.email == "7+appuser@users.noreply.github.com", f.raw)
T:arm("2 no GIT_* identity is left exported", f.left == "", f.raw)
T:arm("2 the species is stable for the forge's life", (f.s1 or "") ~= "" and f.s1 == f.s2, f.raw)
T:arm("3 a scratch repo's own -c identity wins", f.author == "fixture <f@x>", f.raw)
T:arm("4 the hook wrote Tillandsias-Host", f.trailer == "lenovinha", f.raw)
T:arm("4 fleet-activity.sh attributes the noreply commit to the host", ("|" .. (f.activity or "")):find("|%s*lenovinha%s"), f.raw)

f = facts("none", [[
configure_git_identity
echo "name=$(git config --global user.name 2>/dev/null)"
echo "left=${GIT_AUTHOR_NAME:-}"
]], { GIT_AUTHOR_NAME = "Host Person", GIT_AUTHOR_EMAIL = "host@example.test" })
T:arm("5 NEGATIVE with no identity passed nothing is configured and the exported one is gone", f.name == "" and f.left == "", f.raw)

f = facts("ro", [[
printf '[tillandsias]\n\tmounted = yes\n' > "$HOME/.gitconfig"
: > "$HOME/.gitconfig.lock"
git config --global user.name probe 2>/dev/null && echo "premise=broken"
configure_git_identity
git init -q "$W/repo-ro" && cd "$W/repo-ro" || exit 1
echo "ident=$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed 's/ [0-9]* [-+][0-9]*$//')"
echo "mounted=$(git config --global --get tillandsias.mounted)"
]], app{})
T:arm("7 with ~/.gitconfig unwritable the identity still lands", not f.premise
    and (f.ident or ""):find(APP_NAME .. " <7%+appuser@users%.noreply%.github%.com>$"), f.raw)
T:arm("7 the mounted ~/.gitconfig is still read", f.mounted == "yes", f.raw)

T:arm("6 the real checkout's local user.*/hooksPath config is unchanged", real_config() == before, real_config())
T:finish()
