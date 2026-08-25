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

mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
# auth status green; everything else inert.
[ "$1 ${2:-}" = "auth status" ] && exit 0
exit 0
STUB
chmod +x "$W/bin/gh"

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
    *blocked:gh-cli-only*) ok "gh-green + unexplained probe failure -> blocked:gh-cli-only" ;;
    *) bad "no-helper shape returned: $out" ;;
esac
[ "$rc" -ne 0 ] || bad "gh-cli-only must exit non-zero"

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
    blocked:gh-cli-only)
        ok "MUTATION: the pre-fix guard calls our own hook a credential fault — arm 6 has teeth" ;;
    *) bad "mutation reconstruction unexpected: $out" ;;
esac

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
