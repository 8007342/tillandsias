-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_DEMUCS_WEIGHTS_DIR
-- @trace order:2068-cqis, order:2055-d9sa
--
-- test-audio-studio-separate.lua — audio-tool `separate` (images/audio-studio)
-- splits a mix into Demucs stems on CPU from safetensors ONLY (2068-cqis).
--
-- The mix is synthesised here, in Lua, so the fixture owns its premise: 8.5 s
-- (longer than the models' 7.8 s segment, so the splitter's overlap-add runs)
-- of 44.1 kHz stereo 16-bit PCM, the sum of
--   bass    a 55 Hz sine with its 110 Hz harmonic
--   drums   LCG-noise hats every 0.25 s (20 ms decay), no kick, so nothing
--           but the bass sits at 55 Hz
--   vocal   a 440 Hz tone with 5 Hz vibrato and two harmonics, panned left
--
-- PIPELINE ARMS, on every host. Weights are a RANDOMLY INITIALISED model of
-- the registered class written as safetensors by `audio-tool fixture-weights`
-- (no acknowledgement needed: they are nobody's weights), bind-mounted
-- read-only at /models:
--   1  htdemucs:    4 stems, float WAV, 44.1 kHz stereo, the input's frames
--   2  htdemucs_6s: 6 stems, the same shape
--   3  a wrong --sha256 is refused weights_refused, nothing written
--   4  a .th file is refused weights_refused (not a .safetensors), whatever
--      its hash
--   5  4-stem weights asked to be htdemucs_6s are refused (wrong sources)
--   6  Demucs's OWN .th loader (demucs.states.load_model) behind the tripwire
--      answers pickle_refused: torch.load cannot run. The file is garbage
--      bytes, never a pickle.
-- REAL-WEIGHTS ARMS, only where TILLANDSIAS_DEMUCS_WEIGHTS_DIR names a
-- directory holding the registered files (the model cache's audio/demucs/,
-- filled by audio.separate after the project's acknowledgement). The reading
-- rule was fixed BEFORE any real run: the stems must sum back to the input
-- at >= 20 dB SNR, and the bass stem must hold more than half of the 55 Hz
-- energy across all stems (Goertzel, both channels).
--   7  htdemucs:    4 stems, reconstruction >= 20 dB, bass holds the 55 Hz
--   8  htdemucs_6s: 6 stems, reconstruction >= 20 dB
-- Without the real weights the pipeline arms still decide (a failure is a
-- violation), and the verdict is could-not-run, never ok: the reconstruction
-- is the criterion's own number and no random model can produce it.
--
-- PRE-FIX: audio-tool has no separate subcommand and refuses every arm.
-- Verdict: ok:audio-studio-separate:<arms>-arms | violation:audio-studio-separate:failed=<n>
--          | could-not-run:audio-studio-separate:<why>

local CF = "images/audio-studio/Containerfile"
if not fs.exists(CF) then verdict.emit("violation:audio-studio-separate:no-studio", 1, CF .. " does not exist") end
local TAG = "localhost/tillandsias-audio-studio:separate-fixture"
local SR, DUR = 44100, 8.5
local N = math.floor(SR * DUR)

-- The registered rows, from the shipped manifest.
local REG = {}
for _, line in ipairs(text.lines(fs.read("images/audio-studio/weights.tsv"))) do
    if line ~= "" and line:sub(1, 1) ~= "#" then
        local c = text.split(line, "\t")
        REG[c[1]] = { file = c[4], sha256 = c[5] }
    end
end
if not (REG.htdemucs and REG.htdemucs_6s) then
    verdict.emit("violation:audio-studio-separate:manifest", 1, "weights.tsv lacks an htdemucs or htdemucs_6s row")
end

-- The mix.
local seed = 20681110
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648 * 2 - 1
end
local L, R = {}, {}
local vph = 0
for n = 0, N - 1 do
    local t = n / SR
    local bass = 0.22 * math.sin(2 * math.pi * 55 * t) + 0.07 * math.sin(2 * math.pi * 110 * t)
    local since = t % 0.25
    local hat = 0.18 * math.exp(-since / 0.02) * rnd()
    vph = vph + 2 * math.pi * (440 + 6 * math.sin(2 * math.pi * 5 * t)) / SR
    local vocal = 0.10 * math.sin(vph) + 0.04 * math.sin(2 * vph) + 0.02 * math.sin(3 * vph)
    L[n + 1] = bass + hat + vocal
    R[n + 1] = bass + hat + 0.4 * vocal
end
local function q16(x)
    local v = math.floor(x * 32767 + 0.5)
    if v > 32767 then v = 32767 elseif v < -32768 then v = -32768 end
    return v
end
local parts = {}
for i = 1, N do parts[i] = string.pack("<i2<i2", q16(L[i]), q16(R[i])) end
local data = table.concat(parts)
local WAV = "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVE"
    .. "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 2, SR, SR * 4, 4, 16)
    .. "data" .. string.pack("<I4", #data) .. data
-- Premise: the file holds N stereo frames.
if #data ~= N * 4 then verdict.emit("violation:audio-studio-separate:premise", 1, "the mix is not " .. N .. " frames") end

local here = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
local REL = "target/plan-scratch/audio-separate-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL .. "/w")
fs.write(REL .. "/mix.wav", WAV)
-- Garbage bytes under a pickle's name: NOT a pickle.
fs.write(REL .. "/w/not-a-pickle.th", "tillandsias fixture: these bytes are not a pickle\n")

local build = proc.run{ argv = { "podman", "build", "-q", "-t", TAG, "-f", here .. "/" .. CF, here .. "/images/audio-studio" },
                        timeout_ms = 3600000 }
if not build.ok then
    log.raw(text.trim((build.stdout or "") .. "\n" .. (build.stderr or "")))
    verdict.emit("could-not-run:audio-studio-separate:image-build:" .. (build.status or "?"), 2)
end

-- mounts: { {host, inside}, ... } bind-mounted read-only.
local function studio(args, mounts)
    local argv = { "podman", "run", "--rm", "--network=none", "--pull=never", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--security-opt=label=disable", "--userns=keep-id:uid=1001,gid=1001",
        "-v", here .. "/" .. REL .. ":/work/tmp/audio" }
    for _, m in ipairs(mounts or {}) do argv[#argv + 1] = "-v"; argv[#argv + 1] = m[1] .. ":" .. m[2] .. ":ro" end
    argv[#argv + 1] = TAG
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, timeout_ms = 900000 }
    local ok, res = pcall(json.parse, r.stdout or "")
    return r, (ok and type(res) == "table") and res or nil
end

local passes, fails = 0, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok: " .. name)
    else fails = fails + 1; out.line("FAIL: " .. name .. (got and (" — got: " .. tostring(got)) or "")) end
end

-- A 32-bit float stereo WAV, read back: frames, rate, channels, L, R.
local function readf(path)
    if not fs.exists(path) then return nil end
    local b = fs.read(path)
    local f = b:find("fmt ", 13, true)
    local at = b:find("data", 13, true)
    if not (f and at) then return nil end
    local fmt, ch, rate = string.unpack("<I2I2I4", b, f + 8)
    local bits = string.unpack("<I2", b, f + 22)
    if fmt ~= 3 or bits ~= 32 then return { bad = "format " .. fmt .. "/" .. bits } end
    local len = string.unpack("<I4", b, at + 4)
    local frames = len // (4 * ch)
    local l, r, p = {}, {}, at + 8
    for i = 1, frames do
        l[i] = string.unpack("<f", b, p); p = p + 4
        if ch == 2 then r[i] = string.unpack("<f", b, p); p = p + 4 end
    end
    return { frames = frames, rate = rate, ch = ch, l = l, r = r }
end

local function shape_ok(res, want)
    if not (res and type(res.stems) == "table" and #res.stems == want) then
        return false, "stems " .. tostring(res and res.stems and #res.stems)
    end
    for _, s in ipairs(res.stems) do
        local w = readf(REL .. "/" .. s.output:sub(#"/work/tmp/audio/" + 1))
        if not w or w.bad or w.rate ~= SR or w.ch ~= 2 or w.frames ~= N then
            return false, s.source .. ": " .. (w and (w.bad or (w.rate .. " Hz " .. w.ch .. "ch " .. w.frames .. " frames")) or "unreadable")
        end
    end
    return true
end

-- PIPELINE ARMS.
local fx = {}
for _, m in ipairs({ "htdemucs", "htdemucs_6s" }) do
    local _, res = studio({ "fixture-weights", "--model", m, "--output", "/work/tmp/audio/w/fx-" .. m .. ".safetensors" })
    fx[m] = res and res.sha256
end
if not (fx.htdemucs and fx.htdemucs_6s) then
    verdict.emit("violation:audio-studio-separate:fixture-weights", 1, "audio-tool fixture-weights wrote no weights (no separate support in this studio)")
end
local function wmount(m) return { { here .. "/" .. REL .. "/w/fx-" .. m .. ".safetensors", "/models/fx.safetensors" } } end

for _, c in ipairs({ { "htdemucs", 4 }, { "htdemucs_6s", 6 } }) do
    local m, want = c[1], c[2]
    local r, res = studio({ "separate", "--model", m, "--weights", "/models/fx.safetensors", "--sha256", fx[m],
                            "--input", "/work/tmp/audio/mix.wav", "--output", "/work/tmp/audio/fx-" .. m }, wmount(m))
    local ok, why = shape_ok(res, want)
    arm(m .. " (fixture weights): " .. want .. " float stems at 44.1 kHz stereo, the input's frames",
        r.ok and ok and res.weights_sha256 == fx[m], why or text.trim(r.stdout or ""):sub(1, 300))
end

local bad = fx.htdemucs:sub(1, 63) .. (fx.htdemucs:sub(64) == "0" and "1" or "0")
local r = studio({ "separate", "--model", "htdemucs", "--weights", "/models/fx.safetensors", "--sha256", bad,
                   "--input", "/work/tmp/audio/mix.wav", "--output", "/work/tmp/audio/wrong-hash" }, wmount("htdemucs"))
arm("a wrong --sha256 is refused weights_refused and writes nothing",
    r.code == 2 and (r.stdout or ""):find("weights_refused:", 1, true) ~= nil and not fs.exists(REL .. "/wrong-hash"),
    text.trim(r.stdout or ""))

r = studio({ "separate", "--model", "htdemucs", "--weights", "/models/x.th", "--sha256", fx.htdemucs,
             "--input", "/work/tmp/audio/mix.wav", "--output", "/work/tmp/audio/th" },
           { { here .. "/" .. REL .. "/w/not-a-pickle.th", "/models/x.th" } })
arm("a .th file is refused weights_refused (not a .safetensors)",
    r.code == 2 and (r.stdout or ""):find("is not a .safetensors file", 1, true) ~= nil, text.trim(r.stdout or ""))

r = studio({ "separate", "--model", "htdemucs_6s", "--weights", "/models/fx.safetensors", "--sha256", fx.htdemucs,
             "--input", "/work/tmp/audio/mix.wav", "--output", "/work/tmp/audio/wrong-model" }, wmount("htdemucs"))
arm("4-stem weights asked to be htdemucs_6s are refused (wrong sources)",
    r.code == 2 and (r.stdout or ""):find("weights_refused:", 1, true) ~= nil
        and (r.stdout or ""):find("separates", 1, true) ~= nil, text.trim(r.stdout or ""))

r = studio({ "fixture-pickle-probe", "--weights", "/models/x.th" },
           { { here .. "/" .. REL .. "/w/not-a-pickle.th", "/models/x.th" } })
arm("Demucs's own .th loader behind the tripwire answers pickle_refused (torch.load cannot run)",
    r.code == 2 and (r.stdout or ""):find("pickle_refused:", 1, true) ~= nil,
    text.trim((r.stdout or "") .. " " .. (r.stderr or "")):sub(1, 300))

-- REAL-WEIGHTS ARMS.
local function goertzel(x, f)
    local w = 2 * math.pi * f / SR
    local k = 2 * math.cos(w)
    local s1, s2 = 0, 0
    for i = 1, #x do
        local s0 = x[i] + k * s1 - s2
        s2 = s1; s1 = s0
    end
    return s1 * s1 + s2 * s2 - k * s1 * s2
end
local DIR = env.get("TILLANDSIAS_DEMUCS_WEIGHTS_DIR") or ""
local real = DIR ~= ""
for _, m in ipairs({ "htdemucs", "htdemucs_6s" }) do
    if real and not proc.run{ argv = { "test", "-f", DIR .. "/" .. REG[m].file }, timeout_ms = 10000 }.ok then real = false end
end
if real then
    for _, c in ipairs({ { "htdemucs", 4 }, { "htdemucs_6s", 6 } }) do
        local m, want = c[1], c[2]
        local inside = "/models/" .. REG[m].file
        local rr, res = studio({ "separate", "--model", m, "--weights", inside, "--sha256", REG[m].sha256,
                                 "--input", "/work/tmp/audio/mix.wav", "--output", "/work/tmp/audio/real-" .. m },
                               { { DIR .. "/" .. REG[m].file, inside } })
        local ok, why = shape_ok(res, want)
        local snr = res and res.reconstruction and tonumber(res.reconstruction.snr_db)
        out.line(string.format("measured: %s reconstruction snr_db=%s", m, tostring(snr)))
        arm(m .. " (registered weights): " .. want .. " stems, reconstruction >= 20 dB",
            rr.ok and ok and res.weights_sha256 == REG[m].sha256 and snr ~= nil and snr >= 20,
            why or ("snr_db=" .. tostring(snr) .. " " .. text.trim(rr.stdout or ""):sub(1, 200)))
        if m == "htdemucs" and ok then
            local at, total = nil, 0
            for _, s in ipairs(res.stems) do
                local w = readf(REL .. "/" .. s.output:sub(#"/work/tmp/audio/" + 1))
                local e = goertzel(w.l, 55) + goertzel(w.r, 55)
                total = total + e
                if s.source == "bass" then at = e end
            end
            local share = (at and total > 0) and at / total or 0
            out.line(string.format("measured: htdemucs bass share of 55 Hz energy=%.3f", share))
            arm("htdemucs (registered weights): the bass stem holds more than half the 55 Hz energy", share > 0.5,
                string.format("%.3f", share))
        end
    end
end

out.line("audio-studio separate fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails > 0 then verdict.emit("violation:audio-studio-separate:failed=" .. fails, 1) end
if not real then
    verdict.emit("could-not-run:audio-studio-separate:no-registered-weights", 2,
        "the " .. passes .. " pipeline arms passed; the reconstruction arms need the registered Demucs safetensors in "
        .. "TILLANDSIAS_DEMUCS_WEIGHTS_DIR (the model cache's audio/demucs/, filled by audio.separate after the "
        .. "project's licence acknowledgement)")
end
verdict.emit("ok:audio-studio-separate:" .. passes .. "-arms", 0)
