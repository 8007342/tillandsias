## ADDED Requirements

### Requirement: Text-friendly sources are curated in one catalog

The proxy SHALL generate its `reading` tier from a versioned catalog. Each
catalog entry SHALL name its URL, its kind, its refresh interval, its licence
and its provenance. Adding a catalog entry SHALL NOT remove any existing
allowlist line.

#### Scenario: A feed reaches an agent

- **WHEN** a forge agent requests a feed listed in the catalog
- **THEN** the proxy admits it, and serves a cached copy within the feed's refresh interval

#### Scenario: Nothing is narrowed

- **WHEN** the allowlist is regenerated with the reading tier
- **THEN** every host in the previous allowlist is still present

### Requirement: The proxy caches by kind

The proxy SHALL cache immutable artifacts and RFC text for a long time, docs
for hours and feeds for minutes. Its existing release-asset and query-string
rules SHALL still match first.

#### Scenario: An immutable crate file is served from cache

- **WHEN** a crate file from static.crates.io is requested a second time within a week
- **THEN** squid serves it from cache, without revalidating it

### Requirement: New sources are proposed, never auto-allowed

A probe SHALL report whether a docs host serves llms.txt or Markdown. A host
SHALL enter the catalog only through operator approval.

#### Scenario: A host with llms.txt is proposed

- **WHEN** the probe finds Markdown at a host's /llms.txt
- **THEN** it answers `propose:<host>:llms-txt` and changes no file
