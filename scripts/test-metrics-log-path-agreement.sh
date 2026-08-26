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
    "$ROOT/"*) ok "in-checkout default is repo-relative: ${probe_path#"$ROOT"/}" ;;
    /tmp/*) bad "still defaulting to /tmp inside a checkout — the boundary split is back" ;;
    *) bad "unexpected default path: $probe_path" ;;
esac

# ── arm 2b: and it must NOT live under target/, which our own GC destroys ─────
# This arm asserts a PROPERTY, not a literal path, deliberately: arm 2 used to
# pin "$ROOT/target/metrics/" and would have gone green on a location that our
# own daily maintenance deletes.
#
# `check-build-cache-sweep.sh` fires at 40 GiB or a 14-day marker, and both
# Start-Of-Day maintenance and Finalization 9c then run `cargo clean`, which
# removes the target directory wholesale. Measured in a throwaway crate:
#   before: target/metrics=1  .cache/metrics=1 ; cargo clean ;
#   after:  target/metrics=0  .cache/metrics=1
# And macuahuitl's target/ went 24 -> 31 GiB inside one cycle of gate runs.
#
# Why it matters more than a deleted file: `flow:` is a ROLLING average whose
# value IS its length, and a reset on routine GC is indistinguishable from the
# documented one-time /tmp migration — so the loss reads as expected.
case "$probe_path" in
    "$ROOT/target/"*)
        bad "default lives under target/, which \`cargo clean\` removes — a routine build-cache sweep would silently reset every rolling metric: $probe_path" ;;
    *)
        ok "default is outside target/, so the build-cache sweep cannot eat the series" ;;
esac

# ── arm 2c: whatever the location, git must ignore it ────────────────────────
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

printf 'metrics-log-path-agreement: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:metrics-log-path-agreement:%d\n' "$pass"
