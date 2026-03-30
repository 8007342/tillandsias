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
    fn tray_icon_pup_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Pup);
        assert!(!bytes.is_empty(), "Pup tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Pup tray icon missing PNG magic bytes"
        );
    }

    #[test]
    fn tray_icon_mature_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Mature);
        assert!(!bytes.is_empty(), "Mature tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Mature tray icon missing PNG magic bytes"
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
    fn tray_icon_blooming_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Blooming);
        assert!(!bytes.is_empty(), "Blooming tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Blooming tray icon missing PNG magic bytes"
        );
    }

    #[test]
    fn tray_icon_dried_is_valid_png() {
        let bytes = tray_icon_png(TrayIconState::Dried);
        assert!(!bytes.is_empty(), "Dried tray icon is empty");
        assert!(
            bytes.starts_with(PNG_MAGIC),
            "Dried tray icon missing PNG magic bytes"
        );
    }

    #[test]
    fn all_five_tray_icon_states_valid() {
        let states = [
            TrayIconState::Pup,
            TrayIconState::Mature,
            TrayIconState::Building,
            TrayIconState::Blooming,
            TrayIconState::Dried,
        ];
        for state in &states {
            let bytes = tray_icon_png(*state);
            assert!(
                !bytes.is_empty(),
                "Tray icon for {:?} is empty",
                state
            );
            assert!(
                bytes.starts_with(PNG_MAGIC),
                "Tray icon for {:?} missing PNG magic bytes",
                state
            );
        }
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
