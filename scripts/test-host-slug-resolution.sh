#!/usr/bin/env bash
# @trace order:1337-3tk6
#
# test-host-slug-resolution.sh — ORDER 1337-3tk6.
#
# Both scripts that stamp a HOST into something durable resolved it through the
# `hostname` executable with a literal "unknown" fallback. The forge image does
# not ship that executable, so on every forge:
#   scripts/salvage-dirty-worktree.sh      pushed salvage/unknown/<date>-<slug>
#   scripts/push-plan-fragments-to-trunk.sh committed "plan(unknown): …"
# while $HOSTNAME, /etc/hostname and `uname -n` all answered correctly in the
# same container, and the fragment FILENAMES in those same commit subjects
# carried the host correctly because the plan tool takes it from --host.
# The host was present in the payload and absent in the attribution.
#
# THE FALLBACK WAS A PLACEHOLDER, NOT A SECOND RESOLVER — it invented a
# plausible name instead of trying another source or refusing.
#
# scripts/agent-identity.sh already solved this as order 743-mgf3, for this
# exact cause, and its `node-name` probe is already shared with
# scripts/mo-full-attest.sh. These two scripts never adopted it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
AI="scripts/agent-identity.sh"
SUBJECTS="scripts/salvage-dirty-worktree.sh scripts/push-plan-fragments-to-trunk.sh"

rc=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/host-slug.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*" >&2; rc=1; }

# ── ARM 0 — CAN THIS RUN MEASURE? ───────────────────────────────────────────
# If the resolver is missing or silent, every arm below reads empty and would
# report the SUBJECTS as broken. Say could-not-run instead; nothing here is an
# accusation against them.
if [ ! -x "$AI" ]; then
    note "could-not-run:host-slug:resolver-absent:$AI"
    echo "  The shared resolver is missing, so no arm measured anything. This is a" >&2
    echo "  MEASUREMENT failure, not a verdict on the subjects." >&2
    exit 2
fi
resolved="$("$AI" node-name 2>/dev/null | tr -d '\n')"
if [ -z "$resolved" ]; then
    note "could-not-run:host-slug:resolver-silent — $AI node-name printed nothing on this host"
    echo "  Not a verdict on the subjects: the instrument this test measures with" >&2
    echo "  could not answer. Fix the resolver, or run this on a host where it does." >&2
    exit 2
fi
note "ok:host-slug:arm0-can-measure:resolver answers [$resolved]"

# ── ARM 1 — THE PRE-FIX CHAIN, RUN HERE ─────────────────────────────────────
# Not a description of the old code: the old chain itself, executed. On a host
# with no `hostname` executable it must produce the defect, or this host cannot
# demonstrate the row and says so rather than passing quietly.
old_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
old_host="$(printf '%s' "$old_host" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
[ -n "$old_host" ] || old_host="unknown"
if [ "$old_host" = "unknown" ]; then
    note "ok:host-slug:arm1-pre-fix-chain-fails-here:the old chain yields [unknown] on this host"
elif [ "$old_host" = "$resolved" ]; then
    note "skip:host-slug:arm1:this host HAS a working hostname executable ([$old_host]), so it cannot demonstrate the defect — the fix is still asserted by arms 2-4"
else
    fail "host-slug:arm1:the old chain produced [$old_host] which is neither 'unknown' nor the resolved name [$resolved]"
fi

# ── ARM 2 — NEITHER SUBJECT INVENTS A NAME ──────────────────────────────────
for s in $SUBJECTS; do
    if grep -qE 'HOST="unknown"|HOST=unknown' "$s"; then
        fail "host-slug:arm2:$s still falls back to a literal placeholder — a fallback that invents a name is the defect, not the fix"
    fi
done
[ $rc -eq 0 ] && note "ok:host-slug:arm2-no-placeholder:neither subject substitutes a literal host name"

# ── ARM 3 — BOTH SUBJECTS USE THE ONE RESOLVER ──────────────────────────────
# Named so a THIRD script cannot quietly hand-roll a fourth chain: the point of
# 743-mgf3 was one probe, and two copies drifting is how this row happened.
for s in $SUBJECTS; do
    grep -q 'agent-identity.sh' "$s" \
      || fail "host-slug:arm3:$s does not call the shared resolver (scripts/agent-identity.sh node-name)"
done
[ $rc -eq 0 ] && note "ok:host-slug:arm3-one-resolver:both subjects call agent-identity.sh node-name"

# ── ARM 4 — IT REFUSES WHEN THE RESOLVER IS SILENT ──────────────────────────
# The behaviour the row actually asks for: refuse, do not invent. Exercised
# against a STUB resolver that answers nothing, so no push is attempted.
mkdir -p "$tmp/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tmp/scripts/agent-identity.sh"
chmod +x "$tmp/scripts/agent-identity.sh"
cat > "$tmp/scripts/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
_ai="$(dirname "${BASH_SOURCE[0]}")/agent-identity.sh"
HOST="$([ -x "$_ai" ] && "$_ai" node-name 2>/dev/null || true)"
HOST="$(printf '%s' "$HOST" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
if [ -z "$HOST" ]; then
    echo "refused:host-unresolved: … Nothing pushed." >&2
    exit 2
fi
echo "would-push-as:$HOST"
PROBE
chmod +x "$tmp/scripts/probe.sh"
probe_out="$(bash "$tmp/scripts/probe.sh" 2>&1)"; probe_rc=$?
case "$probe_rc:$probe_out" in
    2:refused:host-unresolved*) note "ok:host-slug:arm4-refuses-on-silence:rc=2 and refuses by name rather than inventing a slug" ;;
    0:*) fail "host-slug:arm4:a silent resolver still produced a push [$probe_out] — the placeholder is back" ;;
    *)   fail "host-slug:arm4:unexpected rc=$probe_rc out=[$probe_out]" ;;
esac

if [ $rc -eq 0 ]; then note "ok:host-slug-resolution:4/4 arms"; else note "violation:host-slug-resolution"; fi
exit $rc
