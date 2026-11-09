-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:2055-grzz
--
-- test-audio-studio-glitches.lua — the audio studio's glitch detector
-- (images/audio-studio/audio-tool, `detect`) finds each of the five fault
-- kinds at its PLANTED time range and reports nothing on a clean control.
--
-- The audio is synthesised here, in Lua, so the fixture owns its premise:
-- 3 s of 48 kHz mono 16-bit PCM, the sum of 80 tones at 100..8000 Hz (integer
-- hertz over exactly 3 s, so the clean file loops seamlessly) with fixed
-- pseudo-random phases. One file per fault, each with exactly one fault:
--   click          one sample +0.6 at 1.200 s
--   dropout        digital silence over [0.800, 0.850) s
--   spectral_hole  the 2000-4000 Hz tones faded out over [1.500, 2.000] s
--                  (10 ms raised-cosine ramps, so the edges are not clicks)
--   clipping       x10 gain clamped to full scale over [2.300, 2.400] s
--                  (5 ms gain ramps)
--   loop_seam      the clean signal cut at 2.9876 s: looping it jumps
-- Before any verdict the fixture asserts each planted fault is really in the
-- samples it wrote (a zero run, a full-scale run, the spike), so a generator
-- bug cannot pass as a detector pass.
--
-- The detector is Python with numpy/scipy/librosa INSIDE the appliance image
-- (operator approval, 2026-11-08 relay), never the host's: the fixture builds
-- images/audio-studio and runs it with --network=none, read-only input.
--
-- PRE-FIX: with no images/audio-studio/Containerfile the fixture refuses
-- (violation, exit 1), never a skip.
-- Verdict: ok:audio-studio-glitches:<arms>; violation:...; could-not-run:...
-- when podman cannot build or run the image (exit 2).

local CF = "images/audio-studio/Containerfile"
if not fs.exists(CF) then
    verdict.emit("violation:audio-studio-glitches:no-studio", 1, CF .. " does not exist")
end

local SR, DUR = 48000, 3
local N = SR * DUR
local TAG = "localhost/tillandsias-audio-studio:glitch-fixture"

-- Deterministic phases (an LCG; the same file every run).
local seed = 20551108
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end

-- The clean signal, split into the hole band (2000..4000 Hz) and the rest.
local band, rest = {}, {}
local tones = {}
for f = 100, 8000, 100 do tones[#tones + 1] = { f = f, ph = rnd() * 2 * math.pi, inband = (f >= 2000 and f <= 4000) } end
local AMP = 0.008
local w = 2 * math.pi / SR
for n = 0, N - 1 do
    local b, r = 0.0, 0.0
    for _, t in ipairs(tones) do
        local v = AMP * math.sin(w * t.f * n + t.ph)
        if t.inband then b = b + v else r = r + v end
    end
    band[n + 1], rest[n + 1] = b, r
end

local function clean()
    local x = {}
    for i = 1, N do x[i] = band[i] + rest[i] end
    return x
end
local function idx(t) return math.floor(t * SR + 0.5) + 1 end  -- seconds -> 1-based sample
-- A gain envelope: 1 outside [t0,t1], g inside, with raised-cosine ramps of
-- `ramp` seconds just outside the range.
local function envelope(t0, t1, g, ramp)
    return function(i)
        local t = (i - 1) / SR
        local function rc(u) return 0.5 - 0.5 * math.cos(math.pi * u) end
        if t >= t0 and t <= t1 then return g end
        if t < t0 and t > t0 - ramp then return 1 + (g - 1) * rc((t - (t0 - ramp)) / ramp) end
        if t > t1 and t < t1 + ramp then return g + (1 - g) * rc((t - t1) / ramp) end
        return 1
    end
end

local files = {}
local function add(name, kind, x, t0, t1, loop) files[#files + 1] = { name = name, kind = kind, x = x, t0 = t0, t1 = t1, loop = loop } end

add("clean", nil, clean(), nil, nil, true)
do
    local x = clean(); x[idx(1.2)] = x[idx(1.2)] + 0.6
    add("click", "click", x, 1.2, 1.2 + 1 / SR)
end
do
    local x = clean(); for i = idx(0.8), idx(0.85) - 1 do x[i] = 0.0 end
    add("dropout", "dropout", x, 0.8, 0.85)
end
do
    local g = envelope(1.5, 2.0, 0.0, 0.010)
    local x = {}; for i = 1, N do x[i] = rest[i] + band[i] * g(i) end
    add("spectral_hole", "spectral_hole", x, 1.5, 2.0)
end
do
    local g = envelope(2.3, 2.4, 10.0, 0.005)
    local x = clean()
    for i = 1, N do local v = x[i] * g(i); if v > 1 then v = 1 elseif v < -1 then v = -1 end; x[i] = v end
    add("clipping", "clipping", x, 2.3, 2.4)
end
do
    local cut = math.floor(2.9876 * SR)
    local x = {}; local c = clean(); for i = 1, cut do x[i] = c[i] end
    add("loop_seam", "loop_seam", x, (cut / SR) - 0.02, cut / SR, true)
    -- What looping plays after the last sample (x[1]) against what the
    -- signal would have played (c[cut + 1]): the seam's jump.
    files[#files].jump = math.abs(c[cut + 1] - c[1])
end

-- PREMISE: each planted fault is in the samples (before any detector runs).
local function premise(f)
    local x = f.x
    if f.kind == "click" then
        local i = idx(1.2); return math.abs(x[i] - x[i - 1]) > 0.4 and math.abs(x[i] - x[i + 1]) > 0.4
    elseif f.kind == "dropout" then
        for i = idx(0.8), idx(0.85) - 1 do if x[i] ~= 0 then return false end end; return true
    elseif f.kind == "clipping" then
        local run, best = 0, 0
        for i = idx(2.3), idx(2.4) do if math.abs(x[i]) >= 1 then run = run + 1; if run > best then best = run end else run = 0 end end
        return best >= 3
    elseif f.kind == "spectral_hole" then
        for i = idx(1.55), idx(1.95) do if math.abs(x[i] - rest[i]) > 1e-12 then return false end end; return true
    elseif f.kind == "loop_seam" then
        return f.jump > 0.02
    end
    -- clean: no sample at full scale, no zero run, and it loops (integer cycles).
    for i = 1, N do if math.abs(x[i]) >= 0.99 then return false end end
    return #x == N
end
for _, f in ipairs(files) do
    if not premise(f) then verdict.emit("violation:audio-studio-glitches:premise:" .. f.name, 1, "the planted fault is not in the generated samples") end
end

-- 16-bit PCM WAV.
local function wav(x)
    local parts = {}
    for i = 1, #x do
        local v = math.floor(x[i] * 32767 + 0.5)
        if v > 32767 then v = 32767 elseif v < -32768 then v = -32768 end
        parts[i] = string.pack("<i2", v)
    end
    local data = table.concat(parts)
    return "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVE"
        .. "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, SR, SR * 2, 2, 16)
        .. "data" .. string.pack("<I4", #data) .. data
end

local here = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
local REL = "target/plan-scratch/audio-glitches-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
for _, f in ipairs(files) do fs.write(REL .. "/" .. f.name .. ".wav", wav(f.x)) end

local build = proc.run{ argv = { "podman", "build", "-q", "-t", TAG, "-f", here .. "/" .. CF, here .. "/images/audio-studio" },
                        timeout_ms = 1800000 }
if not build.ok then
    log.raw(text.trim((build.stdout or "") .. "\n" .. (build.stderr or "")))
    verdict.emit("could-not-run:audio-studio-glitches:image-build:" .. (build.status or "?"), 2)
end

local passes, fails = 0, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok: " .. name)
    else fails = fails + 1; out.line("FAIL: " .. name .. (got and (" — got: " .. got) or "")) end
end

local TOL = 0.030  -- seconds of slack on each edge of a planted range
for _, f in ipairs(files) do
    local argv = { "podman", "run", "--rm", "--network=none", "--pull=never", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--security-opt=label=disable",
        "-v", here .. "/" .. REL .. ":/work/tmp/audio/in:ro", TAG,
        "detect", "--input", "/work/tmp/audio/in/" .. f.name .. ".wav" }
    if f.loop then argv[#argv + 1] = "--loop" end
    local r = proc.run{ argv = argv, timeout_ms = 300000 }
    if not r.ok then
        log.raw(text.trim((r.stdout or "") .. "\n" .. (r.stderr or "")))
        verdict.emit("could-not-run:audio-studio-glitches:detect:" .. f.name .. ":" .. (r.status or "?"), 2)
    end
    local ok, res = pcall(json.parse, r.stdout or "")
    if not ok or type(res) ~= "table" or type(res.findings) ~= "table" then
        arm(f.name .. ": detect returns JSON findings", false, text.trim(r.stdout or ""))
    else
        local kinds = {}
        for _, x in ipairs(res.findings) do kinds[#kinds + 1] = tostring(x.kind) .. "@" .. tostring(x.start) .. "-" .. tostring(x["end"]) end
        local summary = table.concat(kinds, ",")
        if f.kind == nil then
            arm(f.name .. ": the clean control (looped) has no findings", #res.findings == 0, summary)
        else
            local hit, other = false, false
            for _, x in ipairs(res.findings) do
                if x.kind == f.kind then
                    local s, e = tonumber(x.start), tonumber(x["end"])
                    if s and e and s >= f.t0 - TOL and e <= f.t1 + TOL and e >= s then hit = true end
                else
                    other = true
                end
            end
            arm(f.name .. ": found at its planted range [" .. f.t0 .. ", " .. f.t1 .. "]", hit, summary)
            arm(f.name .. ": no finding of another kind", not other, summary)
        end
    end
end

out.line("audio-studio glitch fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:audio-studio-glitches:" .. passes .. "-arms", 0) end
verdict.emit("violation:audio-studio-glitches:failed=" .. fails, 1)
