//! Build-time SVG->PNG rendering pipeline.
//!
//! Uses `resvg` + `tiny-skia` (pure Rust, no system deps) to render all
//! genus/lifecycle SVG icons into PNGs at compile time. Generated PNGs
//! are placed in `OUT_DIR` and embedded via `include_bytes!` in the
//! generated `icons_generated.rs` source file.
//!
//! Genera without dedicated SVG assets fall back to Ionantha icons.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// All 24 genera slugs. Order matches `TillandsiaGenus::ALL`.
const GENERA: &[&str] = &[
    "aeranthos",
    "ionantha",
    "xerographica",
    "caput-medusae",
    "bulbosa",
    "tectorum",
    "stricta",
    "usneoides",
    // 16 new genera — no dedicated SVGs, fall back to ionantha
    "cyanea",
    "funckiana",
    "magnusiana",
    "bergeri",
    "brachycaulos",
    "harrisii",
    "duratii",
    "gardneri",
    "seleriana",
    "fasciculata",
    "leiboldiana",
    "flabellata",
    "paleacea",
    "recurvata",
    "kolbii",
    "pruinosa",
];

/// Fallback genus for genera without dedicated SVG assets.
const FALLBACK_GENUS: &str = "ionantha";

const LIFECYCLES: &[&str] = &["bud", "bloom", "dried", "pup"];

/// Tray icon mappings: (tray_state_name, genus, lifecycle)
const TRAY_ICONS: &[(&str, &str, &str)] = &[
    ("base", "ionantha", "bud"),
    ("building", "ionantha", "bloom"),
    ("decay", "ionantha", "dried"),
];

fn main() {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let assets_dir = manifest_dir.join("../../assets/icons");

    // Tell cargo to re-run if any SVG changes
    println!("cargo:rerun-if-changed=../../assets/icons");
    for genus in GENERA {
        let genus_dir = assets_dir.join(genus);
        if genus_dir.is_dir() {
            for lifecycle in LIFECYCLES {
                let svg_path = genus_dir.join(format!("{lifecycle}.svg"));
                println!("cargo:rerun-if-changed={}", svg_path.display());
            }
        }
    }

    // Create output directories
    let icons_dir = out_dir.join("icons");
    let tray_dir = icons_dir.join("tray");
    let window_dir = icons_dir.join("window");
    fs::create_dir_all(&tray_dir).unwrap();
    fs::create_dir_all(&window_dir).unwrap();

    // Render all genus/lifecycle combinations at 32x32
    // For genera without SVG assets, use the fallback genus (ionantha)
    for genus in GENERA {
        let genus_out_dir = icons_dir.join(genus);
        fs::create_dir_all(&genus_out_dir).unwrap();

        let source_genus = if assets_dir.join(genus).is_dir() {
            genus
        } else {
            FALLBACK_GENUS
        };

        for lifecycle in LIFECYCLES {
            let svg_path = assets_dir.join(source_genus).join(format!("{lifecycle}.svg"));
            let png_path = genus_out_dir.join(format!("{lifecycle}.png"));
            render_svg_to_png(&svg_path, &png_path, 32, 32);
        }
    }

    // Render 3 tray icon variants at 32x32
    for (tray_name, genus, lifecycle) in TRAY_ICONS {
        let svg_path = assets_dir.join(genus).join(format!("{lifecycle}.svg"));
        let png_path = tray_dir.join(format!("{tray_name}.png"));
        render_svg_to_png(&svg_path, &png_path, 32, 32);
    }

    // Render per-genus, per-lifecycle window icons at 48x48
    for genus in GENERA {
        let genus_window_dir = window_dir.join(genus);
        fs::create_dir_all(&genus_window_dir).unwrap();

        let source_genus = if assets_dir.join(genus).is_dir() {
            genus
        } else {
            FALLBACK_GENUS
        };

        for lifecycle in LIFECYCLES {
            let svg_path = assets_dir.join(source_genus).join(format!("{lifecycle}.svg"));
            let png_path = genus_window_dir.join(format!("{lifecycle}@48.png"));
            render_svg_to_png(&svg_path, &png_path, 48, 48);
        }
    }

    // Generate Rust source with include_bytes! references
    generate_icons_rs(&out_dir);
}

/// Render an SVG file to a PNG file at the specified dimensions.
fn render_svg_to_png(svg_path: &Path, png_path: &Path, width: u32, height: u32) {
    let svg_data = fs::read(svg_path)
        .unwrap_or_else(|e| panic!("Failed to read SVG {}: {}", svg_path.display(), e));

    let tree = resvg::usvg::Tree::from_data(&svg_data, &resvg::usvg::Options::default())
        .unwrap_or_else(|e| panic!("Failed to parse SVG {}: {}", svg_path.display(), e));

    let mut pixmap = tiny_skia::Pixmap::new(width, height)
        .unwrap_or_else(|| panic!("Failed to create {}x{} pixmap", width, height));

    // Scale SVG to fit the target dimensions
    let svg_size = tree.size();
    let scale_x = width as f32 / svg_size.width();
    let scale_y = height as f32 / svg_size.height();
    let transform = tiny_skia::Transform::from_scale(scale_x, scale_y);

    resvg::render(&tree, transform, &mut pixmap.as_mut());

    let png_data = pixmap.encode_png().unwrap_or_else(|e| {
        panic!(
            "Failed to encode PNG for {}: {}",
            svg_path.display(),
            e
        )
    });

    fs::write(png_path, &png_data).unwrap_or_else(|e| {
        panic!(
            "Failed to write PNG {}: {}",
            png_path.display(),
            e
        )
    });
}

/// Generate `icons_generated.rs` with `include_bytes!` references to all rendered PNGs.
fn generate_icons_rs(out_dir: &Path) {
    let gen_path = out_dir.join("icons_generated.rs");
    let mut f = fs::File::create(&gen_path).unwrap();

    // --- 32x32 genus/lifecycle icons ---
    writeln!(f, "// Auto-generated by build.rs — do not edit").unwrap();
    writeln!(f).unwrap();

    // Generate constants for 32x32 icons
    for genus in GENERA {
        for lifecycle in LIFECYCLES {
            let const_name = format!(
                "PNG_{}_{}",
                genus.to_uppercase().replace('-', "_"),
                lifecycle.to_uppercase()
            );
            let rel_path = format!("icons/{genus}/{lifecycle}.png");
            writeln!(
                f,
                r#"const {const_name}: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/{rel_path}"));"#,
            )
            .unwrap();
        }
        writeln!(f).unwrap();
    }

    // Generate constants for tray icons
    writeln!(f, "// Tray icon variants (32x32, Ionantha genus)").unwrap();
    for (tray_name, _, _) in TRAY_ICONS {
        let const_name = format!("PNG_TRAY_{}", tray_name.to_uppercase());
        let rel_path = format!("icons/tray/{tray_name}.png");
        writeln!(
            f,
            r#"const {const_name}: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/{rel_path}"));"#,
        )
        .unwrap();
    }
    writeln!(f).unwrap();

    // Generate constants for 48x48 window icons
    writeln!(f, "// Window icon variants (48x48)").unwrap();
    for genus in GENERA {
        for lifecycle in LIFECYCLES {
            let const_name = format!(
                "PNG_WINDOW_{}_{}",
                genus.to_uppercase().replace('-', "_"),
                lifecycle.to_uppercase()
            );
            let rel_path = format!("icons/window/{genus}/{lifecycle}@48.png");
            writeln!(
                f,
                r#"const {const_name}: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/{rel_path}"));"#,
            )
            .unwrap();
        }
        writeln!(f).unwrap();
    }

    // Generate tray_icon_png function
    writeln!(f, r#"/// Return the PNG bytes for a tray icon state (32x32)."#).unwrap();
    writeln!(
        f,
        "pub fn tray_icon_png(state: crate::genus::TrayIconState) -> &'static [u8] {{"
    )
    .unwrap();
    writeln!(f, "    match state {{").unwrap();
    writeln!(f, "        crate::genus::TrayIconState::Base => PNG_TRAY_BASE,").unwrap();
    writeln!(f, "        crate::genus::TrayIconState::Building => PNG_TRAY_BUILDING,").unwrap();
    writeln!(f, "        crate::genus::TrayIconState::Decay => PNG_TRAY_DECAY,").unwrap();
    writeln!(f, "    }}").unwrap();
    writeln!(f, "}}").unwrap();
    writeln!(f).unwrap();

    // Generate icon_png function (32x32)
    writeln!(
        f,
        r#"/// Return the PNG bytes for a genus/lifecycle icon (32x32)."#
    )
    .unwrap();
    writeln!(
        f,
        "pub fn icon_png(genus: crate::genus::TillandsiaGenus, lifecycle: crate::genus::PlantLifecycle) -> &'static [u8] {{"
    )
    .unwrap();
    writeln!(f, "    match (genus, lifecycle) {{").unwrap();
    for genus in GENERA {
        let genus_variant = genus_to_variant(genus);
        for lifecycle in LIFECYCLES {
            let lifecycle_variant = lifecycle_to_variant(lifecycle);
            let const_name = format!(
                "PNG_{}_{}",
                genus.to_uppercase().replace('-', "_"),
                lifecycle.to_uppercase()
            );
            writeln!(
                f,
                "        (crate::genus::TillandsiaGenus::{genus_variant}, crate::genus::PlantLifecycle::{lifecycle_variant}) => {const_name},"
            )
            .unwrap();
        }
    }
    writeln!(f, "    }}").unwrap();
    writeln!(f, "}}").unwrap();
    writeln!(f).unwrap();

    // Generate window_icon_png function (48x48)
    writeln!(
        f,
        r#"/// Return the PNG bytes for a genus/lifecycle window icon (48x48)."#
    )
    .unwrap();
    writeln!(
        f,
        "pub fn window_icon_png(genus: crate::genus::TillandsiaGenus, lifecycle: crate::genus::PlantLifecycle) -> &'static [u8] {{"
    )
    .unwrap();
    writeln!(f, "    match (genus, lifecycle) {{").unwrap();
    for genus in GENERA {
        let genus_variant = genus_to_variant(genus);
        for lifecycle in LIFECYCLES {
            let lifecycle_variant = lifecycle_to_variant(lifecycle);
            let const_name = format!(
                "PNG_WINDOW_{}_{}",
                genus.to_uppercase().replace('-', "_"),
                lifecycle.to_uppercase()
            );
            writeln!(
                f,
                "        (crate::genus::TillandsiaGenus::{genus_variant}, crate::genus::PlantLifecycle::{lifecycle_variant}) => {const_name},"
            )
            .unwrap();
        }
    }
    writeln!(f, "    }}").unwrap();
    writeln!(f, "}}").unwrap();
}

/// Map a genus slug to its Rust enum variant name.
fn genus_to_variant(slug: &str) -> &'static str {
    match slug {
        "aeranthos" => "Aeranthos",
        "ionantha" => "Ionantha",
        "xerographica" => "Xerographica",
        "caput-medusae" => "CaputMedusae",
        "bulbosa" => "Bulbosa",
        "tectorum" => "Tectorum",
        "stricta" => "Stricta",
        "usneoides" => "Usneoides",
        "cyanea" => "Cyanea",
        "funckiana" => "Funckiana",
        "magnusiana" => "Magnusiana",
        "bergeri" => "Bergeri",
        "brachycaulos" => "Brachycaulos",
        "harrisii" => "Harrisii",
        "duratii" => "Duratii",
        "gardneri" => "Gardneri",
        "seleriana" => "Seleriana",
        "fasciculata" => "Fasciculata",
        "leiboldiana" => "Leiboldiana",
        "flabellata" => "Flabellata",
        "paleacea" => "Paleacea",
        "recurvata" => "Recurvata",
        "kolbii" => "Kolbii",
        "pruinosa" => "Pruinosa",
        _ => panic!("Unknown genus slug: {slug}"),
    }
}

/// Map a lifecycle slug to its Rust enum variant name.
fn lifecycle_to_variant(slug: &str) -> &'static str {
    match slug {
        "bud" => "Bud",
        "bloom" => "Bloom",
        "dried" => "Dried",
        "pup" => "Pup",
        _ => panic!("Unknown lifecycle slug: {slug}"),
    }
}
