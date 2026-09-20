#!/usr/bin/env bash
# @trace order:1273-4mak, spec:binary-signing
#
# THE DEFECT. The curl-install smoke — the acceptance gate a release is promoted
# to stable on — verified INTEGRITY and never AUTHENTICITY. Measured by the row's
# author on 2026-09-19: `grep -ci 'cosign|verify.sh' SKILL.md` returned 0. Every
# release publishes a .cosign.bundle beside every asset, and nothing read one on
# any lane, for any release, ever.
#
# WHY INTEGRITY IS NOT ENOUGH, which is the whole point and is what ARM 3 pins:
# install.sh checks the asset's SHA256 against a SHA256SUMS fetched from the same
# place as the asset. A substituted asset served with a REGENERATED manifest is
# self-consistent and passes. Only the signature answers "who produced this".
#
# THIS FIXTURE RUNS THE RUNBOOK'S OWN TEXT. It extracts the Linux block from
# §1s of SKILL.md and executes it against a fake release served over file://,
# with a stub cosign on PATH. A fixture that re-implemented the block would
# verify its own paraphrase and let the runbook rot underneath it.
#
# THE STUB MODELS A SIGNATURE, not a verdict: it records the bytes that were
# "signed" at setup and exits 0 only if the artifact still matches them. So ARM 3
# fails for the reason a real signature would fail, rather than because a stub
# was told to fail.
#
# COSIGN IS NOT INSTALLED ON THIS HOST, NOR IN THE TOOLBOX, NOR IN dnf (checked
# 2026-09-20 on yoga; macneo measured the same absence on macOS). So there is no
# real-cosign arm here, and this fixture must not pretend otherwise — the row's
# own criterion 2 is that could-not-run is never a pass, and that applies to the
# test as much as to the lane. ARM 1 pins the could-not-run path, which is the
# path every host in this fleet takes today.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKILL="skills/smoke-curl-install-and-test-e2e/SKILL.md"

# ---------------------------------------------------------------- ARM 0
# THE PREMISE: the runbook carries an extractable Linux verification block that
# probes for cosign. Without this every arm below would be testing a block it
# invented, and a deleted §1s would read as green.
awk '/^Linux — use the release/{f=1} f&&/^```bash$/{c=1;next} c&&/^```$/{exit} c' \
    "$SKILL" > "$TMP/linux-block.sh"
if [ ! -s "$TMP/linux-block.sh" ]; then
    bad "ARM 0: no Linux verification block could be extracted from $SKILL §1s — the runbook has no signature check to test"
elif ! grep -q 'command -v cosign' "$TMP/linux-block.sh"; then
    bad "ARM 0: the extracted block does not probe for cosign, so it cannot distinguish a missing tool from a bad signature"
else
    ok "ARM 0: the runbook's own Linux block extracted ($(wc -l < "$TMP/linux-block.sh") lines) and it probes for cosign"
fi

# A fake release served over file://. curl handles file:// URLs, so no network
# and no listener is needed.
REL="$TMP/release"; mkdir -p "$REL"
printf 'genuine tillandsias binary\n' > "$REL/tillandsias-linux-x86_64"
# The release's verify.sh is not in the checkout — it is published per release.
# The block calls `bash verify.sh <asset>`, so the fake release serves a
# stand-in with the SAME contract as the published one: refuse when cosign is
# absent, otherwise let cosign's status decide. Checked against the real
# v56.9.19.2 verify.sh, which is `set -euo pipefail`, exits 1 on a missing
# cosign, and prints its success line only after verify-blob returns 0.
cat > "$REL/verify.sh" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
ARTIFACT="${1:?artifact required}"
command -v cosign >/dev/null 2>&1 || { echo "Error: cosign is not installed." >&2; exit 1; }
cosign verify-blob --bundle "${ARTIFACT}.cosign.bundle" "${ARTIFACT}"
echo "Verification succeeded."
VERIFY
printf 'bundle for the genuine bytes\n' > "$REL/tillandsias-linux-x86_64.cosign.bundle"

# The stub: a signature binds to CONTENT. Records the signed bytes once.
STUBDIR="$TMP/stub"; mkdir -p "$STUBDIR"
sha256sum "$REL/tillandsias-linux-x86_64" | awk '{print $1}' > "$TMP/signed.sha"
cat > "$STUBDIR/cosign" <<STUB
#!/usr/bin/env bash
# stub cosign: exits 0 only when the artifact still matches the signed bytes.
art="\${@: -1}"
have="\$(sha256sum "\$art" 2>/dev/null | awk '{print \$1}')"
want="\$(cat "$TMP/signed.sha")"
[ "\$have" = "\$want" ]
STUB
chmod +x "$STUBDIR/cosign"

run_block() {  # <PATH to use>  -> echoes the cosign: line the block emitted
    ( cd "$TMP" && env PATH="$1" SMOKE_BASE="file://$REL" \
        bash "$TMP/linux-block.sh" 2>/dev/null | grep -E '^cosign:' | head -1 )
}

# ---------------------------------------------------------------- ARM 1
# NO COSIGN: could-not-run, named, and NOT a verified line. This is the path
# every host in this fleet takes today, so it is the one that must be right.
line="$(run_block "/usr/bin:/bin")"
if [ "$line" = "cosign:could-not-run:cosign-absent" ]; then
    ok "ARM 1: a host without cosign emits cosign:could-not-run:cosign-absent — not a pass, not a failure"
elif printf '%s' "$line" | grep -q '^cosign:verified'; then
    bad "ARM 1: a host WITHOUT cosign reported '$line' — a missing tool read as a verified signature, which is the could-not-run-as-ok shape this row exists to remove"
else
    bad "ARM 1: expected cosign:could-not-run:cosign-absent, got '${line:-<nothing>}'"
fi

# ---------------------------------------------------------------- ARM 2
# A GENUINE ARTIFACT VERIFIES. Without this, a block that refused everything
# would pass ARM 1 and ARM 3 and be useless.
line="$(run_block "$STUBDIR:/usr/bin:/bin")"
if [ "$line" = "cosign:verified:1/1" ]; then
    ok "ARM 2: an artifact matching its signature emits cosign:verified:1/1"
else
    bad "ARM 2: a genuine artifact did not verify, got '${line:-<nothing>}' — the block refuses everything and ARM 3 proves nothing"
fi

# ---------------------------------------------------------------- ARM 3
# THE ATTACK THE INTEGRITY CHECK CANNOT SEE, and the row's third criterion.
# Substitute the asset AND regenerate its SHA256SUMS entry so the hash check is
# self-consistent. The lane must still REFUSE, on the signature.
printf 'SUBSTITUTED payload\n' > "$REL/tillandsias-linux-x86_64"
sha256sum "$REL/tillandsias-linux-x86_64" | awk '{print $1"  tillandsias-linux-x86_64"}' > "$REL/SHA256SUMS"

# First prove the premise: the integrity check PASSES on the substituted pair.
if ( cd "$REL" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    line="$(run_block "$STUBDIR:/usr/bin:/bin")"
    if printf '%s' "$line" | grep -q '^cosign:FAILED:'; then
        ok "ARM 3: a substituted asset whose SHA256SUMS entry was regenerated PASSES the hash check and is REFUSED on the signature ($line)"
    elif printf '%s' "$line" | grep -q '^cosign:verified'; then
        bad "ARM 3: the substituted asset was reported VERIFIED ('$line') — the signature check does not bind to content and adds nothing over the hash"
    else
        bad "ARM 3: expected cosign:FAILED:, got '${line:-<nothing>}'"
    fi
else
    bad "ARM 3: premise broken — the regenerated SHA256SUMS does not validate the substituted asset, so this arm is not exercising the self-consistent-manifest case"
fi

# ---------------------------------------------------------------- ARM 4
# COULD-NOT-RUN IS NOT A PASS, IN THE REPORT. The second half of criterion 2
# lives in §5: a run that could not verify must not be filed as an unqualified
# PASS. Three honest "NOT CHECKED" declarations across three platforms did not
# close this gap; requiring the verdict itself to carry it is what does.
if grep -q 'signature_verification' "$SKILL" \
   && grep -q 'MUST NOT be reported as an' "$SKILL"; then
    ok "ARM 4: §5 requires the cosign line in the report's opening lines and forbids an unqualified PASS when it is could-not-run"
else
    bad "ARM 4: §5 does not require the signature line or does not forbid an unqualified PASS — a lane may again verify nothing and file a clean PASS"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:smoke-verifies-a-signature:%d/%d\n' "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:smoke-verifies-a-signature:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1
