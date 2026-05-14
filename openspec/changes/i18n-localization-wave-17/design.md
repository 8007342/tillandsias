## Context

Tillandsias Forge already has a locale detection system in place:
- Locale files live at `/etc/tillandsias/locales/{en,es,de,fr,ja,ko,ru,...}.sh`
- Detection via `forge-welcome.sh` reads `LC_ALL`, `LC_MESSAGES`, or `LANG` and sources the matching file
- Spanish (es.sh) and German (de.sh) are complete with 98 localized strings each
- French (fr.sh) and Japanese (ja.sh) are stubs that source English and override nothing
- Error handling and help system currently have no localization layer

### Current Gaps

1. **French & Japanese Shell Prompts**: Only stubs; need full 98-string translations
2. **Help System**: No `--help` flag support; no localized variants
3. **Error Messages**: Hardcoded in entrypoints; no templates or localization

## Goals / Non-Goals

**Goals:**
- Complete French and Japanese locale bundles (98 strings each) matching existing Spanish/German structure
- Create help system with Spanish, French, German, Japanese variants
- Provide localized error message templates for common failures (container, image, network, git, auth)
- All changes integrate seamlessly into existing locale detection (no new env vars or complexity)
- Improve first-time UX for non-English speakers across all three surface areas

**Non-Goals:**
- Add new languages beyond Spanish, French, German, Japanese
- Change locale detection mechanism (LC_ALL/LC_MESSAGES already working)
- Localize cheatsheets (separate capability)
- Add runtime switching of locale (env var at startup is sufficient)

## Decisions

### Decision 1: Locale File Format & Structure
**Choice**: Keep existing format — bash source-able files with `L_<NAME>` prefixed variables.
**Rationale**: Already proven with Spanish/German; integrates cleanly with existing detection in `forge-welcome.sh`. No new tooling or parsing needed.
**Alternatives Considered**:
- JSON locale files → Adds jq/parsing dependency, breaks seamless sourcing pattern
- YAML → Same jq burden; less shell-friendly
- Gettext .po files → Over-engineered for our 4-language, <200-string scope

### Decision 2: Help System Implementation
**Choice**: Create `scripts/help.sh` (main) and `scripts/help-{es,fr,de,ja}.sh` (localized). Wire via `TILLANDSIAS_LOCALE` env var (optional; defaults to English if unset).
**Rationale**: Mirrors locale file approach; minimal integration; optional fallback to English is safe.
**Where to invoke**: `--help` flag in entrypoint-terminal.sh, accessible from within forge
**Alternatives Considered**:
- Single `help.sh` with embedded locale detection → More complex parsing; less testable
- man pages → Overkill; offline-only; hard to maintain in 4 languages

### Decision 3: Error Message Strategy
**Choice**: Create `lib-localized-errors.sh` with error template functions (e.g., `error_container_failed()`, `error_image_missing()`). Entrypoints source this and call functions instead of echo hardcoded strings.
**Rationale**: 
- Centralizes error messages (single source of truth)
- Templates ensure consistent tone across languages
- Entrypoint code stays clean (call functions, not echo 20 lines)
- Reusable across all entrypoints
**Alternatives Considered**:
- Inline locale vars in each entrypoint → Scattered, unmaintainable
- Runtime locale detection per error → Too expensive; should be done once at startup

### Decision 4: French & Japanese Translation Approach
**Choice**: Use human translations (where available from existing translation communities) or high-quality LLM translations validated against native speakers.
**Rationale**: Ensures quality for user-facing text. Spanish/German are already high quality; matching that standard is non-negotiable.
**Notes**: 
- Spanish and German translations were done by native speakers
- French and Japanese translations should follow the same quality bar
- All translations should respect terminology (e.g., "Tillandsias Forge" stays as-is in all languages)

### Decision 5: Testing & Validation
**Choice**: Create shell syntax check test and locale variable coverage test (verify all 98 L_* vars are defined in each locale file).
**Rationale**: Catches obvious errors (typos, missing variables) without needing live container testing.
**Coverage Metric**: All L_* vars in en.sh must exist in es.sh, de.sh, fr.sh, ja.sh (test will verify this)

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| **Translation Quality**: French/Japanese translations don't match tone/intent of Spanish/German | Validate against native speaker feedback; use glossary terms from existing translations |
| **Incompleteness**: Env vars added to en.sh but not backported to fr.sh/ja.sh | Automated test: verify all `L_*` vars in en.sh are defined in fr.sh, ja.sh |
| **RTL Languages**: Japanese and future RTL support not anticipated | Out of scope; Japanese LTR. Note as future capability if needed |
| **Encoding Issues**: Non-ASCII characters in bash files might not source correctly | Use UTF-8 encoding; test with `source` in both bash/fish |
| **Help System Discoverability**: Users might not find `--help` | Wire into welcome banner; include in tips |

## Migration Plan

1. **Phase 1 — Complete Locale Bundles**: Add fr.sh, ja.sh full translations; verify shell syntax and variable coverage via test
2. **Phase 2 — Help System**: Create help.sh and variants; wire `--help` into entrypoint
3. **Phase 3 — Error Messages**: Create lib-localized-errors.sh; refactor entrypoints to call functions instead of inline echo
4. **Phase 4 — Testing & Validation**: Run automated checks; manual smoke test in French/Japanese locale
5. **Phase 5 — Documentation**: Update CLAUDE.md with locale file structure and help system usage

**Rollback**: All changes are additive. Removing them is as simple as deleting the new files and reverting entrypoint sourcing calls.

## Open Questions

1. Are there existing French/Japanese translations elsewhere in the codebase or docs that should be referenced for consistency?
2. Should the help system be baked into the image or dynamically sourced?
3. Should common error messages also be added to the welcome banner tips?
