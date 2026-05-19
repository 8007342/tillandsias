# certificate-validation Specification

@trace spec:certificate-validation

## Status

active

## Requirements

### Requirement: Enclave TLS validation is explicit

Containers and host-side probes that participate in proxy-mediated HTTPS MUST use a known CA bundle path and MUST fail with diagnosable output when the expected CA material is missing or malformed.

#### Scenario: Missing CA material is reported

- **WHEN** a component needs the Tillandsias intermediate CA but the mounted certificate is absent
- **THEN** startup or validation MUST report the missing path
- **AND** it MUST NOT silently disable certificate validation for runtime traffic

## Sources of Truth

- `cheatsheets/runtime/networking.md` - Network trust boundary context
- `cheatsheets/runtime/squid-cache-peer-routing.md` - Proxy routing context
- `cheatsheets/security/owasp-top-10-2021.md` - Security failure handling reference

