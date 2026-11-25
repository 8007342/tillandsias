-- @trace order:1140-i6ct, order:2301-eny9, spec:tillandsias-vault
--
-- The guard 1140-i6ct's `unscoreable: unpinnable-until-the-guard-exists` was
-- waiting on. HERMETIC: sources the classifier out of
-- scripts/test-vault-shutdown-forwards-sigterm.sh and drives it with injected
-- values. No podman, no container, no clock, so it is safe to wire into the
-- gate, which the live fixture is not and must not be. Lua port of the .sh.
--
-- WHAT IT EXISTS TO PREVENT, in yoga's words on the row: "a vintage check that
-- short-circuits the measurement would make the fixture unable to fail at all,
-- which is worse than the defect it fixes". Arm 3 below is that negative
-- control, and it is the reason this file is not optional.
--
-- Usage: tillandsias-plan script run scripts/lua/test-vault-shutdown-fixture-classifier.lua
-- Verdict: ok:vault-shutdown-fixture-classifier:8 arms
--        | violation:vault-shutdown-fixture-classifier:<n>
--        | could-not-run:vault-shutdown-fixture-classifier:<reason>  (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("vault-shutdown-fixture-classifier")
local ROOT = fixture.repo_root()
local SUBJECT = "scripts/test-vault-shutdown-forwards-sigterm.sh"

local function could_not_run(reason)
    verdict.emit("could-not-run:vault-shutdown-fixture-classifier:" .. reason, 3)
end

if not fs.exists(SUBJECT) then could_not_run("no-fixture") end

local function bash(script, args)
    local spec = { fixture.posix_shell(), "-s", "--", cwd = ROOT,
        env = { TILLANDSIAS_VAULT_FIXTURE_LIB = "1" }, stdin = script }
    for _, a in ipairs(args or {}) do spec[#spec + 1] = a end
    return T:run(spec)
end

-- The LIB guard is what makes this hermetic. If it ever stops working the
-- source below runs the live fixture, so assert the function arrived.
local SOURCE = ". " .. SUBJECT .. " || exit 97\n"
    .. "command -v vault_shutdown_classify >/dev/null 2>&1 || exit 98\n"
local probe = bash(SOURCE .. "echo loaded\n")
if probe.code == 97 then could_not_run("fixture-would-not-source") end
if probe.code ~= 0 or text.trim(probe.stdout or "") ~= "loaded" then could_not_run("classifier-absent") end

-- args: elapsed, budget, exit_code, entrypoint
local function arm(name, want_rc, want_txt, args)
    local r = bash(SOURCE .. 'vault_shutdown_classify "$@" 2>&1\n', args)
    local said = tostring(r.stdout)
    T:arm(name .. " (rc=" .. want_rc .. ", says '" .. want_txt .. "')",
        r.code == want_rc and said:find(want_txt, 1, true) ~= nil,
        "rc=" .. tostring(r.code) .. " " .. said)
end

-- ARM 1: the green. 1s against a 15s budget, exit 0, this tree's entrypoint.
arm("green/match -> 0", 0, "SIGTERM is forwarded", { "1", "15", "0", "match" })

-- ARM 2: 1134-u934 as it was actually measured, the full grace and a SIGKILL.
--        THIS TREE's entrypoint, so the source IS indicted.
arm("stall+137/match -> FAIL", 1, "1134-u934 defect", { "30", "15", "137", "match" })

-- ARM 3: THE NEGATIVE CONTROL. Same red as arm 2, same entrypoint verdict.
--        A classifier that consulted vintage FIRST, or that treated any red as
--        a stale image, returns 4 here, and the fixture could then never fail.
--
--        DO NOT DELETE THIS AS A DUPLICATE OF ARM 2. It is written to look like
--        one, and that is the point (yoga, 1140-i6ct): the wrong fix it catches
--        (check the image vintage BEFORE measuring) passes every other arm in
--        this file, and it is attractive because it reads as an optimisation
--        rather than as a bug. An arm whose only job is to fail for the
--        seductive wrong answer is exactly the arm a cold reader deletes as
--        redundant. Arm 2 asserts the verdict; arm 3 asserts the verdict is
--        still REACHABLE. Losing it costs nothing visible and silently makes
--        the live fixture unable to fail at all.
arm("regression still fails", 1, "FAIL:", { "30", "15", "137", "match" })

-- ARM 4: yoga's case. Red, but the container is not running this tree's
--        entrypoint: the host is behind, the source is not indicted.
arm("stall+137/differs -> 4", 4, "stale-image", { "30", "15", "137", "differs" })

-- ARM 5: red and unattributable. 965-sxec: no verdict about a thing the check
--        could not evaluate. Distinct from 4 so the two never blur.
arm("stall+137/unknown -> 3", 3, "cannot-attribute", { "30", "15", "137", "unknown" })

-- ARM 6: a green on a stale image is STILL a green, but it passes the image,
--        not the checkout, and must say so rather than claiming the tree.
arm("green/differs -> 0, noted", 0, "passes the IMAGE", { "1", "15", "0", "differs" })

-- ARM 7: the exit-code half alone. Fast stop, non-zero status: a container
--        that exits quickly for a bad reason must not read as a pass.
arm("fast but non-zero -> FAIL", 1, "ExitCode 1", { "1", "15", "1", "match" })

-- ARM 8: the elapsed half alone. Exit 0, but it burned the grace to get there.
arm("slow but zero -> FAIL", 1, "did not reach", { "30", "15", "0", "match" })

T:finish()
