#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability
#
# spec-index-ensure.sh — build the spec RAG index so `spec_answer` can answer
# on a DEV host (orders 552 and 760-hzi4), into the DURABLE tier (801-a2by).
#
# WHAT WAS ACTUALLY MISSING. `tillandsias-plan spec-index` (the chunker) has
# existed since order 547 and produces chunks.jsonl in 25ms. `spec-retrieve`
# reads chunks.jsonl + vectors.jsonl. The EMBEDDING step between them — the
# thing that turns 9909 chunks into 9909 vectors — existed only as English
# prose inside forge-plan.sh's refusal message, on every host, in-forge
# included. So `spec_answer` refused everywhere, correctly and truthfully, for
# want of a producer nobody had written. This is that producer.
#
# It is deliberately SMALL, because the interesting part was never the code:
#   chunks.jsonl  (the binary already makes it)
#   -> POST each chunk's text to the SAME /v1/embeddings the query path uses
#   -> vectors.jsonl, one JSON float array per line, index-aligned with chunks
#
# ── ORDER 801-a2by: THE INDEX BELONGS TO THE DURABLE TIER ────────────────────
#
# It used to build into ${FORGE_EXPERTS_STATE_DIR}/spec-index — i.e. /dev/shm,
# which is TMPFS. In-forge that dies with the container; on bare metal it dies
# on reboot. Measured on macuahuitl: 9910 chunks, ~12 minutes cold, 0.048s warm
# (the fingerprint short-circuit below). So the EXPENSIVE path was being paid,
# over and over, for a cache that was thrown away — while the cheap path had
# existed all along and simply never had anything to hit.
#
# The operator's decomposition, which is the right one:
#   durable   : git-mirror, inference, expert index   <- outlives any forge
#   ephemeral : forge containers, N concurrent, freely destroyed
# The forge keeps every idempotence and ephemerality guarantee it has today. It
# simply stops OWNING state that outlives it. Its expert LIVENESS state (state,
# started_at, plan-source-hash, project-index) stays in tmpfs and is still
# pinned there by litmus:forge-experts-ephemerality-shape. Only the index — a
# pure function of the corpus, carrying no working-tree knowledge — moves.
#
# WHY A PODMAN NAMED VOLUME AND NOT A HOST BIND-MOUNT. The forge is enclave-only
# by spec (forge-offline); the host-checkout bind mount is a deliberate opt-in
# guard (order 437) and must not become the default fast path. A named volume is
# container-managed storage with ZERO host-$HOME reference — the same reasoning
# and the same mechanism `tillandsias-forge-cache-<project>` already uses, and
# the same reasoning 801-kqme gives for refusing to bind-mount the nix store.
# The forge mounts it READ-ONLY, so the ephemeral tier structurally cannot
# corrupt the durable tier: that is a mount mode, not a convention.
#
# CONTENT-ADDRESSED, SO CONCURRENCY IS THE NORMAL CASE AND NOT A HAZARD. The
# layout is keyed by the fingerprint this script already computed:
#   <root>/<fingerprint>/{chunks.jsonl,vectors.jsonl,.fingerprint}
#   <root>/current      -- a one-line file naming the last published fingerprint
# A published entry is IMMUTABLE. Readers therefore need NO lock: they resolve a
# fingerprint directory that is either wholly absent or wholly complete, and
# nothing ever rewrites one in place. Two harnesses on different commits get two
# entries instead of evicting each other — the old single-directory layout made
# them thrash, each rebuild costing the full twelve minutes.
#
# THE HIT IS CHECKED BEFORE THE LOCK IS TAKEN, which is the whole point of the
# packet. The old order (lock, then chunk, then compare) meant a forge launching
# while a builder held the lock got `skip:already-building` and no index AT ALL,
# even when its own corpus was already published and sitting right there. Now
# chunking (25ms) and the fingerprint comparison happen first, so a relaunch is
# a fingerprint HIT rather than a twelve-minute rebuild or an empty skip.
#
# NOT A BLANK CHEQUE ON SHARING — WHAT MAKES A SHARED INDEX SAFE TO TRUST.
# The fingerprint proves an entry describes corpus X. It does NOT prove corpus X
# is what the ASKING agent has checked out, so a caller at a different commit can
# read `path:45-49` in its own tree and get different bytes. Order 801-g9nn
# closes that: every published entry now records the commit it was built at in
# `.commit`, `spec-envelope --corpus-commit` stamps it onto each citation, and
# `verify-answer` re-reads the span at that commit — so a citation the caller
# cannot resolve is reported as `stale` with a fetch instruction instead of being
# indistinguishable from a fabrication.
#
# RESOLUTION IS COPIED FROM THE CONSUMER ON PURPOSE. The root, endpoint and
# model are resolved exactly as images/default/config-overlay/mcp/forge-plan.sh
# and images/default/lib-expert-capability.sh resolve them. A producer that
# writes where the reader does not look, or embeds with a model the query path
# does not use, builds an index that is silently wrong rather than absent — and
# an index that answers WRONGLY is far worse than one that refuses, because the
# refusal is typed and this would not be. The dev/runtime model split those
# variables encode is already settled (lib-dev-env.sh, checked by
# check-dev-embed-model-agreement.sh); the ROOT/serving-dir resolution is kept
# in step by check-spec-index-resolution-agreement.sh for the same reason.
#
# ORDER ALIGNMENT IS THE CORRECTNESS PROPERTY. vectors.jsonl line N must be the
# embedding of chunks.jsonl line N; spec-retrieve pairs them by position and
# refuses outright if the counts differ. Every batch is therefore checked for
# arity, and the entry is published ATOMICALLY (built in a staging dir, renamed
# into place) so no reader can ever observe a half-written index.
#
# Grammar (exactly one line on stdout):
#   ok:spec-index:fresh:<n>
#   ok:spec-index:built:<n>
#   skip:spec-index:<reason>        — no endpoint/binary; advisory, exit 0
#   blocked:spec-index:<reason>     — tried and failed; exit 1
#
# `skip:` exits 0 by design: a host with no inference endpoint is degraded, not
# broken, and the consumer already refuses in a typed, self-describing way.
#
# Usage:
#   scripts/spec-index-ensure.sh
#   scripts/spec-index-ensure.sh --where     # print the resolved tier, no build
set -uo pipefail

# Portable SHA-256 (851-28b5): coreutils sha256sum on Linux/forge/WSL; stock
# macOS before 13 ships only `shasum`. Identical "<hex>  <name>" output.
if command -v sha256sum >/dev/null 2>&1; then
    PORTABLE_SHA256=(sha256sum)
else
    PORTABLE_SHA256=(shasum -a 256)
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── DURABLE ROOT RESOLUTION ──────────────────────────────────────────────────
# The PROJECT NAME is an INPUT to the shared resolver below, and the builder is
# the one side that can derive it properly. The launcher names the volume from
# the project directory, so a git WORKTREE must resolve to its MAIN checkout's
# name or the host builder would fill `tillandsias-spec-index-<worktree-hash>`
# while every forge mounted `tillandsias-spec-index-tillandsias`. `git rev-parse
# --git-common-dir` is what distinguishes them: it points at the main
# checkout's .git from inside any linked worktree.
if [ -z "${TILLANDSIAS_PROJECT:-}" ]; then
    _gcd="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || _gcd=""
    case "$_gcd" in
        /*) TILLANDSIAS_PROJECT="$(basename "$(dirname "$_gcd")")" ;;
        *)  TILLANDSIAS_PROJECT="$(basename "$ROOT")" ;;
    esac
    export TILLANDSIAS_PROJECT
fi

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

# PRODUCER-ONLY: create the volume before resolving, so the first host build and
# the first forge land on the SAME store. A forge mounting a not-yet-created
# volume auto-creates an empty one, which would sit beside a populated cache dir
# and look exactly like a cold index. Readers never do this.
SPEC_INDEX_VOLUME="${TILLANDSIAS_SPEC_INDEX_VOLUME:-tillandsias-spec-index-${TILLANDSIAS_PROJECT:-tillandsias}}"
if [ -z "${FORGE_SPEC_INDEX_ROOT:-}" ] \
   && [ "${TILLANDSIAS_SPEC_INDEX_NO_PODMAN:-0}" != "1" ] \
   && command -v podman >/dev/null 2>&1; then
    podman volume inspect "$SPEC_INDEX_VOLUME" >/dev/null 2>&1 \
        || podman volume create "$SPEC_INDEX_VOLUME" >/dev/null 2>&1 || true
fi

INDEX_ROOT="$(_tillandsias_spec_index_paths | sed -n 1p)"

if [ "${1:-}" = "--where" ]; then
    printf 'spec-index:project=%s\n' "$TILLANDSIAS_PROJECT"
    printf 'spec-index:volume=%s\n' "$SPEC_INDEX_VOLUME"
    printf 'spec-index:root=%s\n' "$INDEX_ROOT"
    # ORDER 760-hzi4. `serving=` is the line every consumer parses and its shape
    # is unchanged. What is new is that this report no longer describes TWO
    # DIFFERENT DIRECTORIES as if they were one.
    #
    # The bug, measured on macuahuitl 2026-08-22: `serving=` is overridable to
    # an EXACT directory via FORGE_SPEC_INDEX_DIR, while `entries=` counted
    # $INDEX_ROOT — a different path. With a stale override this printed
    #   serving=/mnt/c/Users/bullo/.../target/spec-index      (does not exist)
    #   entries=3                                             (of the LOCAL root)
    # and a reader concludes the served directory holds three indices. It holds
    # nothing; it is not even a directory on this host. That misreading cost an
    # hour and produced a wrong conclusion about whether this host had an index
    # at all — the premise of this very packet.
    #
    # The BUILD path already refuses an unwritable destination loudly and names
    # FORGE_SPEC_INDEX_DIR and 789-nc2s while doing it. The QUERY path said
    # nothing, which is the "reports a verdict it could not compute" shape.
    _serving="$(_tillandsias_spec_index_paths | sed -n 2p)"
    printf 'spec-index:serving=%s\n' "$_serving"
    if [ -n "$_serving" ] && [ -d "$_serving" ]; then
        printf 'spec-index:serving-exists=yes\n'
    else
        printf 'spec-index:serving-exists=no\n'
        {
            echo "spec-index: the resolved serving directory does not exist:"
            echo "  $_serving"
            echo "If that path belongs to another machine, FORGE_SPEC_INDEX_DIR or"
            echo "FORGE_SPEC_INDEX_ROOT is set in this environment (789-nc2s). A"
            echo "session started before 2b1f8d188 keeps the stale value until it"
            echo "restarts; \`env -u FORGE_SPEC_INDEX_DIR\` resolves locally."
        } >&2
    fi
    # `entries` DELIBERATELY still counts $INDEX_ROOT, and is left alone.
    #
    # The first draft of this fix repointed it at `serving`, on the reasoning
    # that a reader sees the two lines together and assumes they describe one
    # directory. That was an over-correction: `entries` pairs with `keep` below
    # — they are the retention accounting for index GENERATIONS under the root
    # ("3 kept of 3"), and repointing it produced the incoherent `entries=2,
    # keep=3` where 2 was a file count and 3 a generation count. The ambiguity
    # that actually misled a reader was not entries-versus-serving; it was a
    # `serving=` path that did not exist and said nothing about it. One line
    # fixes that, and it is the line above.
    printf 'spec-index:entries=%s\n' "$(ls -1 "$INDEX_ROOT" 2>/dev/null | grep -cv '^current$')"
    printf 'spec-index:keep=%s\n' "${TILLANDSIAS_SPEC_INDEX_KEEP:-3}"
    exit 0
fi

EMBED_EP="${TILLANDSIAS_EMBED_ENDPOINT:-}"
EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-nomic-embed-text}"
BATCH="${TILLANDSIAS_SPEC_INDEX_BATCH:-64}"
# nomic-embed-text truncates past its context anyway; cutting here keeps one
# oversized chunk from failing a whole batch and stalling the build.
MAX_CHARS="${TILLANDSIAS_SPEC_INDEX_MAX_CHARS:-6000}"

for _tool in jq curl; do
    command -v "$_tool" >/dev/null 2>&1 || { echo "skip:spec-index:no-$_tool"; exit 0; }
done
[ -n "$EMBED_EP" ] || { echo "skip:spec-index:no-embed-endpoint"; exit 0; }

# Resolve the binary through the SHARED probe, never a hardcoded path — a
# hardcoded ./target/release path is the bug 704-zcgi centralised this to stop
# recurring, and CARGO_TARGET_DIR moves it (783-jdeh).
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary)" || { echo "skip:spec-index:no-plan-binary"; exit 0; }

# PROVE THE DESTINATION IS WRITABLE BEFORE DOING TWELVE MINUTES OF WORK.
# Learned the expensive way on 2026-08-17: this script embedded all 9909 chunks
# and only then discovered it could not create the index directory, because
# FORGE_SPEC_INDEX_DIR was still exported into the session as a /mnt/c Windows
# path (789-nc2s: removed from the tracked config in 2b1f8d188, but every agent
# session started before that commit keeps the stale value until it restarts).
# The refusal was correct and the ordering was not. A destination check costs
# one mkdir; discovering it last costs the whole build.
#
# 801-a2by refines WHEN it is fatal rather than weakening it. The durable root
# is now a SHARED tier that a reader may legitimately hold read-only, so an
# unwritable root must still serve a fingerprint HIT. The refusal therefore
# fires at the point a BUILD is required — which is still before the first
# embedding call, so the expensive lesson above is fully preserved.
ROOT_WRITABLE=1
if ! mkdir -p "$INDEX_ROOT" 2>/dev/null || [ ! -w "$INDEX_ROOT" ]; then
    ROOT_WRITABLE=0
fi

_refuse_unwritable() {
    echo "blocked:spec-index:destination-unwritable:$INDEX_ROOT"
    {
        echo "Cannot write the spec index to '$INDEX_ROOT'."
        echo "If that path belongs to another machine, FORGE_SPEC_INDEX_DIR or"
        echo "FORGE_SPEC_INDEX_ROOT is set in this environment (789-nc2s). Unset"
        echo "it, or point it at a directory on THIS host, and re-run."
    } >&2
    exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/spec-index-ensure.XXXXXX")" || {
    echo "blocked:spec-index:no-tmpdir"; exit 1; }
LOCK_DIR=""
_cleanup() {
    rm -rf "$work"
    [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
    return 0
}
trap _cleanup EXIT

# ── CHUNK AND FINGERPRINT FIRST, LOCK ONLY IF WE MUST BUILD ──────────────────
# 25ms of chunking buys the ability to answer "already published?" without
# serialising behind a twelve-minute builder. This ordering IS the packet.
"$PLAN_BIN" spec-index --root "$ROOT" --out "$work" >/dev/null 2>&1 || {
    echo "blocked:spec-index:chunker-failed"; exit 1; }
[ -s "$work/chunks.jsonl" ] || { echo "blocked:spec-index:no-chunks"; exit 1; }

n_chunks="$(wc -l < "$work/chunks.jsonl" | tr -d '[:space:]')"

# IDEMPOTENCE. The fingerprint covers the chunk corpus AND the model, because
# re-embedding the same text with a different model produces a different vector
# space, and mixing two spaces in one file yields confident nonsense.
#
# ...AND THE DOCUMENT PREFIX, for exactly the same reason (864-p2rk). Prefixing
# a passage with "search_document: " changes what is embedded, so it changes
# the space — but `content_hash` is hash_hex(span), the TEXT AND NOTHING ELSE,
# so the chunk keeps its hash and the delta happily reuses UNPREFIXED vectors
# for a build that asked for prefixed ones.
#
# Measured 2026-08-23, on the first prefixed build ever attempted here:
#   spec-index:delta reused=21123 embed=3 of 21126
#   spec-index:delta identity-verified=5 reused samples
# A full nomic index takes ~8 minutes; that one finished in FIVE SECONDS and
# declared itself verified. The identity assertion did not catch it because it
# re-embeds the sample through the same unprefixed path, so it compared wrong
# against wrong and agreed.
#
# This is the model-key defect of order 552 recurring in a second dimension.
# The lesson it should have taught was not "add the model to the key" but
# "anything that changes the embedded BYTES belongs in the key", so the key now
# covers every input to the embedding call rather than being extended one
# incident at a time.
fingerprint="$(
    {
        "${PORTABLE_SHA256[@]}" < "$work/chunks.jsonl"
        printf '%s\n' "$EMBED_MODEL"
        printf '%s\n' "${TILLANDSIAS_EMBED_DOC_PREFIX:-}"
    } | "${PORTABLE_SHA256[@]}" | cut -d' ' -f1
)"
INDEX_DIR="$INDEX_ROOT/$fingerprint"

# _entry_complete <dir> — the same predicate the readers use, plus the arity
# check. An entry is only ever observed complete because it is renamed into
# place; this re-checks anyway, because a half-copied entry restored from a
# backup, or one truncated by a full disk, must be rebuilt rather than served.
_entry_complete() {
    [ -s "$1/vectors.jsonl" ] || return 1
    [ -s "$1/chunks.jsonl" ] || return 1
    [ "$(wc -l < "$1/vectors.jsonl" | tr -d '[:space:]')" = "$n_chunks" ] || return 1
    return 0
}

# _publish_current — point `current` at $fingerprint. Written to a temp name and
# renamed, because rename(2) is atomic: a reader either sees the old pointer or
# the new one, never a truncated fingerprint naming a directory that is not
# there. Silent no-op on a read-only root — a reader is allowed to hold one.
_publish_current() {
    [ "$ROOT_WRITABLE" = "1" ] || return 0
    [ "$(cat "$INDEX_ROOT/current" 2>/dev/null | tr -d '[:space:]')" = "$fingerprint" ] && return 0
    printf '%s\n' "$fingerprint" > "$INDEX_ROOT/.current.$$" 2>/dev/null || return 0
    mv -f "$INDEX_ROOT/.current.$$" "$INDEX_ROOT/current" 2>/dev/null || rm -f "$INDEX_ROOT/.current.$$"
    return 0
}

# RETENTION CEILING. Content-addressing is what stops concurrent harnesses on
# different commits from evicting each other, but it also means the store GROWS
# instead of being overwritten in place: this corpus is 96 MiB per entry, and the
# post-commit hook publishes a new one every time the corpus moves. Unbounded, a
# week of spec work would fill the volume and the failure would land on whoever
# was next to build. So keep the newest few and drop the rest — the same "pin +
# ceiling" shape 795-h8er gave the nix store.
#
# WHAT IS NEVER PRUNED: whatever `current` names, regardless of its age. And
# pruning happens only AFTER a successful publish, so a failed build can never
# take the working index down with it. A reader that resolved a fingerprint one
# instant before it was pruned gets ENOENT and refuses in the typed way — the
# open file it already holds survives unlink, so nothing is read half-deleted.
_prune_entries() {
    [ "$ROOT_WRITABLE" = "1" ] || return 0
    _pe_keep="${TILLANDSIAS_SPEC_INDEX_KEEP:-3}"
    case "$_pe_keep" in '' | *[!0-9]*) _pe_keep=3 ;; esac
    [ "$_pe_keep" -ge 1 ] || _pe_keep=1
    _pe_cur="$(cat "$INDEX_ROOT/current" 2>/dev/null | tr -d '[:space:]')"
    _pe_n=0
    # Newest first. Entry names are hex fingerprints, so word-splitting is safe.
    for _pe_d in $(ls -1t "$INDEX_ROOT" 2>/dev/null); do
        case "$_pe_d" in
            current | .*) continue ;;
        esac
        [ -d "$INDEX_ROOT/$_pe_d" ] || continue
        [ "$_pe_d" = "$_pe_cur" ] && continue
        _pe_n=$((_pe_n + 1))
        if [ "$_pe_n" -ge "$_pe_keep" ]; then
            rm -rf "$INDEX_ROOT/$_pe_d"
        fi
    done
    return 0
}

if _entry_complete "$INDEX_DIR"; then
    _publish_current
    echo "ok:spec-index:fresh:$n_chunks"
    exit 0
fi

# From here we are going to BUILD, so the destination must be writable.
[ "$ROOT_WRITABLE" = "1" ] || _refuse_unwritable

# ONE BUILDER AT A TIME. The post-commit hook fires this on every commit, and a
# cold build takes ~12 minutes here — so without a lock a burst of commits
# during a spec change would start several concurrent full builds, each
# hammering the same single-threaded embedding endpoint and making all of them
# slower. `mkdir` is the atomic test-and-set that works on every filesystem
# this project runs on. The lock is GLOBAL to the root rather than per
# fingerprint, deliberately: two builders on different corpora are still two
# builders on one endpoint, which is exactly what this exists to prevent.
LOCK_DIR="$INDEX_ROOT/.build.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # A stale lock from a killed builder must not wedge the index forever.
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || { LOCK_DIR=""; echo "skip:spec-index:locked"; exit 0; }
    else
        LOCK_DIR=""
        echo "skip:spec-index:already-building"
        exit 0
    fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

# DOUBLE-CHECK UNDER THE LOCK. Another builder may have published this exact
# fingerprint between our miss above and our acquisition here; re-embedding it
# would be twelve minutes spent reproducing bytes that already exist.
if _entry_complete "$INDEX_DIR"; then
    _publish_current
    echo "ok:spec-index:fresh:$n_chunks"
    exit 0
fi

# One JSON string per line, truncated, never empty (an empty input is a 400
# from most /v1/embeddings servers and would strand the whole batch).
jq -c --argjson max "$MAX_CHARS" \
    '((.text // "") | .[0:$max]) | if (. | length) == 0 then " " else . end' \
    "$work/chunks.jsonl" > "$work/texts.jsonl" || {
    echo "blocked:spec-index:text-extract-failed"; exit 1; }

# ── DELTA RE-EMBED (order 552) ──────────────────────────────────────────────
#
# Every rebuild re-embedded every chunk: ~490s for 20,657 chunks at 1.52s per
# 64-chunk batch, while a one-file edit changes ~0.6% of them. Roughly 325x
# waste, and `crates/` is a corpus root, so editing the indexer itself forced a
# full re-embed.
#
# THE JOIN IS BY CONTENT HASH, NEVER BY POSITION, and that is the whole safety
# argument. chunks.jsonl and vectors.jsonl are LINE-ALIGNED, and the existing
# per-batch arity check exists because "a shifted index answers plausibly and
# wrongly". A delta that paired reused vectors positionally would reproduce
# exactly that shift WHILE PASSING that check, because every batch it does
# embed is the right size. So reuse is keyed on the chunk's own content_hash
# and a prior generation is only read after its own arity is verified.
#
# That still cannot see a source generation that was ALREADY mis-joined before
# we read it, so the assembled result is additionally spot-checked below by
# re-embedding a deterministic sample of reused chunks and comparing bytes.
DELTA="${TILLANDSIAS_SPEC_INDEX_DELTA:-1}"
: > "$work/reuse.tsv"
n_reused=0
if [ "$DELTA" = "1" ]; then
    for gen in "$INDEX_ROOT"/*/; do
        [ -d "$gen" ] || continue
        # ARITY AGAINST THE GENERATION'S OWN CHUNK COUNT, not the current
        # corpus size. `_entry_complete` compares against $n_chunks because it
        # validates THIS build's entry; reusing it here rejected every prior
        # generation the moment the corpus grew by a single chunk, and the
        # delta silently degraded to a full rebuild while reporting reused=0.
        # Measured: 99.3% of hashes (19,720 of 19,850) were reusable and none
        # were reused.
        _g_c="$(wc -l < "${gen%/}/chunks.jsonl" 2>/dev/null | tr -d '[:space:]')"
        _g_v="$(wc -l < "${gen%/}/vectors.jsonl" 2>/dev/null | tr -d '[:space:]')"
        [ -n "$_g_c" ] && [ "$_g_c" = "$_g_v" ] && [ "$_g_c" != "0" ] || continue
        # THE CACHE KEY MUST INCLUDE THE EMBEDDING MODEL. `content_hash` is
        # hash_hex(span) — the TEXT and nothing else (spec.rs:1020) — so a
        # chunk keeps the same hash under every model, and a delta keyed on it
        # alone hands nomic-embed-text vectors to a bge-m3 build. Measured
        # 2026-08-23: reused=20919 of 21028, 768-dim vectors spliced into a
        # 1024-dim index. The identity assertion caught it and refused, which
        # is the net working — but reuse-then-refuse makes building with ANY
        # other embedder impossible, so the model belongs in the key.
        #
        # A generation with NO .model marker is never reused. That is
        # deliberate and conservative: the marker did not exist before this
        # change, so the alternative is guessing which model wrote a
        # generation, and a wrong guess is the exact failure above. It costs
        # one full rebuild per model, once, and self-heals thereafter.
        [ -f "${gen%/}/.model" ] || continue
        [ "$(cat "${gen%/}/.model" 2>/dev/null)" = "$EMBED_MODEL" ] || continue
        # 864-p2rk: same rule for the document prefix. A generation with no .prefix
        # marker predates prefixes and is only reusable by an unprefixed build.
        [ "$(cat "${gen%/}/.prefix" 2>/dev/null)" = "${TILLANDSIAS_EMBED_DOC_PREFIX:-}" ] || continue
        # Without that equality this paste would mint a hash->vector map that
        # is wrong from its first line.
        paste -d '\t' \
            <(jq -r '.content_hash // empty' "${gen%/}/chunks.jsonl") \
            "${gen%/}/vectors.jsonl" 2>/dev/null >> "$work/reuse.tsv" || true
    done
    # First occurrence wins; identical content hashes carry identical text and
    # therefore identical vectors under a fixed model.
    if [ -s "$work/reuse.tsv" ]; then
        awk -F'\t' '!seen[$1]++ && $1 != "" && $2 != ""' "$work/reuse.tsv" > "$work/reuse-uniq.tsv"
        mv "$work/reuse-uniq.tsv" "$work/reuse.tsv"
    fi
fi

# Per-chunk decision, in chunk order: REUSE <vector> or EMBED.
jq -r '.content_hash // ""' "$work/chunks.jsonl" > "$work/hashes.txt"
paste -d '\t' "$work/hashes.txt" "$work/texts.jsonl" > "$work/plan.tsv"
awk -F'\t' -v reuse="$work/reuse.tsv" '
BEGIN { while ((getline l < reuse) > 0) { i = index(l, "\t"); if (i) v[substr(l,1,i-1)] = substr(l,i+1) } }
{ if ($1 != "" && ($1 in v)) printf "R\t%s\n", v[$1]; else printf "E\t%s\n", $2 }
' "$work/plan.tsv" > "$work/decisions.tsv"

awk -F'\t' '$1=="E"{print $2}' "$work/decisions.tsv" > "$work/todo-texts.jsonl"
n_reused="$(awk -F'\t' '$1=="R"' "$work/decisions.tsv" | wc -l | tr -d '[:space:]')"
n_todo="$(wc -l < "$work/todo-texts.jsonl" | tr -d '[:space:]')"
printf 'spec-index:delta reused=%s embed=%s of %s\n' "$n_reused" "$n_todo" "$n_chunks" >&2

mkdir -p "$work/b"
if [ "$n_todo" -gt 0 ]; then
    split -l "$BATCH" -a 5 -d "$work/todo-texts.jsonl" "$work/b/part-" || {
        echo "blocked:spec-index:split-failed"; exit 1; }
fi

: > "$work/new-vecs.jsonl"
for part in "$work"/b/part-*; do
    [ -e "$part" ] || break
    want="$(wc -l < "$part" | tr -d '[:space:]')"
    # DOCUMENT PREFIX (864-p2rk). Several embedders are trained with an
    # asymmetric query/passage convention and are documented as REQUIRING it —
    # nomic-embed-text wants "search_document: " on passages and
    # "search_query: " on queries. This harness applied neither, to any model,
    # in every comparison filed so far. nomic's own template is a bare
    # `{{ .Prompt }}`, so nothing supplies it downstream either. Empty by
    # default, which reproduces every historical measurement exactly.
    jq -sc --arg m "$EMBED_MODEL" --arg p "${TILLANDSIAS_EMBED_DOC_PREFIX:-}" \
        '{model:$m, input:[.[] | $p + .]}' "$part" > "$work/payload.json" || {
        echo "blocked:spec-index:payload-failed"; exit 1; }
    # `-f` IS THE BUG THIS BLOCK KEEPS RE-LEARNING, so it is gone. curl's --fail
    # makes an HTTP 400 an exit-22 failure AND DISCARDS THE RESPONSE BODY — the
    # body being the only place the server says what was actually wrong. This
    # handler then printed a guess in its place, and the guess was wrong.
    #
    # Measured 2026-08-23, and the diagnostic misled its own author for a full
    # cycle. A qwen3-embedding:4b build died here and this block reported
    # "models resident right now: qwen3-embedding:4b, qwen2.5:0.5b / loading
    # another model beside these aborts (849-tz8g)". Residency was NOT the
    # cause. The discarded body said:
    #     Post "http://127.0.0.1:NNNNN/tokenize": read tcp …: connection reset
    # — the model runner had CRASHED while tokenizing, on a batch of 64 real
    # chunks totalling 255 KB. Bisected: batch 32 (128 KB) succeeds, 64 fails.
    # A smaller batch fixes it; unloading models does not.
    #
    # So the original comment was right that "endpoint-refused" sends the reader
    # to the proxy and the CA bundle, and then made the same mistake one level
    # down: it replaced a wrong generic cause with a wrong specific one. An
    # error may only assert what it measured (797-5kqe). Print the server's own
    # words FIRST, and offer residency only as a hint clearly marked as a hint.
    _http="$(curl -sS --max-time 300 -o "$work/resp.json" -w '%{http_code}' \
            "$EMBED_EP/embeddings" -H 'Content-Type: application/json' \
            -d @"$work/payload.json" 2>"$work/curl.err")"
    _curl_rc=$?
    if [ "$_curl_rc" -ne 0 ] || [ "${_http:-000}" -ge 400 ] 2>/dev/null; then
        # ORDER 811-28eh — NAME THE RIGHT SUBJECT.
        #
        # This block emitted `embed-endpoint-refused` for every failure mode,
        # including the one where NOTHING IS LISTENING. "Refused" asserts that a
        # server answered and declined; when curl exits 7 nothing answered at
        # all, and there may be no server on the host in the first place.
        #
        # MEASURED 2026-08-25 on macuahuitl, during a release cut: the verdict
        # read `embed-endpoint-refused` with `curl: (7) Failed to connect ...
        # Could not connect to server` underneath it. The host had no ollama, no
        # inference image and an empty podman store — there was nothing to
        # refuse. The reader (me) spent the first minutes looking for a
        # misconfigured endpoint instead of an absent one, which is exactly the
        # cost this packet describes: the verdict names the wrong subject.
        #
        # The DIED case is this packet's own headline symptom and deserves its
        # own token: the container serves 200s at ~250ms each and then vanishes
        # with exit 2, so the caller sees a connection torn down MID-STREAM
        # after earlier batches succeeded. That is a different fact from "never
        # reachable" and it points at a different investigation.
        #
        # An error may only assert what it measured (797-5kqe) — so the token is
        # derived from curl's own exit code and the HTTP status, never guessed.
        case "$_curl_rc" in
            7)  _subject="embed-endpoint-absent" ;;      # nothing listening
            28) _subject="embed-endpoint-timeout" ;;     # listening, never answered
            52|56)
                # Connection died with no/partial reply. If earlier batches
                # succeeded this is a mid-workload death, not an absence.
                if [ "${_embed_batches_ok:-0}" -gt 0 ]; then
                    _subject="embed-endpoint-died-mid-request"
                else
                    _subject="embed-endpoint-unreachable"
                fi
                ;;
            0)  _subject="embed-endpoint-refused" ;;     # it ANSWERED, with >=400
            *)  _subject="embed-endpoint-unreachable" ;;
        esac
        echo "blocked:spec-index:${_subject}"
        if [ "$_subject" = "embed-endpoint-absent" ]; then
            echo "  NOTHING IS LISTENING on ${EMBED_EP} — this is an absent endpoint," >&2
            echo "  not a refusal. Check that an embedding service is running at all" >&2
            echo "  before looking for a misconfiguration (order 811-28eh)." >&2
        elif [ "$_subject" = "embed-endpoint-died-mid-request" ]; then
            echo "  THE ENDPOINT DIED MID-WORKLOAD: ${_embed_batches_ok:-0} batch(es) had already" >&2
            echo "  succeeded before the connection was torn down. That is order 811-28eh's" >&2
            echo "  signature — serving 200s, then gone. Check the container's exit code and" >&2
            echo "  note that podman may label the corpse (healthy) (798-tk7b)." >&2
        fi
        echo "  HTTP ${_http:-<none>} from ${EMBED_EP}/embeddings on a batch of ${want:-?} chunk(s)" >&2
        echo "  curl exit ${_curl_rc}" >&2
        if [ -s "$work/resp.json" ]; then
            echo "  THE SERVER SAID: $(head -c 400 "$work/resp.json")" >&2
        elif [ -s "$work/curl.err" ]; then
            echo "  curl said: $(head -c 200 "$work/curl.err")" >&2
        else
            echo "  (no response body and no curl error — a genuinely silent refusal)" >&2
        fi
        echo "  PAYLOAD: $(wc -c < "$work/payload.json" | tr -d ' ') bytes." >&2
        echo "  IF THE BODY MENTIONS /tokenize OR A RESET CONNECTION the runner crashed" >&2
        echo "  on batch size, not on residency: retry with a smaller" >&2
        echo "  TILLANDSIAS_SPEC_INDEX_BATCH (qwen3-embedding:4b needs 32, not 64)." >&2
        _resident="$(curl -fsS --max-time 5 "${EMBED_EP%/v1}/api/ps" 2>/dev/null \
            | jq -r '[.models[]?.name] | join(", ")' 2>/dev/null)"
        if [ -n "$_resident" ] && [ "$_resident" != "$EMBED_MODEL" ]; then
            echo "  HINT ONLY, not a diagnosis: other models are resident (${_resident})." >&2
            echo "  If the body above does NOT explain the failure, 849-tz8g may apply." >&2
        fi
        exit 1
    fi
    if ! jq -c '.data[].embedding' "$work/resp.json" > "$work/batch-vecs.jsonl" 2>/dev/null; then
        echo "blocked:spec-index:embed-response-unparseable"
        exit 1
    fi
    got="$(wc -l < "$work/batch-vecs.jsonl" | tr -d '[:space:]')"
    # Arity per batch, not just at the end: a server that silently drops one
    # input shifts every subsequent pairing, and a shifted index answers
    # plausibly and wrongly. Catch it where it happens.
    if [ "$got" != "$want" ]; then
        echo "blocked:spec-index:batch-arity-$got-of-$want"
        exit 1
    fi
    cat "$work/batch-vecs.jsonl" >> "$work/new-vecs.jsonl"
    # ORDER 811-28eh. Counts batches the endpoint actually COMPLETED, so a later
    # torn-down connection can be reported as a mid-workload death rather than
    # as an unreachable endpoint. This is the one fact that separates "it served
    # and then died" — this packet's whole symptom — from "it was never there".
    _embed_batches_ok=$(( ${_embed_batches_ok:-0} + 1 ))
done

# ── ASSEMBLE IN CHUNK ORDER ─────────────────────────────────────────────────
# Walk the decisions in order: a REUSE line carries its vector inline (already
# joined by hash), an EMBED line consumes the next freshly-embedded vector.
# Consuming in order is safe here because todo-texts.jsonl was produced from
# the SAME pass in the SAME order.
awk -F'\t' -v newf="$work/new-vecs.jsonl" '
$1 == "R" { print $2; next }
$1 == "E" { if ((getline nv < newf) > 0) print nv; else { print "MISSING" > "/dev/stderr"; bad=1 } }
END { if (bad) exit 1 }
' "$work/decisions.tsv" > "$work/vectors.jsonl" || {
    echo "blocked:spec-index:delta-assembly-underran"; exit 1; }

# EVERY new vector must have been consumed. A leftover means the decision list
# and the embed list disagreed, which is the shift this design exists to avoid.
_new_emitted="$(wc -l < "$work/new-vecs.jsonl" | tr -d '[:space:]')"
_new_wanted="$(awk -F'\t' '$1=="E"' "$work/decisions.tsv" | wc -l | tr -d '[:space:]')"
if [ "$_new_emitted" != "$_new_wanted" ]; then
    echo "blocked:spec-index:delta-embedded-$_new_emitted-for-$_new_wanted-misses"
    exit 1
fi

# ── PER-CHUNK IDENTITY ASSERTION (order 552, do not remove) ─────────────────
#
# The arity checks above cannot see a REUSED vector paired with the wrong
# chunk: the count is right and the bytes are opaque. So re-embed a
# deterministic sample of reused chunks and compare the result to what the
# cache handed us. Deterministic (first N reused) rather than random so a
# negative control can target a sampled row and the failure is reproducible.
_sample="${TILLANDSIAS_SPEC_INDEX_VERIFY_SAMPLE:-5}"
if [ "$n_reused" -gt 0 ] && [ "$_sample" -gt 0 ]; then
    _checked=0
    _line=0
    while IFS= read -r dec && [ "$_checked" -lt "$_sample" ]; do
        _line=$((_line + 1))
        case "$dec" in R*) ;; *) continue ;; esac
        _cached="${dec#R	}"
        _text="$(sed -n "${_line}p" "$work/texts.jsonl")"
        _probe="$(jq -nc --arg m "$EMBED_MODEL" --argjson t "$_text" '{model:$m, input:[$t]}')"
        _got="$(curl -fsS --max-time 120 "$EMBED_EP/embeddings" -H 'Content-Type: application/json' \
            -d "$_probe" 2>/dev/null | jq -c '.data[0].embedding' 2>/dev/null)"
        [ -n "$_got" ] && [ "$_got" != null ] || continue   # endpoint hiccup: not a mis-join
        if [ "$_got" != "$_cached" ]; then
            echo "blocked:spec-index:delta-identity-mismatch-at-chunk-$_line"
            echo "  a REUSED vector is not the embedding of the chunk it was paired with;" >&2
            echo "  the delta cache is mis-joined and this index would answer plausibly and wrongly" >&2
            exit 1
        fi
        _checked=$((_checked + 1))
    done < "$work/decisions.tsv"
    printf 'spec-index:delta identity-verified=%s reused samples\n' "$_checked" >&2
fi

n_vecs="$(wc -l < "$work/vectors.jsonl" | tr -d '[:space:]')"
if [ "$n_vecs" != "$n_chunks" ]; then
    echo "blocked:spec-index:arity-$n_vecs-vectors-for-$n_chunks-chunks"
    exit 1
fi

# ATOMIC PUBLISH, CONTENT-ADDRESSED. The entry is assembled in a staging dir on
# the same filesystem and RENAMED to its fingerprint name, so a concurrent
# reader resolving that name sees either nothing or a complete entry — never a
# partial one, and never a directory being rewritten under it.
stage="$INDEX_ROOT/.staging.$$"
rm -rf "$stage"; mkdir -p "$stage" || { echo "blocked:spec-index:cannot-stage"; exit 1; }
cp "$work/chunks.jsonl" "$stage/chunks.jsonl" || { echo "blocked:spec-index:copy-failed"; exit 1; }
cp "$work/vectors.jsonl" "$stage/vectors.jsonl" || { echo "blocked:spec-index:copy-failed"; exit 1; }
printf '%s\n' "$fingerprint" > "$stage/.fingerprint"
# The embedding model that produced these vectors. Read by the delta cache
# loop: a generation is reusable only by a build using the SAME model, because
# content_hash covers the text and not the model that embedded it.
printf %s\\n "$EMBED_MODEL" > "$stage/.model"
printf %s\\n "${TILLANDSIAS_EMBED_DOC_PREFIX:-}" > "$stage/.prefix"
# ORDER 801-g9nn — THE FRAME THIS ENTRY DESCRIBES.
#
# The fingerprint proves an entry describes corpus X. It says nothing about
# WHICH COMMIT X was read at, and a citation is `path:45-49` — a line range that
# only means anything relative to a version of the file. A reader on a different
# commit opens line 45 in its own tree and, since 803-su4n put CODE in this
# corpus, may edit it. Recording the commit here is what lets `verify-answer`
# ask "does this span hold at the frame it was read in?" instead of guessing.
#
# ONE COMMIT IS ENOUGH EVEN THOUGH MANY PRODUCE THIS CORPUS. Entries are keyed
# by a hash OVER chunks.jsonl, which carries every chunk's path, line range and
# text; so if two commits map to this fingerprint, every cited span is
# byte-identical at both, and any of them is a sound frame for every citation
# the entry can produce. An existing entry is never rewritten, so the recorded
# commit is the first publisher's — older than a later caller's HEAD, which
# reports honestly as `behind` with an empty drift list.
#
# NOT PART OF `_entry_complete`. Every entry published before this line existed
# is still perfectly servable, just frameless; demanding the file would condemn
# the whole shared volume to a twelve-minute rebuild apiece to gain a field that
# is additive by design.
if _sie_commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" && [ -n "$_sie_commit" ]; then
    printf '%s\n' "$_sie_commit" > "$stage/.commit"
    chmod 0644 "$stage/.commit" 2>/dev/null || true
fi
# World-readable: the forge reads this volume as a different uid through a
# read-only mount, so a 0600 entry would be a permission refusal that looks
# exactly like a missing index.
chmod 0755 "$stage" 2>/dev/null || true
chmod 0644 "$stage/chunks.jsonl" "$stage/vectors.jsonl" "$stage/.fingerprint" "$stage/.model" "$stage/.prefix" 2>/dev/null || true
if [ -d "$INDEX_DIR" ]; then
    # Lost a race we hold the lock against, or a partial entry survived. Never
    # `mv` onto an existing directory: that NESTS the staging dir inside it.
    rm -rf "$stage"
else
    mv "$stage" "$INDEX_DIR" || { rm -rf "$stage"; echo "blocked:spec-index:publish-failed"; exit 1; }
fi
_publish_current
_prune_entries

echo "ok:spec-index:built:$n_chunks"
exit 0
