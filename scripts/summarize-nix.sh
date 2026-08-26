#!/bin/bash
# @trace spec:project-summarizers
# freshness: auditor=linux-lenovinha-fable5-20260823t235308z date=2026-08-24 verdict=refreshed scope=full file, 52 lines, exercised. Correct on both paths: against this repo's flake.nix it emits the three sections and exits 0; against a directory with no flake.nix it exits 2, which its own comment defines as skip-not-error and which is the contract a summarizer dispatcher needs. Still meaningful — one of six sibling summarizers that give a cold-start agent a project's shape without reading its build files.
# freshness-notes, neither acted on: (1) its litmus (project-summarizers-shape) pins all six siblings by GREPPING FOR SOURCE STRINGS — the annotation line and `set -euo pipefail` — so it constrains text rather than behaviour; nothing executes these scripts in CI. Same weakness recorded on resolve-smoke-release.sh 2026-08-23; it is a family pattern across the shape-litmus suite rather than a defect in this file. (2) shebang is `#!/bin/bash` where the repo's convention is `#!/usr/bin/env bash`; harmless on macOS and Fedora, but it is the one shape that breaks on NixOS, which is a pointed place for the NIX summarizer to break. Left alone because changing it is a behaviour change to all six or to none.

set -euo pipefail

FLAKE_NIX="${1:-.}/flake.nix"

# If flake.nix not found, exit with code 2 (skip, not error)
if [ ! -f "$FLAKE_NIX" ]; then
  exit 2
fi

# Parse flake.nix to extract system, inputs, and outputs

echo "### Languages"
echo ""
echo "- Nix (reproducible builds + environments)"
echo ""

echo "### Runtimes"
echo ""

# Extract inputs (check for common ones)
if grep -q 'nixpkgs' "$FLAKE_NIX"; then
  echo "- nixpkgs (package repository)"
fi
if grep -q 'flake-utils' "$FLAKE_NIX"; then
  echo "- flake-utils (multi-platform helpers)"
fi
if grep -q 'rust-overlay' "$FLAKE_NIX"; then
  echo "- rust-overlay (Rust toolchain)"
fi
if grep -q 'flutter' "$FLAKE_NIX"; then
  echo "- flutter (cross-platform UI)"
fi

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Look for devShells or buildInputs
if grep -q 'devShell' "$FLAKE_NIX"; then
  echo "- Development shell (nix flake show)"
fi
if grep -q 'buildInputs' "$FLAKE_NIX"; then
  echo "- Custom build dependencies"
fi

echo ""

exit 0
