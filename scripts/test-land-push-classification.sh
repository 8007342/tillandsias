#!/usr/bin/env bash
# @trace order:1366-d5v2
# test-land-push-classification.sh — pins WHAT the land tool pushes and HOW it
# names a push that did not land.
#
# Measured on yoga 2026-09-23: run from a work branch, the tool merged trunk
# into HEAD and gated HEAD, then ran `git push origin linux-next` — the LOCAL
# branch of that name, a stale ancestor of trunk. The push was refused
# non-fast-forward and the tool printed "origin moved — retrying" four times
# while origin never moved, ending attempts-exhausted. A plain push of the same
# HEAD landed at once.
#
#   ARM 1  HEAD is a work branch, local linux-next is a stale ancestor of origin:
#          the tool lands HEAD (origin's ref equals HEAD afterwards).
#   ARM 2  a push that fails race-shaped ("non-fast-forward") while origin does
#          NOT move: the tool must not say "origin moved"; it refuses by name
#          and prints the push's own output.
#   ARM 3  CONTROL: origin genuinely moves during the first push; the tool still
#          says origin moved, retries, and lands.
#   ARM 4  from a linked worktree whose credential helper is a RELATIVE
#          `store --file=.git/...`, an auth failure names that cause.
#
# Hermetic: scratch bare origin, scratch checkout with a copy of the tool, a
# green stub gate, and a `git` wrapper on PATH that intercepts `push` only.
# TILLANDSIAS_LAND_UNDER_TEST overrides the tool under test (mutation control:
# the pre-fix tool must fail ARMS 1 and 2). bash 3.2 clean (761-g36m).
set -u
REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDSH="${TILLANDSIAS_LAND_UNDER_TEST:-$REAL_ROOT/scripts/land-on-platform-branch.sh}"
REAL_GIT="$(command -v git)"
fails=0; passes=0
ok()  { passes=$((passes + 1)); echo "ok: $1"; }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }
G() { "$REAL_GIT" -c user.email=t@t -c user.name=t "$@"; }

# scratch <push-mode>: mode is passthrough | fail-unmoved | move-then-fail | auth
scratch() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/land-push-class.XXXXXX")"
    G init -q --bare "$d/origin.git"
    G init -q -b linux-next "$d/w"
    # The tool under test rebases and merges with the REAL git, which needs an
    # identity. A host whose FQDN lets git auto-derive one passes without this;
    # inside the builder toolbox (bare hostname) the rebase fails for want of
    # an identity and the tool reads that as a conflict: ARMS 1 and 3 went red
    # on macuahuitl's gate while 8/8 standalone (2026-09-23).
    G -C "$d/w" config user.email t@t
    G -C "$d/w" config user.name t
    G -C "$d/w" remote add origin "$d/origin.git"
    mkdir -p "$d/w/scripts" "$d/bin"
    cp "$LANDSH" "$d/w/scripts/land-on-platform-branch.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/w/build.sh"; chmod +x "$d/w/build.sh"
    G -C "$d/w" add -A
    G -C "$d/w" commit -q -m base
    G -C "$d/w" push -q origin linux-next
    echo "$1" > "$d/mode"
    : > "$d/pushes"
    cat > "$d/bin/git" <<WRAP
#!/usr/bin/env bash
if [ "\${1:-}" = "push" ]; then
    echo "\$*" >> "$d/pushes"
    mode=\$(cat "$d/mode")
    case "\$mode" in
        fail-unmoved)
            echo " ! [rejected]        linux-next -> linux-next (non-fast-forward)" >&2
            echo "error: failed to push some refs to '$d/origin.git'" >&2
            exit 1 ;;
        move-then-fail)
            echo passthrough > "$d/mode"
            "$REAL_GIT" clone -q -b linux-next "$d/origin.git" "$d/other" 2>/dev/null
            "$REAL_GIT" -C "$d/other" -c user.email=o@o -c user.name=o commit -q --allow-empty -m "sibling landed"
            "$REAL_GIT" -C "$d/other" push -q origin linux-next
            echo " ! [rejected]        linux-next -> linux-next (fetch first)" >&2
            exit 1 ;;
        auth)
            echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
            exit 128 ;;
    esac
fi
exec "$REAL_GIT" "\$@"
WRAP
    chmod +x "$d/bin/git"
    echo "$d"
}

run_land() { # <dir> <workdir>
    ( cd "$2" && PATH="$1/bin:$PATH" GIT_TERMINAL_PROMPT=0 TILLANDSIAS_LAND_AUTH_RETRY_DELAY=0 \
        bash scripts/land-on-platform-branch.sh linux-next 2 > "$1/out.txt" 2> "$1/err.txt" < /dev/null; echo $? > "$1/rc" )
}
origin_head() { "$REAL_GIT" --git-dir="$1/origin.git" rev-parse refs/heads/linux-next; }

# ARM 1: land from a work branch while local linux-next is a stale ancestor.
d="$(scratch passthrough)"
G -C "$d/w" switch -q -c work/0000-test
G -C "$d/w" commit -q --allow-empty -m "the gated work"
G -C "$d/w" branch -f linux-next "$(G -C "$d/w" rev-list --max-parents=0 HEAD)"
G clone -q -b linux-next "$d/origin.git" "$d/sib" 2>/dev/null
G -C "$d/sib" commit -q --allow-empty -m "trunk moved before the land"
G -C "$d/sib" push -q origin linux-next
run_land "$d" "$d/w"
head_now="$(G -C "$d/w" rev-parse HEAD)"
[ "$(origin_head "$d")" = "$head_now" ] \
    && ok "ARM 1: from a work branch the tool lands HEAD, not the local linux-next" \
    || bad "ARM 1: origin=$(origin_head "$d" | cut -c1-9) HEAD=$(printf %s "$head_now" | cut -c1-9) rc=$(cat "$d/rc") $(tail -2 "$d/err.txt" | tr '\n' ' ')"
rm -rf "$d"

# ARM 2: race-shaped failure, origin unmoved -> refuse by name, no "origin moved".
d="$(scratch fail-unmoved)"
G -C "$d/w" commit -q --allow-empty -m unpushed
before="$(origin_head "$d")"
run_land "$d" "$d/w"
[ "$(origin_head "$d")" = "$before" ] || bad "ARM 2 PREMISE: origin moved in the unmoved arm"
if grep -q 'origin moved' "$d/out.txt" "$d/err.txt"; then
    bad "ARM 2: said 'origin moved' while origin sat at ${before:0:9}"
else
    ok "ARM 2: no 'origin moved' when origin did not move"
fi
grep -q '^refused:land:push-failed-origin-unmoved:' "$d/err.txt" \
    && ok "ARM 2: refused by name (rc=$(cat "$d/rc"))" \
    || bad "ARM 2: no refused:land:push-failed-origin-unmoved verdict (rc=$(cat "$d/rc"))"
grep -q 'non-fast-forward' "$d/err.txt" \
    && ok "ARM 2: the push's own output is printed" \
    || bad "ARM 2: the push log was not shown"
rm -rf "$d"

# ARM 3 (CONTROL): origin really moves during the push -> still a race, lands.
d="$(scratch move-then-fail)"
G -C "$d/w" commit -q --allow-empty -m unpushed
run_land "$d" "$d/w"
grep -q 'origin moved' "$d/out.txt" \
    && ok "ARM 3 CONTROL: a real move is still reported as origin moved" \
    || bad "ARM 3 CONTROL: no 'origin moved' line for a real move"
grep -q '^ok:land:' "$d/out.txt" \
    && ok "ARM 3 CONTROL: the retry lands" \
    || bad "ARM 3 CONTROL: did not land (rc=$(cat "$d/rc")) $(tail -2 "$d/err.txt" | tr '\n' ' ')"
rm -rf "$d"

# ARM 4: linked worktree + relative store helper -> the cause is named.
d="$(scratch auth)"
G -C "$d/w" config credential.helper "store --file=.git/.gh-credentials"
G -C "$d/w" worktree add -q -b wt-branch "$d/wt" 2>/dev/null
cp "$LANDSH" "$d/wt/scripts/land-on-platform-branch.sh"
G -C "$d/wt" commit -q --allow-empty -m unpushed
run_land "$d" "$d/wt"
[ "$(cat "$d/rc")" = 5 ] && ok "ARM 4: auth failure still refuses with exit 5" || bad "ARM 4: rc=$(cat "$d/rc"), wanted 5"
grep -q 'cause:land:relative-credential-store-in-linked-worktree:.git/.gh-credentials' "$d/err.txt" \
    && ok "ARM 4: the relative-helper-in-a-worktree cause is named" \
    || bad "ARM 4: cause not named: $(grep -m2 -E 'refused|cause' "$d/err.txt" | tr '\n' ' ')"
rm -rf "$d"

echo "land-push-classification fixture: ${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ] && { echo "ok:land-push-classification:${passes}/${passes}"; exit 0; } || exit 1
