-- @trace order:1471-8ydv, order:2235-zkmx
--
-- test-gate-host-memory-figure.lua — a WSL2 gate's memory floor judges the
-- Windows HOST's figure: with-wsl2-builder.sh samples the host's MemFree into
-- TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB, and build.sh's memory-floor block
-- judges that figure instead of the guest's own meminfo. Both halves are cut
-- from the shipped files (the sampler between its BEGIN/END markers, the
-- consumer block of build.sh) and driven through helper files, as the .sh
-- drove them. Ported from test-gate-host-memory-figure.sh (2235-zkmx).
--
--   1 the sampler exports the host's MemFree
--   2 a figure already set is kept
--   3 a starved host figure stops the gate (rc 1)
--   4 a healthy host figure proceeds, judged from it
--   5 a non-numeric figure is ignored, no temp meminfo left
--   6 end to end: the host's 292MB is judged and refused, temp file removed
--
-- TILLANDSIAS_* names pass proc.run's scrub, so every run sets
-- TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB explicitly ("" reads as unset: both
-- halves test it with ${…:-}).
--
-- Verdict: ok:gate-host-memory-figure:<pass>/<total> | violation:gate-host-memory-figure:<pass>/<total>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pass, failn = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/gate-host-memory-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

-- cut the two halves from the shipped files
local function cut(text_, first, last)
    local outl, on = {}, false
    for _, l in ipairs(text.lines(text_)) do
        if not on and l == first then on = true end
        if on then
            outl[#outl + 1] = l
            if l == last and #outl > 1 then break end
        end
    end
    return table.concat(outl, "\n") .. "\n"
end
local sample_src = cut(fs.read("scripts/with-wsl2-builder.sh"), "# BEGIN-HOST-MEMORY-SAMPLE", "# END-HOST-MEMORY-SAMPLE")
local consumer_src = cut(fs.read("build.sh"), "    _mem_rc=0", "    esac")
if not sample_src:find("END-HOST-MEMORY-SAMPLE", 1, true) or not consumer_src:find("TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB", 1, true) then
    bad("could not cut the sampler or the consumer block from the shipped files")
    cleanup()
    verdict.emit("violation:gate-host-memory-figure:0/1", 1)
end
fs.write(rel .. "/sample.sh", sample_src)
fs.write(rel .. "/consumer.sh", consumer_src)
fs.write(rel .. "/run-sample.sh", ". \"$1\"\nprintf '%s\\n' \"${TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB:-<unset>}\"\n")
fs.write(rel .. "/host-meminfo", "MemTotal:       16000000 kB\nMemFree:         4465888 kB\n")

local function sample(meminfo, preset)
    local r = proc.run{ argv = { "bash", W .. "/run-sample.sh", W .. "/sample.sh" }, timeout_ms = 30000,
        env = { TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB = preset or "", TILLANDSIAS_WSL2_HOST_MEMINFO = meminfo } }
    return text.trim(r.stdout or "")
end

local runs = 0
local function drive(figure)
    runs = runs + 1
    local d = W .. "/run." .. runs
    proc.run{ argv = { "mkdir", "-p", d } }
    local q = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    fs.write(rel .. "/run." .. runs .. "/driver.sh", "set -euo pipefail\nSCRIPT_DIR=" .. q(root) .. "\nTMPDIR=" .. q(d) .. "\n"
        .. "_info() { echo \"INFO: $*\"; }\n_warn() { echo \"WARN: $*\"; }\n_error() { echo \"ERROR: $*\"; }\n"
        .. ". " .. q(W .. "/consumer.sh") .. "\necho \"consumer-block-completed\"\n")
    local r = proc.run{ argv = { "bash", d .. "/driver.sh" }, timeout_ms = 60000,
        env = { TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB = figure, TILLANDSIAS_GATE_MEMORY_FLOOR_MB = "1024" } }
    local leftover = 0
    for _, f in ipairs(fs.list(rel .. "/run." .. runs)) do
        if f:find("gate-host-meminfo.", 1, true) then leftover = leftover + 1 end
    end
    return r.code, (r.stdout or "") .. (r.stderr or "") .. "leftover=" .. leftover .. "\n"
end

local v = sample(W .. "/host-meminfo")
if v == "4465888" then ok("arm 1: the sampler exports the host's MemFree (" .. v .. " kB)")
else bad("arm 1: sampler exported [" .. v .. "], want 4465888") end

v = sample(W .. "/host-meminfo", "777")
if v == "777" then ok("arm 2: a figure already set is kept") else bad("arm 2: preset overwritten -> [" .. v .. "]") end

local rc, o = drive("200000")
if rc == 1 and o:find("refused:gate:insufficient-memory", 1, true) then ok("arm 3: a starved host figure stops the gate (rc 1)")
else bad("arm 3: starved host figure did not stop the gate (rc=" .. tostring(rc) .. "): " .. o) end

rc, o = drive("8000000")
local i4 = o:find("INFO: ok:gate-memory:7812MB", 1, true)
if rc == 0 and i4 and o:find("consumer-block-completed", i4, true) then ok("arm 4: a healthy host figure proceeds, judged from it (7812MB)")
else bad("arm 4: healthy host figure (rc=" .. tostring(rc) .. "): " .. o) end

rc, o = drive("abc")
if o:find("gate-host-meminfo", 1, true) then bad("arm 5: a non-numeric figure was used: " .. o)
elseif o:find("leftover=0", 1, true) then ok("arm 5: a non-numeric figure is ignored, no temp meminfo left (rc=" .. tostring(rc) .. ")")
else bad("arm 5: " .. o) end

fs.write(rel .. "/host-starved", "MemTotal:       16000000 kB\nMemFree:          300000 kB\n")
local fig = sample(W .. "/host-starved")
rc, o = drive(fig)
local i6 = o:find("refused:gate:insufficient-memory (292MB available", 1, true)
if rc == 1 and i6 and o:find("leftover=0", i6, true) then ok("arm 6: end to end, the host's 292MB is judged and refused, temp file removed")
else bad("arm 6: end to end (fig=" .. fig .. " rc=" .. tostring(rc) .. "): " .. o) end

cleanup()
local total = pass + failn
if failn == 0 then verdict.ok("gate-host-memory-figure:" .. pass .. "/" .. total) end
verdict.emit("violation:gate-host-memory-figure:" .. pass .. "/" .. total, 1)
