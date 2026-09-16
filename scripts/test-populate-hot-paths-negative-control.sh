#!/usr/bin/env bash
# 920-tqhs negative control: with /opt/cheatsheets deliberately unwritable by
# the lane user, populate_hot_paths must NAME the failure loudly (no
# unconditional success line) and tellme must still answer from the shipped
# /opt/cheatsheets-image bundle.
#
# Root + runuser-gated: the fixture mutates /opt and runs the copy as an
# unprivileged lane user, which is the only way to reproduce the EACCES the
# 2>/dev/null used to swallow. Skips (exit 0) rather than fails on hosts that
# cannot or should not run it.
#
# @trace spec:forge-environment-discoverability, plan/issues/populate-hot-paths-fails-silent-and-traces-success

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

skip() { echo "skip: $*" ; exit 0 ; }

if [ "$(id -u)" -ne 0 ]; then
    skip "not root — the negative control needs to mutate /opt and drop to a lane user"
fi
command -v runuser >/dev/null 2>&1 || skip "runuser unavailable"
id nobody >/dev/null 2>&1 || skip "no 'nobody' account"
[ -e /opt/cheatsheets ] && skip "pre-existing /opt/cheatsheets — refusing to destroy it"
[ -e /opt/cheatsheets-image ] && skip "pre-existing /opt/cheatsheets-image — refusing to touch it"

FAIL_COUNT=0
LINE_MARK="920-tqhs-negative-control-$$"

trap 'rm -rf /opt/cheatsheets /opt/cheatsheets-image /tmp/php-ng-home "$TMPD" /tmp/php-ng-*' EXIT

TMPD="$(mktemp -d /tmp/php-ng-XXXXXX)"
HOME_LANE="$TMPD/home"

mkdir -p /opt/cheatsheets-image/cookbook "$HOME_LANE"
printf '%s\n' '## heatmap' > /opt/cheatsheets-image/INDEX.md
printf '%s\n' '# heatland' > /opt/cheatsheets-image/cookbook/heat.md
chmod 0755 /opt/cheatsheets /opt/cheatsheets-image
chmod -R a+rX /opt/cheatsheets-image

# /opt/cheatsheets sits at 0555 — present but unwritable, exactly the
# root-owned-tmpfs-under-keep-id symptom the packet names.
mkdir -p /opt/cheatsheets
chmod 0555 /opt/cheatsheets

chown -R nobody:nobody "$HOME_LANE"

# -- Negative control 1: populate_hot_paths logs FAILED, never a success line.
printf '%s\n' "$LINE_MARK" >> /tmp/forge-lifecycle.log 2>/dev/null || true
runuser -u nobody -- env HOME="$HOME_LANE" bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/images/default/lib-common.sh"
    populate_hot_paths
' >"$TMPD/php.out" 2>&1
rc=$?

if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "FAIL: populate_hot_paths unexpected rc $rc (expected 0 — degrade loudly, not abort)"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi
tail_log="$(sed -n "/$LINE_MARK/,\$p" /tmp/forge-lifecycle.log 2>/dev/null || true)"
if ! printf '%s' "$tail_log" | grep -q 'FAILED: cp /opt/cheatsheets-image'; then
    echo "FAIL: lifecycle log did not name the copy failure:"
    printf '%s\n' "$tail_log"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi
if printf '%s' "$tail_log" | grep -q 'cheatsheets copied to tmpfs'; then
    echo "FAIL: lifecycle log printed the unconditional success line despite the failure"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi

# -- Negative control 2: tellme answers from the image bundle and says so.
runuser -u nobody -- env HOME="$HOME_LANE" \
    BASH_ENV=/dev/null \
    TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets \
    bash "$REPO_ROOT/images/default/cli/tellme" about --list \
    >"$TMPD/tellme.out" 2>"$TMPD/tellme.err"
t_rc=$?
if [ "$t_rc" -ne 0 ]; then
    echo "FAIL: tellme exited $t_rc (stderr: $(tr '\n' ' ' < "$TMPD/tellme.err"))"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi
if ! grep -q 'serving the shipped image bundle (/opt/cheatsheets-image)' "$TMPD/tellme.err"; then
    echo "FAIL: tellme did not name the degraded copy it serves (stderr: $(tr '\n' ' ' < "$TMPD/tellme.err"))"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi
if ! grep -q '^heatmap$' "$TMPD/tellme.out"; then
    echo "FAIL: tellme did not list the image-bundle topic (out: $(tr '\n' ' ' < "$TMPD/tellme.out"))"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "populate-hot-paths negative control: $FAIL_COUNT failure(s)"
    exit 1
fi
echo "PASS: unwritable /opt/cheatsheets — populate_hot_paths named the failure, tellme served the image bundle"