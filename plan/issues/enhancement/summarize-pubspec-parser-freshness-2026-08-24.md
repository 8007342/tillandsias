# summarize-pubspec parser freshness — 2026-08-24

Disposition: **updated**.

The standing freshness draw selected `scripts/summarize-pubspec.sh`. It remains
live and useful as one of the six manifest summarizers consumed by README
generation, so deletion would remove Dart/Flutter project orientation.

The pre-update script was not sound on a normal manifest: single-quoted Dart
constraints and double-quoted Flutter constraints rendered as empty strings,
and a raw indentation grep counted nested `sdk:` keys, environment keys, and
Flutter configuration as dependencies (8 reported for 5 direct entries). Raw
substring scans could also report `provider_tools` as Provider.

The update parses only direct keys under `environment`, `dependencies`, and
`dev_dependencies`; preserves either quote style; reports an absent SDK
constraint as unspecified instead of inventing a version; and matches framework
names exactly. `scripts/test-summarize-pubspec.sh` pins Flutter, Dart-only,
determinism, false-positive, and missing-manifest behavior and is bound into
`litmus:project-summarizers-shape`.

The sibling active spec still describes obsolete script names, paths, JSON
output, and missing-manifest semantics. That existing independently schedulable
contract drift remains owned by order `815-yace`; this audit does not silently
rewrite it.
