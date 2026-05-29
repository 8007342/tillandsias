# Forge Diagnostics Summary — unknown

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260528T190248Z.log`
- **Forge version**: unknown
- **Completeness**: 0 / 0 checks passed (0%)

## Parse Errors

- Expecting value: line 1 column 1 (char 0)

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260528T190248Z.stderr.log`
- **Total launch events**: 8
- **state=running**: 3
- **state=failed**: 1

### Distinct stage → state pairings

```
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=opencode state=failed
event:container_launch stage=opencode state=starting
```

### ❌ Failed launches

```
[2026-05-28T19:04:09.288Z] event:container_launch stage=opencode state=failed container=tillandsias-tillandsias-forge detail="stage 'opencode' attached command exited with status 1"
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 115   |

#### container_stderr — top 5 containers by line count
```
    107 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```
