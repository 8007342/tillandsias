-- @trace order:1176-fn2p, order:2183-mfbn
-- @env PATH HOME
--
-- test-gate-memory-floor-consumer.lua — consumer fixture for build.sh's
-- memory-floor block (1176-fn2p's consumer, fixed 2026-09-14 after macbookair
-- proved every macOS gate died at it). Ported from the .sh of the same name
-- (order 2183-mfbn); same arms and the same ok lines, byte for byte, because
-- gate step 067's STEP_SECOND_REGIME quotes one of them.
--
-- THE CLASS: under `set -euo pipefail`, `_mem_out="$(probe)"` with the probe
-- exiting 3 (could-not-run: no /proc/meminfo) exits the shell at the
-- assignment; the `case` written to wave that host past never runs. The block
-- is extracted from build.sh by its own anchors and driven under the gate's
-- OWN options with a completion sentinel: rc 3 must PROCEED with the warn, rc 0
-- must proceed with the info, rc 1 must STOP (exit 1), and a copy of the block
-- with the pre-fix capture form must NOT proceed on rc 3 (the mutation control,
-- built from content, proven different).
--
-- THE CONSTRUCTION MATTERS: the block runs in a SEPARATE bash process from a
-- driver file. bash IGNORES errexit inside `( set -e; … )` in $(…) or a
-- pipeline, so that shape prints the sentinel for the pre-fix form too
-- (measured 2026-09-14). A separate process with `set -euo pipefail` at its
-- top dies at the assignment as build.sh does.
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-memory-floor-consumer.lua
-- Verdicts:
--   ok:gate-memory-floor-consumer:<p>/<t>                            exit 0
--   violation:gate-memory-floor-consumer:<p>/<t>                     exit 1

local NAME = "gate-memory-floor-consumer"
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, env = BASE }).stdout or "")
local pass, fail = 0, 0
local function ok(m) pass = pass + 1; out.line("ok:   " .. m) end
local function bad(m) fail = fail + 1; out.line("FAIL: " .. m) end
local REL = "target/plan-scratch/gate-memory-floor." .. tostring(time.now_ms())
local W = ROOT .. "/" .. REL
fs.mkdir(REL)
local function cleanup() proc.run({ argv = { "rm", "-rf", W }, env = BASE }) end

-- sed -n '/^    _mem_rc=0$/,/^    esac$/p' build.sh — every such range.
local block, inr = {}, false
for _, l in ipairs(text.lines(fs.read("build.sh") or "")) do
    if not inr and l == "    _mem_rc=0" then inr = true end
    if inr then block[#block + 1] = l; if l == "    esac" then inr = false end end
end
local BLOCK = table.concat(block, "\n") .. (#block > 0 and "\n" or "")
if #block == 0 or not text.contains(BLOCK, "esac") then
    bad("could not extract the memory-floor consumer block from build.sh")
    cleanup()
    verdict.emit("violation:" .. NAME .. ":0/1", 1)
end
fs.write(REL .. "/block.sh", BLOCK)
ok("the consumer block is extractable from the shipped build.sh")

local seq = 0
local function drive(code, blockfile)
    seq = seq + 1
    local d = REL .. "/run." .. code .. "." .. seq
    fs.mkdir(d .. "/scripts")
    fs.write(d .. "/scripts/check-gate-memory-floor.sh", "#!/usr/bin/env bash\necho \"stub-probe rc=" .. code .. "\"\nexit " .. code .. "\n")
    proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. d .. "/scripts/check-gate-memory-floor.sh" }, env = BASE })
    fs.write(d .. "/driver.sh", "set -euo pipefail\nSCRIPT_DIR='" .. ROOT .. "/" .. d .. "'\n"
        .. "_info() { echo \"INFO: $*\"; }\n_warn() { echo \"WARN: $*\"; }\n_error() { echo \"ERROR: $*\"; }\n"
        .. ". '" .. ROOT .. "/" .. blockfile .. "'\necho \"consumer-block-completed\"\n")
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. d .. "/driver.sh" }, env = BASE, timeout_ms = 60000 })
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local function flat(s) return (s:gsub("\n", " ")) end

local o, rc = drive(3, REL .. "/block.sh")
if text.contains(o, "consumer-block-completed") then ok("rc 3 (could-not-run) PROCEEDS past the block") else bad("rc 3 did not proceed (rc=" .. tostring(rc) .. "): " .. flat(o)) end
if o:match("WARN:.*unguarded") then ok("rc 3 is waved past with the warn") else bad("rc 3 did not warn: " .. flat(o)) end

o, rc = drive(0, REL .. "/block.sh")
if text.contains(o, "consumer-block-completed") then ok("rc 0 proceeds") else bad("rc 0 did not proceed (rc=" .. tostring(rc) .. "): " .. flat(o)) end
if text.contains(o, "INFO:") then ok("rc 0 reports the info line") else bad("rc 0 did not report: " .. flat(o)) end

o, rc = drive(1, REL .. "/block.sh")
if text.contains(o, "consumer-block-completed") then bad("rc 1 (floor breached) PROCEEDED — the refusal is gone: " .. flat(o)) else ok("rc 1 stops the gate (no sentinel)") end
if rc == 1 then ok("rc 1 exits 1") else bad("rc 1 exited " .. tostring(rc) .. ", want 1") end

-- MUTATION CONTROL from content: the pre-fix capture form.
local mut = {}
for _, l in ipairs(block) do
    if l ~= "    _mem_rc=0" then
        if l:match(" || _mem_rc=%$%?$") then
            mut[#mut + 1] = l:gsub(" || _mem_rc=%$%?$", "")
            mut[#mut + 1] = "    _mem_rc=$?"
        else
            mut[#mut + 1] = l
        end
    end
end
local MUT = table.concat(mut, "\n") .. "\n"
if MUT == BLOCK then
    bad("mutation did not apply — the strip matched nothing")
else
    ok("the mutant differs from the shipped block (cmp)")
    fs.write(REL .. "/mutant.sh", MUT)
    o, rc = drive(3, REL .. "/mutant.sh")
    if text.contains(o, "consumer-block-completed") then bad("the pre-fix capture form PROCEEDED on rc 3 — the arm has no teeth: " .. flat(o))
    else ok("the pre-fix capture form dies on rc 3 (rc=" .. tostring(rc) .. "), so the arm has teeth") end
end

cleanup()
local total = pass + fail
if fail > 0 then verdict.emit("violation:" .. NAME .. ":" .. pass .. "/" .. total, 1) end
verdict.ok(NAME, pass .. "/" .. total)
