-- @env PATH HOME
-- @trace order:1350-ku7v, order:1606-25nf, order:2373-8vq6
--
-- test-mirror-sync-state.lua — publish-sync-state.sh tells a forge whether its mirror is current,
-- behind or diverged, as one ref readable by ls-remote, and something runs it. Ported from the .sh
-- of the same name (2373-8vq6). Scratch mirrors; arm 11 runs the built binary with a stub podman, so
-- no live mirror is reached.
--
--   1 no tracking data: unknown, never current    2 current     3 behind, with the head count
--   4 an untracked head is not behind             5 one verdict after two runs
--   6 readable by ls-remote, an empty blob        7 the image ships it   8 the entrypoint calls it
--   9 a real relay run publishes                  10 a failing publisher never changes the relay
--   11 the binary knows --sync                    12 the built image has both scripts
--   13 a rebased work ref: diverged and named, while linux-next alone stays current or behind
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-sync-state.lua
-- Verdict: ok:mirror-sync-state:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("mirror-sync-state")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local w = T:scratch()
local PRE = [==[
set -u
W="$1"; PUB="$2/images/git/publish-sync-state.sh"; RR="$2/images/git/relay-refs.sh"; shift 2
G="git -c user.email=a@example.invalid -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=linux-next"
mk() { # mk <name> <ahead>: a bare mirror, its tracking twin <ahead> commits past the exported head
    src="$W/$1.src"; dir="$W/$1"
    $G init -q "$src"; echo base >"$src/f"; $G -C "$src" add f; $G -C "$src" commit -q -m base
    $G init -q --bare "$dir"; $G -C "$src" push -q "$dir" HEAD:refs/heads/linux-next
    i=0; while [ "$i" -lt "$2" ]; do echo "more$i" >>"$src/f"; $G -C "$src" commit -q -am "ahead$i"; i=$((i + 1)); done
    $G -C "$dir" fetch -q "$src" "+refs/heads/linux-next:refs/remotes/origin/linux-next"
}
refs() { $G -C "$W/$1" for-each-ref --format='%(refname)' "$2"; }
]==]
local function sh(body)
    local r = proc.run{ argv = { SH, "-s", "--", w.abs, ROOT }, cwd = w.abs, stdin = PRE .. body, env = { PATH = env.get("PATH"), HOME = w.abs, GIT_CONFIG_NOSYSTEM = "1" }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = "\n" .. (r.stdout or ""):gsub("\r", "")
    local line
    for l in o:gmatch("\n(sync%-state:[^\n]*)") do line = l end
    return { rc = r.code, out = o, state = line and line:match("^sync%-state:([^:]*)"), why = "rc=" .. tostring(r.code) .. o:sub(1, 400) .. (r.stderr or ""):sub(1, 300) }
end
local x = sh 'mk m1 0; $G -C "$W/m1" update-ref -d refs/remotes/origin/linux-next; sh "$PUB" "$W/m1" 2>/dev/null'
T:arm("1 no tracking data is unknown, never current", x.state == "heads-unknown", x.why)
x = sh 'mk m2 0; sh "$PUB" "$W/m2" 2>/dev/null'
T:arm("2 an equal twin is current", x.state == "heads-current", x.why)
x = sh 'mk m3 3; sh "$PUB" "$W/m3" 2>/dev/null; refs m3 refs/tillandsias/sync-state'
T:arm("3 upstream moved: behind, one head", x.state == "heads-behind" and text.contains(x.out, "\nrefs/tillandsias/sync-state/heads-behind/1/"), x.why)
x = sh 'mk m4 0; $G -C "$W/m4" update-ref refs/heads/salvage/local-only refs/heads/linux-next; sh "$PUB" "$W/m4" 2>/dev/null'
T:arm("4 a head with no twin is not behind", x.state == "heads-current", x.why)
x = sh 'sleep 1; sh "$PUB" "$W/m2" >/dev/null 2>&1; refs m2 refs/tillandsias/sync-state'
T:arm("5 one verdict after two runs", select(2, x.out:gsub("\nrefs/tillandsias/sync%-state/", "")) == 1, x.why)
x = sh '$G ls-remote "$W/m2" "refs/tillandsias/sync-state/*"; echo "empty=$($G -C "$W/m2" hash-object -t blob --stdin </dev/null)"'
local sha, empty = x.out:match("\n(%x+)%s+refs/tillandsias/sync%-state/"), x.out:match("\nempty=(%x+)")
T:arm("6 ls-remote reads it, and it is the empty blob", sha ~= nil and sha == empty, x.why)

x = sh [==[
mk m13 0; s="$W/m13.src"; $G -C "$s" checkout -q -b work/rebased
echo local >"$s/w"; $G -C "$s" add w; $G -C "$s" commit -q -m local-tip; $G -C "$s" push -q "$W/m13" HEAD:refs/heads/work/rebased
$G -C "$s" reset -q --hard HEAD~1; echo rewritten >"$s/w"; $G -C "$s" add w; $G -C "$s" commit -q -m rewritten-tip
$G -C "$W/m13" fetch -q "$s" "+refs/heads/work/rebased:refs/remotes/origin/work/rebased"
sh "$PUB" "$W/m13" 2>/dev/null
echo "marker=$($G -C "$W/m13" rev-parse --verify --quiet refs/tillandsias/diverged/work/rebased) head=$($G -C "$W/m13" rev-parse refs/heads/work/rebased)"
]==]
local marker, head = x.out:match("\nmarker=(%x+) head=(%x+)")
T:arm("13a a rebased work ref reads diverged, counted and named", x.state == "heads-diverged" and text.contains(x.out, "\nnote:sync-state:diverged-work-refs:1\n") and marker ~= nil and marker == head, x.why)
x = sh 'sh "$PUB" "$W/m13" linux-next 2>/dev/null'
T:arm("13b scoped to linux-next it is current", x.state == "heads-current", x.why)
x = sh 'mk m13b 2; sh "$PUB" "$W/m13b" linux-next 2>/dev/null'
T:arm("13c linux-next behind, scoped to it, is behind", x.state == "heads-behind", x.why)

local function count(f, s)
    local n, at, body = 0, 1, fs.read(f)
    while true do
        local a, z = body:find(s, at, true)
        if not a then return n end
        n, at = n + 1, z + 1
    end
end
local SHIPPED = "/usr/local/share/git-service/publish-sync-state"
T:arm("7 the image copies it and marks it executable", count("images/git/Containerfile", "COPY publish-sync-state.sh " .. SHIPPED) == 1 and count("images/git/Containerfile", SHIPPED) >= 2, "Containerfile")
T:arm("8 the entrypoint publishes at startup and on the tick", count("images/git/entrypoint.sh", 'SYNC_STATE="${SYNC_STATE:-' .. SHIPPED .. '}"') == 1 and count("images/git/entrypoint.sh", 'run_sync_state "') >= 2, "entrypoint")
local RELAY = [==[
mk @M 0; $G init -q --bare "$W/@M.up"; $G -C "$W/@M" remote add origin "$W/@M.up"
tip="$($G -C "$W/@M" rev-parse refs/heads/linux-next)"; cd "$W/@M" || exit 90
rc=0; printf '%s %s %s\n' "$tip" "$tip" refs/heads/linux-next | SYNC_STATE="@P" sh "$RR" >/dev/null 2>&1 || rc=$?
echo "relay=$rc up=$($G -C "$W/@M.up" rev-parse --verify --quiet refs/heads/linux-next)"; refs @M refs/tillandsias/sync-state
]==]
x = sh(RELAY:gsub("@M", "m9"):gsub("@P", "$PUB"))
T:arm("9 a live relay run leaves a verdict in the mirror", text.contains(x.out, "\nrefs/tillandsias/sync-state/"), x.why)
fs.write(w.rel .. "/boom.sh", "#!/bin/sh\nexit 9\n")
T:must{ "chmod", "+x", w.abs .. "/boom.sh" }
x = sh(RELAY:gsub("@M", "m10"):gsub("@P", "$W/boom.sh"))
T:arm("10 a failing publisher changes neither the relay's status nor the push", x.out:find("\nrelay=0 up=%x+\n") ~= nil, x.why)

local BIN = ROOT .. "/target/release/tillandsias"
if T:run{ "test", "-x", BIN }.code ~= 0 then
    out.line("skip: 11 no built binary")
else
    fs.mkdir(w.rel .. "/bin"); fs.mkdir(w.rel .. "/home")
    for _, n in ipairs{ "podman", "toolbox", "flatpak-spawn" } do
        fs.write(w.rel .. "/bin/" .. n, "#!/bin/sh\nexit 1\n")
        T:must{ "chmod", "+x", w.abs .. "/bin/" .. n }
    end
    local r = proc.run{ argv = { BIN, "--sync", "tillandsias" }, cwd = w.abs, env = { PATH = w.abs .. "/bin:" .. env.get("PATH"), HOME = w.abs .. "/home", TILLANDSIAS_PODMAN_BIN = w.abs .. "/bin/podman" }, env_unset = { "TILLANDSIAS_*", "XDG_RUNTIME_DIR" }, stdin = "", timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    T:arm("11 the built binary knows --sync", r.status == "exited" and not text.contains(o, "Unsupported option: --sync"), tostring(r.status) .. " " .. o:sub(1, 300))
end
local img = fixture.which("podman") and ("\n" .. (T:run{ "podman", "image", "ls", "--format", "{{.Repository}}:{{.Tag}}" }.stdout or "")):match("\n(localhost/tillandsias%-git:[^\n]+)")
if not img then
    out.line("skip: 12 no podman, or no git image built here")
else
    for _, f in ipairs{ "publish-sync-state", "reconcile-exported-heads" } do
        local r = T:run{ "podman", "run", "--rm", "--network", "none", "--entrypoint", "test", img, "-x", "/usr/local/share/git-service/" .. f }
        T:arm("12 " .. img .. " ships " .. f, r.code == 0, (r.stderr or ""):sub(1, 300))
    end
end
T:finish()
