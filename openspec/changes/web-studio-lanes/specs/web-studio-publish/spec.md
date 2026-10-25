## ADDED Requirements

### Requirement: publish is an explicit, named handoff to the deploy tool

A studio's Publish control and `studio_publish_request` SHALL do nothing until the user explicitly confirms the publish in a dialog that names the revision. On confirmation, they SHALL hand that revision to the host-side Cloudflare deploy tool (order 1853-qr4h), which moves only the deploy branch. A save, a commit, or a push to any other branch SHALL trigger zero cloud builds. No credential SHALL enter the forge or the studio.

#### Scenario: agent requests publish without user consent

- **WHEN** the agent calls `studio_publish_request` with no user confirmation
- **THEN** the request is held as pending, and the deploy tool is not called

#### Scenario: saves never build

- **WHEN** the user saves fifty times and the agent pushes a work branch
- **THEN** the fake deploy API records zero builds
