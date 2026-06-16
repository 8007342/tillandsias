---
title: Install Clang/LLVM toolchain (clang, clangd, clang-tidy, clang-format)
gap: "missing_tools: clang, clang++, clangd, clang-tidy, clang-format — C/C++ tooling gap alongside existing GCC"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install clang/LLVM toolchain via microdnf (clang, clang-tools-extra
      packages) alongside existing GCC installation. Provides clangd LSP,
      clang-tidy linter, and clang-format formatter.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260603T044258Z-summary.md`,
`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`,
`diagnostics_20260614T070420Z-summary.md`,
`diagnostics_20260614T230648Z-summary.md`) report that the Clang/LLVM
toolchain is absent.

GCC is installed (from the May 29 dev-quality-of-life batch), but Clang is
the de facto standard for C/C++ LSP (clangd), linting (clang-tidy), and
formatting (clang-format). Many modern C/C++ projects prefer Clang over GCC.

## Evidence

- Reported in 5+ diagnostics files across multiple dates
- `missing_tools` consistently includes `clang`, `clangd`, `clang-tidy`, `clang-format`
- GCC present but Clang absent — complementary, not replacement

## Privacy/Isolation Assessment

- Installed via microdnf from Fedora repos — same envelope as existing GCC
- No network egress beyond package download at build time
- All tools are local executables; no daemon or root requirements
- **Safe within the existing privacy/isolation envelope**
