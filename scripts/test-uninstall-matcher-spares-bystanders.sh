#!/usr/bin/env bash
# test-uninstall-matcher-spares-bystanders.sh — order 1231-cbie, SECOND HALF.
#
# WHAT IT GUARDS, and why the sibling fixture cannot. Order 1231-cbie has two
# halves. The platform guard (test-uninstall-tray-stop-is-macos-only.sh) proves
# the tray stop cannot fire OFF Darwin. This proves the matcher cannot kill a
# BYSTANDER ON Darwin — the half that needed a Mac to decide, because the target
# is a .app bundle and `pgrep -x` matches an executable name that may not equal
# the bundle name. MEASURED 2026-09-17: CFBundleExecutable is `tillandsias-tray`
# and CFBundleName is `Tillandsias`, so they DIFFER and a bundle-name matcher
# would have matched nothing at all.
#
# USE, NOT MENTION. Reading uninstall.sh for the string `-x` would pass on a file
# that merely DISCUSSES the matcher and would go green if someone reorganised the
# stop into a helper. So this EXTRACTS the real stop block and EXECUTES it with
# real processes running, exactly as the sweeps fixture does for the app dirs.
# Running the whole uninstaller would touch the real machine.
#
# WHY IT MAY SKIP, AND WHY A SKIP IS NOT A PASS (1141-vf9w). The arms below run
# the genuine `pkill` against the genuine executable name. If a REAL tray is
# running, arm 2 would kill the operator's tray. That is not a risk worth taking
# for a test, so the fixture REFUSES to run and exits 2 — an honest "I could not
# look", never a content verdict. The gate step binds STEP_SKIP_EXIT=2 so a skip
# is reported as a skip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNINSTALL="$ROOT/scripts/uninstall.sh"
pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

[ "$(uname -s)" = "Darwin" ] || {
  echo "skip:not-darwin — this fixture exercises pgrep/pkill -x against a real"
  echo "  executable name; the matcher's behaviour is a Darwin question."
  exit 2
}

# The refusal that protects a live tray. Deliberately BEFORE any decoy starts.
if pgrep -x tillandsias-tray >/dev/null 2>&1; then
  echo "skip:live-tray-present — a real tray is running and arm 2 would kill it."
  echo "  This is a SKIP, not a pass: the matcher was not exercised."
  exit 2
fi

# Take exactly ONE complete block: the sed range restarts on later matches, and
# a fixed `head -N` truncates the closing `fi`. That is not hypothetical — the
# first draft used `head -6`, eval hit a syntax error, `|| true` swallowed it,
# and ARM 1 PASSED while nothing had executed. Arm 2 caught it. Stop at the
# first column-0 `fi` instead, and assert the block parses before trusting it.
BLOCK="$(sed -n '/if \[\[ "\$IS_MACOS" == true \]\]; then/,/^fi$/p' "$UNINSTALL" | awk '1; /^fi$/{exit}')"
if ! bash -n <(printf '%s\n' "$BLOCK") 2>/dev/null; then
  echo "FAIL:tray-stop-block-does-not-parse" >&2
  echo "  The extracted block is not valid shell, so executing it would prove" >&2
  echo "  nothing and every arm below would pass vacuously." >&2
  exit 1
fi
case "$BLOCK" in
  *tillandsias-tray*) : ;;
  *) echo "FAIL:tray-stop-block-not-found" >&2
     echo "  The fixture locates the stop by its IS_MACOS guard. If that was" >&2
     echo "  renamed, update this fixture — do not delete the assertion." >&2
     exit 1 ;;
esac

TMP="$(mktemp -d)"
cleanup() {
  [ -n "${BYSTANDER:-}" ] && kill "$BYSTANDER" 2>/dev/null
  [ -n "${DECOY:-}" ] && kill "$DECOY" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# ARM 1 — A BYSTANDER MERELY MENTIONING THE LITERAL MUST SURVIVE.
# This is the defect in one process: under `-f` the selector matched the whole
# COMMAND LINE, so an editor, a grep or a tail holding a path with the tray's
# name in it was SIGTERMed then SIGKILLed.
touch "$TMP/tillandsias-tray.log"
tail -f "$TMP/tillandsias-tray.log" >/dev/null 2>&1 &
BYSTANDER=$!
sleep 1
IS_MACOS=true
eval "$BLOCK" >/dev/null 2>&1 || true
sleep 1
if kill -0 "$BYSTANDER" 2>/dev/null; then
  ok "ARM 1: a process whose argv merely MENTIONS the tray literal SURVIVED the stop"
else
  bad "ARM 1: the stop killed a bystander that only mentioned the literal — the matcher is still command-line based"
fi
kill "$BYSTANDER" 2>/dev/null; BYSTANDER=""

# ARM 2 — NEGATIVE CONTROL: A GENUINE TRAY MUST STILL BE STOPPED.
# Arm 1 alone is satisfied by a stop that does nothing at all. A symlink to
# /bin/sleep gives a process whose EXECUTABLE NAME is the tray's; a copy does
# not, because a copied system binary loses its signature and is SIGKILLed on
# Apple Silicon (measured: rc=137).
ln -s /bin/sleep "$TMP/tillandsias-tray"
"$TMP/tillandsias-tray" 30 >/dev/null 2>&1 &
DECOY=$!
sleep 1
if ! kill -0 "$DECOY" 2>/dev/null; then
  bad "ARM 2 SETUP: the decoy never ran, so the control proves nothing"
else
  eval "$BLOCK" >/dev/null 2>&1 || true
  sleep 1
  if kill -0 "$DECOY" 2>/dev/null; then
    bad "ARM 2: a process genuinely NAMED tillandsias-tray survived — the stop no longer stops the tray, which trades the defect for its opposite"
  else
    ok "ARM 2 (negative control): a genuine tray process WAS stopped"
  fi
fi
DECOY=""

# ARM 3 — THE INSTALL PATH, because criterion 2 says "the uninstall OR INSTALL
# path" and a fixture that only exercises the uninstaller proves half of it.
# install-macos.sh stops a running tray before replacing the bundle, using the
# same selector. It defines `say`, so stub it rather than extracting around it.
INSTALL="$ROOT/scripts/install-macos.sh"
IBLOCK="$(sed -n '/^if pgrep -[fx] tillandsias-tray >\/dev\/null 2>&1; then$/,/^fi$/p' "$INSTALL" | awk '1; /^fi$/{exit}')"
if [ -z "$IBLOCK" ]; then
  bad "ARM 3 SETUP: the installer's stop block was not found — locate it by its pgrep guard, do not delete this arm"
elif ! bash -n <(printf '%s\n' "$IBLOCK") 2>/dev/null; then
  bad "ARM 3 SETUP: the installer's block does not parse, so executing it would prove nothing"
else
  touch "$TMP/tillandsias-tray.log"
  tail -f "$TMP/tillandsias-tray.log" >/dev/null 2>&1 &
  BYSTANDER=$!
  sleep 1
  say() { :; }
  eval "$IBLOCK" >/dev/null 2>&1 || true
  sleep 1
  if kill -0 "$BYSTANDER" 2>/dev/null; then
    ok "ARM 3: the INSTALLER's stop also spared a bystander that merely mentions the literal"
  else
    bad "ARM 3: the installer's stop killed a bystander — install-macos.sh still matches on the command line"
  fi
  kill "$BYSTANDER" 2>/dev/null; BYSTANDER=""
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
  echo "ok:uninstall-matcher-spares-bystanders"
  echo "PASS: uninstall-matcher-spares-bystanders $pass/$total (1231-cbie)"
  exit 0
fi
echo "FAIL: uninstall-matcher-spares-bystanders $pass/$total (1231-cbie)"
exit 1
