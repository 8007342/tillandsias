#!/usr/bin/env bash
# @trace spec:ci-release
#
# fleet-activity.sh — which HOSTS landed on a branch in a window, and what kind
# of work each landed. Order 1223-wzc4.
#
# RUN THIS. DO NOT RETYPE THE QUERY. That instruction is the whole point of the
# file and it is copied deliberately from scripts/loop-status-metrics-audit.sh,
# which exists because the same read was typed from memory on 2026-09-05, the
# paraphrase dropped both of its fixes, and two figures filed into a packet came
# from the wrong entry.
#
# ── THE THREE CORRECTIONS THIS CARRIES, each paid for ────────────────────────
#
# 1. COUNT BY EMAIL, NOT BY NAME. Commit author NAME does not identify the host.
#    MEASURED 2026-09-16 over seven days: eleven distinct (name, email) pairs,
#    `Tlatoani` mapping to FOUR emails and `Tlatoāni` to two. A `%an` count
#    MERGED macuahuitl with an unattributed bucket into one row of 159 and LOST
#    macneo entirely — its 9 commits folded into that row, so a working host
#    read as silent.
#
# 2. PRINT THE HOST PART, NEVER THE LOCAL PART. Two passes after correction 1
#    was written down as prose, this coordinator used `%ae` and then printed
#    `${e%%@*}` — stripping the domain, which is the ONLY part that names the
#    host. macuahuitl and yoga both rendered as `tlatoani`. The recipe was
#    followed and the display threw away what the recipe exists to preserve.
#    That third instance is why this is a script and not another paragraph.
#
# 3. AN ADDRESS THAT NAMES NO HOST IS A BUCKET, NOT A HOST. Order 1012-hu7d's
#    rule, which loop-status-metrics-audit.sh already enforces for platform-label
#    stems and which the git-author view did not. `bulloncito@gmail.com` carried
#    59 commits in one 24h window and is at least macbookair, which has no
#    host-identified git address at all.
#
# PLAN-ONLY versus CODE is reported per host because the two have different
# costs of entry to a shared branch — code pays a full gate before its first
# push, plan-only pays none — and a bare count cannot be read against that.
#
# ── WHAT THIS DOES NOT ANSWER ────────────────────────────────────────────────
#
# IDLENESS. A host absent from the window landed nothing in the window; that is
# all. It may be mid-analysis, gating, blocked, or asleep, and those look
# identical from here. Idleness is established by ASKING (1005-class). The
# output says so on every run rather than trusting the reader to remember.
#
# ── VERDICTS (stdout, last line) ─────────────────────────────────────────────
#   ok:fleet-activity:<commits>c:<hosts>h:<bucketed>b:window=<w>
#   skipped:fleet-activity:no-commits:window=<w>
#   fail:fleet-activity:unknown-argument:<arg>     nothing was examined
#   fail:fleet-activity:missing-value:<flag>       nothing was examined
#   fail:fleet-activity:bad-ref:<ref>              nothing was examined
#
# EVERY verdict is the LAST line on stdout, and every explanation precedes it on
# stderr. Not cosmetic: callers read the verdict with `| tail -1`, and printing
# the verdict FIRST put the explanation last under `2>&1` — so the fixture read
# a prose line as the verdict. The contract was already documented above and the
# fail paths violated it; the fixture caught it on its first run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

WINDOW="3.hours"
REF="origin/linux-next"
# A domain identifies a HOST when it is not a shared public provider. Deriving
# the host from the domain's first label rather than matching one hard-coded
# suffix, because THE FLEET USES MORE THAN ONE CONVENTION and assuming a single
# one is how this instrument bucketed a host on its very first real run:
# macneo's address is `tlatoani@Tlatoanis-MacBook-Neo.local`, which names its
# host perfectly well and matches no `.ayahuitlcalpan.com` suffix. Enumerate the
# shared providers — a short, checkable list — and treat everything else as
# host-identifying, so a NEW per-host convention works without editing this file.
SHARED_PROVIDERS="gmail.com hotmail.com outlook.com yahoo.com icloud.com protonmail.com proton.me users.noreply.github.com"

# Unknown arguments EXAMINE NOTHING and say so; flags REQUIRE their value.
# Both inherited from 1218-25z3 rather than rediscovered: a `*) shift ;;` arm
# silently answers about the default, and `shift 2` with one argument left fails
# with the count unchanged, spinning forever under `set -uo pipefail` and no -e.
while [ $# -gt 0 ]; do
    case "$1" in
        --since)
            [ $# -ge 2 ] || { echo "  --since needs a value; nothing was examined" >&2; echo "fail:fleet-activity:missing-value:--since"; exit 0; }
            WINDOW="$2"; shift 2 ;;
        --ref)
            [ $# -ge 2 ] || { echo "  --ref needs a value; nothing was examined" >&2; echo "fail:fleet-activity:missing-value:--ref"; exit 0; }
            REF="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
        *)
            echo "  nothing was examined. usage: $(basename "${BASH_SOURCE[0]}") [--since <git-date>] [--ref <ref>]" >&2
            echo "fail:fleet-activity:unknown-argument:$1"
            exit 0 ;;
    esac
done

if ! git -C "$ROOT" rev-parse --verify "$REF" >/dev/null 2>&1; then
    echo "  '$REF' does not resolve; NOTHING was counted. An empty result here would" >&2
    echo "  mean 'could not look', not 'nobody landed'." >&2
    echo "fail:fleet-activity:bad-ref:$REF"
    exit 0
fi

_rows="$(mktemp)" || exit 2
trap 'rm -f "$_rows"' EXIT INT TERM

total=0
while IFS='|' read -r sha email; do
    [ -n "$sha" ] || continue
    total=$((total + 1))
    # A commit is PLAN-ONLY when every path it touches is under plan/. That is
    # the same boundary the push lanes use, so the count can be read against the
    # gate cost each class actually pays.
    nonplan="$(git -C "$ROOT" show --name-only --format= "$sha" 2>/dev/null | grep -vcE '^plan/')"
    kind="code"; [ "${nonplan:-0}" -eq 0 ] && kind="plan"
    domain="${email#*@}"
    shared=0
    for _sp in $SHARED_PROVIDERS; do [ "$domain" = "$_sp" ] && { shared=1; break; }; done
    if [ "$shared" -eq 1 ] || [ "$domain" = "$email" ]; then
        printf 'bucket\t%s\t%s\n' "$email" "$kind" >> "$_rows"
    else
        # The domain's FIRST LABEL is the host under every convention the fleet
        # currently uses — <host>.ayahuitlcalpan.com and <Host>.local alike.
        host="${domain%%.*}"
        printf 'host\t%s\t%s\n' "$host" "$kind" >> "$_rows"
    fi
done < <(git -C "$ROOT" log --since="$WINDOW" --format='%H|%ae' "$REF" 2>/dev/null)

if [ "$total" -eq 0 ]; then
    echo "  no commits on $REF in the last $WINDOW. That is a fact about the WINDOW," >&2
    echo "  not about any host: nobody is shown idle by this, and idleness is" >&2
    echo "  established by asking (1005-class)." >&2
    echo "skipped:fleet-activity:no-commits:window=$WINDOW"
    exit 0
fi

printf 'fleet-activity: ref=%s window=%s commits=%s\n' "$REF" "$WINDOW" "$total" >&2
printf '  %-14s %5s %5s %5s\n' "HOST" "all" "plan" "code" >&2
nhosts=0
while read -r h; do
    [ -n "$h" ] || continue
    nhosts=$((nhosts + 1))
    a=$(grep -c "^host	$h	" "$_rows"); p=$(grep -c "^host	$h	plan$" "$_rows"); c=$(grep -c "^host	$h	code$" "$_rows")
    printf '  %-14s %5s %5s %5s\n' "$h" "$a" "$p" "$c" >&2
done < <(grep '^host	' "$_rows" | cut -f2 | sort -u)

nbucket=0
while read -r b; do
    [ -n "$b" ] || continue
    nbucket=$((nbucket + 1))
    a=$(grep -c "^bucket	$b	" "$_rows"); p=$(grep -c "^bucket	$b	plan$" "$_rows"); c=$(grep -c "^bucket	$b	code$" "$_rows")
    printf '  %-14s %5s %5s %5s   UNATTRIBUTED BUCKET — not a host (1012-hu7d)\n' "${b%@*}@…" "$a" "$p" "$c" >&2
done < <(grep '^bucket	' "$_rows" | cut -f2 | sort -u)

echo "  A host absent above landed nothing in this window. That is ALL it means —" >&2
echo "  mid-analysis, gating, blocked and asleep are indistinguishable from here." >&2
echo "  IDLENESS IS ESTABLISHED BY ASKING (1005-class); this cannot answer it." >&2
echo "ok:fleet-activity:${total}c:${nhosts}h:${nbucket}b:window=$WINDOW"
