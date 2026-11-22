-- @trace spec:default-image, order:1864-qymj, order:2182-flrp
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_TEST_FORGE_IMAGE
--
-- test-forge-lua-tooling.lua — a forge has a Lua interpreter on PATH, the
-- startup context names it, and its two helpers behave:
--   lua-edit      batched asserted replace: refuses, changing nothing, unless
--                 every OLD occurs exactly once;
--   lua-conflict  resolves a merge-conflict hunk as ours, theirs or both.
-- Runs inside the built forge image, where these live; the host has no lua.
-- Ported from the .sh of the same name (order 2182-flrp); same probes, same
-- fifteen wants.
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-lua-tooling.lua
-- Verdicts:
--   ok:forge-lua:interpreter-context-edit-conflict                  exit 0
--   violation:forge-lua:<n>-failed                                   exit 1
--   could-not-run:forge-lua:<no-podman|no-forge-image:<image>>       exit 3

local E = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
local function run(argv) return proc.run({ argv = argv, env = E, timeout_ms = 300000 }) end
local IMAGE = env.get("TILLANDSIAS_TEST_FORGE_IMAGE")
if IMAGE == nil or IMAGE == "" then IMAGE = "localhost/tillandsias-forge:v" .. text.trim(fs.read("VERSION") or "") end

if run({ "podman", "--version" }).status ~= "exited" then verdict.emit("could-not-run:forge-lua:no-podman", 3) end
if run({ "podman", "image", "exists", IMAGE }).code ~= 0 then verdict.emit("could-not-run:forge-lua:no-forge-image:" .. IMAGE, 3) end

local INNER = [[
cd /tmp
echo "lua-path=$(command -v lua || echo none)"
echo "lua-version=$(lua -v 2>&1 || echo none)"
echo "lfs=$(lua -e "require(\"lfs\") print(\"yes\")" 2>/dev/null || echo no)"
echo "lpeg=$(lua -e "require(\"lpeg\") print(\"yes\")" 2>/dev/null || echo no)"

mkdir -p ctx
( source /usr/local/lib/tillandsias/lib-common.sh >/dev/null 2>&1; inject_startup_context /tmp/ctx >/dev/null 2>&1 ) || true
present=$(grep -m1 "^\*\*Present:\*\*" ctx/.forge-startup-context.md 2>/dev/null || echo none)
echo "ctx-present=$present"

printf "alpha beta\ngamma alpha\n" > dup.txt; cp dup.txt dup.orig
lua-edit dup.txt alpha ALPHA >/dev/null 2>&1 && echo edit-dup=applied || echo edit-dup=refused
cmp -s dup.txt dup.orig && echo edit-dup-unchanged=yes || echo edit-dup-unchanged=no
printf "one two three\n" > ok.txt
lua-edit ok.txt one 1 three 3 >/dev/null 2>&1 && echo edit-ok=applied || echo edit-ok=refused
echo "edit-ok-content=$(cat ok.txt)"
printf "a b\n" > miss.txt; cp miss.txt miss.orig
lua-edit miss.txt a A zzz Z >/dev/null 2>&1 && echo edit-miss=applied || echo edit-miss=refused
cmp -s miss.txt miss.orig && echo edit-miss-unchanged=yes || echo edit-miss-unchanged=no

for side in ours theirs both; do
  printf "top\n<<<<<<< HEAD\nmine\n=======\nyours\n>>>>>>> topic\nend\n" > c.txt
  lua-conflict c.txt $side >/dev/null 2>&1 || echo "conflict-$side=refused"
  echo "conflict-$side=$(tr "\n" "," < c.txt)"
done
printf "plain\n" > none.txt
lua-conflict none.txt ours >/dev/null 2>&1 && echo conflict-none=applied || echo conflict-none=refused
]]
local r = run({ "podman", "run", "--rm", "--network", "none", "--user", "forge", "--entrypoint", "bash", IMAGE, "-c", INNER })
local all = (r.stdout or "") .. (r.stderr or "")
out.line(text.trim(all))

local lines = text.lines(all)
local has = {}
for _, l in ipairs(lines) do has[l] = true end
local function any(pat) for _, l in ipairs(lines) do if l:match(pat) then return true end end return false end
local fail = 0
local function need(cond, why) if not cond then fail = fail + 1; out.line("FAIL: " .. why) end end
need(any("^lua%-path=/"), "lua is not on PATH")
need(any("^lua%-version=Lua 5%."), "lua -v did not print a version")
need(any("^ctx%-present=.*`lua`"), "the startup context's Present list does not name lua")
for _, w in ipairs({ "lfs=yes", "lpeg=yes", "edit-dup=refused", "edit-dup-unchanged=yes", "edit-ok=applied",
    "edit-ok-content=1 two 3", "edit-miss=refused", "edit-miss-unchanged=yes",
    "conflict-ours=top,mine,end,", "conflict-theirs=top,yours,end,", "conflict-both=top,mine,yours,end,",
    "conflict-none=refused" }) do
    need(has[w], "want '" .. w .. "'")
end
if fail > 0 then verdict.emit("violation:forge-lua:" .. fail .. "-failed", 1) end
verdict.ok("forge-lua", "interpreter-context-edit-conflict")
