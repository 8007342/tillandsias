## MODIFIED Requirements

### Requirement: Coding agents are image-baked, not runtime-installed

Claude Code, OpenCode, and OpenSpec SHALL be installed into the forge
image at `podman build` time. The binaries SHALL live under
`/opt/agents/{claude,opencode,openspec}/` with symlinks at
`/usr/local/bin/{claude,opencode,openspec}`. No runtime installer
(npm, curl | bash) SHALL run on each attach.

Rationale: the prior runtime tools overlay re-installed these agents on
every launch into a bind-mounted `/home/forge/.tools` directory. It
added ~7s to every attach, routinely failed the OpenCode install
(dropping the binary outside the overlay target path), and duplicated
work whose output was already in the image. Hard-install gives
deterministic agent versions per forge image tag, zero runtime
network for agents, and one fewer failure surface.

#### Scenario: Agents resolve from image at attach time
- **WHEN** a forge container is freshly spawned
- **THEN** `which claude opencode openspec` inside the container SHALL
  return `/usr/local/bin/{claude,opencode,openspec}` respectively
- **AND** the binaries SHALL be present without any runtime install
  step running on the host

#### Scenario: No runtime overlay build runs
- **WHEN** the user runs `tillandsias <project>` with a fresh or
  existing forge image
- **THEN** the tray SHALL NOT invoke `scripts/build-tools-overlay.sh`
  (the script SHALL NOT exist in the repo or the embedded source tree)
- **AND** no temporary forge container SHALL spawn to populate
  `/home/forge/.tools`
- **AND** no `[tools-overlay]` log lines SHALL appear at attach time
