-- @env PATH
-- @trace order:1437-evzi, order:2006-wahn, spec:host-state-lifecycle, order:2367-d5gx
--
-- test-uninstall-confirms-before-destroying.lua — scripts/uninstall.sh asks once, before anything is
-- removed (operator ruling 2026-10-08). Ported from the .sh of the same name.
--
-- HERMETIC, AND IT MUST BE: the subject deletes what HOME names. HOME is set inside the shell that
-- starts it, and that shell refuses (97) unless HOME is under this fixture's scratch.
--
-- Usage: tillandsias-plan script run scripts/lua/test-uninstall-confirms-before-destroying.lua
-- Verdict: ok:uninstall-confirms-before-destroying:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("uninstall-confirms-before-destroying")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local SUBJECT = "scripts/uninstall.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local W = T:scratch()

local RUN = [[
work="$1" home="$2" tty="$3" subject="$4"; shift 4
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
PATH="$work/stubbin:$PATH" TILLANDSIAS_UNINSTALL_FAKE_UNAME=Linux TILLANDSIAS_UNINSTALL_TTY="$work/$tty" \
    TILLANDSIAS_UNINSTALL_APPS_DIR="$HOME/Applications" TILLANDSIAS_UNINSTALL_TRAY_PROC=nonce-tray-1437 \
    "$BASH" "$subject" "$@" 2>&1 </dev/null
]]
local SEED = { [".local/bin/tillandsias"] = "bin", [".local/bin/tillandsias-uninstall"] = "unin",
    [".local/lib/tillandsias/lib.so"] = "lib", [".local/share/tillandsias/vault/store"] = "root-token",
    [".config/tillandsias/settings"] = "cfg", [".local/state/tillandsias/log"] = "log",
    [".cache/tillandsias/models/weights"] = "w" }
local function home(tag)
    for p, body in pairs(SEED) do
        local f = W.rel .. "/h-" .. tag .. "/" .. p
        fs.mkdir(f:match("^(.*)/"))
        fs.write(f, body .. "\n")
    end
    return "h-" .. tag
end
local function has(h, p) return fs.exists(W.rel .. "/" .. h .. "/" .. p) end
-- Every path, and the checksum of every file.
local function snapshot(h)
    return T:must{ SH, "-s", "--", W.abs .. "/" .. h, env = { LC_ALL = "C" },
        stdin = 'cd "$1" || exit 9\nfind . | sort\nfind . -type f | sort | while read -r p; do cksum "$p"; done\n' }.stdout
end
-- o: {answer=, args=, env=, subject=}; no answer means no terminal.
local function uninstall(h, o)
    if o.answer then fs.write(W.rel .. "/ans", o.answer .. "\n") end
    local argv = { SH, "-s", "--", W.abs, h, o.answer and "ans" or "no-terminal", o.subject or (ROOT .. "/" .. SUBJECT) }
    for _, a in ipairs(o.args or {}) do argv[#argv + 1] = a end
    local env_ = { PATH = env.get("PATH") }
    for k, v in pairs(o.env or {}) do env_[k] = v end
    local r = proc.run{ argv = argv, stdin = RUN, timeout_ms = 60000, env = env_,
        env_unset = { "TILLANDSIAS_*", "NO_COLOR", "CLICOLOR_FORCE" } }
    if r.code == 97 then T:refuse("home-not-sandboxed", tostring(r.stderr)) end
    return r.code, r.stdout or ""
end
local function untouched(name, h, o, want)
    local before = snapshot(h)
    local rc, said = uninstall(h, o)
    T:arm(name .. ": nothing removed", snapshot(h) == before, said)
    T:arm(name .. ": refused, and it says why", rc == 1 and text.contains(said, want), "rc=" .. tostring(rc) .. " " .. said)
    return said
end

untouched("1 Enter cancels", home("enter"), { answer = "" }, "Nothing was removed")
untouched("1 no cancels", home("no"), { answer = "no" }, "Nothing was removed")
untouched("1 anything else cancels", home("garbage"), { answer = "yes please" }, "Nothing was removed")

local h = home("delete")
local rc, said = uninstall(h, { answer = "DeLeTe" })
T:arm("2 delete, in any case, proceeds", rc == 0 and text.contains(said, "Uninstall complete")
    and not has(h, ".local/bin/tillandsias") and not has(h, ".local/share/tillandsias") and not has(h, ".config/tillandsias"), said)

untouched("3 no terminal", home("notty"), {}, "--yes")
h = home("yes")
rc = uninstall(h, { args = { "--yes" } })
T:arm("3 no terminal with --yes proceeds", rc == 0 and not has(h, ".local/bin/tillandsias"), rc)
T:arm("4 --yes alone keeps the cache", has(h, ".cache/tillandsias"), "gone")
for i, args in ipairs{ { "--wipe", "--yes" }, { "--yes", "--wipe" } } do
    h = home("wipe" .. i)
    rc = uninstall(h, { args = args })
    T:arm("4 " .. table.concat(args, " ") .. " removes the cache", rc == 0 and not has(h, ".cache/tillandsias"), rc)
end

local RED, ESC = "\27[1;31m", "\27"
h = home("colour")
rc, said = uninstall(h, { answer = "" })
T:arm("5 a pipe has no escape bytes", not text.contains(said, ESC), said)
T:arm("5 and carries both warnings", text.contains(said:lower(), "cannot be undone") and text.contains(said:lower(), "sign in again"), said)
T:arm("5 --yes is not advertised when it can ask", not text.contains(said, "--yes"), said)
rc, said = uninstall(h, { answer = "", env = { CLICOLOR_FORCE = "1" } })
T:arm("6 forced colour is bold red, same words", text.contains(said, RED) and text.contains(said:lower(), "cannot be undone")
    and text.contains(said:lower(), "sign in again"), said)
rc, said = uninstall(h, { answer = "", env = { CLICOLOR_FORCE = "0" } })
T:arm("6 CLICOLOR_FORCE=0 is not force", not text.contains(said, ESC), said)
rc, said = uninstall(h, { answer = "", env = { CLICOLOR_FORCE = "1", NO_COLOR = "1" } })
T:arm("6 NO_COLOR wins over force", not text.contains(said, ESC), said)
T:arm("6 and no colour run removed anything", has(h, ".local/bin/tillandsias"), "gone")

-- MUTATION, in the same sandbox.
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    fs.write(W.rel .. "/" .. name .. ".sh", src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return W.abs .. "/" .. name .. ".sh"
end
h = home("m-enter")
uninstall(h, { answer = "", subject = mutant("any-answer", 'if [[ "$_answer" != "delete" ]]; then', "if false; then") })
T:arm("7 MUTATION an uninstaller that takes any answer removes on Enter", not has(h, ".local/bin/tillandsias"), "kept")
h = home("m-notty")
uninstall(h, { subject = mutant("no-terminal", 'confirm in a script." >&2\n        exit 1', 'confirm in a script." >&2') })
T:arm("7 MUTATION one that does not stop without a terminal removes", not has(h, ".local/bin/tillandsias"), "kept")

T:finish()
