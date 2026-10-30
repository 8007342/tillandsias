-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:1921-7aa5 (spec: openspec/changes/local-image-generation, not yet archived)
--
-- test-studio-custom-nodes.lua — the build-time custom-node check
-- (images/imagegen-studio/custom-nodes.py verify) passes on exactly the
-- manifest set and fails on each way an image could drift from it: a node dir
-- not in the manifest, a node at another commit, a missing node, and any
-- ComfyUI-Manager path anywhere under the image root.
--
-- The arms are custom-nodes.py's own selftest, run inside the studio's pinned
-- Python base image with --network none: Python is the image's runtime, never
-- the host's (1087-h2z9).
-- Verdict ok:studio-custom-nodes:<arms>, violation:... otherwise.

local function base_image()
    local cf = fs.read("images/imagegen-studio/Containerfile") or ""
    return cf:match("\nFROM%s+(%S+)")
end

local image = base_image()
if not image then
    verdict.emit("could-not-run:studio-custom-nodes:no-FROM-in-the-studio-Containerfile", 2)
end

-- 1926-pjn8: THE VERDICT IS THE CONTAINER'S STDOUT, NEVER STDERR. The first
-- form judged the LAST line of stdout..stderr, so when the base image was not
-- yet in the store podman's pull progress ("Writing manifest to image
-- destination") was that line and a passing selftest read as a violation
-- (v56.10.30.1 cut gate, 2026-10-30). The image is pre-pulled quietly as its
-- own step, and judge() reads stdout alone.
local function judge(ok, stdout)
    local out = text.trim(stdout or "")
    local last = out:match("([^\n]*)$") or ""
    if last:find("^ok:studio%-custom%-nodes:") and ok then return last, 0 end
    if not ok and not last:find("^violation:") then return nil, 2 end
    return "violation:studio-custom-nodes:" .. last, 1
end

-- ARM 0 (1926-pjn8): a passing selftest followed by pull-progress noise on
-- stderr is still a pass. Judged before the container runs, on synthetic input,
-- so it holds on a host whose store already has the image (the warm case that
-- hid the defect).
local noisy_stdout = "arm 1 ok\nok:studio-custom-nodes:6-arms\n"
local noisy_stderr = "Copying blob sha256:0000\nWriting manifest to image destination\n"
local v0, c0 = judge(true, noisy_stdout, noisy_stderr)
if c0 ~= 0 or v0 ~= "ok:studio-custom-nodes:6-arms" then
    verdict.emit("violation:studio-custom-nodes:arm0-pull-noise-on-stderr-decided-the-verdict:" .. tostring(v0), 1)
end

local pull = proc.run{ argv = { "podman", "pull", "-q", image }, timeout_ms = 600000 }
if not pull.ok then
    verdict.emit("could-not-run:studio-custom-nodes:podman-pull:" .. (pull.status or "?"), 2)
end

local here = text.trim(proc.run{ argv = { "pwd" }, timeout_ms = 5000 }.stdout or "")
local r = proc.run{ argv = { "podman", "run", "--rm", "--network=none", "--pull=never",
    "--security-opt=label=disable", "-v", here .. "/images/imagegen-studio:/s:ro",
    "--entrypoint", "python", image, "/s/custom-nodes.py", "selftest", "/s/custom-nodes.toml" },
    timeout_ms = 600000 }
log.raw(text.trim((r.stdout or "") .. "\n" .. (r.stderr or "")))

local v, code = judge(r.ok, r.stdout, r.stderr)
if code == 2 then
    verdict.emit("could-not-run:studio-custom-nodes:podman:" .. (r.status or "?"), 2)
end
verdict.emit(v, code)
