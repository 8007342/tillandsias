#!/usr/bin/env bash
# @trace order:1310-rec6, spec:git-mirror-service
#
# test-mirror-refuses-when-broken.sh — a mirror whose relay-state is BROKEN
# refuses every push up front, with the remedy for the failing layer and then
# for who is pushing; reads stay open; one ok tick restores service with no
# restart (1310-rec6 steps 3+4, coordinator ruling 2026-09-30).
#
# HERMETIC: a scratch bare mirror running images/git/pre-receive-hook.sh with a
# stub relay that records whether it ran. The relay-state ref is written the
# way publish-relay-state writes it. HOME and system git config are pinned.
#
# Arms:
#   1 CREDENTIAL/FORGE  refused before the relay; remedy is the operator
#                       re-seed, and does NOT say rebuild
#   2 CREDENTIAL/HOST   (principal til:host-push:<host>) the same re-seed remedy
#   3 TRANSPORT         a forge is told upgrade + rebuild; a host is told to
#                       restore connectivity
#   4 READS OPEN        clone and ls-remote work while broken
#   5 RESTORE           the broken ref replaced by an ok one: the next push is
#                       admitted and relayed, nothing restarted
#   6 NEGATIVE CONTROL  no relay-state ref at all: pushes admitted as before
#   7 FORGE AUTONOMOUS  broken + a prompted Codex/OpenCode lane: hard stop
#                       before any work (lib-common forge_mirror_relay_gate)
#   8 FORGE INTERACTIVE broken + no unattended prompt: a loud banner, and the
#                       forge starts (it can still read, debug and fix)
#   9 FORGE REMEDY/OK   transport tells a forge upgrade + rebuild; an ok state
#                       gates nothing
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/images/git/pre-receive-hook.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/refuse-broken.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
git config --global user.email f@f; git config --global user.name f; git config --global init.defaultBranch main
unset TILLANDSIAS_PUSH_PRINCIPAL

M="$W/mirror.git"
git init -q --bare "$M"; mkdir -p "$M/hooks" "$W/nohooks"
git -C "$M" config core.hooksPath "$W/nohooks"
git init -q "$W/work"; git -C "$W/work" commit -q --allow-empty -m base
git -C "$W/work" remote add origin "$M"; git -C "$W/work" push -q origin main
cp "$HOOK" "$M/hooks/pre-receive"; chmod +x "$M/hooks/pre-receive"
printf '#!/bin/sh\ncat >/dev/null\n: > "%s/relayed"\nexit 0\n' "$W" > "$M/hooks/tillandsias-relay-refs"
chmod +x "$M/hooks/tillandsias-relay-refs"
git -C "$M" config core.hooksPath "$M/hooks"
EMPTY="$(git -C "$M" hash-object -w --stdin </dev/null)"

set_state() {   # <state/class/n> : exactly one relay-state ref, like the publisher
    git -C "$M" for-each-ref --format='%(refname)' refs/tillandsias/relay-state | while read -r r; do git -C "$M" update-ref -d "$r"; done
    [ -n "$1" ] && git -C "$M" update-ref "refs/tillandsias/relay-state/$1/$(date +%s)" "$EMPTY"
}
push() {   # [principal]; sets out/rc and whether the relay ran
    rm -f "$W/relayed"
    git -C "$W/work" commit -q --allow-empty -m "c$RANDOM"
    out="$(TILLANDSIAS_PUSH_PRINCIPAL="${1:-}" git -C "$W/work" push origin main 2>&1)"; rc=$?
    [ -e "$W/relayed" ] && relayed=yes || relayed=no
    git -C "$W/work" reset -q --hard "origin/main" 2>/dev/null || true
}

# ── ARM 1 ────────────────────────────────────────────────────────────────
set_state broken/credential/1; push ""
if [ "$rc" -ne 0 ] && [ "$relayed" = no ] && grep -q 'blocked:mirror-broken:credential' <<<"$out" \
   && grep -q 'tillandsias --github-login' <<<"$out" && ! grep -q 'upgrade and a forge rebuild' <<<"$out"; then
    ok "ARM1 credential/forge: refused before the relay; remedy is the operator re-seed, not a rebuild"
else bad "ARM1 rc=$rc relayed=$relayed out='$(tr '\n' '|' <<<"$out")'"; fi

# ── ARM 2 ────────────────────────────────────────────────────────────────
push "til:host-push:lenovinha"
if [ "$rc" -ne 0 ] && [ "$relayed" = no ] && grep -q 'tillandsias --github-login' <<<"$out"; then
    ok "ARM2 credential/host: the same re-seed remedy"
else bad "ARM2 rc=$rc relayed=$relayed"; fi

# ── ARM 3 ────────────────────────────────────────────────────────────────
set_state broken/transport/1
push ""; f_out="$out"; f_rc=$rc
push "til:host-push:lenovinha"; h_out="$out"; h_rc=$rc
if [ "$f_rc" -ne 0 ] && grep -q 'tillandsias upgrade and a forge rebuild' <<<"$f_out" \
   && [ "$h_rc" -ne 0 ] && grep -q "restore this host's connectivity" <<<"$h_out" && ! grep -q 'upgrade and a forge rebuild' <<<"$h_out"; then
    ok "ARM3 transport: a forge is told upgrade + rebuild, a host is told to restore connectivity"
else bad "ARM3 forge rc=$f_rc host rc=$h_rc"; fi

# ── ARM 4 ────────────────────────────────────────────────────────────────
if git clone -q "$M" "$W/clone" 2>/dev/null && git ls-remote "$M" 'refs/tillandsias/relay-state/*' | grep -q 'broken/transport'; then
    ok "ARM4 reads stay open while broken: clone works and the verdict ref is readable"
else bad "ARM4 a read failed while broken"; fi

# ── ARM 5 ────────────────────────────────────────────────────────────────
set_state ok/none/0; push ""
if [ "$rc" -eq 0 ] && [ "$relayed" = yes ]; then
    ok "ARM5 restore: after one ok tick the next push is admitted and relayed, no restart"
else bad "ARM5 rc=$rc relayed=$relayed out='$(tr '\n' '|' <<<"$out")'"; fi

# ── ARM 6 ────────────────────────────────────────────────────────────────
set_state ""; push ""
[ "$rc" -eq 0 ] && [ "$relayed" = yes ] && ok "ARM6 negative control: no relay-state ref, pushes admitted as before" \
    || bad "ARM6 rc=$rc relayed=$relayed"

# ── ARMS 7-9: the forge-start half, extracted from lib-common.sh ─────────
eval "$(awk '/^forge_mirror_relay_gate\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$ROOT/images/default/lib-common.sh")"
declare -F forge_mirror_relay_gate >/dev/null || { bad "forge_mirror_relay_gate not found in lib-common.sh"; }
set_state broken/credential/1
o7="$(TILLANDSIAS_CODEX_PROMPT="run the loop" forge_mirror_relay_gate "$M" 2>&1)"; r7=$?
if [ "$r7" -ne 0 ] && grep -q 'blocked:mirror-broken:credential' <<<"$o7" && grep -q 'tillandsias --github-login' <<<"$o7"; then
    ok "ARM7 an autonomous lane on a broken mirror stops before any work, with the credential remedy"
else bad "ARM7 r=$r7 out='$(tr '\n' '|' <<<"$o7")'"; fi
o8="$(env -u TILLANDSIAS_CODEX_PROMPT -u TILLANDSIAS_OPENCODE_PROMPT bash -c "$(declare -f forge_mirror_relay_gate); forge_mirror_relay_gate '$M'" 2>&1)"; r8=$?
if [ "$r8" -eq 0 ] && grep -q 'WARNING: the git mirror cannot relay' <<<"$o8" && ! grep -q 'blocked:' <<<"$o8"; then
    ok "ARM8 an interactive forge on a broken mirror starts, with a loud banner"
else bad "ARM8 r=$r8 out='$(tr '\n' '|' <<<"$o8")'"; fi
set_state broken/transport/1
o9="$(TILLANDSIAS_OPENCODE_PROMPT=x forge_mirror_relay_gate "$M" 2>&1)"; r9=$?
set_state ok/none/0
o9ok="$(TILLANDSIAS_OPENCODE_PROMPT=x forge_mirror_relay_gate "$M" 2>&1)"; r9ok=$?
if [ "$r9" -ne 0 ] && grep -q 'tillandsias upgrade and a forge rebuild' <<<"$o9" && [ "$r9ok" -eq 0 ] && [ -z "$o9ok" ]; then
    ok "ARM9 transport tells a forge upgrade + rebuild; an ok state gates nothing and prints nothing"
else bad "ARM9 transport r=$r9, ok r=$r9ok out='$o9ok'"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: mirror-refuses-when-broken (1310-rec6)"; exit 0; }
echo "FAILED: mirror-refuses-when-broken (1310-rec6)"; exit 1
