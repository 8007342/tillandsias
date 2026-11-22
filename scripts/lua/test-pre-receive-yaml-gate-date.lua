-- @trace spec:git-mirror-service, order:1863-mqiw, order:2172-7n62
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_TEST_GIT_IMAGE TILLANDSIAS_TEST_YQ_IMAGE
--
-- test-pre-receive-yaml-gate-date.lua — the mirror's pre-receive YAML gate
-- accepts the plain date that `openspec new change` writes (`created:
-- 2026-10-25`), and agrees with yq. Ported from the .sh of the same name
-- (order 2172-7n62); same four checks.
--
-- The git image ships ruby and no tillandsias-policy, so production validates
-- with ruby. Psych 4 (Ruby 3.1+) makes YAML.load_file a safe load that refuses
-- Date, so the whole push was rejected. This runs the hook INSIDE the git image,
-- where ruby is the validator (the sibling pre-receive fixture puts
-- tillandsias-policy on PATH and never reaches the ruby branch).
--
-- Usage: tillandsias-plan script run scripts/lua/test-pre-receive-yaml-gate-date.lua
-- Verdicts:
--   ok:pre-receive-date:ruby-and-yq-agree                         exit 0
--   violation:pre-receive-date:<n>-failed                         exit 1
--   could-not-run:pre-receive-date:<no-podman|no-git-image:…|no-yq-image:…>  exit 3

local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
local function run(argv, extra)
    local spec = { argv = argv, env = E, timeout_ms = 600000 }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local function cnr(why) verdict.emit("could-not-run:pre-receive-date:" .. why, 3) end

local version = text.trim(fs.read("VERSION") or "")
local GIT_IMAGE = env.get("TILLANDSIAS_TEST_GIT_IMAGE")
if GIT_IMAGE == nil or GIT_IMAGE == "" then GIT_IMAGE = "localhost/tillandsias-git:v" .. version end
local YQ_IMAGE = env.get("TILLANDSIAS_TEST_YQ_IMAGE")
if YQ_IMAGE == nil or YQ_IMAGE == "" then YQ_IMAGE = "docker.io/mikefarah/yq:4.44.3" end

if run({ "podman", "--version" }).status ~= "exited" then cnr("no-podman") end
if run({ "podman", "image", "exists", GIT_IMAGE }).code ~= 0 then cnr("no-git-image:" .. GIT_IMAGE) end

local DOC = "created: 2026-10-25\nschema: spec-driven\n"

-- The push, run as the image's git user with the checkout's hook mounted
-- read-only. The script runs INSIDE the container (podman is argv[0] here).
local INNER = [[
set -e
cd /tmp
git init -q --bare m.git
mkdir -p m.git/hooks
cp /hook/pre-receive m.git/hooks/pre-receive
cp /hook/tillandsias-relay-refs m.git/hooks/tillandsias-relay-refs
chmod +x m.git/hooks/pre-receive m.git/hooks/tillandsias-relay-refs
git init -q w
mkdir -p w/openspec/changes/demo
printf "%s" "$DOC" > w/openspec/changes/demo/.openspec.yaml
cp w/openspec/changes/demo/.openspec.yaml w/openspec/changes/demo/change.yaml
git -C w add -A
git -C w -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -m "openspec new change"
echo "validator=$(command -v tillandsias-policy >/dev/null && echo tillandsias-policy || echo ruby)"
if git -C w push -q /tmp/m.git HEAD:refs/heads/main 2>/tmp/push.err; then echo push=accepted; else echo push=rejected; cat /tmp/push.err; fi
printf "broken: [[[\n" > w/openspec/changes/demo/change.yaml
git -C w -c user.email=fixture@tillandsias.invalid -c user.name=fixture commit -q -am "broken"
if git -C w push -q /tmp/m.git HEAD:refs/heads/broken 2>/dev/null; then echo broken=accepted; else echo broken=rejected; fi
]]
local p = run({ "podman", "run", "--rm", "--network", "none", "--user", "git", "--entrypoint", "bash",
    "-v", ROOT .. "/images/git/pre-receive-hook.sh:/hook/pre-receive:ro,z",
    "-v", ROOT .. "/images/git/relay-refs.sh:/hook/tillandsias-relay-refs:ro,z",
    "-e", "DOC=" .. DOC, GIT_IMAGE, "-c", INNER })
local push_out = (p.stdout or "") .. (p.stderr or "")
out.line(text.trim(push_out))

if run({ "podman", "image", "exists", YQ_IMAGE }).code ~= 0
    and run({ "podman", "pull", "-q", YQ_IMAGE }).code ~= 0 then
    cnr("no-yq-image:" .. YQ_IMAGE)
end
local y = run({ "podman", "run", "--rm", "-i", "--network", "none", YQ_IMAGE, ".created" }, { stdin = DOC })
local yq_out = text.trim(y.stdout or "")
out.line("yq=" .. yq_out .. " rc=" .. tostring(y.code))

local has = {}
for _, l in ipairs(text.lines(push_out)) do has[text.trim(l)] = true end
local fail = 0
local function need(cond, why) if not cond then fail = fail + 1; out.line("FAIL: " .. why) end end
need(has["validator=ruby"], "the hook did not validate with ruby, so this arm tested nothing")
need(has["push=accepted"], "the mirror rejected a push openspec itself writes")
need(has["broken=rejected"], "broken YAML passed the gate, so the gate no longer gates")
need(y.code == 0 and yq_out == "2026-10-25", "yq did not load the same document")
if fail > 0 then verdict.emit("violation:pre-receive-date:" .. fail .. "-failed", 1) end
verdict.ok("pre-receive-date", "ruby-and-yq-agree")
