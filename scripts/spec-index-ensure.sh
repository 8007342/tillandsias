#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability
#
# spec-index-ensure.sh — build the spec RAG index so `spec_answer` can answer
# on a DEV host (orders 552 and 760-hzi4).
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
# RESOLUTION IS COPIED FROM THE CONSUMER ON PURPOSE. The directory, endpoint
# and model are resolved exactly as images/default/config-overlay/mcp/
# forge-plan.sh resolves them. A producer that writes where the reader does not
# look, or embeds with a model the query path does not use, builds an index
# that is silently wrong rather than absent — and an index that answers WRONGLY
# is far worse than one that refuses, because the refusal is typed and this
# would not be. The dev/runtime model split those variables encode is already
# settled (lib-dev-env.sh, checked by check-dev-embed-model-agreement.sh).
#
# ORDER ALIGNMENT IS THE CORRECTNESS PROPERTY. vectors.jsonl line N must be the
# embedding of chunks.jsonl line N; spec-retrieve pairs them by position and
# refuses outright if the counts differ. Every batch is therefore checked for
# arity, and the file is published ATOMICALLY (built in a temp dir, moved into
# place) so no reader can ever observe a half-written index.
#
# Grammar (exactly one line on stdout):
#   ok:spec-index:fresh:<n>
#   ok:spec-index:built:<n>
#   skip:spec-index:<reason>        — no endpoint/binary; advisory, exit 0
#   blocked:spec-index:<reason>     — tried and failed; exit 1
#
# `skip:` exits 0 by design: a host with no inference endpoint is degraded, not
# broken, and the consumer already refuses in a typed, self-describing way.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FORGE_EXPERTS_STATE_DIR="${FORGE_EXPERTS_STATE_DIR:-/dev/shm/tillandsias-experts}"
INDEX_DIR="${FORGE_SPEC_INDEX_DIR:-$FORGE_EXPERTS_STATE_DIR/spec-index}"
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
if ! mkdir -p "$INDEX_DIR" 2>/dev/null || [ ! -w "$INDEX_DIR" ]; then
    echo "blocked:spec-index:destination-unwritable:$INDEX_DIR"
    {
        echo "Cannot write the spec index to '$INDEX_DIR'."
        echo "If that path belongs to another machine, FORGE_SPEC_INDEX_DIR is"
        echo "set in this environment (789-nc2s). Unset it, or point it at a"
        echo "directory on THIS host, and re-run."
    } >&2
    exit 1
fi

# ONE BUILDER AT A TIME. The post-commit hook fires this on every commit, and a
# cold build takes ~12 minutes here — so without a lock a burst of commits
# during a spec change would start several concurrent full builds, each
# hammering the same single-threaded embedding endpoint and making all of them
# slower. `mkdir` is the atomic test-and-set that works on every filesystem
# this project runs on.
LOCK_DIR="${INDEX_DIR}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # A stale lock from a killed builder must not wedge the index forever.
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "skip:spec-index:locked"; exit 0; }
    else
        echo "skip:spec-index:already-building"
        exit 0
    fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"

work="$(mktemp -d "${TMPDIR:-/tmp}/spec-index-ensure.XXXXXX")" || {
    rm -rf "$LOCK_DIR"; echo "blocked:spec-index:no-tmpdir"; exit 1; }
trap 'rm -rf "$work" "$LOCK_DIR"' EXIT

"$PLAN_BIN" spec-index --root "$ROOT" --out "$work" >/dev/null 2>&1 || {
    echo "blocked:spec-index:chunker-failed"; exit 1; }
[ -s "$work/chunks.jsonl" ] || { echo "blocked:spec-index:no-chunks"; exit 1; }

n_chunks="$(wc -l < "$work/chunks.jsonl" | tr -d '[:space:]')"

# IDEMPOTENCE. The fingerprint covers the chunk corpus AND the model, because
# re-embedding the same text with a different model produces a different vector
# space, and mixing two spaces in one file yields confident nonsense.
fingerprint="$(
    { sha256sum < "$work/chunks.jsonl"; printf '%s\n' "$EMBED_MODEL"; } | sha256sum | cut -d' ' -f1
)"
if [ -f "$INDEX_DIR/.fingerprint" ] \
   && [ "$(cat "$INDEX_DIR/.fingerprint" 2>/dev/null)" = "$fingerprint" ] \
   && [ -s "$INDEX_DIR/vectors.jsonl" ] \
   && [ "$(wc -l < "$INDEX_DIR/vectors.jsonl" | tr -d '[:space:]')" = "$n_chunks" ]; then
    echo "ok:spec-index:fresh:$n_chunks"
    exit 0
fi

# One JSON string per line, truncated, never empty (an empty input is a 400
# from most /v1/embeddings servers and would strand the whole batch).
jq -c --argjson max "$MAX_CHARS" \
    '((.text // "") | .[0:$max]) | if (. | length) == 0 then " " else . end' \
    "$work/chunks.jsonl" > "$work/texts.jsonl" || {
    echo "blocked:spec-index:text-extract-failed"; exit 1; }

mkdir -p "$work/b"
split -l "$BATCH" -a 5 -d "$work/texts.jsonl" "$work/b/part-" || {
    echo "blocked:spec-index:split-failed"; exit 1; }

: > "$work/vectors.jsonl"
for part in "$work"/b/part-*; do
    want="$(wc -l < "$part" | tr -d '[:space:]')"
    jq -sc --arg m "$EMBED_MODEL" '{model:$m, input:.}' "$part" > "$work/payload.json" || {
        echo "blocked:spec-index:payload-failed"; exit 1; }
    if ! curl -fsS --max-time 300 "$EMBED_EP/embeddings" \
            -H 'Content-Type: application/json' \
            -d @"$work/payload.json" > "$work/resp.json" 2>/dev/null; then
        echo "blocked:spec-index:embed-endpoint-refused"
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
    cat "$work/batch-vecs.jsonl" >> "$work/vectors.jsonl"
done

n_vecs="$(wc -l < "$work/vectors.jsonl" | tr -d '[:space:]')"
if [ "$n_vecs" != "$n_chunks" ]; then
    echo "blocked:spec-index:arity-$n_vecs-vectors-for-$n_chunks-chunks"
    exit 1
fi

# ATOMIC PUBLISH. Stage a complete index beside the live one and swap, so a
# concurrent spec_answer either sees the whole old index or the whole new one.
mkdir -p "$INDEX_DIR" || { echo "blocked:spec-index:cannot-mkdir"; exit 1; }
stage="$INDEX_DIR/.staging.$$"
rm -rf "$stage"; mkdir -p "$stage" || { echo "blocked:spec-index:cannot-stage"; exit 1; }
cp "$work/chunks.jsonl" "$stage/chunks.jsonl" || { echo "blocked:spec-index:copy-failed"; exit 1; }
cp "$work/vectors.jsonl" "$stage/vectors.jsonl" || { echo "blocked:spec-index:copy-failed"; exit 1; }
printf '%s\n' "$fingerprint" > "$stage/.fingerprint"
mv -f "$stage/chunks.jsonl" "$INDEX_DIR/chunks.jsonl"
mv -f "$stage/vectors.jsonl" "$INDEX_DIR/vectors.jsonl"
mv -f "$stage/.fingerprint" "$INDEX_DIR/.fingerprint"
rmdir "$stage" 2>/dev/null || true

echo "ok:spec-index:built:$n_chunks"
exit 0
