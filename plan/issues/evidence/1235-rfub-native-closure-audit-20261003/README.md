# 1235-rfub native closure audit — 2026-10-03

Source audited: `3c05fc230a06ae72efc3daa592bb48900cb62c4c` on
`aarch64-apple-darwin`, macOS 27.0.1, Rust/Cargo 1.96.1.  `b35acba6c` and
the relayed `ccbd36616` are ancestors of this source (see `provenance.raw`
and `mechanism-audit.raw`).

## Receipts

- `test-native-lint-attested.raw`: exit 0; 8/8 scratch-repository controls.
- `clippy-tray.status`: exit 0 for the required real native command.
- `clippy-tray.raw`: unmodified Cargo/Clippy stream; no Rust diagnostic or
  source-line citation was emitted.

## Mechanism audit

`attest-native-lint.sh` runs `cargo clippy -p <pkg> --all-targets -- -D
warnings` and records the native crate-tree identity in `Native-Lint`.
`check-native-lint-attested.sh` compares that identity against `HEAD` and
refuses unattested or stale content.  `land-on-platform-branch.sh` invokes
that check after integration and before its build gate, refusing the land on
failure.  The fixture covers no attestation, failed lint/no writer commit,
all-targets argv, stale content, wrong platform, out-of-scope change, relay
wiring, and override behavior.

## Closure disposition

The normal relay path satisfies the original native-lint and all-targets
criteria.  It does **not** literally satisfy the absolute first criterion:
the deliberately supported named `TILLANDSIAS_NATIVE_LINT_UNATTESTED` path
allows an unlinted crate to land as an explicitly recorded
`Native-Lint-Unattested` debt.  Fixture arm 8 proves this exception.  Do not
mark the unchanged criterion closed unless its owner accepts or amends that
recorded-debt exception.
