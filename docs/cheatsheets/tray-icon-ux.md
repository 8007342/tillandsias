---
tags: [tray, ux, icons, tauri, design]
languages: [rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://tauri.app/learn/system-tray/
authority: high
status: current
---

# Tray Icon UX Guidelines

## Design Principles

- **Minimalistic**: A single plant silhouette, no text, no badges, no counters
- **Informative**: The plant's lifecycle state communicates environment status at a glance
- **Non-intrusive**: The icon blends into the system tray without demanding attention
- **Universal**: Must be recognizable on Linux (GNOME, KDE, XFCE), macOS, and Windows tray bars

## Color Contrast Requirements

### Dark tray backgrounds (most Linux DEs, macOS dark mode)

Background range: #1a1a1a to #3d3d3d

| State | Primary fill | Minimum contrast ratio |
|-------|-------------|----------------------|
| Bud (green) | #7ec87e or brighter | 3:1 against #2d2d2d |
| Bloom (green + accent) | #6ab86a base + vivid pink/purple/red | Accent color provides contrast |
| Dried (brown) | #b09968 or brighter | 3:1 against #2d2d2d |
| Pup (light green) | #a0dda0 | Already high contrast |

### Light tray backgrounds (macOS light mode, some KDE themes)

Background range: #e0e0e0 to #ffffff

- Green fills (#7ec87e) remain visible against white due to saturation
- Stroke outlines (#4a8a4a dark green, #98804c dark brown) provide edge definition
- Pup light greens (#a0dda0, #b0eeb0) are the lowest contrast on light -- acceptable because pup state is transient

### Colors to AVOID

- Pure greens below #6aad6a (disappear on dark panels)
- Greys or desaturated colors (blend into any panel)
- Pure white fills (invisible on light panels, too harsh on dark)

## Size Guidelines

| Principle | Target |
|-----------|--------|
| Canvas utilization | 70-85% of the 64x64 viewBox |
| Vertical centering | Plant centered with ~equal padding top and bottom |
| Minimum stroke width | 1.5px (visible when rendered at 22px) |
| No fine details | Anything smaller than 2px at 64x64 disappears at 22px render |
| Render size range | 22px (XFCE/i3) to 32px (GNOME/macOS) |

### Scale factors by state

Smaller plants (pup) get a higher scale factor to compensate for fewer elements:

| State | Typical scale | Rationale |
|-------|--------------|-----------|
| Bloom | 1.3x | Already has flower spike extending upward |
| Bud | 1.4x | Medium-sized, needs moderate enlargement |
| Dried | 1.4x | Same geometry as bud, same scale |
| Pup | 1.7-1.8x | Smallest form, needs the most enlargement |

## Plant Lifecycle State Meanings

The icon tells a story about the development environment's status:

| State | Plant form | Environment meaning | Visual cue |
|-------|-----------|---------------------|------------|
| **Pup** | Tiny sprout, light green | Creating / launching | Small, bright, fresh |
| **Bud** | Full leaves, medium green | Ready / idle | Healthy, waiting |
| **Bloom** | Leaves + flower | Active / in use | Colorful accent (pink, purple, red) |
| **Dried** | Brown/faded leaves | Stopped / error | Muted, earthy tones |

The narrative: growing (launching) -> mature (ready) -> flowering (activity) -> withered (error/stopped).

## What NOT to Show

- **No text**: Tray icons are too small for readable text
- **No badges**: No notification dots, counters, or overlays
- **No technical indicators**: No gear icons, terminal prompts, or container symbols
- **No animation**: System trays have inconsistent animation support
- **No gradients**: Flat fills render more reliably across platforms and sizes
- **No transparency tricks**: Some tray implementations composite poorly with alpha

## Genus Differentiation

Each genus has a distinctive silhouette that remains recognizable at small sizes:

| Genus | Silhouette | Key visual feature |
|-------|-----------|-------------------|
| Ionantha | Pointed polygon rosette | Sharp triangular leaves |
| Aeranthos | Smooth ellipse rosette | Rounded overlapping leaves |
| Bulbosa | Round base + curving tentacles | Bulbous bottom, wavy top |
| Caput-Medusae | Bulb + sprawling tentacles | Wide Medusa-like tendrils |
| Stricta | Tall pointed polygons | Upright, stiff, vase-shaped |
| Tectorum | Circle with spikes | Fuzzy ball with trichomes |
| Usneoides | Hanging strands from bar | Only genus that hangs downward |
| Xerographica | Wide curling arcs | Sweeping spiral curves |

## Provenance

- https://tauri.app/learn/system-tray/ — Tauri system tray guide; TrayIcon and TrayIconBuilder API, icon customization, menu integration via `menu` option, tray events (Click, DoubleClick, Enter, Move, Leave), `features = ["tray-icon"]` requirement
- **Last updated:** 2026-04-27
