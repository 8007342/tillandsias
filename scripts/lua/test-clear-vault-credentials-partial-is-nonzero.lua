-- @env PATH HOME
-- @trace order:1284-jf86, order:900-z3kv, order:2378-hcxg
--
-- test-clear-vault-credentials-partial-is-nonzero.lua — a vault-data directory that cannot all be
-- removed is retried in podman's user namespace, and a partial clear exits non-zero. Ported from the
-- .sh of the same name (2378-hcxg). Scratch caches; podman and secret-tool are stubs.
--
--   1 removed through podman unshare: ok, 0      2 refused both ways, 3 no podman: partial, non-zero
--   4 a removable one clears with no podman call
--
-- Usage: tillandsias-plan script run scripts/lua/test-clear-vault-credentials-partial-is-nonzero.lua
-- Verdict: ok:clear-vault-credentials-partial-is-nonzero:<n> arms | violation:... | skip:...:running-as-root

local fixture = require "common.fixture"
local bus = require "common.privatebus"
local T = fixture.new("clear-vault-credentials-partial-is-nonzero")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
if text.trim(T:run{ "id", "-u" }.stdout or "") == "0" then T:skip("running-as-root") end
local PODMAN = {
    resolve = "#!/usr/bin/env bash\necho \"$*\" >>\"@D/calls\"\n[ \"$1\" = unshare ] || exit 1\nshift\nfor a in \"$@\"; do last=\"$a\"; done\nchmod -R u+w \"$last\" 2>/dev/null\nexec \"$@\"\n",
    refuse = "#!/bin/sh\necho \"$*\" >>\"@D/calls\"\nexit 1\n",
}
local function case(locked, podman)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin"); fs.write(d.rel .. "/calls", "")
    local t = d.rel .. "/cache/tillandsias"
    fs.mkdir(t .. "/vault-data/core/sys"); fs.write(t .. "/vault-data/core/sys/k", "x\n")
    fs.write(t .. "/fallback_vault-shamir-share-v1", "x\n"); fs.write(t .. "/fallback_vault-root-token-v1", "x\n")
    fs.write(d.rel .. "/bin/secret-tool", "#!/bin/sh\nexit 0\n")
    if PODMAN[podman] then fs.write(d.rel .. "/bin/podman", (PODMAN[podman]:gsub("@D", function() return d.abs end))) end
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, ROOT .. "/scripts/clear-vault-host-credentials.sh", locked and "1" or "0", podman }, cwd = d.abs, env = bus.env{ HOME = d.abs }, env_unset = { "TILLANDSIAS_*", "XDG_*" }, timeout_ms = 60000, stdin = [==[
D="$1"; chmod +x "$D"/bin/*; B="$BASH"; [ -x "$B" ] || B="$(command -v bash)"
[ "$3" = 0 ] || chmod a-w "$D/cache/tillandsias/vault-data/core"
if [ "$4" = absent ]; then for t in rm sed chmod cat; do ln -s "$(command -v $t)" "$D/bin/$t"; done; PATH="$D/bin"; else PATH="$D/bin:$PATH"; fi
export PATH XDG_CACHE_HOME="$D/cache" TILLANDSIAS_DESTRUCTIVE_RESET_OK=1
rc=0; "$B" "$2" </dev/null 2>&1 || rc=$?
[ -e "$D/cache/tillandsias/vault-data" ] && echo "left=yes" || echo "left=no"
PATH=/usr/bin:/bin; chmod -R u+w "$D/cache" 2>/dev/null
exit "$rc"
]==] }
    local o = "\n" .. (r.stdout or "")
    return { rc = r.code, out = o, left = text.contains(o, "\nleft=yes\n"), calls = fs.read(d.rel .. "/calls"), why = "rc=" .. tostring(r.code) .. " " .. o:sub(-500) .. (r.stderr or ""):sub(1, 200) }
end
local function ok(x) return x.rc == 0 and not x.left and text.contains(x.out, "\nok:clear-vault-credentials:") end
local function partial(x) return x.rc ~= nil and x.rc ~= 0 and x.left and text.contains(x.out, "\nwarn:clear-vault-credentials:partial") end
local x = case(true, "resolve")
T:arm("1 a locked vault-data goes through podman unshare, and says so", ok(x) and text.contains(x.out, "via podman unshare"), x.why)
x = case(true, "refuse")
T:arm("2 both removals refused: partial, non-zero", partial(x) and x.calls ~= "", x.why)
x = case(true, "absent")
T:arm("3 no podman to retry with: partial, non-zero", partial(x), x.why)
x = case(false, "refuse")
T:arm("4 a removable one clears and never calls podman", ok(x) and x.calls == "", x.why .. x.calls)
T:finish()
