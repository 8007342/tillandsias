-- @trace order:734-sjb3, order:2185-inst, order:2375-psb9
-- @env PATH HOME
--
-- test-precommit-zero-trace-scan-scope.lua — excluding build output from the pre-commit
-- spec sweep must not change the ANSWER, only the cost. Ported from
-- test-precommit-zero-trace-scan-scope.sh (2375-psb9); same four arms.
--
-- WHY. `grep -r --include` still WALKS every directory; the sweep descended 141k entries
-- under target/ to read 928 sources (237ms -> 93ms median on yoga; macbookair measured
-- 10373ms against a 2500ms budget). The RISK the exclusion carries: a spec referenced ONLY
-- from build output would be reported as a false zero-trace spec, so the invariant is
-- asserted. 2185-inst: deterministic on every host (a scratch tree, plus a subset check
-- against git's own source set, not an equality that measured host-local target/).
-- Every sweep uses /usr/bin/grep, what the hook gets (an interactive shell's grep may be
-- a ugrep function reporting 2-6ms).
--
--   1  NON-VACUITY: the excluded sweep of the checkout finds > 20 spec tokens
--   2  SCRATCH: on a planted tree the exclusion drops exactly the build-output-only tokens
--      and keeps the one source also names
--   3  SUBSET: every spec token in git's source set (tracked + untracked-not-ignored, read
--      by git grep, a different tool) is in the excluded sweep
--   4  the hook's sweep (scripts/hooks/pre-commit-openspec.sh) carries the exclusion
--
-- GRAMMAR ok:precommit-zero-trace-scan-scope:<n> arms
--       | violation:precommit-zero-trace-scan-scope:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("precommit-zero-trace-scan-scope")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()

-- $1 = root, $2 = "excl" | "all". Prints the sorted unique token set.
local SWEEP = [[
GREP=/usr/bin/grep; [ -x "$GREP" ] || GREP=grep
EXCL=""; [ "$2" = excl ] && EXCL="--exclude-dir=target --exclude-dir=.git --exclude-dir=node_modules"
# shellcheck disable=SC2086
"$GREP" -rhoE 'spec:[a-zA-Z0-9._-]+' \
    --include='*.rs' --include='*.sh' --include='*.toml' --include='Containerfile*' \
    $EXCL "$1" 2>/dev/null | sed 's/^spec://' | LC_ALL=C sort -u
]]
local function sweep(root, mode)
    local r = T:run{ SH, "-s", "--", root, mode, cwd = ROOT, stdin = SWEEP, timeout_ms = 120000 }
    return text.lines(text.trim(r.stdout or ""))
end
local function set_of(list)
    local s = {}
    for _, v in ipairs(list) do if v ~= "" then s[v] = true end end
    return s
end

local with_excl = sweep(ROOT, "excl")
local excl_set, n_excl = set_of(with_excl), 0
for _ in pairs(excl_set) do n_excl = n_excl + 1 end
T:arm("1 the sweep finds a real corpus (" .. n_excl .. " spec tokens) — the comparison is not vacuous",
    n_excl > 20, n_excl .. " tokens; the comparisons below would prove nothing")

-- ARM 2: planted build output is dropped, shared tokens are kept.
local W = T:scratch()
for _, d in ipairs{ "/src", "/target/debug", "/node_modules/m", "/.git/hooks" } do fs.mkdir(W.rel .. d) end
fs.write(W.rel .. "/src/a.rs", "// spec:alpha-fixture\n// spec:shared-fixture\n")
fs.write(W.rel .. "/target/debug/b.rs", "// spec:shared-fixture\n// spec:buildonly-fixture\n")
fs.write(W.rel .. "/node_modules/m/c.sh", "# spec:buildonly-fixture\n")
fs.write(W.rel .. "/.git/hooks/d.sh", "# spec:gitonly-fixture\n")
local got = table.concat(sweep(W.abs, "excl"), " ")
local all = table.concat(sweep(W.abs, "all"), " ")
T:arm("2 on a scratch tree the exclusion drops exactly the build-output-only tokens and keeps the shared one",
    got == "alpha-fixture shared-fixture" and all == "alpha-fixture buildonly-fixture gitonly-fixture shared-fixture",
    "excluded [" .. got .. "] (want [alpha-fixture shared-fixture]), full [" .. all .. "]")

-- ARM 3: no token named in source is lost to the exclusion.
local g = T:run{ "git", "grep", "-hoE", "--untracked", "spec:[a-zA-Z0-9._-]+", "--",
    "*.rs", "*.sh", "*.toml", ":(glob)**/Containerfile*", cwd = ROOT, timeout_ms = 120000 }
local src, n_src, lost = {}, 0, {}
for _, l in ipairs(text.lines(g.stdout or "")) do
    local tok = l:match("^spec:(.+)$")
    if tok and not src[tok] then src[tok] = true; n_src = n_src + 1 end
end
for tok in pairs(src) do if not excl_set[tok] then lost[#lost + 1] = tok end end
table.sort(lost)
T:arm("3 every spec token in source (" .. n_src .. ") is in the excluded sweep", n_src > 0 and #lost == 0,
    "the exclusion LOST a token source names (a false zero-trace): " .. table.concat(lost, " ", 1, math.min(#lost, 10)))

-- ARM 4: the hook must actually carry the exclusion, or the invariant is true of a sweep nobody runs.
local hook = fs.exists("scripts/hooks/pre-commit-openspec.sh") and fs.read("scripts/hooks/pre-commit-openspec.sh") or ""
T:arm("4 the hook's sweep carries the exclusion", text.contains(hook, "--exclude-dir=target"),
    "scripts/hooks/pre-commit-openspec.sh no longer excludes build output")

T:finish()
