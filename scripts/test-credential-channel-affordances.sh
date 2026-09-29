#!/usr/bin/env bash
# @trace order:1497-ahmd, order:1247-amcu
#
# test-credential-channel-affordances.sh — every blocked: verdict of
# check-credential-channel.sh says why and what clears it, no remedy tells an
# agent to run the re-auth 1025-a896 forbids, and a printed remedy is EXECUTED
# and shown to clear its refusal (1247-amcu criterion 5).
#
# WHICH REMEDY IS EXECUTED, and why not gh-cli-only. 1494-kkbi ranked
# blocked:gh-cli-only #2 by recorded hits, but 894-scxy split that path into
# layer-specific verdicts, so it is now reached only when the failure layer is
# unclassifiable: most of its hits are HISTORY. The live refusal with a
# runnable remedy is blocked:interactive-credential-helper (gh green, push
# probe failing, git's helper chain interactive-only). Its remedy is printed
# as commands; arm 3 runs exactly those lines.
#
# Arms:
#   1 AUDIT       the slice-4 audit counts 0 bare sites in the script
#   2 NO RE-AUTH  no printed remedy line tells the reader to run gh auth
#                 login/refresh; the credential remedies name the operator's
#                 tillandsias --github-login
#   3 EXECUTED    reproduce interactive-credential-helper in a scratch repo,
#                 run the remedy lines the guard printed, re-run: no longer
#                 refused. NEGATIVE CONTROL: without running them it still is
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-credential-channel.sh"
FAIL=0
ok()   { printf 'ok:   %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip() { printf 'skip: %s\n' "$1"; }

# ── ARM 1 ────────────────────────────────────────────────────────────────
audit="$(bash "$ROOT/scripts/check-refusal-affordance-added.sh" --audit 2>/dev/null)"
bare="$(grep -c '^bare scripts/check-credential-channel.sh:' <<<"$audit")"
covered="$(grep -c '^covered scripts/check-credential-channel.sh:' <<<"$audit")"
if [ "$bare" -eq 0 ] && [ "$covered" -ge 15 ]; then
    ok "ARM1 0 bare verdict sites in check-credential-channel.sh ($covered covered; pre-fix 15 bare)"
else bad "ARM1 bare=$bare covered=$covered"; fi

# ── ARM 2 ────────────────────────────────────────────────────────────────
# A remedy line that INSTRUCTS the re-auth, as opposed to one that forbids it.
instructs="$(grep -nE '^[[:space:]]*(echo|printf|_afford)[^#]*(REMEDY|remedy)[^#]*gh auth (login|refresh)' "$GUARD" | grep -viE 'not|never' || true)"
reseed="$(grep -c 'tillandsias --github-login' "$GUARD")"
if [ -z "$instructs" ] && [ "$reseed" -ge 3 ]; then
    ok "ARM2 no remedy instructs gh auth login/refresh; $reseed name the operator's tillandsias --github-login"
else bad "ARM2 a remedy instructs the forbidden re-auth: $instructs (reseed mentions=$reseed)"; fi

# ── ARM 3 ────────────────────────────────────────────────────────────────
W="$(mktemp -d "${TMPDIR:-/tmp}/ccc-afford.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# A gh that is logged in, knows its user and token, and never reaches GitHub.
cat > "$W/bin/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "auth status") echo "Logged in to github.com account fixture-user (keyring)" >&2; exit 0 ;;
  "auth token")  echo "gho_fixturetoken000000000000000000000000"; exit 0 ;;
  "api user")    echo "fixture-user"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$W/bin/gh"
repo="$W/repo"; git init -q -b main "$repo"
git -C "$repo" config core.hooksPath .git/hooks
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
git -C "$repo" config credential.helper manager
# The push "works" exactly when git would stop prompting: a seeded repo-local
# store AND no interactive helper left first in the chain.
# The guard runs TILLANDSIAS_CRED_PROBE_CMD as ARGV (word-split, no shell),
# so the probe is a script file.
cat > "$W/probe.sh" <<'PROBE'
#!/bin/sh
store="$(git rev-parse --path-format=absolute --git-common-dir)/.gh-credentials"
helpers="$(git config --get-all credential.helper)"
[ -s "$store" ] || exit 1
case "
$helpers
" in *"
manager
"*) exit 1 ;; esac
exit 0
PROBE
chmod +x "$W/probe.sh"
probe="$W/probe.sh"
# HOME and system config point into the scratch dir for the guard AND the
# executed remedy: today's remedy is --local only, but a future line with
# --global must not be able to write the operator's real ~/.gitconfig
# (macbookair, 2026-09-29; the lenovinha fixture-identity leak of 1453-7rzd).
mkdir -p "$W/home"
guard() { ( cd "$repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_HOST_PUSH_DIR \
    HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 \
    TILLANDSIAS_CCC_NO_LANE=1 PATH="$W/bin:$PATH" TILLANDSIAS_CRED_PROBE_CMD="$probe" \
    bash "$GUARD" 2>"$W/err" ); }

out1="$(guard)"; rc1=$?
if ! grep -q 'blocked:interactive-credential-helper' <<<"$out1$(cat "$W/err")"; then
    skip "ARM3 could not reproduce interactive-credential-helper here (rc=$rc1 out=$out1); named skip, not a pass"
else
    # NEGATIVE CONTROL: re-run WITHOUT executing the remedy.
    guard >/dev/null; rc_nc=$?
    # Execute EXACTLY the remedy lines the guard printed (indented commands
    # after "REMEDY:", before the verdict), in the scratch repo.
    awk '/REMEDY:/{on=1; next} on && (/^blocked:/ || /^ *why:/){exit} on' "$W/err" | sed 's/^ *//; /^#/d' > "$W/remedy.sh"
    ( cd "$repo" && HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 PATH="$W/bin:$PATH" bash "$W/remedy.sh" >/dev/null 2>&1 ); rrc=$?
    out2="$(guard)"; rc2=$?
    if [ "$rc_nc" -ne 0 ] && [ "$rrc" -eq 0 ] && [ "$rc2" -eq 0 ] && ! grep -q 'blocked:' <<<"$out2"; then
        ok "ARM3 the printed remedy, executed verbatim, clears interactive-credential-helper (after: $out2); without it the refusal stands"
    else bad "ARM3 negative-control rc=$rc_nc remedy rc=$rrc after rc=$rc2 out='$out2' remedy='$(tr '\n' ';' < "$W/remedy.sh")'"; fi
fi

[ "$FAIL" -eq 0 ] && { echo "PASS: credential-channel-affordances (1497-ahmd)"; exit 0; }
echo "FAILED: credential-channel-affordances (1497-ahmd)"; exit 1
