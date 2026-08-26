#!/usr/bin/env bash
# test-check-credential-channel.sh — pin the 860-g798 fix: `gh auth status`
# succeeding while git cannot push non-interactively must NEVER produce a bare
# ok. The measured incident: a fresh clone passed `ok:gh-keyring`, entered
# committable work, and the first push hung >10 minutes on Git Credential
# Manager's interactive prompt (esmeraldinha, 2026-08-23).
#
# Hermetic: a stub `gh` on PATH answers auth status green; the push probe is a
# fixture seam (TILLANDSIAS_CRED_PROBE_CMD) so no network is touched; each
# scenario runs in its own scratch repo.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REAL_ROOT/scripts/check-credential-channel.sh"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/cred-channel-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

mkdir -p "$W/bin" "$W/bin-noauth"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# auth status green; everything else inert.
[ "$1 ${2:-}" = "auth status" ] && exit 0
exit 0
STUB
chmod +x "$W/bin/gh"

# gh present but holding NO usable auth — the shape where no token arm can
# rescue the probe. Needed by the 892-aw9p arms: without it PATH falls through
# to the REAL gh, and arm 12 passes on this host's live credential rather than
# on the condition it claims to test.
cat >"$W/bin-noauth/gh" <<'NOAUTH'
#!/usr/bin/env bash
[ "$1 ${2:-}" = "auth status" ] && { echo "not logged in" >&2; exit 1; }
exit 1
NOAUTH
chmod +x "$W/bin-noauth/gh"

scratch() {
    local d="$W/repo-$1"
    git init -q -b main "$d"
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    printf '%s' "$d"
}

# Run the guard inside a scratch repo with the stub gh and a controlled probe.
# Env/store arms are neutralised: no GH_TOKEN/GITHUB_TOKEN, no .gh-credentials.
run_guard() {
    local repo="$1" probe="$2"
    ( cd "$repo" && \
      env -u GH_TOKEN -u GITHUB_TOKEN PATH="$W/bin:$PATH" \
          TILLANDSIAS_CRED_PROBE_CMD="$probe" \
          bash "$GUARD" 2>"$repo/.stderr" )
}

# ── 1. THE INCIDENT SHAPE: gh green + probe fails + interactive helper ──────
D="$(scratch a)"
git -C "$D" config credential.helper manager
out="$(run_guard "$D" "false")"; rc=$?
case "$out" in
    *blocked:interactive-credential-helper*) ok "gh-green + GCM helper -> blocked, not ok (rc=$rc)" ;;
    *) bad "incident shape returned: $out (rc=$rc)" ;;
esac
[ "$rc" -ne 0 ] || bad "incident shape must exit non-zero"
grep -q "credential-store --file" "$D/.stderr" && ok "remedy names the repo-local seeding" \
    || bad "remedy missing from stderr"

# ── 2. gh green + probe fails + NO interactive helper -> distinct verdict ───
D="$(scratch b)"
out="$(run_guard "$D" "false")"; rc=$?
case "$out" in
    # ORDER 894-scxy replaced the generic blocked:gh-cli-only with a verdict
    # that names the layer that FAILED. Here the stub's `gh api user` succeeds,
    # so GitHub accepts the identity and only the PUSH is refused — which is a
    # different remedy (repo permission / SSO / scope) than a dead token.
    *blocked:credential-accepted-but-push-refused*)
        ok "gh-green + push refused -> names the push, not the keyring" ;;
    *) bad "no-helper shape returned: $out" ;;
esac
[ "$rc" -ne 0 ] || bad "a push-refused verdict must exit non-zero"

# ── 3. gh green + probe SUCCEEDS -> the verified ok ─────────────────────────
D="$(scratch c)"
out="$(run_guard "$D" "true")"; rc=$?
case "$out" in
    ok:gh-keyring-push-verified) ok "working channel -> ok:gh-keyring-push-verified (rc=$rc)" ;;
    *) bad "working shape returned: $out" ;;
esac
[ "$rc" -eq 0 ] || bad "verified ok must exit 0"

# ── 4. the repo-local store STILL short-circuits first (no regression) ──────
D="$(scratch d)"
printf 'x\n' > "$(git -C "$D" rev-parse --absolute-git-dir)/.gh-credentials"
out="$(run_guard "$D" "false")"
case "$out" in
    ok:gh-credentials-store) ok "repo-local store arm unchanged, checked first" ;;
    *) bad "store arm returned: $out" ;;
esac

# ── 5. MUTATION CONTROL: the pre-fix guard must FAIL this suite ─────────────
# Reconstruct the old arm (bare ok:gh-keyring on gh auth status alone) and
# assert scenario 1 would have passed it — proving the suite detects the
# regression this fix exists to prevent.
OLD="$W/old-guard.sh"
sed -e 's/ok:gh-keyring-push-verified/ok:gh-keyring/' \
    -e 's/^\( *\)_probe_cmd=.*/\1_probe_cmd="true"/' "$GUARD" > "$OLD"
D="$(scratch e)"
git -C "$D" config credential.helper manager
out="$( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN PATH="$W/bin:$PATH" bash "$OLD" 2>/dev/null )"
case "$out" in
    ok:gh-keyring)
        ok "MUTATION: the pre-fix arm passes the incident shape — the suite has teeth" ;;
    *) bad "mutation reconstruction unexpected: $out" ;;
esac

# ── 6. ORDER 876-exg2: OUR OWN PRE-PUSH HOOK REFUSING IS NOT A CREDENTIAL ───
# FAULT. Fully hermetic: a local bare remote (no network, no credential of any
# kind) and a pre-push hook that always refuses. The default probe therefore
# fails for a reason that has nothing to do with authentication, exactly as it
# does on a real host whose gate stamp went stale behind a fetch, a claim
# fragment, or the previous cycle's mandated attestation commit.
#
# These arms deliberately do NOT set TILLANDSIAS_CRED_PROBE_CMD — the seam the
# arms above use bypasses the retry, and the whole defect lives on the default
# path.
run_guard_default() {
    ( cd "$1" && \
      env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
          PATH="$W/bin:$PATH" bash "$GUARD" 2>"$1/.stderr" )
}

with_remote() { # with_remote <name> <hook-body> ; echoes the repo path
    local d="$W/hookrepo-$1" bare="$W/bare-$1.git"
    git init -q --bare "$bare"
    git init -q -b main "$d"
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    git -C "$d" remote add origin "$bare"
    git -C "$d" push -q origin main 2>/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m y
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$d/.git/hooks/pre-push"
    chmod +x "$d/.git/hooks/pre-push"
    printf '%s' "$d"
}

D="$(with_remote refuse 'echo "✗ pre-push refused: the tree changed since ./build.sh --check last passed" >&2; exit 1')"
out="$(run_guard_default "$D")"; rc=$?
case "$out" in
    ok:gh-keyring-push-verified-hook-refused)
        ok "hook refusal -> ok:...-hook-refused, NOT blocked:* (rc=$rc)" ;;
    blocked:*)
        bad "REGRESSION: our own hook refusing still reads as a credential fault: $out" ;;
    *) bad "hook-refusal shape returned: $out (rc=$rc)" ;;
esac
[ "$rc" -eq 0 ] || bad "a hook refusal must exit 0 — the skill hard-stops on non-zero"
grep -q 'build.sh --check' "$D/.stderr" \
    && ok "the note names ./build.sh --check, not credential seeding" \
    || bad "note must name the gate, not the credential remedy"
grep -q 'credential-store --file' "$D/.stderr" \
    && bad "the note must NOT print the credential-seeding remedy" \
    || ok "no misleading credential remedy printed"

# ── 7. NEGATIVE CONTROL — the true positive 860-g798 caught must survive. ───
# When the push cannot authenticate at ALL, --no-verify does not rescue it and
# the verdict must still be blocked. Here the remote path does not exist, so
# both probes fail for a real transport/auth reason.
D="$(with_remote broken 'exit 0')"
git -C "$D" remote set-url origin "$W/does-not-exist.git"
out="$(run_guard_default "$D")"; rc=$?
case "$out" in
    blocked:*) ok "an unreachable remote is still blocked:* (rc=$rc) — the retry rescues nothing real" ;;
    *) bad "unreachable-remote shape returned: $out (rc=$rc) — the true positive was weakened" ;;
esac
[ "$rc" -ne 0 ] || bad "a genuinely broken channel must exit non-zero"

# ── 8. MUTATION CONTROL for this fix: the PRE-876-exg2 guard must fail arm 6. ─
# Strip the retry block and assert the old script calls the hook refusal a
# credential fault — proving arm 6 has teeth rather than passing by luck.
PRE="$W/pre-876-guard.sh"
awk '/# ORDER 876-exg2\./{skip=1} skip && /^    _helpers=/{skip=0} skip{next} {print}' \
    "$GUARD" > "$PRE"
D="$(with_remote mutation 'echo refused >&2; exit 1')"
out="$( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
        PATH="$W/bin:$PATH" bash "$PRE" 2>/dev/null )"
case "$out" in
    # Asserts the pre-fix guard REFUSES; the exact token is incidental to that
    # claim and moved when 894-scxy made the verdicts specific.
    blocked:*)
        ok "MUTATION: the pre-fix guard calls our own hook a credential fault — arm 6 has teeth ($out)" ;;
    *) bad "mutation reconstruction unexpected: $out" ;;
esac

# ── 8b. ORDER 886-qmdz — a BEHIND branch must not read as a credential fault. ─
# `git push origin HEAD` names a concrete branch, so a local branch behind its
# remote counterpart is refused as a non-fast-forward — AFTER the credential
# authenticated. Start-Of-Cycle fetches (skill step 2) before fast-forwarding
# (step 5), so this is the single most normal state a cycle enters the guard in.
# The 876-exg2 retry cannot rescue it: --no-verify removes the hook, not the
# non-fast-forward. Here the hook is a no-op, so ref state is the ONLY cause.
behind_repo() { # behind_repo <name>; echoes a repo whose branch is behind origin
    local d="$W/behindrepo-$1" bare="$W/bare-behind-$1.git"
    git init -q --bare -b main "$bare"
    git init -q -b main "$d"
    git -C "$d" remote add origin "$bare"
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    git -C "$d" push -q origin main
    # Advance origin, then rewind the local branch: strictly behind, clean tree.
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
    git -C "$d" push -q origin main
    git -C "$d" reset -q --hard HEAD~1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.git/hooks/pre-push"
    chmod +x "$d/.git/hooks/pre-push"
    printf '%s' "$d"
}
D="$(behind_repo one)"
# precondition: the plain probe really is refused, and for the ref-state reason
if ( cd "$D" && git push --dry-run --no-verify origin HEAD >/dev/null 2>&1 ); then
    bad "fixture is not actually behind — arm 8b would pass vacuously"
else
    ok "fixture precondition: a behind branch really is refused by the remote"
fi
out="$(run_guard_default "$D")"; rc=$?
case "$out" in
    ok:gh-keyring-push-verified-refstate-refused)
        ok "behind branch -> ok:...-refstate-refused, NOT blocked:* (rc=$rc)" ;;
    blocked:*)
        bad "REGRESSION: a branch merely behind origin reads as a credential fault: $out" ;;
    *) bad "behind-branch shape returned: $out (rc=$rc)" ;;
esac
[ "$rc" -eq 0 ] || bad "a ref-state refusal must exit 0 — the skill hard-stops on non-zero"
grep -q 'ff-only' "$D/.stderr" \
    && ok "the note names the fast-forward remedy" \
    || bad "note must name the branch update, not credential seeding"
grep -q 'credential-store --file' "$D/.stderr" \
    && bad "the note must NOT print the credential-seeding remedy" \
    || ok "no misleading credential remedy printed for a ref-state refusal"

# ── 8c. MUTATION CONTROL for 886-qmdz: the pre-fix guard must fail arm 8b. ────
PRE2="$W/pre-886-guard.sh"
awk '/# ORDER 886-qmdz\./{skip=1} skip && /^    _helpers=/{skip=0} skip{next} {print}' \
    "$GUARD" > "$PRE2"
D2="$(behind_repo two)"
out="$( cd "$D2" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
        PATH="$W/bin:$PATH" bash "$PRE2" 2>/dev/null )"
case "$out" in
    blocked:*)
        ok "MUTATION: the pre-fix guard calls a behind branch a credential fault — arm 8b has teeth ($out)" ;;
    *) bad "mutation reconstruction unexpected: $out" ;;
esac

# ═══ ORDER 892-aw9p: a correct verdict has a SHELF LIFE ══════════════════════
# calmecacpilli, 2026-08-25: the guard passed at Start-Of-Cycle, two pushes
# succeeded, and ~50 minutes later the keyring token was invalid. Nothing the
# guard measured was wrong — the verdict was true when issued. The failure
# surfaced after the work and after a 142s gate, with the exit contract
# forbidding an unpushed exit, so the host was wedged rather than delayed.

# ── 10. reverify passes through a healthy channel unchanged. ─────────────────
D="$(with_remote reverify_ok 'exit 0')"
out="$( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
        PATH="$W/bin:$PATH" bash "$GUARD" reverify 2>/dev/null )"; rc=$?
case "$out" in
    ok:*) ok "reverify on a healthy channel -> $out (rc=$rc)" ;;
    *)    bad "reverify broke the healthy path: $out (rc=$rc)" ;;
esac
[ "$rc" -eq 0 ] || bad "a healthy reverify must exit 0"

# ── 11. THE HEADLINE: a credential that DIED reads differently from one that ─
#        was never there. Same repair cost, very different diagnosis, and the
#        guard previously reported both as missing:no-credential-channel.
D="$(with_remote reverify_died 'exit 0')"
# a pass is recorded...
( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
  PATH="$W/bin:$PATH" bash "$GUARD" >/dev/null 2>&1 )
[ -s "$D/.git/tillandsias-credential-verified" ] \
    && ok "a passing verdict records a stamp" \
    || bad "no stamp written on a pass — reverify cannot tell died from absent"
# ...then the channel dies (unreachable remote + no token anywhere)
git -C "$D" remote set-url origin "$W/does-not-exist.git"
out="$( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
        PATH="$W/bin-noauth:$PATH" bash "$GUARD" reverify 2>"$D/.rv" )"; rc=$?
case "$out" in
    blocked:credential-expired-mid-cycle)
        ok "a credential that DIED mid-cycle is named as such (rc=$rc)" ;;
    *)  bad "expiry not distinguished: $out (rc=$rc)" ;;
esac
[ "$rc" -ne 0 ] || bad "an expired credential must exit non-zero"
grep -q 'DIED DURING THIS CYCLE' "$D/.rv" \
    && ok "the diagnosis states it worked and then stopped" \
    || bad "stderr must say the credential died, not that it is absent"
grep -q 'gh auth refresh' "$D/.rv" \
    && ok "the remedy names the token refresh" \
    || bad "remedy must name gh auth refresh"
grep -q 'salvage-dirty-worktree' "$D/.rv" \
    && ok "it points at the 872-c9nd salvage path instead of discarding work" \
    || bad "a wedged host must be told how to preserve its work"

# ── 12. NEGATIVE CONTROL: with NO prior pass, reverify must NOT claim expiry. ─
# A host that never had a credential has not lost one. Claiming otherwise sends
# the reader to refresh a token that never existed.
D="$(with_remote reverify_never 'exit 0')"
git -C "$D" remote set-url origin "$W/does-not-exist.git"
rm -f "$D/.git/tillandsias-credential-verified"
out="$( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
        PATH="$W/bin-noauth:$PATH" bash "$GUARD" reverify 2>/dev/null )"; rc=$?
case "$out" in
    blocked:credential-expired-mid-cycle)
        bad "claimed an expiry with no prior pass — a host that never had one has not lost one" ;;
    blocked:*|missing:*) ok "no prior pass -> ordinary verdict, not a false expiry ($out)" ;;
    *) bad "unexpected no-stamp verdict: $out (rc=$rc)" ;;
esac

# ── 13. The healthy path costs NO extra round trip per push. ─────────────────
# The exit criterion that keeps this from trading a rare failure for a permanent
# slowdown: reverify is a separate mode the skill calls ONCE before the gate, not
# something wired into every git operation. Assert the default path did not grow
# a second probe.
# Count INVOCATIONS, not mentions. The first version of this assertion used a
# bare `grep -c 'push --dry-run'` and counted two COMMENT lines describing the
# probe — the same incidental-co-occurrence error fixed in the promotion gate
# earlier tonight (888-m75r), reproduced here in a test that was supposed to be
# checking for exactly that kind of sloppiness.
probes="$(grep -nE 'timeout [0-9]+ +git push --dry-run|_probe_cmd=' "$GUARD" \
          | grep -vcE ':[[:space:]]*#')"
[ "$probes" -le 3 ] \
    && ok "reverify added no probe to the hot path ($probes invocation sites)" \
    || bad "reverify added probes to the hot path ($probes invocation sites)"

# ═══ ORDER 894-scxy: name the layer that FAILED, not the one we OBSERVED ═════
# gh prints "The token in keyring is invalid". MEASURED on pirria 2026-08-25:
# secret-service entry present, login collection UNLOCKED (`b false`), token
# retrieved intact at 40 chars — and GitHub answered 401 on it. The keyring was
# healthy in every component. THREE HOSTS diagnosed the wrong subsystem from
# that one string; one built a mechanism on the premise.
#
# The packet requires BOTH directions proven by fixture, because one direction
# is an assertion. All four states below are driven by a stubbed `gh` so they
# are hermetic and never touch a real credential — and none of them extracts a
# secret, which is the security constraint two hosts learned the hard way.

# Helper: a repo whose push always fails, with a scripted `gh` on PATH.
layer_case() { # layer_case <name> <gh-api-user-rc> <gh-api-user-stderr>
    local name="$1" apirc="$2" apierr="$3"
    local d="$W/layer-$name" bin="$W/layerbin-$name"
    rm -rf "$d" "$bin"; mkdir -p "$bin"
    git init -q -b main "$d"
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    git -C "$d" remote add origin "$W/does-not-exist.git"   # push always fails
    cat >"$bin/gh" <<GHEOF
#!/usr/bin/env bash
case "\$1 \${2:-}" in
    "auth status") echo "Logged in to github.com"; exit 0 ;;
    "api user")    printf '%s\n' "$apierr" >&2; exit $apirc ;;
esac
exit 0
GHEOF
    chmod +x "$bin/gh"
    printf '%s' "$d|$bin"
}

run_layer() { # run_layer <dir> <bin> [extra-env...]
    local d="$1" bin="$2"; shift 2
    ( cd "$d" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_CRED_PROBE_CMD \
      "$@" PATH="$bin:$PATH" bash "$GUARD" 2>"$d/.err" )
}

# ── 14. DIRECTION ONE: healthy keyring, token REJECTED by GitHub. ────────────
# The pirria state. Must name the ACCOUNT, and must NOT send the reader to the
# keyring — that misdirection is the entire defect.
IFS='|' read -r LD LB <<<"$(layer_case rejected 1 'HTTP 401: Bad credentials')"
out="$(run_layer "$LD" "$LB" HOME="$W/nohome-rejected")"; rc=$?
case "$out" in
    blocked:credential-rejected-by-github)
        ok "healthy keyring + 401 -> names GitHub, not the keyring (rc=$rc)" ;;
    *)  bad "rejected direction returned: $out (rc=$rc)" ;;
esac
[ "$rc" -ne 0 ] || bad "a rejected credential must exit non-zero"
grep -q 'keyring is not the problem' "$LD/.err" \
    && ok "the diagnosis says outright that the keyring is not the problem" \
    || bad "must state the keyring is not the problem"
# PIN THE NEGATION, NOT THE ABSENCE OF THE WORD. The first version of this
# assertion grepped for "secret-service" and fired on the sentence
# "Do NOT go looking at secret-service" — a warning against the misdirection,
# read as the misdirection itself. A bare word-absence test cannot tell an
# imperative from its negation, which is the same incidental-match defect this
# suite exists to catch, committed inside the suite. Assert the sentence that
# actually does the work.
grep -q 'Do NOT go looking at secret-service' "$LD/.err" \
    && ok "explicitly steers the reader AWAY from the secret store" \
    || bad "must actively redirect off the keyring, not merely omit it"
grep -qi 'unlock\|secret-tool' "$LD/.err" \
    && bad "prescribed a keyring action on a server-side rejection" \
    || ok "prescribes no keyring action on a rejection"

# ── 15. DIRECTION TWO: the credential cannot be RETRIEVED at all. ────────────
# No secret-service on the bus — the headless/cron shape. Nothing has been
# presented to GitHub, so naming the account here would be the mirror-image
# misattribution of the one this packet fixes.
IFS='|' read -r LD LB <<<"$(layer_case noservice 1 'connection refused')"
cat >"$LB/busctl" <<'BEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--user" ] && [ "${2:-}" = "list" ] && { echo "org.freedesktop.DBus"; exit 0; }
exit 1
BEOF
chmod +x "$LB/busctl"
out="$(run_layer "$LD" "$LB" HOME="$W/nohome-noservice")"; rc=$?
case "$out" in
    blocked:credential-unretrievable-no-keyring-service)
        ok "no secret-service on the bus -> unretrievable, not rejected (rc=$rc)" ;;
    *)  bad "no-service direction returned: $out (rc=$rc)" ;;
esac
grep -qi 'LOCAL retrieval failure' "$LD/.err" \
    && ok "names it a LOCAL retrieval failure" \
    || bad "must distinguish local retrieval from an account problem"
grep -qi 'gh auth refresh' "$LD/.err" \
    && bad "told the reader to refresh a token that was never presented" \
    || ok "does not prescribe a token refresh for a retrieval failure"

# ── 16. DIRECTION TWO(b): the collection exists but is LOCKED. ───────────────
IFS='|' read -r LD LB <<<"$(layer_case locked 1 'connection refused')"
cat >"$LB/busctl" <<'BEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "list" ]; then
    echo "org.freedesktop.secrets"; exit 0
fi
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "get-property" ]; then
    echo "b true"; exit 0
fi
exit 1
BEOF
chmod +x "$LB/busctl"
out="$(run_layer "$LD" "$LB" HOME="$W/nohome-locked")"; rc=$?
case "$out" in
    blocked:credential-unretrievable-keyring-locked)
        ok "locked collection -> unretrievable-keyring-locked (rc=$rc)" ;;
    *)  bad "locked direction returned: $out (rc=$rc)" ;;
esac

# ── 17. THE THIRD STATE pirria NAMED: a PLAINTEXT token, no keyring at all. ──
# The absence of an oauth_token key in ~/.config/gh/hosts.yml is what proves gh
# is on secret-service; its PRESENCE means keyring probes say nothing about this
# host. A two-state classifier silently buckets this as "keyring healthy", which
# is the same misattribution one layer over.
IFS='|' read -r LD LB <<<"$(layer_case plaintext 1 'HTTP 401: Bad credentials')"
PH="$W/home-plaintext"; mkdir -p "$PH/.config/gh"
printf 'github.com:\n    oauth_token: REDACTED\n' > "$PH/.config/gh/hosts.yml"
out="$(run_layer "$LD" "$LB" HOME="$PH")"; rc=$?
case "$out" in
    blocked:credential-plaintext-token-rejected)
        ok "plaintext fallback is its own state, not 'keyring healthy' (rc=$rc)" ;;
    *)  bad "plaintext direction returned: $out (rc=$rc)" ;;
esac
grep -qi 'keyring probes say nothing' "$LD/.err" \
    && ok "says outright that keyring probes are irrelevant here" \
    || bad "must state why keyring probes do not apply"

# ── 18. NEGATIVE CONTROL: GitHub ACCEPTS the identity, only the push fails. ──
# Neither a keyring fault nor a dead token. Naming either would be a third
# misattribution, so this gets its own verdict pointing at push permission.
IFS='|' read -r LD LB <<<"$(layer_case accepted 0 '')"
out="$(run_layer "$LD" "$LB" HOME="$W/nohome-accepted")"; rc=$?
case "$out" in
    blocked:credential-accepted-but-push-refused)
        ok "GitHub accepts but push refused -> names the push (rc=$rc)" ;;
    *)  bad "accepted direction returned: $out (rc=$rc)" ;;
esac
grep -qi 'neither a keyring fault nor a dead token' "$LD/.err" \
    && ok "rules out BOTH previously-conflated causes explicitly" \
    || bad "must rule out keyring and token explicitly"

# ── 19. SECURITY: no arm above ever materialises a secret. ───────────────────
# Two hosts printed live gho_ values into transcripts learning this. The guard
# must decide 401-vs-200 without extracting anything.
grep -n 'secret-tool' "$GUARD" | grep -vE ':[[:space:]]*#' \
    && bad "the guard calls secret-tool, which prints the secret inline" \
    || ok "the guard never calls secret-tool — discrimination is via gh api user"

# ── 20. All five verdicts are single pinned tokens. ──────────────────────────
for v in blocked:credential-rejected-by-github \
         blocked:credential-unretrievable-no-keyring-service \
         blocked:credential-unretrievable-keyring-locked \
         blocked:credential-plaintext-token-rejected \
         blocked:credential-accepted-but-push-refused; do
    printf '%s\n' "$v" | grep -qE '^(ok:[a-z0-9-]+|blocked:[a-z0-9-]+|missing:no-credential-channel)$' \
        || bad "verdict breaks litmus:credential-channel-check-shape: $v"
done
ok "all five 894-scxy verdicts match the pinned grammar"

# ── 9. Grammar: every verdict this suite produced is a single pinned token. ──
grammar='^(ok:[a-z0-9-]+|blocked:[a-z0-9-]+|missing:no-credential-channel)$'
printf '%s\n' "ok:gh-keyring-push-verified-hook-refused" | grep -qE "$grammar" \
    && ok "the new verdict matches the pinned grammar (no second colon)" \
    || bad "the new verdict breaks litmus:credential-channel-check-shape"

if [ "$fail" -eq 0 ]; then
    echo "ok:credential-channel-fixture:all"
    exit 0
fi
echo "fail:credential-channel-fixture"
exit 1
