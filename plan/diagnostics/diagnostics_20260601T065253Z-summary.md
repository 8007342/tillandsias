# Forge Diagnostics Summary — 2026-06-01T00:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260601T065253Z.log`
- **Forge version**: 0.2.260531.3
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- nix
- flutter
- gradle
### Proposed enhancements
- other: nix — forge-discovery cheatsheets reference build/nix-flake-basics.md and nix-first.md instruction exists, but nix is not installed
- dart: flutter — flutter.md agent instruction exists and dart SDK is present at /opt/dart-sdk/bin/dart, but flutter SDK is not installed
- jvm: gradle — GRADLE_USER_HOME is pre-configured to /home/forge/.cache/tillandsias-project/gradle and Java 25 is installed, but gradle binary is absent
- other: cheatsheets — /opt/cheatsheets is an 8M dedicated tmpfs for this purpose but is completely empty; populate with forge-paths-ephemeral-vs-persistent.md, nix-flake-basics.md, and other referenced cheatsheets

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260601T065253Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 159   |

#### container_stderr — top 5 containers by line count
```
    151 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
