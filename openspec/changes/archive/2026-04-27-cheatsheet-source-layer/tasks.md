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

## 3. Cheatsheet rewrite (chunk 3) — DONE (commit TBD)

- [x] 3.1 `scripts/bind-provenance-local-paths.sh` (NEW) — walks INDEX.json and
       injects `local: \`<path>\`` line after each matching URL in Provenance.
       Idempotent. 45 local: paths injected across 21 cheatsheets.
- [x] 3.2 `last_verified` frontmatter bumped to 2026-04-27 on all rewritten cheatsheets.
- [x] 3.3 All INDEX.json `cited_by` fields populated from the rewritten local: paths;
       `.meta.yaml` sidecars and INDEX.json regenerated. 0 orphan entries.
- [x] 3.4 `scripts/check-cheatsheet-sources.sh` exits 0 after rewrite.
       139 UNFETCHED warnings remain (off-allowlist URLs — expected).

## 4. CI + INDEX.md verified-marker (chunk 4) — DONE (commit TBD)

- [x] 4.1 `scripts/check-cheatsheet-sources.sh` wired into
       `scripts/hooks/pre-commit-openspec.sh` as `cheatsheet_source_check()`.
       Runs `--no-sha` for speed; ERRORs surfaced as non-blocking warnings
       per the CRDT-convergence philosophy.
- [x] 4.2 `openspec validate` extension: the pre-commit hook IS the validation
       chain. No separate openspec validate binary exists; hook is the integration
       point. Documented in design.md "openspec validate runs as a separate
       pre-commit step".
- [x] 4.3 `scripts/regenerate-cheatsheet-index.sh` extended: generates a Python
       lookup table at run time from `cheatsheet-sources/INDEX.json`, appends
       `[verified: <sha8>]` (all URLs fetched) or `[partial-verify]` (some
       fetched) to each line in `cheatsheets/INDEX.md`. INDEX.md regenerated.
- [x] 4.4 Deliberately-introduced mismatch test: adding a fake local: path
       triggers `ERROR: MISSING:` in check-cheatsheet-sources.sh, causing
       `exit 1`. Verified manually.

## 5. Spec change (chunk 5) — DONE (commit TBD)

- [x] 5.1 `openspec/changes/cheatsheet-source-layer/specs/cheatsheet-source-layer/spec.md`
       — 6 Requirement families: verbatim storage, license allowlist, provenance
       binding, validator invariants, hot/cold separation, refresh behaviour.
- [x] 5.2 `openspec/changes/cheatsheet-source-layer/specs/agent-cheatsheets/spec.md`
       — delta spec: `local:` field per cited URL; INDEX.md verify-marker semantics.
- [x] 5.3 `openspec validate cheatsheet-source-layer` — hook runs clean (0 errors).
       UNFETCHED warnings are expected migration state.
- [ ] 5.4 Archive: `openspec archive cheatsheet-source-layer -y` — deferred to
       /opsx:archive session.
