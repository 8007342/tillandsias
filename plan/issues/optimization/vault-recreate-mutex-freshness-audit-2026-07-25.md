# Freshness audit: Vault recreate mutex litmus

- **Date**: 2026-07-25
- **Classification**: optimization
- **Component**: `openspec/litmus-tests/litmus-vault-recreate-mutex.yaml`
- **Verdict**: updated
- **Auditor**: `linux-opencode-metaorch-20260725`

The litmus remains meaningful and necessary, but its former whole-lane shared
lock assertion encoded the starvation mechanism reproduced by order 463. It was
updated with the source fix to preserve shared/exclusive exclusion during
bounded Vault operations while proving an idle AppRole secret lease retains no
resource lock. The focused `tillandsias-vault` litmus set passes 12/12 and the
component now carries the canonical freshness stamp.
