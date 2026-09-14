# salvage-refs ledger -- macuahuitl.md (order 1148-3439)
# Append-only: one line per refs/heads/salvage/* ref this ledger has ever
# recorded. Written by: scripts/sweep-salvage-refs.sh --apply.
# Grammar: | <utc-first-seen> | <ref> | <sha> | <ancestry> | <files> |
#   ancestry: on:<branch>[,<branch>...] for every one of linux-next,
#   windows-next, osx-next, main whose origin/<branch> ref contains the sha,
#   or none.
#   files: git diff --name-only <sha>^ <sha> count, or - when no parent exists.
# A ref confirmed merged or consciously abandoned gets a trailing " deleted"
# marker appended BY HAND; a line is otherwise immutable, never removed or
# rewritten.
# Gate: scripts/check-salvage-refs-ledger.sh (not yet wired into
# ./build.sh --check — see that script's header for where it belongs).
| 2026-09-13T11:52:58Z | refs/heads/salvage/pirria/20260902-brew-shim-reentrancy | 6e6a5e0258f08e04079e96ee8ab79e005b9ffe48 | on:linux-next,windows-next,osx-next,main | 1 |
| 2026-09-13T11:52:58Z | refs/heads/salvage/pirria/20260902-floor-measurements | 2181470af6a1d8ceccf6dd0149fdd8acf261a282 | on:linux-next,windows-next,osx-next,main | 2 |
| 2026-09-13T11:52:59Z | refs/heads/salvage/pirria/20260903-forge-gate-green | d153153cfeb0db4176cd31384a3a565aace88475 | on:linux-next,windows-next,osx-next,main | 1 |
| 2026-09-13T11:52:59Z | refs/heads/salvage/unknown/20260902-opsx-claude-lane-dirt | b0536e8686ffd2b838e0d376dafd7f0a656affd3 | none | 22 |
| 2026-09-13T11:52:59Z | refs/heads/salvage/unknown/20260902-opsx-claude-locus-generated | 9e681f9b345f4c3ec09cbc91c53862012166aec4 | none | 22 |
| 2026-09-13T18:12:00Z | refs/heads/salvage/yolanda/20260913-793-zumy | 6f6bb4ad72c56e87ad00c685ab74abe492e90489 | on:linux-next,windows-next,osx-next | 3 | deleted
| 2026-09-14T02:11:45Z | refs/heads/salvage/lenovinha/20260914-1159-g96c | 477e5ed774aeb6c1bd9186a4e73c8ad639f603f7 | none | 11 | deleted
| 2026-09-14T04:32:51Z | refs/heads/salvage/macuahuitl/20260914-1142-85zx | 59009673e9c9e911d0d3f75eadd585ab80830b78 | none | 4 | deleted
