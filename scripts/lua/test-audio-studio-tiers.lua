-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:2055-d9sa
--
-- test-audio-studio-tiers.lua — the audio studio's tier tool
-- (images/audio-studio/audio-tool, `tiers`) builds cumulative mixes that each
-- contain EXACTLY their stems, at the LUFS target (2055-d9sa).
--
-- The stems are synthesised here, in Lua, so the fixture owns its premise:
-- 2 s of 48 kHz mono 16-bit PCM each, pure tones at integer hertz over exactly
-- 2 s (so they are orthogonal):  drums 300 Hz, bass 80 Hz, other 1200 Hz.
-- Tiers [[drums],[drums,bass],[drums,bass,other]] at -20 LUFS.
--   1-3 EXACT     each tier's mix is a scalar multiple of the sum of exactly
--                 its stems: residual energy against that sum < 1e-6 of the
--                 mix's, and its normalised correlation with every stem it
--                 does NOT name < 1e-3 (read back by this fixture, not by the
--                 tool)
--   4-6 LUFS      each mix measures -20 +/- 0.5 LUFS by ffmpeg's ebur128, an
--                 implementation independent of the tool's pyloudnorm
--   7   UNKNOWN   a tier naming a stem that is not there refuses
--                 invalid_arguments and writes nothing
--   8   MISMATCH  a stem of a different length refuses invalid_arguments
--   9   CLIP      a target the stems cannot reach without clipping refuses
--                 would_clip
-- The tool runs in images/audio-studio (--network=none), built here.
--
-- PRE-FIX: audio-tool has no tiers subcommand and refuses it.
-- Verdict: ok:audio-studio-tiers:<arms>; violation:...; could-not-run:...

local CF = "images/audio-studio/Containerfile"
if not fs.exists(CF) then verdict.emit("violation:audio-studio-tiers:no-studio", 1, CF .. " does not exist") end
local TAG = "localhost/tillandsias-audio-studio:tiers-fixture"
local SR, DUR = 48000, 2
local N = SR * DUR
local STEMS = { drums = { f = 300, a = 0.15 }, bass = { f = 80, a = 0.20 }, other = { f = 1200, a = 0.10 } }
local ORDER = { "drums", "bass", "other" }
local TIERS = { { "drums" }, { "drums", "bass" }, { "drums", "bass", "other" } }
local TARGET = -20

local function wav16(x)
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

-- The quantised samples, as the tool reads them back (int16 / 32768).
local samples = {}
for _, name in ipairs(ORDER) do
    local s, q = STEMS[name], {}
    local w = 2 * math.pi * s.f / SR
    for n = 0, N - 1 do q[n + 1] = s.a * math.sin(w * n) end
    samples[name] = q
end
local function quant(x)
    local v = math.floor(x * 32767 + 0.5)
    if v > 32767 then v = 32767 elseif v < -32768 then v = -32768 end
    return v / 32768
end

local here = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
local REL = "target/plan-scratch/audio-tiers-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
for _, d in ipairs({ "/in/stems", "/in/bad", "/out" }) do fs.mkdir(REL .. d) end
for _, name in ipairs(ORDER) do
    fs.write(REL .. "/in/stems/" .. name .. ".wav", wav16(samples[name]))
    local q = {}
    for i = 1, N do q[i] = quant(samples[name][i]) end
    samples[name] = q
end
-- The mismatch set: drums at half length.
local short = {}
for i = 1, N // 2 do short[i] = samples.drums[i] end
fs.write(REL .. "/in/bad/drums.wav", wav16(short))
fs.write(REL .. "/in/bad/bass.wav", wav16(samples.bass))

local build = proc.run{ argv = { "podman", "build", "-q", "-t", TAG, "-f", here .. "/" .. CF, here .. "/images/audio-studio" },
                        timeout_ms = 1800000 }
if not build.ok then
    log.raw(text.trim((build.stdout or "") .. "\n" .. (build.stderr or "")))
    verdict.emit("could-not-run:audio-studio-tiers:image-build:" .. (build.status or "?"), 2)
end

local function studio(args, entry)
    local argv = { "podman", "run", "--rm", "--network=none", "--pull=never", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--security-opt=label=disable", "--userns=keep-id:uid=1001,gid=1001",
        "-v", here .. "/" .. REL .. ":/work/tmp/audio" }
    if entry then argv[#argv + 1] = "--entrypoint"; argv[#argv + 1] = entry end
    argv[#argv + 1] = TAG
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run{ argv = argv, timeout_ms = 300000 }
end

local passes, fails = 0, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok: " .. name)
    else fails = fails + 1; out.line("FAIL: " .. name .. (got and (" — got: " .. tostring(got)) or "")) end
end

local spec = '[["drums"],["drums","bass"],["drums","bass","other"]]'
local r = studio({ "tiers", "--stems", "/work/tmp/audio/in/stems", "--tiers", spec, "--output", "/work/tmp/audio/out",
                   "--param", "target_lufs=" .. TARGET })
local ok, res = pcall(json.parse, r.stdout or "")
if not (r.ok and ok and type(res) == "table" and type(res.tiers) == "table" and #res.tiers == 3) then
    log.raw(text.trim((r.stdout or "") .. "\n" .. (r.stderr or "")))
    arm("tiers answers JSON with three tiers", false, text.trim(r.stdout or ""):sub(1, 300))
else
    -- Read a 32-bit float mono WAV back.
    local function readf(path)
        local b = fs.read(path)
        local at = b:find("data", 13, true)
        if not at then return nil end
        local len = string.unpack("<I4", b, at + 4)
        local x, p = {}, at + 8
        for i = 1, len // 4 do x[i] = string.unpack("<f", b, p + (i - 1) * 4) end
        return x
    end
    for n, t in ipairs(TIERS) do
        local m = readf(REL .. "/out/tier-" .. n .. ".wav")
        local name = "tier " .. n .. " (" .. table.concat(t, "+") .. ")"
        if not m or #m ~= N then
            arm(name .. ": contains exactly its stems", false, "mix unreadable or wrong length " .. tostring(m and #m))
        else
            local S, inT = {}, {}
            for _, s in ipairs(t) do inT[s] = true end
            for i = 1, N do
                local v = 0
                for _, s in ipairs(t) do v = v + samples[s][i] end
                S[i] = v
            end
            local ms, ss, mm = 0, 0, 0
            for i = 1, N do ms = ms + m[i] * S[i]; ss = ss + S[i] * S[i]; mm = mm + m[i] * m[i] end
            local g = ms / ss
            local rr = 0
            for i = 1, N do local d = m[i] - g * S[i]; rr = rr + d * d end
            local worst = 0
            for _, s in ipairs(ORDER) do
                if not inT[s] then
                    local c, kk = 0, 0
                    for i = 1, N do c = c + m[i] * samples[s][i]; kk = kk + samples[s][i] * samples[s][i] end
                    worst = math.max(worst, math.abs(c) / math.sqrt(mm * kk))
                end
            end
            arm(name .. ": contains exactly its stems", rr / mm < 1e-6 and worst < 1e-3,
                string.format("residual=%.3g excluded-corr=%.3g", rr / mm, worst))
        end
    end
    for n, t in ipairs(TIERS) do
        local e = studio({ "-nostdin", "-hide_banner", "-nostats", "-i", "/work/tmp/audio/out/tier-" .. n .. ".wav",
                           "-af", "ebur128", "-f", "null", "-" }, "ffmpeg")
        local all = (e.stdout or "") .. (e.stderr or "")
        local lufs = tonumber(all:match("Integrated loudness:%s*I:%s*(%-?[%d.]+) LUFS"))
        arm(string.format("tier %d (%s): %d LUFS by ebur128", n, table.concat(t, "+"), TARGET),
            lufs ~= nil and math.abs(lufs - TARGET) <= 0.5, tostring(lufs))
    end
end

local u = studio({ "tiers", "--stems", "/work/tmp/audio/in/stems", "--tiers", '[["drums","vocals"]]', "--output", "/work/tmp/audio/out-u" })
arm("a tier naming a missing stem refuses invalid_arguments, writes nothing",
    u.code == 2 and (u.stdout or ""):find("invalid_arguments: tier", 1, true) ~= nil and not fs.exists(REL .. "/out-u/tier-1.wav"),
    text.trim(u.stdout or ""))
local b = studio({ "tiers", "--stems", "/work/tmp/audio/in/bad", "--tiers", '[["drums","bass"]]', "--output", "/work/tmp/audio/out-b" })
arm("a stem of another length refuses invalid_arguments",
    b.code == 2 and (b.stdout or ""):find("every stem must match", 1, true) ~= nil, text.trim(b.stdout or ""))
local c = studio({ "tiers", "--stems", "/work/tmp/audio/in/stems", "--tiers", spec, "--output", "/work/tmp/audio/out-c",
                   "--param", "target_lufs=-5" })
arm("a target the stems cannot reach unclipped refuses would_clip",
    c.code == 2 and (c.stdout or ""):find("would_clip:", 1, true) ~= nil, text.trim(c.stdout or ""))

out.line("audio-studio tier fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:audio-studio-tiers:" .. passes .. "-arms", 0) end
verdict.emit("violation:audio-studio-tiers:failed=" .. fails, 1)
