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

if [ "$fail" -eq 0 ]; then
    echo "ok:credential-channel-fixture:all"
    exit 0
fi
echo "fail:credential-channel-fixture"
exit 1
