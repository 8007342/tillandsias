-- @env HOME TILLANDSIAS_STUDIO_IMAGE TILLANDSIAS_STUDIO_MODELS
-- @read-env TILLANDSIAS_STUDIO_IMAGE TILLANDSIAS_STUDIO_MODELS
-- @trace order:1921-vkrr, order:1874-zry8
--
-- probe-studio-placement.lua — proves the ComfyUI studio places a one-step
-- SDXL-Lightning generation on CUDA in a rootless CDI sibling, and that the
-- in-image probe catches a silent CPU fallback. Device nodes are not placement
-- (917-zkge): the studio is offered only where this passes.
--
-- Two runs of the studio image, both --network=none, the shared model cache
-- read-only at /models:
--   gpu: --device nvidia.com/gpu=all           -> must print backend=cuda, exit 0
--   cpu: the same with CUDA_VISIBLE_DEVICES='' -> must print backend=cpu, exit 1
-- Verdict ok:studio-placement:<gpu line>, violation:... otherwise.

local home = env.get("HOME") or ""
local image = env.get("TILLANDSIAS_STUDIO_IMAGE") or "localhost/tillandsias-imagegen-studio:latest"
local models = env.get("TILLANDSIAS_STUDIO_MODELS") or (home .. "/.cache/tillandsias/models/imagegen")

-- The cache lives outside the repo, where fs.* refuses to look.
if proc.run{ argv = { "test", "-f", models .. "/I1/sdxl_lightning_4step.safetensors" } }.code ~= 0 then
    verdict.emit("could-not-run:studio-placement:no-I1-checkpoint-under:" .. models, 2)
end

local function run(extra)
    local argv = { "podman", "run", "--rm", "--network=none", "--security-opt=label=disable",
        "--device", "nvidia.com/gpu=all", "-v", models .. ":/models:ro" }
    for _, a in ipairs(extra) do argv[#argv + 1] = a end
    for _, a in ipairs({ "--entrypoint", "python", image, "/opt/tillandsias/probe-placement.py" }) do
        argv[#argv + 1] = a
    end
    local r = proc.run{ argv = argv, timeout_ms = 1800000 }
    local out = (r.stdout or "") .. (r.stderr or "")
    local line = out:match("(backend=%S+[^\n]*)") or out:match("(could%-not%-run:[^\n]*)") or text.trim(out)
    return r.code, line
end

local gcode, gline = run({})
log.raw("gpu run: exit " .. tostring(gcode) .. " " .. gline)
local ccode, cline = run({ "-e", "CUDA_VISIBLE_DEVICES=" })
log.raw("cpu run: exit " .. tostring(ccode) .. " " .. cline)

if gcode ~= 0 or not gline:find("^backend=cuda") then
    verdict.emit("violation:studio-placement:gpu-run-not-cuda", 1)
end
if ccode ~= 1 or not cline:find("^backend=cpu") then
    verdict.emit("violation:studio-placement:cpu-fallback-not-caught", 1)
end
verdict.emit("ok:studio-placement:" .. gline:gsub("%s+", ":"), 0)
