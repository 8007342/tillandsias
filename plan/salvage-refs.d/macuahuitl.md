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
| 2026-09-14T08:19:30Z | refs/heads/salvage/tlatoanis-macbook-air/20260914-804deux-blocked-on-1183-j9dk | 8b3208b027d2d89a9531c8e93c2376a00b19cf4d | none | 5 | deleted
| 2026-09-14T08:19:31Z | refs/heads/salvage/toolbx/20260914---help | 5f4b122e2486280151a167379b8c6e7440aa0148 | on:linux-next,windows-next | 6 | deleted
| 2026-09-14T08:19:31Z | refs/heads/salvage/toolbx/20260914---help-053147 | be5a3275ec6f617e25a4a68835d20788ba7d86c7 | on:linux-next,windows-next | 7 | deleted
| 2026-09-14T08:19:32Z | refs/heads/salvage/toolbx/20260914---help-054359 | bff49e06cb44d2bbc2aa80757be49e4190a295ab | on:linux-next,windows-next | 6 | deleted
| 2026-09-14T08:19:32Z | refs/heads/salvage/toolbx/20260914---help-060203 | 59225de1d36f9bb877534b8d1937f4b36fe73a5a | on:linux-next,windows-next | 5 | deleted
| 2026-09-14T08:19:32Z | refs/heads/salvage/toolbx/20260914---help-074445 | 8891fab221e3775621e8776c6108dd5f313c4914 | none | 6 | deleted
| 2026-09-14T08:19:33Z | refs/heads/salvage/toolbx/20260914---help-080232 | 213d1ce244e30e65c27d1c21db063399cfb2db09 | on:linux-next | 7 | deleted
| 2026-09-14T08:19:33Z | refs/heads/salvage/yoga/20260914---help | c75e1c4be0b3819d3759bc617cff41f134fd347b | none | 2 | deleted
| 2026-09-14T08:19:33Z | refs/heads/salvage/yoga/20260914---help-045526 | 8fb65bdb4a0fea3266b96d68d53608eb28ca6d2f | none | 2 | deleted
| 2026-09-14T08:19:34Z | refs/heads/salvage/yoga/20260914---help-045529 | 4712c62d84ac9a466dc9aa453340302f57934ef1 | none | 2 | deleted
| 2026-09-14T08:19:34Z | refs/heads/salvage/yoga/20260914---help-045531 | a50422e0aa479a6e00b2c31084c3e9a890408aa0 | none | 2 | deleted
| 2026-09-14T08:19:35Z | refs/heads/salvage/yoga/20260914---help-045539 | 7ee26fdeb98996e518ea14b152394a862bf852b8 | none | 2 | deleted
| 2026-09-14T08:19:35Z | refs/heads/salvage/yoga/20260914---help-045546 | 0e2b80ec238ba3de2d5f7377587d4846ba22f52e | none | 2 | deleted
| 2026-09-14T08:19:35Z | refs/heads/salvage/yoga/20260914---help-045549 | de9691adb4d91fef62a4d130c8abcfc28c38d276 | none | 2 | deleted
| 2026-09-14T10:12:54Z | refs/heads/salvage/tlatoanis-macbook-air/20260914---help | 83658b439c0159df0e24a7569354975a2a50694f | on:osx-next | 37 | deleted
| 2026-09-14T10:12:54Z | refs/heads/salvage/toolbx/20260914---help-082022 | ff91de8600496dabeba48be42eb598c393f73979 | on:linux-next,osx-next | 7 | deleted
| 2026-09-14T10:12:54Z | refs/heads/salvage/toolbx/20260914---help-094324 | beeef3d38fd894b111acfc2bb4a12a77df9aeb06 | on:linux-next | 1 | deleted
| 2026-09-14T10:12:55Z | refs/heads/salvage/toolbx/20260914---help-095443 | 73e6b29029577db6166e4db78c42327b12fe5bf7 | on:linux-next | 3 | deleted
