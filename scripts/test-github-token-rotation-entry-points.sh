#!/usr/bin/env bash
# @trace order:1489-8qd6, spec:gh-auth-script
#
# test-github-token-rotation-entry-points.sh — every resident Tillandsias
# process runs the GitHub token due-check (1461-8tyy), and removing any one
# entry point fails this fixture.
#
# test-github-token-auto-rotation.sh pins the due-check LOGIC. Nothing pinned
# its CALLERS: deleting a call left every gate green, and a host whose only
# resident process had lost its call went back to pushes dying at the 8-hour
# expiry (lenovinha 2026-09-28, mirror verdict denied/unauthenticated).
#
# The three entry points (gh-auth-script, "Every resident process keeps the
# token alive"):
#   TRAY   tray/mod.rs, the Linux tray's start-up (the fn that starts the
#          control socket server)
#   LANE   main.rs ensure_enclave_for_project, which every lane launch runs
#   GUEST  main.rs maybe_spawn_vsock_listener, the macOS/Windows guest
#
# A call counts only when it sits in the NAMED FUNCTION's body and is not a
# comment. Function bodies are extracted by brace depth from the Rust source,
# so a call moved into another function, or left in a comment, is caught.
#
# Arms:
#   1-3  each entry point calls spawn_github_token_rotation_scheduler
#   4-6  MUTATION: a scratch copy with that one call commented out FAILS,
#        naming the entry point
#   7    the audit events cite spec gh-auth-script, not the tombstoned
#        secret-rotation
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/crates/tillandsias-headless/src/main.rs"
TRAY="$ROOT/crates/tillandsias-headless/src/tray/mod.rs"
VB="$ROOT/crates/tillandsias-headless/src/vault_bootstrap.rs"
CALL="spawn_github_token_rotation_scheduler"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
for f in "$MAIN" "$TRAY" "$VB"; do [ -r "$f" ] || { echo "blocked:rotation-entry-points:missing:$f"; exit 2; }; done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/rotation-entry.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# body <file> <fn-name-regex>: the body of the first fn matching, by brace depth.
body() {
    awk -v re="$2" '
        !on && $0 ~ "fn " re "[(<]" { on = 1 }
        on {
            print
            line = $0
            gsub(/"([^"\\]|\\.)*"/, "", line)
            sub(/\/\/.*/, "", line)
            n = gsub(/\{/, "{", line); depth += n; seen += n
            depth -= gsub(/\}/, "}", line)
            if (seen && depth <= 0) exit
        }' "$1"
}
# calls <file> <fn-regex>: non-comment lines in that fn calling the scheduler.
calls() { body "$1" "$2" | grep -vE '^[[:space:]]*//' | grep -c "$CALL" || true; }

# The tray's call sits in the fn that starts the control socket server.
tray_fn="$(awk -v c="$CALL" '
    /^[[:space:]]*(pub(\([a-z]+\))? )?(async )?fn [a-z_]+/ { match($0, /fn [a-z_]+/); f = substr($0, RSTART + 3, RLENGTH - 3) }
    index($0, c) && $0 !~ /^[[:space:]]*\/\// { print f; exit }' "$TRAY")"

check() {   # <label> <file> <fn-regex>
    local n; n="$(calls "$2" "$3")"
    [ "${n:-0}" -ge 1 ]
}
ENTRIES="TRAY|$TRAY|${tray_fn:-<none>} LANE|$MAIN|ensure_enclave_for_project GUEST|$MAIN|maybe_spawn_vsock_listener"

i=0
for e in $ENTRIES; do
    i=$((i + 1)); label="${e%%|*}"; rest="${e#*|}"; file="${rest%%|*}"; fn="${rest#*|}"
    if check "$label" "$file" "$fn"; then
        ok "ARM$i $label: $fn calls $CALL"
    else bad "ARM$i $label: $fn does NOT call $CALL — this process would never rotate the token"; fi
done
if [ -z "$tray_fn" ]; then bad "ARM1 TRAY: no tray function calls $CALL at all"; fi

# ── MUTATION ARMS: comment out exactly one call in a scratch copy ──────────
i=3
for e in $ENTRIES; do
    i=$((i + 1)); label="${e%%|*}"; rest="${e#*|}"; file="${rest%%|*}"; fn="${rest#*|}"
    m="$scratch/$label.rs"
    awk -v re="$fn" -v c="$CALL" '
        !on && $0 ~ "fn " re "[(<]" { on = 1 }
        on && !done && index($0, c) && $0 !~ /^[[:space:]]*\/\// { sub(/[^[:space:]]/, "// &"); done = 1 }
        { print }' "$file" > "$m"
    if check "$label" "$m" "$fn"; then
        bad "ARM$i MUTATION $label: removing the call was NOT caught"
    else ok "ARM$i MUTATION $label: commenting out the call in $fn is caught"; fi
done

# ── ARM 7: audit events cite the live spec ────────────────────────────────
for fnname in audit_github_token_auto_rotation:"$VB" audit_github_token_refresh:"$MAIN"; do
    f="${fnname#*:}"; n="${fnname%%:*}"
    b="$(body "$f" "$n")"
    if grep -q 'spec = "gh-auth-script"' <<<"$b" && ! grep -q 'spec = "secret-rotation"' <<<"$b"; then
        ok "ARM7 $n records its audit event under spec gh-auth-script"
    else bad "ARM7 $n does not cite spec gh-auth-script (secret-rotation is tombstoned, 1397-eppt)"; fi
done

[ "$FAIL" -eq 0 ] && { echo "PASS: github-token-rotation-entry-points (1489-8qd6)"; exit 0; }
echo "FAILED: github-token-rotation-entry-points (1489-8qd6)"; exit 1
