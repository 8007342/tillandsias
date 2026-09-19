#!/usr/bin/env bash
# @trace order:1249-xngp
#
# configure-ollama.sh — bring up a BARE-METAL ollama for the local expert lane,
# idempotently, on Fedora Workstation and on Silverblue-family immutable hosts.
#
# WHY BARE METAL AND NOT THE CONTAINER (operator ruling 2026-09-18, and it is
# measured rather than preferred). The engine-selection policy is: prefer a
# bare-metal instance, fall back to a throwaway container only when none exists.
# MEASURED on macuahuitl with scripts/bench-accel-lane.sh (A5000, qwen2.5:0.5b,
# 3 reps, workload_suite 802-2536-v1):
#
#     lane              decode tok/s            embed ms/chunk
#     host-native gpu   487.9 / 561.1 / 513.9   7 / 7 / 7
#     container   gpu    24.9 / 467.4 / 462.8   19 / 18 / 18
#
# Warm decode costs ~10% in the container, which is cheap. The other two numbers
# are not. The FIRST rep is 24.9 tok/s — a 19x cold-start penalty as the model
# loads — and a THROWAWAY container pays that every time it is thrown away, so
# "throwaway" and "cold start" are one cost counted twice. Embedding is 2.6x
# slower on EVERY rep, not just the first, and gains nothing from the GPU on
# either lane. Inference is exactly the workload where small overheads compound,
# which is why this script exists instead of a container recipe.
#
# WHY ~/.local/bin AND NOT A PACKAGE. It is the one install path that works
# unchanged on a mutable Fedora host and an rpm-ostree immutable one: no root,
# no layered package, no /usr write, and it survives an ostree upgrade. The
# binary already on macuahuitl was installed this way (39 MB, owned by no
# package), so this script formalises what the fleet already does rather than
# introducing a second convention.
#
# IDEMPOTENT. Every step checks before acting: an install that is already
# current is skipped, a running API is reused rather than restarted, and
# `ollama pull` is itself a no-op for an up-to-date model. Running this twice in
# a row makes no changes the second time and says so.
#
# VERDICTS (stdout, last line), each carrying its own remedy per order 1247-amcu:
#   ok:configure-ollama:ready:<models>        engine up, models present
#   ok:configure-ollama:already-current       nothing needed
#   blocked:configure-ollama:no-network       cannot fetch the runtime or a model
#   blocked:configure-ollama:install-failed   download or unpack refused
#   blocked:configure-ollama:api-unreachable  started, never answered
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${TILLANDSIAS_OLLAMA_BIN_DIR:-$HOME/.local/bin}"
OLLAMA="$BIN_DIR/ollama"
ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
UNIT_DIR="$HOME/.config/systemd/user"
# The models the tree itself names. Kept here rather than invented so this
# script and scripts/check-local-expert-health.sh cannot drift apart.
MODELS="${TILLANDSIAS_OLLAMA_MODELS:-qwen2.5:0.5b nomic-embed-text qwen2.5:7b}"
WANT_UNIT="${TILLANDSIAS_OLLAMA_INSTALL_UNIT:-1}"
changed=0

say() { printf '%s\n' "$*"; }

host_kind() {
    if [ -e /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then
        echo "linux_immutable"
    else
        echo "linux_mutable"
    fi
}

api_up() { curl -fsS --max-time 3 "$ENDPOINT/api/version" >/dev/null 2>&1; }

# WHICH LANE IS ANSWERING? (order 1249-xngp, and this script needed it itself.)
# An API on 11434 proves an engine is up; it does NOT prove the engine is the
# bare-metal one this script exists to provide. FOUND THE HARD WAY on macuahuitl:
# a containerised ollama is visible to the HOST as an `ollama serve` process, so
# pgrep reports a bare-metal engine that does not exist — its cgroup reads
# `libpod-<id>`. A port probe plus a pgrep therefore BOTH say "bare metal is
# running" when only a container is. Ask podman, which is the only source that
# can distinguish them.
container_holds_port() {
    command -v podman >/dev/null 2>&1 || return 1
    podman ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
        | grep -q '11434' && return 0
    # A container may reach the port without publishing it (host networking or
    # an enclave DNS name), so also accept a running ollama whose cgroup is a
    # libpod slice — the discriminator that actually settled this on macuahuitl.
    local _p
    for _p in $(pgrep -f 'ollama serve' 2>/dev/null); do
        grep -q 'libpod-' "/proc/$_p/cgroup" 2>/dev/null && return 0
    done
    return 1
}

# ---- 1. the binary -------------------------------------------------------
if [ -x "$OLLAMA" ]; then
    say "  present: $OLLAMA ($("$OLLAMA" --version 2>/dev/null | head -1))"
else
    if ! command -v curl >/dev/null 2>&1; then
        say "blocked:configure-ollama:install-failed"
        say "  curl is required to fetch the runtime and is not on PATH."
        say "  WHAT TO DO: install it, then re-run this script."
        say "    $( [ "$(host_kind)" = linux_immutable ] && echo 'rpm-ostree install curl   # then reboot' || echo 'sudo dnf install -y curl' )"
        exit 1
    fi
    mkdir -p "$BIN_DIR" || { say "blocked:configure-ollama:install-failed"; say "  cannot create $BIN_DIR"; exit 1; }
    say "  installing ollama into $BIN_DIR (no root, survives an ostree upgrade)"
    if ! curl -fsSL https://ollama.com/install.sh 2>/dev/null \
         | OLLAMA_INSTALL_DIR="$BIN_DIR" sh >/dev/null 2>&1; then
        say "blocked:configure-ollama:no-network"
        say "  could not fetch https://ollama.com/install.sh"
        say "  WHY THIS IS NOT A LOCAL FAULT: nothing on this host is missing;"
        say "  the runtime is downloaded on first configure and cached thereafter."
        say "  WHAT TO DO: restore outbound HTTPS and re-run, or copy an existing"
        say "  ollama binary to $OLLAMA from a host that already has one — it is a"
        say "  single static binary and needs no package."
        exit 1
    fi
    [ -x "$OLLAMA" ] || { say "blocked:configure-ollama:install-failed"; say "  installer ran but $OLLAMA is absent — see its output above"; exit 1; }
    changed=1
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "  NOTE: $BIN_DIR is not on PATH for this shell."
       say "        WHAT TO DO: add it to your shell profile, or invoke $OLLAMA by path."
       ;;
esac

# ---- 2. durability: a user unit, so the lane survives a reboot -----------
# A --user unit is deliberate: it needs no root, works identically on an
# immutable host, and keeps the engine in the operator's own session rather
# than as a system service they did not ask for.
if [ "$WANT_UNIT" = "1" ] && command -v systemctl >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR"
    _unit="$UNIT_DIR/ollama.service"
    _want="[Unit]
Description=Ollama (Tillandsias local expert lane, bare metal)
After=network-online.target

[Service]
ExecStart=$OLLAMA serve
Restart=on-failure
Environment=OLLAMA_HOST=127.0.0.1:11434

[Install]
WantedBy=default.target
"
    # BOTH SIDES THROUGH COMMAND SUBSTITUTION, deliberately. `$(cat f)` strips
    # trailing newlines and a here-string literal does not, so comparing one
    # against the other NEVER matches and the unit is rewritten on every run —
    # which is exactly what the first version of this script did, reporting
    # `ready` instead of `already-current` on a second invocation. Caught by
    # running it twice and reading the verdict, not by reading the code.
    if [ ! -f "$_unit" ] || [ "$(cat "$_unit" 2>/dev/null)" != "$(printf '%s' "$_want")" ]; then
        printf '%s' "$_want" > "$_unit"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        changed=1
        say "  wrote $_unit"
    fi
    systemctl --user enable --now ollama.service >/dev/null 2>&1 || true
fi

# ---- 3. the API ----------------------------------------------------------
if api_up && container_holds_port; then
    say "blocked:configure-ollama:container-holds-the-lane"
    say "  an engine is answering on $ENDPOINT, but it is a CONTAINER, not the"
    say "  bare-metal instance this script provides."
    say "  WHY THAT MATTERS RATHER THAN BEING FINE: measured on macuahuitl, the"
    say "  container lane costs ~10% of warm decode, 19x on the first rep (a cold"
    say "  start a throwaway container pays every time), and 2.6x on EVERY"
    say "  embedding. The bare-metal-first policy (1249-xngp) exists because"
    say "  inference is where small overheads compound."
    say "  WHAT TO DO: stop the container, then re-run this script."
    say "    podman stop tillandsias-dev-inference"
    say "  Or, to deliberately keep the container lane and skip bare metal:"
    say "    TILLANDSIAS_OLLAMA_ALLOW_CONTAINER=1 $0"
    [ "${TILLANDSIAS_OLLAMA_ALLOW_CONTAINER:-0}" = "1" ] || exit 1
    say "  (TILLANDSIAS_OLLAMA_ALLOW_CONTAINER=1 set — continuing against the container)"
fi

if ! api_up; then
    if ! systemctl --user is-active ollama.service >/dev/null 2>&1; then
        setsid nohup "$OLLAMA" serve >/dev/null 2>&1 < /dev/null &
        changed=1
    fi
    _w=0
    while [ "$_w" -lt 30 ]; do api_up && break; sleep 2; _w=$((_w + 2)); done
fi
if ! api_up; then
    say "blocked:configure-ollama:api-unreachable"
    say "  the engine was started but $ENDPOINT never answered within 30s."
    say "  WHAT TO DO, in order:"
    say "    systemctl --user status ollama.service    # if the unit is in use"
    say "    $OLLAMA serve                             # run it in the foreground and read the error"
    say "  A BUSY PORT IS THE COMMON CAUSE: another engine may already hold 11434."
    say "  That is not a failure of this script — under the bare-metal-first policy"
    say "  (1249-xngp) an engine already serving there is the PREFERRED lane."
    exit 1
fi

# ---- 4. models -----------------------------------------------------------
_have="$(curl -fsS --max-time 5 "$ENDPOINT/api/tags" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
for m in $MODELS; do
    if printf '%s\n' "$_have" | grep -qx "$m" || printf '%s\n' "$_have" | grep -qx "$m:latest"; then
        continue
    fi
    say "  pulling $m"
    if ! "$OLLAMA" pull "$m" >/dev/null 2>&1; then
        say "blocked:configure-ollama:no-network"
        say "  the engine is up but '$m' could not be pulled."
        say "  WHAT TO DO: restore outbound HTTPS and re-run — every step above is"
        say "  idempotent, so a re-run resumes at this model rather than redoing"
        say "  the install. To proceed with fewer models meanwhile:"
        say "    TILLANDSIAS_OLLAMA_MODELS='qwen2.5:0.5b nomic-embed-text' $0"
        exit 1
    fi
    changed=1
done

# ---- 5. verdict, verified against the tree's own health check ------------
_health="$(bash "$REPO_ROOT/scripts/check-local-expert-health.sh" 2>&1 | tail -1)"
case "$_health" in
    ok:*) ;;
    *) say "blocked:configure-ollama:api-unreachable"
       say "  configure completed but the tree's own health check disagrees:"
       say "    $_health"
       say "  WHAT TO DO: that check is the authority, not this script. Run it"
       say "  directly and follow its verdict:"
       say "    bash scripts/check-local-expert-health.sh"
       exit 1 ;;
esac

if [ "$changed" = "0" ]; then
    say "ok:configure-ollama:already-current"
else
    say "ok:configure-ollama:ready:$(printf '%s' "$MODELS" | tr ' ' ',')"
fi
