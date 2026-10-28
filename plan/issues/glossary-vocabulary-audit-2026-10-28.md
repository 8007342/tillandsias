# Vocabulary audit, 2026-10-28 (1908-9q4c)

Corpus: methodology.yaml, methodology/, openspec/specs/, skills/ (*.md, *.yaml).
Counts: `/usr/bin/grep -rowiE "term(s|ed|ing)?"` over the corpus; per-sense
figures are collocation tallies (lower bounds), citations are first hits, not
a complete list. The canonical result is methodology/glossary.yaml.

Before this audit there was no glossary. The one naming ruling was 851-gpb5
(skills/meta-orchestration/SKILL.md:2461: "local gate" = ./build.sh --check,
"pre-push gate" = pull_merge_cadence.pre_push_gate). methodology/litmus.yaml:162
has a caveat_glossary for litmus caveats only.

Rule applied on top (coordinator, 2026-10-28): where the operator uses a word,
the operator's sense wins over the ledger's.

## Senses found

| Term | Uses | Senses (citation) | Canonical |
|---|---|---|---|
| lane | 578 | push path (methodology/multi-host-development.yaml:396, methodology/distributed-work.yaml:1895); forge session/launch mode (openspec/specs/default-image/spec.md:268, openspec/changes/web-studio-lanes); compute backend (openspec/specs/inference-container/spec.md:156); storage pattern (openspec/specs/forge-hot-cold-split/spec.md:215); platform team (skills/build-windows-tray/SKILL.md:67); review track (methodology/versioning.yaml:224) | launch/reach path of a forge runtime (operator sense, web-studio-lanes and 1874-4b88); push path becomes "push route" |
| tier | 324 | role (methodology.yaml:60); inference model/hardware (openspec/specs/inference-container/spec.md:153); CI depth (methodology/convergence.yaml:90); HOT/COLD (openspec/specs/forge-hot-cold-split/spec.md:10); log (openspec/specs/external-logs-layer/spec.md:13) | host tier and model tier (operator sense: "floor tier", "one tier larger") |
| packet / order / row | 517 / 893 / 354 | one ledger entry under three names (methodology.yaml:14, :312; methodology/convergence.yaml:597); order also = sequence (methodology/between-commits-work-discipline.yaml:209) and ruling (methodology.yaml:329); row also = table row (openspec/specs/versioning/spec.md:70) | packet; order id = identifier; row = table row |
| gate | 615 | local gate (methodology/ci.yaml:317); pre-push rule (skills/meta-orchestration/SKILL.md:676); release/CI gate (methodology/convergence.yaml:825); land gate (methodology/ci.yaml:361); auth (openspec/specs/browser-isolation-tray-integration/spec.md:113); approval (methodology/forge-diagnostics.yaml:61); verb (methodology.yaml:554) | qualified pass/fail check |
| stamp | 123 | gate stamp (methodology/multi-host-development.yaml:278); build stamp, same marker (methodology/multi-host-development.yaml:989); cert freshness (methodology.yaml:570) | gate stamp |
| claim | 593 | lease (methodology/distributed-work.yaml:2128); assertion (methodology/provenance.yaml:131) | lease |
| land / relay / cut | 432 / 212 / 94 | land = integrate (methodology/verification.yaml:518) and the tool (methodology/convergence.yaml:92); relay = coordinator forward (methodology/ci.yaml:338) and mirror pre-receive (openspec/specs/git-mirror-service/spec.md:12); cut = promotion (methodology/ci.yaml:339), cut host = land-queue host (skills/merge-to-main-and-release/SKILL.md:267), cutover (openspec/specs/versioning/spec.md:38) | land into trunk; relay = coordinator forward; cut = trunk to main |
| trunk | 135 | linux-next (methodology/verification.yaml:517) vs main (skills/meta-orchestration/SKILL.md:2458) | linux-next |
| regime | 60 | guest context (openspec/specs/tillandsias-vault/spec.md:42); policy scope (openspec/specs/command-policies/spec.md:112); launch mode (skills/build-macos-tray/SKILL.md:116) | guest context |
| arm / fixture | 149 / 135 | test branch (methodology/arm-blindness.yaml:35) vs enable verb (methodology/multi-host-development.yaml:1410); test harness (methodology/multi-host-development.yaml:650) vs check class (methodology/ci.yaml:354) | test senses |

Runners-up, folded into the glossary with one meaning each: host, fragment,
mirror (verb), litmus (test vs chain), cycle (vs session/run/loop), forge,
enclave, decider, epic.
