-- @trace order:1084-nzqc, order:1069-c9w6, order:1307-ermc, order:2385-psbb
-- @env PATH HOME TMPDIR
--
-- test-sigpipe-guard-sees-paths-and-continuations.lua — hermetic fixture for
-- scripts/check-sigpipe-verdict-pipelines-added.sh. Ported from
-- test-sigpipe-guard-sees-paths-and-continuations.sh (2385-psbb); same fifteen arms.
--
-- Every arm builds a throwaway repo, commits a base (branch base-ref), adds a shell file, and
-- runs the guard through TILLANDSIAS_SIGPIPE_ROOT/BASE; TILLANDSIAS_* (incl. GATE_DIFF_BASE) is
-- stripped so the real checkout's diff is never seen. Two escapes (1084-nzqc), each sufficient
-- alone and both in 1069-c9w6: an absolute-path producer (/usr/bin/grep: the anchor wanted a
-- delimiter, and the one there is `/`), and a pipeline split across `\` continuations. 1307-ermc
-- added the and-or spelling and printf-of-a-variable as a producer (1306-ifhv: a 15 KB transcript
-- flaked 2/20 under 8 KB pipes). Needles are assembled from P (pipe) and BS (ONE backslash) so
-- text-scanning guards never see a literal specimen; the files written carry the real bytes.
--
--   1  the 1069-c9w6 shape (absolute path across continuations into grep -q) is flagged
--   2  an absolute-path producer on one line is flagged
--   3  a continued pipeline with a bare command is flagged
--   4  NC a continued pipeline whose consumer reads to EOF is NOT flagged
--   5  a bounded printf-of-a-variable IS flagged (retired control, 1307-ermc: breadth chosen)
--   5b the same line answers with one `# sigpipe-ok:`
--   6  NC a sigpipe-ok marker on the last physical line exempts the folded line
--   7  NC a pre-existing violation in an unchanged file is NOT flagged (file scope)
--   8  NC an untouched violation in a CHANGED file is NOT flagged (line scope)
--   A1 the and-or spelling on one line is named   A2 ... in the continued 1306-ifhv form
--   A3 regression: the if-not spelling is still named
--   B  printf of a variable is a producer in a plain if-context
--   C  sigpipe-ok exempts the and-or spelling      C2 NC a pipeline nobody branches on is NOT flagged
--
-- GRAMMAR ok:sigpipe-guard-sees-paths-and-continuations:<n> arms
--       | violation:sigpipe-guard-sees-paths-and-continuations:<n>-failed
--       | could-not-run:sigpipe-guard-sees-paths-and-continuations:missing-guard (exit 3)

local fixture = require "common.fixture"
local V = require "common.verdict"
local NAME = "sigpipe-guard-sees-paths-and-continuations"
local T = fixture.new(NAME)
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local GUARD = ROOT .. "/scripts/check-sigpipe-verdict-pipelines-added.sh"
if not fs.exists("scripts/check-sigpipe-verdict-pipelines-added.sh") then
    V.emit("could-not-run:" .. NAME .. ":missing-guard", 3)
end
local P, BS = "|", "\\"
local HDR = "#!/usr/bin/env bash\nset -euo pipefail\n"
local HDRU = "#!/usr/bin/env bash\nset -uo pipefail\n"

local function git(d, ...)
    local argv = { "git", "-C", d.abs }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    return T:must(argv)
end
-- Base commit (branch base-ref), then `body` becomes the ADDED content of scripts/subject.sh.
local function repo(body)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/scripts")
    git(d, "init", "-q")
    git(d, "config", "user.email", "t@example.invalid")
    git(d, "config", "user.name", "t")
    git(d, "config", "commit.gpgsign", "false")
    fs.write(d.rel .. "/scripts/subject.sh", HDR .. "echo base\n")
    git(d, "add", "-A"); git(d, "commit", "-qm", "base"); git(d, "branch", "-f", "base-ref")
    fs.write(d.rel .. "/scripts/subject.sh", body)
    return d
end
local function run(d)
    local r = T:run{ SH, GUARD, cwd = d.abs, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" },
        env = { TILLANDSIAS_SIGPIPE_ROOT = d.abs, TILLANDSIAS_SIGPIPE_BASE = "base-ref", TMPDIR = env.get("TMPDIR") } }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o
end
local function tail(o) local last = "" for l in o:gmatch("[^\n]+") do last = l end return last end
local function flagged(name, body)
    local rc, o = run(repo(body))
    T:arm(name, rc ~= 0, "rc=" .. tostring(rc) .. " " .. tail(o))
end
local function clean(name, d)
    local rc, o = run(d)
    T:arm(name, rc == 0, "rc=" .. tostring(rc) .. " " .. tail(o))
end

-- 1: reproduced, not reverted in place in validate-traces.sh.
local d = repo(HDR .. 'for spec_dir in "$ROOT"/openspec/specs/*/; do\n'
    .. '  spec_name="$(basename "$spec_dir")"\n'
    .. "  if /usr/bin/grep -rl --include='*.rs' --include='*.sh' " .. BS .. "\n"
    .. '      "spec:${spec_name}" ' .. BS .. "\n"
    .. '      "$ROOT/scripts" "$ROOT/crates" 2>/dev/null ' .. BS .. "\n"
    .. "      " .. P .. " grep -q .; then\n    :\n  fi\ndone\n")
local rc, o = run(d)
T:arm("1 the 1069-c9w6 shape is flagged: /usr/bin/grep across continuations into grep -q",
    rc ~= 0 and o:find("violation:sigpipe-verdict-added:", 1, true) ~= nil, "rc=" .. tostring(rc) .. " " .. tail(o))

flagged("2 an absolute-path producer on one line is flagged",
    HDR .. "if /usr/bin/grep -rn foo . " .. P .. " grep -q bar; then :; fi\n")
flagged("3 a continued pipeline is flagged even with a bare command",
    HDR .. "if find . -name '*.rs' " .. BS .. "\n     -print " .. BS .. "\n     " .. P .. " head -1 " .. P .. " grep -q x; then :; fi\n")
-- 4: wc/sort consume everything, so SIGPIPE cannot decide the verdict.
clean("4 NC: a continued pipeline whose consumer reads to EOF is NOT flagged",
    repo(HDR .. "if /usr/bin/grep -rn foo . " .. BS .. "\n     " .. P .. " sort " .. BS .. "\n     " .. P .. " wc -l; then :; fi\n"))
-- 5: RETIRED BY MEASUREMENT (1307-ermc). Until then this asserted NOT flagged (792-ksr8). The
-- benign size is a property of the VARIABLE, invisible in the text; diff scope (9 added lines
-- fleet-wide in 7 days) makes the breadth tolerable.
local BOUNDED = HDR .. 'v="some text"\nif printf \'%s\' "$v" ' .. BS .. "\n     " .. P .. " grep -q text; then :; fi"
flagged("5 a printf-of-a-variable producer IS now flagged even when a reader can see it is bounded", BOUNDED .. "\n")
clean("5b the same bounded line answers the guard with one `# sigpipe-ok:`",
    repo(BOUNDED .. "  # sigpipe-ok: v is a literal assigned above\n"))
clean("6 NC: a sigpipe-ok marker on the last physical line still exempts the folded line",
    repo(HDR .. "if /usr/bin/grep -rn foo . " .. BS .. "\n     " .. P .. " grep -q bar; then :; fi   # sigpipe-ok: reviewed, producer is one file\n"))

-- 7: the fold reads the whole FILE; this proves it did not become a corpus scan.
d = repo(HDR .. "echo base\n")
fs.write(d.rel .. "/scripts/preexisting.sh", HDR .. "if /usr/bin/grep -rn foo . " .. P .. " grep -q bar; then :; fi\n")
git(d, "add", "scripts/preexisting.sh"); git(d, "commit", "-qm", "preexisting"); git(d, "branch", "-f", "base-ref")
clean("7 NC: a pre-existing violation in an unchanged file is NOT flagged (still diff-scoped)", d)

-- 8: line-level scoping; a mutation deleting it left arm 7 green.
d = repo(HDR .. "if /usr/bin/grep -rn foo . " .. P .. " grep -q bar; then :; fi\necho base\n")
git(d, "add", "-A"); git(d, "commit", "-qm", "the violation is now PRE-EXISTING"); git(d, "branch", "-f", "base-ref")
fs.write(d.rel .. "/scripts/subject.sh", fs.read(d.rel .. "/scripts/subject.sh") .. "echo an unrelated added line\n")
clean("8 NC: an untouched violation in a CHANGED file is NOT flagged (line-level scoping)", d)

-- 1307-ermc: tested together and apart, or the row closes on half a fix.
flagged("A1 the and-or spelling is NAMED — a verdict is a verdict without a leading if",
    HDRU .. "printf '%s' \"$out\" " .. P .. " grep -q 'pat' && ok \"matched\" " .. P .. P .. " bad \"absent\"\n")
flagged("A2 the 1306-ifhv line, in its real continued form, is NAMED",
    HDRU .. "printf '%s' \"$out\" " .. P .. " grep -qi 'ANCESTRY IS NOT USED' " .. BS
    .. "\n    && ok \"the disclaimer is present\" " .. BS .. "\n    " .. P .. P .. " bad \"the disclaimer is gone\"\n")
flagged("A3 (regression): the if-not spelling is still named",
    HDRU .. "if " .. "! git log --oneline " .. P .. " grep -q 'pat'; then echo no; fi\n")
flagged("B printf of a VARIABLE counts as a producer in a plain if-context",
    HDRU .. "if printf '%s' \"$out\" " .. P .. " grep -q 'pat'; then echo yes; fi\n")
clean("C a sigpipe-ok marker still exempts the and-or spelling too",
    repo(HDRU .. "printf '%s' \"$sha\" " .. P .. " grep -q 'pat' && ok \"m\" " .. P .. P .. " bad \"a\"  # sigpipe-ok: one 40-char line\n"))
-- C2: without it, "flag every printf into grep -q" passes every arm above.
clean("C2 (negative control): a pipeline with no branch on its status is NOT flagged",
    repo(HDRU .. "printf '%s' \"$out\" " .. P .. " grep -q 'pat'\necho unrelated\n"))

T:finish()
