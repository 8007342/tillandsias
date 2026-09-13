#!/usr/bin/env bash
# @trace order:1129-xm5z
#
# check-ripgrep-available.sh — is ripgrep present on this host?
#
# ONE LINE ON STDOUT, exit 0 either way. This is a PRESENCE PROBE, not a gate:
# it answers a question and never refuses. The gate's teeth for the thing that
# needs rg live in check-cheatsheet-refs.sh; duplicating a refusal here would
# give one condition two verdicts.
#
#   ok:rg:<version>   ripgrep resolves on PATH
#   missing:rg        it does not
#
# WHY STDOUT AND WHY EXIT 0. scripts/test-host-tools.sh falsifies every
# prover-backed row by hiding the tool and reading the prover's LAST STDOUT
# LINE (`bash scripts/<prover> 2>/dev/null | tail -1`), then matching it
# against the row's <expect>. A prover that reports absence on STDERR, or that
# exits non-zero, cannot be falsified by that arm — which is exactly why
# check-cheatsheet-refs.sh is the wrong prover for this row: it writes its
# rg-absent refusal to stderr and exits 2, and it proves a downstream SYMPTOM
# rather than the tool's presence.
#
# ORDER 1129-xm5z. rg was absent from the tillandsias-build WSL2 distro and
# nothing provisioned it. 1087-h2z9 promoted the cheatsheet-reference check
# from --ci-full into --check, so every land on every host now needs rg.
# MEASURED on esmeraldinha 2026-09-12: the land refused with
# `a cheatsheet reference does not resolve (1087-h2z9)` having examined ZERO
# references — a missing INSTRUMENT reported as a verdict about CONTENT. With
# rg present the same step passes in 4.2s over 577 references.
set -u

if command -v rg >/dev/null 2>&1; then
    # `| head -1` because rg --version prints several lines; the row asserts
    # presence, not a version floor, so the first line is the whole answer.
    version="$(rg --version 2>/dev/null | head -1 | awk '{print $2}')"
    printf 'ok:rg:%s\n' "${version:-unknown}"
else
    printf 'missing:rg\n'
fi
exit 0
