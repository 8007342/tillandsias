-- @env PATH
-- @trace order:1181-bkem, spec:app-lifecycle, order:2367-d5gx
--
-- test-uninstall-keeps-models.lua — TILLANDSIAS_RESET_KEEP_MODELS=1 makes `uninstall.sh --wipe` spare
-- $CACHE_DIR/models; unset, --wipe is unchanged; without --wipe the flag deletes nothing. Ported from
-- the .sh of the same name.
--
-- HERMETIC, AND IT MUST BE: the subject deletes what HOME names. HOME is set inside the shell that
-- starts it, and that shell refuses (97) unless HOME is under this fixture's scratch.
--
-- Usage: tillandsias-plan script run scripts/lua/test-uninstall-keeps-models.lua
-- Verdict: ok:uninstall-keeps-models:<n> arms | violation:uninstall-keeps-models:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("uninstall-keeps-models")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local SUBJECT = "scripts/uninstall.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local W = T:scratch()

local RUN = [[
work="$1" home="$2" subject="$3"; shift 3
cd "$work" || exit 97; work="$(pwd)"
mkdir -p stubbin
for c in podman pkill update-desktop-database userdel groupdel runuser loginctl systemctl launchctl; do
    printf '#!/bin/sh\nexit 0\n' > "stubbin/$c"
done
printf '#!/bin/sh\nexit 1\n' > stubbin/pgrep
printf '#!/bin/sh\nexit 1\n' > stubbin/sudo
chmod +x stubbin/*
HOME="$work/$home"; export HOME
case "$HOME" in */plan-scratch/uninstall-*/h-*) ;; *) exit 97 ;; esac
[ -d "$HOME" ] || exit 97
PATH="$work/stubbin:$PATH" TILLANDSIAS_UNINSTALL_FAKE_UNAME=Linux TILLANDSIAS_UNINSTALL_INSTALL_DIR="$HOME/fixture-bin" \
    TILLANDSIAS_UNINSTALL_APPS_DIR="$HOME/Applications" TILLANDSIAS_UNINSTALL_TRAY_PROC=nonce-tray-1401 \
    "$BASH" "$subject" "$@" --yes 2>&1 </dev/null
]]
local WEIGHTS = ("weights \1\2\3 \r\n"):rep(200)
local OTHERS = { "fallback_x", "vault-data/y", "other.txt", "build-output/artifact" }
local function home(tag)
    local c = W.rel .. "/h-" .. tag .. "/.cache/tillandsias"
    for _, d in ipairs{ "models", "vault-data", "build-output" } do fs.mkdir(c .. "/" .. d) end
    fs.write(c .. "/models/weights.bin", WEIGHTS)
    for _, f in ipairs(OTHERS) do fs.write(c .. "/" .. f, f .. "\n") end
    return "h-" .. tag, c
end
local function uninstall(h, keep, args, subject)
    local argv = { SH, "-s", "--", W.abs, h, subject or (ROOT .. "/" .. SUBJECT) }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, stdin = RUN, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), TILLANDSIAS_RESET_KEEP_MODELS = keep and "1" or nil } }
    if r.code ~= 0 then T:refuse("uninstall-did-not-run", "rc=" .. tostring(r.code) .. " " .. tostring(r.stdout) .. tostring(r.stderr)) end
    return r.stdout
end
local function weights(c)
    local f = c .. "/models/weights.bin"
    return fs.exists(f) and fs.read(f) == WEIGHTS
end
local function others(c)
    local n = 0
    for _, f in ipairs(OTHERS) do if fs.exists(c .. "/" .. f) then n = n + 1 end end
    return n
end

local h, c = home("1")
local said = uninstall(h, true, { "--wipe" })
T:arm("1 the flag with --wipe keeps the models byte for byte", weights(c), said)
T:arm("1 and removes everything else under the cache", others(c) == 0 and not fs.exists(c .. "/vault-data")
    and not fs.exists(c .. "/build-output"), others(c))
T:arm("1 and names the spared path", said:find("keep%-models: spared [^\n]*/" .. "h%-1/%.cache/tillandsias/models %(") ~= nil, said)
h, c = home("2")
uninstall(h, false, { "--wipe" })
T:arm("2 without the flag --wipe removes the whole cache", not fs.exists(c), "cache survived")
h, c = home("3")
uninstall(h, true, {})
T:arm("3 the flag without --wipe deletes nothing", weights(c) and others(c) == #OTHERS, others(c))

-- MUTATION: arms 1 and 2 notice a flag that is ignored, and one that is always on.
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local GUARD = 'if [[ "$KEEP_MODELS" == true && -d "$CACHE_DIR/models" ]]; then'
local a, b = src:find(GUARD, 1, true)
if not a then T:refuse("mutation-anchor-missing") end
for _, m in ipairs{ { "ignored", "if false; then" }, { "always", 'if [[ -d "$CACHE_DIR/models" ]]; then' } } do
    fs.write(W.rel .. "/" .. m[1] .. ".sh", src:sub(1, a - 1) .. m[2] .. src:sub(b + 1))
end
h, c = home("4")
uninstall(h, true, { "--wipe" }, W.abs .. "/ignored.sh")
T:arm("4 MUTATION an ignored flag loses the models", not fs.exists(c .. "/models"), "kept")
h, c = home("5")
uninstall(h, false, { "--wipe" }, W.abs .. "/always.sh")
T:arm("4 MUTATION an always-on flag keeps them unasked", weights(c), "gone")

T:finish()
