#!/bin/sh
# @trace spec:forge-environment-discoverability
# @trace order:569 (forge-experts-capability-honesty)
# @trace plan/issues/claude-mcp-expert-validation-2026-08-01.md §2, §5B
# @trace plan/issues/mcp-server-performance-and-discoverability-audit-2026-08-01.md §2.1
#
# Forge-side EXPERT CAPABILITY SKEW state.
#
# THE FAILURE THIS EXISTS TO NAME
#
# `experts: ready` means the launch BUILD FINISHED. It has never meant the
# binary can answer. Order 531 ran a forge whose mounted checkout was a
# pre-expert `main` snapshot: the launch dutifully compiled that checkout,
# installed the artifact, stamped `ready`, and then every `plan_answer` came back
# `confidence=unsupported` while every health signal read green (validation:
# claude-mcp-expert-validation-2026-08-01 §2, hash-proven). A capability STAMP
# alone would not have been enough either, because the operator's question is
# not "is it capable" but three questions:
#
#   1. what can I use RIGHT NOW, in this session?
#   2. what would I get if this forge were RELAUNCHED — i.e. what do the sources
#      in the mounted checkout actually provide?
#   3. is my current work therefore BLOCKED until that relaunch?
#
# Question 2 is the one nothing answered before. Local edits to the expert crate
# are invisible to the running binary but WILL be present on the next forge run,
# so an agent that cannot see the difference either abandons work that is
# actually one relaunch away, or waits forever for a capability that is never
# coming.
#
# WHY A SEPARATE FILE: lib-common.sh cannot be sourced outside the forge image
# (it hard-fails on the vendor CA bundle) and forge-plan.sh is an MCP server on a
# live stdio socket, so neither can own this logic testably. This helper has no
# import-time side effects, uses no jq and no python, and can be executed
# directly, so litmus:expert-capability-skew-honesty exercises EVERY branch of
# the grammar against fixture binaries on the host.
#
# PINNED GRAMMAR — the machine line agents branch on (peer of `inference_state=`
# and `experts_state=`; same discipline, closed vocabulary, no indeterminate
# state):
#
#   expert_capability: now=<csv|none|stale-binary> after_relaunch=<csv|none> \
#                      skew=<none|pending-build|relaunch-required|relaunch-regresses> \
#                      blocked_capabilities=<csv|-> lost_on_relaunch=<csv|->
#
# FIELD VOCABULARIES (all CLOSED):
#
#   now              the subcommand set the INSTALLED binary reports for itself
#                    (`tillandsias-plan capabilities`, embedded at compile time).
#                    `none`         no binary resolved at all.
#                    `stale-binary` a binary IS installed but does not carry the
#                                   capability manifest, i.e. it predates order
#                                   569. Its capabilities are UNKNOWABLE, not
#                                   assumed — so nothing it offers is counted.
#                                   This is a named fact, not an indeterminate
#                                   state: the action is unambiguous (rebuild or
#                                   relaunch).
#   after_relaunch   the subcommand set the MOUNTED CHECKOUT would build, read
#                    straight out of crates/tillandsias-plan/capabilities.txt.
#                    No cargo, no build, no assumption. `none` when the checkout
#                    carries no manifest (not a plan-expert project, an older
#                    checkout, or no checkout resolved).
#
#   skew — THE LOAD-BEARING FIELD, because two of its values demand OPPOSITE
#   actions and conflating them is the whole defect:
#     none                the running binary already covers everything the
#                         checkout provides. Nothing to wait for, nothing to
#                         relaunch for.
#     pending-build       the checkout provides more AND a build is in flight
#                         (experts_state=building). WAIT AND RETRY — capability
#                         legitimately INCREASES mid-session, because
#                         ensure_forge_experts builds asynchronously after
#                         launch.
#     relaunch-required   the checkout provides more and NO build will deliver
#                         it in this session. Retrying is FUTILE. Relaunch the
#                         forge (or rebuild by hand). Telling an agent to wait
#                         here is telling it to wait forever.
#     relaunch-regresses  the running binary provides MORE than the checkout —
#                         a relaunch would REMOVE capability. Observed for real
#                         in the order-557 validation, which hand-installed a
#                         linux-next binary into a `main`-checkout forge. Do not
#                         relaunch; fix the checkout first.
#   Precedence when several apply: pending-build > relaunch-required >
#   relaunch-regresses > none. Missing capability is what BLOCKS work, so it
#   outranks a regression that has not happened yet; `lost_on_relaunch` still
#   reports the regression, so nothing is hidden by the precedence.
#
#   blocked_capabilities  after_relaunch minus now — what this session CANNOT do
#                         but a relaunch would provide. `-` when empty. This is
#                         the direct answer to question 3.
#   lost_on_relaunch      now minus after_relaunch — what a relaunch would TAKE
#                         AWAY. `-` when empty, and always `-` when
#                         after_relaunch=none (see below).
#
# `relaunch-regresses` AND `lost_on_relaunch` are deliberately suppressed when
# after_relaunch=none: "we found no manifest in the checkout" is not evidence of
# regression, and crying one would be a guess. The `after_relaunch=none` token is
# right there in the line, so the reader can see exactly why.
#
# CONTRACT: ALWAYS returns 0, never writes to stdout when sourced, never runs
# longer than the probe timeout. The expert lane is OPTIONAL (order 486
# warn-and-continue) — a capability probe that breaks a forge launch is strictly
# worse than the skew it was measuring.

# Where the checkout keeps its manifest. MUST stay identical to the path
# `include_str!` embeds in crates/tillandsias-plan/src/main.rs — if these two
# disagree, `after_relaunch` silently reads `none` on a perfectly good checkout
# and every skew verdict collapses to `none`. Pinned by
# litmus:expert-capability-skew-honesty.
TILLANDSIAS_EXPERT_MANIFEST_REL="crates/tillandsias-plan/capabilities.txt"

# _tec_clean_manifest — read a manifest-shaped stream, emit sorted unique tokens.
# Anything that is not a bare `[a-z][a-z0-9-]*` token is DROPPED, and the caller
# treats an empty result as "no manifest". That is what makes a pre-569 binary's
# usage dump (prose, spaces, capitals) fail the shape test instead of being
# mistaken for a capability list.
_tec_clean_manifest() {
    awk '
        { sub(/#.*/, "") }
        { gsub(/[ \t\r]+/, "") }
        /^[a-z][a-z0-9-]*$/ { print }
    ' 2>/dev/null | sort -u
}

# _tec_join — newline-separated tokens -> csv, or the supplied empty-marker.
_tec_join() {
    _tec_j_empty="$1"
    _tec_j_out="$(tr '\n' ',' 2>/dev/null | sed 's/,*$//' 2>/dev/null)" || _tec_j_out=""
    if [ -z "$_tec_j_out" ]; then
        printf '%s' "$_tec_j_empty"
    else
        printf '%s' "$_tec_j_out"
    fi
}

# tillandsias_expert_capability [<binary>] [<checkout>]
#
# <binary>   path to the installed tillandsias-plan (may be empty/absent).
# <checkout> the mounted project checkout (may be empty/absent).
#
# Sets TILLANDSIAS_EXPERT_CAP_{NOW,AFTER,SKEW,BLOCKED,LOST} and
# TILLANDSIAS_EXPERT_CAPABILITY_LINE.
tillandsias_expert_capability() {
    _tec_bin="${1:-}"
    _tec_checkout="${2:-}"
    TILLANDSIAS_EXPERT_CAP_NOW="none"
    TILLANDSIAS_EXPERT_CAP_AFTER="none"
    TILLANDSIAS_EXPERT_CAP_SKEW="none"
    TILLANDSIAS_EXPERT_CAP_BLOCKED="-"
    TILLANDSIAS_EXPERT_CAP_LOST="-"
    _tec_now_set=""
    _tec_after_set=""

    # ── what can I use RIGHT NOW ──────────────────────────────────────────
    # Asked of the ARTIFACT, never inferred from the checkout: that inference is
    # precisely the mistake `experts: ready` made.
    if [ -n "$_tec_bin" ] && [ -x "$_tec_bin" ]; then
        _tec_raw=""
        if command -v timeout >/dev/null 2>&1; then
            # A hung or wedged binary must not stall a launch. 5s is ~1000x the
            # measured cost of this call (sub-5ms in the order-557 timings).
            _tec_raw="$(timeout 5 "$_tec_bin" capabilities 2>/dev/null)" || _tec_raw=""
        else
            _tec_raw="$("$_tec_bin" capabilities 2>/dev/null)" || _tec_raw=""
        fi
        # Every substitution below carries an explicit `|| <fallback>`. Not
        # defensive noise: forge-plan.sh sources this under `set -euo pipefail`,
        # where ONE failing command in a pipeline inside `$( )` terminates the
        # MCP server mid-request and the client sees a dropped connection
        # instead of a diagnostic. The fallbacks keep every failure inside the
        # grammar.
        _tec_now_set="$(printf '%s\n' "$_tec_raw" | _tec_clean_manifest)" || _tec_now_set=""
        if [ -z "$_tec_now_set" ]; then
            # The binary exists but produced no manifest. A pre-569 artifact
            # prints usage here — and the one order 531 shipped printed it on
            # STDOUT and exited 0, so a caller checking only the exit status
            # would have read incapability as success. Shape, not status, is
            # what decides.
            TILLANDSIAS_EXPERT_CAP_NOW="stale-binary"
        else
            TILLANDSIAS_EXPERT_CAP_NOW="$(printf '%s\n' "$_tec_now_set" | _tec_join none)" || TILLANDSIAS_EXPERT_CAP_NOW="none"
        fi
    fi

    # ── what would a RELAUNCH give me ─────────────────────────────────────
    # Read from the checkout, so it reflects uncommitted local edits to the
    # expert crate — the case the operator named: work that is undiscoverable
    # now but present on the next forge run.
    if [ -n "$_tec_checkout" ] && [ -r "$_tec_checkout/$TILLANDSIAS_EXPERT_MANIFEST_REL" ]; then
        _tec_after_set="$(_tec_clean_manifest < "$_tec_checkout/$TILLANDSIAS_EXPERT_MANIFEST_REL")" || _tec_after_set=""
        if [ -n "$_tec_after_set" ]; then
            TILLANDSIAS_EXPERT_CAP_AFTER="$(printf '%s\n' "$_tec_after_set" | _tec_join none)" || TILLANDSIAS_EXPERT_CAP_AFTER="none"
        fi
    fi

    # ── the two set differences ───────────────────────────────────────────
    _tec_missing=""
    for _tec_t in $_tec_after_set; do
        if ! _tec_has "$_tec_t" "$_tec_now_set"; then
            _tec_missing="${_tec_missing}${_tec_t}
"
        fi
    done
    _tec_lost=""
    for _tec_t in $_tec_now_set; do
        if ! _tec_has "$_tec_t" "$_tec_after_set"; then
            _tec_lost="${_tec_lost}${_tec_t}
"
        fi
    done
    TILLANDSIAS_EXPERT_CAP_BLOCKED="$(printf '%s' "$_tec_missing" | _tec_join -)" || TILLANDSIAS_EXPERT_CAP_BLOCKED="-"
    # A checkout with NO manifest is not evidence that a relaunch would take
    # anything away — we simply have nothing to compare against. Reporting the
    # whole capability set as "lost" there would be a guess dressed as a fact,
    # and an alarming one. `after_relaunch=none` is already in the line, so the
    # reader can see exactly why this field is empty.
    if [ "$TILLANDSIAS_EXPERT_CAP_AFTER" = "none" ]; then
        TILLANDSIAS_EXPERT_CAP_LOST="-"
    else
        TILLANDSIAS_EXPERT_CAP_LOST="$(printf '%s' "$_tec_lost" | _tec_join -)" || TILLANDSIAS_EXPERT_CAP_LOST="-"
    fi

    # ── the verdict ───────────────────────────────────────────────────────
    if [ "$TILLANDSIAS_EXPERT_CAP_BLOCKED" != "-" ]; then
        if _tec_build_in_flight; then
            TILLANDSIAS_EXPERT_CAP_SKEW="pending-build"
        else
            TILLANDSIAS_EXPERT_CAP_SKEW="relaunch-required"
        fi
    elif [ "$TILLANDSIAS_EXPERT_CAP_LOST" != "-" ] \
        && [ "$TILLANDSIAS_EXPERT_CAP_AFTER" != "none" ]; then
        TILLANDSIAS_EXPERT_CAP_SKEW="relaunch-regresses"
    fi

    _tillandsias_expert_capability_emit
    return 0
}

# _tec_has <token> <newline-separated-set>
_tec_has() {
    _tec_h_needle="$1"
    for _tec_h_t in $2; do
        if [ "$_tec_h_t" = "$_tec_h_needle" ]; then
            return 0
        fi
    done
    return 1
}

# _tec_build_in_flight — is ensure_forge_experts still running?
#
# THE DISTINCTION THIS FUNCTION CARRIES. `pending-build` says "wait, it is
# coming"; `relaunch-required` says "retrying is futile". They are opposite
# instructions, and only this probe separates them. If it is deleted or made to
# always answer false, every mid-build forge tells its agent to relaunch
# needlessly; if it always answers true, an agent on a checkout that can never
# build the capability waits forever. Both are worse than the skew itself.
_tec_build_in_flight() {
    _tec_state_dir="${FORGE_EXPERTS_STATE_DIR:-/dev/shm/tillandsias-experts}"
    [ -r "$_tec_state_dir/state" ] || return 1
    _tec_state="$(cat "$_tec_state_dir/state" 2>/dev/null)" || _tec_state=""
    [ "$_tec_state" = "building" ] || return 1
    # A `building` stamp older than the budget is an ABANDONED build, not an
    # in-flight one — the same rule forge_experts_state_line applies before it
    # renders degraded(build-abandoned-after-Ns). Without this, an OOM-killed
    # builder pins the verdict at "wait" for the rest of the session.
    _tec_started="$(cat "$_tec_state_dir/started_at" 2>/dev/null)" || _tec_started=0
    case "$_tec_started" in
        '' | *[!0-9]*) _tec_started=0 ;;
    esac
    _tec_now_ts="$(date +%s 2>/dev/null)" || _tec_now_ts=0
    case "$_tec_now_ts" in
        '' | *[!0-9]*) _tec_now_ts=0 ;;
    esac
    _tec_elapsed=$((_tec_now_ts - _tec_started))
    [ "$_tec_elapsed" -ge 0 ] || _tec_elapsed=0
    [ "$_tec_elapsed" -le "${FORGE_EXPERTS_BUILD_BUDGET_SECS:-300}" ] || return 1
    return 0
}

# Is the spec RAG index actually built? (order 760-hzi4 / 712-r5x8.)
#
# WHY THIS FIELD EXISTS. Every other field on this line reports SUBCOMMANDS —
# what the binary can be asked. `spec-retrieve` and `spec-envelope` are
# compiled in, so the line has always advertised them truthfully while
# `spec_answer` refused every question for want of DATA. A caller reading the
# capability line therefore concluded the spec expert was usable when it could
# not answer anything. That is the same behavioural-vs-subcommand drift as
# 760-nwzr: a capability is what the system can DO, not what it can be asked.
#
# Uses the same predicate the answer path uses (forge-plan.sh: both
# chunks.jsonl and vectors.jsonl non-empty), so the line cannot claim an index
# the answer path would reject. Order 801-a2by moved the index into the DURABLE
# tier, so it resolves the path with the same shared block forge-plan.sh and
# the producer use — a capability line computed from a different path than the
# answer path opens would claim `spec_index=present` for an index spec_answer
# then refuses, which is worse than either being wrong alone.
#
# >>> BEGIN spec-index resolution (801-a2by) — BYTE-IDENTICAL in three files:
#       scripts/spec-index-ensure.sh                     (the producer)
#       images/default/config-overlay/mcp/forge-plan.sh  (spec_answer)
#       images/default/lib-expert-capability.sh          (the capability line)
#     A producer that writes where the reader does not look builds an index that
#     is silently ABSENT rather than loudly missing, which is how the embedding
#     step stayed unwritten on every host for weeks. Agreement is proven
#     BEHAVIOURALLY — the block is extracted from each file and executed under
#     one env — by scripts/check-spec-index-resolution-agreement.sh. Edit all
#     three together or that guard goes red.
#
#     Precedence, highest first:
#       1. FORGE_SPEC_INDEX_DIR   — an EXACT serving directory, honoured
#          verbatim so the 789-nc2s stale-override diagnostics keep working.
#       2. FORGE_SPEC_INDEX_ROOT  — an explicit durable root. The forge launcher
#          injects this (/opt/tillandsias/spec-index, the read-only volume
#          mount), so nothing inside the enclave ever shells out to podman.
#       3. The project's podman named volume — what makes the host builder and
#          every forge share ONE store. INSPECT only: creating it is the
#          producer's job, never a reader's.
#       4. $XDG_CACHE_HOME/tillandsias/spec-index — durable, podman-free, for
#          hosts and harnesses with no podman (macOS/Windows bare metal).
#     Every podman step is fail-soft: a hiccup degrades to (4), never to an
#     error. POSIX sh — lib-expert-capability.sh is not bash.
_tillandsias_spec_index_paths() {
    _tsi_root="${FORGE_SPEC_INDEX_ROOT:-}"
    if [ -z "$_tsi_root" ] && [ "${TILLANDSIAS_SPEC_INDEX_NO_PODMAN:-0}" != "1" ] \
       && command -v podman >/dev/null 2>&1; then
        _tsi_vol="${TILLANDSIAS_SPEC_INDEX_VOLUME:-tillandsias-spec-index-${TILLANDSIAS_PROJECT:-tillandsias}}"
        _tsi_root="$(podman volume inspect -f '{{.Mountpoint}}' "$_tsi_vol" 2>/dev/null)" || _tsi_root=""
        if [ -z "$_tsi_root" ] || [ ! -d "$_tsi_root" ]; then _tsi_root=""; fi
    fi
    if [ -z "$_tsi_root" ]; then
        _tsi_root="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/spec-index"
    fi
    _tsi_dir="${FORGE_SPEC_INDEX_DIR:-}"
    if [ -z "$_tsi_dir" ]; then
        # `current` is written last and RENAMED into place, so it never names a
        # half-published entry. With no pointer yet, name the ROOT so a refusal
        # points at a real directory a human can inspect.
        _tsi_fp="$(cat "$_tsi_root/current" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$_tsi_fp" ]; then _tsi_dir="$_tsi_root/$_tsi_fp"; else _tsi_dir="$_tsi_root"; fi
    fi
    printf '%s\n%s\n' "$_tsi_root" "$_tsi_dir"
}
# <<< END spec-index resolution (801-a2by)

_tillandsias_expert_spec_index_state() {
    _tec_index_dir="$(_tillandsias_spec_index_paths | sed -n 2p)"
    if [ -s "$_tec_index_dir/chunks.jsonl" ] && [ -s "$_tec_index_dir/vectors.jsonl" ]; then
        printf 'present\n'
    else
        printf 'absent\n'
    fi
}

# _tillandsias_expert_embed_state — ORDER 712-r5x8.
#
# The 2026-08-13 in-forge finding: spec_answer refused (correctly,
# confidence=unsupported) in a fresh forge because the embedding endpoint is
# not provisioned at launch — but NOTHING advertised that, so the delegate
# debugged the expert instead of the endpoint. This field makes the
# degradation DISCOVERABLE: `unset` means the launch never wired
# TILLANDSIAS_EMBED_ENDPOINT (the fresh-forge gap itself); `unreachable`
# means it is wired but not answering (probe bounded at 3s so a dead
# endpoint cannot stall a capability call); `reachable` means spec_answer's
# embedding half will actually serve. GET <ep>/models is the cheap
# OpenAI-shape liveness probe the /v1 base guarantees.
_tillandsias_expert_embed_state() {
    _tec_ep="${TILLANDSIAS_EMBED_ENDPOINT:-}"
    if [ -z "$_tec_ep" ]; then
        printf 'unset\n'
        return 0
    fi
    if command -v curl >/dev/null 2>&1 \
        && curl -fsS -m 3 -o /dev/null "$_tec_ep/models" 2>/dev/null; then
        printf 'reachable\n'
    else
        printf 'unreachable\n'
    fi
}

_tillandsias_expert_capability_emit() {
    TILLANDSIAS_EXPERT_CAP_SPEC_INDEX="$(_tillandsias_expert_spec_index_state)"
    TILLANDSIAS_EXPERT_CAP_EMBED="$(_tillandsias_expert_embed_state)"
    # spec_index and embed_endpoint are APPENDED, never inserted: the
    # existing fields are matched by substring in
    # litmus:capability-manifest-guard and
    # litmus:expert-capability-skew-honesty, so growing the line at the end
    # is additive for every current reader.
    TILLANDSIAS_EXPERT_CAPABILITY_LINE="expert_capability: now=${TILLANDSIAS_EXPERT_CAP_NOW} after_relaunch=${TILLANDSIAS_EXPERT_CAP_AFTER} skew=${TILLANDSIAS_EXPERT_CAP_SKEW} blocked_capabilities=${TILLANDSIAS_EXPERT_CAP_BLOCKED} lost_on_relaunch=${TILLANDSIAS_EXPERT_CAP_LOST} spec_index=${TILLANDSIAS_EXPERT_CAP_SPEC_INDEX} embed_endpoint=${TILLANDSIAS_EXPERT_CAP_EMBED}"
}

# tillandsias_expert_capability_advice — the one-sentence action for the verdict.
# Kept beside the vocabulary it explains so a new skew value cannot be added
# without an action being written for it.
tillandsias_expert_capability_advice() {
    case "${1:-none}" in
        pending-build)
            printf 'TRANSIENT: the expert build is still running and WILL deliver the missing capabilities in this session — wait a few seconds and retry the same call.\n'
            ;;
        relaunch-required)
            printf 'BLOCKED PENDING RELAUNCH: the mounted checkout provides capabilities this running binary does not, and no build in this session will deliver them — retrying is futile. Relaunch the forge, or rebuild by hand: cargo build --release -p tillandsias-plan && install -m0755 target/release/tillandsias-plan "$HOME/.local/bin/tillandsias-plan".\n'
            ;;
        relaunch-regresses)
            printf 'DO NOT RELAUNCH YET: the running binary provides MORE than the mounted checkout, so a relaunch would REMOVE capability. Move the checkout to a base that carries the expert sources first.\n'
            ;;
        *)
            printf 'No capability skew: everything the mounted checkout provides is already available in this session.\n'
            ;;
    esac
}

# Run directly (litmus / operator diagnostics) vs sourced (lib-common.sh,
# forge-plan.sh): when this file IS the program, $0 ends in its own basename.
case "${0##*/}" in
    lib-expert-capability.sh)
        tillandsias_expert_capability "$@"
        printf '%s\n' "$TILLANDSIAS_EXPERT_CAPABILITY_LINE"
        tillandsias_expert_capability_advice "$TILLANDSIAS_EXPERT_CAP_SKEW"
        ;;
esac
