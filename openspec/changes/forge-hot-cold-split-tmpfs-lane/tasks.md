## 1. Spec landing

- [x] 1.1 Author proposal.md, design.md, and the forge-hot-cold-split delta spec
- [x] 1.2 Validate via `openspec validate forge-hot-cold-split-tmpfs-lane --strict`

## 2. Cheatsheet alignment

- [ ] 2.1 Update `cheatsheets/runtime/forge-hot-cold-split.md` to document the tmpfs-overlay lane as the third pattern (alongside HOT and COLD); refresh provenance + `Last updated:` date

## 3. Apply-time hooks (deferred to cheatsheets-license-tiered)

- [ ] 3.1 Implement `MemTotal` detection in tray startup → resolve cap → set `TILLANDSIAS_PULL_CACHE_RAM_MB`
- [ ] 3.2 Implement the tmpfs-overlay cache mechanism inside the forge (writes to `~/.cache/tillandsias/cheatsheets-pulled/<project>/`)
- [ ] 3.3 Implement LRU eviction across the tmpfs/disk boundary, scoped per-project
- [ ] 3.4 Add the four-HOT-roots enumeration scenario (proves the tmpfs-overlay path does NOT appear in the HOT root list)

> Tasks 3.1–3.4 are tracked here for spec-completeness but are EXECUTED inside the `cheatsheets-license-tiered` apply phase. This change is spec-only; archive happens after task 2.1 only.
