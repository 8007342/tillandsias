-- @trace order:1152-y3bv, order:1109-t8kw, order:1124-7f3u, order:1553-x8js, order:1570-mxcg, order:2242-u39b, order:2401-prg5
-- @env PATH HOME
--
-- test-plan-only-lane-structural.lua — fixture for order 1152-y3bv. Ported from
-- test-plan-only-lane-structural.sh (2401-prg5); same arms, in its order.
--
-- Three floor hosts were refused the plan-only lane in one night for STRUCTURAL reasons:
-- a mandated origin/linux-next merge pulled a non-plan path trunk had ALREADY gated into the
-- outgoing diff, and the plan-binary staleness check compared against the WHOLE crate and
-- workspace lock, so any Cargo.lock change re-armed it. This fixture pins both fixes:
--   A  a non-plan path whose PUSHED blob is byte-identical to origin/linux-next's is dropped
--   B  NEGATIVE: a non-plan path that DIFFERS from origin/linux-next still forces the full gate
--   C  plan-only staleness is judged against the VALIDATOR SURFACE hash, recorded beside the
--      binary by scripts/check-plan-binary-current.sh, so a change elsewhere does not re-arm it
--   D  NEGATIVE: a change to the validator surface's own sources still refuses, naming the rebuild
--
-- EACH ARM CARRIES A MUTATION CONTROL, built from a COPY of scripts/hooks/pre-push-local-gate.sh
-- by removing the exact construct (never from git history). Each mutant is proven non-empty,
-- different, carrying its intended edit, and parseable before any arm trusts it (1553-x8js:
-- an empty mutant once "passed" on BSD sed). CONTROL D runs the same swap harness with the
-- UNMUTATED hook, so an acceptance under MUT_D is the mutation's doing.
--
-- HERMETIC: two scratch git repos (a bare "remote" plus a working copy each) under kit scratch,
-- a stub plan binary for C/D, and a stub for check-plan-binary-current.sh's own fixture
-- dependency. Every hook run gets the ref line on stdin; nothing is pushed anywhere real. The
-- gate's frozen diff base names objects these repos do not hold, so it is dropped (2242-u39b).
-- Arms A/B skip by name without a built target/release/tillandsias-plan (1109-t8kw; yq does not
-- substitute, 1124-7f3u).
--
-- GRAMMAR ok:plan-only-lane-structural:<n> arms | violation:plan-only-lane-structural:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("plan-only-lane-structural")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local GUARD_REL = "scripts/hooks/pre-push-local-gate.sh"
local CHECKER_REL = "scripts/check-plan-binary-current.sh"
local GUARD = fs.read(GUARD_REL) or T:refuse("setup-failed", GUARD_REL .. " unreadable")
local UNSET = { "TILLANDSIAS_PLAN_BIN", "TILLANDSIAS_PLAN_BINARY", "CARGO_TARGET_DIR",
    "TILLANDSIAS_GATE_DIFF_BASE", "TILLANDSIAS_GATE_DIFF_BASE_ROOT" }
local GENV = { GIT_TERMINAL_PROMPT = "0" }
local W = T:scratch()

local function cat(r) return (r.stdout or "") .. (r.stderr or "") end
local function has(s, w) return text.contains(s, w) end

-- ── Mutated copies of the hook, one per construct under test ────────────────
local function lines(s) local t = {}; for l in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; t[#t] = nil; return t end
local GL = lines(GUARD)
-- MUTATION A: delete the whole byte-identical-to-trunk carve-out (from its ORDER comment through
-- the next line that is exactly 20 spaces and `fi`), restoring the unconditional refusal.
local MUT_A
do
    local outl, i, cut = {}, 1, false
    while i <= #GL do
        if not cut and has(GL[i], "# ORDER 1152-y3bv. A non-plan path is not automatically") then
            cut = true
            while i <= #GL and GL[i] ~= "                    fi" do i = i + 1 end
        else outl[#outl + 1] = GL[i] end
        i = i + 1
    end
    MUT_A = table.concat(outl, "\n") .. "\n"
end
local function sub1(s, o, n) local a, b = s:find(o, 1, true); if not a then return s end; return s:sub(1, a - 1) .. n .. s:sub(b + 1) end
-- Every occurrence, as sed's per-line s/// does (the construct is also quoted in a comment).
local function suball(s, o, n)
    local outp, i = {}, 1
    while true do
        local a, b = s:find(o, i, true)
        if not a then outp[#outp + 1] = s:sub(i); return table.concat(outp) end
        outp[#outp + 1] = s:sub(i, a - 1) .. n; i = b + 1
    end
end
-- MUTATION B: keep the carve-out's SHAPE but drop the content-equality test.
local MUT_B = suball(GUARD, 'if [[ -n "$_1152_push_blob" && "$_1152_trunk_blob" == "$_1152_push_blob" ]]; then',
    'if [[ -n "$_1152_trunk_blob" ]]; then')
-- MUTATION C: revert the lane's staleness predicate to the bare mtime check.
local MUT_C = suball(GUARD, '&& _lane_staleness_check "$plan_bin"; then', '&& plan_binary_is_stale "$plan_bin"; then')
-- MUTATION D: the surface-differs verdict reports FRESH (the line after the phrase returns 1).
local PHRASE_D = "the fragment checkers' own sources changed"
local MUT_D
do
    local outl, flip = {}, false
    for _, l in ipairs(GL) do
        if flip then l = sub1(l, "return 0", "return 1"); flip = false end
        if has(l, PHRASE_D) then flip = true end
        outl[#outl + 1] = l
    end
    MUT_D = table.concat(outl, "\n") .. "\n"
end
local function line_after(s, phrase)
    local L = lines(s)
    for i, l in ipairs(L) do if has(l, phrase) then return text.trim(L[i + 1] or "") end end
    return nil
end
local function intended(name, m)
    if name == "MUT_A" then
        return has(GUARD, "# ORDER 1152-y3bv. A non-plan path is not automatically")
            and not has(m, "# ORDER 1152-y3bv. A non-plan path is not automatically") and has(m, "_lane_staleness_check")
    elseif name == "MUT_B" then
        return has(m, 'if [[ -n "$_1152_trunk_blob" ]]; then') and not has(m, '"$_1152_trunk_blob" == "$_1152_push_blob"')
    elseif name == "MUT_C" then
        return has(m, '&& plan_binary_is_stale "$plan_bin"; then') and not has(m, ']] && _lane_staleness_check "$plan_bin"; then')
    elseif name == "MUT_D" then
        return line_after(GUARD, PHRASE_D) == "return 0" and line_after(m, PHRASE_D) == "return 1" and #lines(m) == #GL
    end
    return false
end
local MUTS = { MUT_A = MUT_A, MUT_B = MUT_B, MUT_C = MUT_C, MUT_D = MUT_D }
for _, name in ipairs({ "MUT_A", "MUT_B", "MUT_C", "MUT_D" }) do
    local m = MUTS[name]
    local path = W.rel .. "/" .. name .. ".sh"
    fs.write(path, m)
    if m == "" then
        T:arm("MUTATION SETUP " .. name .. " is non-empty", false, "EMPTY mutant; its arm proves nothing")
    elseif m == GUARD then
        T:arm("MUTATION SETUP " .. name .. " differs from the hook", false, "NO-OP strip: the construct no longer matches " .. GUARD_REL)
    elseif not intended(name, m) then
        T:arm("MUTATION SETUP " .. name .. " carries its intended edit", false, "differs but is truncated or mis-targeted")
    else
        local r = T:run{ SH, "-n", W.abs .. "/" .. name .. ".sh" }
        T:arm("MUTATION SETUP " .. name .. ": non-empty, differs, carries its intended edit, and still parses",
            r.code == 0, "syntax: " .. cat(r))
    end
end

-- ── scratch repo helpers ───────────────────────────────────────────────────
local function mkworld(tag)
    local base, abs = W.rel .. "/" .. tag, W.abs .. "/" .. tag
    fs.mkdir(base)
    T:must{ "git", "init", "-q", "--bare", abs .. "/bare.git" }
    T:must{ "git", "init", "-q", "-b", "linux-next", abs .. "/wc" }
    T:must{ "git", "-C", abs .. "/wc", "remote", "add", "origin", abs .. "/bare.git" }
    T:must{ "git", "-C", abs .. "/wc", "config", "core.hooksPath", ".git/hooks" }
    T:must{ "git", "-C", abs .. "/wc", "config", "core.autocrlf", "false" }
    T:must{ "git", "-C", abs .. "/wc", "config", "commit.gpgsign", "false" }
    local wc, wca = base .. "/wc", abs .. "/wc"
    local function G(...)
        local argv = { "git", "-C", wca, "-c", "user.email=t@t", "-c", "user.name=t", ... }
        argv.env = GENV
        return T:run(argv)
    end
    local function GM(...) local r = G(...)
        if r.code ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. cat(r)) end
        return r
    end
    return wc, wca, G, GM
end
local function provision(wc, wca)
    fs.mkdir(wc .. "/scripts/hooks"); fs.mkdir(wc .. "/plan/index.d")
    T:must{ "cp", ROOT .. "/" .. GUARD_REL, wca .. "/scripts/hooks/pre-push-local-gate.sh" }
    for _, f in ipairs({ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh", "check-issue-citation-convention.sh" }) do
        if fs.exists("scripts/" .. f) then T:must{ "cp", ROOT .. "/scripts/" .. f, wca .. "/scripts/" .. f } end
    end
end
local function rev(wca, r) return text.trim(T:must{ "git", "-C", wca, "rev-parse", r }.stdout or "") end
local function guard_run(wca, branch)
    local stdin = string.format("refs/heads/%s %s refs/heads/%s %s\n", branch, rev(wca, "HEAD"), branch, rev(wca, "origin/" .. branch))
    local env = {}; for k, v in pairs(GENV) do env[k] = v end
    local r = T:run{ SH, "scripts/hooks/pre-push-local-gate.sh", cwd = wca, stdin = stdin, env = env,
        env_unset = UNSET, timeout_ms = 300000 }
    return cat(r), r.code
end
local function guard_run_with(wc, wca, branch, content)
    local hook = wc .. "/scripts/hooks/pre-push-local-gate.sh"
    local saved = fs.read(hook)
    fs.write(hook, content)
    local o, rc = guard_run(wca, branch)
    fs.write(hook, saved)
    return o, rc
end

-- ════ ARMS A / B — PATH CLASSIFICATION ════════════════════════════════════
-- Cross-branch, deliberately: the push target's remote must be a DIFFERENT ref than
-- origin/linux-next, or the defect cannot be constructed.
local AB, ABa, GA, GAM = mkworld("ab")
provision(AB, ABa)
local AB_VALIDATOR = fs.exists("target/release/tillandsias-plan")
if AB_VALIDATOR then
    fs.mkdir(AB .. "/target/release")
    T:must{ "cp", ROOT .. "/target/release/tillandsias-plan", ABa .. "/target/release/tillandsias-plan" }
end
fs.write(AB .. "/plan/index.yaml", "packets: []\n")
fs.write(AB .. "/shared.txt", "trunk-version-old\n")
GAM("add", "-A"); GAM("commit", "-q", "-m", "base")
GAM("push", "-q", "-u", "origin", "linux-next"); GAM("push", "-q", "origin", "linux-next:windows-next")
fs.write(AB .. "/shared.txt", "trunk-version-new\n")
GAM("add", "-A"); GAM("commit", "-q", "-m", "trunk moves shared.txt"); GAM("push", "-q", "origin", "linux-next")
GAM("checkout", "-q", "-B", "windows-next", "origin/windows-next")
local function reset_ab()
    GAM("reset", "-q", "--hard", "origin/windows-next"); GAM("clean", "-qfd"); fs.mkdir(AB .. "/plan/index.d")
end

if not AB_VALIDATOR then
    out.line("skip:arms-ab:no-plan-binary (1109-t8kw) — target/release/tillandsias-plan is not built in this checkout, so the lane's fold and status-loss precondition cannot be constructed (yq does not substitute, 1124-7f3u); NOT a verdict about the guard")
else
    -- ARM A
    fs.write(AB .. "/plan/index.d/20260913t000000z-arm-a.yaml", "packets: []\n")
    fs.write(AB .. "/shared.txt", "trunk-version-new\n")
    GAM("add", "-A"); GAM("commit", "-q", "-m", "own commit whose non-plan path happens to match trunk")
    local outgoing = GA("diff", "--name-only", "origin/windows-next", "HEAD").stdout or ""
    if not has(outgoing, "shared.txt") then T:arm("ARM A is not vacuous (shared.txt in the outgoing diff)", false, outgoing) end
    local o, rc = guard_run(ABa, "windows-next")
    T:arm("ARM A: a non-plan path byte-identical to origin/linux-next is dropped, not refused",
        rc == 0 and has(o, "byte-identical to origin/linux-next"), "rc=" .. tostring(rc) .. " " .. o)
    o, rc = guard_run_with(AB, ABa, "windows-next", MUT_A)
    T:arm("MUTATION A: stripping the carve-out makes arm A's own push wrongly refused (arm A has teeth)",
        rc ~= nil and rc ~= 0, "rc=" .. tostring(rc))
    reset_ab()

    -- ARM B
    fs.write(AB .. "/plan/index.d/20260913t000001z-arm-b.yaml", "packets: []\n")
    fs.write(AB .. "/shared.txt", "windows-own-version\n")
    GAM("add", "-A"); GAM("commit", "-q", "-m", "own commit whose non-plan path diverges from trunk")
    outgoing = GA("diff", "--name-only", "origin/windows-next", "HEAD").stdout or ""
    if not has(outgoing, "shared.txt") then T:arm("ARM B is not vacuous (shared.txt in the outgoing diff)", false, outgoing) end
    o, rc = guard_run(ABa, "windows-next")
    T:arm("ARM B (NEGATIVE): a non-plan path differing from origin/linux-next still forces the full gate",
        rc ~= 0 and has(o, "differs from origin/linux-next"), "rc=" .. tostring(rc) .. " " .. o)
    o, rc = guard_run_with(AB, ABa, "windows-next", MUT_B)
    T:arm("MUTATION B: weakening the equality test makes arm B's own push wrongly ACCEPTED (arm B has teeth)",
        rc == 0, "rc=" .. tostring(rc))
    reset_ab()
end

-- ════ ARMS C / D — STALENESS AGAINST THE VALIDATOR SURFACE ════════════════
local CD, CDa, GC, GCM = mkworld("cd")
provision(CD, CDa)
T:must{ "cp", ROOT .. "/" .. CHECKER_REL, CDa .. "/scripts/check-plan-binary-current.sh" }
-- 1570-mxcg: the status-loss guard is Lua now and this tree's plan binary is a stub that cannot
-- run Lua, so it is deliberately NOT provisioned (the lane skips it with a note). A stand-in for
-- check-plan-binary-current.sh's own fixture dependency; the stub's `script` verb answers it.
fs.mkdir(CD .. "/scripts/lua"); fs.mkdir(CD .. "/target/release"); fs.mkdir(CD .. "/crates/tillandsias-plan/src")
fs.write(CD .. "/scripts/lua/test-expire-claims-write-is-opt-in.lua", "-- stub\n")
-- A REAL validator-surface source: it contains the keywords the fix greps for.
local MAIN_RS = "fn main() {\n    // implements validate-yaml, strict-fragments, declared-closures-check,\n    // and closure-evidence-check for this fixture's grep to find.\n"
fs.write(CD .. "/crates/tillandsias-plan/src/main.rs", MAIN_RS .. "}\n")
fs.write(CD .. "/crates/tillandsias-plan/Cargo.toml", '[package]\nname = "tillandsias-plan"\nversion = "0.1.0"\n')
fs.write(CD .. "/Cargo.lock", "# lock\n")
fs.write(CD .. "/crates/tillandsias-plan/src/other_subcommand.rs", "fn other() {}\n")
fs.write(CD .. "/target/release/tillandsias-plan", [[#!/usr/bin/env bash
case "${1:-}" in
    capabilities) echo compact; exit 0 ;;
    build-id) echo "0.1.0+deadbeef"; exit 0 ;;
    check) exit 0 ;;
    validate-yaml) exit 0 ;;
    yaml-type) echo '!!map'; exit 0 ;;
    script) echo "expire-claims-write-is-opt-in: 0 passed, 0 failed"; exit 0 ;;
esac
exit 0
]])
T:must{ "chmod", "+x", CDa .. "/target/release/tillandsias-plan", CDa .. "/scripts/check-plan-binary-current.sh" }
fs.write(CD .. "/.gitignore", "/target/\n")
fs.write(CD .. "/plan/index.yaml", "packets: []\n")
GCM("add", "-A"); GCM("commit", "-q", "-m", "base"); GCM("push", "-q", "-u", "origin", "linux-next")

-- Mint the validator-surface stamp with the REAL check-plan-binary-current.sh.
T:run{ SH, "scripts/check-plan-binary-current.sh", cwd = CDa, env_unset = UNSET, timeout_ms = 300000 }
local STAMP = CD .. "/target/release/tillandsias-plan.validator-surface-sha256"
local WRITER_HASH = text.trim(fs.read(STAMP) or "")
T:arm("SETUP: scripts/check-plan-binary-current.sh minted the validator-surface stamp", WRITER_HASH ~= "", "no stamp at " .. STAMP)

-- CROSS-CHECK: the reader's and writer's copies of the validator-surface hash agree. Checked
-- before C/D touch any crate file, while the hashed sources are exactly what is on disk.
do
    local fn, on = {}, false
    for _, l in ipairs(GL) do
        if l == "_validator_surface_files() {" then on = true end
        if l == "attempt_plan_only_lane() {" then on = false end
        if on then fn[#fn + 1] = l end
    end
    fs.write(W.rel .. "/reader-hash.sh", table.concat(fn, "\n") .. "\n_validator_surface_hash\n")
    local r = T:run{ SH, W.abs .. "/reader-hash.sh", cwd = CDa, env_unset = UNSET }
    local READER_HASH = text.trim(r.stdout or "")
    T:arm("CROSS-CHECK: the reader's (pre-push-local-gate.sh) and writer's (check-plan-binary-current.sh) validator-surface hashes agree",
        READER_HASH ~= "" and READER_HASH == WRITER_HASH, "reader='" .. READER_HASH .. "' writer='" .. WRITER_HASH .. "'")
end

-- ARM C: a change elsewhere in the crate leaves the surface unstaled. The crate/lock touch is
-- ON DISK ONLY, never committed; the mtime bump is what re-armed the OLD check.
T:must{ "touch", CDa .. "/crates/tillandsias-plan/src/other_subcommand.rs", CDa .. "/Cargo.lock" }
fs.write(W.rel .. "/mtime.sh", '. "$1/scripts/plan-binary-probe.sh"\ncd "$2" || exit 2\nif plan_binary_is_stale ./target/release/tillandsias-plan; then exit 0; else exit 1; fi\n')
local mv = T:run{ SH, W.abs .. "/mtime.sh", ROOT, CDa, env_unset = UNSET }
local mtime_verdict = mv.code == 0 and "stale" or (mv.code == 1 and "fresh" or "unknown")
if mtime_verdict ~= "stale" then
    T:arm("ARM C is not vacuous (the OLD mtime check calls this binary stale)", false, "got: " .. mtime_verdict)
end
fs.write(CD .. "/plan/index.d/20260913t000002z-arm-c.yaml", "packets: []\n")
GCM("add", "plan/index.d/20260913t000002z-arm-c.yaml")
GCM("commit", "-q", "-m", "just a fragment; the crate/lock touch above never entered a commit")
local outgoing = GC("diff", "--name-only", "origin/linux-next", "HEAD").stdout or ""
if has(outgoing, "other_subcommand.rs") or has(outgoing, "Cargo.lock") then
    T:arm("ARM C's scaffolding keeps the crate/lock touch out of the outgoing diff", false, outgoing)
end
local o, rc = guard_run(CDa, "linux-next")
T:arm("ARM C: a change elsewhere in the crate (surface hash unchanged) does not stale the lane",
    rc == 0 and not has(o, "is STALE"), "rc=" .. tostring(rc) .. " " .. o)
o, rc = guard_run_with(CD, CDa, "linux-next", MUT_C)
T:arm("MUTATION C: reverting to the bare mtime predicate makes arm C's own push wrongly refused (arm C has teeth)",
    rc ~= nil and rc ~= 0, "rc=" .. tostring(rc))

-- ARM D: NEGATIVE — a validator-surface source change still refuses.
fs.write(CD .. "/crates/tillandsias-plan/src/main.rs", MAIN_RS .. "    // CHANGED for arm D — the validator's own sources moved.\n}\n")
fs.write(CD .. "/plan/index.d/20260913t000003z-arm-d.yaml", "packets: []\n")
GCM("add", "plan/index.d/20260913t000003z-arm-d.yaml")
GCM("commit", "-q", "-m", "just a fragment; main.rs changed on disk, never committed")
outgoing = GC("diff", "--name-only", "origin/linux-next", "HEAD").stdout or ""
if has(outgoing, "main.rs") then T:arm("ARM D's scaffolding keeps the main.rs edit out of the outgoing diff", false, outgoing) end
o, rc = guard_run(CDa, "linux-next")
local remedy = "cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh"
T:arm("ARM D (NEGATIVE): a validator-surface source change still refuses a stale binary, and the remedy names the exact rebuild",
    rc ~= 0 and has(o, "validator-surface hash") and has(o, remedy), "rc=" .. tostring(rc) .. " " .. o)
o, rc = guard_run_with(CD, CDa, "linux-next", GUARD)
T:arm("CONTROL D: the swap harness with the UNMUTATED hook refuses arm D's push",
    rc ~= nil and rc ~= 0, "rc=" .. tostring(rc))
o, rc = guard_run_with(CD, CDa, "linux-next", MUT_D)
T:arm("MUTATION D: making the surface-differs verdict report fresh makes arm D's own push wrongly ACCEPTED (arm D has teeth)",
    rc == 0, "rc=" .. tostring(rc))

T:finish()
