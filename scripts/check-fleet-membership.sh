#!/usr/bin/env bash
# @trace order:1311-ajpm, spec:methodology-accountability
# bash-dialect: pure-3.2 — runs on the two Macs' /bin/bash and on Git Bash.
#
# check-fleet-membership.sh — the NON-MUTATING verifier behind
# ./skills/join-the-fleet (operator direction 2026-09-20).
#
# It walks the fleet's joining requirements for the regime it detects and
# prints one line per step:
#   ok:join-the-fleet:<step>[:<detail>]      the requirement holds
#   skip:join-the-fleet:<step>:<reason>      not applicable in this regime, BY NAME
#   todo:join-the-fleet:<step>:<remedy>      what is LEFT, with the command that does it
#   note:join-the-fleet:<step>:<detail>      information the operator wants seen
# and ONE verdict line last:
#   ok:join-the-fleet:<host>:<regime>:ran=<n> skipped=<m>            exit 0
#   todo:join-the-fleet:<host>:<regime>:todos=<k> ran=<n> skipped=<m> exit 1
#
# THE CHECKER NEVER INSTALLS, CREATES, SEEDS OR STARTS ANYTHING. The skill runs
# the ensure-shaped commands; this script only says what is left. A green that
# does not say what it did not run is worthless, so every skip is named and the
# verdict carries the counts (the rule three rows learned on 2026-09-20).
#
# REGIME (from scripts/agent-identity.sh's precedence): forge when
# TILLANDSIAS_HOST_KIND=forge or the .forge-startup-context.md marker exists;
# else by $OSTYPE: linux-immutable (/run/ostree-booted or rpm-ostree),
# linux-mutable, macos, windows.
#
# HERMETIC OVERRIDES, for fixtures only (same idiom as TILLANDSIAS_ETC_HOSTNAME):
#   JOIN_FLEET_ROOT     the checkout to inspect (default: this script's parent)
#   JOIN_FLEET_GIT_DIR  the git dir whose hooks/ are inspected
#   JOIN_FLEET_PROBES=0 skip the probes that execute other guards (credential
#                       channel, plan binary currency, experts, substrate) —
#                       they are counted as named skips, never as passes.
set -uo pipefail

ROOT="${JOIN_FLEET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || { echo "refused:join-the-fleet:no-checkout:$ROOT"; exit 2; }

ran=0; skipped=0; todos=0
_ok()   { echo "ok:join-the-fleet:$1";   ran=$((ran + 1)); }
_skip() { echo "skip:join-the-fleet:$1"; skipped=$((skipped + 1)); }
_todo() { echo "todo:join-the-fleet:$1"; todos=$((todos + 1)); ran=$((ran + 1)); }
_note() { echo "note:join-the-fleet:$1"; }

# ---- regime and identity ---------------------------------------------------
REGIME=unknown
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ] || [ -f "$ROOT/.forge-startup-context.md" ]; then
    REGIME=forge
else
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        linux*|Linux*)
            if [ -e /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then
                REGIME=linux-immutable
            else
                REGIME=linux-mutable
            fi ;;
        darwin*|Darwin*) REGIME=macos ;;
        msys*|cygwin*|MINGW*|MSYS*|CYGWIN*) REGIME=windows ;;
    esac
fi
HOST="$(bash "$ROOT/scripts/agent-identity.sh" node-name 2>/dev/null || true)"
[ -n "$HOST" ] || HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
PROJECT="${TILLANDSIAS_PROJECT:-$(basename "$ROOT")}"
PROBES="${JOIN_FLEET_PROBES:-1}"

case "$REGIME" in
    forge) _note "session-name:${HOST}-${PROJECT}-forge" ;;
    linux-immutable) _note "session-name:${HOST}-silverblue" ;;
    linux-mutable)   _note "session-name:${HOST}-$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}")" ;;
    macos)   _note "session-name:${HOST}-macos" ;;
    windows) _note "session-name:${HOST}-windows" ;;
    *)       _note "session-name:${HOST}-unknown" ;;
esac

# ---- 1. platform branch, or a work ref ------------------------------------
case "$REGIME" in
    linux-*) want=linux-next ;;
    macos)   want=osx-next ;;
    windows) want=windows-next ;;
    *)       want="" ;;
esac
branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"
case "$branch" in
    work/*)
        # ORDER 1317-9ugn (methodology work_ref_lane, 1315-4a7j): a work ref is
        # where a host WORKS. It is a correct place to be, never a todo; the
        # note is so the operator sees which order the checkout is on.
        _note "branch:$branch"
        _ok "branch:work-ref:$branch" ;;
    *)
        if [ -z "$want" ]; then
            case "$branch" in
                linux-next|osx-next|windows-next) _ok "branch:$branch" ;;
                *) _todo "branch:seeded-off-a-platform-branch:$branch:git checkout <linux-next|osx-next|windows-next>" ;;
            esac
        elif [ "$branch" = "$want" ]; then
            _ok "branch:$branch"
        else
            _todo "branch:$branch:git checkout $want"
        fi ;;
esac

# ---- 2. hooks ----------------------------------------------------------------
gitdir="${JOIN_FLEET_GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null || echo .git)}"
hook="$gitdir/hooks/pre-push"
hv=""
[ -f "$hook" ] && hv="$(grep -o -m1 -E 'tillandsias-pre-push-v[0-9]+' "$hook" 2>/dev/null || true)"
if [ -n "$hv" ]; then
    _ok "hooks:$hv"
else
    _todo "hooks:scripts/install-hooks.sh"
fi

# ---- 2b. rerere (1317-9ugn: a work ref merges trunk more than once) ---------
# `git config --get` reads the checkout's effective value (local over global);
# the remedy is the local setting, so a fixture can pin both outcomes.
if [ "$(git config --get rerere.enabled 2>/dev/null || true)" = "true" ]; then
    _ok "rerere"
else
    _todo "rerere:git config rerere.enabled true"
fi

# ---- 3. builder toolbox (Linux bare metal only) ----------------------------
case "$REGIME" in
    linux-*)
        if command -v toolbox >/dev/null 2>&1; then
            tl="$(toolbox list --containers 2>/dev/null || true)"
            case "$tl" in
                *tillandsias-builder*) _ok "toolbox:tillandsias-builder" ;;
                *) _todo "toolbox:scripts/with-tillandsias-builder.sh true" ;;
            esac
        else
            _todo "toolbox:no-toolbox-command:install toolbox (methodology toolbox_first_scripts)"
        fi ;;
    *) _skip "toolbox:$REGIME" ;;
esac

# ---- 4. plan binary resolves ------------------------------------------------
PB=""
if [ -f "$ROOT/scripts/plan-binary-probe.sh" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/scripts/plan-binary-probe.sh"
    PB="$(resolve_plan_binary 2>/dev/null || true)"
fi
if [ -n "$PB" ] && [ -x "$PB" ]; then
    _ok "plan-binary:$PB"
else
    _todo "plan-binary:scripts/cycle-preflight.sh"
fi

# ---- 5. plan binary current (the 1287-h6qn content-hash lane) --------------
if [ "$PROBES" != "1" ]; then
    _skip "plan-binary-current:probes-disabled"
elif [ -z "$PB" ]; then
    _skip "plan-binary-current:no-binary"
elif [ -x "$ROOT/scripts/check-plan-binary-current.sh" ]; then
    out="$(bash "$ROOT/scripts/check-plan-binary-current.sh" 2>&1)"; rc=$?
    last="$(printf '%s\n' "$out" | tail -1)"
    if [ "$rc" = 0 ]; then _ok "plan-binary-current"; else _todo "plan-binary-current:${last}"; fi
else
    _skip "plan-binary-current:no-checker"
fi

# ---- 6. credential channel (982-sguu: blocked = stop and report) -----------
if [ "$PROBES" != "1" ]; then
    _skip "credential-channel:probes-disabled"
elif [ -x "$ROOT/scripts/check-credential-channel.sh" ]; then
    out="$(bash "$ROOT/scripts/check-credential-channel.sh" 2>&1)"; rc=$?
    verdict="$(printf '%s\n' "$out" | grep -E -m1 -e '^(ok|blocked|skip):' || printf '%s\n' "$out" | tail -1)"
    if [ "$rc" = 0 ]; then _ok "credential-channel:${verdict}"; else _todo "credential-channel:${verdict}:stop-and-report"; fi
else
    _skip "credential-channel:no-guard"
fi

# ---- 7. daily maintenance (bare metal; forges exempt by the gate itself) ---
if [ -x "$ROOT/scripts/check-daily-maintenance.sh" ]; then
    out="$(TILLANDSIAS_HOST_KIND="${TILLANDSIAS_HOST_KIND:-}" bash "$ROOT/scripts/check-daily-maintenance.sh" check 2>&1)"; rc=$?
    last="$(printf '%s\n' "$out" | tail -1)"
    case "$last" in
        skip:forge-exempt) _skip "daily-maintenance:forge-exempt" ;;
        ok:*) _ok "daily-maintenance:${last}" ;;
        *) _todo "daily-maintenance:${last}:run the Start Of Day gate (skills/meta-orchestration)" ;;
    esac
else
    _skip "daily-maintenance:no-gate"
fi

# ---- 8. experts (ask, don't read: the MCP experts must answer) -------------
if [ "$PROBES" != "1" ]; then
    _skip "experts:probes-disabled"
elif [ -x "$ROOT/scripts/check-mcp-expert-health.sh" ]; then
    out="$(bash "$ROOT/scripts/check-mcp-expert-health.sh" 2>&1)"; rc=$?
    last="$(printf '%s\n' "$out" | tail -1)"
    if [ "$rc" = 0 ]; then _ok "experts:${last}"; else _todo "experts:${last}:scripts/dev-host-experts.sh"; fi
else
    _skip "experts:no-probe"
fi

# ---- 9. substrate (bare-metal Linux: ./skills/initialize-bare-metal-host) --
case "$REGIME" in
    linux-*)
        if [ "$PROBES" != "1" ]; then
            _skip "substrate:probes-disabled"
        elif [ -x "$ROOT/scripts/check-bare-metal-host-initialized.sh" ]; then
            out="$(bash "$ROOT/scripts/check-bare-metal-host-initialized.sh" 2>&1)"; rc=$?
            last="$(printf '%s\n' "$out" | tail -1)"
            case "$last" in
                skip:*) _skip "substrate:${last}" ;;
                *) if [ "$rc" = 0 ]; then _ok "substrate:${last}"; else _todo "substrate:${last}"; fi ;;
            esac
        else
            _skip "substrate:1312-i6da-not-landed"
        fi ;;
    forge)   _skip "substrate:forge-has-no-podman" ;;
    *)       _skip "substrate:${REGIME}:the-tray-provisions" ;;
esac

# ---- 10. capability row (846-idhn: a first-ever host row enters the base) --
caprow=0
if [ -f "$ROOT/plan/index.yaml" ] && grep -q -E -e "host_id:[[:space:]]*${HOST}([[:space:]]|$)" "$ROOT/plan/index.yaml" 2>/dev/null; then
    caprow=1
fi
if [ "$caprow" = 1 ]; then
    _ok "capability-row:$HOST"
else
    case "$REGIME" in
        forge) _skip "capability-row:forge-rows-belong-to-the-host" ;;
        *) _todo "capability-row:846-idhn:add a capabilities row for host_id ${HOST} to plan/index.yaml (never as a fragment)" ;;
    esac
fi

# ---- verdict ----------------------------------------------------------------
if [ "$todos" = 0 ]; then
    echo "ok:join-the-fleet:${HOST}:${REGIME}:ran=${ran} skipped=${skipped}"
    exit 0
fi
echo "todo:join-the-fleet:${HOST}:${REGIME}:todos=${todos} ran=${ran} skipped=${skipped}"
exit 1
