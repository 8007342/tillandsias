#!/usr/bin/env bash
# @trace order:1846-dykd
# Fixture: promote-stable.sh step 5 enqueues ONE website-update task when the
# range previous-stable..release carries a `Website-Update:` trailer, never a
# second for the same tag, nothing when there is no trailer, and a failing
# client defers without failing the promotion.
#
# The function under test is EXTRACTED from scripts/promote-stable.sh (so the
# fixture cannot drift from what promotion runs) and driven against a
# throwaway repo and a stub coordinator client that records its argv. A static
# arm proves promote-stable.sh calls it after step 4 and before `promoted:`.
# Exit 0 pass, 1 fail.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS="$ROOT/scripts/promote-stable.sh"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/website-update.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ── static: called after step 4, before the final promoted: line ────────────
deploy=$(grep -n '^_advance_deploy_ref "\$COMMIT" "\$TAG"$' "$PS" | cut -d: -f1)
step5=$(grep -n '^_enqueue_website_update "\$PREV_STABLE" "\$COMMIT" "\$TAG"$' "$PS" | cut -d: -f1)
prevcap=$(grep -n '^PREV_STABLE="\$(git' "$PS" | cut -d: -f1)
tagmove=$(grep -n '^git -C "\$REPO_ROOT" tag -f -a stable -m "Stable channel: promoted' "$PS" | cut -d: -f1)
last=$(grep -n '^echo "promoted:\$TAG"$' "$PS" | cut -d: -f1)
if [ -n "$deploy" ] && [ -n "$step5" ] && [ -n "$last" ] && [ "$deploy" -lt "$step5" ] && [ "$step5" -lt "$last" ]; then
    ok "static: step 5 runs after step 4 and before promoted:"
else bad "static: step 5 is not between step 4 and promoted: (deploy=$deploy step5=$step5 last=$last)"; fi
if [ -n "$prevcap" ] && [ -n "$tagmove" ] && [ "$prevcap" -lt "$tagmove" ]; then
    ok "static: the previous stable is read before step 3 moves the tag"
else bad "static: PREV_STABLE is not captured before the tag moves"; fi

# ── the function, extracted ──────────────────────────────────────────────────
awk '/^WEBSITE_NS=/{p=1} p{print} p&&/^}$/{exit}' "$PS" > "$work/step5.sh"
grep -q '^_enqueue_website_update() {' "$work/step5.sh" || { bad "could not extract _enqueue_website_update"; exit 1; }

# A repo: v1 (previous stable) -> a trailer commit -> v2 (the release).
repo="$work/repo"
git init -q "$repo"
gitc() { git -C "$repo" -c user.email=f@x.invalid -c user.name=f "$@"; }
gitc commit -q --allow-empty -m "one"
v1=$(git -C "$repo" rev-parse HEAD)
gitc commit -q --allow-empty -m "$(printf 'retire local launches\n\nWebsite-Update: local launches are retired; the site lists them as a main feature')"
gitc commit -q --allow-empty -m "two"
v2=$(git -C "$repo" rev-parse HEAD)
gitc commit -q --allow-empty -m "three, no trailer"
v3=$(git -C "$repo" rev-parse HEAD)

# Stub client: records argv; STUB_RC decides its exit.
cat > "$work/plan" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
chmod 755 "$work/plan"

run() { # $1=prev $2=commit $3=tag ; env: STUB_RC
    ( cd "$repo" && REPO_ROOT="$ROOT" XDG_STATE_HOME="$work/state" TILLANDSIAS_PLAN_BIN="$work/plan" \
        STUB_LOG="$work/calls" bash -c ". '$work/step5.sh'; _enqueue_website_update \"\$@\"" _ "$1" "$2" "$3" )
}
calls() { [ -f "$work/calls" ] && wc -l < "$work/calls" | tr -d ' ' || echo 0; }

# enqueue once
out=$(run "$v1" "$v2" v9.0.0)
[ "$(calls)" = 1 ] && ok "enqueue: exactly one client call" || bad "enqueue: $(calls) client calls"
grep -q -- '--ns 8007342/tillandsias.org' "$work/calls" && ok "enqueue: on the site namespace" || bad "enqueue: wrong namespace: $(cat "$work/calls")"
grep -q '"tag":"v9.0.0"' "$work/calls" && grep -q 'local launches are retired' "$work/calls" \
    && ok "enqueue: carries the tag and the reason" || bad "enqueue: payload lacks tag or reason: $(cat "$work/calls")"
grep -qiE 'host|fleet|yoga|macuahuitl' <<<"$(grep -o '{.*}' "$work/calls")" \
    && bad "enqueue: payload carries host or fleet detail" || ok "enqueue: payload is only tag + reasons"
[ "$out" = "website-update:enqueued:v9.0.0:ns=8007342/tillandsias.org" ] && ok "enqueue: says so" || bad "enqueue: line was: $out"

# idempotent
out=$(run "$v1" "$v2" v9.0.0)
[ "$(calls)" = 1 ] && ok "idempotent: a second run for the tag makes no second call" || bad "idempotent: $(calls) calls"
[ "$out" = "website-update:already-enqueued:v9.0.0" ] && ok "idempotent: says so" || bad "idempotent: line was: $out"

# no trailer in range (v2..v3): vacuous arm, recorded as such in the row
out=$(run "$v2" "$v3" v9.0.1)
[ "$(calls)" = 1 ] && [ -z "$out" ] && ok "no trailer (vacuous): no call, no line" || bad "no trailer: calls=$(calls) line=$out"

# client fails: deferred, promotion unaffected
out=$(STUB_RC=7 run "$v1" "$v2" v9.0.2; echo "rc=$?")
grep -q '^website-update:deferred:v9.0.2:client-exit-7$' <<<"$out" && ok "deferred: a failing client defers" || bad "deferred: $out"
grep -q '^rc=0$' <<<"$out" && ok "deferred: step 5 returns 0, so promotion stands" || bad "deferred: step 5 failed: $out"
[ ! -e "$work/state/tillandsias/website-update/v9.0.2" ] && ok "deferred: no marker, so a re-run enqueues" || bad "deferred: marker written on failure"

# no client at all
out=$(cd "$repo" && REPO_ROOT="$ROOT" XDG_STATE_HOME="$work/state" TILLANDSIAS_PLAN_BIN="$work/absent" PATH=/usr/bin:/bin \
    bash -c ". '$work/step5.sh'; _enqueue_website_update '$v1' '$v2' v9.0.3")
[ "$out" = "website-update:deferred:v9.0.3:no-coordinator-client" ] && ok "deferred: no client" || bad "no client: $out"

[ "$fail" -eq 0 ] && echo "PASS: step 5 enqueues one website-update per tag and never blocks promotion"
exit "$fail"
