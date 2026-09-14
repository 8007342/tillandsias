#!/usr/bin/env bash
# Consumer fixture for build.sh's memory-floor block (1176-fn2p's consumer,
# fixed 2026-09-14 after macbookair proved every macOS gate died at it).
#
# THE CLASS: under `set -euo pipefail`, `_mem_out="$(probe)"` with the probe
# exiting 3 (could-not-run: no /proc/meminfo) exits the shell at the
# assignment; the `case` written to wave that host past never runs. The block
# is extracted from build.sh by its own anchors and driven under the gate's
# OWN options with a completion sentinel: rc 3 must PROCEED with the warn, rc 0
# must proceed with the info, rc 1 must STOP (exit 1) — and a copy of the block
# with the pre-fix capture form must NOT proceed on rc 3 (the mutation control,
# built from content, proven different by cmp).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok:   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

sed -n '/^    _mem_rc=0$/,/^    esac$/p' "$ROOT/build.sh" > "$W/block.sh"
if [ ! -s "$W/block.sh" ] || ! grep -q 'esac' "$W/block.sh"; then
    bad "could not extract the memory-floor consumer block from build.sh"
    echo "FAIL: gate-memory-floor-consumer 0/1 (1176-fn2p)"; exit 1
fi
ok "the consumer block is extractable from the shipped build.sh"

# drive <probe-rc> <block-file> -> prints the driven shell's combined output;
# exit status = the driven shell's status. THE CONSTRUCTION MATTERS: the block
# runs in a SEPARATE bash process from a driver file, never in a `( set -e; … )`
# subshell inside $(…) or a pipeline — bash IGNORES errexit in those contexts,
# so that shape prints the sentinel for the pre-fix form too (measured
# 2026-09-14: ARM END from the bare assignment under both). A separate process
# with `set -euo pipefail` at its top dies at the assignment as build.sh does.
drive() {
    local code="$1" block="$2"
    local d="$W/run.$code.$RANDOM"
    mkdir -p "$d/scripts"
    printf '#!/usr/bin/env bash\necho "stub-probe rc=%s"\nexit %s\n' "$code" "$code" > "$d/scripts/check-gate-memory-floor.sh"
    chmod +x "$d/scripts/check-gate-memory-floor.sh"
    {
        printf 'set -euo pipefail\nSCRIPT_DIR=%q\n' "$d"
        printf '_info() { echo "INFO: $*"; }\n_warn() { echo "WARN: $*"; }\n_error() { echo "ERROR: $*"; }\n'
        printf '. %q\necho "consumer-block-completed"\n' "$block"
    } > "$d/driver.sh"
    bash "$d/driver.sh" > "$d/out.txt" 2>&1
    local rc=$?
    cat "$d/out.txt"
    return "$rc"
}

out="$(drive 3 "$W/block.sh")"; rc=$?
case "$out" in *"consumer-block-completed"*) ok "rc 3 (could-not-run) PROCEEDS past the block";; *) bad "rc 3 did not proceed (rc=$rc): $out";; esac
case "$out" in *"WARN:"*"unguarded"*) ok "rc 3 is waved past with the warn";; *) bad "rc 3 did not warn: $out";; esac

out="$(drive 0 "$W/block.sh")"; rc=$?
case "$out" in *"consumer-block-completed"*) ok "rc 0 proceeds";; *) bad "rc 0 did not proceed (rc=$rc): $out";; esac
case "$out" in *"INFO:"*) ok "rc 0 reports the info line";; *) bad "rc 0 did not report: $out";; esac

out="$(drive 1 "$W/block.sh")"; rc=$?
case "$out" in *"consumer-block-completed"*) bad "rc 1 (floor breached) PROCEEDED — the refusal is gone: $out";; *) ok "rc 1 stops the gate (no sentinel)";; esac
[ "$rc" -eq 1 ] && ok "rc 1 exits 1" || bad "rc 1 exited $rc, want 1"

# MUTATION CONTROL from content: the pre-fix capture form.
awk '{ if ($0 ~ /^    _mem_rc=0$/) next; if ($0 ~ /\|\| _mem_rc=\$\?$/) { sub(/ \|\| _mem_rc=\$\?$/, ""); print; print "    _mem_rc=$?"; next } print }' "$W/block.sh" > "$W/mutant.sh"
if cmp -s "$W/block.sh" "$W/mutant.sh"; then
    bad "mutation did not apply — the strip matched nothing"
else
    ok "the mutant differs from the shipped block (cmp)"
    out="$(drive 3 "$W/mutant.sh")"; rc=$?
    case "$out" in *"consumer-block-completed"*) bad "the pre-fix capture form PROCEEDED on rc 3 — the arm has no teeth: $out";; *) ok "the pre-fix capture form dies on rc 3 (rc=$rc), so the arm has teeth";; esac
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: gate-memory-floor-consumer $pass/$total (1176-fn2p)"; exit 0; fi
echo "FAIL: gate-memory-floor-consumer $pass/$total (1176-fn2p)"; exit 1
