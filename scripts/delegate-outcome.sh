#!/usr/bin/env bash
# delegate-outcome.sh — the host-readable disposition channel for in-forge
# delegates (order 690-2kwd). A stage-0 delegate runs in an ephemeral forge and
# can vanish with no trace; the host loop must still be able to tell, at cycle
# end, whether it finished-with-evidence, is still-running, or died-without-
# outcome — and a silent death must file itself within one cycle.
#
# The channel has two halves:
#   1. A DURABLE HOST-OWNED REGISTRY (survives forge teardown, survives the
#      per-cycle boundary tmp sweep) recording each launch: id, assigned order,
#      launch time, and how to probe the delegate's liveness.
#   2. A HOST-GREPPABLE LEDGER TOKEN the delegate writes as its mandatory exit
#      evidence: an event on its assigned order whose summary contains the
#      literal `delegate-outcome:<id>:<disposition>`. Because it rides the
#      ledger, it reaches the host by ordinary `git fetch` — no live query
#      against the delegate's churning forge stack (criterion 3: host reads the
#      ledger, not the delegate's recycled containers).
#
# Disposition grammar (reconcile stdout, one line, pinned by the litmus):
#   outcome:finished-with-evidence <id> <order> <token-disposition>
#   outcome:still-running          <id> <order>
#   outcome:died-without-outcome   <id> <order>
#
# Subcommands:
#   register --id ID --order ORDER [--alive-cmd CMD] [--ledger-glob GLOB]
#   reconcile --id ID
#   sweep [--dry-run]        # reconcile every registered run; file silent deaths
#   token ID DISPOSITION     # print the exact ledger token a delegate must emit
#
# State dir (durable, overridable for tests):
#   $TILLANDSIAS_DELEGATE_STATE  (default: ${XDG_STATE_HOME:-$HOME/.local/state}/tillandsias/delegate-runs)
set -euo pipefail

STATE_DIR="${TILLANDSIAS_DELEGATE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/tillandsias/delegate-runs}"
# Where the delegate's evidence token lands. Default scans the committed ledger
# and its append-only fragments; a test can point this at a fixture tree.
LEDGER_GLOB_DEFAULT="${TILLANDSIAS_DELEGATE_LEDGER_GLOB:-plan/index.yaml plan/index.d/*.yaml}"

die() { echo "delegate-outcome: $*" >&2; exit 2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

rec_path() { printf '%s/%s.rec' "$STATE_DIR" "$1"; }

rec_get() { # rec_get <file> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

cmd_token() { # token <id> <disposition>
  [ $# -eq 2 ] || die "usage: token <id> <disposition>"
  printf 'delegate-outcome:%s:%s\n' "$1" "$2"
}

cmd_register() {
  local id="" order="" alive_cmd="" ledger_glob=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="$2"; shift 2;;
      --order) order="$2"; shift 2;;
      --alive-cmd) alive_cmd="$2"; shift 2;;
      --ledger-glob) ledger_glob="$2"; shift 2;;
      *) die "register: unknown arg $1";;
    esac
  done
  [ -n "$id" ] || die "register: --id required"
  [ -n "$order" ] || die "register: --order required"
  # Default liveness probe: is any process matching the delegate id alive?
  [ -n "$alive_cmd" ] || alive_cmd="pgrep -f $id"
  mkdir -p "$STATE_DIR"
  {
    printf 'id=%s\n' "$id"
    printf 'order=%s\n' "$order"
    printf 'launched_at=%s\n' "$(now_iso)"
    printf 'alive_cmd=%s\n' "$alive_cmd"
    printf 'ledger_glob=%s\n' "${ledger_glob:-$LEDGER_GLOB_DEFAULT}"
    printf 'filed=no\n'
  } > "$(rec_path "$id")"
  echo "registered:$id $order"
}

# Look for the delegate's evidence token anywhere in the ledger glob.
# Prints the disposition suffix (done|blocked|progress|...) if found; empty if not.
#
# Robustness (order 690-2kwd): a MISSING token is the whole point of the
# died-without-outcome path, so a no-match must NOT abort. Two hazards handled:
#   1. An empty/unset glob must never reach `grep -r` with no file args — that
#      makes grep read STDIN (hangs a real run) or recurse the CWD. We return
#      "no token" instead of running grep at all.
#   2. The glob is expanded to REAL files only; an unmatched pattern (nullglob
#      off) is dropped rather than handed to grep as a bogus path. grep finding
#      nothing then exits 1 under `set -e`/pipefail, so the pipeline is guarded
#      with `|| true` — a no-match is a normal, non-fatal empty result.
find_token() { # find_token <id> <ledger_glob>
  local id="$1"; shift
  local glob="$*"
  [ -n "$glob" ] || return 0   # empty glob -> no token; never grep bare stdin
  local files=() pat f
  # shellcheck disable=SC2086
  for pat in $glob; do            # word-split the stored glob spec
    for f in $pat; do             # expand each pattern; keep only real files
      [ -f "$f" ] && files+=("$f")
    done
  done
  [ "${#files[@]}" -gt 0 ] || return 0   # nothing on disk to search -> no token
  grep -rhoE "delegate-outcome:${id}:[A-Za-z0-9_-]+" "${files[@]}" 2>/dev/null \
    | head -1 | sed "s/^delegate-outcome:${id}://" || true
}

is_alive() { # is_alive <alive_cmd>
  # Runs the recorded probe; exit 0 => alive. Kept a cheap LOCAL check (pgrep),
  # never a live query into the delegate's ephemeral forge stack.
  sh -c "$1" >/dev/null 2>&1
}

cmd_reconcile() {
  local id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="$2"; shift 2;;
      *) die "reconcile: unknown arg $1";;
    esac
  done
  [ -n "$id" ] || die "reconcile: --id required"
  local rec; rec="$(rec_path "$id")"
  [ -f "$rec" ] || die "reconcile: no registered run for id=$id"
  local order glob alive_cmd
  order="$(rec_get "$rec" order)"
  glob="$(rec_get "$rec" ledger_glob)"
  alive_cmd="$(rec_get "$rec" alive_cmd)"

  local disp
  disp="$(find_token "$id" "$glob")"
  if [ -n "$disp" ]; then
    echo "outcome:finished-with-evidence $id $order $disp"
    return 0
  fi
  if is_alive "$alive_cmd"; then
    echo "outcome:still-running $id $order"
    return 0
  fi
  echo "outcome:died-without-outcome $id $order"
  return 0
}

# Auto-file a silent death as an append-only ledger fragment (criterion 2).
file_silent_death() { # file_silent_death <id> <order> [--dry-run]
  local id="$1" order="$2" dry="${3:-}"
  local next_order fragment ts realts
  if [ "$dry" = "--dry-run" ]; then
    echo "would-file:died-without-outcome $id $order"
    return 0
  fi
  # Order 721-nyev: a hardcoded target/ path selects the Linux ELF on a shared
  # Windows/WSL checkout. Resolve by execution.
  . "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
  _pbin="$(resolve_plan_binary || true)"
  next_order="$([ -n "$_pbin" ] && "$_pbin" next-order 2>/dev/null | head -1)"
  [ -n "$next_order" ] || die "sweep: could not allocate next-order to file silent death"
  ts="$(date -u +%Y%m%dt%H%M%sz)"
  realts="$(now_iso)"
  fragment="plan/index.d/${ts}-delegate-silent-death-${id}.yaml"
  cat > "$fragment" <<YAML
# Ledger fragment — append-only, IMMUTABLE once written.
# Auto-filed by scripts/delegate-outcome.sh sweep (order 690-2kwd).
packets:

  - packet_id: delegate-silent-death-${id}
    order: ${next_order}
    status: ready
    desired_release: v0.6
    priority: p3
    title: "In-forge delegate ${id} (assigned ${order}) died without a recorded outcome"
    kind: finding
    deliverable: root-cause why delegate ${id} vanished with no ledger token; harden the surgical prompt or the forge lifecycle
    depends_on: []
    pickup_role: linux
    capability_tags: [delegation, forge, observability, finding]
    context: >
      Auto-filed by the delegate-outcome channel: delegate ${id}, launched
      against order ${order}, left NO delegate-outcome ledger token and its
      liveness probe reports it gone. Per the methodology, a delegate session
      that ends without a recorded outcome is itself a finding; this is that
      finding, captured within one host cycle so the silent death is never
      mistaken for a clean finish.
    exit_criteria:
      - "the cause of delegate ${id}'s silent exit is identified (prompt drift, forge teardown race, or harness crash) and recorded"
      - "a mitigation lands (tighter surgical prompt, liveness/keepalive, or a forge-side status) or this is consciously accepted with rationale"
    events:
      - type: filed
        ts: "${realts}"
        agent_id: delegate-outcome-sweep
        host: linux_mutable
        summary: "Auto-filed: delegate ${id} died without a recorded outcome (assigned ${order})."
YAML
  echo "filed:died-without-outcome $id $order $next_order $fragment"
}

cmd_sweep() {
  local dry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry="--dry-run"; shift;;
      *) die "sweep: unknown arg $1";;
    esac
  done
  [ -d "$STATE_DIR" ] || { echo "sweep:no-registered-runs"; return 0; }
  local any=0
  local rec id order line disp filed
  for rec in "$STATE_DIR"/*.rec; do
    [ -e "$rec" ] || continue
    any=1
    id="$(rec_get "$rec" id)"
    order="$(rec_get "$rec" order)"
    filed="$(rec_get "$rec" filed)"
    line="$(cmd_reconcile --id "$id")"
    echo "$line"
    case "$line" in
      outcome:died-without-outcome*)
        if [ "$filed" = "yes" ]; then
          echo "already-filed:$id $order"
        else
          file_silent_death "$id" "$order" "$dry"
          if [ -z "$dry" ]; then
            # mark filed so a later cycle does not double-file
            sed -i 's/^filed=no$/filed=yes/' "$rec"
          fi
        fi
        ;;
      outcome:finished-with-evidence*)
        # terminal + recorded: retire the record so it is not swept forever
        [ -z "$dry" ] && rm -f "$rec"
        ;;
    esac
  done
  [ "$any" = 1 ] || echo "sweep:no-registered-runs"
}

[ $# -ge 1 ] || die "usage: {register|reconcile|sweep|token} ..."
sub="$1"; shift
case "$sub" in
  register)  cmd_register "$@";;
  reconcile) cmd_reconcile "$@";;
  sweep)     cmd_sweep "$@";;
  token)     cmd_token "$@";;
  *) die "unknown subcommand: $sub";;
esac
