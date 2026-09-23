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

# ── ARM 5 — RESOLUTION SURVIVES A SUBDIRECTORY-RELATIVE INVOCATION ──────────
#
# WHY ARMS 1-4 COULD NOT SEE THE DEFECT THIS CLOSES. Arm 3 greps that both
# subjects CALL agent-identity.sh; a grep cannot tell whether the call RESOLVES.
# Arm 4 is worse and is the sharper instance: it writes a PROBE containing a
# COPY of the resolution line into $tmp/scripts/probe.sh and runs THAT — a
# synthetic reproduction of the subject living inside the subject's own test
# suite. When the real line differed from the probe's, which is exactly what the
# `cd "$ROOT"` above it made true, the probe still passed. A ref whose entire
# subject is host resolution shipped a resolution path that breaks on a relative
# invocation, with its own 4/4 green.
#
# THE PATH THAT MAKES IT WORTH AN ARM (lenovinha-silverblue): someone in
# scripts/ pastes the hook's documented advice `scripts/salvage-dirty-worktree.sh
# <slug>`, gets a clear "No such file or directory", corrects it the obvious way
# to `./salvage-dirty-worktree.sh <slug>` — and lands on the wrong-cause refusal.
# Following the documentation is step one of the path to the broken form.
#
# IT INVOKES THE REAL SUBJECTS. Prerequisites are copied in beside them: without
# plan-binary-probe.sh, push-plan dies at line 132 — BEFORE resolution — and an
# absence-assertion passes identically fixed and unfixed. Measured.
# The assertions are POSITIVE, per lenovinha's rule: assert the NEXT NAMED
# CHECKPOINT was reached, not that the failure was absent.
for _subj in push-plan-fragments-to-trunk.sh salvage-dirty-worktree.sh; do
    _r="$(mktemp -d)"; mkdir -p "$_r/scripts"
    git -C "$_r" init -q
    git -C "$_r" config user.email t@example.invalid; git -C "$_r" config user.name t
    printf 'x\n' > "$_r/f"; git -C "$_r" add -A; git -C "$_r" commit -qm base >/dev/null 2>&1
    cp "$ROOT/scripts/$_subj" "$_r/scripts/"
    for _dep in plan-binary-probe.sh; do
        [ -f "$ROOT/scripts/$_dep" ] && cp "$ROOT/scripts/$_dep" "$_r/scripts/"
    done
    printf '%s\n' '#!/usr/bin/env bash' 'echo armsentinel' > "$_r/scripts/agent-identity.sh"
    chmod +x "$_r/scripts/agent-identity.sh" "$_r/scripts/$_subj"
    _o="$(cd "$_r/scripts" && ./"$_subj" probe-slug 2>&1)"; _arc=$?
    case "$_subj:$_o" in
        *:*refused:host-unresolved*)
            fail "host-slug:arm5:$_subj refused host resolution when invoked as ./$_subj from inside scripts/ — the resolver was never FOUND and the refusal names the wrong cause (rc=$_arc)" ;;
        salvage-dirty-worktree.sh:*armsentinel*)
            note "ok:host-slug:arm5-relative:$_subj resolved its host from a subdirectory-relative call — the sentinel appears in the verdict, so resolution RAN and produced the right value" ;;
        push-plan-fragments-to-trunk.sh:*refused:fragments-to-trunk:fetch*)
            note "ok:host-slug:arm5-relative:$_subj passed the resolution gate and reached the fetch checkpoint (rc=$_arc)" ;;
        *)
            fail "host-slug:arm5:$_subj reached neither its checkpoint nor a resolution refusal (rc=$_arc) — the arm cannot see the region it tests; first line: $(printf '%s' "$_o" | head -1)" ;;
    esac
    rm -rf "$_r"
done

# ── ARM 6 — THE SABOTAGE THAT FIRES THE NEGATIVE ARM ────────────────────────
#
# WHY THIS EXISTS, and it is a defect found in THIS FILE. Arm 2 asserts a
# NEGATIVE — that neither subject substitutes a literal host name — by grepping
# for the spelling `HOST="unknown"`. A placeholder spelled ANY OTHER WAY sails
# through it. Measured: injecting `HOST=nohost` into the refusal branch of
# salvage-dirty-worktree.sh reintroduces exactly the defect 1337-3tk6 was filed
# about, and THE WHOLE SUITE REPORTS 5/5 GREEN. Arm 4 cannot see it either,
# because it runs a COPY of the resolution line rather than the subject.
#
# A POSITIVE ARM FAILS LOUDLY WHEN ITS SUBJECT REGRESSES. A NEGATIVE ARM GOES
# QUIET WHEN ITS OWN PATTERN STOPS MATCHING, AND QUIET IS INDISTINGUISHABLE FROM
# CORRECT (macuahuitl, 2026-09-22, drawn from an installer arm that failed twice
# on one property while green both times).
#
# So this arm stops asserting the ABSENCE of a spelling and asserts the
# BEHAVIOUR instead: give the REAL subject a resolver that answers NOTHING and
# require it to REFUSE. A placeholder of any spelling makes it proceed, and this
# arm fires — which is what arm 2 could not do.
for _subj in salvage-dirty-worktree.sh push-plan-fragments-to-trunk.sh; do
    [ -f "$ROOT/scripts/$_subj" ] || { fail "host-slug:arm6:subject missing: $_subj"; continue; }
    _r="$(mktemp -d)"; mkdir -p "$_r/scripts"
    git -C "$_r" init -q
    git -C "$_r" config user.email t@example.invalid; git -C "$_r" config user.name t
    printf 'x\n' > "$_r/f"; git -C "$_r" add -A; git -C "$_r" commit -qm base >/dev/null 2>&1
    cp "$ROOT/scripts/$_subj" "$_r/scripts/"
    for _dep in plan-binary-probe.sh; do
        [ -f "$ROOT/scripts/$_dep" ] && cp "$ROOT/scripts/$_dep" "$_r/scripts/"
    done
    # A resolver that RUNS and answers NOTHING — distinct from arm 5's sentinel,
    # and distinct from an absent resolver, which would be the wrong cause.
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$_r/scripts/agent-identity.sh"
    chmod +x "$_r/scripts/agent-identity.sh" "$_r/scripts/$_subj"
    _o="$(cd "$_r" && ./scripts/"$_subj" probe-slug 2>&1)"; _arc=$?
    case "$_o" in
        *refused:host-unresolved*)
            note "ok:host-slug:arm6-silent-resolver:$_subj REFUSES when the resolver answers nothing (rc=$_arc)" ;;
        *)
            fail "host-slug:arm6:$_subj did NOT refuse with a silent resolver (rc=$_arc) — it is substituting a placeholder of some spelling, which arm 2's literal grep cannot see; first line: $(printf '%s' "$_o" | head -1)" ;;
    esac
    rm -rf "$_r"
done

if [ $rc -eq 0 ]; then note "ok:host-slug-resolution:6/6 arms"; else note "violation:host-slug-resolution"; fi
exit $rc
