-- @env PATH HOME
-- @trace order:1189-2ra5, order:1265-8qr6, order:1347-r9g8, order:1193-yw6u, order:1025-a896, order:2378-hcxg
--
-- test-credential-channel-names-a-locked-keyring.lua — check-credential-channel.sh tells a keyring
-- it cannot open from one that is absent: `missing:` invites a re-auth that evicts the fleet
-- (1025-a896). Ported from the .sh of the same name (2378-hcxg). gh and busctl are stubs, the
-- repositories scratch, and the two bare-PATH arms are built from nothing.
--
--   1 a service on the bus gh cannot open: unknown, not missing
--   2 NEGATIVE CONTROL no service: unretrievable, and no lock claim      2b no busctl at all: missing
--   3 an unlocked collection makes no lock claim   4 the remedy says unlock and forbids the re-auth
--   5 TRIPWIRE the Locked read that aborts the daemon is not back        6 gh auth status is bounded
--   7 the answer is fast    9 with no timeout(1) a healthy gh is not "no credential channel"
--
-- Usage: tillandsias-plan script run scripts/lua/test-credential-channel-names-a-locked-keyring.lua
-- Verdict: ok:locked-keyring-discriminator:<n> arms | violation:...

local fixture = require "common.fixture"
local bus = require "common.privatebus"
local T = fixture.new("locked-keyring-discriminator")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GUARD = "scripts/check-credential-channel.sh"
local ONBUS = '#!/usr/bin/env bash\ncase "$*" in\n  *--user*list*) echo "org.freedesktop.secrets 1234 gnome-keyring-daemon"; exit 0 ;;\n'
local BUSCTL = {
    locked = ONBUS .. '  *"/collection/login"*Locked*) echo "b true"; exit 0 ;;\n  *Locked*) echo "b false"; exit 0 ;;\nesac\nexit 1\n',
    unlocked = ONBUS .. '  *Locked*) echo "b false"; exit 0 ;;\nesac\nexit 1\n',
    noservice = '#!/usr/bin/env bash\necho "Failed to get property: no such service" >&2\nexit 1\n',
}
-- mode: a BUSCTL stub, or "bare" / "bare-notimeout": a PATH of the guard's tools and nothing else.
local function guard(mode, gh_rc)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/home"); fs.mkdir(d.rel .. "/repo")
    fs.write(d.rel .. "/bin/gh", "#!/usr/bin/env bash\nexit " .. (gh_rc or 1) .. "\n")
    T:must{ "chmod", "+x", d.abs .. "/bin/gh" }
    if BUSCTL[mode] then fs.write(d.rel .. "/bin/busctl", BUSCTL[mode]); T:must{ "chmod", "+x", d.abs .. "/bin/busctl" } end
    local t0 = time.now_ms()
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, ROOT .. "/" .. GUARD, mode }, cwd = d.abs, env = bus.env{ HOME = d.abs .. "/home" }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000, stdin = [==[
D="$1"; G="$2"; export GIT_CONFIG_NOSYSTEM=1 TILLANDSIAS_CCC_NO_LANE=1; unset GH_TOKEN GITHUB_TOKEN GIT_DIR GIT_WORK_TREE
cd "$D/repo" && git init -q && git config core.hooksPath .git/hooks && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m x || exit 90
case "$3" in
    bare*)
        for t in bash sh git grep sed awk cat cut tr wc head tail date mktemp dirname basename sort uniq stat env printf id hostname find xargs jq rm mkdir chmod expr timeout; do
            [ "$t" = timeout ] && [ "$3" = bare-notimeout ] && continue
            p="$(command -v "$t" 2>/dev/null)" && case "$p" in /*) ln -sf "$p" "$D/bin/$t" ;; esac
        done
        PATH="$D/bin"; hash -r
        command -v busctl >/dev/null 2>&1 && { echo premise-failed; exit 91; }
        [ "$3" = bare-notimeout ] && command -v timeout >/dev/null 2>&1 && { echo premise-failed; exit 91; } ;;
    *) PATH="$D/bin:$PATH" ;;
esac
export PATH; exec bash "$G" </dev/null
]==] }
    local o = text.trim((r.stdout or ""):gsub("\r", ""))
    return { rc = r.code, out = o, err = (r.stderr or ""):lower(), ms = time.now_ms() - t0, why = "rc=" .. tostring(r.code) .. " [" .. o:sub(1, 200) .. "] " .. (r.stderr or ""):sub(1, 300) }
end
local function says(x, v) return text.contains("\n" .. x.out .. "\n", "\n" .. v .. "\n") end
local UNKNOWN, MISSING = "unknown:secret-service-unprobed", "missing:no-credential-channel"
local x = guard("locked")
T:arm("1 a service gh cannot open is unknown, not missing", x.rc ~= 0 and says(x, UNKNOWN) and not says(x, MISSING), x.why)
T:arm("4 the remedy says unlock, forbids the re-auth and cites 1025-a896", text.contains(x.err, "unlock") and text.contains(x.err, "do not run 'gh auth login'") and text.contains(x.err, "1025-a896"), x.why)
T:arm("7 it answers within 60 s", x.ms <= 60000, x.ms .. " ms")
x = guard("noservice")
T:arm("2a NEGATIVE CONTROL no service is unretrievable, never missing", says(x, "blocked:credential-unretrievable-no-keyring-service") and not says(x, MISSING), x.why)
T:arm("2b and makes no lock claim", not text.contains(x.err, "is locked") and not text.contains(x.err, "unlock"), x.why)
x = guard("bare")
T:arm("2c NEGATIVE CONTROL no busctl at all is missing", says(x, MISSING), x.why)
x = guard("unlocked")
T:arm("3 an unlocked collection is unknown, with no lock claim", says(x, UNKNOWN) and not text.contains(x.out:lower(), "is locked"), x.why)
x = guard("bare-notimeout", 0)
T:arm("9 with no timeout(1) a healthy gh is not an absent channel", not says(x, MISSING) and (x.out:match("^blocked:") or x.out:match("^ok:") or x.out:match("^unverified:")) ~= nil, x.why)
local src = fs.read(GUARD):gsub("\r", "")
local back = {}
for l in (src .. "\n"):gmatch("([^\n]*)\n") do
    if l:find("get%-property[^|]*Locked") then back[#back + 1] = l end
end
T:arm("5 TRIPWIRE no Locked property read in the guard", #back == 0, table.concat(back, " | "))
T:arm("6 gh auth status runs bounded", src:find("_ccc_keyring_bounded %d+ gh auth status") ~= nil, "unbounded")
T:finish()
