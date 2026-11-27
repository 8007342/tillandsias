-- @env PATH HOME
-- @trace order:1310-rec6, spec:git-mirror-service, order:2331-8emp
--
-- test-mirror-refuses-when-broken.lua — a mirror whose relay-state is BROKEN refuses every push
-- up front with the remedy for the failing layer and for who pushes; reads stay open; one ok
-- tick restores service. Ported from the .sh of the same name (2331-8emp). A scratch bare
-- mirror runs images/git/pre-receive-hook.sh with a stub relay that records whether it ran.
--
--   1 credential/forge: refused before the relay; the remedy is the re-seed, not a rebuild
--   2 credential/host: the same remedy
--   3 transport: a forge is told upgrade and rebuild, a host to restore connectivity
--   4 clone and ls-remote work while broken   5 one ok state admits and relays the next push
--   6 CONTROL no relay-state ref admits       7 an unattended forge lane stops
--   8 an interactive one starts with a banner 9 transport remedy; an ok state is silent
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-refuses-when-broken.lua
-- Verdict: ok:mirror-refuses-when-broken:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("mirror-refuses-when-broken")
local SH = fixture.posix_shell()
local d = T:scratch()
fs.write(d.rel .. "/pre-receive", fs.read("images/git/pre-receive-hook.sh"))
local gate = ("\n" .. fs.read("images/default/lib-common.sh"):gsub("\r", "")):match("\n(forge_mirror_relay_gate%(%) {\n.-\n}\n)")
if not gate then T:refuse("extraction-empty", "forge_mirror_relay_gate is not in lib-common.sh") end
fs.write(d.rel .. "/gate.sh", gate)
local SCRIPT = [==[
set -u
W=$PWD; M="$W/mirror.git"
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig"
mkdir -p "$HOME" nohooks; printf '[user]\n\tname = f\n\temail = f@example.invalid\n' >"$W/gitconfig"
git init -q --bare -b main "$M" || exit 90
git -C "$M" config core.hooksPath "$W/nohooks"
git init -q -b main work && git -C work commit -q --allow-empty -m base && git -C work remote add origin "$M" && git -C work push -q origin main || exit 91
cp pre-receive "$M/hooks/pre-receive"
printf '#!/bin/sh\ncat >/dev/null\n: >"%s/relayed"\nexit 0\n' "$W" >"$M/hooks/tillandsias-relay-refs"
chmod +x "$M/hooks/pre-receive" "$M/hooks/tillandsias-relay-refs"
git -C "$M" config core.hooksPath "$M/hooks"
EMPTY="$(git -C "$M" hash-object -w --stdin </dev/null)"
state() {
    for r in $(git -C "$M" for-each-ref --format='%(refname)' refs/tillandsias/relay-state); do git -C "$M" update-ref -d "$r"; done
    [ -z "$1" ] || git -C "$M" update-ref "refs/tillandsias/relay-state/$1/$(date +%s)" "$EMPTY" || exit 92
}
try() {
    rm -f relayed; git -C work commit -q --allow-empty -m "c $1"
    if [ -n "${2:-}" ]; then TILLANDSIAS_PUSH_PRINCIPAL="$2" git -C work push origin main >"$1.out" 2>&1; else git -C work push origin main >"$1.out" 2>&1; fi
    echo $? >"$1.rc"; [ -e relayed ] && echo yes >"$1.relayed" || echo no >"$1.relayed"
    git -C work reset -q --hard origin/main
}
lane() { n=$1; shift; env "$@" bash -c '. ./gate.sh; forge_mirror_relay_gate "$1"' _ "$M" >"$n.out" 2>&1 </dev/null; echo $? >"$n.rc"; }
state broken/credential/1; try cred; try credhost til:host-push:lenovinha
state broken/transport/1; try tf; try th til:host-push:lenovinha
git clone -q "$M" clone 2>/dev/null; echo $? >clone.rc; git ls-remote "$M" 'refs/tillandsias/relay-state/*' >ls.out 2>&1
state ok/none/0; try ok
state ""; try none
state broken/credential/1; lane l7 TILLANDSIAS_CODEX_PROMPT="run the loop"; lane l8 -u NOTHING
state broken/transport/1; lane l9 TILLANDSIAS_OPENCODE_PROMPT=x
state ok/none/0; lane l9ok TILLANDSIAS_OPENCODE_PROMPT=x
exit 0
]==]
local r = T:run{ SH, "-s", cwd = d.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
if r.code ~= 0 then T:refuse("setup-failed", "rc=" .. tostring(r.code) .. " " .. (r.stderr or "")) end
local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or "" end
local function got(n)
    local rc, relayed, o = text.trim(read(n .. ".rc")), text.trim(read(n .. ".relayed")), read(n .. ".out")
    return { ok = rc == "0", failed = rc ~= "" and rc ~= "0", relayed = relayed, why = n .. " rc=" .. rc .. " relayed=" .. relayed .. " " .. o,
        has = function(s) return text.contains(o, s) end, out = o }
end
local SEED, REBUILD = "tillandsias --github-login", "tillandsias upgrade and a forge rebuild"
local x = got("cred")
T:arm("1 credential/forge is refused before the relay, with the re-seed and not a rebuild", x.failed and x.relayed == "no" and x.has("blocked:mirror-broken:credential") and x.has(SEED) and not x.has("upgrade and a forge rebuild"), x.why)
x = got("credhost")
T:arm("2 credential/host is refused before the relay with the same remedy", x.failed and x.relayed == "no" and x.has(SEED), x.why)
x = got("tf")
T:arm("3a transport tells a forge upgrade and rebuild", x.failed and x.relayed == "no" and x.has(REBUILD), x.why)
x = got("th")
T:arm("3b transport tells a host to restore connectivity", x.failed and x.relayed == "no" and x.has("restore this host's connectivity") and not x.has("upgrade and a forge rebuild"), x.why)
T:arm("4 reads stay open while broken", text.trim(read("clone.rc")) == "0" and text.contains(read("ls.out"), "broken/transport"), read("clone.rc") .. read("ls.out"))
x = got("ok")
T:arm("5 after one ok state the next push is admitted and relayed", x.ok and x.relayed == "yes", x.why)
x = got("none")
T:arm("6 CONTROL no relay-state ref: admitted and relayed", x.ok and x.relayed == "yes", x.why)
x = got("l7")
T:arm("7 an unattended lane on a broken mirror stops with the credential remedy", x.failed and x.has("blocked:mirror-broken:credential") and x.has(SEED), x.why)
x = got("l8")
T:arm("8 an interactive forge starts with a loud banner", x.ok and x.has("WARNING: the git mirror cannot relay") and not x.has("blocked:"), x.why)
x = got("l9")
T:arm("9a transport tells an unattended forge upgrade and rebuild", x.failed and x.has(REBUILD), x.why)
x = got("l9ok")
T:arm("9b an ok state gates nothing and prints nothing", x.ok and x.out == "", x.why)
T:finish()
