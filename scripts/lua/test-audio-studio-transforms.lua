-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:2055-grzz
--
-- test-audio-studio-transforms.lua — each named transform of the audio studio
-- appliance (images/audio-studio/audio-tool, `transform`) RUNS in the image and
-- does what it says, judged by a measured property, never by listening:
--   loudness_normalise  output integrated loudness within 0.5 LU of -20 LUFS
--   time_stretch        rubberband: output duration 1.5x the input's (+-2%)
--   to_opus / to_aac    ffmpeg (libopus, native aac): an output ffprobe decodes,
--                       with the input's duration (+-0.1 s) and that codec
--   resample            sox: output at the requested 22050 Hz
-- plus two refusals inside the appliance: an existing output (output_exists)
-- and a path outside /work/tmp/audio (invalid_arguments).
-- The input is 2 s of a 440 Hz tone at -30 dBFS, written here in Lua.
-- The image is built from images/audio-studio exactly as
-- test-audio-studio-glitches.lua builds it (same tag; the layer cache makes a
-- second build seconds).
-- PRE-FIX: with no images/audio-studio/Containerfile the fixture refuses.

local CF = "images/audio-studio/Containerfile"
if not fs.exists(CF) then verdict.emit("violation:audio-studio-transforms:no-studio", 1, CF .. " does not exist") end
local TAG = "localhost/tillandsias-audio-studio:glitch-fixture"
local SR, DUR = 48000, 2

local parts = {}
for n = 0, SR * DUR - 1 do
    parts[#parts + 1] = string.pack("<i2", math.floor(0.0316 * 32767 * math.sin(2 * math.pi * 440 * n / SR) + 0.5))
end
local data = table.concat(parts)
local wav = "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVE" .. "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, SR, SR * 2, 2, 16)
    .. "data" .. string.pack("<I4", #data) .. data

local here = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
local REL = "target/plan-scratch/audio-transforms-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. math.random(100000, 999999)
fs.mkdir(REL); fs.mkdir(REL .. "/in")
fs.write(REL .. "/in/tone.wav", wav)

local build = proc.run{ argv = { "podman", "build", "-q", "-t", TAG, "-f", here .. "/" .. CF, here .. "/images/audio-studio" }, timeout_ms = 1800000 }
if not build.ok then verdict.emit("could-not-run:audio-studio-transforms:image-build:" .. (build.status or "?"), 2) end

-- The scratch dir is the appliance's /work/tmp/audio, read-write, as the
-- lane volume is; uid 1001 is mapped to the host user.
local function appliance(args, entry)
    local argv = { "podman", "run", "--rm", "--network=none", "--pull=never", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--security-opt=label=disable", "--userns=keep-id:uid=1001,gid=1001",
        "-v", here .. "/" .. REL .. ":/work/tmp/audio" }
    if entry then argv[#argv + 1] = "--entrypoint"; argv[#argv + 1] = entry end
    argv[#argv + 1] = TAG
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, timeout_ms = 600000 }
    local ok, v = pcall(json.parse, text.trim(r.stdout or ""))
    return r, ok and v or nil
end
local function probe(path)
    local r = appliance({ "-v", "error", "-show_entries", "stream=codec_name,sample_rate:format=duration", "-of", "json", path }, "ffprobe")
    local ok, j = pcall(json.parse, r.stdout or "")
    if ok and type(j) == "table" and j.streams and j.streams[1] then
        return { codec = j.streams[1].codec_name, rate = tonumber(j.streams[1].sample_rate), dur = tonumber(j.format and j.format.duration) }
    end
    return nil
end

local passes, fails = 0, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok: " .. name)
    else fails = fails + 1; out.line("FAIL: " .. name .. (got and (" — got: " .. got) or "")) end
end
local IN = "/work/tmp/audio/in/tone.wav"
local function t(op, out, params)
    local a = { "transform", "--op", op, "--input", IN, "--output", out }
    for _, p in ipairs(params or {}) do a[#a + 1] = "--param"; a[#a + 1] = p end
    return appliance(a)
end

local r, v = t("loudness_normalise", "/work/tmp/audio/out/norm.wav", { "target_lufs=-20" })
arm("loudness_normalise reaches -20 LUFS (+-0.5)", v and v.measurements and math.abs((v.measurements.lufs_after or 99) + 20) <= 0.5,
    v and json.encode and json.encode(v.measurements) or text.trim((r.stdout or "") .. (r.stderr or "")))

r, v = t("time_stretch", "/work/tmp/audio/out/slow.wav", { "ratio=1.5" })
local p = probe("/work/tmp/audio/out/slow.wav")
arm("time_stretch (rubberband) makes the duration 1.5x (+-2%)", p and p.dur and math.abs(p.dur / DUR - 1.5) <= 0.03, p and tostring(p.dur) or text.trim(r.stdout or ""))

r, v = t("to_opus", "/work/tmp/audio/out/tone.opus", { "bitrate_kbps=96" })
p = probe("/work/tmp/audio/out/tone.opus")
arm("to_opus writes a decodable opus stream of the input's length", p and p.codec == "opus" and p.dur and math.abs(p.dur - DUR) <= 0.1,
    p and (tostring(p.codec) .. "/" .. tostring(p.dur)) or text.trim(r.stdout or ""))

r, v = t("to_aac", "/work/tmp/audio/out/tone.m4a")
p = probe("/work/tmp/audio/out/tone.m4a")
arm("to_aac writes a decodable aac stream of the input's length", p and p.codec == "aac" and p.dur and math.abs(p.dur - DUR) <= 0.1,
    p and (tostring(p.codec) .. "/" .. tostring(p.dur)) or text.trim(r.stdout or ""))

r, v = t("resample", "/work/tmp/audio/out/low.wav", { "rate=22050" })
p = probe("/work/tmp/audio/out/low.wav")
arm("resample (sox) writes 22050 Hz", p and p.rate == 22050, p and tostring(p.rate) or text.trim(r.stdout or ""))

r, v = t("to_aac", "/work/tmp/audio/out/tone.m4a")
arm("an existing output is refused inside the appliance (output_exists)", r.code == 2 and v and tostring(v.error):find("^output_exists") ~= nil, text.trim(r.stdout or ""))

r, v = appliance({ "transform", "--op", "to_opus", "--input", "/etc/hostname", "--output", "/work/tmp/audio/out/x.opus" })
arm("a path outside /work/tmp/audio is refused inside the appliance", r.code == 2 and v and tostring(v.error):find("^invalid_arguments") ~= nil, text.trim(r.stdout or ""))

out.line("audio-studio transform fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:audio-studio-transforms:" .. passes .. "-arms", 0) end
verdict.emit("violation:audio-studio-transforms:failed=" .. fails, 1)
