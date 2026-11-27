-- @env PATH HOME
-- inputs: Cargo.toml methodology/cheatsheets.yaml methodology/convergence.yaml plan/inbox/codex.md plan/index.yaml plan/mo-full-attestations.d/README.md README.md scripts/archive-plan-packets.sh scripts/attest-native-lint.sh scripts/check-added-test-is-referenced.sh scripts/check-append-vs-origin-fold.sh scripts/check-deslop-due.sh scripts/check-issue-citation-convention.sh scripts/check-mo-full-attestations.sh scripts/check-plan-binary-current.sh scripts/check-resumable-claim-dirt.sh scripts/check-scorable-obligation-added.sh scripts/cycle-preflight.sh scripts/gate-stamp.sh scripts/hooks/pre-push-local-gate.sh scripts/hooks/pre-push-version-guard.sh scripts/land-queue.sh scripts/lib-freeze-paths.sh scripts/lua/check-added-fragments-parse.lua scripts/lua/check-carried-obligations.lua scripts/lua/check-fragment-status-loss.lua scripts/lua/check-fragment-ts-skew.lua scripts/lua/check-no-base64-script-injection.lua scripts/lua/check-portability-idioms.lua scripts/lua/check-windows-tray-clippy.lua scripts/lua/probe-remote-reachable.lua scripts/lua/test-gate-stamp-scope.lua scripts/mo-full-attest.sh scripts/plan-binary-probe.sh scripts/promote-stable.sh scripts/release-freeze.sh scripts/release-preflight.sh scripts/remote-probe-judge.sh scripts/salvage-dirty-worktree.sh scripts/stage-image-cheatsheets.sh scripts/sweep-salvage-refs.sh scripts/test-plan-only-lane-structural.sh scripts/test-pre-push-empty-ref-list.sh scripts/unreferenced-grandfathered.txt scripts/with-wsl2-builder.sh lib/lua/common/ crates/tillandsias-plan/
-- @trace order:977-448j, order:1069-5sp4, order:1071-adhj, order:1101-b5rc, order:1093-hzhi, order:2386-zxgc
--
-- test-scorable-obligation-gate.lua — check-scorable-obligation-added.sh refuses a new packet that
-- says nothing about how it could be scored, and accepts a pin, a named command or an honest
-- unscoreable. Ported from the .sh of the same name (2386-zxgc). Each case is one scratch repository
-- with the shipped guard.
--
-- Usage: tillandsias-plan script run scripts/lua/test-scorable-obligation-gate.lua
-- Verdict: ok:scorable-obligation-gate:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("scorable-obligation-gate")
local SH = fixture.posix_shell()
local GUARD = "scripts/check-scorable-obligation-added.sh"
-- COMPOSED, so this file does not satisfy the guards it tests.
local L, C = "lit" .. "mus", "cargo" .. " test"

-- bodies: fragment name -> text. staged: leave them staged, not committed. The guard's whole output.
local function guard(bodies, staged)
    local g = T:git_repo()
    fs.mkdir(g.rel .. "/plan/index.d"); fs.mkdir(g.rel .. "/scripts")
    fs.write(g.rel .. "/" .. GUARD, fs.read(GUARD))
    T:must{ "git", "-C", g.abs, "add", "-A" }; T:must{ "git", "-C", g.abs, "commit", "-qm", "base" }
    T:must{ "git", "-C", g.abs, "branch", "-q", "base-ref" }
    for name, body in pairs(bodies) do fs.write(g.rel .. "/plan/index.d/" .. name .. ".yaml", body) end
    T:must{ "git", "-C", g.abs, "add", "plan/index.d" }
    if not staged then T:must{ "git", "-C", g.abs, "commit", "-qm", "new" } end
    local r = proc.run{ argv = { SH, GUARD, "base-ref" }, cwd = g.abs, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    return ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
end
-- The first ok:, violation: or skip: line.
local function first(o)
    for l in ("\n" .. o):gmatch("\n([^\n]*)") do
        if l:match("^ok:") or l:match("^violation:") or l:match("^skip:") then return l end
    end
end
local function case(name, want, bodies, staged)
    local o = guard(bodies, staged)
    T:arm(name, first(o) == want, tostring(first(o)) .. " / " .. o:sub(1, 300))
end
local function row(id, order, extra) return "packets:\n  - packet_id: " .. id .. "\n    order: " .. order .. "\n    status: ready\n" .. extra end
local function one(body) return { ["20260101t000000z-fixture"] = body } end
local MISSING, OK1 = "violation:scorable-obligation-missing:1", "ok:scorable-obligations:1 checked"

case("a silent new packet is refused", MISSING, one(row("silent-row", "999-aaaa", "    title: a row that says nothing about how it could be scored\n")))
case("a litmus pin is accepted", OK1, one(row("pinned-row", "999-bbbb", "    verifiable_closure: |\n      " .. L .. ":some-test passes\n")))
case("a stated unscoreable is accepted", OK1, one(row("honest-row", "999-cccc", "    unscoreable: closes on an operator decision; no mechanical pin exists\n")))
case("a mixed fragment counts only the silent row", MISSING,
    one(row("pinned-row", "999-dddd", "    verifiable_closure: " .. L .. ":some-test\n") .. "  - packet_id: silent-row\n    order: 999-eeee\n    status: ready\n    title: no pin here\n"))
case("an events-only fragment is not demanded of", "skip:no-new-packets",
    one('events:\n  - packet_id: some-existing-row\n    event:\n      type: note\n      ts: "2026-01-01T00:00:00Z"\n      host: fixture\n      summary: an ordinary progress note\n'))
local o = guard(one(row("rotating-row", "999-ffff", "    verifiable_closure: " .. L .. ":some-test\n    notes: this row will tombstone req-old and replace it\n")))
T:arm("a tombstone is named a regime break", text.contains(o, "regime-broken:1"), o:sub(1, 300))
T:arm("and is not a violation", not text.contains(o, "violation:"), o:sub(1, 300))
o = guard(one(row("mentions-the-mechanism", "999-oooo", "    verifiable_closure: |\n      " .. C .. " -p x --test y passes.\n    notes: this row explains how the tombstone/regime scan reads the body\n")))
T:arm("prose referring to tombstoning is not a tombstone", not text.contains(o, "regime-broken"), o:sub(1, 300))
for _, c in ipairs{
    { "a script-named closure is accepted", OK1, "scripts/check-something.sh reports ok" },
    { "a cargo-named closure is accepted", OK1, C .. " -p some-crate --test some_target passes green at a clean HEAD." },
    { "prose about testing is refused", MISSING, "Someone should test this properly and confirm the behaviour is right." },
    { "prose merely mentioning the tool is refused", MISSING, "We have not run " .. C .. " on this yet; someone should before v0.6." },
    { "prose saying the row is unscoreable is refused", MISSING, "This is hard to verify; " .. C .. " would not cover it, so judgement is required." },
    { "prose mentioning a script is refused", MISSING, "We never wrote scripts/foo.sh for this and probably should." },
    { "a bash-prefixed script closure is accepted", OK1, "bash scripts/test-something.sh prints PASS at a clean HEAD." } } do
    case(c[1], c[2], one(row("closure-row", "999-gggg", "    verifiable_closure: |\n      " .. c[3] .. "\n")))
end

local code = {}
for l in (fs.read("scripts/hooks/pre-push-local-gate.sh") .. "\n"):gmatch("([^\n]*)\n") do code[#code + 1] = (l:gsub("#.*$", "")) end
T:arm("the plan-only lane runs the guard (1069-5sp4)", table.concat(code, "\n"):find("bash%s+[^|\n]*check%-scorable%-obligation%-added%.sh") ~= nil, "it does not")

local DECL = row("repaired-row", "999-adhj", "    title: a row whose obligation arrives in a correction fragment\n")
local function pair(corr) return { ["20260101t000000z-declaration"] = DECL, ["20260101t000001z-correction"] = corr } end
case("obligation in a correction fragment satisfies the FOLDED packet", "ok:scorable-obligations:2 checked",
    pair("packets:\n  - packet_id: repaired-row\n    order: 999-adhj\n    unscoreable: |\n      Stated in a CORRECTION fragment rather than by amending the declaration.\n"))
case("the same declaration with no correction is refused", MISSING, { ["20260101t000000z-declaration"] = DECL })
case("a silent correction repairs nothing", "violation:scorable-obligation-missing:2", pair(row("repaired-row", "999-adhj", "    title: a correction that states nothing\n")))
case("a correction with a prose closure does not satisfy it", "violation:scorable-obligation-missing:2",
    pair("packets:\n  - packet_id: repaired-row\n    order: 999-adhj\n    verifiable_closure: |\n      Someone will look at it and decide whether it seems right.\n"))

local g = {}
for l in (fs.read(GUARD) .. "\n"):gmatch("([^\n]*)\n") do
    if not l:match("^%s*#") then g[#g + 1] = l end
end
g = table.concat(g, "\n")
T:arm("the guard needs nothing built (1071-adhj)", not (text.contains(g, "tillandsias-plan") or text.contains(g, "resolve_plan_binary") or text.contains(g, "plan-binary-probe") or text.contains(g, "target/release")),
    "it reaches for the plan binary")

local UNSC = row("staged-row-with-no-obligation", "1101-aaaa", "    title: nothing says how this could be scored\n")
local SC = row("staged-row-that-is-scorable", "1101-bbbb", "    title: a row that states its refusal\n    unscoreable: |\n      fixture row\n")
local EV = '\nevents:\n  - packet_id: some-other-packet-that-already-exists\n    event:\n      type: note\n      ts: "2026-01-01T00:00:00Z"\n      host: fixture\n      summary: an events entry is not a packet row\n'
case("1101-b5rc a STAGED row with no obligation is refused", MISSING, one(UNSC), true)
case("1101-b5rc a STAGED scorable row passes and is counted", OK1, one(SC), true)
case("1093-hzhi an events entry beside a packet row is not a second row", OK1, one(SC .. EV))
case("a STAGED mixed fragment counts exactly one row", OK1, one(SC .. EV), true)
case("CONTROL a STAGED mixed fragment with an unscorable row is refused, once", MISSING, one(UNSC .. EV), true)
T:finish()
