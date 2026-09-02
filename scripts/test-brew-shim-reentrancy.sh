#!/usr/bin/env bash
# @trace spec:default-image
# test-brew-shim-reentrancy.sh — order 966-rq7f.
#
# THE DEFECT. `brew` is a Ruby program and `ruby` is one of the tools we shim,
# so `brew install ruby` runs brew, brew resolves an interpreter through PATH,
# PATH finds the shim, and the shim runs `brew install ruby`. Each level holds
# for its full install timeout, so nothing unwinds while the next level forks.
# MEASURED on pirria 2026-09-02 from an ordinary ./build.sh --check that merely
# probed for ruby: 3663 live processes (2872 bash + 716 concurrent
# `timeout 150 brew install --formula ruby`), 89.4% of the 4096 pid ceiling,
# empty Cellar — it forked 3663 times and installed nothing.
#
# WHY THIS FIXTURE IS SAFE. It never runs real brew, never touches the network,
# and never installs anything. A FAKE brew stands in, and it carries its own
# hard depth stop, so the mutation arm — which deliberately reproduces the
# UNGUARDED behaviour — recurses a bounded number of times instead of
# reproducing the bomb. A test for a fork bomb must not be one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/images/default/brew-shim-exec.sh"
PASS=0; FAIL=0
ok()  { echo "ok: $*";   PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

[ -x "$SHIM" ] || [ -f "$SHIM" ] || { echo "FAIL: shim not found at $SHIM"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# The fake brew's own stop. If the guard is absent the mutation arm must still
# terminate, so the ceiling lives HERE and not in the code under test.
HARD_STOP=25

mkdir -p "$W/prefix/bin" "$W/shims"
printf 'faketool fakeform\n' > "$W/allowlist.txt"

# A fake brew that does what real brew does to us: resolve a tool through PATH,
# which finds the shim again. Then fail, mirroring the attestation failure —
# the failing path is the one that runs longest and recursed furthest.
#   $1 = "unset-marker" makes it drop the guard's marker before recursing,
#        which reproduces the pre-fix behaviour without editing the shim.
write_fake_brew() {
    cat > "$W/prefix/bin/brew" <<FAKE
#!/usr/bin/env bash
echo "brew-invoked" >> "$W/installs.log"
depth=\$(wc -l < "$W/installs.log")
if [ "\$depth" -ge $HARD_STOP ]; then
    echo "fake-brew: hard stop at depth \$depth" >&2
    exit 1
fi
# Resolve a tool through PATH — this is the re-entry. The nested output goes to
# its own file: the shim gave brew's stdio to the caller, so mixing them would
# make arm 2 unable to tell the outer refusal from the inner one.
if [ -f "$W/drop-marker" ]; then
    env -u TILLANDSIAS_BREW_SHIM_INSTALLING faketool --version >> "$W/nested.txt" 2>&1
else
    faketool --version >> "$W/nested.txt" 2>&1
fi
exit 1
FAKE
    chmod +x "$W/prefix/bin/brew"
}

cat > "$W/shims/faketool" <<SHIMEOF
#!/usr/bin/env bash
exec bash "$SHIM" faketool fakeform "\$@"
SHIMEOF
chmod +x "$W/shims/faketool"

# Every arm pins TILLANDSIAS_BREW_AUTOINSTALL itself. Inheriting an ambient 0 —
# which is the pair's standing measurement protocol on 959-fpc5, so it IS set in
# real cycles — short-circuits above the install path and every arm then measures
# nothing while arm 1 still reads "exactly once". Caught by ./build.sh --check
# on the first run after wiring, which is the only reason it is not still there.
run_probe() {   # run_probe <"guarded"|"unset-marker">
    : > "$W/installs.log"; : > "$W/nested.txt"
    # The shim invokes brew as `brew install --formula X`, so the fake brew
    # cannot be steered by an argument — a file flag is the channel.
    if [ "$1" = "unset-marker" ]; then touch "$W/drop-marker"; else rm -f "$W/drop-marker"; fi
    write_fake_brew
    env -u TILLANDSIAS_BREW_SHIM_INSTALLING \
        TILLANDSIAS_BREW_AUTOINSTALL=1 \
        PATH="$W/shims:$PATH" \
        TILLANDSIAS_BREW_PREFIX="$W/prefix" \
        TILLANDSIAS_BREW_ALLOWLIST="$W/allowlist.txt" \
        TILLANDSIAS_PROJECT_CACHE="$W/cache" \
        TILLANDSIAS_BREW_INSTALL_TIMEOUT=10 \
        "$W/shims/faketool" --version > "$W/out.txt" 2>&1
    wc -l < "$W/installs.log" | tr -d ' '
}

# ── 1. GUARDED: brew is invoked exactly once, however deep the tool probe. ────
n="$(run_probe guarded)"
[ "$n" = "1" ] \
    && ok "guarded: the install path runs EXACTLY ONCE (brew invoked ${n}x)" \
    || bad "guarded: want exactly 1 brew invocation, got '${n}' — the guard did not bound re-entry"

# ── 2. The nested probe says WHY it refused, and names the formula in flight. ─
if grep -q "re-entrancy guard" "$W/nested.txt" && grep -q "already inside an install of 'fakeform'" "$W/nested.txt"; then
    ok "guarded: the nested probe refuses with the re-entrancy reason and the in-flight formula"
else
    bad "guarded: the refusal message is missing or does not name the in-flight formula"
fi

# ── 3. The nested probe DEGRADES, it does not abort: same hint an absent ──────
#      tool already gives, so a caller that can proceed without the tool still can.
grep -q "Install it in userspace with: brew install fakeform" "$W/nested.txt" \
    && ok "guarded: the nested probe degrades to the standard not-installed hint" \
    || bad "guarded: nested probe did not fall through to the not-installed hint"

# ── 4. MUTATION — WITHOUT the marker the SAME fixture recurses. ───────────────
#      This is what gives arm 1 teeth: if this arm did not recurse, arm 1 would
#      be passing because the fixture cannot re-enter, not because of the guard.
n="$(run_probe unset-marker)"
[ "${n:-0}" -gt 1 ] \
    && ok "MUTATION: with the marker dropped the same probe re-enters (${n} brew invocations, hard-stopped at $HARD_STOP)" \
    || bad "MUTATION: want >1 brew invocation with the marker dropped, got '${n}' — arm 1 proves nothing"

# ── 5. The guard must not fire for a tool that is ALREADY INSTALLED. ──────────
#      A nested probe for a present tool has to exec normally; otherwise the
#      guard would break every install that shells out to a real tool.
: > "$W/installs.log"
printf '#!/usr/bin/env bash\necho fake-installed-ok\n' > "$W/prefix/bin/faketool"
chmod +x "$W/prefix/bin/faketool"
out="$(env PATH="$W/shims:$PATH" \
    TILLANDSIAS_BREW_PREFIX="$W/prefix" \
    TILLANDSIAS_BREW_ALLOWLIST="$W/allowlist.txt" \
    TILLANDSIAS_PROJECT_CACHE="$W/cache" \
    TILLANDSIAS_BREW_AUTOINSTALL=1 \
    TILLANDSIAS_BREW_SHIM_INSTALLING=somethingelse \
    "$W/shims/faketool" --version 2>&1)"
[ "$out" = "fake-installed-ok" ] \
    && ok "an already-installed tool execs normally even inside an install (guard sits below that check)" \
    || bad "an already-installed tool did not exec normally under the guard (got '$out')"
rm -f "$W/prefix/bin/faketool"

# ── 6. AUTOINSTALL=0 still short-circuits ABOVE the guard, unchanged. ─────────
: > "$W/installs.log"
out="$(env -u TILLANDSIAS_BREW_SHIM_INSTALLING \
    PATH="$W/shims:$PATH" \
    TILLANDSIAS_BREW_PREFIX="$W/prefix" \
    TILLANDSIAS_BREW_ALLOWLIST="$W/allowlist.txt" \
    TILLANDSIAS_PROJECT_CACHE="$W/cache" \
    TILLANDSIAS_BREW_AUTOINSTALL=0 \
    "$W/shims/faketool" --version 2>&1)"
if echo "$out" | grep -q "is not installed" && [ ! -s "$W/installs.log" ]; then
    ok "AUTOINSTALL=0 still hints without invoking brew at all (ordering preserved)"
else
    bad "AUTOINSTALL=0 path changed — hint missing or brew was invoked"
fi

echo "test-brew-shim-reentrancy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ok:brew-shim-reentrancy:$PASS"
