-- @env PATH HOME
-- @trace spec:git-mirror-service, order:749-wv4d, order:2373-8vq6
--
-- test-mirror-sshd-posture.lua — sshd in the git-mirror image answers under the mirror's posture.
-- Ported from the .sh of the same name (2373-8vq6). Runs the real image; the volume is its own.
--
--   1 read-only root, no capabilities, uid 1000: an SSH-2.0 banner on 2222
--   2 NEGATIVE CONTROL no writable path: the key cannot be made, for that named cause
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-sshd-posture.lua
-- Verdict: ok:mirror-sshd-posture:<n> arms | violation:... | skip:...:no-podman

local fixture = require "common.fixture"
local gitimage = require "common.gitimage"
local T = fixture.new("mirror-sshd-posture")
local G = gitimage.new(T)
local VOLUME = "tillandsias-sshd-posture-" .. tostring(time.now_ms())
local POSITIVE = [==[
set -u
[ "$(id -u)" = "1000" ] || { echo "inner:not-uid-1000"; exit 90; }
grep -qE "^[^ ]+ / [^ ]+ ro[, ]" /proc/mounts || { echo "inner:rootfs-not-read-only"; exit 91; }
if touch /rootfs-write-probe 2>/dev/null; then echo "inner:rootfs-writable"; exit 91; fi
ssh-keygen -q -N "" -t ed25519 -f /tmp/hostkey || { echo "inner:keygen-failed"; exit 92; }
/usr/sbin/sshd -D -e -f /dev/null \
    -o Port=2222 -o ListenAddress=127.0.0.1 \
    -o HostKey=/tmp/hostkey -o PidFile=none \
    2>/tmp/sshd.err &
for _ in $(seq 1 50); do
    banner="$(nc -w 1 127.0.0.1 2222 </dev/null 2>/dev/null | head -c 8)"
    if [ "$banner" = "SSH-2.0-" ]; then echo "inner:banner-ok"; exit 0; fi
    sleep 0.2
done
echo "inner:no-banner"; sed -n "1,10p" /tmp/sshd.err >&2; exit 93
]==]
local NEGATIVE = [==[
err="$(ssh-keygen -q -N "" -t ed25519 -f /tmp/hostkey 2>&1)"
rc=$?
if [ $rc -ne 0 ] && printf "%s" "$err" | grep -qi "read-only file system"; then
    echo "inner:named-cause-ok"; exit 0
fi
echo "inner:unexpected rc=$rc err=$err"; exit 94
]==]
local a = G:run(POSITIVE, { volumes = { VOLUME .. ":/srv/git" } })
local b = G:run(NEGATIVE, { volumes = { VOLUME .. ":/srv/git" }, posture = { "--read-only", "--read-only-tmpfs=false", "--cap-drop=ALL", "--user", "1000" } })
T:run{ "podman", "volume", "rm", "-f", VOLUME }
T:arm("1 sshd serves a banner as uid 1000 under the posture", a.rc == 0 and text.contains(a.out, "inner:banner-ok"), a.why)
T:arm("2 NEGATIVE CONTROL without a writable path it fails, for that cause", b.rc == 0 and text.contains(b.out, "inner:named-cause-ok"), b.why)
T:finish()
