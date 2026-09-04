#!/usr/bin/env bash
# Fixture for order 799-tb7q — the shared host-preferred / toolbox-fallback
# dispatch, and the deliberate exception to it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
fail=0
ok()  { echo "ok: $1"; }
# 956-llei: the FINAL line names the failed arms — the litmus consumes this
# fixture through `2>&1 | tail -1`, so an arm named only on an earlier
# stderr line is an arm nobody sees.
failed_arms=""
bad() { echo "FAIL: $1" >&2; fail=1; failed_arms="${failed_arms:+$failed_arms | }$1"; }

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
CONVERTED="scripts/cycle-metrics.sh scripts/select-work-batch.sh scripts/local-ci.sh
scripts/check-stranded-in-progress.sh scripts/check-mcp-expert-health.sh
scripts/generate-dashboard.sh scripts/manage-cache.sh scripts/host-capability-probe.sh"
for f in $CONVERTED; do
    if grep -nE '\| jq |^[[:space:]]*jq |\$\(jq ' "$ROOT/$f" | grep -vE ':[[:space:]]*#' | grep -q .; then
        bad "$f still calls jq bare"
    fi
done
ok "the converted callers route jq through the dispatch"

# ── 4b. THE EXCLUSIONS, guarded so a later sweep does not "finish the job". ──
# Three classes must never be converted, and each would look like an oversight:
#
#   CURL-PIPED INSTALLERS. install-macos.sh is fetched from a release URL and
#   piped straight into bash (release.yml, and the smoke runbook's macOS row).
#   There is no checkout and no sibling file to source. Converting it breaks the
#   macOS installer for every user.
#
#   BOOTSTRAP WRAPPERS. with-tillandsias-builder.sh CREATES the toolbox; it
#   cannot use the toolbox to decide how to make the toolbox. Same for
#   with-wsl2-builder.sh. (Their apparent "jq" sites are the dnf INSTALL LIST
#   `jq yq ripgrep openssl` — my own classifier regex matched a package name,
#   which is why this arm names them explicitly rather than trusting a grep.)
#
#   SHIPPED DIAGNOSTICS — arm 5 below.
for f in scripts/install-macos.sh scripts/with-tillandsias-builder.sh scripts/with-wsl2-builder.sh; do
    [ -f "$ROOT/$f" ] || continue
    grep -nE '^[[:space:]]*(\.|source)[[:space:]]+.*lib/tool-dispatch\.sh' "$ROOT/$f" \
        | grep -vE ':[[:space:]]*#' | grep -q . \
        && bad "$f SOURCES the shared lib — it is curl-piped or bootstraps the toolbox"
done
ok "curl-piped installer and toolbox bootstrap wrappers stay self-contained"

# ── 4c. NO `$JQ` INSIDE A HEREDOC — the trap that broke two fixtures. ───────
# A mechanical `| jq` -> `| "$JQ"` sweep is UNSAFE wherever the line sits inside
# a heredoc that generates another script: the variable belongs to the
# generating scope, not the generated one.
#
# MEASURED, twice, in one slice. test-opencode-vault-auth-content.sh went
# PASS -> FAIL because two substituted lines were inside a heredoc emitting a
# stub `opencode`; in the stub $JQ is unset, so the pipeline ran with an empty
# command and the rollback assertion failed with no hint as to why.
# test-bench-prompt-uniqueness.sh had the same shape in a generated `curl` stub —
# and there the heredoc is UNQUOTED, so $JQ would expand at generation time and
# bake a literal `toolbox run --container tillandsias-builder jq` into the stub,
# which breaks on exactly the jq-less host the sweep exists to serve. Wrong in
# both directions, for opposite reasons.
# The detector is deliberately simple. My first version buried the search
# string in nested awk/shell quoting, reported 0 hits on a tree where I had
# just REINTRODUCED the bug on purpose, and would have shipped as a green arm
# that could never go red. Pass the needle in as an awk variable instead.
_hd_hits=""
for f in $(git -C "$ROOT" ls-files 'scripts/*.sh'); do
    _h="$(awk -v needle='"$JQ"' -v fname="$f" '
        term == "" {
            if (match($0, /<<-?[ \t]*"?'"'"'?[A-Za-z_][A-Za-z0-9_]*"?'"'"'?/)) {
                t = substr($0, RSTART, RLENGTH)
                gsub(/[<\-\t "'"'"']/, "", t)
                term = t
            }
            next
        }
        {
            s = $0
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            if (s == term) { term = ""; next }
            if (index($0, needle) > 0) print fname ":" NR
        }
    ' "$ROOT/$f")"
    [ -n "$_h" ] && _hd_hits="$_hd_hits$_h "
done
if [ -n "$_hd_hits" ]; then
    bad "\$JQ appears inside a heredoc (the generated scope has no such variable): $_hd_hits"
else
    ok "no \$JQ inside any heredoc — generated scripts keep bare jq"
fi

# ── 4d. rg and openssl callers take the same dispatch. ─────────────────────
for f in scripts/check-cheatsheet-refs.sh scripts/test-forge-config-trust-cross-platform-parity.sh; do
    grep -q 'resolve_tool rg' "$ROOT/$f" || bad "$f does not resolve rg through the dispatch"
    grep -nE '(^|[^$])\brg ' "$ROOT/$f" | grep -vE ':[[:space:]]*#' | grep -vE 'resolve_tool|RG=|ripgrep' | grep -q . \
        && bad "$f still calls rg bare"
done
ok "the rg callers take the dispatch"

for f in scripts/diagnose-proxy.sh scripts/run-forge-project.sh scripts/orchestrate-enclave.sh; do
    grep -q 'resolve_tool openssl' "$ROOT/$f" || bad "$f does not resolve openssl through the dispatch"
    grep -nE '^[[:space:]]*openssl |\| openssl |\$\(openssl ' "$ROOT/$f" | grep -vE ':[[:space:]]*#' | grep -q . \
        && bad "$f still calls openssl bare"
done
# ── 4e. THE openssl WRITE-PATH CAVEAT, recorded where a converter will hit it. ─
# jq is a pure filter: stdin in, stdout out, namespace-agnostic. openssl WRITES
# FILES, so a toolbox fallback only works where the container shares the write
# path. This arm fails if a caller starts writing somewhere unshared, because
# that silently lands the cert where the caller cannot find it.
#
# TWO SHARED ROOTS ARE ALLOWED, EACH MEASURED RATHER THAN ASSUMED:
#   /tmp                  — verified bidirectionally on lenovinha 2026-08-26.
#   $TILLANDSIAS_CA_DIR   — the single-sourced CA path (998-3z6g), which is
#                           HOME-relative since the bundle left /tmp. Verified
#                           bidirectionally on yoga 2026-09-04: a file written
#                           by the host under $HOME/.local/state/tillandsias
#                           was read inside `toolbox run`, and an append made
#                           inside the toolbox was read back on the host.
#
# 998-3z6g MOVED THE CA OUT OF /tmp AND THIS ARM WENT RED, which is the arm
# doing its job — a CERTS_DIR moved and the pin caught it. What it could not
# know is whether the NEW root is shared, and that question is answered by
# measurement above, not by widening the pattern because the tests are red.
# Adding a third root means running the same probe for it; an unmeasured root
# belongs in the reject arm no matter how plausible it looks.
for f in scripts/diagnose-proxy.sh scripts/run-forge-project.sh scripts/orchestrate-enclave.sh; do
    _cd="$(grep -oE 'CERTS_DIR="?[^"]*"?' "$ROOT/$f" | head -1)"
    case "$_cd" in
        *mktemp*|*/tmp/*|*TILLANDSIAS_CA_DIR*) ;;
        *) bad "$f writes certs to a path that may not be shared with the toolbox: $_cd" ;;
    esac
done
ok "every converted openssl caller writes under a MEASURED shared root (/tmp or the CA dir)"
ok "every converted openssl caller writes under /tmp (shared with the toolbox)"

# ── 4f. DEPTH: a caller ONE LEVEL DOWN must still resolve the lib (914-ahsy). ─
# THE FAILURE MODE HERE IS "LOOKING DONE", which is why it gets a constructed
# test rather than an assertion over the current tree. The old header resolved
# lib/tool-dispatch.sh at a FIXED depth relative to the caller. From scripts/ it
# is right; from scripts/refusal-calibration/ it points at a lib that does not
# exist, the `|| true` swallows the miss, and the tool variable falls back to the
# bare name. A conversion there passes review, passes this suite, and changes
# nothing — the exact class of artifact-standing-in-for-work this fleet has spent
# the week killing, and 4 of the 17 scripts on 914-ahsy sit at that depth.
#
# NOTE THIS ARM WOULD PASS VACUOUSLY IF IT ONLY SCANNED THE TREE: every converted
# caller today lives directly in scripts/, so there is nothing at depth to check.
# It builds one instead, and carries a mutation control proving the OLD header
# fails the same construction.
_depth_root="$W/depthrepo"
mkdir -p "$_depth_root/scripts/lib" "$_depth_root/scripts/sub"
cp "$ROOT/scripts/lib/tool-dispatch.sh" "$_depth_root/scripts/lib/"

# The header as callers now carry it: walk up until lib/tool-dispatch.sh is found.
cat >"$_depth_root/scripts/sub/caller.sh" <<'DEPTHEOF'
#!/usr/bin/env bash
set -euo pipefail
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
command -v resolve_tool >/dev/null 2>&1 && echo RESOLVER-PRESENT || echo RESOLVER-ABSENT
DEPTHEOF
chmod +x "$_depth_root/scripts/sub/caller.sh"
if [ "$(bash "$_depth_root/scripts/sub/caller.sh" 2>/dev/null)" = "RESOLVER-PRESENT" ]; then
    ok "a caller one level down resolves the lib (walk-up header)"
else
    bad "a subdirectory caller did NOT resolve the lib — conversions at depth are silent no-ops"
fi

# MUTATION CONTROL: the OLD fixed-depth header must FAIL this same construction.
# Without it, the arm above could pass for reasons unrelated to the walk-up.
cat >"$_depth_root/scripts/sub/old-caller.sh" <<'OLDEOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh" 2>/dev/null || true
command -v resolve_tool >/dev/null 2>&1 && echo RESOLVER-PRESENT || echo RESOLVER-ABSENT
OLDEOF
if [ "$(bash "$_depth_root/scripts/sub/old-caller.sh" 2>/dev/null)" = "RESOLVER-ABSENT" ]; then
    ok "MUTATION: the old fixed-depth header silently fails at depth — arm 4f has teeth"
else
    bad "the old header resolved at depth; arm 4f is not testing what it claims"
fi

# And no caller in the tree may carry the fixed-depth form again.
# EXCLUDE THIS FILE. It legitimately contains the old form inside the mutation
# control above, and the first version of this check matched its own control —
# a guard tripped by the evidence that the guard works. Ninth instance of that
# shape in this suite's history; the rule stays "assert the behaviour, not the
# string", and where a string check is genuinely wanted it must exclude the
# place the string is a specimen rather than a defect.
if grep -rn 'dirname "${BASH_SOURCE\[0\]}")/lib/tool-dispatch\.sh' "$ROOT/scripts" 2>/dev/null \
   | grep -v 'test-tool-dispatch-lib\.sh' \
   | grep -vE ':[[:space:]]*#' | grep -q .; then
    bad "a caller reintroduced the fixed-depth source path"
else
    ok "no caller carries the fixed-depth source path"
fi

# ── 5. THE DELIBERATE EXCEPTION, guarded so it does not read as an oversight. ─
# The shipped diagnostics keep INLINE copies on purpose: they run on end-user
# machines where a sibling lib may not exist, and a shipped diagnostic that
# fails to SOURCE a helper is worse than one that duplicates six lines. This arm
# fails if someone "tidies" them into the lib.
for f in scripts/tray-diagnose.sh scripts/diagnose-macos-provision.sh; do
    # ASSERT THE DIRECTIVE, NOT THE STRING. The first version grepped for
    # 'lib/tool-dispatch.sh' anywhere in the file and fired on the COMMENT that
    # explains why this file deliberately does not source it — a guard about a
    # decision, tripped by the sentence documenting that decision. Same class as
    # a word-absence test firing on "Do NOT …": a bare mention is not a
    # behaviour. Match an actual source directive (`.` or `source`), skipping
    # comment lines.
    grep -nE '^[[:space:]]*(\.|source)[[:space:]]+.*lib/tool-dispatch\.sh' "$ROOT/$f" \
        | grep -vE ':[[:space:]]*#' | grep -q . \
        && bad "$f SOURCES the shared lib — it SHIPS and must stay self-contained"
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
echo "fail:tool-dispatch-lib: ${failed_arms}"
exit 1
