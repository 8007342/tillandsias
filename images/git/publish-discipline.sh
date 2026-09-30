#!/bin/sh
# @trace spec:git-mirror-service, spec:branch-discipline
# @trace order:1443-uit6
#
# publish-discipline.sh <bare-mirror-dir>
#
# Publishes the branch discipline this mirror ENFORCES as exactly one ref:
#
#   refs/tillandsias/discipline/<level>/<enforcement>/<derived>/<digest>/<epoch>
#
#   level        the seed's level; 0 when there is no seed; unknown when the
#                seed cannot be parsed
#   enforcement  ONE word, the strictest across the seed's rules
#                (advised < warn < enforced); unreadable when unparseable
#   derived      unknown until the derivation (1363-xp2v) exists
#   digest       the FULL sha256 of the seed bytes (64 hex), or `none` when
#                there is no seed. Never the hash of empty bytes: a checkout
#                without a seed has digest null, and 1443-z3vb reads
#                "no 64-hex segment" as agreement with it (macuahuitl-forge,
#                2026-09-28). A 12-hex digest would read as no digest at all.
#   epoch        the publishing tick, unix seconds
#
# The ref points at the seed BLOB, so `git fetch` + `git cat-file -p` yields
# the seed bytes, and `git ls-remote <mirror> 'refs/tillandsias/discipline/*'`
# reads the level without pushing (a `push --dry-run` never reaches a
# pre-receive hook, so it cannot be answered).
#
# EXACTLY ONE, ATOMICALLY: old refs are deleted and the new one created in a
# single `git update-ref --stdin` transaction, so a reader taking the first
# 64-hex segment from ls-remote never sees two digests at once.
#
# The seed is read exactly as pre-receive-hook.sh reads it: the seed at HEAD
# names the integration branch, and the seed on that branch is published.
# It is parsed and hashed by ruby (the mirror image ships it), never grepped.
set -u
MIRROR="${1:-}"
if [ -z "$MIRROR" ] || [ ! -d "$MIRROR" ]; then
    echo "publish-discipline: usage: publish-discipline <bare-mirror-dir>" >&2
    exit 2
fi
SEED_PATH=".tillandsias/branch-discipline.yaml"
NS="refs/tillandsias/discipline"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t publish-discipline)"
trap 'rm -rf "$TMP"' EXIT

# describe <ref>: prints "level enforcement integration digest" or fails.
describe() {
    git -C "$MIRROR" cat-file -e "$1:$SEED_PATH" 2>/dev/null || return 1
    git -C "$MIRROR" show "$1:$SEED_PATH" > "$TMP/seed" 2>/dev/null || return 1
    if ! command -v ruby >/dev/null 2>&1; then
        echo "unknown unreadable - none"
        return 0
    fi
    ruby -ryaml -rdigest -e '
        bytes = File.binread(ARGV[0])
        digest = Digest::SHA256.hexdigest(bytes)
        d = (YAML.safe_load(bytes) rescue nil)
        unless d.is_a?(Hash)
            puts "unknown unreadable - #{digest}"; exit 0
        end
        rank = { "advised" => 0, "warn" => 1, "enforced" => 2 }
        e = d["enforcement"].is_a?(Hash) ? d["enforcement"].values.map(&:to_s) : []
        strict = e.select { |w| rank.key?(w) }.max_by { |w| rank[w] } || "advised"
        i = d["integration"].is_a?(Hash) ? d["integration"] : {}
        integ = (i["forge"] || i["linux"] || "-").to_s
        level = d["level"].to_s =~ /\A[0-9]+\z/ ? d["level"].to_s : "unknown"
        puts "#{level} #{strict} #{integ} #{digest}"
    ' "$TMP/seed"
}

BLOB=""
# 1490-zw87: try the configured seed refs (TILLANDSIAS_DISCIPLINE_SEED_REFS,
# from the entrypoint) before HEAD. The integration branch carries a level-2
# seed long before the default branch gets it, so HEAD alone published level 0
# for a level-2 project on the first live mirror.
FOUND=""; TRIED=""
for r in ${TILLANDSIAS_DISCIPLINE_SEED_REFS:-} HEAD; do
    git -C "$MIRROR" rev-parse --verify --quiet "$r" >/dev/null 2>&1 || { TRIED="$TRIED $r(absent)"; continue; }
    if desc="$(describe "$r")"; then FOUND="$r"; break; fi
    TRIED="$TRIED $r"
done
if [ -n "$FOUND" ]; then
    set -- $desc
    integ="$3"
    if [ "$integ" != "-" ] && git -C "$MIRROR" rev-parse --verify --quiet "refs/heads/$integ" >/dev/null \
       && d2="$(describe "refs/heads/$integ")"; then
        desc="$d2"; set -- $desc
        BLOB="$(git -C "$MIRROR" rev-parse "refs/heads/$integ:$SEED_PATH")"
    else
        BLOB="$(git -C "$MIRROR" rev-parse "$FOUND:$SEED_PATH")"
    fi
    LEVEL="$1"; ENF="$2"; DIGEST="$4"
else
    LEVEL=0; ENF=advised; DIGEST=none
    # The built-in level-0 default, rendered as YAML (spec: git-mirror-service),
    # so a fetch of the ref still yields a readable document. Its digest
    # segment stays `none`: a seedless checkout's digest is null.
    BLOB="$(printf '# No .tillandsias/branch-discipline.yaml: the built-in default (1363-xp2v).\nversion: 1\nlevel: 0\nenforcement:\n  default_branch: advised\n  ref_grammar: advised\n' \
        | git -C "$MIRROR" hash-object -w --stdin)"
fi
[ -n "$BLOB" ] || { echo "publish-discipline: could-not-run:no-blob" >&2; exit 1; }

EPOCH="$(date +%s)"
NEW="$NS/$LEVEL/$ENF/unknown/$DIGEST/$EPOCH"
{
    git -C "$MIRROR" for-each-ref --format='%(refname)' "$NS" 2>/dev/null \
        | while IFS= read -r old; do [ "$old" = "$NEW" ] || printf 'delete %s\n' "$old"; done
    printf 'update %s %s\n' "$NEW" "$BLOB"
} > "$TMP/tx"
if git -C "$MIRROR" update-ref --stdin < "$TMP/tx" 2>"$TMP/err"; then
    # Say WHY a level-0 ref was published: "no seed on <refs>" is a finding a
    # reader can act on; a quiet 0/advised is not (1490-zw87).
    if [ -z "$FOUND" ]; then
        echo "published:$NEW (no seed on:$TRIED)"
    else
        echo "published:$NEW (seed from $FOUND)"
    fi
else
    echo "publish-discipline: update-ref failed: $(cat "$TMP/err")" >&2
    exit 1
fi
