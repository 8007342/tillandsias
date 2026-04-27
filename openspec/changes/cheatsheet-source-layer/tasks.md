# Tasks — cheatsheet-source-layer

## 1. Tooling (chunk 1) — DONE

- [x] 1.1 `scripts/fetch-cheatsheet-source.sh` — verbatim fetcher with allowlist, GitHub-blob rewrite, RFC text preference, single-page variants, idempotent --cite Provenance update.
- [x] 1.2 `scripts/regenerate-source-index.sh` + `--check` — walks sidecars, produces deterministic INDEX.json.
- [x] 1.3 `scripts/check-cheatsheet-sources.sh` — four-check validator (URL→INDEX, local-path-exists, orphan, SHA match). UNFETCHED warnings during migration; errors on missing files / SHA mismatch.
- [x] 1.4 `scripts/refresh-cheatsheet-sources.sh [--max-age-days N] [--dry-run]` — drift detection, marks sidecars staleness: drift|gone|current.
- [x] 1.5 `scripts/audit-cheatsheet-sources.sh` — CSV migration triage.
- [x] 1.6 `cheatsheet-sources/license-allowlist.toml` — initial allowlist (RFC, IETF, W3C, WHATWG, MDN, OWASP, kernel.org, Python, Rust, Ollama, plus AWS/Azure/GCP as do-not-bundle).
- [x] 1.7 `.gitignore` for `*.norepublish`; `.gitattributes` LFS rules for HTML/PDF.
- [x] 1.8 End-to-end verification: fetched RFC 6265, INDEX regenerated, validator passes.

Landed in commit 6d7f235.

## 2. Initial bulk fetch (chunk 2) — DONE (commit e858873)

- [x] 2.1 Run `scripts/audit-cheatsheet-sources.sh > /tmp/audit.csv` to triage all ~80 cheatsheets' Provenance URLs.
       185 total URLs, 47 allowlisted (46 unique), 138 off-allowlist.
- [x] 2.2 Bulk-fetch allowlisted-domain URLs: `scripts/fetch-cheatsheet-source.sh <URL>` for each (no `--cite` — just populate the verbatim layer).
       47 fetched. Fixed script bug: compute_dest_path() strip order (fragment before trailing slash).
- [x] 2.3 Off-allowlist URLs: surface for maintainer review — triage in /tmp/off-allowlist-triage.md.
       Top allowlist candidates: docs.podman.io, cmake.org, www.gnu.org, maven.apache.org, pnpm.io, playwright.dev, docs.gradle.org, git-scm.com.
       Do-not-bundle confirmed: docs.oracle.com, code.claude.com, opencode.ai.
- [x] 2.4 No 404s on initial fetch. One URL returned only 326-byte meta-refresh stub (owasp.org/Top10/) — chased redirect to real content at owasp.org/Top10/2025/.
- [x] 2.5 INDEX.json has 48 entries (47 new + 1 from chunk 1). Valid JSON.
- [x] 2.6 `cheatsheet-sources/ATTRIBUTION.md` generated (16 publishers, alphabetical).

## 3. Cheatsheet rewrite (chunk 3)

- [ ] 3.1 Add `local:` line to every cheatsheet's `## Provenance` section per the format in `cheatsheets/web/cookie-auth-best-practices.md` (already done by chunk 1's --cite test).
- [ ] 3.2 Add `last_verified` field if missing.
- [ ] 3.3 Bump `last_verified` only where the SHA matched maintainer expectation; flag drift cases as DRAFT.
- [ ] 3.4 Run `scripts/check-cheatsheet-sources.sh` — expect 0 warnings + 0 errors.

## 4. CI + INDEX.md verified-marker (chunk 4)

- [ ] 4.1 Wire `scripts/check-cheatsheet-sources.sh` into pre-commit alongside `scripts/regenerate-cheatsheet-index.sh --check`.
- [ ] 4.2 Wire into `openspec validate` extension.
- [ ] 4.3 Modify `scripts/regenerate-cheatsheet-index.sh` to append `[verified: <sha256-prefix>]` suffix to each line in `cheatsheets/INDEX.md` from the INDEX.json data.
- [ ] 4.4 Verify CI fails on a deliberately-introduced mismatch.

## 5. Spec change (chunk 5)

- [ ] 5.1 Write `openspec/changes/cheatsheet-source-layer/specs/cheatsheet-source-layer/spec.md` with the canonical Requirements (directory layout, manifest format, fetcher contract, license allowlist, validation invariants, hot/cold separation).
- [ ] 5.2 Write delta `openspec/changes/cheatsheet-source-layer/specs/agent-cheatsheets/spec.md` with the modification: Provenance MUST carry `local:` per cited URL.
- [ ] 5.3 Run `openspec validate cheatsheet-source-layer` — expect 0 warnings.
- [ ] 5.4 Archive: `openspec archive cheatsheet-source-layer -y`.
