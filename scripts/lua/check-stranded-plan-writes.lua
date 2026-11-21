-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1232-av4p, spec:ci-release
--
-- check-stranded-plan-writes.lua — name the PACKETS whose status only a salvage
-- or work ref knows about. (Ported from scripts/check-stranded-plan-writes.sh,
-- a shell-to-lua item; history in `git log -- scripts/check-stranded-plan-writes.sh`.)
--
-- salvage-audit.sh (1226-jb8y) answers which FILES on salvage/* and work/* refs
-- are not on trunk, and which side is ahead. On 2026-09-26 that was 351 lines
-- across 50 refs. The dangerous subset is invisible in a file list: a
-- `status:` write on a ref for a packet trunk reads differently. That is how an
-- unreachable forge session closed EIGHT packets onto a salvage ref while trunk
-- kept offering them as ready (1232-av4p), and how 1430-9227 found 18
-- never-landed fragments, one of which would have flipped 437 wrongly.
--
-- This reads the audit's RELAY CANDIDATES only (ref-may-be-AHEAD / ABSENT —
-- never a stale snapshot the branch has moved past), takes each plan fragment's
-- status writes from the REF's copy, and names every packet whose ref value
-- differs from trunk's folded status. It decides nothing: a line here is a
-- question for the coordinator (relay, refuse, or re-verify), not an action.
--
-- A ref value that merely DIFFERS from trunk is not yet a finding: an old claim
-- for a packet trunk has since completed loses to trunk's later write under LWW,
-- and relaying it would change nothing. So each fragment is folded INTO A
-- SCRATCH COPY OF TRUNK'S LEDGER with the real plan binary — no second
-- implementation of the LWW/ladder rules to drift — and a line says
-- `would-change` only when that fold's status differs from trunk's.
--
-- GRAMMAR (unchanged from the .sh)
--   stranded:would-change:<order>:<packet_id>:ref=<value>:trunk=<status>:folded=<status>:<fragment>:refs=<r1,..>
--   stranded:superseded:<order>:<packet_id>:ref=<value>:trunk=<status>:<fragment>:refs=<r1,..>
--   ok:stranded-plan-writes:<n> would-change, <s> superseded, on <m> ref(s)   exit 0
--   could-not-run:stranded-plan-writes:<reason>                  exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/check-stranded-plan-writes.lua [-- --from <file>]
-- --from <file> reads a saved salvage-audit transcript instead of running it
-- (relative to the checkout root; read with cat, so it may lie outside it).
--
-- DIFFERENCES FROM THE .sh, by the runtime's design:
--   * the plan binary is TILLANDSIAS_PLAN_BIN, else TILLANDSIAS_SCRIPT_RUNNER_BIN,
--     else <root>/target/release/tillandsias-plan, else tillandsias-plan on PATH
--     (the .sh sourced plan-binary-probe.sh, which also tries CARGO_TARGET_DIR,
--     .exe and debug builds); none that exists is no-plan-binary, as before.
--   * the audit's stderr (its per-ref detail) and stdout (its verdict) arrive
--     separately and are joined stderr-then-stdout; the .sh merged them with
--     2>&1. Equal while salvage-audit writes all detail before its verdict.
--   * grouping and output order are byte order (children run LC_ALL=C); the
--     .sh's sort used the caller's locale.
--   * the scratch ledger lives under target/plan-scratch/, not $TMPDIR.
--   * the checkout judged is the one the runtime roots at (its children start
--     there): TILLANDSIAS_REPO_ROOT, else PROJECT_ROOT, else the current
--     directory's checkout. The .sh judged the checkout it lived in. A caller
--     judging another checkout sets TILLANDSIAS_REPO_ROOT to it.

local REMOTE = "origin"

local function cnr(reason)
    verdict.emit("could-not-run:stranded-plan-writes:" .. reason, 3)
end

local FROM = ""
do
    local i = 1
    while i <= #arg do
        if arg[i] == "--from" then
            FROM = arg[i + 1] or ""; i = i + 2
        else
            cnr("unknown-argument:" .. tostring(arg[i]))
        end
    end
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = (top.status == "exited" and top.code == 0) and text.trim(top.stdout or "") or ""
if ROOT == "" then cnr("not-a-git-repo") end

local function run(argv, timeout)
    return proc.run({ argv = argv, cwd = ROOT, timeout_ms = timeout or 120000 })
end
local function ok(r) return r.status == "exited" and r.code == 0 end

local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or "" end
if PLAN == "" then
    if fs.exists(ROOT .. "/target/release/tillandsias-plan") then
        PLAN = ROOT .. "/target/release/tillandsias-plan"
    else
        PLAN = "tillandsias-plan"
    end
end
if not ok(run({ PLAN, "capabilities" }, 30000)) then cnr("no-plan-binary") end

local audit
if FROM ~= "" then
    local r = run({ "cat", FROM }, 30000)
    if not ok(r) then cnr("unreadable:" .. FROM) end
    audit = r.stdout or ""
else
    -- salvage-audit prints its per-ref detail on STDERR and only the verdict
    -- on stdout; the .sh read them merged (2>&1). The detail is all written
    -- before the verdict, so stderr-then-stdout is the merged transcript.
    local r = run({ "bash", ROOT .. "/scripts/salvage-audit.sh" }, 600000)
    local e = r.stderr or ""
    if e ~= "" and e:sub(-1) ~= "\n" then e = e .. "\n" end
    audit = e .. (r.stdout or "")
end
local lines = text.lines(audit)
local last = ""
for i = #lines, 1, -1 do
    if lines[i] ~= "" then last = lines[i]; break end
end
if last:sub(1, 17) == "ok:salvage-audit:" then
    -- proceed
elseif last:sub(1, 22) == "skipped:salvage-audit:" then
    verdict.emit("ok:stranded-plan-writes:0 packet(s) on 0 ref(s)", 0)
else
    cnr("salvage-audit-failed")
end

local REL = "target/plan-scratch/stranded-plan-writes-" .. tostring(math.random(100000, 999999))
local WORK = ROOT .. "/" .. REL
fs.mkdir(REL)
local function cleanup() run({ "rm", "-rf", WORK }, 60000) end
local function bail(reason) cleanup(); cnr(reason) end

-- (ref, fragment) pairs the audit calls relay candidates: a ref header is a
-- line indented two spaces, a candidate a fragment line indented four whose
-- second field is ref-may-be-AHEAD or ABSENT.
local pairs_ = {}
local ref = nil
for _, l in ipairs(lines) do
    if l:match("^  [^ ]") then
        ref = l:match("^%s*(%S+)")
    elseif l:match("^    plan/index%.d/[^ ]+%.yaml") then
        local f1, f2 = l:match("^%s*(%S+)%s+(%S+)")
        if f2 == "ref-may-be-AHEAD" or f2 == "ABSENT" then
            pairs_[#pairs_ + 1] = { ref or "", f1 }
        end
    end
end

-- ref value per (fragment, packet).
local writes, seen = {}, {}
local EXPR = '((.status // [])[], (.fields // [])[]) | select(.field == "status" and (.packet_id // "") != "") | [.packet_id, (.value | tostring)]'
for _, p in ipairs(pairs_) do
    local r, frag = p[1], p[2]
    if r ~= "" and frag ~= "" then
        local show = run({ "git", "show", REMOTE .. "/" .. r .. ":" .. frag })
        if ok(show) then
            fs.write(REL .. "/frag.yaml", show.stdout or "")
            local yj = run({ PLAN, "yaml-json", WORK .. "/frag.yaml" })
            if ok(yj) then
                fs.write(REL .. "/frag.json", yj.stdout or "")
                local jg = run({ PLAN, "json", "get", "-c", EXPR, WORK .. "/frag.json" })
                if not ok(jg) then bail("json-get-refused:" .. frag) end
                for _, jl in ipairs(text.lines(jg.stdout or "")) do
                    local okp, v = pcall(json.parse, jl)
                    if okp and type(v) == "table" and type(v[1]) == "string" and type(v[2]) == "string" then
                        local key = v[1] .. "\t" .. v[2] .. "\t" .. frag .. "\t" .. r
                        if not seen[key] then
                            seen[key] = true
                            writes[#writes + 1] = { pid = v[1], value = v[2], frag = frag, ref = r, key = key }
                        end
                    end
                end
            end
        end
    end
end

-- Trunk's ledger, once, into a scratch tree the fragments are folded into.
fs.mkdir(REL .. "/trunk")
local arch = run({ "git", "archive", "-o", WORK .. "/trunk.tar", REMOTE .. "/linux-next", "plan/index.yaml", "plan/index.d" })
if not ok(arch) or not ok(run({ "tar", "-x", "-f", WORK .. "/trunk.tar", "-C", WORK .. "/trunk" })) then
    bail("cannot-extract-trunk-ledger")
end
local TIDX = WORK .. "/trunk/plan/index.yaml"

-- Group (pid, value, frag): refs joined in sorted order, ref1 the first.
table.sort(writes, function(a, b) return a.key < b.key end)
local groups, gidx = {}, {}
for _, w in ipairs(writes) do
    local k = w.pid .. "\t" .. w.value .. "\t" .. w.frag
    local g = gidx[k]
    if not g then
        g = { pid = w.pid, value = w.value, frag = w.frag, refs = {}, ref1 = w.ref }
        gidx[k] = g; groups[#groups + 1] = g
    end
    g.refs[#g.refs + 1] = w.ref
end
for _, g in ipairs(groups) do
    g.refstr = table.concat(g.refs, ",")
    g.line = g.pid .. "\t" .. g.value .. "\t" .. g.frag .. "\t" .. g.refstr .. "\t" .. g.ref1
end
table.sort(groups, function(a, b) return a.line < b.line end)

local function status_of(pid)
    local r = run({ PLAN, "--index", TIDX, "status", pid })
    local first = text.lines(r.stdout or "")[1] or ""
    local order, st = first:match("^([^\t]*)\t?([^\t]*)")
    return order or "", st or ""
end

local n, sup, refset, nref = 0, 0, {}, 0
for _, g in ipairs(groups) do
    local order, trunk = status_of(g.pid)
    if trunk == "" then order = "?"; trunk = "absent-on-trunk" end
    if trunk ~= g.value then
        local dest = REL .. "/trunk/" .. g.frag
        local folded
        if fs.exists(dest) then
            folded = trunk
        else
            local show = run({ "git", "show", REMOTE .. "/" .. g.ref1 .. ":" .. g.frag })
            fs.write(dest, ok(show) and (show.stdout or "") or "")
            local _, f = status_of(g.pid)
            folded = f
            run({ "rm", "-f", WORK .. "/trunk/" .. g.frag }, 30000)
            if folded == "" then folded = trunk end
        end
        if folded ~= trunk then
            out.line("stranded:would-change:" .. order .. ":" .. g.pid .. ":ref=" .. g.value .. ":trunk=" .. trunk ..
                ":folded=" .. folded .. ":" .. g.frag .. ":refs=" .. g.refstr)
            n = n + 1
        else
            out.line("stranded:superseded:" .. order .. ":" .. g.pid .. ":ref=" .. g.value .. ":trunk=" .. trunk ..
                ":" .. g.frag .. ":refs=" .. g.refstr)
            sup = sup + 1
        end
        for _, r in ipairs(g.refs) do
            if r ~= "" and not refset[r] then refset[r] = true; nref = nref + 1 end
        end
    end
end
cleanup()
verdict.emit("ok:stranded-plan-writes:" .. n .. " would-change, " .. sup .. " superseded, on " .. nref .. " ref(s)", 0)
