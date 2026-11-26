-- @env PATH HOME TMPDIR CARGO_TARGET_DIR TILLANDSIAS_PLAN_BIN TILLANDSIAS_XBRANCH_CLAIM_HOST TILLANDSIAS_XBRANCH_ANCESTOR_SKIP TILLANDSIAS_WORKSTATION TILLANDSIAS_HOST_KIND
-- @trace spec:meta-orchestration, order:1034-whsp, order:1104-w9np, order:1423-ydy3, order:1435-ebcx, order:1948-xbaf, order:2316-6kzg, order:2323-wwaa
--
-- check-claims-across-branches.lua — is this packet claimed on a SIBLING branch? Ported from the
-- .sh of the same name; the grammar, exits and affordances are unchanged.
--
-- WHY (1034-whsp, measured on tlatoanis-macbook-air 2026-09-05): a platform host's claim reaches a
-- trunk host only when the coordinator RELAYS its branch into linux-next, 19m to 2h02m later, not
-- when its push lands (12 s). This reads what is already published: every platform branch is on
-- origin and a claim is a fragment file, so folding each sibling's ledger answers "is anyone else
-- holding this" without a new channel. NOT A LOCK: it narrows an hours-wide race to one fetch, and
-- the claim timestamp still arbitrates.
--
-- THE EXTRACT DIES WITH ITS FOLD (1423-ydy3). Each sibling's plan/ (~19 MB) is extracted and folded
-- inside ONE short shell child whose own EXIT/INT/TERM trap removes it, so a killed run leaks nothing
-- the shell version did not (SIGKILL still cannot be trapped). This file never holds an extract.
--
-- Usage: tillandsias-plan script run scripts/lua/check-claims-across-branches.lua -- <packet> [--no-fetch]
--        tillandsias-plan script run scripts/lua/check-claims-across-branches.lua -- --batch <id> [<id>...]
-- Verdict, one line on stdout:
--   ok:cross-branch-claims:<n> sibling branch(es) checked[...]     exit 0
--     <n> counts folded siblings only; ", unchecked: <b>..." names the rest (2316-6kzg)
--   own-claim-reflected:<packet>:<branch> lines, then ok             exit 0 (1104-w9np)
--   claimed-elsewhere:<packet>:<branch>                              exit 1
--   unknown-packet:<packet>:...                                      exit 2
--   blocked:<reason>                                                 exit 2 — NEVER read as unclaimed
-- Seams (fixtures only): TILLANDSIAS_PLAN_BIN, TILLANDSIAS_XBRANCH_CLAIM_HOST forces the attribution,
-- TILLANDSIAS_XBRANCH_ANCESTOR_SKIP=0 restores the strict pre-1948-xbaf verdict.

local SIBLINGS = { "linux-next", "windows-next", "osx-next" }

-- ORDER 2246-fkea, inlined: a decider a fixture runs from a scratch copy has no lib/ beside it.
local SH
do
    local r = proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }
    local ep = text.trim(r.stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then SH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) end
    SH = SH or "bash"
end

local function eget(k) local v = env.get(k); if v == nil or v == "" then return nil end; return v end
-- ORDER 1247-omqr: every refusal says WHY and WHAT would clear it, on stderr; stdout tokens unchanged.
local function afford(why, remedy) log.raw("  why: " .. why .. "\n  remedy: " .. remedy) end
local function blocked(reason, why, remedy, note)
    if note then log.raw(note) end
    afford(why, remedy)
    verdict.emit("blocked:" .. reason, 2)
end

local args = arg or {}
local BATCH, PACKET, NO_FETCH, IDS = false, nil, false, {}
if args[1] == "--batch" then
    BATCH = true
    for i = 2, #args do IDS[#IDS + 1] = args[i] end
    if #IDS == 0 then
        blocked("usage", "--batch was given no packet ids, so there is nothing to look up",
            "pass the ids: check-claims-across-branches.lua -- --batch <id> [<id>...]")
    end
else
    PACKET = args[1]
    if not PACKET or PACKET == "" then
        blocked("usage", "no packet id or order was given, so there is nothing to look up",
            "check-claims-across-branches.lua -- <packet-id-or-order> [--no-fetch] | --batch <id>...")
    end
    NO_FETCH = args[2] == "--no-fetch"
end

local top = proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then
    blocked("no-root", "the current directory is not inside a readable checkout, so no sibling ledger can be folded",
        "run it from inside the checkout (tillandsias-plan script run scripts/lua/check-claims-across-branches.lua from its repo root); never read this as unclaimed")
end
local function git(...)
    local a = { "git", "-C", ROOT, ... }
    return proc.run{ argv = a, timeout_ms = 120000 }
end

-- RESOLVE THE VALIDATOR THROUGH THE SHARED PROBE, AND REFUSE WITHOUT ONE (1024-c3h3 in advance):
-- "no binary" must never print "nobody else holds this packet".
local function resolve(drop_override)
    local r = proc.run{ argv = { SH, "-s", "--", ROOT }, cwd = ROOT, timeout_ms = 60000,
        env_unset = drop_override and { "TILLANDSIAS_PLAN_BIN" } or nil,
        stdin = 'cd "$1" || exit 9\n. scripts/plan-binary-probe.sh\np="$(resolve_plan_binary 2>/dev/null)" || p=""\n'
            .. 'case "$p" in ./*) p="$1/${p#./}" ;; esac\nprintf "%s" "$p"\n' }
    local p = text.trim(r.stdout or "")
    return p ~= "" and p or nil
end
local NO_BIN_WHY = "no runnable tillandsias-plan resolved (scripts/plan-binary-probe.sh), and folding a sibling's ledger needs one"
local NO_BIN_FIX = "build it (./build.sh, or cargo build --release -p tillandsias-plan), or point TILLANDSIAS_PLAN_BIN at a runnable binary, then re-run"
local PLAN_BIN = resolve(false)
if not PLAN_BIN then
    blocked("no-plan-binary", NO_BIN_WHY, NO_BIN_FIX,
        "blocked:no-plan-binary — cannot fold a sibling branch's ledger, so this says NOTHING about who holds a packet or any packet; build with ./build.sh (never read this as unclaimed)")
end
local OVERRIDE_DROPPED = false
-- The plan binary runs through the shell, never natively: an override may be a shebang script
-- (a fixture's stub), which a native spawn cannot start on Windows.
local BIN_EXEC = 'exec "$@"\n'

-- The fold for one sibling, in one shell child that owns the extract. It prints:
--   FOLD=ok|fail, then READY <id> lines (batch), ST <id> <status> lines, HOST <label> (single).
-- The parser below is the .sh's verbatim; a fixture extracts it from this file by name.
local PARSER = [==[
_claim_host_on_branch() { # _claim_host_on_branch <archived-tree> <packet-id-or-order>
    if [ -n "${TILLANDSIAS_XBRANCH_CLAIM_HOST:-}" ]; then
        printf '%s' "$TILLANDSIAS_XBRANCH_CLAIM_HOST"
        return 0
    fi
    local tree="$1" who="$2"
    [ -d "$tree/plan/index.d" ] || return 0
    find "$tree/plan/index.d" -maxdepth 1 -name '*.yaml' -type f -print0 2>/dev/null |
        LC_ALL=C sort -z | xargs -0 -r awk -v want="$who" '
            FNR == 1 { inblk = 0; pid = ""; f = ""; t = ""; h = "" }
            /^[[:space:]]*-[[:space:]]*packet_id:/ { pid=$0; sub(/^[^:]*:[[:space:]]*/,"",pid); inblk=(index(pid,want)>0 || index(want,pid)>0); f=""; t=""; h="" }
            inblk && /^[[:space:]]*field:[[:space:]]*status[[:space:]]*$/ { f=1 }
            inblk && /^[[:space:]]*ts:/ { t=$0; sub(/^[^:]*:[[:space:]]*/,"",t); gsub(/"/,"",t) }
            inblk && /^[[:space:]]*host:/ { h=$0; sub(/^[^:]*:[[:space:]]*/,"",h); if (f && t != "" && h != "") print t "\t" h }
        ' 2>/dev/null | sort -r | head -1 | cut -f2
}
]==]
local FOLD = PARSER .. [==[
ROOT="$1"; BIN="$2"; B="$3"; MODE="$4"; CHK="$5"; shift 5
cd "$ROOT" || exit 9
tmp="$(mktemp -d "${TMPDIR:-/tmp}/xbranch.$$.XXXXXX")" || { echo FOLD=fail; exit 0; }
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! git archive "origin/$B" plan/index.yaml plan/index.d 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then echo FOLD=fail; exit 0; fi
if [ "$CHK" = 1 ]; then
    case "$("$BIN" --index "$tmp/plan/index.yaml" capabilities 2>&1 >/dev/null)" in
        *"unknown subcommand '--index'"*) echo OVERRIDE=drop; exit 0 ;;
    esac
fi
echo FOLD=ok
if [ "$MODE" = batch ]; then
    ready="$("$BIN" --index "$tmp/plan/index.yaml" ready any 2>/dev/null | awk '{print $1}')"
    printf '%s\n' "$ready" | sed -n 's/^./READY &/p'
    [ -n "$ready" ] || exit 0
    for id in "$@"; do
        case "
$ready
" in *"
$id
"*) continue ;; esac
        printf 'ST %s %s\n' "$id" "$("$BIN" --index "$tmp/plan/index.yaml" status "$id" 2>/dev/null | awk '{print $2}')"
    done
else
    st="$("$BIN" --index "$tmp/plan/index.yaml" status "$1" 2>/dev/null | awk '{print $2}')"
    printf 'ST %s %s\n' "$1" "$st"
    [ "$st" = in_progress ] && printf 'HOST %s\n' "$(_claim_host_on_branch "$tmp" "$1")"
fi
]==]
-- ORDER 2323-wwaa. An inherited TILLANDSIAS_PLAN_BIN may be a wrapper that already passes --index;
-- every fold passes its own and the binary refuses the second, so each sibling folded to 0 rows.
-- Keyed on the binary's own refusal; any other failing override is still the caller's choice.
-- Asked ONCE, inside the first fold and against its extract, as the .sh did: the extract exists
-- (and its shell's trap owns it) before the override is ever run.
local override_unchecked = eget("TILLANDSIAS_PLAN_BIN") ~= nil
local function fold(b, mode, ids)
    local chk = override_unchecked and "1" or "0"
    override_unchecked = false
    local a = { SH, "-s", "--", ROOT, PLAN_BIN, b, mode, chk }
    for _, id in ipairs(ids) do a[#a + 1] = id end
    local r = proc.run{ argv = a, cwd = ROOT, stdin = FOLD, timeout_ms = 600000,
        env_unset = OVERRIDE_DROPPED and { "TILLANDSIAS_PLAN_BIN" } or nil }
    local o = (r.stdout or ""):gsub("\r", "")
    if o:find("OVERRIDE=drop", 1, true) then
        log.raw("note:cross-branch-claims:plan-bin-override-fixes-its-own-index — folding siblings with the checkout's own plan binary")
        OVERRIDE_DROPPED = true
        PLAN_BIN = resolve(true)
        if not PLAN_BIN then
            blocked("no-plan-binary", "TILLANDSIAS_PLAN_BIN fixes its own --index, so it cannot read a sibling's ledger, and no other tillandsias-plan resolved",
                "build it (cargo build --release -p tillandsias-plan) or unset TILLANDSIAS_PLAN_BIN, then re-run")
        end
        return fold(b, mode, ids)
    end
    local res = { ok = o:find("FOLD=ok", 1, true) ~= nil, ready = {}, nready = 0, st = {}, host = nil }
    for line in o:gmatch("([^\n]*)\n") do
        local id = line:match("^READY (.+)$")
        if id then res.ready[id] = true; res.nready = res.nready + 1 end
        local sid, st = line:match("^ST (%S+) ?(%S*)$")
        if sid then res.st[sid] = st end
        local h = line:match("^HOST (.*)$")
        if h then res.host = h end
    end
    return res
end

-- 1012-hu7d: BOTH VOCABULARIES COUNT AS "ME" (node name, workstation label, platform bucket).
local NAMES = {}
do
    local r = proc.run{ argv = { SH, "-s" }, timeout_ms = 10000, stdin = 'hostname -s 2>/dev/null || echo\nuname -s | tr "A-Z" "a-z"\n' }
    for l in ((r.stdout or ""):gsub("\r", "")):gmatch("([^\n]*)\n") do if l ~= "" then NAMES[l] = true end end
    for _, k in ipairs{ "TILLANDSIAS_WORKSTATION", "TILLANDSIAS_HOST_KIND" } do local v = eget(k); if v then NAMES[v] = true end end
end
local function is_me(h) return h ~= nil and h ~= "" and NAMES[h] == true end

-- ORDER 1423-ydy3 / 2392-tv47: THE BOUND FOR AN ABRUPT STOP. The fold's own trap removes its extract on
-- every stop it can see. Some it cannot: SIGKILL, and on native Windows every way a native runner is
-- ended. A deadline uses TerminateJobObject, and a Git Bash kill hard-terminates the runner's MSYS
-- descendants. Neither lets a trap run. So each run first removes the extracts whose owner is gone.
-- An extract is named xbranch.<fold-shell-pid>.XXXXXX, and one whose pid is no longer alive is
-- stale. A name without a pid (the older xbranch.XXXXXX form) is stale after 60 minutes, which is
-- longer than any fold's own 600 s deadline.
do
    local r = proc.run{ argv = { SH, "-s" }, timeout_ms = 60000, stdin = [==[
n=0
for d in "${TMPDIR:-/tmp}"/xbranch.*; do
    [ -d "$d" ] || continue
    pid="${d##*/xbranch.}"; pid="${pid%%.*}"
    case "$pid" in
        ''|*[!0-9]*) [ -n "$(find "$d" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue ;;
        *) ! kill -0 "$pid" 2>/dev/null || continue ;;
    esac
    rm -rf "$d" && n=$((n + 1))
done
echo "$n"
]==] }
    local n = tonumber(text.trim(r.stdout or "")) or 0
    if n > 0 then log.raw("note:cross-branch-claims:swept-stale-extracts:" .. n .. " (an earlier run stopped before its trap ran)") end
end

local CURRENT = text.trim(git("rev-parse", "--abbrev-ref", "HEAD").stdout or "")
-- ORDER 1948-xbaf: a sibling that is an ANCESTOR of HEAD holds nothing HEAD has not folded.
local function ancestor(b)
    if eget("TILLANDSIAS_XBRANCH_ANCESTOR_SKIP") == "0" then return false end
    return git("merge-base", "--is-ancestor", "origin/" .. b, "HEAD").code == 0
end
local function resolves(b) return git("rev-parse", "--verify", "-q", "origin/" .. b).code == 0 end

if not NO_FETCH then
    local a = { "git", "-C", ROOT, "fetch", "-q", "origin" }
    for _, b in ipairs(SIBLINGS) do a[#a + 1] = b end
    if proc.run{ argv = a, timeout_ms = 300000 }.code ~= 0 then
        blocked("fetch-failed", "git fetch of the sibling platform branches from origin failed, so their claims cannot be seen",
            "check the remote with git remote -v and git ls-remote origin, then re-run; to decide on the last-fetched refs instead (possibly stale), re-run with --no-fetch",
            "blocked:fetch-failed — cannot see sibling branches, so this says NOTHING about who holds " .. (PACKET or "these packets"))
    end
end

-- ORDER 2316-6kzg: a sibling counts as checked only once its ledger was FOLDED.
local unchecked = {}
local function unfolded(b)
    unchecked[#unchecked + 1] = b
    log.raw("unchecked:" .. b)
    afford("origin/" .. b .. "'s ledger could not be extracted, so nothing on that branch was compared and it is not counted as checked",
        "run git archive origin/" .. b .. " plan/index.yaml plan/index.d | tar -t to see why, then re-run; never read an unchecked branch as unclaimed")
end
local function unchecked_tail() return #unchecked > 0 and (", unchecked: " .. table.concat(unchecked, " ")) or "" end
local function no_siblings(subject)
    blocked("no-siblings-folded", "no sibling platform branch (other than the current one) resolved as origin/<branch> and had its ledger folded"
        .. (#unchecked > 0 and (" (unchecked: " .. table.concat(unchecked, " ") .. ")") or "") .. ", so nothing was compared" .. (subject or ""),
        "fetch the sibling branches (git fetch origin), confirm they resolve with git branch -r, then re-run; never read this as unclaimed",
        "blocked:no-siblings-folded")
end

if BATCH then
    -- --batch: FOLD ONCE PER SIBLING, then answer every id. Stage 1 (`ready any`, one call) clears
    -- almost every id; stage 2 asks `status` only for the absent ones, because absent-from-ready
    -- also covers done/blocked/obsoleted, and calling those claimed-elsewhere would be a false accusation.
    local checked, hits = 0, 0
    for _, b in ipairs(SIBLINGS) do
        if resolves(b) and b ~= CURRENT then
            if ancestor(b) then
                checked = checked + 1
            else
                local f = fold(b, "batch", IDS)
                if not f.ok then
                    unfolded(b)
                elseif f.nready == 0 then
                    log.raw("blocked:empty-fold:" .. b)
                    afford("the plan binary folded origin/" .. b .. "'s ledger into an empty ready set, which cannot be told apart from everything being claimed, so that branch is skipped and not counted as checked",
                        "check the binary can read that ledger: git archive origin/" .. b .. " plan/index.yaml plan/index.d | tar -t, then tillandsias-plan --index <extract>/plan/index.yaml ready any")
                    unchecked[#unchecked + 1] = b
                else
                    checked = checked + 1
                    for _, id in ipairs(IDS) do
                        if not f.ready[id] and f.st[id] == "in_progress" then
                            out.line("claimed-elsewhere:" .. id .. ":" .. b)
                            afford("origin/" .. b .. " holds " .. id .. " in_progress, and your fold has not seen that claim yet",
                                "do not implement " .. id .. "; pick the next candidate. Arbitration is by claim timestamp: tillandsias-plan script run scripts/lua/check-claim-confirmed.lua -- " .. id .. " --host <you> says whose claim is earlier")
                            hits = hits + 1
                        end
                    end
                end
            end
        end
    end
    if checked == 0 then no_siblings() end
    verdict.emit("ok:cross-branch-claims:" .. checked .. " sibling branch(es) checked, " .. #IDS .. " packet(s)" .. unchecked_tail(), hits > 0 and 1 or 0)
end

-- Per packet. ORDER 1091: does the packet EXIST anywhere? Without it "nobody holds it" and "no
-- such packet" both printed ok, and a host acting on that ok would claim a phantom.
local checked, found, mine, seen = 0, {}, {}, false
for _, b in ipairs(SIBLINGS) do
    if resolves(b) and b ~= CURRENT then
        -- Fold and ask, never grep: status is LWW and a later fragment can release a claim (635-i6vm).
        local f = fold(b, "single", { PACKET })
        if not f.ok then
            unfolded(b)
        else
            checked = checked + 1
            local st = f.st[PACKET] or ""
            if st ~= "" then seen = true end
            -- 1948-xbaf: an ancestor still proves existence, but its in_progress is already folded past.
            if st == "in_progress" and ancestor(b) then st = "superseded" end
            if st == "in_progress" then
                -- 1104-w9np: a holder that is THIS host is its own claim reflected by a merge.
                -- Unattributable is NOT "mine": the safe direction for an ambiguous answer is the refusal.
                if is_me(f.host) then mine[#mine + 1] = b else found[#found + 1] = b end
            end
        end
    end
end

-- ORDER 1435-ebcx: zero siblings folded is not "nobody holds it", in per-packet mode too.
if checked == 0 then no_siblings(" for " .. PACKET) end
if #found == 0 and #mine > 0 then
    for _, b in ipairs(mine) do out.line("own-claim-reflected:" .. PACKET .. ":" .. b) end
    log.raw("  Every sibling branch holding this packet in_progress records THIS HOST as the\n"
        .. "  claimant — your own claim, merged back by routine integration (1104-w9np).\n"
        .. "  It IS yours: resume it, or release it with set-field status ready if you are\n"
        .. "  not going to finish it. Measured cost of the old answer: a day of finished work\n"
        .. "  left stranded because the tool said 'NOT yours to implement' about its author's\n"
        .. "  own claim.")
    verdict.emit("ok:cross-branch-claims:" .. checked .. " sibling branch(es) checked; own claim reflected by " .. #mine .. unchecked_tail(), 0)
end
if #found > 0 then
    for i = 1, #found - 1 do out.line("claimed-elsewhere:" .. PACKET .. ":" .. found[i]) end
    log.raw("  A sibling branch holds this packet in_progress and your fold has not seen it yet.\n"
        .. "  It is NOT yours to implement. Arbitration is by claim TIMESTAMP, not push order:\n"
        .. "  if yours is earlier you continue; if theirs is earlier you release and reroute.")
    afford("a sibling branch holds " .. PACKET .. " in_progress under another host's claim",
        "run tillandsias-plan script run scripts/lua/check-claim-confirmed.lua -- " .. PACKET .. " --host <you>: if it confirms your claim is earlier, continue; if it answers refused:claim-lost, release with set-field " .. PACKET .. " status ready and take another packet")
    verdict.emit("claimed-elsewhere:" .. PACKET .. ":" .. found[#found], 1)
end
-- The local fold counts as existence too: a packet this host just filed is real before it reaches a sibling.
if not seen then
    seen = proc.run{ argv = { SH, "-s", "--", PLAN_BIN, "status", PACKET }, stdin = BIN_EXEC, cwd = ROOT, timeout_ms = 60000,
        env_unset = OVERRIDE_DROPPED and { "TILLANDSIAS_PLAN_BIN" } or nil }.code == 0
end
if not seen then
    log.raw("  No branch and no local fold knows this packet. That is NOT the same\n"
        .. "  as unclaimed: an ok here would send you to claim something that does\n"
        .. "  not exist, or that its author has not pushed yet.")
    afford("no sibling branch and no local fold knows " .. PACKET,
        "check the reference with tillandsias-plan status " .. PACKET .. " after git pull; if its author has not pushed yet, wait for the push; otherwise correct the id or order")
    verdict.emit("unknown-packet:" .. PACKET .. ":" .. checked .. " sibling branch(es) checked" .. unchecked_tail(), 2)
end
verdict.emit("ok:cross-branch-claims:" .. checked .. " sibling branch(es) checked" .. unchecked_tail(), 0)
