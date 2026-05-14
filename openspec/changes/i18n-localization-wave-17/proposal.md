## Why

Non-English users of the Tillandsias Forge face English-only prompts, help text, and error messages on first launch. Spanish and German translations exist but are incomplete; French and Japanese are stubs. Completing these locales improves UX for the international audience (40%+ of users in some regions) and enables the forge to deliver a welcoming, native-language experience from first login.

## What Changes

- **Shell Prompts**: Complete French (fr.sh) and Japanese (ja.sh) locale bundles with full translations of installation messages, warnings, banners, and rotating tips (98 strings total per language).
- **Help System**: Create `scripts/help.sh` (English baseline) and localized variants (`scripts/help-fr.sh`, `scripts/help-ja.sh`) wired to `TILLANDSIAS_LOCALE` environment variable.
- **Error Messages**: Add `images/default/lib-localized-errors.sh` with common error templates (container failed, image missing, network error) in 4 languages (Spanish, French, German, Japanese). Source from entrypoint so errors emit in user's native language.

## Capabilities

### New Capabilities

- `shell-prompt-localization-fr`: Full French locale bundle for forge-welcome.sh and entrypoint messages
- `shell-prompt-localization-ja`: Full Japanese locale bundle for forge-welcome.sh and entrypoint messages
- `help-system-localization`: Help command wired to TILLANDSIAS_LOCALE with Spanish, French, German, Japanese variants
- `error-message-localization`: Localized error message templates (container, image, network, git, auth failures) available to all entrypoints

### Modified Capabilities

- `forge-welcome`: Extend existing locale detection to ensure French and Japanese bundles load correctly (no schema change, just completeness)

## Impact

- **Code**: `images/default/locales/{fr.sh,ja.sh}`, new `scripts/help{,-fr,-de,-ja,-es}.sh`, new `images/default/lib-localized-errors.sh`
- **Entrypoints**: `images/default/entrypoint-*.sh` source `lib-localized-errors.sh` and emit localized errors
- **User-facing**: First-time experience in 4 languages; all prompts, tips, help, and common errors available in Spanish, French, German, Japanese
- **No breaking changes**. Existing English defaults are retained; French/Japanese are additive.
