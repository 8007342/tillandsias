## REMOVED Requirements

### Requirement: Summarizers MUST parse manifest files deterministically
**Reason**: Never wired. No image or crate embeds, copies or calls a summarizer; the six shipped scripts were deleted (order 2114-sdj6, coordinator ruling 2026-11-19).
**Migration**: None needed; nothing ran them. A future forge summarizer is new work in Rust.

### Requirement: Summarizers MUST output structured, consistent data
**Reason**: Withdrawn with the shipped summarizers it constrained (order 2114-sdj6).
**Migration**: A drop-in summarizer for the dispatcher follows the interface in cheatsheets/welcome/readme-discipline.md.

### Requirement: Summarizers MUST be embeddable as shell scripts
**Reason**: The embedding never existed: no include_str!, no Containerfile COPY, and /opt/summarizers/ is created by no image (order 2114-sdj6).
**Migration**: None.
