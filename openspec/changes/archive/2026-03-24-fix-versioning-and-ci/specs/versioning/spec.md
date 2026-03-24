## MODIFIED Requirements
### Requirement: Monotonic version increments
Every version SHALL have a strictly increasing build number that NEVER resets.
#### Scenario: Bump changes preserves monotonic build
- **WHEN** --bump-changes is run at v0.0.5.10
- **THEN** the result is v0.0.6.11 (build incremented, not reset)
