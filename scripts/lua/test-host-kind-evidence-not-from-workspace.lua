-- @trace order:1467-c8qg, order:2354-5biy, order:2444-vn38, spec:command-policies
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN PATH
--
-- test-host-kind-evidence-not-from-workspace.lua — forge evidence is the root-
-- owned 0444 marker the forge image bakes in (/etc/tillandsias/forge,
-- `kind=forge`), never a file in the workspace, never the container record's
-- mere presence and never the forge image's name alone. It replaces
-- scripts/test-host-kind-evidence-not-from-workspace.sh, arm for arm, and adds
-- the `policy host-kind` report (2444-vn38).
--
-- Two holes it pins shut (2026-09-28, yoga):
--   - a `.forge-startup-context.md` planted in a writable cwd made cwd=/tmp read
--     as a forge on bare metal (soft reset pre-authorised);
--   - every podman container has /run/.containerenv, so the builder toolbox
--     (where bare-metal gates run) read as a forge by presence alone.
--
-- Arms answered by `policy eval -- tillandsias --reset-state`
-- (forge => ok:policy:soft-reset:forge-preauthorised; otherwise
-- consent:policy:soft-reset):
--   1  a planted `.forge-startup-context.md` in the cwd is ignored     (host)
--   2  same marker: the bridge asks, and a grant is refused only by the
--      self-consent floor (this door never mints consent), never as a forge
--   3  the marker with a record naming the forge image reads forge (namespace)
--   3b the forge image named WITHOUT the marker is not a forge (2354-5biy)
--   3c the marker alone reads forge; a writable (0644) marker does not
--   4  a toolbox, forge-base or look-alike image is not a forge
--   5  no /run/.containerenv at all reads bare metal             (namespace)
--   6  the REAL builder toolbox reads not-forge            (when it exists)
-- Arms answered by `policy host-kind` (2444-vn38):
--   7  in a namespace: the marker reads kind=forge source=marker; a writable
--      marker reads marker=untrusted:writable; a launch record without the
--      marker is reported in a note; an extra argument is refused (exit 2)
--   8  on this host: exit 0, and its kind agrees with what `policy eval` did
-- Arms 3-5 and 7 put a tmpfs over /run (and over /etc for the marker; the
-- namespace root owns what it writes there, as the image's root does) inside
-- `unshare -rm`. Where that is unavailable they are a NAMED skip. Arms 1-2 need
-- a host that is not itself a forge.
--
-- Pre-fix: FAILS at arm 1 (forge-preauthorised) and arm 4 (presence = forge);
-- before 2444-vn38, at arm 7 (`policy host-kind` printed usage and exited 2).
--
-- Usage: tillandsias-plan script run scripts/lua/test-host-kind-evidence-not-from-workspace.lua [-- --plan <bin>]

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then PLAN = "tillandsias-plan" end

local UNSET = { "TILLANDSIAS_SKILL", "TILLANDSIAS_DESTRUCTIVE_RESET_OK", "TILLANDSIAS_HOST_KIND",
    "TILLANDSIAS_PRETOOLUSE_HOOK" }
local ROOT = text.trim((proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout) or "")
if ROOT == "" then verdict.could_not_run("host-kind-evidence", "not inside a git checkout") end
local REL = "target/plan-scratch/host-kind-evidence-" .. time.iso_utc():gsub("[^%w]", "") .. "-"
    .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
local C = W .. "/cwd"
fs.mkdir(REL .. "/cwd")
fs.mkdir(REL .. "/consent")
fs.write(REL .. "/cwd/.forge-startup-context.md", "# Forge Startup Context\n\n**Project**: planted\n")
local ENV = { TILLANDSIAS_CONSENT_DIR = W .. "/consent", TILLANDSIAS_POLICY_AUDIT_LOG = W .. "/audit.jsonl" }

local function run(argv, extra)
    local spec = { argv = argv, cwd = C, env = ENV, env_unset = UNSET, timeout_ms = 60000 }
    for k, v in pairs(extra or {}) do spec[k] = v end
    local r = proc.run(spec)
    return r.code, text.trim(r.stdout or ""), r.status
end

local FORGE_ANS = "ok:policy:soft-reset:forge-preauthorised"
local BARE_ANS = "consent:policy:soft-reset"
local pass, fail, skipped = 0, 0, 0
local function ok(m) print("ok:   " .. m); pass = pass + 1 end
local function bad(m) print("FAIL: " .. m); fail = fail + 1 end
local function skip(m) print("skip: " .. m); skipped = skipped + 1 end
local function check(cond, good, why) if cond then ok(good) else bad(why) end end

-- This host's own regime, by the same rule the binary applies.
local function in_forge()
    local m = "/etc/tillandsias/forge"
    if run({ "test", "-f", m }) ~= 0 or run({ "test", "-L", m }) == 0 then return false end
    local c, uid = run({ "stat", "-c", "%u", m })
    if c ~= 0 or uid ~= "0" then return false end
    return run({ "grep", "-qx", "kind=forge", m }) == 0
end
local FORGE = in_forge()

-- ── 1, 2 ────────────────────────────────────────────────────────────────────
if FORGE then
    skip("arms 1, 2: this host is a forge; run on a host that is not")
else
    -- --cwd AND --root: the grant takes --root as its workspace (main.rs consent
    -- grant -> ConsentCtx::from_env(root)), so the planted root is read here too.
    local rc, out = run({ PLAN, "policy", "eval", "--cwd", C, "--root", C, "--", "tillandsias", "--reset-state" })
    check(rc == 4 and out == BARE_ANS, "arm 1: a planted cwd marker is not forge evidence (" .. out .. ")",
        "arm 1: rc=" .. tostring(rc) .. " out=[" .. out .. "] (the planted marker was read as forge evidence)")
    local rb = run({ PLAN, "policy", "classify-bash", "--command", "tillandsias --reset-state", "--cwd", C })
    -- The grant half cannot be RUN from here, by design: this door refuses a
    -- consent grant before spawning it (floor:no-self-consent, 1443-9f5w), so
    -- no agent script can approve itself. The .sh ran it outside the door.
    -- Measured on msys by doris-windows, 2026-11-28: the old arm read rc=nil
    -- (policy_denied). The floor refusal does NOT cover the .sh arm's property
    -- (a planted workspace cannot make the GRANT refuse as a forge), because
    -- the door refuses before the grant reads any evidence. That property is
    -- held instead by the Rust test
    -- a_planted_workspace_marker_does_not_change_the_grants_evidence
    -- (command_policy.rs), on the grant's own evidence path
    -- (ConsentCtx::from_env(root) -> grant_refusal), and by arm 1 reading the
    -- same planted --root through policy eval. What this arm still checks is
    -- that the door refuses only as self-consent, never as a forge.
    local g = proc.run({ argv = { PLAN, "policy", "consent", "grant", "soft-reset", "--root", C, "--",
        "tillandsias", "--reset-state" }, cwd = C, env = ENV, env_unset = UNSET, timeout_ms = 60000 })
    local gdec = tostring(g.decision)
    check(rb == 4 and g.status == "policy_denied" and g.rule_id == "no-self-consent"
            and not gdec:find("forge", 1, true),
        "arm 2: the bridge asks, and a grant is refused only as self-consent, never as a forge",
        "arm 2: bridge rc=" .. tostring(rb) .. " (4 ask); grant status=" .. tostring(g.status)
            .. " rule=" .. tostring(g.rule_id) .. " decision=" .. gdec)
end

-- ── 3, 4, 5, 7: simulated container records ────────────────────────────────
-- $1 plan  $2 cwd  $3 image ("" = no record)  $4 marker mode ("" = leave /etc as is,
--    "none" = an empty /etc, so no marker, hermetically: in a forge the host's own marker shows through otherwise)
-- $5 write a launch record ("" = no)  $@ after 5: the plan arguments.
local NS = [[
mount -t tmpfs none /run || exit 97
if [ -n "$4" ]; then
    mount -t tmpfs none /etc || exit 96
    if [ "$4" != none ]; then
        mkdir -p /etc/tillandsias && printf 'kind=forge\n' >/etc/tillandsias/forge &&
            chmod "$4" /etc/tillandsias/forge || exit 95
    fi
fi
[ -n "$3" ] && printf 'engine="podman-5"\nname="x"\nimage="%s"\nrootless=1\n' "$3" >/run/.containerenv
if [ -n "$5" ]; then
    mkdir -p /run/tillandsias && printf 'kind=forge\nimage=%s\nversion=0.5.1\n' "$3" >/run/tillandsias/forge-launch
fi
plan="$1"; cwd="$2"; shift 5
cd "$cwd" || exit 98
exec "$plan" "$@"
]]
local function ns(image, mode, record, args)
    local argv = { "unshare", "-rm", "sh", "-c", NS, "ns", PLAN, C, image or "", mode or "", record and "1" or "" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return run(argv)
end
local EVAL = { "policy", "eval", "--", "tillandsias", "--reset-state" }
local function ns_eval(image, mode) local _, out = ns(image, mode, false, EVAL); return out end

local prc, probe = ns("", "", false, EVAL)
if prc == nil or prc >= 95 or probe == "" then
    skip("arms 3, 4, 5, 7: unprivileged user namespaces with a /run tmpfs are unavailable here (rc="
        .. tostring(prc) .. ")")
else
    local out = ns_eval("localhost/tillandsias-forge:v0.5.1", "0444")
    check(out == FORGE_ANS, "arm 3: the marker with the forge image reads forge",
        "arm 3: marked forge image answered [" .. out .. "]")
    out = ns_eval("localhost/tillandsias-forge:v0.5.1", "")
    check(out == BARE_ANS, "arm 3b: the forge image named without the marker is not a forge",
        "arm 3b: unmarked forge image answered [" .. out .. "] (the image name alone made a forge)")
    local o_m, o_w = ns_eval("", "0444"), ns_eval("", "0644")
    check(o_m == FORGE_ANS and o_w == BARE_ANS, "arm 3c: the marker alone reads forge; a writable marker does not",
        "arm 3c: marker alone [" .. o_m .. "] (want forge), writable marker [" .. o_w .. "] (want bare)")
    local o_tb = ns_eval("registry.fedoraproject.org/fedora-toolbox:44", "")
    local o_base = ns_eval("localhost/tillandsias-forge-base:v1", "")
    local o_imp = ns_eval("docker.io/evil/not-tillandsias-forge:v1", "")
    check(o_tb == BARE_ANS and o_base == BARE_ANS and o_imp == BARE_ANS,
        "arm 4: a toolbox, forge-base or look-alike image is not a forge",
        "arm 4: toolbox [" .. o_tb .. "] base [" .. o_base .. "] look-alike [" .. o_imp .. "]")
    check(probe == BARE_ANS, "arm 5: no container record reads bare metal",
        "arm 5: no record answered [" .. probe .. "]")

    -- ARM 7 (2444-vn38): the report, in each evidence shape.
    local HK = { "policy", "host-kind" }
    local function lines(s) local t = {}; for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[l] = true end; return t end
    local function has_note(s, needle)
        for l in s:gmatch("[^\n]+") do if l:sub(1, 5) == "note=" and l:find(needle, 1, true) then return true end end
        return false
    end
    local why = {}
    local c1, r1 = ns("localhost/tillandsias-forge:v0.5.1", "0444", true, HK)
    local l1 = lines(r1)
    if not (c1 == 0 and l1["kind=forge"] and l1["source=marker"] and l1["marker=valid"]
            and l1["record=present"] and l1["record_kind=forge"]
            and l1["ok:policy-host-kind:forge:marker"] and not r1:find("note=", 1, true)) then
        why[#why + 1] = "marker+record rc=" .. tostring(c1) .. " [" .. r1 .. "]"
    end
    local c2, r2 = ns("", "0644", false, HK)
    local l2 = lines(r2)
    if not (c2 == 0 and l2["kind=bare-metal"] and l2["marker=untrusted:writable"] and l2["record=absent"]) then
        why[#why + 1] = "writable marker rc=" .. tostring(c2) .. " [" .. r2 .. "]"
    end
    local c3, r3 = ns("localhost/tillandsias-forge:v0.5.1", "none", true, HK)
    local l3 = lines(r3)
    if not (c3 == 0 and l3["kind=bare-metal"] and l3["marker=absent"]
            and has_note(r3, "present without the forge marker")) then
        why[#why + 1] = "record without marker rc=" .. tostring(c3) .. " [" .. r3 .. "]"
    end
    local c4 = ns("", "", false, { "policy", "host-kind", "--host-kind", "forge" })
    if c4 ~= 2 then why[#why + 1] = "an override argument was accepted (rc=" .. tostring(c4) .. ", want 2)" end
    check(#why == 0, "arm 7: policy host-kind reports the decision and its evidence in every shape",
        "arm 7: " .. table.concat(why, "; "))
end

-- ── 6: the real builder toolbox ────────────────────────────────────────────
local have_toolbox = (not FORGE) and run({ "sh", "-c", "command -v toolbox" }) == 0
    and run({ "podman", "container", "exists", "tillandsias-builder" }) == 0
if not have_toolbox then
    skip("arm 6: no tillandsias-builder toolbox on this host")
else
    -- Under the litmus runner, PATH starts with its podman shim, which routes
    -- through the Rust facade and swallows the exec'd command's stdout, so the
    -- arm read [] (land85 relay). toolbox must reach the real podman.
    local keep = {}
    for p in (env.get("PATH") or ""):gmatch("[^:]+") do
        if not p:find("/litmus%-runtime/bin$") then keep[#keep + 1] = p end
    end
    local saved = ENV.PATH
    ENV.PATH = table.concat(keep, ":")
    local _, tout = run({ "toolbox", "run", "-c", "tillandsias-builder", PLAN, "policy", "eval", "--",
        "tillandsias", "--reset-state" })
    ENV.PATH = saved
    check(tout == BARE_ANS, "arm 6: the real builder toolbox is not a forge",
        "arm 6: toolbox answered [" .. tout .. "]")
end

-- ── 8: the report on this host agrees with the engine ──────────────────────
do
    local hc, hout = run({ PLAN, "policy", "host-kind" })
    local _, eout = run({ PLAN, "policy", "eval", "--", "tillandsias", "--reset-state" })
    local hk = hout:match("\nkind=([%w%-]+)") or hout:match("^kind=([%w%-]+)")
    local agree = (hk == "forge") == (eout == FORGE_ANS)
    check(hc == 0 and hk ~= nil and agree and hout:find("ok:policy-host-kind:", 1, true) ~= nil,
        "arm 8: policy host-kind on this host (kind=" .. tostring(hk) .. ") agrees with policy eval",
        "arm 8: host-kind rc=" .. tostring(hc) .. " kind=" .. tostring(hk) .. " eval=[" .. eout .. "]")
end

print("summary: pass=" .. pass .. " fail=" .. fail .. " skipped=" .. skipped)
if fail > 0 then verdict.refused("host-kind-evidence", fail .. "-failed") end
verdict.ok("host-kind-evidence:pass=" .. pass .. ":skipped=" .. skipped)
