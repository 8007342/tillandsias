#!/usr/bin/env bash
# Runs INSIDE a forge image (--network=none). Fixtures are copied out of the
# read-only mount so the build writes nowhere shared.
set -u
export CARGO_HOME=/tmp/cargo HOME=/tmp/home
mkdir -p "$CARGO_HOME" "$HOME"
cp -r /fx/libcrate /fx/bindgen /tmp/
echo "rustc: $(rustc --version)"
echo "wasm32 std rpm: $(rpm -q rust-std-static-wasm32-unknown-unknown 2>&1)"
echo "== cargo build --target wasm32-unknown-unknown (minimal lib crate, offline)"
if out="$(cd /tmp/libcrate && cargo build --offline --release --target wasm32-unknown-unknown 2>&1)"; then
  ls -la /tmp/libcrate/target/wasm32-unknown-unknown/release/grk8_lib.wasm
  echo "CARGO_WASM32=ok"
else
  printf '%s\n' "$out" | grep -E '^error' | head -3
  echo "CARGO_WASM32=fail"
fi
echo "== wasm-pack build (minimal wasm-bindgen crate, vendored deps, offline)"
if out="$(cd /tmp/bindgen && PATH=/fx/bin:$PATH wasm-pack build --mode no-install --no-opt --target web 2>&1 -- --offline)"; then
  ls /tmp/bindgen/pkg
  echo "WASM_PACK=ok"
else
  printf '%s\n' "$out" | grep -E 'Error|error' | head -4
  echo "WASM_PACK=fail"
fi
