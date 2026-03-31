## ADDED Requirements

### Requirement: Tray icon canvas utilization
All genus/state SVG icons SHALL fill 70-85% of the 64x64 viewBox, centered vertically and horizontally.

#### Scenario: Plant centered in canvas
- **GIVEN** any genus/state SVG icon
- **WHEN** the icon is rendered at 32x32 pixels
- **THEN** the plant graphic is visually centered in the canvas with roughly equal padding on all sides

#### Scenario: Pup state visible
- **GIVEN** a pup-state SVG icon for any genus
- **WHEN** rendered at 22px (minimum tray size)
- **THEN** the plant is clearly visible as a distinct shape, not just a few pixels

### Requirement: Stroke visibility at small sizes
All strokes SHALL be at minimum 1.5px wide so they remain visible when rendered at 22-32px.

#### Scenario: Stroke width at minimum tray size
- **GIVEN** any genus/state SVG icon with outlined shapes
- **WHEN** rendered at 22px
- **THEN** stroke outlines are visible and contribute to shape recognition

### Requirement: Color contrast on dark backgrounds
Green fills SHALL use brightened values (#7ec87e or lighter) to maintain contrast against dark system tray backgrounds (typical on Linux and macOS).

#### Scenario: Dark panel visibility
- **GIVEN** a bud-state SVG icon with green fills
- **WHEN** displayed against a #2d2d2d or darker panel background
- **THEN** the plant shape is clearly distinguishable from the background

#### Scenario: Light panel visibility
- **GIVEN** any genus/state SVG icon
- **WHEN** displayed against a #f0f0f0 or lighter panel background
- **THEN** the plant shape remains distinguishable (not washed out)
