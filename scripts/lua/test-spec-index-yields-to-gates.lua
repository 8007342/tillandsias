-- @trace order:2286-5agy
--
-- test-spec-index-yields-to-gates.lua — a hook-started spec-index rebuild waits
-- between batches while a gate or preflight runs on the host. The two functions
-- are cut out of scripts/spec-index-ensure.sh and run against a stub ps.
--
--   1 OFF     without TILLANDSIAS_SPEC_INDEX_YIELD=1 nothing is looked at
--   2 WAITS   it waits while a gate runs and goes on when it ends
--   3 BOUND   it stops yielding at the bound, over all batches together
--   4 GATES   each shape a gate really has counts
--   5 NOT     a shell whose text names build.sh, a plain build, a grep do not
--   6 WIRED   the batch loop calls it, and the hook asks for it
--
-- Verdict: ok:spec-index-yields-to-gates:<n> | violation:…

local fixture = require "common.fixture"
local T = fixture.new("spec-index-yields-to-gates")
local SH = fixture.posix_shell()
local SRC = fs.read("scripts/spec-index-ensure.sh") or ""
local fns = SRC:match("\n(_gate_running%(%) {.-\n}\n_yielded=0\n_yield_to_gates%(%) {.-\n}\n)")
if not fns then T:refuse("no-subject", "spec-index-ensure.sh has no _gate_running / _yield_to_gates block") end

local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
-- ps call n prints file ps.<n>, or ps.last
fs.write(W.rel .. "/bin/ps", '#!/usr/bin/env bash\nD="${0%/bin/*}"; n=$(( $(cat "$D/n") + 1 )); echo $n > "$D/n"\n[ -f "$D/ps.$n" ] && cat "$D/ps.$n" || cat "$D/ps.last"\n')
fs.write(W.rel .. "/bin/sleep", '#!/usr/bin/env bash\nD="${0%/bin/*}"; echo "$1" >> "$D/slept"\n')
T:must{ "chmod", "+x", W.abs .. "/bin/ps", W.abs .. "/bin/sleep" }
fs.write(W.rel .. "/go.sh", 'D="$(cd "$(dirname "$0")" && pwd)"; PATH="$D/bin:$PATH"\n' .. fns ..
    'for b in $(seq 1 "${BATCHES:-1}"); do _yield_to_gates; done\necho "slept=$(grep -c . "$D/slept") asked=$(cat "$D/n") yielded=$_yielded"\n')
local function run(ps_lines, last, opts)
    opts = opts or {}
    for i = 1, 4 do if fs.exists(W.rel .. "/ps." .. i) then fs.write(W.rel .. "/ps." .. i, "") end end
    for i = 1, 4 do fs.write(W.rel .. "/ps." .. i, ps_lines[i] or last) end
    fs.write(W.rel .. "/ps.last", last); fs.write(W.rel .. "/n", "0\n"); fs.write(W.rel .. "/slept", "")
    local r = T:run{ SH, W.abs .. "/go.sh", timeout_ms = 20000, env = { TILLANDSIAS_SPEC_INDEX_YIELD = opts.yield or "1",
        TILLANDSIAS_SPEC_INDEX_YIELD_MAX = opts.max or "7200", BATCHES = opts.batches or "1" } }
    return text.trim(r.stdout or ""), r.stderr or ""
end
local GATE, QUIET = "bash ./build.sh --preflight\n", "bash\nsystemd\n"

local o, e = run({}, GATE, { yield = "0" })
T:arm("1 OFF a caller that did not ask never waits, or looks", o == "slept=0 asked=0 yielded=0", o)
o, e = run({ GATE, GATE }, QUIET)
local _, notes = e:gsub("note:spec%-index:yielding", "")
T:arm("2 WAITS two looks at a running gate, then on, with one note", o == "slept=2 asked=3 yielded=30" and notes == 1, o .. " notes=" .. notes)
o = run({}, GATE, { max = "45", batches = "3" })
T:arm("3 BOUND the bound is over all batches, not per batch", o == "slept=3 asked=3 yielded=45", o)

local missed, taken = {}, {}
for _, l in ipairs({ "bash ./build.sh --preflight", "/usr/bin/bash /x/y/build.sh --check", "./build.sh --ci-full --install",
    "sh build.sh --test", "/bin/bash ./build.sh --release --ci", "bash scripts/land-queue.sh --daily-full" }) do
    if run({ "init\n" .. l .. "\nps\n" }, QUIET) ~= "slept=1 asked=2 yielded=15" then missed[#missed + 1] = l end
end
T:arm("4 GATES every shape a gate really has counts", #missed == 0, table.concat(missed, " | "))
for _, l in ipairs({ "/bin/bash -c cd /x && ./build.sh --preflight", "grep -n build.sh --check", "vim build.sh", "bash ./build.sh",
    "bash ./build.sh --help", "bash my-build.sh --check", "bash scripts/test-land-queue.sh", "tail -f build.sh --test" }) do
    if run({ l .. "\n" }, QUIET) ~= "slept=0 asked=1 yielded=0" then taken[#taken + 1] = l end
end
T:arm("5 NOT text that names build.sh, a plain build, or a grep is not a gate", #taken == 0, table.concat(taken, " | "))

local loop = SRC:match('for part in "%$work"/b/part%-%*; do\n(.-)want=') or ""
local hook = fs.read("scripts/hooks/post-commit-expert-refresh.sh") or ""
T:arm("6 WIRED the batch loop yields, and only the hook asks it to",
    loop:find("\n    _yield_to_gates\n", 1, true) ~= nil and hook:find('TILLANDSIAS_SPEC_INDEX_YIELD=1 nice -n 19 bash "$REPO_ROOT/scripts/spec-index-ensure.sh"', 1, true) ~= nil, loop)
T:finish()
