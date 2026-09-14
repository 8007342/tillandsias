#!/usr/bin/env bash
# ORDER 1118-d3b6. The inference engine is pinned and verified before it is
# executed, and the NPU banner states what is true rather than staying silent.
#
# WHAT WAS WRONG. images/inference/entrypoint.sh fetched
# `releases/latest/download/ollama-linux-<arch>.tar.zst` with no checksum, then
# streamed it through zstd/tar and EXECUTED the result inside the enclave.
# `latest` is not a version: whatever GitHub resolved at CONTAINER START ran, so
# two containers from one image, started an hour apart, could execute different
# code and nothing recorded which.
#
# Separately, `grep -i npu` over that entrypoint returned NOTHING while
# openspec/specs/inference-container/spec.md:165-179 specified engine-gated N1/N2
# NPU tier rows. The spec described telemetry the runtime never emitted, and the
# silence read as satisfaction.
#
# REGIME. These are STATIC assertions over the shipped entrypoint, and that is
# deliberate: the subject is what the image WILL do on a host we are not on, so
# running it here would test this machine instead of the artifact. The digest
# arms therefore check the pin and the refusal paths, not a live download — a
# 1.4GB fetch in a gate would be its own defect.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

EP="images/inference/entrypoint.sh"
SPEC="openspec/specs/inference-container/spec.md"
[ -f "$EP" ] || { bad "$EP is missing"; echo "inference-engine-pinned-and-npu-honest: $pass passed, $fail failed"; exit 1; }

# Code only. A comment quoting the old URL to explain what was removed must not
# read as the defect being present — the 888-m75r incidental-co-occurrence
# error, which bit a fixture of mine earlier tonight.
#
# CAPTURED ONCE, NOT PIPED PER ARM (792-ksr8). The first cut of this file ran
# `code "$EP" | grep -q ...` in every arm, and under `set -o pipefail` that is a
# RACE: `grep -q` exits on the first match and SIGPIPEs the upstream `grep -v`,
# so the pipeline status depends on which side won. One arm reported "no
# sha256sum of the payload" on an entrypoint that plainly checksums it, while
# neighbouring arms using the same construct passed. Capture, then match.
_CODE="$(grep -vE '^[[:space:]]*#' "$EP")"
#
# `grep -c`, NEVER `grep -q`. -q exits on the FIRST match and SIGPIPEs whatever
# feeds it; under `set -o pipefail` the pipeline then reports failure on a
# SUCCESSFUL match, decided by which side won the race. Capturing was not enough
# on its own — the second cut of this file still went 11/1 then 12/0 four times
# in a row. -c reads its input to EOF, so there is no early exit to race, and the
# count is compared in the shell where nothing can signal.
code_has()  { [ "$(printf '%s\n' "$_CODE" | grep -c -- "$1")" -gt 0 ]; }
code_hasE() { [ "$(printf '%s\n' "$_CODE" | grep -cE -- "$1")" -gt 0 ]; }
code_hasI() { [ "$(printf '%s\n' "$_CODE" | grep -ci -- "$1")" -gt 0 ]; }

# ── 1. THE DEFECT: no `releases/latest` download in live code. ─────────────
if code_has 'releases/latest/download'; then
    bad "the entrypoint still downloads releases/latest — the executed payload is whatever GitHub resolves at container start"
else
    ok "no releases/latest download remains in live code"
fi

# ── 2. A VERSION IS PINNED, and the URL is built from it. ─────────────────
if code_hasE 'OLLAMA_VERSION="v[0-9]+\.[0-9]+\.[0-9]+"'; then
    ok "a concrete engine version is pinned"
else
    bad "no pinned OLLAMA_VERSION — the download is not reproducible"
fi
if code_has 'releases/download/${OLLAMA_VERSION}/'; then
    ok "the download URL is built from the pinned version"
else
    bad "the URL does not use OLLAMA_VERSION, so the pin does not reach the fetch"
fi

# ── 3. A DIGEST EXISTS FOR EVERY ARCH THE SCRIPT ACCEPTS. A pin that covers
#      one arch leaves the other fetching unverified, which is the defect
#      surviving on half the fleet.
_arches="$(printf '%s\n' "$_CODE" | sed -n 's/.*) *OLLAMA_ARCH="\([a-z0-9]*\)".*/\1/p' | sort -u)"
for a in $_arches; do
    if code_hasE "^[[:space:]]*${a}\)[[:space:]]*OLLAMA_SHA256=\"[0-9a-f]{64}\""; then
        ok "arch '$a' carries a 64-hex pinned digest"
    else
        bad "arch '$a' is accepted by the script but has no pinned digest — it would fetch unverified"
    fi
done

# ── 4. VERIFICATION HAPPENS, AND FAILS CLOSED. Three refusal paths: no pin for
#      this arch, no sha256sum available, digest mismatch. The middle one is the
#      one most likely to be written as a skip — scripts/install.sh does exactly
#      that ("sha256sum not found; skipping checksum verification"), which is a
#      defensible usability trade on a user's host and the WRONG trade in an
#      enclave that executes the payload.
if code_has 'sha256sum'; then
    ok "the payload is checksummed before use"
else
    bad "no sha256sum of the payload — it is extracted and executed unverified"
fi
_refusals=0
code_has 'no pinned SHA-256 for arch' && _refusals=$((_refusals+1))
code_has 'sha256sum unavailable'      && _refusals=$((_refusals+1))
code_has 'engine digest mismatch'     && _refusals=$((_refusals+1))
if [ "$_refusals" -eq 3 ]; then
    ok "all three refusal paths are present (missing pin / missing verifier / mismatch)"
else
    bad "only $_refusals of 3 refusal paths present — one of them falls through and executes the payload"
fi
if code_hasE 'skipping checksum verification'; then
    bad "the entrypoint SKIPS verification when the verifier is absent — a missing verifier is a reason to refuse, not to trust"
else
    ok "a missing verifier refuses rather than skipping (unlike the host installer, deliberately)"
fi

# ── 5. VERIFY BEFORE EXTRACT. Order matters: a digest checked after unpacking
#      has already let the archive touch the filesystem.
_ln_verify="$(printf '%s\n' "$_CODE" | grep -n 'engine digest mismatch' | head -1 | cut -d: -f1)"
_ln_extract="$(printf '%s\n' "$_CODE" | grep -n 'zstd -dc' | head -1 | cut -d: -f1)"
if [ -n "$_ln_verify" ] && [ -n "$_ln_extract" ] && [ "$_ln_verify" -lt "$_ln_extract" ]; then
    ok "the digest is checked BEFORE the archive is unpacked"
else
    bad "verification does not precede extraction (verify@${_ln_verify:-none} extract@${_ln_extract:-none})"
fi

# ── 6. THE NPU BANNER SAYS SOMETHING. The defect was silence while the spec
#      described N1/N2 rows.
if code_hasI 'NPU'; then
    ok "the entrypoint reports NPU state at all (it previously said nothing)"
else
    bad "no NPU telemetry — the spec describes engine-gated NPU rows the runtime never mentions"
fi
if code_has 'NPU_STATUS'; then
    ok "NPU state is a reported value, not a constant string in the banner"
else
    bad "no NPU_STATUS value is computed"
fi

# ── 7. CONTROL: the spec still claims NPU rows. If this arm ever reds, the
#      spec was changed and arm 6 is pinning telemetry for a requirement that no
#      longer exists — the reconciliation would then be stale in the other
#      direction, and this file should be revisited rather than trusted.
if [ -f "$SPEC" ] && [ "$(grep -ci 'NPU' "$SPEC")" -gt 0 ]; then
    ok "CONTROL: the spec still specifies NPU rows, so reporting NPU state is still the reconciliation"
else
    bad "CONTROL: the spec no longer mentions NPU — arm 6 now pins telemetry for a requirement that was removed"
fi

echo "inference-engine-pinned-and-npu-honest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
