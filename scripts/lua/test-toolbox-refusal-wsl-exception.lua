-- @trace order:922-curm, order:2262-7t6f, spec:methodology-accountability
-- inputs: scripts/lua/test-toolbox-refusal-wsl-exception.lua scripts/with-tillandsias-builder.sh
--
-- test-toolbox-refusal-wsl-exception.lua — order 922-curm, ported from the .sh
-- (2262-7t6f). Pins BOTH arms of the toolbox refusal in
-- scripts/with-tillandsias-builder.sh: a WSL2 distro is exempt, and a bare
-- Linux host without toolbox is still refused.
--   1 WSL      a WSL2 kernel + no toolbox passes through (exit 0, no FATAL)
--   2 REFUSED  (NEGATIVE CONTROL) a non-WSL kernel + no toolbox is still
--              refused and prints the toolbox FATAL. This arm gives arm 1 its
--              meaning: a deleted refusal would pass arm 1 just as happily.
--              Never delete it to make a change go green.
--   3 TRUTH    the false "os-release guard covers Windows" comment stays gone,
--              and native WSL detection is present in the real script
--
-- Isolation: the verdict must not depend on the host (yolanda is really WSL,
-- macuahuitl really not, a forge neither). /proc/version and /etc/os-release
-- are bash file tests a PATH stub cannot reach, so each arm runs a COPY of the
-- real script with those two literal paths rewritten to fabricated files. The
-- rewrite is drift-checked: if either substitution stops matching, the arm
-- FAILS instead of exercising the unmodified script.
-- 2118-9rn9: toolbox is MASKED, not assumed absent: the arms run on a PATH of
-- links to every tool in /usr/bin and /bin EXCEPT toolbox (Silverblue ships
-- /usr/bin/toolbox), and the premise is checked: if toolbox still resolves,
-- the arm refuses rather than test the wrong branch (yoga, #1199).
--
-- Verdict: ok:toolbox-refusal-wsl-exception:<n> arms | violation:…:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("toolbox-refusal-wsl-exception")
local REAL_REL = "scripts/with-tillandsias-builder.sh"
local REAL = fs.read(REAL_REL)
if not REAL then verdict.could_not_run("toolbox-refusal-wsl-exception", "cannot read " .. REAL_REL) end
local SH = fixture.posix_shell()
local FATAL = "FATAL: 'toolbox' is not installed"
local FEDORA = 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=44\n'

-- The masked PATH, built once: a link to every /usr/bin and /bin tool but toolbox.
local W = T:scratch("masked")
local BIN = W.abs .. "/bin"
local mk = proc.run{ argv = { SH, "-s", "--", BIN }, timeout_ms = 60000, stdin = [[
mkdir -p "$1" || exit 1
for t in /usr/bin/* /bin/*; do
    n=${t##*/}
    [ "$n" = toolbox ] && continue
    [ -e "$1/$n" ] || ln -s "$t" "$1/$n" 2>/dev/null
done
if PATH="$1" command -v toolbox >/dev/null 2>&1; then echo "resolves:$(PATH="$1" command -v toolbox)"; fi
exit 0
]] }
local premise = mk.status == "exited" and mk.code == 0 and not (mk.stdout or ""):find("resolves:", 1, true)

-- run(proc_version): the real script's copy on fabricated files; rc, output.
local n = 0
local function run(proc_version)
    n = n + 1
    local d = W.rel .. "/a" .. n
    local da = W.abs .. "/a" .. n
    fs.mkdir(d)
    fs.write(d .. "/proc-version", proc_version .. "\n")
    fs.write(d .. "/os-release", FEDORA)
    -- one value only: a bare gsub() here would pass its count as the outer limit
    local function lit(x) return (x:gsub("%%", "%%%%")) end
    local body, c1 = REAL:gsub("/proc/version", lit(da .. "/proc-version"))
    local c2
    body, c2 = body:gsub("/etc/os%-release", lit(da .. "/os-release"))
    if c1 == 0 or c2 == 0 then
        return nil, "substitution matched nothing (proc=" .. c1 .. " os-release=" .. c2 .. "): the arm would exercise the unmodified script"
    end
    fs.write(d .. "/under-test.sh", body)
    if not premise then
        return nil, "premise: toolbox still resolves on the masked PATH (" .. text.trim(mk.stdout or "") .. "); the arm would not test a toolbox-less host"
    end
    local r = proc.run{ argv = { SH, da .. "/under-test.sh", "true" }, timeout_ms = 120000,
        env = { PATH = BIN, HOME = W.abs, TILLANDSIAS_SKIP_TOOLBOX = "", TOOLBOX_PATH = "", container = "" } }
    return r, (r.stdout or "") .. (r.stderr or "")
end

-- 1 WSL
local r1, o1 = run("Linux version 6.18.33.2-microsoft-standard-WSL2 (root@f1bbfb02316b)")
T:arm("1 WSL a WSL2 kernel with no toolbox passes through, exit 0, no toolbox FATAL",
    r1 ~= nil and r1.status == "exited" and r1.code == 0 and not o1:find(FATAL, 1, true),
    r1 and ("rc=" .. tostring(r1.code) .. " out=" .. o1:sub(1, 300)) or o1)

-- 2 REFUSED (negative control)
local r2, o2 = run("Linux version 6.11.3-200.fc40.x86_64 (mockbuild@fedora)")
T:arm("2 REFUSED a non-WSL Linux host with no toolbox is still refused and prints the toolbox FATAL",
    r2 ~= nil and r2.status == "exited" and r2.code ~= 0 and o2:find(FATAL, 1, true) ~= nil,
    r2 and ("rc=" .. tostring(r2.code) .. " out=" .. o2:sub(1, 300)) or o2)

-- 3 TRUTH
T:arm("3 TRUTH the false os-release-covers-Windows claim is gone and native WSL detection is present",
    not REAL:find("macOS and Windows are the sanctioned exceptions and are handled ABOVE", 1, true)
        and REAL:find("grep -qi microsoft /proc/version", 1, true) ~= nil,
    "claim-present=" .. tostring(REAL:find("sanctioned exceptions and are handled ABOVE", 1, true) ~= nil))

T:finish()
