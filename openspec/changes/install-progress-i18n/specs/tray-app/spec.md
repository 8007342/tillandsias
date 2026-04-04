## MODIFIED Requirements

### Requirement: All menu labels use i18n
All user-visible menu labels in the tray application SHALL use `i18n::t()` for localization. No hardcoded English strings in menu construction.

#### Scenario: Remote Projects submenu label
- **WHEN** the tray menu is built with a non-English locale active
- **THEN** the "Remote Projects" submenu label displays in the active language

#### Scenario: Language switch updates all labels
- **WHEN** the user switches language via the Language submenu
- **THEN** all menu labels including "Remote Projects" update to the new language
