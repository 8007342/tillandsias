## 1. Write SECRETS.md design document

- [x] 1.1 Draft the Overview section: transparent secrets management philosophy, user-facing simplicity
- [x] 1.2 Define Secret Categories table: GitHub auth, git identity, SSH keys, project tokens with scope and storage paths
- [x] 1.3 Document Current Implementation (MVP): plain directory mounts, `gh auth` storage, git config path
- [x] 1.4 Propose Future Encrypted Secrets Filesystem: LUKS/gocryptfs options, keyring integration, mount/unlock flow
- [x] 1.5 Write Per-Project vs Shared Credentials analysis with recommendations
- [x] 1.6 Write Security Model threat/mitigation table
- [x] 1.7 Document Mount Strategy: host paths to container paths mapping
- [x] 1.8 Define Implementation Phases (Phase 1/2/3) with scope boundaries

## 2. Write OpenSpec artifacts

- [x] 2.1 Write proposal.md: motivation, what changes, capabilities, impact
- [x] 2.2 Write design.md: context, goals/non-goals, key decisions
- [x] 2.3 Write specs/secrets-management/spec.md: requirements and scenarios
- [x] 2.4 Write tasks.md with document-writing tasks (not implementation tasks)

## 3. Nix Store & Build Chain (addendum)

- [x] 3.1 Document Nix store encryption strategy in SECRETS.md — builder toolbox isolation, content-addressed verification, encrypted-at-rest for Phase 2
- [x] 3.2 Document build artifact chain of trust — embedded sources (Phase 1) → image hash verification → signed images (Phase 3)
- [x] 3.3 Document secrets cache encryption lifecycle — gocryptfs/LUKS, keyring integration, auto-unlock/lock tied to container lifecycle

## 4. Review readiness

- [ ] 4.1 User reviews SECRETS.md and provides feedback
- [ ] 4.2 Incorporate review feedback into SECRETS.md and spec
