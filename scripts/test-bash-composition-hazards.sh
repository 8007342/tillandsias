#!/usr/bin/env bash
# @trace order:1252-r72q
#
# test-bash-composition-hazards.sh — arms for the bash composition-hazard
# advisory (1252-r72q).
#
# The Rust unit tests in crates/tillandsias-litmus-rust/src/bash_hazards.rs
# pin the grammar-level behaviour. THIS file pins the two claims that need real
# repository history and a real toolbox, which a unit test cannot supply:
#   ARM 1  the lint names the pre-fix check-seam-writers-canonical.sh pipeline
#          AT ITS PRE-FIX COMMIT, and is SILENT at the fix commit. A before
#          without an after is not evidence.
#   ARM 2  NEGATIVE CONTROL: a file mentioning pipefail only in a COMMENT,
#          beside a grep -q pipeline, is not reported.
#   ARM 3  the advisory NEVER exits non-zero -- it is advisory tier, and a
#          non-zero exit would make it a gate the first time a caller used
#          `set -e`.
#   ARM 4  the reported counts are PER-PIPELINE and exceed the per-FILE counts,
#          which is the whole point of using a parser. A run whose pipelines
#          equal its files has silently degraded to a file-granularity scan.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
BIN="$ROOT/target/release/tillandsias-litmus-rust"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

if [ ! -x "$BIN" ]; then
    echo "skip:bash-composition-hazards:no-binary (cargo build --release -p tillandsias-litmus-rust)"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- ARM 1: the pre-fix inversion, named, and silent after the fix -----------
# 1251-54p3's guard caught `if ! sed ... | grep -q` in this file and the fix is
# 2b777de3e. NOTE FOR THE READER: the packet describes this as "the `| grep -c`
# pipeline that inverted under pipefail". Both halves are wrong and the row has
# been corrected -- it is `grep -q`, and 2b777de3e's own message measured that
# it NEVER INVERTED, because the script sets only `set -u`. The hazard is
# latent. That is why it is caught here as the negated-pipeline shape and not
# as the pipefail shape.
PRE=c7e860ff1
POST=2b777de3e
if git cat-file -e "$PRE:scripts/check-seam-writers-canonical.sh" 2>/dev/null; then
    git show "$PRE:scripts/check-seam-writers-canonical.sh" > "$TMP/pre.sh"
    git show "$POST:scripts/check-seam-writers-canonical.sh" > "$TMP/post.sh"
    pre_out="$("$BIN" bash-hazards --show "$TMP/pre.sh" 2>&1)"
    post_out="$("$BIN" bash-hazards --show "$TMP/post.sh" 2>&1)"
    case "$pre_out" in
        *negated-pipeline-if*grep\ -q*) ok "ARM 1 pre-fix: the inverting pipeline is named" ;;
        *) bad "ARM 1 pre-fix: expected the grep -q pipeline named, got: $pre_out" ;;
    esac
    # Assert on the COUNT, not on the shape name appearing: the summary line
    # prints every shape unconditionally, including at zero, so a bare
    # `*negated-pipeline-if*` match is true even for a clean file. That
    # mis-assertion failed this arm on its first run against a lint that was
    # behaving correctly -- the test was wrong, not the lint.
    case "$post_out" in
        *negated-pipeline-if:pipelines=0*) ok "ARM 1 post-fix: silent once the pipeline was converted" ;;
        *) bad "ARM 1 post-fix: must be SILENT after 2b777de3e, got: $post_out" ;;
    esac
else
    echo "skip: ARM 1 — commit $PRE not present in this clone (shallow?)"
fi

# --- ARM 2: NEGATIVE CONTROL, comment-only pipefail --------------------------
# Comment-blind source scans are a repeat defect here (881-29me, 885-92iu, and
# the comment arm of 1251-54p3). A parser gets this free: a comment is its own
# node and is never a `command`.
cat > "$TMP/neg.sh" <<'EOF'
#!/usr/bin/env bash
# This comment says pipefail and that must not count.
set -u
cat /etc/hosts | grep -q localhost
EOF
neg_out="$("$BIN" bash-hazards "$TMP/neg.sh" 2>&1)"
case "$neg_out" in
    *pipefail-grep-q:pipelines=0*) ok "ARM 2 negative control: comment-only pipefail is not reported" ;;
    *) bad "ARM 2 negative control: expected 0, got: $neg_out" ;;
esac
# MUTANT, because a zero that cannot become non-zero is not evidence: the same
# file with pipefail actually SET must report exactly one.
cat > "$TMP/pos.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat /etc/hosts | grep -q localhost
EOF
pos_out="$("$BIN" bash-hazards "$TMP/pos.sh" 2>&1)"
case "$pos_out" in
    *pipefail-grep-q:pipelines=1*) ok "ARM 2 mutant: a real pipefail IS reported" ;;
    *) bad "ARM 2 mutant: expected 1, got: $pos_out" ;;
esac

# --- ARM 3: advisory tier never fails the caller ----------------------------
bash "$ROOT/scripts/check-bash-composition-hazards.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "ARM 3 advisory exits 0 over the live tree" \
                || bad "ARM 3 advisory exited $rc — advisory tier must not gate"

# --- ARM 4: per-pipeline granularity, not per-file --------------------------
live="$(bash "$ROOT/scripts/check-bash-composition-hazards.sh" 2>/dev/null)"
p="$(printf '%s\n' "$live" | sed -n 's/.*pipefail-grep-q:pipelines=\([0-9]*\):.*/\1/p')"
f="$(printf '%s\n' "$live" | sed -n 's/.*pipefail-grep-q:.*:files=\([0-9]*\).*/\1/p')"
if [ -n "$p" ] && [ -n "$f" ] && [ "$p" -gt "$f" ]; then
    ok "ARM 4 per-pipeline ($p) exceeds per-file ($f) — the parser is doing work grep cannot"
else
    bad "ARM 4 expected pipelines > files, got pipelines='$p' files='$f'"
fi

echo "bash-composition-hazards: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:bash-composition-hazards:$pass"
