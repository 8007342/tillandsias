-- @trace order:1349-53h6, spec:ci-release, order:2375-psb9
-- @env PATH HOME
--
-- test-preflight-scratch-is-off-checkout.lua — scratch and build-output roots resolve
-- OFF the checkout when CARGO_TARGET_DIR is set, and the front door never reports runner
-- resource exhaustion as a tree refusal. Ported from test-preflight-scratch-is-off-checkout.sh
-- (2375-psb9); same five arms.
--
-- WHY (1349-53h6). On a forge the checkout is a 256 MB tmpfs while CARGO_TARGET_DIR is real
-- disk; scratch written inside the checkout filled the tmpfs, and ./build.sh --preflight then
-- printed refused:preflight:<decider> for deciders that NEVER RAN, conflating runner
-- exhaustion with "these deciders refused your tree".
--
--   1  scripts/build-sidecar.sh resolves SIDECAR_TARGET_DIR against CARGO_TARGET_DIR
--   2  scripts/push-plan-fragments-to-trunk.sh resolves _tmpbase against CARGO_TARGET_DIR
--   3  build.sh maps "No space left on device" to could-not-run:preflight:...:no-space
--   4  behavioural: a simulated ENOSPC decider output, scored by build.sh's verdict logic,
--      is could-not-run:no-space, not refused
--   5  build-sidecar.sh's resolution block, evaluated under a redirected CARGO_TARGET_DIR,
--      derives <CARGO_TARGET_DIR>-musl
--
-- GRAMMAR ok:preflight-scratch-is-off-checkout:<n> arms
--       | violation:preflight-scratch-is-off-checkout:<n>-failed
--       | refused:preflight-scratch-is-off-checkout:subject-missing

local fixture = require "common.fixture"
local T = fixture.new("preflight-scratch-is-off-checkout")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()

local BUILD, SIDECAR, PUSH = "build.sh", "scripts/build-sidecar.sh", "scripts/push-plan-fragments-to-trunk.sh"
for _, p in ipairs{ BUILD, SIDECAR, PUSH } do
    if not fs.exists(p) then T:refuse("subject-missing", p) end
end

-- grep -q, line by line (a Lua pattern on the whole file would match across lines).
local function has_line(path, pat)
    for _, l in ipairs(text.lines(fs.read(path))) do
        if l:find(pat) then return true end
    end
    return false
end

T:arm("arm1 build-sidecar.sh resolves SIDECAR_TARGET_DIR against CARGO_TARGET_DIR",
    has_line(SIDECAR, "CARGO_TARGET_DIR.*SIDECAR_TARGET_DIR") or has_line(SIDECAR, "SIDECAR_TARGET_DIR=.*CARGO_TARGET_DIR"),
    "build-sidecar.sh hardcodes SIDECAR_TARGET_DIR under $ROOT")

T:arm("arm2 push-plan-fragments-to-trunk.sh resolves _tmpbase against CARGO_TARGET_DIR",
    has_line(PUSH, "CARGO_TARGET_DIR.*_tmpbase") or has_line(PUSH, "_tmpbase=.*CARGO_TARGET_DIR"),
    "push-plan-fragments-to-trunk.sh hardcodes _tmpbase under $ROOT")

T:arm("arm3 build.sh front door maps 'No space left on device' to could-not-run:...:no-space",
    has_line(BUILD, "No space left on device") and has_line(BUILD, "could%-not%-run:preflight:.*:no%-space"),
    "build.sh front door does not categorize disk exhaustion as could-not-run")

-- ARM 4: the exact verdict logic build.sh uses, run on a simulated ENOSPC decider output.
local W = T:scratch()
fs.write(W.rel .. "/sim_enospc",
    'awk: cmd. line:1: fatal: print to "standard output" failed: No space left on device\n')
local r4 = T:run{ SH, "-s", "--", W.abs .. "/sim_enospc", cwd = ROOT, stdin = [[
sim_out="$1"; _pf_rc=1; _pf_cantrun=0; _pf_failed=0; _verdict=""
if [ "$_pf_rc" -eq 127 ] || grep -qE '(^|: )(exec: )?[A-Za-z0-9_.-]+: (not found|command not found)$' "$sim_out"; then
    _pf_cantrun=$((_pf_cantrun + 1)); _verdict="could-not-run:runner"
elif grep -qE 'No space left on device' "$sim_out"; then
    _pf_cantrun=$((_pf_cantrun + 1)); _verdict="could-not-run:no-space"
else
    _pf_failed=$((_pf_failed + 1)); _verdict="refused"
fi
printf '%s %s %s' "$_verdict" "$_pf_cantrun" "$_pf_failed"
]] }
local v4 = text.trim(r4.stdout or "")
T:arm("arm4 simulated ENOSPC decider failure is scored as could-not-run:no-space, not refused",
    v4 == "could-not-run:no-space 1 0", "verdict cantrun failed = [" .. v4 .. "]")

-- ARM 5: evaluate build-sidecar.sh's own resolution block under a redirected CARGO_TARGET_DIR.
local CTD = W.abs .. "/custom-target"
local r5 = T:run{ SH, "-s", "--", SIDECAR, cwd = ROOT, env = { CARGO_TARGET_DIR = CTD },
    env_unset = { "TILLANDSIAS_*" }, stdin =
    'eval "$(sed -n \'/if \\[ -n "\\${TILLANDSIAS_SIDECAR_TARGET_DIR/,/^fi/p\' "$1")"\n'
    .. 'printf "%s" "${SIDECAR_TARGET_DIR:-}"\n' }
local got5 = r5.stdout or ""
T:arm("arm5 build-sidecar.sh derives external musl target path matching redirected CARGO_TARGET_DIR",
    got5 == CTD .. "-musl", "SIDECAR_TARGET_DIR=[" .. got5 .. "] want [" .. CTD .. "-musl]")

T:finish()
