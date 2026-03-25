## ADDED Requirements

### Requirement: Cosign signing produces verifiable signatures
All release artifacts SHALL be signed with Cosign keyless mode and verifiable locally.

#### Scenario: Successful local verification
- **WHEN** a signed artifact and its `.cosign.sig` and `.cosign.cert` files are downloaded
- **THEN** `cosign verify-blob` succeeds with the correct identity and OIDC issuer

#### Scenario: Tampered artifact fails verification
- **WHEN** a downloaded artifact is modified (e.g., a byte appended)
- **THEN** `cosign verify-blob` fails and reports signature mismatch

#### Scenario: Rekor transparency log entry exists
- **WHEN** a Cosign-signed artifact is released
- **THEN** the signature is recorded in the Rekor transparency log and searchable by artifact hash

#### Scenario: Verification on clean machine
- **WHEN** the release notes verification instructions are followed on a machine with no prior Cosign state
- **THEN** the verification succeeds without additional configuration
