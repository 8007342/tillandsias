#!/usr/bin/env bash
# Fixture for order 915-wkm2 — the scratchpad quota-headroom check.
#
# THE PROPERTY: report what you can actually USE, and never report a filesystem
# number as a quota headroom. `df` sees the tmpfs size (systemd default: 50% of
# RAM); the usrquota can sit far below it, so writes fail while df looks fine.
#
# THE THRESHOLD IS ABSOLUTE, NOT A PERCENTAGE, and arm 3 is why. Measured
# 2026-08-26: macuahuitl's quota is 25564 MB, lenovinha's is 5525 MB — a 4.6x
# spread. A percentage tuned to one is wrong on the other. The bar is instead
# what the work costs: one cold Rust target/ at 2.6-4.4 GB.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
GUARD="$PWD/scripts/check-scratchpad-headroom.sh"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/scratch-headroom.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# stub_env <used> <limit> <df_avail_mb> [no-quota-tool|no-quota-rows]
stub_env() {
    local used="$1" limit="$2" dfm="$3" mode="${4:-normal}"
    local bin="$W/bin-$RANDOM$RANDOM"; mkdir -p "$bin"
    if [ "$mode" != "no-quota-tool" ]; then
        cat >"$bin/quota" <<QEOF
#!/usr/bin/env bash
echo "Disk quotas for user test (uid 1000): "
echo "     Filesystem   space   quota   limit   grace   files   quota   limit   grace"
QEOF
        [ "$mode" = "no-quota-rows" ] || \
          printf '%s\n' "echo '          tmpfs   $used   $limit   $limit           100       0       0'" >>"$bin/quota"
        chmod +x "$bin/quota"
    fi
    cat >"$bin/df" <<DEOF
#!/usr/bin/env bash
echo "Filesystem 1M-blocks Used Available Use% Mounted on"
echo "tmpfs 99999 0 $dfm 1% /tmp"
DEOF
    chmod +x "$bin/df"
    printf '%s' "$bin"
}

run() { PATH="$1:$PATH" TILLANDSIAS_SCRATCHPAD_DIR="$W" bash "$GUARD" 2>"$W/err"; }

# A PATH that genuinely lacks `quota`. PREPENDING a bin dir cannot hide a system
# binary — my first version omitted the quota stub and the real /usr/bin/quota
# was found anyway, so the "no quota tooling" arms silently tested the WITH-quota
# path. Same trap as masking jq. Build a curated mirror and assert the absence.
_curated="$W/nq"; mkdir -p "$_curated"
for _t in bash sh awk sed grep cat head tail cut tr printf echo test dirname basename mktemp rm mkdir; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$_curated/$_t" 2>/dev/null || true
done
if PATH="$_curated" command -v quota >/dev/null 2>&1; then
    bad "PRECONDITION: quota still reachable on the curated PATH — the no-quota arms would test nothing"
fi
run_noquota() { PATH="$1:$_curated" TILLANDSIAS_SCRATCHPAD_DIR="$W" bash "$GUARD" 2>"$W/err"; }

# ── 1. Ample quota -> ok, and the numbers are the QUOTA's, not df's. ────────
B="$(stub_env 1000M 25564M 99999)"
out="$(run "$B")"
case "$out" in
    ok:scratchpad-headroom:24564m-of-25564m) ok "ample quota -> ok with quota-derived numbers" ;;
    *) bad "ample case returned: $out" ;;
esac

# ── 2. Tight quota -> warn, AND it must say df overstates. ─────────────────
# This is the live lenovinha shape: 3905M usable, df claiming 5286M.
B="$(stub_env 1620M 5525M 5286)"
out="$(run "$B")"
case "$out" in
    warn:scratchpad-headroom-low:3905m-of-5525m) ok "tight quota -> warn with real headroom (3905m)" ;;
    *) bad "tight case returned: $out" ;;
esac
grep -q 'OVERSTATES' "$W/err" \
    && ok "names df as OVERSTATING what can be used" \
    || bad "must say df overstates — that gap is the trap"

# ── 3. THE 4.6x SPREAD: one absolute threshold, both hosts classified right. ─
# A percentage would get one of these wrong. lenovinha is at 71% used and CANNOT
# build; macuahuitl at 62% used CAN. Percentages say the opposite of the truth.
B="$(stub_env 1620M 5525M 5286)";   len="$(run "$B")"
B="$(stub_env 15900M 25564M 20000)"; mac="$(run "$B")"
case "$len:$mac" in
    warn:*:ok:*) ok "one absolute threshold classifies BOTH hosts correctly across a 4.6x spread" ;;
    *) bad "spread case: lenovinha=$len macuahuitl=$mac" ;;
esac
# Make the percentage trap explicit, and state it the RIGHT way round — my first
# version asserted the warned host was FULLER by percent. It is the opposite, and
# that is precisely what makes a percentage rule dangerous: lenovinha is only 29%
# used and CANNOT build; macuahuitl is 62% used and CAN. Any "warn above N%" rule
# passes the host that will wedge and warns the one that will not.
_lp=$(( 1620 * 100 / 5525 )); _mp=$(( 15900 * 100 / 25564 ))
[ "$_lp" -lt "$_mp" ] \
    && ok "the WARNED host is emptier by percentage (${_lp}% vs ${_mp}%) — a % rule would invert both verdicts" \
    || bad "the spread arm no longer demonstrates the percentage trap"

# ── 4. NEGATIVE CONTROL: quota-exhausted and disk-full are DIFFERENT verdicts. ─
# The amended criteria call for this explicitly: the two have different remedies
# and only one of them is what happened on macuahuitl.
B="$(stub_env 5400M 5525M 99999)"; quota_case="$(run "$B")"
B="$(stub_env 0 0 200 no-quota-tool)"; disk_case="$(run_noquota "$B")"
[ "${quota_case%%:*}" = "warn" ] && [ "${disk_case%%:*}" = "warn" ] \
    && [ "$quota_case" != "$disk_case" ] \
    && ok "quota-exhausted and disk-full are distinct verdicts ($quota_case vs $disk_case)" \
    || bad "must distinguish the two: quota=$quota_case disk=$disk_case"
case "$disk_case" in
    warn:scratchpad-disk-low:*) ok "the no-quota-tool path names it DISK, not quota" ;;
    *) bad "disk path returned: $disk_case" ;;
esac
grep -qi 'not a quota headroom' "$W/err" \
    && ok "says outright it is filesystem free space, not a quota headroom" \
    || bad "must not present a df number as a quota headroom"

# ── 5. No quota configured -> skip, not a false alarm. ─────────────────────
B="$(stub_env 0 0 99999 no-quota-rows)"
out="$(run "$B")"
[ "$out" = "skip:no-quota" ] && ok "no quota configured -> skip:no-quota" \
    || bad "no-quota case returned: $out"

# ── 6. ADVISORY, NEVER A GATE — every path exits 0. ───────────────────────
# A cycle must not fail because a host is low on scratch; it must be TOLD while
# it can still choose where to build. Red-lighting on a capacity condition is
# the 888-miiy shape.
for spec in "1000M 25564M 99999" "1620M 5525M 5286" "5400M 5525M 99999"; do
    # shellcheck disable=SC2086
    B="$(stub_env $spec)"; PATH="$B:$PATH" TILLANDSIAS_SCRATCHPAD_DIR="$W" bash "$GUARD" >/dev/null 2>&1
    [ $? -eq 0 ] || bad "a headroom verdict exited non-zero — this must never gate"
done
ok "every verdict exits 0 (advisory, never a gate)"

# ── 7. Grammar: one line, pinned. ─────────────────────────────────────────
g='^(ok:scratchpad-headroom:[0-9]+m-of-[0-9]+m|warn:scratchpad-headroom-low:[0-9]+m-of-[0-9]+m|warn:scratchpad-disk-low:[0-9]+m|skip:(no-quota|no-scratchpad|no-quota-tool))$'
for v in "$len" "$mac" "$quota_case" "$disk_case" "$out"; do
    printf '%s\n' "$v" | grep -qE "$g" || bad "verdict escaped the pinned grammar: $v"
done
ok "every verdict matches the pinned grammar"

if [ "$fail" -eq 0 ]; then
    echo "ok:scratchpad-headroom-fixture:all"
    exit 0
fi
echo "fail:scratchpad-headroom-fixture"
exit 1
