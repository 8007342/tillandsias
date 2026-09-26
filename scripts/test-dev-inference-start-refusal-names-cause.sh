#!/usr/bin/env bash
# @trace order:1248-j6vd
# test-dev-inference-start-refusal-names-cause.sh — criterion 2 of 1248-j6vd:
# a GPU container start that fails names its CAUSE and the LOG PATH in the
# refusal itself.
#
# Measured on macuahuitl: dev-inference-ensure.sh printed a bare
# `blocked:container-start-failed`, and the cause (a CDI spec mounting a library
# the host no longer had) sat in serve.log, found only by a manual diagnosis.
#
#   ARM 1  podman run fails with an error line -> the refusal keeps its prefix,
#          quotes that error, names the log path, exits 1, one stdout line.
#   ARM 2  the log already holds an OLDER failure -> the refusal quotes THIS
#          attempt's error, never the stale one.
#   ARM 3  a failure that wrote no error-shaped line -> a named fallback, not an
#          empty cause.
#   ARM 4  CONTROL: no image -> blocked:image-missing:build-inference, unchanged.
#
# Hermetic: podman and curl are PATH stubs (curl fails, so the endpoint is
# down), HOME and the state dir are scratch, and PATH carries no tillandsias
# binary, so the tier resolves to cpu. TILLANDSIAS_DEVINF_UNDER_TEST overrides
# the subject (mutation control: the pre-fix script fails ARMS 1-3).
set -u
REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${TILLANDSIAS_DEVINF_UNDER_TEST:-$REAL_ROOT/scripts/dev-inference-ensure.sh}"
fails=0; passes=0
ok()  { passes=$((passes + 1)); echo "ok: $1"; }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }

# scratch <image: yes|no> <podman-run stderr line, may be empty>
scratch() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/devinf-refusal.XXXXXX")"
    mkdir -p "$d/bin" "$d/home" "$d/state" "$d/scripts"
    cp "$SUBJECT" "$d/scripts/dev-inference-ensure.sh"
    printf '#!/usr/bin/env bash\necho skip:nvidia-cdi:no-gpu\n' > "$d/scripts/nvidia-cdi-ensure.sh"
    printf '#!/usr/bin/env bash\nexit 7\n' > "$d/bin/curl"
    cat > "$d/bin/podman" <<POD
#!/usr/bin/env bash
case "\$1" in
    container) exit 1 ;;
    images) [ "$1" = yes ] && echo "localhost/tillandsias-inference:v56.9.23.1"; exit 0 ;;
    run) [ -s "$d/run-err" ] && cat "$d/run-err" >&2; exit 126 ;;
    *) exit 0 ;;
esac
POD
    # The error text goes through a FILE, never into generated code: pasted
    # into this unquoted heredoc, backticks in it ran as a command substitution.
    printf '%s' "$2" > "$d/run-err"
    [ -n "$2" ] && printf '\n' >> "$d/run-err"
    chmod +x "$d/bin/curl" "$d/bin/podman" "$d/scripts/"*.sh
    echo "$d"
}
run() { # <dir>
    ( PATH="$1/bin:/usr/bin:/bin" HOME="$1/home" TILLANDSIAS_DEV_INFERENCE_HOME="$1/state" \
        TILLANDSIAS_DEV_INFERENCE_READY_SECS=1 \
        bash "$1/scripts/dev-inference-ensure.sh" > "$1/stdout" 2> "$1/stderr" < /dev/null; echo $? > "$1/rc" )
}

ERR='Error: crun: open `/usr/lib64/libnvidia-egl-gbm.so.1.1.3`: $HOME No such file or directory: OCI runtime attempted to invoke a command that was not found'

# ARM 1
d="$(scratch yes "$ERR")"; run "$d"
out="$(cat "$d/stdout")"
case "$out" in
    blocked:container-start-failed:*libnvidia-egl-gbm.so.1.1.3*" log=$d/state/serve.log")
        ok "ARM 1: the refusal quotes podman's error and names the log path" ;;
    *) bad "ARM 1: stdout was: $out" ;;
esac
[ "$(cat "$d/rc")" = 1 ] && ok "ARM 1: exit 1, as blocked:* always was" || bad "ARM 1: rc=$(cat "$d/rc")"
[ "$(wc -l < "$d/stdout" | tr -d ' ')" = 1 ] && ok "ARM 1: exactly one stdout line (the grammar)" || bad "ARM 1: $(wc -l < "$d/stdout") stdout lines"
rm -rf "$d"

# ARM 2
d="$(scratch yes "Error: this attempt's cause")"
printf 'Error: an OLD failure from yesterday\n' > "$d/state/serve.log"
run "$d"
out="$(cat "$d/stdout")"
case "$out" in
    *"this attempt's cause"*) ok "ARM 2: the refusal quotes THIS attempt's error" ;;
    *) bad "ARM 2: stdout was: $out" ;;
esac
case "$out" in *"OLD failure"*) bad "ARM 2: the stale error leaked into the refusal" ;; esac
rm -rf "$d"

# ARM 3
d="$(scratch yes "")"; run "$d"
out="$(cat "$d/stdout")"
case "$out" in
    "blocked:container-start-failed:no-error-line-in-log log=$d/state/serve.log")
        ok "ARM 3: no error-shaped line -> a named fallback, still with the log path" ;;
    *) bad "ARM 3: stdout was: $out" ;;
esac
rm -rf "$d"

# ARM 4 (CONTROL)
d="$(scratch no "$ERR")"; run "$d"
[ "$(cat "$d/stdout")" = "blocked:image-missing:build-inference" ] \
    && ok "ARM 4 CONTROL: no image still refuses as image-missing, unchanged" \
    || bad "ARM 4 CONTROL: stdout was: $(cat "$d/stdout")"
rm -rf "$d"

echo "dev-inference-start-refusal fixture: ${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ] && { echo "ok:dev-inference-start-refusal-names-cause:${passes}/${passes}"; exit 0; } || exit 1
