---
title: Install build essential tools (gcc, g++, make, cmake)
gap: Native compilation toolchain is missing from the forge image; many npm packages and Rust builds require gcc/g++ and make
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T10:50:00Z
changes:
  - file: images/default/Containerfile
    description: Add `gcc gcc-c++ make cmake` to the microdnf install RUN layer. These are required for compiling native Node.js addons (node-gyp), Cargo native deps, and general build workflows.
approved_by: null
---

## Gap

The forge image does not include `gcc`, `g++`, `make`, or `cmake`. These are required for:

1. **npm native addons**: Packages like `node-gyp`, `sharp`, `bcrypt`, and many others require a C/C++ compiler and `make` to build native extensions.
2. **Cargo dependencies**: Some Rust crates have C/C++ build-time dependencies that need `gcc` and `cmake`.
3. **General development**: Agents building C/C++ projects, compiling native modules, or running `configure`/`make`-style builds.

The forge-completeness-baseline audit shows 36% of forge requirements have NO coverage, and the lack of a native toolchain is a common failure point for agents trying to build projects.

## Evidence

- `images/default/Containerfile` lines 17-24: system packages install bash, git, nodejs, java, maven — no gcc, make, or cmake
- Fedora Minimal 44 packages: `gcc`, `gcc-c++`, `make`, `cmake` are all available via microdnf

## Safety

- All packages are standard Fedora Minimal packages — no untrusted downloads.
- Adding ~50-80 MB to the image for the full native toolchain.
- No credentials or secrets are involved.
