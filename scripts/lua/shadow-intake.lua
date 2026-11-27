-- @env SHADOW_TREE PATH HOME USER LANG XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS CARGO_HOME RUSTUP_HOME SHADOW_CMD SHADOW_LOG SHADOW_LOCK SHADOW_PR_S SHADOW_RUN_S SHADOW_PLAN SHADOW_KEEP
-- @trace order:2248-zcqh
--
-- shadow-intake.lua — run intake beside gates that already answered, and record
-- both verdicts (bundle landing phase 0). scripts/land-queue.sh starts it
-- detached, at low priority, after its last landing, sharing nothing with it that
-- it needs: this holds its OWN lock, never the land lock, works in its own
-- worktree with its own target dir, and lands, evicts and comments nothing.
--
-- Usage (by land-queue.sh):
--   tillandsias-plan script run shadow-intake.lua -- <num>:<base>:<head>:<gate>:<via> ...
--   SHADOW_CMD   run in the shadow tree as `<cmd> <base>` (./build.sh --intake --changed)
--   SHADOW_LOG   appended; SHADOW_LOCK a dir (pid inside; a `stop` file in it ends
--                the run, a build in flight included); SHADOW_PR_S, SHADOW_RUN_S bounds
-- Log line:
--   shadow:accept:<pr> tier=intake|heavy selected=<fx>/<pop> crates=<n> intake_s=<s>
--     intake=ok|red|-|timeout|merge-conflict|could-not-run gate=<verdict> via= base= head= rc= ts=
--   unmeasured:shadow:<pr>:<stopped|stopped-mid-build|run-bound|lock-held>   — named, never silently missing

local LOG, LOCK = env.get("SHADOW_LOG"), env.get("SHADOW_LOCK")
local PR_S, RUN_S = tonumber(env.get("SHADOW_PR_S") or "") or 1200, tonumber(env.get("SHADOW_RUN_S") or "") or 1200
local CMD, PLAN, KEEP = env.get("SHADOW_CMD") or "", env.get("SHADOW_PLAN") or "", env.get("SHADOW_KEEP") or ""
local ROOT = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" } }.stdout or "")
if ROOT == "" or CMD == "" or not LOG or not LOCK then verdict.could_not_run("shadow-intake", "no repo, SHADOW_CMD, SHADOW_LOG or SHADOW_LOCK") end
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME"), USER = env.get("USER"), LANG = env.get("LANG"),
    XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR"), DBUS_SESSION_BUS_ADDRESS = env.get("DBUS_SESSION_BUS_ADDRESS"),
    CARGO_HOME = env.get("CARGO_HOME"), RUSTUP_HOME = env.get("RUSTUP_HOME") }
local function run(argv, o) o = o or {}; return proc.run{ argv = argv, env = o.env or BASE, stdin = o.stdin, timeout_ms = o.ms or 120000 } end
local function sh(script, args, o)
    local argv = { "/bin/sh", "-s", "--" }
    for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
    o = o or {}; o.stdin = script
    return run(argv, o)
end
local function log(l) run({ "tee", "-a", LOG }, { stdin = l .. "\n" }) end
local function exists(p) return run({ "test", "-e", p }).code == 0 end
local T0 = time.now_ms()
local function secs(t) return math.floor((time.now_ms() - (t or T0)) / 1000) end

-- The lock: mkdir is the test-and-set; a holder whose pid is gone is cleared. A
-- live holder was told to stop by the land run that just ended; wait one PR.
local OWN = sh('printf "%s" "$PPID"').stdout
local function take()
    return sh([[mkdir "$1" 2>/dev/null && { printf '%s' "$2" > "$1/pid"; exit 0; }
p="$(cat "$1/pid" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && exit 1
rm -f "$1/pid" "$1/stop" "$1/current"; rmdir "$1" 2>/dev/null; mkdir "$1" 2>/dev/null && printf '%s' "$2" > "$1/pid"]], { LOCK, OWN }).code == 0
end
-- Never a recursive rm: the lock's two known files and an empty dir, nothing else.
local function release() run({ "rm", "-f", LOCK .. "/pid", LOCK .. "/stop", LOCK .. "/current" }); run({ "rmdir", LOCK }) end
local got = take()
while not got and secs() < PR_S do sh("sleep 2"); got = take() end
-- Fully outside the checkout (coordinator 2026-11-24), so no scan or archive copy of it
-- sees the tree or its build output. A dir there that is not this repo's is refused.
local TREE = env.get("SHADOW_TREE") or ""
local function common(d) return text.trim(run({ "git", "-C", d, "rev-parse", "--path-format=absolute", "--git-common-dir" }).stdout or "") end
if not (TREE:sub(1, 1) == "/" or TREE:find("^%a:[/\\]")) or (exists(TREE) and common(TREE) ~= common(ROOT)) then
    if got then release() end
    verdict.could_not_run("shadow-intake", "SHADOW_TREE is not absolute, or is not a worktree of this repo: " .. TREE)
end
-- ONE PERSISTENT TREE. CARGO_TARGET_DIR does not reach the builder toolbox, so the
-- tree's own target/ is the cache: a fresh worktree per PR compiled cold and timed
-- out (measured on yoga, 481 s). Ignored files are kept, everything else is reset.
local function tree_at(b)
    if exists(TREE .. "/.git") then
        run({ "git", "-C", TREE, "merge", "--abort" })
        if run({ "git", "-C", TREE, "checkout", "-q", "-f", "--detach", b }).code == 0 and run({ "git", "-C", TREE, "clean", "-qfd" }).code == 0 then return true end
        run({ "git", "-C", ROOT, "worktree", "remove", "--force", TREE })
    end
    if exists(TREE) then return false end  -- git could not remove it: never ours to delete by hand
    return run({ "git", "-C", ROOT, "worktree", "add", "-q", "--detach", TREE, b }).code == 0
end
local start, done, stopped = time.now_ms(), 0, nil
run({ "mkdir", "-p", (TREE:match("^(.*)/[^/]*$")) })
for i = 1, #arg do
    local n, b, h, g, via = arg[i]:match("^(%d+):(%x+):(%x+):([%w%-]+):(%w+)$")
    if n then
        local left = math.min(PR_S, RUN_S - secs(start))
        local why = not got and "lock-held" or exists(LOCK .. "/stop") and "stopped" or left <= 0 and "run-bound" or nil
        if why then
            log("unmeasured:shadow:" .. n .. ":" .. why .. " gate=" .. g .. " via=" .. via .. " base=" .. b:sub(1, 9) .. " head=" .. h:sub(1, 9))
        else
            run({ "tee", LOCK .. "/current" }, { stdin = n })
            local t, tier, verd, rc, o = time.now_ms(), "intake", "could-not-run", "-", ""
            if tree_at(b) then
                if run({ "git", "-C", TREE, "-c", "user.name=land-queue", "-c", "user.email=land-queue@localhost", "merge", "-q", "--no-ff", "--no-edit", h }).code ~= 0 then
                    verd = "merge-conflict"
                else
                    -- The router sidecar is a BUILD ARTIFACT a fresh tree lacks; without it every
                    -- cargo build fails and reads as intake=red (a false red on #1109, yoga).
                    local car = "/images/router/tillandsias-router-sidecar"
                    local staged = exists(ROOT .. car) and run({ "cp", "-p", ROOT .. car, TREE .. car }).code == 0
                    local need = exists(ROOT .. "/crates/tillandsias-router-sidecar")
                    if need and not staged then o = "no router sidecar in " .. ROOT else
                    local e = {}
                    for k, v in pairs(BASE) do e[k] = v end
                    -- ITS OWN target/, never the shared one (1807-shtg): measured on yoga, a shadow
                    -- built into <main checkout>/target and HELD ITS LOCK, so on the lander it would
                    -- overwrite the gate's artifacts (freshness is mtime-only) or make it wait.
                    e.TILLANDSIAS_SHARED_TARGET = "off"
                    if PLAN ~= "" then e.TILLANDSIAS_PLAN_BIN = PLAN end
                    -- A stop (or this runner dying) ends the build MID-PR, the way the bound does:
                    -- TERM to `timeout`, whose group holds the toolbox wrapper, which ends the
                    -- container side. A build left running would compete with the real gate.
                    local r = sh('cd "$1" || exit 99\ntimeout -k 10 ' .. left .. " " .. CMD .. [[ "$2" &
p=$!; me=$PPID
while kill -0 "$p" 2>/dev/null; do
    if [ -e "$3/stop" ] || ! kill -0 "$me" 2>/dev/null; then kill -TERM "$p" 2>/dev/null; wait "$p"; exit 97; fi
    sleep 1
done
wait "$p"
]], { TREE, b, LOCK }, { env = e, ms = (left + 60) * 1000 })
                    o = (r.stdout or "") .. (r.stderr or "")
                    rc = r.status == "exited" and r.code or 124
                    if rc == 0 then verd = "ok" elseif rc == 1 then verd = "red" elseif rc == 10 then tier, verd = "heavy", "-"
                    elseif rc == 124 or rc == 137 then verd = "timeout"
                    elseif rc == 97 then verd = nil end
                    end
                end
            end
            local fx, cr = o:match("select:intake fixtures=(%d+/%d+) .-crates=(%d+)/")
            if not fx then
                local pop = o:match("heavy:.- fixtures=(%d+) crates=")
                fx, cr = pop and "-/" .. pop or "-", "-"
            end
            if verd == nil then
                log("unmeasured:shadow:" .. n .. ":stopped-mid-build gate=" .. g .. " via=" .. via .. " base=" .. b:sub(1, 9) .. " head=" .. h:sub(1, 9))
            else
            log(("shadow:accept:%s tier=%s selected=%s crates=%s intake_s=%d intake=%s gate=%s via=%s base=%s head=%s rc=%s ts=%s"):format(
                n, tier, fx, cr, secs(t), verd, g, via, b:sub(1, 9), h:sub(1, 9), tostring(rc), time.iso_utc()))
            end
            if verd == "red" and g == "green" and KEEP ~= "" then run({ "tee", KEEP .. "/shadow-" .. n .. "-false-red.log" }, { stdin = o }) end
            done = done + 1
        end
    end
end
if done > 0 then log(("shadow:tree %s size_mb=%s"):format(TREE, (run({ "du", "-sm", TREE }, { ms = 120000 }).stdout or ""):match("^(%d+)") or "-")) end
if got then release() end
verdict.ok("shadow-intake", done .. " of " .. #arg)
