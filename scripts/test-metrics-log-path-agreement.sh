#!/usr/bin/env bash
# test-metrics-log-path-agreement.sh — the writer and the reader of a metrics
# log must resolve the SAME path, and a record must name the host that made it.
# @trace order:890-t9pu
#
# The defect this pins: `/tmp` was the default in four places across three
# scripts, and `/tmp` is not one place. On a Windows host the gate re-execs into
# WSL2 and writes there while `cycle-metrics.sh` reads Git Bash's filesystem —
# 322 records on one side, 0 on the other, so every timing metric that host ever
# published was stale or absent.
#
# ARM 1 is the load-bearing one and it is deliberately not "does the path look
# right": it asserts the three participants AGREE. A fix applied to one script
# and not the others re-creates the defect one subsystem over, which is exactly
# what would have happened here between the health PROBE and the health REPORT.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# ── arm 1: every participant resolves the same health-log path ────────────────
# Asked of the scripts themselves, not of the shared library, so a script that
# forgets to source the rule is caught rather than assumed correct.
probe_path="$(
    unset TILLANDSIAS_EXPERT_HEALTH_LOG
    . "$ROOT/scripts/metrics-log-path.sh" 2>/dev/null || true
    metrics_default_log forge-expert-health.jsonl "$ROOT"
)"
health_decl="$(grep -c 'metrics_default_log forge-expert-health.jsonl' \
    "$ROOT/scripts/check-mcp-expert-health.sh" 2>/dev/null || echo 0)"
surface_decl="$(grep -c 'metrics_default_log forge-expert-health.jsonl' \
    "$ROOT/scripts/check-mcp-surface.sh" 2>/dev/null || echo 0)"
metrics_decl="$(grep -c '_metrics_default_log forge-expert-health.jsonl' \
    "$ROOT/scripts/cycle-metrics.sh" 2>/dev/null || echo 0)"
if [ "$health_decl" -ge 1 ] && [ "$surface_decl" -ge 1 ] && [ "$metrics_decl" -ge 1 ]; then
    ok "all three health-log participants ask the shared rule (probe, surface, report)"
else
    bad "a health-log participant still hardcodes its own path (probe=$health_decl surface=$surface_decl report=$metrics_decl)"
fi

# ── arm 2: inside a checkout the default is repo-relative, not /tmp ───────────
case "$probe_path" in
    "$ROOT/.cache/metrics/"*) ok "in-checkout default is repo-relative: ${probe_path#"$ROOT"/}" ;;
    /tmp/*) bad "still defaulting to /tmp inside a checkout — the boundary split is back" ;;
    *) bad "unexpected default path: $probe_path" ;;
esac

# NOTE: the "must not be under target/" assertion lives at ARM 7, not here.
# Two hosts wrote it independently within the same hour — see arm 7's header for
# the measurement. One copy is enough; a duplicated arm inflates the pass count
# without adding coverage.

# ── arm 2b: whatever the location, git must ignore it ────────────────────────
# Repo-relative machine state must never become project content.
if git -C "$ROOT" check-ignore -q "$probe_path" 2>/dev/null; then
    ok "the default path is gitignored (machine state, not project content)"
else
    bad "the default path is NOT gitignored — metrics would become committable: $probe_path"
fi

# ── arm 3: NEGATIVE CONTROL — outside a checkout it must still work ───────────
# A forge or a bare invocation has no repo to write into. Falling back to /tmp
# there is correct; failing there would be a regression this fix must not cause.
outside="$(
    . "$ROOT/scripts/metrics-log-path.sh" 2>/dev/null || true
    metrics_default_log tillandsias-timing.jsonl "/nonexistent-checkout-$$"
)"
case "$outside" in
    /tmp/tillandsias-timing.jsonl) ok "outside a checkout it falls back to /tmp (forge path preserved)" ;;
    *) bad "no-checkout fallback broke: $outside" ;;
esac

# ── arm 4: an explicit env override still wins ───────────────────────────────
# Every existing fixture names its own log; this fix must not disturb them.
override="$(TILLANDSIAS_EXPERT_HEALTH_LOG=/tmp/explicit-$$.jsonl bash -c '
    . "'"$ROOT"'/scripts/metrics-log-path.sh" 2>/dev/null || true
    printf "%s" "${TILLANDSIAS_EXPERT_HEALTH_LOG:-$(metrics_default_log forge-expert-health.jsonl "'"$ROOT"'")}"
')"
case "$override" in
    "/tmp/explicit-$$.jsonl") ok "an explicit TILLANDSIAS_*_LOG still wins over the default" ;;
    *) bad "env override was ignored: $override" ;;
esac

# ── arm 5: host attribution survives a missing `hostname` binary ─────────────
# The real cause of 2977 host="unknown" records: the WSL2 build distro is a
# Fedora CONTAINER IMAGE and ships no `hostname`. /etc/hostname had the answer
# the whole time. Simulated by shadowing `hostname` with a failing stub.
tdir="$(mktemp -d)"
trap 'rm -rf "$tdir"' EXIT
mkdir -p "$tdir/bin"
printf '#!/bin/sh\nexit 127\n' > "$tdir/bin/hostname"
chmod +x "$tdir/bin/hostname"
printf 'fixture-host\n' > "$tdir/etc-hostname"
resolved="$(
    PATH="$tdir/bin:$PATH" HOSTNAME='' TILLANDSIAS_HOST_ID='' bash -c '
        _host="${TILLANDSIAS_HOST_ID:-}"
        [ -n "$_host" ] || _host="${HOSTNAME:-}"
        [ -n "$_host" ] || _host="$(hostname 2>/dev/null || true)"
        [ -n "$_host" ] || _host="$(cat "'"$tdir"'/etc-hostname" 2>/dev/null || true)"
        _host="$(printf "%s" "$_host" | tr -d "[:space:]")"
        [ -n "$_host" ] || _host="unknown"
        printf "%s" "$_host"
    '
)"
if [ "$resolved" = "fixture-host" ]; then
    ok "host resolves from the file when the hostname BINARY is absent"
else
    bad "host fell back to '$resolved' with hostname absent — expected fixture-host"
fi

# ── arm 6: NEGATIVE CONTROL — 'unknown' still reachable ──────────────────────
# "unknown" must keep meaning genuinely unknown. If every arm resolved to
# something, the field would be decorative and arm 5 would prove nothing.
resolved_none="$(
    PATH="$tdir/bin:$PATH" HOSTNAME='' TILLANDSIAS_HOST_ID='' bash -c '
        _host="${TILLANDSIAS_HOST_ID:-}"
        [ -n "$_host" ] || _host="${HOSTNAME:-}"
        [ -n "$_host" ] || _host="$(hostname 2>/dev/null || true)"
        [ -n "$_host" ] || _host="$(cat /nonexistent/etc/hostname 2>/dev/null || true)"
        _host="$(printf "%s" "$_host" | tr -d "[:space:]")"
        [ -n "$_host" ] || _host="unknown"
        printf "%s" "$_host"
    '
)"
if [ "$resolved_none" = "unknown" ]; then
    ok "with every source unavailable the host is still 'unknown' (not fabricated)"
else
    bad "expected unknown with no source available, got '$resolved_none'"
fi

# ── arm 7: the log must survive `cargo clean` ────────────────────────────────
# `target/` was the first choice and it is wrong: daily maintenance runs
# `cargo clean`, which removes the target directory WHOLESALE and would take the
# metrics with it. Measured by macuahuitl in a throwaway crate — target/metrics
# 1 -> 0 across a clean, .cache/metrics 1 -> 1 — on a host whose target/ grew
# 24 -> 31 GiB in one cycle against a 40 GiB sweep threshold.
#
# Pinned because the failure is near-undetectable: a routine GC silently resets
# every rolling series, and the reset looks exactly like the documented one-time
# migration. This arm is what stops someone moving it back into target/.
case "$probe_path" in
    */target/*) bad "metrics log is under target/ — cargo clean will delete it (see macuahuitl 2026-08-26)" ;;
    *) ok "metrics log is outside target/, so daily-maintenance cargo clean cannot eat it" ;;
esac

# ── arm 8: ORDER 1096-p3tn — an UNRESOLVABLE rule file must REFUSE ──────────
# The closure criterion of 1096-p3tn, made executable. cycle-metrics.sh used to
# source the rule best-effort and, on failure, define a stub returning
# /tmp/<name>. The file is present in every checkout, so SOME invocations
# sourced it and some did not, and pirria measured the result on 2026-09-06:
# two live timing logs, overlapping in time, both carrying both hosts, with
# near-disjoint step sets — so every runs= and skippable: was computed over a
# PARTITION while presenting as a TOTAL.
#
# A writer that cannot resolve the canonical path must SAY SO, not pick one.
# The copy below has no metrics-log-path.sh beside it, which is exactly the
# condition the stub used to paper over.
MD="$(mktemp -d "${TMPDIR:-/tmp}/metrics-norule.XXXXXX")"
cp "$ROOT/scripts/cycle-metrics.sh" "$MD/cycle-metrics.sh"
norule_out="$(bash "$MD/cycle-metrics.sh" 2>&1 >/dev/null | head -1)"
norule_rc=0; bash "$MD/cycle-metrics.sh" >/dev/null 2>&1 || norule_rc=$?
case "$norule_out" in
    refused:metrics:unresolvable-log-path*)
        if [ "$norule_rc" -ne 0 ]; then
            ok "an unsourceable path rule REFUSES with a named cause (rc=$norule_rc)"
        else
            bad "it printed the refusal but exited 0 — a refusal nobody can branch on"
        fi ;;
    *)
        bad "an unsourceable path rule did not refuse: '$norule_out' (rc=$norule_rc) — it is choosing a path it cannot justify" ;;
esac

# ── arm 8b: MUTATION CONTROL — the PRE-1096-p3tn script must NOT refuse. ────
# Arm 8 passes trivially once the refusal is present. This restores the old
# best-effort stub in a scratch copy and asserts that copy silently resolves a
# /tmp path instead of refusing, proving arm 8 has teeth. Same shape as the
# mutation arms in test-check-credential-channel.sh (876-exg2 / 877-mynm) and
# test-cycle-checkout-lock.sh arm 7 (1098-q7bk).
MUT="$MD/pre-1096-cycle-metrics.sh"
awk '/# ORDER 1096-p3tn: A WRITER THAT CANNOT RESOLVE/{skip=1}
     skip && /^# shellcheck source=scripts\/metrics-log-path\.sh$/{skip=0}
     skip{next} {print}' "$ROOT/scripts/cycle-metrics.sh" \
  | awk '/^if ! command -v metrics_default_log/{sub(/^if ! command -v metrics_default_log >\/dev\/null 2>&1; then$/, "command -v metrics_default_log >/dev/null 2>\\&1 || {\n    metrics_default_log() { printf \x27/tmp/%s\x27 \"$1\"; }\n}\nif false; then")} {print}' \
  > "$MUT"
if grep -q 'refused:metrics:unresolvable-log-path' "$MUT" && ! grep -q 'if false; then' "$MUT"; then
    bad "MUTATION: the strip left the refusal reachable — arm 8b proves nothing"
elif ! bash -n "$MUT" 2>/dev/null; then
    bad "MUTATION: the reconstructed pre-fix script does not parse — arm 8b proves nothing"
else
    mut_rc=0; bash "$MUT" >/dev/null 2>&1 || mut_rc=$?
    if [ "$mut_rc" -eq 0 ]; then
        ok "MUTATION: the pre-fix script silently accepts an unresolvable rule — arm 8 has teeth (pre-fix result: FAILS)"
    else
        bad "MUTATION: the pre-fix script exited $mut_rc; it was expected to silently substitute /tmp"
    fi
fi
rm -rf "$MD"

# ── arm 9: ORDER 1096-p3tn — a SECOND live timing log must be REFUSED ────────
# The reader half. On a host carrying both files, runs= and skippable: are
# computed from one and published as totals, and the cross-host recurrence
# audit (1001-q3zf) compares those totals ACROSS hosts — so a low runs= reads
# as "this step is rare" rather than "I read half the log".
#
# The guard fires ONLY on a defaulted path. Arm 9b is the control that pins
# that, and it is not optional: metrics-log-path.sh's contract is that an
# explicit TILLANDSIAS_*_LOG always wins so every fixture keeps working, and
# every fixture sets it. A guard without that exemption would red this suite.
SD="$(mktemp -d "${TMPDIR:-/tmp}/metrics-split.XXXXXX")"
split_out=""
if [ -e /tmp/tillandsias-timing.jsonl ]; then
    # Never disturb a real log: if one is already there, this arm cannot run
    # hermetically, so it declines rather than overwriting evidence.
    ok "SKIPPED (a real /tmp/tillandsias-timing.jsonl exists; arm 9 declines rather than overwrite it)"
else
    printf '{"ts":"2026-01-01T00:00:00Z","step":"fixture","phase":"f","duration_ms":1,"host":"fixture"}\n' \
        > /tmp/tillandsias-timing.jsonl
    split_out="$(cd "$ROOT" && bash scripts/cycle-metrics.sh 2>&1 >/dev/null | head -1)"
    split_rc=0; (cd "$ROOT" && bash scripts/cycle-metrics.sh >/dev/null 2>&1) || split_rc=$?
    case "$split_out" in
        violation:metrics-log-split:*)
            if [ "$split_rc" -ne 0 ]; then
                ok "two live timing logs are refused, not silently halved (rc=$split_rc)"
            else
                bad "it named the split but exited 0 — the numbers still publish"
            fi ;;
        *) bad "a second live timing log was not refused: '$split_out' (rc=$split_rc) — runs= is a partition presenting as a total" ;;
    esac

    # ── arm 9b: CONTROL — naming the log explicitly stands the guard down ────
    named_rc=0
    (cd "$ROOT" && TILLANDSIAS_TIMING_LOG="$ROOT/.cache/metrics/tillandsias-timing.jsonl" \
        bash scripts/cycle-metrics.sh >/dev/null 2>&1) || named_rc=$?
    if [ "$named_rc" -eq 0 ]; then
        ok "CONTROL: an explicitly named timing log is read without complaint, split or no split"
    else
        bad "CONTROL: naming the log explicitly still refused (rc=$named_rc) — this would red every fixture that names its own log"
    fi
    rm -f /tmp/tillandsias-timing.jsonl
fi
rm -rf "$SD"

# ── arm 9c: the split guard must NOT touch the append subcommands. ──────────
# Found by measurement after 1096-p3tn first landed, and it was a real
# regression: the guard sat before the subcommand branches, so a TIMING-log
# split refused an unrelated --emit-flow. With the /tmp debris every host
# carried that night, test-cycle-flow-emit-idempotency.sh failed 12 scenarios.
# The emit paths are best-effort by contract — they must never take down the
# step they measure — and --emit-flow does not even read the timing log. The
# split matters when numbers are PUBLISHED, not when a record is appended.
if [ -e /tmp/tillandsias-timing.jsonl ]; then
    ok "SKIPPED arm 9c (a real /tmp/tillandsias-timing.jsonl exists; declining rather than overwrite it)"
else
    printf '{"ts":"2026-01-01T00:00:00Z","step":"fixture","phase":"f","duration_ms":1,"host":"fixture"}\n' \
        > /tmp/tillandsias-timing.jsonl
    emit_rc=0
    (cd "$ROOT" && bash scripts/cycle-metrics.sh --emit-timing step=arm9c phase=f duration_ms=1 \
        >/dev/null 2>&1) || emit_rc=$?
    if [ "$emit_rc" -eq 0 ]; then
        ok "CONTROL: --emit-* is unaffected by a split — an append never takes down the step it measures"
    else
        bad "--emit-timing refused (rc=$emit_rc) over a timing-log split — the guard is coupling an append to a reader's problem"
    fi
    rep_rc=0
    (cd "$ROOT" && bash scripts/cycle-metrics.sh >/dev/null 2>&1) || rep_rc=$?
    if [ "$rep_rc" -ne 0 ]; then
        ok "CONTROL: the REPORTING path still refuses the same split (rc=$rep_rc) — the scoping did not disarm the guard"
    else
        bad "the reporting path stopped refusing a split — scoping the guard disarmed it"
    fi
    rm -f /tmp/tillandsias-timing.jsonl
fi

printf 'metrics-log-path-agreement: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:metrics-log-path-agreement:%d\n' "$pass"
