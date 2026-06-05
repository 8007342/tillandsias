# Forge Diagnostics Summary — 2026-06-03T21:59:26Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260603T215926Z.log`
- **Forge version**: 0.2.260602.7 (from-envelope; in-forge JSON missing)
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 0 / 0 checks passed (0%)

## Parse Errors

- Extra data: line 143 column 1 (char 6660)

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260603T215926Z.stderr.log`
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
| event:container_stderr     | 126   |

#### container_stderr — top 5 containers by line count
```
    118 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
