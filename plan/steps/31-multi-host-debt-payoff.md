# Step 31 — Multi-Host Simplification & Debt Payoff

Status: ready
Owner: multi-host
Depends on: [github-vault-integration]

## Goal
Pay off technical debt accumulated during the Fedora pivot and simplify the multi-host coordination logic.

## Tasks
- [ ] **Methodology Audit**: Review `methodology/*.yaml` and ensure they align with the current Fedora Cloud / WSL2 implementation.
- [ ] **Cheatsheet Synchronization**: Verify that all `images/default/cheatsheets/` are correctly mirrored to the host and surfaced by the agents.
- [ ] **Install Script Hardening**: Ensure `install-windows.ps1` and `install-macos.sh` are fully convergent with the v0.3.0 released binary.
- [ ] **Plan Archive Cleanup**: Final sweep of any remaining stale plan items or issues.

## Exit Criteria
- Zero discrepancy between documentation and implementation.
- 100% pass rate on all cross-platform installers.
- CentiColon dashboard shows 100% closure of the v0.3.0 wave.
