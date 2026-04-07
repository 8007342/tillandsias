# fix-signing-spec-clarity

Clarify binary-signing spec: Rekor is required for CI signing (releases fail without it). The --insecure-ignore-tlog is only for user-side offline verification, not a production workaround. Update spec language to distinguish signing requirements from verification fallbacks. Fix .cosign.sig/.cosign.cert naming inconsistency between spec and implementation.
