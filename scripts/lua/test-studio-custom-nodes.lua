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

local here = text.trim(proc.run{ argv = { "pwd" }, timeout_ms = 5000 }.stdout or "")
local r = proc.run{ argv = { "podman", "run", "--rm", "--network=none",
    "--security-opt=label=disable", "-v", here .. "/images/imagegen-studio:/s:ro",
    "--entrypoint", "python", image, "/s/custom-nodes.py", "selftest", "/s/custom-nodes.toml" },
    timeout_ms = 600000 }
local out = text.trim((r.stdout or "") .. "\n" .. (r.stderr or ""))
log.raw(out)

local last = out:match("([^\n]*)$") or ""
if not r.ok and not last:find("^violation:") then
    verdict.emit("could-not-run:studio-custom-nodes:podman:" .. (r.status or "?"), 2)
end
if last:find("^ok:studio%-custom%-nodes:") and r.ok then
    verdict.emit(last, 0)
end
verdict.emit("violation:studio-custom-nodes:" .. last, 1)
