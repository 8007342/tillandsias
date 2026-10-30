-- @env PATH HOME
-- @trace order:1921-7aa5 (spec: openspec/changes/local-image-generation, not yet archived)
--
-- test-studio-custom-nodes.lua — the build-time custom-node check
-- (images/imagegen-studio/custom-nodes.py verify) passes on exactly the
-- manifest set and fails on each way an image could drift from it: a node dir
-- not in the manifest, a node at another commit, a missing node, and any
-- ComfyUI-Manager path anywhere under the image root.
-- Verdict ok:studio-custom-nodes:<arms>, violation:... otherwise.

local verifier = "images/imagegen-studio/custom-nodes.py"
local manifest = "images/imagegen-studio/custom-nodes.toml"

local function run(argv)
    local r = proc.run{ argv = argv, timeout_ms = 30000 }
    return r.code or (r.ok and 0 or -1), text.trim((r.stdout or "") .. (r.stderr or ""))
end

-- Builds one image root holding the manifest set, then applies the arm's
-- drift. Argv only: the runner refuses shell strings (1252-fg9e).
local SETUP = [[
import os, shutil, sys, tomllib
manifest, root, arm = sys.argv[1:4]
nodes = os.path.join(root, "opt/comfyui/custom_nodes")
pins = tomllib.load(open(manifest, "rb"))["node"]
os.makedirs(os.path.join(nodes, "__pycache__"))
for n in pins:
    os.makedirs(os.path.join(nodes, n["name"]))
    open(os.path.join(nodes, n["name"], ".tillandsias-node-commit"), "w").write(n["commit"] + "\n")
first = pins[0]["name"]
if arm == "unlisted-node":
    os.makedirs(os.path.join(nodes, "SomeOtherNode"))
elif arm == "other-commit":
    open(os.path.join(nodes, first, ".tillandsias-node-commit"), "w").write("0" * 40 + "\n")
elif arm == "missing-node":
    shutil.rmtree(os.path.join(nodes, first))
elif arm == "manager-in-custom-nodes":
    os.makedirs(os.path.join(nodes, "ComfyUI-Manager"))
elif arm == "manager-elsewhere":
    os.makedirs(os.path.join(root, "usr/lib/python3/site-packages/comfyui_manager"))
print(first)
]]

local _, tmp = run({ "mktemp", "-d" })
if tmp == "" then verdict.emit("could-not-run:studio-custom-nodes:no-tmpdir", 2) end

local arms = {
    { "manifest-set", 0, function(_) return "^ok:custom%-nodes:" end },
    { "unlisted-node", 1, function(_) return "not%-in%-manifest:SomeOtherNode" end },
    { "other-commit", 1, function(f) return "wrong%-commit:" .. f .. ":0000" end },
    { "missing-node", 1, function(f) return "missing:" .. f end },
    { "manager-in-custom-nodes", 1, function(_) return "comfyui%-manager%-path:.*ComfyUI%-Manager" end },
    { "manager-elsewhere", 1, function(_) return "comfyui%-manager%-path:.*comfyui_manager" end },
}

local failed = {}
for _, a in ipairs(arms) do
    local root = tmp .. "/" .. a[1]
    local sc, first = run({ "python3", "-c", SETUP, manifest, root, a[1] })
    if sc ~= 0 then verdict.emit("could-not-run:studio-custom-nodes:setup:" .. a[1] .. ":" .. first, 2) end
    local c, out = run({ "python3", verifier, "verify", manifest, root .. "/opt/comfyui/custom_nodes", root })
    log.raw(a[1] .. ": exit " .. c .. " " .. out:gsub("\n", " | "))
    if c ~= a[2] or not out:find(a[3](first:gsub("%-", "%%-"))) then failed[#failed + 1] = a[1] end
end
run({ "find", tmp, "-delete" })

if #failed > 0 then
    verdict.emit("violation:studio-custom-nodes:arms-wrong:" .. table.concat(failed, ","), 1)
end
verdict.emit("ok:studio-custom-nodes:" .. #arms .. "-arms", 0)
