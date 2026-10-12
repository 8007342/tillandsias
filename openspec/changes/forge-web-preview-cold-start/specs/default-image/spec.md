## ADDED Requirements

### Requirement: Forge builds wasm32 web projects with its system toolchain

The forge image MUST let `cargo build --target wasm32-unknown-unknown` and
`wasm-pack build` succeed, using the image's system Rust toolchain with its
matching target standard library. No `rustup` and no network toolchain
download is allowed at build time.

> Delta: on 2026-10-12 a forge could not build a wasm web project. It had
> Fedora rustc and wasm-pack, but no `wasm32-unknown-unknown` std and no
> rustup (packet 1625-grk8).

#### Scenario: wasm-pack project builds in a fresh forge
- **WHEN** an agent runs `wasm-pack build` on a minimal wasm-bindgen crate in a freshly launched forge
- **THEN** the build produces `pkg/` without downloading a toolchain
