-- preflight: serial — writes the fixed /tmp/tillandsias-timing.jsonl and counts lines of the fixed /tmp/forge-expert-usage.jsonl before and after a run
-- @env PATH HOME TMPDIR
-- @trace order:890-t9pu, order:1125-92xa, order:1209-hkcq, order:1096-p3tn, order:1455-d7hc, order:1807-shtg, order:2006-wahn
--
-- test-metrics-log-path-agreement.lua — the writer and the reader of a metrics log must resolve
-- the SAME path, and a record must name the host that made it. Ported from the .sh of the same
-- name. The subjects stay shell (metrics-log-path.sh, cycle-metrics.sh) and the Rust plan binary;
-- each arm runs its subject under fixture.posix_shell() and this file judges what it printed.
--
-- The defect this pins: `/tmp` was the default in four places across three scripts, and `/tmp`
-- is not one place. On a Windows host the gate re-execs into WSL2 and writes there while
-- cycle-metrics.sh reads Git Bash's filesystem — 322 records on one side, 0 on the other.
--
-- ORDER 1209-hkcq: THIS FIXTURE MUST NOT WRITE THE HOST'S OWN METRICS. Every child inherits a
-- scratch TILLANDSIAS_EXPERT_USAGE_LOG, except arm 1c, whose subject is whether the writer
-- DERIVES its path, so it alone drops the override. It tests the DEFAULT paths on purpose, which
-- is why check-cycle-metrics-fixtures-pin-logs.lua exempts it.
--
--   1   the three health-log participants ask the shared rule (probe, surface, report)
--   1b  the Rust writer and the shell rule resolve the same usage-log path (1125-92xa)
--   1c  the real CLI writer appends inside its OWN checkout; the host's log is unchanged
--   1d  outside a checkout the Rust writer falls back to /tmp
--   2   in a checkout the default is repo-relative   2b and gitignored
--   3   NEGATIVE CONTROL outside a checkout the shell rule falls back to /tmp
--   4   an explicit TILLANDSIAS_*_LOG still wins
--   5   host attribution survives a missing `hostname` binary   6 'unknown' still reachable
--   7   the log is outside target/ (cargo clean cannot eat it; 1807-shtg: judged relative)
--   8   an unresolvable rule file REFUSES   8b MUTATION the pre-1096-p3tn script does not
--   9   a second live timing log is refused   9b CONTROL a named log stands the guard down
--   9c  CONTROL --emit-* is unaffected by a split, the report still refuses it
--   9z  the run leaves no default-path timing log behind; a fixture-only leftover is swept first
--   W   in a linked worktree the Rust writer and the shell reader agree (1455-d7hc)
--
-- Usage: tillandsias-plan script run scripts/lua/test-metrics-log-path-agreement.lua
-- Verdict: ok:metrics-log-path-agreement:<n> arms | violation:metrics-log-path-agreement:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("metrics-log-path-agreement")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local OWN = T:scratch("own")
local USAGE = OWN.abs .. "/forge-expert-usage.jsonl"

-- Every arm's shell: the root, a scratch dir and the plan binary as $1..$3, the gate's private
-- fallback dropped (1966-ubsw: this fixture pins the DEFAULT /tmp fallback), and say k v.
local PRE = [==[
set -u
R="$1"; W="$2"; BIN="$3"
unset TILLANDSIAS_METRICS_FALLBACK_DIR
say() { printf '%s=%s\n' "$1" "$2"; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
]==]

local function sh(body, opts)
    opts = opts or {}
    local w = opts.w or T:scratch()
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") or w.abs,
        TILLANDSIAS_EXPERT_USAGE_LOG = USAGE, TILLANDSIAS_CYCLE_METRICS_SKIP_TRACES = "1" }
    local tmpdir = env.get("TMPDIR")
    if tmpdir and tmpdir ~= "" then e.TMPDIR = tmpdir end
    for k, v in pairs(opts.env or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, "-s", "--", ROOT, w.abs, opts.bin or "" }, cwd = ROOT, stdin = PRE .. body,
        env = e, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, timeout_ms = opts.timeout_ms or 300000 }
    local x = { w = w, why = "rc=" .. tostring(r.code) .. " " .. (r.stdout or ""):sub(1, 600) .. (r.stderr or ""):sub(1, 300) }
    for k, v in (r.stdout or ""):gsub("\r", ""):gmatch("([%w_]+)=([^\n]*)\n") do x[k] = v end
    return x
end
local function starts(v, p) return v ~= nil and v:sub(1, #p) == p end
local function n(v) return tonumber(v or "") or -1 end

-- ── arm 1: every participant resolves the same health-log path ────────────────
-- Asked of the scripts themselves, not of the shared library, so a script that forgets to
-- source the rule is caught rather than assumed correct.
local function count(path, needle)
    if not fs.exists(path) then return 0 end
    local c = 0
    for line in (fs.read(path) .. "\n"):gmatch("([^\n]*)\n") do
        if text.contains(line, needle) then c = c + 1 end
    end
    return c
end
local probe_decl = count("scripts/check-mcp-expert-health.sh", "metrics_default_log forge-expert-health.jsonl")
local surface_decl = count("scripts/check-mcp-surface.sh", "metrics_default_log forge-expert-health.jsonl")
-- The reporter resolves defaults at top level through _default_log_into (the refusal must stop it).
local report_decl = count("scripts/cycle-metrics.sh", "_default_log_into HEALTH_LOG forge-expert-health.jsonl")
T:arm("1 all three health-log participants ask the shared rule (probe, surface, report)",
    probe_decl >= 1 and surface_decl >= 1 and report_decl >= 1,
    "probe=" .. probe_decl .. " surface=" .. surface_decl .. " report=" .. report_decl)

local base = sh [==[
say probe "$(unset TILLANDSIAS_EXPERT_HEALTH_LOG; . "$R/scripts/metrics-log-path.sh" 2>/dev/null || true; metrics_default_log forge-expert-health.jsonl "$R")"
say usage "$(. "$R/scripts/metrics-log-path.sh" 2>/dev/null || true; metrics_default_log forge-expert-usage.jsonl "$R")"
say rootsh "$(cd "$R" && pwd)"
]==]
local probe, shell_usage, ROOTSH = base.probe or "", base.usage or "", base.rootsh or ROOT

-- ── arms 1b-1d: THE RUST PARTICIPANT AGREES WITH THE SHELL RULE (1125-92xa) ───
-- The rule lives in a SHELL file and a Rust binary cannot source one, so 1125-92xa duplicates
-- the ALGORITHM in Rust; these arms are why that is safe. The binary is resolved through the
-- shared probe (fixture.plan_binary, 704-zcgi), never a hardcoded target/ path, and asked, not read.
local BIN = fixture.plan_binary()
if BIN == "" then
    -- NOT a pass: an absent binary means this participant was not examined.
    out.line("skip: no tillandsias-plan binary to ask (build it to exercise the Rust participant)")
else
    -- The root as a shell caller spells it ($(pwd), /c/x under msys), as the .sh's
    -- ROOT was and as cycle-metrics.sh's REPO_ROOT is; never the native C:/x form.
    local x = sh([==[
R="$(cd "$R" && pwd)"
say rust "$("$BIN" metrics-log-path forge-expert-usage.jsonl "$R" 2>/dev/null)"
say shell "$(. "$R/scripts/metrics-log-path.sh" 2>/dev/null || true; metrics_default_log forge-expert-usage.jsonl "$R")"
say outside "$("$BIN" metrics-log-path forge-expert-usage.jsonl "/nonexistent-checkout-$$" 2>/dev/null)"
]==], { bin = BIN })
    if (x.rust or "") == "" then
        T:arm("1b the binary answers 'metrics-log-path' (1125-92xa)", false, x.why)
    else
        T:arm("1b the Rust writer and the shell rule resolve the same usage-log path",
            x.rust == x.shell, "rust=" .. tostring(x.rust) .. " shell=" .. tostring(x.shell))
    end

    -- 1c drives the REAL writer end to end from a COPY of the binary inside a scratch checkout:
    -- 1125-92xa anchors on the executable, so the record must land in that scratch checkout and
    -- in neither /tmp nor the host's own log (1209-hkcq: no pollution, no race on a live count).
    -- `capabilities` returns before logging; `capability-matrix` reaches log_cli_usage. The
    -- fixture-wide override is removed HERE and only here, so the arm tests DERIVATION.
    local c = sh([==[
mkdir -p "$W/.git" "$W/target/release"
say tmp_before "$(lines /tmp/forge-expert-usage.jsonl)"; say canon_before "$(lines "$CANON")"
cp "$BIN" "$W/target/release/$(basename "$BIN")" 2>/dev/null
( cd "$W" && env -u TILLANDSIAS_EXPERT_USAGE_LOG "./target/release/$(basename "$BIN")" --index "$R/plan/index.yaml" capability-matrix --hosts >/dev/null 2>&1 || true )
say landed "$(lines "$W/.cache/metrics/forge-expert-usage.jsonl")"
say tmp_after "$(lines /tmp/forge-expert-usage.jsonl)"; say canon_after "$(lines "$CANON")"
]==], { bin = BIN, env = { CANON = shell_usage } })
    if n(c.landed) > 0 then
        T:arm("1c the CLI writer appends inside its OWN checkout, resolved not overridden", true)
    elseif n(c.tmp_after) > n(c.tmp_before) then
        T:arm("1c the CLI writer appends inside its OWN checkout, not /tmp (1125-92xa)", false, c.why)
    elseif n(c.canon_after) > n(c.canon_before) then
        T:arm("1c the CLI writer appends inside its OWN checkout, not the HOST's log", false, c.why)
    else
        -- Nothing grew anywhere: the arm did not observe the writer. Say so, never agree.
        out.line("skip: 1c no usage record was written by any path (telemetry off, or no logging subcommand ran)")
    end
    T:arm("1c' the host's forge-expert-usage.jsonl is unchanged by arm 1c (1209-hkcq)",
        c.canon_after ~= nil and c.canon_after == c.canon_before, c.why)

    -- NEGATIVE CONTROL for the Rust half: outside a checkout it still falls back to /tmp.
    T:arm("1d outside a checkout the Rust writer falls back to /tmp (forge path preserved)",
        x.outside == "/tmp/forge-expert-usage.jsonl", "got " .. tostring(x.outside))
end

-- ── arm 2: inside a checkout the default is repo-relative, not /tmp ───────────
-- The rule may answer either spelling of the root (C:/x or /c/x under Git Bash); both are it.
local PROBE_ROOT = starts(probe, ROOT .. "/") and ROOT or ROOTSH
T:arm("2 in-checkout default is repo-relative (.cache/metrics/)",
    starts(probe, PROBE_ROOT .. "/.cache/metrics/"), "probe=" .. probe .. " root=" .. ROOT .. " | " .. ROOTSH)

-- ── arm 2b: whatever the location, git must ignore it ────────────────────────
local ig = T:run{ "git", "-C", ROOT, "check-ignore", "-q", (probe:sub(#PROBE_ROOT + 2)) }
T:arm("2b the default path is gitignored (machine state, not project content)", ig.code == 0, probe)

-- ── arm 3: NEGATIVE CONTROL — outside a checkout the shell rule still works ───
-- 1455-d7hc: "outside a checkout" means the LIBRARY is outside one (since 1268-m2ir the rule
-- falls back to the checkout its own library lives in), so source a copy from scratch outside
-- any checkout. The scratch root is under this repo's target/, which is a checkout, so the copy
-- goes to the system temp dir and is removed by the same shell.
local x = sh [==[
O="$(mktemp -d "${TMPDIR:-/tmp}/metrics-outside.XXXXXX")"; mkdir -p "$O/scripts"
cp "$R/scripts/metrics-log-path.sh" "$O/scripts/"
say outside "$(cd "$O" && unset PROJECT_ROOT && . "$O/scripts/metrics-log-path.sh" 2>/dev/null; metrics_default_log tillandsias-timing.jsonl "/nonexistent-checkout-$$" 2>/dev/null)"
rm -rf "$O"
]==]
T:arm("3 outside a checkout the shell rule falls back to /tmp (forge path preserved)",
    x.outside == "/tmp/tillandsias-timing.jsonl", x.why)

-- ── arm 4: an explicit env override still wins ───────────────────────────────
x = sh([==[
say override "$(. "$R/scripts/metrics-log-path.sh" 2>/dev/null || true; printf "%s" "${TILLANDSIAS_EXPERT_HEALTH_LOG:-$(metrics_default_log forge-expert-health.jsonl "$R")}")"
]==], { env = { TILLANDSIAS_EXPERT_HEALTH_LOG = "/tmp/explicit-fixture.jsonl" } })
T:arm("4 an explicit TILLANDSIAS_*_LOG still wins over the default",
    x.override == "/tmp/explicit-fixture.jsonl", x.why)

-- ── arms 5, 6: host attribution survives a missing `hostname` binary ─────────
-- The WSL2 build distro is a Fedora container image with no `hostname`; /etc/hostname had the
-- answer. Simulated by shadowing `hostname` with a failing stub. Arm 6 is the negative control:
-- with every source gone the host is still 'unknown', so arm 5 proves something.
local RESOLVE = [==[
_host="${TILLANDSIAS_HOST_ID:-}"
[ -n "$_host" ] || _host="${HOSTNAME:-}"
[ -n "$_host" ] || _host="$(hostname 2>/dev/null || true)"
[ -n "$_host" ] || _host="$(cat "$HF" 2>/dev/null || true)"
_host="$(printf "%s" "$_host" | tr -d "[:space:]")"
[ -n "$_host" ] || _host="unknown"
printf "%s" "$_host"
]==]
x = sh([==[
# A drive path (C:/x) in PATH splits on its colon; under msys give the stub dir its /c/x spelling.
if command -v cygpath >/dev/null 2>&1; then W="$(cygpath -u "$W")"; fi
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 127\n' > "$W/bin/hostname"; chmod +x "$W/bin/hostname"
printf 'fixture-host\n' > "$W/etc-hostname"
cat > "$W/resolve.sh" <<'EOF'
]==] .. RESOLVE .. [==[
EOF
# In-process, not `bash resolve.sh`: a new bash sets HOSTNAME itself, which would hide the stub.
say found "$(PATH="$W/bin:$PATH"; HOSTNAME=''; TILLANDSIAS_HOST_ID=''; HF="$W/etc-hostname"; . "$W/resolve.sh")"
say none "$(PATH="$W/bin:$PATH"; HOSTNAME=''; TILLANDSIAS_HOST_ID=''; HF=/nonexistent/etc/hostname; . "$W/resolve.sh")"
]==])
T:arm("5 host resolves from the file when the hostname BINARY is absent", x.found == "fixture-host", x.why)
T:arm("6 with every source unavailable the host is still 'unknown' (not fabricated)", x.none == "unknown", x.why)

-- ── arm 7: the log must survive `cargo clean` ────────────────────────────────
-- target/ is removed wholesale by daily maintenance. 1807-shtg: judge the path RELATIVE to the
-- checkout, since a worktree under <main>/target/work/<name> has "/target/" in its absolute path.
local rel = probe:sub(#PROBE_ROOT + 2)
T:arm("7 the metrics log is outside target/, so daily-maintenance cargo clean cannot eat it",
    rel ~= "" and not starts(rel, "target/") and not text.contains(rel, "/target/"), rel)

-- ── arms 8, 8b: ORDER 1096-p3tn — an UNRESOLVABLE rule file must REFUSE ──────
-- A copy of cycle-metrics.sh with no metrics-log-path.sh beside it must SAY SO, not pick a path.
-- 8b restores the old best-effort stub in a scratch copy and asserts it silently accepts, so
-- arm 8 has teeth.
x = sh [==[
cp "$R/scripts/cycle-metrics.sh" "$W/cycle-metrics.sh"
say out "$(bash "$W/cycle-metrics.sh" 2>&1 >/dev/null | head -1)"
rc=0; bash "$W/cycle-metrics.sh" >/dev/null 2>&1 || rc=$?; say rc "$rc"
M="$W/pre-1096-cycle-metrics.sh"
awk '/# ORDER 1096-p3tn: A WRITER THAT CANNOT RESOLVE/{skip=1}
     skip && /^# shellcheck source=scripts\/metrics-log-path\.sh$/{skip=0}
     skip{next} {print}' "$R/scripts/cycle-metrics.sh" \
  | awk '/^if ! command -v metrics_default_log/{sub(/^if ! command -v metrics_default_log >\/dev\/null 2>&1; then$/, "command -v metrics_default_log >/dev/null 2>\\&1 || {\n    metrics_default_log() { printf \x27/tmp/%s\x27 \"$1\"; }\n}\nif false; then")} {print}' \
  > "$M"
if grep -q 'refused:metrics:unresolvable-log-path' "$M" && ! grep -q 'if false; then' "$M"; then say mut stripped-nothing
elif ! bash -n "$M" 2>/dev/null; then say mut unparseable
else mrc=0; bash "$M" >/dev/null 2>&1 || mrc=$?; say mut "rc=$mrc"; fi
]==]
T:arm("8 an unsourceable path rule REFUSES with a named cause and a nonzero exit",
    starts(x.out, "refused:metrics:unresolvable-log-path") and n(x.rc) > 0, x.why)
T:arm("8b MUTATION the pre-fix script silently accepts an unresolvable rule (arm 8 has teeth)",
    x.mut == "rc=0", x.why)

-- ── arms 9, 9b, 9c: ORDER 1096-p3tn — a SECOND live timing log must be REFUSED ─
-- The guard fires only on a DEFAULTED path (9b), and only when numbers are PUBLISHED, never on
-- an append (9c). The split needs the REAL /tmp/tillandsias-timing.jsonl, so an existing one is
-- never touched: the arm declines. Each reporter runs as `( ... ) & wait` (2006-wahn) and the
-- shell removes the file on any exit while it holds only this fixture's record.
--
-- ORDER 2402-4avd. THE TRAP IS NOT ENOUGH ON MSYS. A deadline kill of the runner terminates this shell
-- before its trap runs (2392-tv47's finding), and the one-record file it leaves makes every later run
-- skip 9-9c as if a REAL log were there: measured on yolanda, 17 of 21 arms. So a file holding ONLY
-- this fixture's record is ours, and is swept before the arm (a real log, with any other line, is
-- never touched); arm 9z pins that the shell left nothing; and the same sweep runs after it whatever
-- happened, so a failing run cannot poison the next one.
local SWEEP = [==[
F=/tmp/tillandsias-timing.jsonl
if [ -f "$F" ] && ! grep -qv '"host":"fixture"' "$F"; then rm -f "$F" && say swept yes; fi
[ -e "$F" ] && say present yes || say present no
]==]
local pre = sh(SWEEP)
if pre.swept == "yes" then out.line("note: swept a fixture-only /tmp/tillandsias-timing.jsonl an earlier run left behind (2402-4avd)") end
x = sh [==[
F=/tmp/tillandsias-timing.jsonl
if [ -e "$F" ]; then say real yes; exit 0; fi
cleanup() { [ -f "$F" ] || return 0; grep -qv '"host":"fixture"' "$F" && return 0; rm -f "$F"; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
rec='{"ts":"2026-01-01T00:00:00Z","step":"fixture","phase":"f","duration_ms":1,"host":"fixture"}'
printf '%s\n' "$rec" > "$F"
(cd "$R" && bash scripts/cycle-metrics.sh 2>&1 >/dev/null | head -1) > "$W/split.out" &
wait "$!"; say split "$(cat "$W/split.out")"
rc=0; (cd "$R" && bash scripts/cycle-metrics.sh >/dev/null 2>&1) & wait "$!" || rc=$?; say split_rc "$rc"
rc=0; (cd "$R" && TILLANDSIAS_TIMING_LOG="$R/.cache/metrics/tillandsias-timing.jsonl" bash scripts/cycle-metrics.sh >/dev/null 2>&1) & wait "$!" || rc=$?; say named_rc "$rc"
rc=0; (cd "$R" && bash scripts/cycle-metrics.sh --emit-timing step=arm9c phase=f duration_ms=1 >/dev/null 2>&1) & wait "$!" || rc=$?; say emit_rc "$rc"
rc=0; (cd "$R" && bash scripts/cycle-metrics.sh >/dev/null 2>&1) & wait "$!" || rc=$?; say rep_rc "$rc"
]==]
if x.real == "yes" then
    out.line("skip: 9-9c a real /tmp/tillandsias-timing.jsonl exists; declining rather than overwrite it")
else
    T:arm("9 two live timing logs are refused, not silently halved",
        starts(x.split, "violation:metrics-log-split:") and n(x.split_rc) > 0, x.why)
    T:arm("9b CONTROL an explicitly named timing log is read without complaint, split or no split",
        x.named_rc == "0", x.why)
    T:arm("9c CONTROL --emit-* is unaffected by a split", x.emit_rc == "0", x.why)
    T:arm("9c' CONTROL the REPORTING path still refuses the same split", n(x.rep_rc) > 0, x.why)
    local post = sh(SWEEP)
    T:arm("9z the run leaves no default-path /tmp/tillandsias-timing.jsonl behind (2402-4avd)",
        post.swept ~= "yes" and post.present == "no", "swept=" .. tostring(post.swept) .. " present=" .. tostring(post.present))
end

-- ── arm W: a LINKED WORKTREE is a checkout on both sides (1455-d7hc) ─────────
-- A linked worktree's .git is a FILE; the Rust writer used is_dir and fell back to /tmp. Built
-- in a SCRATCH repo so the real checkout's worktree list is never touched.
if BIN == "" then
    out.line("skip: W linked-worktree arm: no runnable plan binary")
else
    x = sh([==[
git -C "$W" init -q main 2>/dev/null
git -C "$W/main" -c user.email=f@x -c user.name=f -c commit.gpgsign=false commit -q --allow-empty -m init 2>/dev/null
git -C "$W/main" worktree add -q --detach "$W/linked" 2>/dev/null
L="$(cd "$W/linked" 2>/dev/null && pwd)"
[ -f "$W/linked/.git" ] && say file yes
say want "$L/.cache/metrics/wt-probe.jsonl"
say rust "$("$BIN" metrics-log-path wt-probe.jsonl "$L" 2>/dev/null)"
say shell "$(unset PROJECT_ROOT; . "$R/scripts/metrics-log-path.sh" 2>/dev/null; metrics_default_log wt-probe.jsonl "$L" 2>/dev/null)"
]==], { bin = BIN })
    T:arm("W0 PREMISE the scratch linked worktree has a .git FILE", x.file == "yes", x.why)
    T:arm("W in a linked worktree the Rust writer and the shell reader agree on the worktree",
        x.rust ~= nil and x.rust == x.shell and x.rust == x.want, x.why)
end

T:finish()
