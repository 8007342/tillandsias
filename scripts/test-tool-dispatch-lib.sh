#!/usr/bin/env bash
# Fixture for order 799-tb7q — the shared host-preferred / toolbox-fallback
# dispatch, and the deliberate exception to it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

. "$ROOT/scripts/lib/tool-dispatch.sh" || { echo "FAIL: cannot source the lib" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/tool-dispatch.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# ── 1. Host tool present -> the bare tool name, no container round trip. ────
if command -v jq >/dev/null 2>&1; then
    [ "$(resolve_tool jq)" = "jq" ] \
        && ok "host tool present -> bare name (no toolbox round trip)" \
        || bad "resolved '$(resolve_tool jq)' when a host jq exists"
else
    ok "SKIP(no host jq): cannot exercise the host arm here"
fi

# ── 2. Nothing anywhere -> non-zero, and BOTH places named. ────────────────
# The message must name the host AND the toolbox: "command not found" from
# inside a container is the confusing failure this packet exists to prevent.
if resolve_tool definitely-not-a-real-tool-xyz >/dev/null 2>&1; then
    bad "resolved a tool that exists nowhere"
else
    ok "a tool that exists nowhere resolves to nothing, non-zero"
fi
err="$(require_tool definitely-not-a-real-tool-xyz 2>&1 >/dev/null)"
case "$err" in
    *host*toolbox*|*toolbox*host*) ok "the diagnosis names BOTH host and toolbox" ;;
    *) bad "diagnosis must name both places checked: $err" ;;
esac
case "$err" in
    *"TOOLING gap"*) ok "names it a tooling gap, not a fault in the inspected thing" ;;
    *) bad "must distinguish a tooling gap from a real fault" ;;
esac

# ── 3. Host tool ABSENT -> the toolbox arm, with the precondition ASSERTED. ─
# Masking jq is fiddly and I got it wrong twice before this arm was right:
# `env -i` strips the environment podman needs, so the toolbox arm fails for
# reasons that have nothing to do with the code, and dropping /usr/bin from PATH
# removes every other utility too. The only construction that isolates the
# variable is a curated mirror of /usr/bin with jq omitted. Assert it, do not
# assume it — a fixture whose environment does not hold its own precondition
# cannot fail for the right reason.
MASK="$W/nojq"; mkdir -p "$MASK"
if [ -d /usr/bin ]; then
    for t in $(ls /usr/bin 2>/dev/null | grep -vx jq); do
        ln -sf "/usr/bin/$t" "$MASK/$t" 2>/dev/null || true
    done
fi
if PATH="$MASK" command -v jq >/dev/null 2>&1; then
    bad "PRECONDITION: jq still reachable on the masked PATH — arm 3 would test nothing"
elif ! PATH="$MASK" command -v toolbox >/dev/null 2>&1; then
    ok "SKIP(no toolbox on this host): the fallback arm is not applicable"
else
    got="$(PATH="$MASK" bash -c ". '$ROOT/scripts/lib/tool-dispatch.sh'; resolve_tool jq" 2>/dev/null)"
    case "$got" in
        "toolbox run --container tillandsias-builder jq")
            ok "host tool absent -> the documented toolbox invocation" ;;
        "") bad "host absent and toolbox present, but nothing resolved: '$got'" ;;
        *)  bad "unexpected fallback resolution: '$got'" ;;
    esac
fi

# ── 4. The converted callers carry no bare jq. ─────────────────────────────
for f in scripts/cycle-metrics.sh scripts/select-work-batch.sh scripts/local-ci.sh; do
    if grep -nE '\| jq |^[[:space:]]*jq |\$\(jq ' "$ROOT/$f" | grep -vE ':[[:space:]]*#' | grep -q .; then
        bad "$f still calls jq bare"
    fi
done
ok "the converted callers route jq through the dispatch"

# ── 5. THE DELIBERATE EXCEPTION, guarded so it does not read as an oversight. ─
# The shipped diagnostics keep INLINE copies on purpose: they run on end-user
# machines where a sibling lib may not exist, and a shipped diagnostic that
# fails to SOURCE a helper is worse than one that duplicates six lines. This arm
# fails if someone "tidies" them into the lib.
for f in scripts/tray-diagnose.sh scripts/diagnose-macos-provision.sh; do
    grep -q 'lib/tool-dispatch.sh' "$ROOT/$f" \
        && bad "$f sources the shared lib — it SHIPS and must stay self-contained"
    grep -q 'toolbox run --container tillandsias-builder jq' "$ROOT/$f" \
        || bad "$f lost its inline dispatch"
done
ok "shipped diagnostics keep self-contained inline dispatch (deliberate, guarded)"

# ── 6. A caller with the lib missing must not be worse off than before. ────
# Every converted script falls back to a literal `jq`, preserving the exact
# prior behaviour, so a lost or unreadable lib degrades to the status quo ante
# rather than to a crash.
for f in scripts/cycle-metrics.sh scripts/select-work-batch.sh scripts/local-ci.sh; do
    grep -q 'JQ="jq"' "$ROOT/$f" \
        || bad "$f has no literal-jq fallback if the lib cannot be sourced"
done
ok "a missing lib degrades callers to the previous behaviour, not to a crash"

if [ "$fail" -eq 0 ]; then
    echo "ok:tool-dispatch-lib:all"
    exit 0
fi
echo "fail:tool-dispatch-lib"
exit 1
