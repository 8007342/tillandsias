//! Build-time rendered PNG icons for all genus/lifecycle combinations.
//!
//! The PNGs are rendered from SVG sources by `build.rs` using `resvg` + `tiny-skia`
//! and embedded into the binary via `include_bytes!`. No runtime filesystem I/O is
//! used to load icons.
//!
//! This module provides:
//! - [`tray_icon_png`] — tray icon by system state (32x32)
//! - [`icon_png`] — per-genus, per-lifecycle icon (32x32)
//! - [`window_icon_png`] — per-genus, per-lifecycle window icon (48x48)

// Pull in the generated constants and functions from build.rs.
// The generated code uses fully qualified paths (crate::genus::*) so no
// imports are needed at this level.
include!(concat!(env!("OUT_DIR"), "/icons_generated.rs"));

#[cfg(test)]
mod tests {
    use super::*;
    use crate::genus::{PlantLifecycle, TillandsiaGenus, TrayIconState};

    /// PNG magic bytes: `\x89PNG\r\n\x1a\n`
    const PNG_MAGIC: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    #[test]
    fn tray_icon_base_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Base);
        assert!(!bytes.is_empty(), "Base tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Base tray icon missing PNG magic bytes"
        );
    }

    #[test]
    fn tray_icon_building_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Building);
        assert!(!bytes.is_empty(), "Building tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Building tray icon missing PNG magic bytes"
        );
    }

    #[test]
    fn tray_icon_decay_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Decay);
        assert!(!bytes.is_empty(), "Decay tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Decay tray icon missing PNG magic bytes"
        );
    }

    #[test]
    fn all_32_icon_png_combinations_valid() {
        let lifecycles = [
            PlantLifecycle::Bud,
            PlantLifecycle::Bloom,
            PlantLifecycle::Dried,
            PlantLifecycle::Pup,
        ];

        for genus in TillandsiaGenus::ALL {
            for lifecycle in &lifecycles {
                let bytes = icon_png(*genus, *lifecycle);
                assert!(
                    !bytes.is_empty(),
                    "32x32 PNG for {:?}/{:?} is empty",
                    genus,
                    lifecycle
                );
                assert!(
                    bytes.starts_with(PNG_MAGIC),
                    "32x32 PNG for {:?}/{:?} missing PNG magic bytes",
                    genus,
                    lifecycle
                );
            }
        }
    }

    #[test]
    fn all_32_window_icon_png_combinations_valid() {
        let lifecycles = [
            PlantLifecycle::Bud,
            PlantLifecycle::Bloom,
            PlantLifecycle::Dried,
            PlantLifecycle::Pup,
        ];

        for genus in TillandsiaGenus::ALL {
            for lifecycle in &lifecycles {
                let bytes = window_icon_png(*genus, *lifecycle);
                assert!(
                    !bytes.is_empty(),
                    "48x48 PNG for {:?}/{:?} is empty",
                    genus,
                    lifecycle
                );
                assert!(
                    bytes.starts_with(PNG_MAGIC),
                    "48x48 PNG for {:?}/{:?} missing PNG magic bytes",
                    genus,
                    lifecycle
                );
            }
        }
    }
}
