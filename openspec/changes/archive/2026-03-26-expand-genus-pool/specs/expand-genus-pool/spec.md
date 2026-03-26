## CHANGED Requirements

### Requirement: Genus pool size
The genus pool SHALL contain at least 24 unique tillandsia species to support multiple concurrent environments per project without exhaustion.

#### Scenario: Pool has 24 genera
- **GIVEN** the `TillandsiaGenus::ALL` constant
- **THEN** it contains exactly 24 entries
- **AND** each entry has a unique slug, display name, and flower emoji

#### Scenario: Allocator supports 24 environments per project
- **GIVEN** a fresh `GenusAllocator`
- **WHEN** 24 environments are allocated for the same project
- **THEN** all 24 allocations succeed with distinct genera
- **AND** the 25th allocation returns `None`

### Requirement: Icon fallback for genera without SVG assets
Genera that do not have dedicated SVG icon assets SHALL fall back to the Ionantha genus icons at compile time.

#### Scenario: New genus icon resolution
- **GIVEN** a genus without a dedicated `assets/icons/<genus>/` directory
- **WHEN** `icon_svg()`, `icon_png()`, or `window_icon_png()` is called for that genus
- **THEN** the Ionantha icon bytes are returned for the requested lifecycle state

#### Scenario: Original genus icons unchanged
- **GIVEN** one of the original 8 genera with dedicated SVG assets
- **WHEN** `icon_svg()` is called
- **THEN** the genus-specific icon bytes are returned (not the Ionantha fallback)
