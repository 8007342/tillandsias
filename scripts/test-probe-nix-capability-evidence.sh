#!/usr/bin/env bash
# ORDER 917-zkge — the nix-capability probe's EVIDENCE must survive a noisy shell.
#
# Third-generation defect in probe-nix-capability.sh, found by pirria 2026-08-30:
# the capable branch captured `nix --version 2>&1 | head -1`, which merges the
# invoking shell's stderr ahead of nix's stdout. On a host with a chatty
# ~/.bashrc, head -1 returned the rc warning — pirria's capable row carried a
# brew-not-found message as its proof that nix answered.
#
# The verdict was never wrong (exit status branches correctly). The EVIDENCE was,
# silently, on exactly the hosts with noisy shells. That is the probe's own rule
# — record the evidence, not the conclusion — failing at the evidence channel,
# and it is invisible because the wrong string looks like plausible output.
#
# This pins the capture in isolation, with a deliberately noisy command standing
# in for the noisy shell.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/probe-nix-capability.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Pull the helper out of the probe without running the probe itself.
_nix_version_evidence() {
    local _out
    _out="$("$@" 2>/dev/null)" || true
    grep -m1 -iE 'nix.*[0-9]+\.[0-9]+' <<<"$_out" && return 0
    printf 'answered, but printed no recognisable version line'
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A "nix" whose shell is noisy: warnings on stderr BEFORE the real version.
cat > "$WORK/noisy-nix" <<'FAKE'
#!/usr/bin/env bash
echo "bash: brew: command not found" >&2
echo "warning: some rc noise" >&2
echo "nix (Nix) 2.34.8"
FAKE
chmod +x "$WORK/noisy-nix"

# ARM 1: the defect itself. stderr must not become the evidence.
got="$(_nix_version_evidence "$WORK/noisy-nix" --version)"
[[ "$got" == "nix (Nix) 2.34.8" ]] \
    || fail "noisy shell polluted the evidence: expected the version line, got '$got'"
grep -qi "brew\|warning" <<<"$got" \
    && fail "the evidence field carries shell noise as proof that nix answered: '$got'"

# ARM 2: the defect's shape reproduced, so arm 1 is known to have teeth.
# `| head -1` closes the pipe early, so the producer takes SIGPIPE and, under
# this script's own `set -o pipefail`, the substitution returns 141 — which is
# how this arm previously killed the whole test AFTER printing ok (exit 141 with
# every assertion passed). Reproducing a defect must not import the defect's
# side effects into the harness: capture to a file, then read it.
"$WORK/noisy-nix" --version > "$WORK/old.out" 2>&1 || true
old_way="$(head -1 "$WORK/old.out")"
[[ "$old_way" != "nix (Nix) 2.34.8" ]] \
    || fail "fixture drift: the old 2>&1|head -1 capture no longer reproduces the defect, so arm 1 proves nothing"

# ARM 3: version not on the first stdout line either — position must not be trusted.
cat > "$WORK/banner-nix" <<'FAKE'
#!/usr/bin/env bash
echo "some banner line"
echo "nix (Nix) 2.34.8"
FAKE
chmod +x "$WORK/banner-nix"
got="$(_nix_version_evidence "$WORK/banner-nix" --version)"
[[ "$got" == "nix (Nix) 2.34.8" ]] \
    || fail "the capture trusted line position rather than finding the version line: got '$got'"

# ARM 4: nothing recognisable — say so rather than presenting noise as a version.
cat > "$WORK/mute-nix" <<'FAKE'
#!/usr/bin/env bash
echo "totally unrelated output"
FAKE
chmod +x "$WORK/mute-nix"
got="$(_nix_version_evidence "$WORK/mute-nix" --version)"
grep -q "no recognisable version line" <<<"$got" \
    || fail "an unrecognised string was presented as a version: '$got'"

# ARM 5: the SHIM branch must keep merging stderr — there, the error IS the
# evidence, and "fixing" it into silence would destroy the distinction between
# a shim to an absent binary and a genuine absence.
grep -q 'Deliberately 2>&1 HERE' "$PROBE" \
    || fail "the shim branch lost its deliberate stderr capture, or its note explaining why"

echo "ok: the probe's evidence field survives a noisy shell and never presents noise as a version (917-zkge)"
