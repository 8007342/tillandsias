## ADDED Requirements

### Requirement: each host enrols one approval key

Each host SHALL enrol one approval key that the OS releases only after a user
check: Secure Enclave behind Touch ID on macOS, a Windows Hello key credential
on Windows, a FIDO2 security key on Linux. Without such hardware the host SHALL
use a software key released after a polkit check, labelled
`software-password`. The private key SHALL never be stored in plaintext or
enter a forge.

#### Scenario: enrolment publishes only the public key

- **WHEN** the operator enrols a key from the tray
- **THEN** the mirror's allowed-signers file gains one line with the host name
  and public key, and no private key material exists outside the OS key store
  or the security key

#### Scenario: the strength is stated, not inflated

- **WHEN** a Linux host without a security key signs an approval
- **THEN** the statement's `strength` is `software-password`

### Requirement: a signature needs a fresh user check

Each approval signature SHALL require its own user check; the platform SHALL
NOT reuse a recent authentication to sign silently.

#### Scenario: two approvals, two checks

- **WHEN** two gated actions are approved one after the other
- **THEN** the OS prompt (Touch ID, Hello or key touch) appears twice

### Requirement: signatures are SSHSIG

Every platform signer SHALL emit an `SSHSIG` signature with namespace
`tillandsias-approval@v1` that `ssh-keygen -Y verify` accepts with the
host's allowed-signers line.

#### Scenario: a platform signature verifies with stock ssh-keygen

- **WHEN** a statement signed on any platform is checked with
  `ssh-keygen -Y verify -n tillandsias-approval@v1`
- **THEN** it verifies, and the same signature over a statement with one
  changed byte does not
