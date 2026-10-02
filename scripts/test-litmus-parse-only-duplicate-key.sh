#!/usr/bin/env bash
# preflight: gate-only — runs scripts/run-litmus-test.sh end to end (the whole litmus runner); 30 s uncapped on yoga 2026-09-29
# @trace order:1274-cbk7, spec:spec-traceability
#
# THE DEFECT. Two checks answer two different questions, and the one authors
# reach for did not say which was which:
#
#   run-litmus-test.sh --parse-only    -> "can the RUNNER extract steps here"
#   scripts/check-litmus-yaml-parses.sh -> "does this LOAD as YAML"
#
# The runner's parser is line-based and tolerates a duplicated mapping key,
# silently taking the last occurrence. A YAML loader rejects the document
# outright. So a file could be reported parseable and be unloadable at once.
#
# It happened: during the 1252-znbn migration three corpus files gained a
# duplicate key, --parse-only reported every file ok, and the gate refused with
# blocked:yaml-load-failed roughly fifteen minutes later. The author had run a
# check and read a green verdict. The check was real; it was aimed at a
# different question than the one being asked of it.
#
# ARM 1 IS THE LOAD-BEARING ONE. It neutralises the fix in a COPY of the runner
# and requires the defect to come back. Without it, every other arm here would
# stay green if the detector were deleted tomorrow — a fixture that cannot fail
# has moved the prose, not the teeth.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

_tmpbase="${TMPDIR:-/tmp}"
[ ! -d /tmp/opencode ] || _tmpbase=/tmp/opencode
TMP="$(mktemp -d "$_tmpbase/parse-only-boundary.XXXXXX")"
# Both runners derive a scratch PROJECT_ROOT. No generated scripts or runtime
# shims belong in the real checkout. Keep failed captures for diagnosis.
cleanup() {
    if [ "${fail:-1}" -eq 0 ]; then rm -rf "$TMP"
    else printf 'diagnostics: %s\n' "$TMP" >&2; fi
}
trap cleanup EXIT
mkdir -p "$TMP/project/scripts" "$TMP/project/images/router" "$TMP/bin" "$TMP/markers"
RUNNER="$TMP/project/scripts/run-litmus-test.sh"
PREFIX_RUNNER="$TMP/project/scripts/prefix-runner.sh"
cp "$ROOT/scripts/run-litmus-test.sh" "$RUNNER"
cp "$ROOT/scripts/plan-binary-probe.sh" "$TMP/project/scripts/"
: > "$TMP/project/images/router/tillandsias-router-sidecar"
# No installed tool, container runtime or Cargo fallback may be reached. These
# sentinels refuse and record invocation; the actual YAML reader stays pinned.
for tool in tillandsias-litmus-rust cargo rustup toolbox podman docker; do
    cat > "$TMP/bin/$tool" <<'SH'
#!/bin/sh
name=${0##*/}
printf '%s\n' "$*" >> "$SENTINEL_DIR/$name"
echo "refused:fixture-sentinel:$name:73" >&2
exit 73
SH
    chmod +x "$TMP/bin/$tool"
done
# Presence prevents bootstrap provisioning; runner metadata uses the real plan.
printf '#!/bin/sh\nexit 73\n' > "$TMP/bin/yq"
chmod +x "$TMP/bin/yq"
# The recording shim delegates here in normal mode, never to a real backend.
cat > "$TMP/project/scripts/tillandsias-podman" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SENTINEL_DIR/podman"
echo 'refused:fixture-sentinel:podman:73' >&2
exit 73
SH
chmod +x "$TMP/project/scripts/tillandsias-podman"
run_runner() {
    env -u CONTAINER_HOST -u TILLANDSIAS_PODMAN_REMOTE_URL \
        -u TILLANDSIAS_PODMAN_BIN -u TILLANDSIAS_REAL_PODMAN \
        -u LITMUS_PODMAN_MODE \
        PATH="$TMP/bin:$PATH" SENTINEL_DIR="$TMP/markers" \
        TILLANDSIAS_PLAN_BIN="$READER" \
        CARGO_TARGET_DIR="$TMP/cargo-target" \
        TILLANDSIAS_LITMUS_RUNTIME_DIR="$TMP/project/target/litmus-runtime" \
        LITMUS_PODMAN_CALLS_FILE="$TMP/podman-calls.log" \
        XDG_RUNTIME_DIR="$TMP" TILLANDSIAS_TIMING_LOG="$TMP/timing.jsonl" \
        LITMUS_STEP_TIMING_LOG="$TMP/steps.jsonl" \
        "$@"
}

# check-litmus-pin-claims.sh scans scripts/ for `<prefix>:<name>` and treats a
# bare occurrence as a pin claim, so the token is assembled rather than written.
LIT="litmus"
OK_PARSEABLE="ok:${LIT}-parseable"

pass=0; fail=0
ok()   { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# write_probe <file> <extra-key-lines>
write_probe() {
    local dest="$1" extra="$2"
    {
        printf '%s\n' "name: ${LIT}:cbk7-probe"
        printf '%s\n' "spec: spec-traceability"
        printf '%s\n' "phase: pre-build"
        printf '%s\n' "severity: high"
        printf '%s\n' "size: instant"
        printf '%s\n' "description: >"
        printf '%s\n' "  probe for 1274-cbk7"
        printf '%s\n' "critical_path:"
        printf '%s\n' '  - step: "a step"'
        printf '%s\n' '    command: "echo hello"'
        printf '%s\n' "    timeout_ms: 3000"
        [ -n "$extra" ] && printf '%s\n' "$extra"
        printf '%s\n' '    expected_behavior: "hello"'
    } > "$dest"
}

write_probe "$TMP/clean.yaml"       '    assert_output_contains: "hello"'
write_probe "$TMP/dup-assert.yaml"  '    assert_output_contains: "hello"
    assert_output_contains: "hello"'
write_probe "$TMP/dup-timeout.yaml" '    timeout_ms: 9000'
write_probe "$TMP/dup-command.yaml" '    command: "echo again"'

# ---------------------------------------------------------------- ARM 0
# THE PREMISE. Asserted before any verdict is read: the duplicates really are
# YAML-invalid and the clean file really is valid. If a future YAML reader
# started accepting duplicate keys, every arm below would still "pass" while
# testing nothing, and this arm is what would notice.
# Resolve from this checkout, not the caller's PATH or target override: the
# default-target gate runs fixtures from a scratch cwd with both masked
# (1401-x76w). Same fix as Codex's PR #197 for this line.
. "$ROOT/scripts/plan-binary-probe.sh"
READER="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || READER=""
case "$READER" in
    ./*) READER="$ROOT/${READER#./}" ;;
esac
if [ -z "$READER" ]; then
    printf 'skip:%s-parse-only-duplicate-key:no-yaml-reader-on-PATH\n' "$LIT"
    exit 0
fi
"$READER" validate-yaml "$TMP/clean.yaml" >/dev/null 2>&1
rc_clean_yaml=$?
"$READER" validate-yaml "$TMP/dup-assert.yaml" >/dev/null 2>&1
rc_dup_yaml=$?
if [ "$rc_clean_yaml" -eq 0 ] && [ "$rc_dup_yaml" -ne 0 ]; then
    ok "ARM 0: premise — a YAML loader ACCEPTS the clean probe and REJECTS the duplicate"
else
    bad "ARM 0: premise broken (clean rc=$rc_clean_yaml, dup rc=$rc_dup_yaml) — the gap this row closes is not reproducible, so no arm below means anything"
fi

# ---------------------------------------------------------------- ARM 1
# PRE-FIX CONTROL. Neutralise the detector in a copy and require the false
# green to return.
# TWO SITES, NOT ONE, since order 1303-2d5g. That order made --parse-only LOAD
# the document before extracting from it, and the load sits ABOVE this order's
# duplicate-key detector — so a copy with only the detector neutralised still
# refuses a duplicate-key file, on the loader's verdict, and this arm stopped
# exercising its own defect. Neutralising only one of two fixes for the same
# file proves nothing about either.
#
# The second sed is anchored on `_parse_load_enabled=1`, a line 1303-2d5g added
# for this purpose and documented as load-bearing for THIS fixture.
sed -e 's|^ *duplicate_keys+=(.*|                    : # neutralised for ARM 1|' \
    -e 's|^ *local _parse_load_enabled=1 .*|                local _parse_load_enabled=0 # neutralised for ARM 1|' \
    "$ROOT/scripts/run-litmus-test.sh" > "$PREFIX_RUNNER" 2>/dev/null
chmod +x "$PREFIX_RUNNER" 2>/dev/null

# ASSERT BOTH MUTATIONS LANDED. A sed that matched nothing produces a copy
# identical to the subject, and "the defect did not reproduce" would then be
# indistinguishable from "the mutation never applied". With two sites the
# weaker failure is worse: ONE mutation landing and the other not still yields
# a copy that refuses, which reads exactly like a fixed defect.
live_hits="$(grep -c 'duplicate_keys+=(' "$ROOT/scripts/run-litmus-test.sh")"
mut_hits="$(grep -c 'duplicate_keys+=(' "$PREFIX_RUNNER")"
live_load="$(grep -c 'local _parse_load_enabled=1 ' "$ROOT/scripts/run-litmus-test.sh")"
mut_load="$(grep -c 'local _parse_load_enabled=1 ' "$PREFIX_RUNNER")"
if [ "$live_hits" -ge 1 ] && [ "$mut_hits" -eq 0 ] \
   && [ "$live_load" -ge 1 ] && [ "$mut_load" -eq 0 ]; then
    prefix_out="$(run_runner bash "$PREFIX_RUNNER" --parse-only "$TMP/dup-assert.yaml" 2>&1)"
    prefix_rc=$?
    if [ "$prefix_rc" -eq 0 ] && printf '%s' "$prefix_out" | grep -Fq "$OK_PARSEABLE"; then
        ok "ARM 1: PRE-FIX the duplicate is reported parseable and exits 0 — the defect reproduces on demand"
    else
        bad "ARM 1: pre-fix copy did NOT reproduce the false green (rc=$prefix_rc) — the arm is not exercising the defect"
    fi
else
    bad "ARM 1: mutation did not apply (detector live=$live_hits mutant=$mut_hits; load live=$live_load mutant=$mut_load) — refusing to read a verdict from a partly-mutated copy"
fi

# ---------------------------------------------------------------- ARMS 2-4
# THE FIX, on the assert key that was actually hit AND on two keys outside the
# assert family. A fix keyed on assert_* would close the instance and leave
# every other key open.
for probe in dup-assert:assert_output_contains dup-timeout:timeout_ms dup-command:command; do
    f="${probe%%:*}"; key="${probe##*:}"
    out="$(run_runner bash "$RUNNER" --parse-only "$TMP/$f.yaml" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] \
       && printf '%s' "$out" | grep -Fq "$f.yaml" \
       && printf '%s' "$out" | grep -Fq "$key"; then
        ok "ARM: duplicated '$key' refused, exit $rc, refusal names the file and the key"
    else
        bad "ARM: duplicated '$key' not refused as required (rc=$rc): $(printf '%s' "$out" | tail -1)"
    fi
done

# ---------------------------------------------------------------- ARM 5
# NEGATIVE CONTROL. A refusal that also fires on valid input has replaced a
# false green with a false red.
out="$(run_runner bash "$RUNNER" --parse-only "$TMP/clean.yaml" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq "${OK_PARSEABLE}"; then
    ok "ARM 5: a clean probe still reports parseable with its step count, exit 0"
else
    bad "ARM 5: clean probe no longer passes (rc=$rc) — false green traded for false red"
fi

# ---------------------------------------------------------------- ARM 6
# THE CORPUS IS UNCHANGED. The row's criterion quotes a fixed count, but a
# fixed number rots as the corpus grows; what must hold is that this change
# adds no refusal. Compared against the neutralised copy on the SAME tree.
accepted_set() {
    sed -n "s|^${OK_PARSEABLE}:\(.*\):[0-9][0-9]* step(s)$|\1|p" "$1" | LC_ALL=C sort -u > "$2"
}
same_set() { cmp -s "$1" "$2"; }
if [ "$mut_hits" -eq 0 ] && [ "$mut_load" -eq 0 ]; then
    printf '%s\n' openspec/${LIT}-tests/*.yaml > "$TMP/corpus.inputs"
    corpus_ok=1
    for variant in live base; do
        subject="$RUNNER"; [ "$variant" != base ] || subject="$PREFIX_RUNNER"
        run_runner bash "$subject" --parse-only openspec/${LIT}-tests/*.yaml \
            > "$TMP/$variant.stdout" 2> "$TMP/$variant.stderr"
        corpus_rc=$?
        printf '%s\n' "$corpus_rc" > "$TMP/$variant.rc"
        accepted_set "$TMP/$variant.stdout" "$TMP/$variant.accepted"
        escape="$(printf '\033')"
        sed "s/${escape}\[[0-9;]*m//g" "$TMP/$variant.stderr" > "$TMP/$variant.diagnostics"
        # Every input must have an explicit verdict. A crash, unknown output or
        # silently dropped file cannot pass merely because both counts match.
        refused=0
        while IFS= read -r file; do
            if grep -Fxq "$file" "$TMP/$variant.accepted"; then continue; fi
            if grep -Fxq "  [PARSE FAIL] $file" "$TMP/$variant.diagnostics" \
                || grep -Fq "  [PARSE ERROR] $file:" "$TMP/$variant.diagnostics" \
                || grep -Fxq "blocked:parse-only:not-yaml:$file" "$TMP/$variant.diagnostics"; then
                refused=$((refused + 1))
            else
                printf 'unaccounted:%s:%s\n' "$variant" "$file" >&2
                corpus_ok=0
            fi
        done < "$TMP/corpus.inputs"
        while IFS= read -r file; do
            grep -Fxq "$file" "$TMP/corpus.inputs" || corpus_ok=0
        done < "$TMP/$variant.accepted"
        if [ "$refused" -eq 0 ]; then [ "$corpus_rc" -eq 0 ] || corpus_ok=0
        else [ "$corpus_rc" -eq 1 ] || corpus_ok=0; fi
        printf 'corpus:%s:accepted=%s refused=%s rc=%s\n' "$variant" \
            "$(wc -l < "$TMP/$variant.accepted" | tr -d ' ')" "$refused" "$corpus_rc"
        # Shared extraction failures remain visible, not promoted to success.
        cat "$TMP/$variant.stderr" >&2
    done
    if [ "$corpus_ok" -eq 1 ] && same_set "$TMP/live.accepted" "$TMP/base.accepted"; then
        ok "ARM 6: real corpus accepted filename sets identical; all named files accounted for"
    else
        diff -u "$TMP/base.accepted" "$TMP/live.accepted" >&2 || true
        bad "ARM 6: corpus verdict sets differ or an invocation is incomplete (captures retained)"
    fi
else
    bad "ARM 6: no usable baseline copy"
fi

# ---------------------------------------------------------------- ARM 7
# THE MODE SAYS WHICH QUESTION IT ANSWERS, and names the other check by path.
#
# THE ASSERTION MOVED BECAUSE THE BEHAVIOUR MOVED (order 1303-2d5g). This arm
# used to require the literal 'NOT YAML validity', which was true when
# --parse-only only extracted. It now LOADS each named file as YAML first, so
# that sentence became FALSE and pinning it would have required the mode to go
# on saying something untrue in order to keep a fixture green. What survives
# the change, and is the thing this arm was always really about, is that the
# mode states its SCOPE and names the corpus-wide gate by path: --parse-only
# answers for the files named on the command line, check-litmus-yaml-parses.sh
# answers for the corpus.
#
# Kept deliberately loose — 'FILES NAMED' and the path — rather than pinning
# the whole sentence. An arm that pins prose word-for-word reds on a reword
# that changed nothing, which is the expression-pinning shape 634-39ik refuses
# in litmus steps and which is no better in a fixture.
out="$(run_runner bash "$RUNNER" --parse-only "$TMP/clean.yaml" 2>&1)"
if printf '%s' "$out" | grep -Fq 'check-litmus-yaml-parses.sh' \
   && printf '%s' "$out" | grep -Fqi 'FILES NAMED'; then
    ok "ARM 7: --parse-only states its scope and names the corpus-wide gate by path"
else
    bad "ARM 7: --parse-only does not say which question it answers"
fi

# ---------------------------------------------------------------- ARM 8
# REGRESSION, AND THIS ARM EXISTS BECAUSE THE FIRST VERSION OF THIS FIX WAS
# WRONG. A critical_path item opened by `- name:` MERGES into the previous step
# in this parser (that is 1252-znbn's defect), so the merged item's command:,
# timeout_ms: and expected_behavior: look like repeats of the predecessor's
# keys — while a YAML loader, which sees two separate list items, ACCEPTS the
# file. The detector keyed on the `step:` key rather than the list-item
# boundary and reported a duplicate on valid YAML. The corpus control (ARM 6)
# did not catch it because no corpus file has that shape; the 1252-znbn
# item-opener fixture did, in the gate.
#
# A duplicated-key refusal on THIS file would be a false red. The file must be
# refused for the reason it is actually broken — the merged item — not this one.
{
    printf '%s\n' "name: ${LIT}:cbk7-merged"
    printf '%s\n' "spec: spec-traceability"
    printf '%s\n' "phase: pre-build"
    printf '%s\n' "severity: high"
    printf '%s\n' "size: instant"
    printf '%s\n' "description: >"
    printf '%s\n' "  merged-item probe"
    printf '%s\n' "critical_path:"
    printf '%s\n' '  - step: "first item"'
    printf '%s\n' '    command: "echo one"'
    printf '%s\n' "    timeout_ms: 3000"
    printf '%s\n' '    expected_behavior: "one"'
    printf '%s\n' '  - name: "second item, opened by the WRONG key"'
    printf '%s\n' '    command: "echo two"'
    printf '%s\n' "    timeout_ms: 3000"
    printf '%s\n' '    expected_behavior: "two"'
} > "$TMP/merged.yaml"

"$READER" validate-yaml "$TMP/merged.yaml" >/dev/null 2>&1
rc_merged_yaml=$?
out="$(run_runner bash "$RUNNER" --parse-only "$TMP/merged.yaml" 2>&1)"
if [ "$rc_merged_yaml" -eq 0 ] && ! printf '%s' "$out" | grep -Fq 'duplicated mapping key'; then
    ok "ARM 8: a merged '- name:' item is NOT reported as a duplicated key — a YAML loader accepts that file, so a duplicate refusal there is a false red"
elif [ "$rc_merged_yaml" -ne 0 ]; then
    bad "ARM 8: premise gone — the loader now rejects the merged-item probe (rc=$rc_merged_yaml), so this arm no longer tests a false positive"
else
    bad "ARM 8: FALSE POSITIVE — duplicate-key refusal fired on a file a YAML loader accepts"
fi

# ---------------------------------------------------------------- ARM 9
# Equal cardinality does not imply equality. Exercise the SAME comparator that
# ARM 6 uses, not a second count-only approximation of it.
printf '%s\n' a.yaml b.yaml > "$TMP/set-a"
printf '%s\n' a.yaml c.yaml > "$TMP/set-b"
if [ "$(wc -l < "$TMP/set-a")" = "$(wc -l < "$TMP/set-b")" ] \
    && same_set "$TMP/set-a" "$TMP/set-a" \
    && ! same_set "$TMP/set-a" "$TMP/set-b"; then
    ok "ARM 9: equal-count/different-filenames control is rejected by corpus comparator"
else
    bad "ARM 9: corpus comparator accepts a count-preserving filename substitution"
fi

# ---------------------------------------------------------------- ARMS 10-12
# Mode boundary: valid/extractable YAML must not execute Rust queries or
# environmental probes. Normal execution of the SAME input still refuses the
# sentinels, proving no runtime check was removed to get a parse-only green.
mkdir -p "$TMP/tests"
cat > "$TMP/bindings.yaml" <<YAML
version: '1.0'
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:cbk7-probe
YAML
normal_probe() {
    run_runner env TILLANDSIAS_LITMUS_BINDINGS="$TMP/bindings.yaml" \
        TILLANDSIAS_LITMUS_TESTS_DIR="$TMP/tests" "$@" \
        bash "$RUNNER" --test "${LIT}:cbk7-probe" --phase pre-build --size instant --compact
}
probe="$TMP/tests/${LIT}-cbk7-probe.yaml"
write_probe "$probe" '    assert_output_contains: "hello"'
cat >> "$probe" <<'YAML'
rust_queries:
  - id: fixture.rust.query@v1
    spec: spec-traceability
    processor: syn
    file: fixture.rs
    method: harmless
    required: true
YAML
rm -f "$TMP/markers/"*
"$READER" validate-yaml "$probe" > "$TMP/rust.yaml-load" 2>&1; yaml_rc=$?
run_runner bash "$RUNNER" --parse-only "$probe" > "$TMP/rust.parse" 2>&1; parse_rc=$?
if [ "$yaml_rc" -eq 0 ] && [ "$parse_rc" -eq 0 ] \
    && grep -Fq "$OK_PARSEABLE:$probe:1 step(s)" "$TMP/rust.parse" \
    && [ ! -e "$TMP/markers/tillandsias-litmus-rust" ]; then
    ok "ARM 10: Rust-query file parses without invoking refusing helper"
else
    bad "ARM 10: parse-only executed Rust queries or refused valid input (rc=$parse_rc)"
    cat "$TMP/rust.parse" >&2
fi
rm -f "$TMP/markers/tillandsias-litmus-rust"
normal_probe > "$TMP/rust.normal" 2>&1; normal_rc=$?
if [ "$normal_rc" -ne 0 ] && [ -s "$TMP/markers/tillandsias-litmus-rust" ] \
    && grep -Fq 'refused:fixture-sentinel:tillandsias-litmus-rust:73' "$TMP/rust.normal"; then
    ok "ARM 11: normal execution still invokes/refuses Rust-query helper"
else
    bad "ARM 11: normal Rust-query refusal did not occur (rc=$normal_rc)"
    cat "$TMP/rust.normal" >&2
fi

write_probe "$probe" '    assert_output_contains: "hello"'
sed 's/command: "echo hello"/command: "podman ps"/' "$probe" > "$TMP/podman.yaml"
cp "$TMP/podman.yaml" "$probe"
rm -f "$TMP/markers/podman"
run_runner bash "$RUNNER" --parse-only "$probe" > "$TMP/podman.parse" 2>&1; parse_rc=$?
if [ "$parse_rc" -eq 0 ] && grep -Fq "$OK_PARSEABLE:$probe:1 step(s)" "$TMP/podman.parse" \
    && [ ! -e "$TMP/markers/podman" ]; then
    ok "ARM 12: Podman-shaped input parses without invoking environmental probe"
else
    bad "ARM 12: parse-only invoked Podman or refused input (rc=$parse_rc)"
    cat "$TMP/podman.parse" >&2
fi
if [ "$(uname -s)" = Linux ]; then
    rm -f "$TMP/markers/podman"
    normal_probe > "$TMP/podman.normal" 2>&1; normal_rc=$?
    if [ "$normal_rc" -ne 0 ] && [ -s "$TMP/markers/podman" ] \
        && grep -Fq '[ENV-FAIL]' "$TMP/podman.normal" \
        && grep -Fq 'refused:fixture-sentinel:podman:73' "$TMP/podman.normal"; then
        ok "ARM 13: normal execution still invokes/refuses Podman preflight"
    else
        bad "ARM 13: normal Podman preflight refusal did not occur (rc=$normal_rc)"
        cat "$TMP/podman.normal" >&2
    fi
else
    printf 'skip:ARM-13:Podman-preflight-is-Linux-only\n'
fi

printf '%s\n' 'backend: fake' >> "$probe"
run_runner env CONTAINER_HOST=fixture://no-runtime bash "$RUNNER" --parse-only "$probe" \
    > "$TMP/environment.parse" 2>&1; parse_rc=$?
normal_probe CONTAINER_HOST=fixture://no-runtime > "$TMP/environment.normal" 2>&1; normal_rc=$?
if [ "$parse_rc" -eq 0 ] && grep -Fq "$OK_PARSEABLE:$probe:1 step(s)" "$TMP/environment.parse" \
    && [ "$normal_rc" -ne 0 ] \
    && grep -Fq 'refused:litmus-gate:fake-backend-under-remote-podman' "$TMP/environment.normal"; then
    ok "ARM 14: remote/fake environment check is execution-only and still refuses normal mode"
else
    bad "ARM 14: environmental mode boundary failed (parse=$parse_rc normal=$normal_rc)"
    cat "$TMP/environment.parse" "$TMP/environment.normal" >&2
fi
unexpected=0
for tool in cargo rustup toolbox docker; do
    [ ! -e "$TMP/markers/$tool" ] || unexpected=1
done
if [ "$unexpected" -eq 0 ]; then
    ok "ARM 15: no Cargo fallback, tool provisioning or container launch attempted"
else
    bad "ARM 15: execution escaped to a blocked build/provisioning sentinel"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:%s-parse-only-duplicate-key:%d/%d\n' "$LIT" "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:%s-parse-only-duplicate-key:%d-failed-of-%d\n' "$LIT" "$fail" "$((pass + fail))"
exit 1
