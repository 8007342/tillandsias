-- @trace spec:forge-environment-discoverability, plan/issues/populate-hot-paths-fails-silent-and-traces-success, order:2375-psb9
-- @env PATH HOME
--
-- test-populate-hot-paths-negative-control.lua — 920-tqhs negative control: with
-- /opt/cheatsheets deliberately unwritable by the lane user, populate_hot_paths
-- (images/default/lib-common.sh) must NAME the failure loudly (no unconditional success line)
-- and tellme must still answer from the shipped /opt/cheatsheets-image bundle. Ported from
-- test-populate-hot-paths-negative-control.sh (2375-psb9); same six checks.
--
-- Root + runuser-gated: it mutates /opt and runs the copy as an unprivileged lane user, the
-- only way to reproduce the EACCES the 2>/dev/null used to swallow. Skips (exit 0) on hosts
-- that cannot or should not run it (every macOS host: not root, no runuser).
--
--   1  populate_hot_paths returns 0 or 1 (degrade loudly, not abort)
--   2  the lifecycle log names the copy failure (FAILED: cp /opt/cheatsheets-image)
--   3  the lifecycle log does NOT print the unconditional success line
--   4  tellme (from the image install layout) exits 0
--   5  tellme names the degraded copy it serves (/opt/cheatsheets-image)
--   6  tellme lists the image-bundle topic (heatmap)
-- Arms 1-3 are skipped BY NAME (no arm) when lib-common.sh refuses at its top level because
-- the image vendor CA bundle is absent (1674-sgy9): every gate host that is not the forge image.
--
-- GRAMMAR ok:populate-hot-paths-negative-control:<n> arms
--       | violation:populate-hot-paths-negative-control:<n>-failed
--       | skip:populate-hot-paths-negative-control:<reason>

local fixture = require "common.fixture"
local T = fixture.new("populate-hot-paths-negative-control")
local ROOT = fixture.repo_root()

if text.trim(T:run{ "id", "-u" }.stdout or "") ~= "0" then T:skip("not-root") end
if not fixture.which("runuser") then T:skip("runuser-unavailable") end
if T:run{ "id", "nobody" }.code ~= 0 then T:skip("no-nobody-account") end
if T:run{ "test", "-e", "/opt/cheatsheets" }.code == 0 then T:skip("pre-existing-opt-cheatsheets") end
if T:run{ "test", "-e", "/opt/cheatsheets-image" }.code == 0 then T:skip("pre-existing-opt-cheatsheets-image") end

local SH = fixture.posix_shell("/bin/bash")
local MARK = "920-tqhs-negative-control-" .. tostring(time.now_ms())
local TMPD = text.trim(T:run{ "mktemp", "-d", "/tmp/php-ng-XXXXXX" }.stdout or "")
if TMPD == "" then T:refuse("setup-failed", "mktemp -d /tmp/php-ng-XXXXXX") end
local HOME_LANE = TMPD .. "/home"
local function cleanup()
    T:run{ "rm", "-rf", "/opt/cheatsheets", "/opt/cheatsheets-image", "/tmp/php-ng-home", TMPD }
end
-- /opt and /tmp are outside the repo: every touch goes through a child, not fs.*.
local function sh(script, ...)
    local argv = { SH, "-s", "--", ... }
    argv.stdin = script
    return T:run(argv)
end
local function must_sh(script, ...)
    local r = sh(script, ...)
    if r.code ~= 0 then cleanup(); T:refuse("setup-failed", tostring(r.stderr)) end
    return r
end
-- A lane-user shell: `runuser -u nobody -- env HOME=... <extra env> bash -s` with the script on stdin.
local function lane(script, extra_env)
    local argv = { "runuser", "-u", "nobody", "--", "env", "HOME=" .. HOME_LANE }
    for _, kv in ipairs(extra_env or {}) do argv[#argv + 1] = kv end
    argv[#argv + 1] = SH; argv[#argv + 1] = "-s"
    argv.stdin = script
    return T:run(argv)
end

must_sh([[
set -e
mkdir -p /opt/cheatsheets-image/cookbook "$1"
printf '%s\n' '## heatmap' > /opt/cheatsheets-image/INDEX.md
printf '%s\n' '# heatland' > /opt/cheatsheets-image/cookbook/heat.md
chmod 0755 /opt/cheatsheets-image
chmod -R a+rX /opt/cheatsheets-image
# /opt/cheatsheets at 0555: present but unwritable, the root-owned-tmpfs-under-keep-id symptom.
mkdir -p /opt/cheatsheets
chmod 0555 /opt/cheatsheets
chown -R nobody:nobody "$1"
]], HOME_LANE)

-- 1674-sgy9: source lib-common.sh once as the lane user; skip arms 1-3 BY NAME only on the
-- exact vendor-CA refusal. Any other source failure falls through and fails loudly.
local src = lane('set -euo pipefail\nsource "' .. ROOT .. '/images/default/lib-common.sh"\n')
local src_out = (src.stdout or "") .. (src.stderr or "")
local skip1
if src.code ~= 0 and text.contains(src_out, "image vendor CA bundle is missing") then
    for _, l in ipairs(text.lines(src_out)) do
        if text.contains(l, "image vendor CA bundle is missing") then skip1 = "vendor CA bundle absent: not a forge image (" .. l .. ")"; break end
    end
end

if skip1 then
    out.line("skip: control 1 (populate_hot_paths) — " .. skip1)
else
    sh('printf "%s\\n" "$1" >> /tmp/forge-lifecycle.log 2>/dev/null || true\n', MARK)
    local r = lane('set -euo pipefail\nsource "' .. ROOT .. '/images/default/lib-common.sh"\npopulate_hot_paths\n')
    T:arm("1 populate_hot_paths rc is 0 or 1 (degrade loudly, not abort)", r.code == 0 or r.code == 1, "rc=" .. tostring(r.code))
    local tail = sh('sed -n "/$1/,\\$p" /tmp/forge-lifecycle.log 2>/dev/null || true\n', MARK).stdout or ""
    T:arm("2 lifecycle log names the copy failure", text.contains(tail, "FAILED: cp /opt/cheatsheets-image"), tail)
    T:arm("3 lifecycle log has no unconditional success line", not text.contains(tail, "cheatsheets copied to tmpfs"), tail)
end

-- 1674-sgy9: run tellme from the image's install layout (Containerfile: COPY cli/tellme
-- /opt/agents/tillandsias-cli/bin/). In the checkout its repo-local fallback finds the TRACKED
-- images/default/cheatsheets/INDEX.md first, so the image bundle could never be reached.
local BIN = TMPD .. "/opt/agents/tillandsias-cli/bin"
must_sh([[
set -e
mkdir -p "$2"
cp "$3/images/default/cli/tellme" "$2/tellme"
chmod a+x "$1"          # mktemp made it 0700; the lane user must traverse it
chmod -R a+rX "$1/opt"
]], TMPD, BIN, ROOT)
local t = lane('exec bash "' .. BIN .. '/tellme" about --list\n', { "BASH_ENV=/dev/null", "TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets" })
local terr, tout = t.stderr or "", t.stdout or ""
T:arm("4 tellme exits 0", t.code == 0, "rc=" .. tostring(t.code) .. " stderr: " .. terr:gsub("\n", " "))
T:arm("5 tellme names the degraded copy it serves",
    text.contains(terr, "serving the shipped image bundle (/opt/cheatsheets-image)"), terr:gsub("\n", " "))
local listed = false
for _, l in ipairs(text.lines(tout)) do if l == "heatmap" then listed = true end end
T:arm("6 tellme lists the image-bundle topic", listed, tout:gsub("\n", " "))

cleanup()
T:finish()
