## Context
Same pattern as Attach Here — open terminal running podman command. GitHub Login mounts secrets volume so credentials persist.
## Decisions
### D1: GitHub Login uses the forge image with only secrets mounted (no project)
### D2: Terminal opens bash (not opencode) in the forge with the project mounted
### D3: Detection: check ~/.cache/tillandsias/secrets/gh/hosts.yml exists
