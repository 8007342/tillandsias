<!-- @trace spec:tray-minimal-ux -->

# Tray Minimal UX Cheatsheet

## Overview

Tillandsias uses a minimalistic tray UX that shows only essential elements at launch, then expands as the environment becomes ready.

## Launch State (4 Elements Only)

| Element | Description | Icon |
|---------|-------------|------|
| Status | Dynamic: Verifying → Building → OK/Unhealthy | ☐ → 🌐... → ✅/🌹 |
| Divider | Visual separator | ─ |
| Version | `Tillandsias vX.Y.Z` (disabled) | — |
| Quit | Always visible and enabled | — |

## Dynamic Status Progression

```
Initial:      ☐ Verifying environment...
Building:      🌐🌐... Building Network + Forge + Mirror...
Success:       ✅ Environment OK
Failure:       🌹 Unhealthy environment
```

Icons used:
- 🌐 = proxy (Network)
- 🔧 = forge  
- 🪞 = git (Mirror)
- 🧠 = inference
- 🌐 = chromium-core
- 🌐 = chromium-framework

## Post-Initialization Menu

Once `forge_available = true`:

| Item | Condition | Icon |
|------|-----------|------|
| `~/src >` Attach Here | Always shown (uses watch path) | 🏠 |
| `Root Terminal` | `forge_available` | 🛠️ |
| `Cloud >` Remote Projects | Authenticated AND remote repos exist | ☁️ |
| `GitHub login` | NOT authenticated | 🔑 |
| Projects ▸ | Inactive projects exist | — |
| Settings ▸ | Always shown | ⚙️ |

## Implementation Files

- `src-tauri/src/menu.rs`:
  - `build_tray_menu()` - Main menu builder with minimal UX check
  - `build_minimal_menu()` - 4-element launch menu
  - `environment_status_label()` - Dynamic status text

## Trace Links

- Spec: `openspec/specs/tray-ux/spec.md`
- GitHub search: https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Atray-minimal-ux&type=code
