-- @trace order:798-tk7b, order:878-79b5, order:975-rsgm, order:1004-inkc, order:1242-4x53, order:2375-ch7i
--
-- test-enclave-service-health.lua — check-enclave-service-health.sh over a scripted podman:
-- no live containers, so the state no host produces on demand can be pinned, a STOPPED
-- container whose recorded healthcheck still says healthy. The strings are the product's
-- own (format_enclave_service_line). Ported from the .sh (2375-ch7i).
--
--   1-9 the reporter   13-18 the acting arm (--act)   M mutants   20 a desynced CA pair
--   R a removed service is not a healthy one
-- The reporter's clock (`date -u +%s`) is pinned to this fixture's: it read the clock again
-- and a second boundary between the two reads reddened one run in twenty (1242-4x53).
--
-- Verdict: ok: all enclave-service-health scenarios passed (the litmus reads it), then
--          ok:enclave-service-health:<n> | violation:enclave-service-health:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("enclave-service-health")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local GUARD = ROOT .. "/scripts/check-enclave-service-health.sh"
local W = T:scratch()
local now = math.floor(time.now_ms() / 1000)
fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/tools")
local function script(rel, body) fs.write(W.rel .. "/" .. rel, body); T:must{ "chmod", "+x", W.abs .. "/" .. rel } end
-- PS_OUT is the `ps -a --format` body (name|state|exit|started|exited|restarts); `container
-- exists` is answered from it, so the fake cannot disagree with itself.
script("bin/podman", [[#!/usr/bin/env bash
case "$1" in
    ps) [ "${PS_RC:-0}" -eq 0 ] || exit "$PS_RC"; printf '%s\n' "$PS_OUT" ;;
    inspect)
        key="$(printf '%s' "$2" | tr -c '[:alnum:]' '_')"
        eval "h=\"\${HEALTH_${key}:-}\"; l=\"\${LABEL_${key}:-}\""
        printf '%s|%s\n' "$h" "$l" ;;
    secret) exit "${STUB_ROTATION_RC:-0}" ;;
    start) [ -z "${START_LOG:-}" ] || printf 'start %s\n' "$2" >> "$START_LOG"; exit "${START_RC:-0}" ;;
    container)
        [ "$2" = exists ] || exit 1
        while IFS='|' read -r n _; do [ "$n" != "$3" ] || exit 0; done <<<"$PS_OUT"
        exit 1 ;;
    *) exit 1 ;;
esac
]])
local real_date = fixture.which("date")
if not real_date then T:refuse("no-date") end
script("bin/date", '#!/usr/bin/env bash\nif [ "$*" = "-u +%s" ]; then echo ' .. string.format("%d", now) .. '; else exec "' .. real_date .. '" "$@"; fi\n')
script("bin/ca-ok.sh", "#!/usr/bin/env bash\necho ok:enclave-ca-consistent\n")
script("bin/ca-desync.sh", "#!/usr/bin/env bash\necho desync:enclave-ca-key-secret\nexit 1\n")
local function row(name, state, code, started, exited, restarts)
    local function ago(s) return s == 0 and "0" or string.format("%d", now - s) end
    return table.concat({ "tillandsias-" .. name, state, code, ago(started), ago(exited), restarts or 0 }, "|")
end
local function up(name) return table.concat({ "tillandsias-" .. name, "running", 0, string.format("%d", now), 0, 0 }, "|") end
-- The expected set is opted out of by default: a vault without a proxy is most scenarios'
-- model. "-" leaves it unset, so the declared file answers.
local function run(ps, args, env, guard)
    local argv = { SH, guard or GUARD }
    for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
    local e = { PATH = W.abs .. "/bin:/usr/bin:/bin", PS_OUT = table.concat(ps, "\n"), TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES = "none" }
    for k, v in pairs(env or {}) do e[k] = v end
    if e.TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES == "-" then e.TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES = nil end
    argv.cwd, argv.env, argv.env_unset = ROOT, e, { "TILLANDSIAS_*" }
    local r = T:run(argv)
    return text.trim(r.stdout or ""), r.stderr or "", r.code
end
local function has(s, p) return s:find(p, 1, true) ~= nil end
local function tally(v, s, u, d, x, a) return ("%s:enclave-service-health:services=%d:up=%d:down=%d:dead=%d:absent=%d"):format(v, s, u, d, x, a) end

-- Tools only, and no podman: pointing at /usr/bin would find the real one.
for _, t in ipairs{ "date", "tr" } do T:must{ "ln", "-s", fixture.which(t), W.abs .. "/tools/" .. t } end
local sh_abs = fixture.which("bash")
if not sh_abs then T:refuse("no-bash") end
local r = T:run{ sh_abs, GUARD, cwd = ROOT, env = { PATH = W.abs .. "/tools" }, env_unset = { "TILLANDSIAS_*" } }
T:arm("1 no podman is blocked, not healthy", text.trim(r.stdout or "") == "blocked:enclave-service-health:no-podman", (r.stdout or "") .. (r.stderr or ""))
local o, err, rc = run{ up"vault", up"proxy", up"router" }
T:arm("2 all running: ok, rc 0", o == tally("ok", 3, 3, 0, 0, 0) and rc == 0, o)
o, err, rc = run{ up"vault", row("nix", "exited", 143, 300000, 250492) }
T:arm("3 exited(143) is dead, with signal, age and origin, and still rc 0", o == tally("degraded", 2, 1, 1, 1, 0) and rc == 0
    and has(err, "fail:enclave-service-dead:service=tillandsias-nix:state=exited:rc=143:signal=SIGTERM:age=2d21h:restarts=0:health=none:origin=unlabelled:age_s=250492"), o .. err)
o, err = run{ row("proxy", "exited", 0, 800, 700, 2) }
T:arm("3a a clean stop is a note, not dead", o == tally("degraded", 1, 0, 1, 0, 0)
    and has(err, "note:enclave-service-stopped:service=tillandsias-proxy:state=exited:rc=0:signal=none:age=11m:restarts=2"), o .. err)
o, err = run({ row("vault", "exited", 1, 500, 400), row("scratch", "exited", 1, 500, 400) }, nil, { LABEL_tillandsias_vault = "vault" })
local lab, unlab
for _, l in ipairs(text.lines(err)) do
    lab = lab or (has(l, "service=tillandsias-vault:") and has(l, ":origin=product-vault"))
    unlab = unlab or (has(l, "service=tillandsias-scratch:") and has(l, ":origin=unlabelled"))
end
T:arm("3b origin labels both, and drops neither", lab and unlab and o == tally("degraded", 2, 0, 2, 2, 0), o .. err)
local CORPSE, HEALTHY = { row("vault", "exited", 137, 20000, 18000) }, { HEALTH_tillandsias_vault = "healthy" }
o, err = run(CORPSE, nil, HEALTHY)
T:arm("4 stopped but recorded healthy is stale-healthy, SIGKILL, with the note", o == tally("degraded", 1, 0, 1, 1, 0)
    and has(err, ":signal=SIGKILL:") and has(err, ":health=stale-healthy") and has(err, "podman's stale record, not a reading"), o .. err)
o, err = run({ up"proxy" }, nil, { HEALTH_tillandsias_proxy = "healthy" })
T:arm("5 running and healthy is ok and silent", o == tally("ok", 1, 1, 0, 0, 0) and err == "", o .. err)
o, err = run({ up"proxy" }, { "--expect", "tillandsias-git,tillandsias-proxy" })
T:arm("6 a declared missing service is absent, and named", o == tally("degraded", 2, 1, 0, 0, 1) and has(err, "fail:enclave-service-absent:service=tillandsias-git:state=absent"), o .. err)
o = run{ up"proxy", "modest_proskuriakova|created|0|0|0|0" }
T:arm("7 a foreign container is ignored", o == tally("ok", 1, 1, 0, 0, 0), o)
local _, _, deg = run({ row("nix", "exited", 139, 900, 600) }, { "--strict" })
local _, _, fine = run({ up"proxy" }, { "--strict" })
T:arm("8 --strict: degraded rc 1, ok rc 0", deg == 1 and fine == 0, tostring(deg) .. " " .. tostring(fine))
o, err, rc = run({}, nil, { PS_RC = "125" })
T:arm("9 a failed reading is blocked and says it is not healthy", o == "blocked:enclave-service-health:unreadable" and rc == 0 and has(err, "NOT a report of a healthy stack"), o .. err)

local OLD = { up"vault", row("proxy", "exited", 0, 40000, 36000) }
local FRESH = { up"vault", row("proxy", "exited", 0, 400, 300) }
local seq = 0
-- act(ps, files, env, guard): files seed the state dir. -> start log, stderr, state dir
local function act(ps, files, env, guard, plain)
    seq = seq + 1
    local rel = W.rel .. "/act" .. seq
    fs.mkdir(rel .. "/state"); fs.write(rel .. "/log", "")
    for n, body in pairs(files or {}) do fs.write(rel .. "/state/" .. n, body) end
    local e = { START_LOG = W.abs .. "/act" .. seq .. "/log", TILLANDSIAS_CYCLE_STATE_DIR = W.abs .. "/act" .. seq .. "/state",
        TILLANDSIAS_CA_CONSISTENCY_CHECK = W.abs .. "/bin/ca-ok.sh", TILLANDSIAS_ENCLAVE_ACT_GRACE_S = "1800" }
    for k, v in pairs(env or {}) do e[k] = v end
    local so, se = run(ps, plain and {} or { "--act" }, e, guard)
    return fs.read(rel .. "/log"), se, rel .. "/state/", so
end
local log, st
log, err, st = act(OLD)
local ct = st .. "service-restarts-tillandsias-proxy"
T:arm("13 an old stop in a partial enclave is restarted, counted and reported", has(log, "start tillandsias-proxy") and fs.exists(ct) and fs.read(ct):match("^%S+ (%S+)") == "1"
    and has(err, "fix:enclave-service-restarted:service=tillandsias-proxy:restarts=1:action=started"), log .. err)
log, err = act(FRESH)
T:arm("14 NEGATIVE a fresh operator stop is not fought", log == "" and has(err, "note:enclave-service-grace:service=tillandsias-proxy:action=none"), log .. err)
log, err = act(OLD, { ["service-hold-tillandsias-proxy"] = "" })
T:arm("15 a hold marker refuses the restart", log == "" and has(err, "note:enclave-service-held:service=tillandsias-proxy"), log .. err)
log, err = act{ row("proxy", "exited", 0, 40000, 36000), row("vault", "exited", 0, 40000, 36000) }
T:arm("16 a whole stack down is left alone", log == "" and has(err, "reason=stack-down"), log .. err)
log, err = act(OLD, { ["service-restarts-tillandsias-proxy"] = string.format("%d 3\n", now) })
T:arm("17 at the cap it is flapping, for the operator", log == "" and err:find("fail:enclave%-service%-flapping:service=tillandsias%-proxy:restarts=3:[^\n]*action=operator"), log .. err)
log, err = act(OLD, nil, nil, nil, true)
local spoke
for _, c in ipairs{ "grace", "held", "restarted", "flapping", "unattended" } do spoke = spoke or has(err, "enclave-service-" .. c) end
T:arm("18 without --act it is still a reporter", log == "" and not spoke and has(err, "enclave-service-stopped:service=tillandsias-proxy"), log .. err)

-- Mutants live beside a copy of the tree's layout only as text: the guard is run by path.
local src = fs.read("scripts/check-enclave-service-health.sh")
local function mutant(name, drop)
    local keep, cut, skip = {}, 0, 0
    for _, l in ipairs(text.lines(src)) do
        local n = drop(l)
        if n then skip = n end
        if skip > 0 then skip = skip - 1; cut = cut + 1 else keep[#keep + 1] = l end
    end
    fs.write(W.rel .. "/" .. name, table.concat(keep, "\n") .. "\n")
    local p = T:run{ SH, "-n", W.abs .. "/" .. name }
    return cut > 0 and p.code == 0 and W.abs .. "/" .. name
end
-- The grace if-block is five physical lines: its details string embeds a newline.
local m = mutant("mutant-act.sh", function(l) return has(l, '-lt "$ACT_GRACE_S" ]; then') and 5 or nil end)
if m then log, err = act(FRESH, nil, nil, m) else log, err = "", "grace block not removed cleanly" end
T:arm("M without the grace guard the fresh stop IS fought", m and has(log, "start tillandsias-proxy"), log .. err)
m = mutant("mutant-stale.sh", function(l) return has(l, 'health="stale-healthy"') and 1 or nil end)
if m then o, err = run(CORPSE, nil, HEALTHY, m) else err = "branch not removed" end
T:arm("M without the stale branch the corpse reports podman's healthy", m and has(err, ":health=healthy"), err)

log, err, st, o = act({ row("vault", "running", 0, 7200, 0), row("proxy", "exited", 143, 7200, 3600) }, nil,
    { TILLANDSIAS_CA_CONSISTENCY_CHECK = W.abs .. "/bin/ca-desync.sh", STUB_ROTATION_RC = "1" })
T:arm("20 a desynced proxy is refused with its own reason, not restarted", has(err .. o, "enclave-ca-desync-unrepaired")
    and not has(err .. o, "fix:enclave-service-restarted:service=tillandsias-proxy"), log .. err)

-- No --expect on purpose: 6 passed all the while a deleted service read as healthy.
local DECL = { TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES = "-" }
if not fs.exists("images/default/enclave-services.txt") then T:arm("R the declared set is readable", false, "images/default/enclave-services.txt") end
o = run({ up"vault", up"proxy" }, nil, DECL)
T:arm("R the declared set present is ok", o:find("^ok:enclave%-service%-health:.*absent=0"), o)
o, err = run({ up"vault" }, nil, DECL)
T:arm("R a deleted required service is degraded, absent, and named", o:find("^degraded:enclave%-service%-health:.*absent=[1-9]") and has(err, "fail:enclave-service-absent:service=tillandsias-proxy"), o .. err)
o = run({}, nil, DECL)
T:arm("R a host that never had an enclave is not reported absent", o:find("^ok:") or o:find("^blocked:"), o)
if #T.failed == 0 then out.line("ok: all enclave-service-health scenarios passed") end
T:finish({ ok = function(n) return "ok:enclave-service-health:" .. n end })
