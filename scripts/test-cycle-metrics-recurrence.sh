#!/usr/bin/env bash
# freshness: added 2026-09-04 linux-macuahuitl (order 1001-q3zf)
# @trace spec:methodology-accountability
# @trace order:1001-q3zf
#
# The repeat:/recur:/skippable: lines of scripts/cycle-metrics.sh, driven
# against synthetic timing logs with KNOWN sums. Every scenario asserts exact
# arithmetic, not "a line appeared": a reporter that printed the grammar with
# wrong numbers would be the eight-instruments-in-one-day defect
# (agent-observability.yaml, proxy_discipline) with a ninth instrument.
#
# Scenarios:
#   (a) exact arithmetic on all three lines, including a step name that
#       itself contains colons, parsed FROM THE RIGHT (step is everything
#       before the first `:runs=`; the trailing :key=value fields never carry
#       a colon)
#   (b) skippable excludes a mixed-outcome step (fail_pct strictly between 0
#       and 100), includes an always-failing one, and excludes a step whose
#       ONE failure rounds to fail_pct=0 (invariance is decided on raw counts)
#   (c) floor and min_runs boundaries: avg exactly AT the floor is in, runs
#       one BELOW min_runs is out, avg one below the floor is out
#   (d) repeat honours --cycle-start (and the env fallback) and the 3h default
#   (e) recur excludes a record older than the 7-day window, and widens with
#       --recur-window-days
#   (f) missing log => source=absent, zeros, top3=- on all three lines, exit 0
#   (g) a malformed row and a row with ts=unknown are dropped; exit 0
#   (h) --experts-only prints none of the three lines
#   (i) a step name that DECODES to a newline, a tab, a space or a comma is
#       sanitised to `_` in the reported key, so the three lines keep their
#       own labels (adversarial review 2026-09-04: a newline in a step shifted
#       the jq output and recur: carried repeat data); --emit-timing strips
#       `"` and `\` so it cannot write such a row in the first place
#   (j) --cycle-start: an unparseable value reads since=<value>:unparsed with
#       steps=0 instead of silently widening to 3h; fractional seconds are
#       accepted; a trailing --cycle-start with no value is the env fallback
#   (k) a directory where the log should be reads source=absent, not zeros
#       with a path
#   (l) a non-integer duration_ms is summed and the total floored to an
#       integer, so total_ms keeps the integer grammar
#
# Timestamps are minted RELATIVE TO NOW with jq (`now - <s> | todate`), never
# with date(1): no GNU `date -d` exists on macOS bash 3.2 or Git Bash, and the
# reporter itself windows with jq for the same reason.
#
# ISOLATION. The usage and flow logs are pointed at empty temp files so the
# other blocks stay inert, the window knobs are pinned to their defaults so a
# host that exports TILLANDSIAS_RECUR_WINDOW_DAYS cannot skew the sums, and
# TILLANDSIAS_PLAN_BIN is pointed at a non-existent path so the reporter does
# not spend ~11 s per call grading groundtruth (the lines under test do not
# read the plan binary). The last line is a pinned token consumed by the
# litmus spec; the count suffix is the number of checks.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/cycle-metrics-recur.XXXXXX")"; trap 'rm -rf "$W"' EXIT
JQ="${JQ:-jq}"
command -v "$JQ" >/dev/null 2>&1 || { echo "fail: jq is required by this fixture"; exit 1; }

: > "$W/usage.jsonl"; : > "$W/flow.jsonl"
export TILLANDSIAS_EXPERT_USAGE_LOG="$W/usage.jsonl"
export TILLANDSIAS_CYCLE_FLOW_LOG="$W/flow.jsonl"
export TILLANDSIAS_PLAN_BIN=/nonexistent/tillandsias-plan
export TILLANDSIAS_CYCLE_START_TS=""
export TILLANDSIAS_RECUR_WINDOW_DAYS=7
export TILLANDSIAS_SKIP_MIN_RUNS=5
export TILLANDSIAS_SKIP_FLOOR_MS=2000

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok: $1"; }
bad()  { fail=$((fail+1)); echo "fail: $1"; }
# check <label> <observed> <expected-exact>
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$3] got [${2:-<nothing>}]"; fi; }

# ago <seconds> -> UTC ISO-8601 that many seconds before now (jq clock).
ago() { "$JQ" -n -r --arg s "$1" 'now - ($s | tonumber) | todate'; }
# row <log> <ts> <step> <duration_ms> <exit>
row() { printf '{"ts":"%s","host":"h","step":"%s","phase":"p","duration_ms":%s,"exit":%s}\n' "$2" "$3" "$4" "$5" >> "$1"; }
# rows <log> <n> <ts> <step> <duration_ms> <exit>
rows() { _i=0; while [ "$_i" -lt "$2" ]; do row "$1" "$3" "$4" "$5" "$6"; _i=$((_i+1)); done; }
# report <log> [args...] -> full report on stdout (stderr discarded)
report() { _log="$1"; shift; TILLANDSIAS_TIMING_LOG="$_log" bash "$ROOT/scripts/cycle-metrics.sh" "$@" 2>/dev/null; }
line() { grep "^$1:" | head -1; }

# ── (a) exact arithmetic, colon-bearing step name ───────────────────────────
A="$W/a.jsonl"; : > "$A"; T=$(ago 60)
row  "$A"   "$T" "step:gate:archiver" 3000 0
row  "$A"   "$T" "step:gate:archiver" 5000 0
rows "$A" 3 "$T" "step:gate:archiver" 4000 0        # 5 runs, total 20000, avg 4000, never fails
row  "$A"   "$T" "build-check" 7000 0
row  "$A"   "$T" "build-check" 9000 1               # 2 runs, total 16000, avg 8000, fail_pct 50
row  "$A"   "$T" "quick" 100 0                      # 1 run: not recurring
rows "$A" 6 "$T" "litmus-suite" 2500 1              # 6 runs, total 15000, avg 2500, ALWAYS fails
out="$(report "$A")"; rc=$?
check "(a) reporter exit 0" "$rc" "0"
check "(a) repeat: counts inside the 3h window, top3 by count desc then name asc" \
  "$(printf '%s\n' "$out" | line repeat)" \
  "repeat: window=3h steps=4 top3=litmus-suite=6,step:gate:archiver=5,build-check=2 source=$A"
check "(a) recur: runs>=2 only, top3 by total_ms desc, exact totals/avg/fail_pct" \
  "$(printf '%s\n' "$out" | line recur)" \
  "recur: window=7d runs=14 steps=3 top3=step:gate:archiver:runs=5:total_ms=20000:avg_ms=4000:fail_pct=0,build-check:runs=2:total_ms=16000:avg_ms=8000:fail_pct=50,litmus-suite:runs=6:total_ms=15000:avg_ms=2500:fail_pct=100 source=$A"
check "(a) skippable: invariant + expensive + repeated, saved_ms_upper = total - avg" \
  "$(printf '%s\n' "$out" | line skippable)" \
  "skippable: candidates=2 floor_ms=2000 min_runs=5 top3=step:gate:archiver:runs=5:avg_ms=4000:fail_pct=0:saved_ms_upper=16000,litmus-suite:runs=6:avg_ms=2500:fail_pct=100:saved_ms_upper=12500 source=$A"
# Parse-from-the-right on the first skippable entry: the step keeps its colons.
entry="$(printf '%s\n' "$out" | line skippable | sed 's/^skippable: .*top3=//; s/ source=.*$//' | cut -d, -f1)"
check "(a) parse rule: step is everything before the first :runs=" "${entry%%:runs=*}" "step:gate:archiver"
check "(a) parse rule: trailing field read from the right" "${entry##*:saved_ms_upper=}" "16000"
check "(a) parse rule: middle field read from the right" "$(printf '%s' "${entry##*:avg_ms=}" | cut -d: -f1)" "4000"

# ── (b) outcome invariance decides skippable ────────────────────────────────
B="$W/b.jsonl"; : > "$B"
rows "$B" 5 "$T" "mixed" 3000 0;  row "$B" "$T" "mixed" 3000 1     # 1/6 fails: 17%, excluded
rows "$B" 6 "$T" "alwaysfail" 3000 1                                # 100%: included
rows "$B" 249 "$T" "nearly" 3000 0; row "$B" "$T" "nearly" 3000 1   # 1/250 rounds to 0%: still excluded
out="$(report "$B" | line skippable)"
check "(b) mixed excluded, always-failing included, 1-in-250 not rounded into invariance" "$out" \
  "skippable: candidates=1 floor_ms=2000 min_runs=5 top3=alwaysfail:runs=6:avg_ms=3000:fail_pct=100:saved_ms_upper=15000 source=$B"
case "$(report "$B" | line recur)" in
    *"nearly:runs=250:total_ms=750000:avg_ms=3000:fail_pct=0"*) ok "(b) recur still reports the near-invariant step with its rounded fail_pct=0" ;;
    *) bad "(b) recur should carry nearly:runs=250:total_ms=750000:avg_ms=3000:fail_pct=0" ;;
esac

# ── (c) floor and min_runs boundaries ───────────────────────────────────────
C="$W/c.jsonl"; : > "$C"
rows "$C" 5 "$T" "atfloor" 2000 0       # avg == floor: in
rows "$C" 4 "$T" "belowmin" 5000 0      # runs == min_runs-1: out
rows "$C" 5 "$T" "belowfloor" 1999 0    # avg == floor-1: out
out="$(report "$C" | line skippable)"
check "(c) avg exactly at floor_ms is a candidate; one run short or one ms short is not" "$out" \
  "skippable: candidates=1 floor_ms=2000 min_runs=5 top3=atfloor:runs=5:avg_ms=2000:fail_pct=0:saved_ms_upper=8000 source=$C"
out="$(TILLANDSIAS_SKIP_MIN_RUNS=4 TILLANDSIAS_SKIP_FLOOR_MS=1999 report "$C" | line skippable)"
check "(c) env knobs move both boundaries and are echoed on the line" "$out" \
  "skippable: candidates=3 floor_ms=1999 min_runs=4 top3=belowmin:runs=4:avg_ms=5000:fail_pct=0:saved_ms_upper=15000,atfloor:runs=5:avg_ms=2000:fail_pct=0:saved_ms_upper=8000,belowfloor:runs=5:avg_ms=1999:fail_pct=0:saved_ms_upper=7996 source=$C"

# ── (d) repeat window: --cycle-start vs the 3h default ──────────────────────
D="$W/d.jsonl"; : > "$D"
rows "$D" 2 "$(ago 30)" "a" 10 0
row  "$D"   "$(ago 7200)" "a" 10 0       # 2h ago: inside 3h, outside a 1h-old cycle start
row  "$D"   "$(ago 9000)" "b" 10 0       # 2.5h ago: inside 3h
row  "$D"   "$(ago 18000)" "c" 10 0      # 5h ago: outside both
CS="$(ago 3600)"
check "(d) default window is 3h" "$(report "$D" | line repeat)" \
  "repeat: window=3h steps=2 top3=a=3,b=1 source=$D"
check "(d) --cycle-start excludes records older than the start" "$(report "$D" --cycle-start "$CS" | line repeat)" \
  "repeat: window=since=$CS steps=1 top3=a=2 source=$D"
check "(d) TILLANDSIAS_CYCLE_START_TS is the env fallback" "$(TILLANDSIAS_CYCLE_START_TS="$CS" report "$D" | line repeat)" \
  "repeat: window=since=$CS steps=1 top3=a=2 source=$D"
check "(d) --cycle-start does not leak into the since-ref (commits stays -)" \
  "$(report "$D" --cycle-start "$CS" | line repo | grep -c 'commits_this_cycle=- ')" "1"

# ── (e) recur window: 7 days by default, widened by --recur-window-days ─────
E="$W/e.jsonl"; : > "$E"
rows "$E" 2 "$(ago 691200)" "old" 4000 0    # 8 days ago
rows "$E" 2 "$(ago 86400)"  "new" 3000 0    # 1 day ago
check "(e) a record older than 7 days is outside recur" "$(report "$E" | line recur)" \
  "recur: window=7d runs=2 steps=1 top3=new:runs=2:total_ms=6000:avg_ms=3000:fail_pct=0 source=$E"
check "(e) --recur-window-days widens the window and is echoed" "$(report "$E" --recur-window-days 10 | line recur)" \
  "recur: window=10d runs=4 steps=2 top3=old:runs=2:total_ms=8000:avg_ms=4000:fail_pct=0,new:runs=2:total_ms=6000:avg_ms=3000:fail_pct=0 source=$E"

# ── (f) missing log ─────────────────────────────────────────────────────────
out="$(report "$W/does-not-exist.jsonl")"; rc=$?
check "(f) missing log: exit 0" "$rc" "0"
check "(f) missing log: repeat absent" "$(printf '%s\n' "$out" | line repeat)" "repeat: window=3h steps=0 top3=- source=absent"
check "(f) missing log: recur absent" "$(printf '%s\n' "$out" | line recur)" "recur: window=7d runs=0 steps=0 top3=- source=absent"
check "(f) missing log: skippable absent" "$(printf '%s\n' "$out" | line skippable)" "skippable: candidates=0 floor_ms=2000 min_runs=5 top3=- source=absent"

# ── (g) malformed and unplaceable rows are dropped, never fatal ─────────────
G="$W/g.jsonl"; : > "$G"
row "$G" "$T" "x" 100 0
printf 'this is not json\n' >> "$G"
printf '{"ts":"unknown","host":"h","step":"x","phase":"p","duration_ms":100,"exit":0}\n' >> "$G"
row "$G" "$T" "x" 300 0
out="$(report "$G")"; rc=$?
check "(g) malformed row: exit 0" "$rc" "0"
check "(g) malformed and ts=unknown rows dropped; the two placeable rows are summed" \
  "$(printf '%s\n' "$out" | line recur)" \
  "recur: window=7d runs=2 steps=1 top3=x:runs=2:total_ms=400:avg_ms=200:fail_pct=0 source=$G"

# ── (h) --experts-only prints none of the three lines ───────────────────────
n="$(report "$A" --experts-only | grep -cE '^(repeat|recur|skippable):')"
check "(h) --experts-only carries no repeat:/recur:/skippable: line" "$n" "0"

# ── (i) step-name sanitisation: control bytes, whitespace, commas ───────────
I="$W/i.jsonl"; : > "$I"
rows "$I" 5 "$T" 'line\nbreak' 3000 0          # JSON \n: decodes to a newline
rows "$I" 5 "$T" 'tab\there' 3000 0            # JSON \t: decodes to a tab
rows "$I" 5 "$T" 'sp ace' 3000 0
rows "$I" 5 "$T" 'com,ma' 3000 0
out="$(report "$I")"; rc=$?
check "(i) reporter exit 0 with control bytes in step names" "$rc" "0"
check "(i) exactly one line per label survives a newline-bearing step" \
  "$(printf '%s\n' "$out" | grep -cE '^(repeat|recur|skippable): ')" "3"
check "(i) repeat: keys sanitised to _ (count desc, then sanitised name asc)" \
  "$(printf '%s\n' "$out" | line repeat)" \
  "repeat: window=3h steps=4 top3=com_ma=5,line_break=5,sp_ace=5 source=$I"
check "(i) recur: label carries recur data, not the tail of repeat" \
  "$(printf '%s\n' "$out" | line recur)" \
  "recur: window=7d runs=20 steps=4 top3=com_ma:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0,line_break:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0,sp_ace:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0 source=$I"
check "(i) skippable: line is present and its own" \
  "$(printf '%s\n' "$out" | line skippable)" \
  "skippable: candidates=4 floor_ms=2000 min_runs=5 top3=com_ma:runs=5:avg_ms=3000:fail_pct=0:saved_ms_upper=12000,line_break:runs=5:avg_ms=3000:fail_pct=0:saved_ms_upper=12000,sp_ace:runs=5:avg_ms=3000:fail_pct=0:saved_ms_upper=12000 source=$I"
I2="$W/i2.jsonl"; : > "$I2"
TILLANDSIAS_TIMING_LOG="$I2" bash "$ROOT/scripts/cycle-metrics.sh" --emit-timing 'step=q"u\o\te' phase='p"h' duration_ms=3000 exit=0 host='h\x' 2>/dev/null
check "(i) --emit-timing strips quote and backslash from step/phase/host" \
  "$("$JQ" -r '[.step, .phase, .host] | join("/")' "$I2" 2>/dev/null)" "quote/ph/hx"

# ── (j) --cycle-start error surfaces ────────────────────────────────────────
check "(j) an unparseable --cycle-start is labelled, with zero steps, never widened to 3h" \
  "$(report "$D" --cycle-start garbage | line repeat)" \
  "repeat: window=since=garbage:unparsed steps=0 top3=- source=$D"
check "(j) a --cycle-start without the trailing Z is unparsed too" \
  "$(report "$D" --cycle-start "${CS%Z}" | line repeat)" \
  "repeat: window=since=${CS%Z}:unparsed steps=0 top3=- source=$D"
check "(j) fractional seconds on --cycle-start parse like they do on records" \
  "$(report "$D" --cycle-start "${CS%Z}.000Z" | line repeat)" \
  "repeat: window=since=${CS%Z}.000Z steps=1 top3=a=2 source=$D"
check "(j) a trailing --cycle-start with no value is the env fallback (3h here), not the flag text" \
  "$(report "$D" --cycle-start | line repeat)" \
  "repeat: window=3h steps=2 top3=a=3,b=1 source=$D"

# ── (k) a directory is not a readable log ───────────────────────────────────
mkdir -p "$W/dir.jsonl"
out="$(report "$W/dir.jsonl")"; rc=$?
check "(k) directory as log: exit 0" "$rc" "0"
check "(k) directory as log: recur reads source=absent, not zeros with a path" \
  "$(printf '%s\n' "$out" | line recur)" "recur: window=7d runs=0 steps=0 top3=- source=absent"

# ── (l) non-integer duration keeps the integer grammar ──────────────────────
L="$W/l.jsonl"; : > "$L"
rows "$L" 4 "$T" "frac" 3000 0; row "$L" "$T" "frac" 3000.7 0     # 15000.7 -> 15000
check "(l) total_ms is floored to an integer; avg unaffected" \
  "$(report "$L" | line recur)" \
  "recur: window=7d runs=5 steps=1 top3=frac:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0 source=$L"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:cycle-metrics-recurrence-fixture:${total}"; exit 0; fi
echo "fail: cycle-metrics-recurrence ${fail}/${total} red (1001-q3zf)"; exit 1
