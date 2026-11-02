//! 1959-xsy5, design D13 (openspec/changes/studio-asset-pipeline/design.md):
//! a contact sheet for human review across tiers and seeds. One labelled grid
//! of outputs with its provenance beside it, so "row 2, column 3" resolves to
//! a file and a seed. No GPU; deterministic like the D12 finish: integer
//! arithmetic, an embedded bitmap font (no host fonts), the same fixed PNG
//! encoder.
//!
//! Layout: rows and columns in first-appearance order of their labels. A row
//! label gutter on the left, column labels on top. Each cell is the output
//! scaled nearest-neighbour to fit `cell_px` (pixel art stays crisp, a soft
//! render stays soft), centred on a checkerboard so transparency shows, then
//! two text lines under it: the model's short name, and the first eight hex
//! characters of the output's sha256. A footer names the sheet's subject
//! (workflow or tier), its sha256 and the pipeline version.

use crate::pixel_finish::{Rgba, sha256_hex};

// ── embedded 5x7 bitmap font ────────────────────────────────────────────────
// Each glyph is seven rows of five bits (bit 4 = leftmost column), drawn in a
// 6x8 advance. Lowercase is drawn as uppercase; anything else as '?'.
const GLYPH_W: u32 = 6;
const GLYPH_H: u32 = 8;

fn glyph(c: char) -> [u8; 7] {
    match c.to_ascii_uppercase() {
        '0' => [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        '1' => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        '2' => [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
        '3' => [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        '4' => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        '5' => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        '6' => [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        '7' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        '9' => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        'A' => [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'B' => [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        'C' => [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        'D' => [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C],
        'E' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        'F' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        'G' => [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
        'H' => [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'I' => [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        'J' => [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
        'K' => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        'L' => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        'M' => [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
        'N' => [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
        'O' => [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'P' => [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        'Q' => [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        'R' => [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        'S' => [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
        'T' => [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'U' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'V' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        'W' => [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A],
        'X' => [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        'Y' => [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04],
        'Z' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        '-' => [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
        '_' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F],
        '.' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
        ':' => [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
        '/' => [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00],
        '#' => [0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A],
        '+' => [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00],
        ' ' => [0x00; 7],
        _ => [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04], // '?'
    }
}

/// A canvas the sheet is drawn on; RGBA, opaque throughout.
struct Canvas {
    w: u32,
    h: u32,
    px: Vec<u8>,
}

const BG: [u8; 3] = [0x20, 0x20, 0x24];
const INK: [u8; 3] = [0xF0, 0xF0, 0xF0];
const CHECK_A: [u8; 3] = [0xC8, 0xC8, 0xC8];
const CHECK_B: [u8; 3] = [0xF8, 0xF8, 0xF8];
const CHECK: u32 = 8;

impl Canvas {
    fn new(w: u32, h: u32) -> Self {
        let mut px = Vec::with_capacity((w * h * 4) as usize);
        for _ in 0..w * h {
            px.extend_from_slice(&[BG[0], BG[1], BG[2], 255]);
        }
        Self { w, h, px }
    }
    fn set(&mut self, x: u32, y: u32, c: [u8; 3]) {
        if x < self.w && y < self.h {
            let i = ((y * self.w + x) * 4) as usize;
            self.px[i..i + 3].copy_from_slice(&c);
        }
    }
    /// Text in the embedded font, clipped to `max_w` pixels.
    fn text(&mut self, x: u32, y: u32, s: &str, max_w: u32) {
        let fit = (max_w / GLYPH_W) as usize;
        for (i, c) in s.chars().take(fit).enumerate() {
            let g = glyph(c);
            for (row, bits) in g.iter().enumerate() {
                for col in 0..5u32 {
                    if bits & (0x10 >> col) != 0 {
                        self.set(x + i as u32 * GLYPH_W + col, y + row as u32, INK);
                    }
                }
            }
        }
    }
    /// `img` scaled nearest-neighbour to fit a `side` square at (x, y),
    /// centred, over a checkerboard. Alpha blends in integer arithmetic.
    fn cell(&mut self, x: u32, y: u32, side: u32, img: &Rgba) {
        for cy in 0..side {
            for cx in 0..side {
                let chk = if ((cx / CHECK) + (cy / CHECK)).is_multiple_of(2) {
                    CHECK_A
                } else {
                    CHECK_B
                };
                self.set(x + cx, y + cy, chk);
            }
        }
        // Fit: the longer side becomes `side`, fixed point.
        let long = img.width.max(img.height);
        let (dw, dh) = (
            (img.width as u64 * side as u64 / long as u64).max(1) as u32,
            (img.height as u64 * side as u64 / long as u64).max(1) as u32,
        );
        let (ox, oy) = (x + (side - dw) / 2, y + (side - dh) / 2);
        for dy in 0..dh {
            for dx in 0..dw {
                let sx = (dx as u64 * img.width as u64 / dw as u64) as u32;
                let sy = (dy as u64 * img.height as u64 / dh as u64) as u32;
                let i = ((sy * img.width + sx) * 4) as usize;
                let (r, g, b, a) = (
                    img.pixels[i],
                    img.pixels[i + 1],
                    img.pixels[i + 2],
                    img.pixels[i + 3] as u32,
                );
                let o = (((oy + dy) * self.w + ox + dx) * 4) as usize;
                for (k, s) in [r, g, b].into_iter().enumerate() {
                    let under = self.px[o + k] as u32;
                    self.px[o + k] = ((s as u32 * a + under * (255 - a) + 127) / 255) as u8;
                }
            }
        }
    }
}

/// One cell's content.
pub(crate) struct CellIn {
    pub image: Rgba,
    pub row: String,
    pub col: String,
    pub model: String,
    pub sha256: String,
}

const GUTTER: u32 = 12 * GLYPH_W; // row labels: up to 12 characters
const HEADER: u32 = GLYPH_H + 4;
const PAD: u32 = 4;
const UNDER: u32 = 2 * GLYPH_H + 2; // model line + sha line

/// The row and column label orders: first appearance.
fn orders(cells: &[CellIn]) -> (Vec<String>, Vec<String>) {
    let (mut rows, mut cols) = (Vec::<String>::new(), Vec::<String>::new());
    for c in cells {
        if !rows.contains(&c.row) {
            rows.push(c.row.clone());
        }
        if !cols.contains(&c.col) {
            cols.push(c.col.clone());
        }
    }
    (rows, cols)
}

/// Draw the sheet. `footer` names the subject, its sha256, the version.
pub(crate) fn build(cells: &[CellIn], cell_px: u32, footer: &str) -> Result<Rgba, String> {
    if cells.is_empty() {
        return Err("a contact sheet needs at least one cell".into());
    }
    if !(16..=1024).contains(&cell_px) {
        return Err(format!("cell_px must be 16..=1024, got {cell_px}"));
    }
    let (rows, cols) = orders(cells);
    let pitch_x = cell_px + PAD;
    let pitch_y = cell_px + UNDER + PAD;
    let w = GUTTER + PAD + cols.len() as u32 * pitch_x;
    let h = HEADER + rows.len() as u32 * pitch_y + HEADER;
    let mut c = Canvas::new(w, h);
    for (i, col) in cols.iter().enumerate() {
        c.text(GUTTER + PAD + i as u32 * pitch_x, 2, col, cell_px);
    }
    for (j, row) in rows.iter().enumerate() {
        c.text(
            2,
            HEADER + j as u32 * pitch_y + cell_px / 2,
            row,
            GUTTER - 2,
        );
    }
    for cell in cells {
        let i = cols.iter().position(|x| *x == cell.col).expect("ordered") as u32;
        let j = rows.iter().position(|x| *x == cell.row).expect("ordered") as u32;
        let (x, y) = (GUTTER + PAD + i * pitch_x, HEADER + j * pitch_y);
        c.cell(x, y, cell_px, &cell.image);
        c.text(x, y + cell_px + 1, &cell.model, cell_px);
        c.text(
            x,
            y + cell_px + 1 + GLYPH_H,
            &cell.sha256[..cell.sha256.len().min(8)],
            cell_px,
        );
    }
    c.text(2, h - GLYPH_H - 2, footer, w - 4);
    Ok(Rgba {
        width: c.w,
        height: c.h,
        pixels: c.px,
    })
}

pub(crate) fn descriptor() -> serde_json::Value {
    serde_json::json!({
        "name": "studio.contact_sheet",
        "description": format!(
            "Lay outputs on one labelled grid for review (design D13): rows and columns are \
             free labels (default use: rows = tiers, columns = seeds), each cell scaled \
             nearest-neighbour to cell_px over a checkerboard, labelled with the model's short \
             name and the first eight hex of its sha256, and a footer. Writes the sheet PNG and \
             <out>.contact.json, which resolves every cell to its output and provenance path. \
             No GPU; deterministic. Paths are under {}/.",
            crate::imagegen_tool::FORGE_SCRATCH
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "cells": { "type": "array", "items": { "type": "object", "properties": {
                    "path": { "type": "string" }, "row": { "type": "string" }, "col": { "type": "string" } },
                    "required": ["path", "row", "col"] } },
                "cell_px": { "type": "integer", "minimum": 16, "maximum": 1024, "default": 256 },
                "title": { "type": "string", "description": "footer subject: the workflow or tier" },
                "out": { "type": "string" }
            },
            "required": ["cells", "out"]
        }
    })
}

/// The model's short name from a cell's provenance: the first model file's
/// stem, else its tier, else "?".
fn model_of(provenance: Option<&serde_json::Value>) -> String {
    let Some(p) = provenance else {
        return "?".into();
    };
    if let Some(f) = p["models"][0]["file"].as_str() {
        let stem = f.rsplit('/').next().unwrap_or(f);
        return stem.split('.').next().unwrap_or(stem).to_string();
    }
    p["tier"].as_str().unwrap_or("?").to_string()
}

pub(crate) fn call(
    project: &str,
    instance: &str,
    args: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    use crate::studio_tool::{scratch_dir, scratch_relative};
    let out = args["out"]
        .as_str()
        .ok_or("invalid_arguments: out is required")?;
    if !out.ends_with(".png") {
        return Err("invalid_arguments: out must end in .png".into());
    }
    let list = args["cells"]
        .as_array()
        .ok_or("invalid_arguments: cells is required")?;
    let cell_px = args["cell_px"].as_u64().unwrap_or(256) as u32;
    let scratch = scratch_dir(project, instance)?;
    let mut cells = Vec::with_capacity(list.len());
    let mut listed = Vec::with_capacity(list.len());
    for (n, c) in list.iter().enumerate() {
        let path = c["path"]
            .as_str()
            .ok_or_else(|| format!("invalid_arguments: cells[{n}].path is required"))?;
        let row = c["row"]
            .as_str()
            .ok_or_else(|| format!("invalid_arguments: cells[{n}].row is required"))?;
        let col = c["col"]
            .as_str()
            .ok_or_else(|| format!("invalid_arguments: cells[{n}].col is required"))?;
        let host = scratch.join(scratch_relative(path)?);
        let bytes = std::fs::read(&host).map_err(|e| format!("{path}: {e}"))?;
        let img = image::load_from_memory_with_format(&bytes, image::ImageFormat::Png)
            .map_err(|e| format!("{path} is not a PNG: {e}"))?
            .to_rgba8();
        let side = crate::provenance::sidecar_path(&host);
        let prov: Option<serde_json::Value> = std::fs::read_to_string(&side)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok());
        let sha = sha256_hex(&bytes);
        let prov_forge = prov.as_ref().map(|_| format!("{path}.provenance.json"));
        listed.push(serde_json::json!({
            "row": row, "col": col, "path": path, "sha256": sha,
            "provenance": prov_forge, "model": model_of(prov.as_ref()),
            "seed": prov.as_ref().and_then(|p| p.get("seed").cloned()),
        }));
        cells.push(CellIn {
            image: Rgba {
                width: img.width(),
                height: img.height(),
                pixels: img.into_raw(),
            },
            row: row.into(),
            col: col.into(),
            model: model_of(prov.as_ref()),
            sha256: sha,
        });
    }
    let title = args["title"].as_str().unwrap_or("contact sheet");
    let footer = format!(
        "{title}  {}  v{}",
        &sha256_hex(title.as_bytes())[..8],
        crate::VERSION.trim()
    );
    let sheet = build(&cells, cell_px, &footer)?;
    let png = crate::pixel_finish::encode_rgba(&sheet)?;
    let out_host = scratch.join(scratch_relative(out)?);
    if let Some(dir) = out_host.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(&out_host, &png).map_err(|e| format!("{out}: {e}"))?;
    let sha = sha256_hex(&png);
    let contact = serde_json::json!({
        "schema": "tillandsias.contact/v1", "sheet": out, "sheet_sha256": sha,
        "cell_px": cell_px, "title": title, "pipelineVersion": crate::VERSION.trim(),
        "cells": listed,
    });
    let json_host = out_host.with_extension("contact.json");
    std::fs::write(&json_host, format!("{contact:#}\n"))
        .map_err(|e| format!("{}: {e}", json_host.display()))?;
    Ok(serde_json::json!({
        "sheet": out, "sha256": sha,
        "contact_json": format!("{}.contact.json", out.trim_end_matches(".png")),
        "cells": list.len(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: u32, h: u32, c: [u8; 4]) -> Rgba {
        Rgba {
            width: w,
            height: h,
            pixels: (0..w * h).flat_map(|_| c).collect(),
        }
    }

    fn cells() -> Vec<CellIn> {
        let mk = |row: &str, col: &str, img: Rgba| CellIn {
            row: row.into(),
            col: col.into(),
            model: "sdxs09".into(),
            sha256: sha256_hex(&img.pixels),
            image: img,
        };
        vec![
            mk("I0", "930001", solid(16, 16, [200, 40, 40, 255])),
            mk("I0", "930002", solid(32, 16, [40, 200, 40, 255])),
            mk("I1", "930001", solid(16, 32, [40, 40, 200, 255])),
            mk("I1", "930002", solid(16, 16, [0, 0, 0, 0])), // transparent
        ]
    }

    #[test]
    fn contact_sheet_lays_rows_and_columns_in_first_appearance_order() {
        let (rows, cols) = orders(&cells());
        assert_eq!(rows, ["I0", "I1"]);
        assert_eq!(cols, ["930001", "930002"]);
        let s = build(&cells(), 32, "I0+I1").unwrap();
        assert_eq!(s.width, GUTTER + PAD + 2 * (32 + PAD));
        assert_eq!(s.height, HEADER + 2 * (32 + UNDER + PAD) + HEADER);
    }

    #[test]
    fn contact_sheet_shows_a_transparent_cell_on_a_checkerboard() {
        let s = build(&cells(), 32, "x").unwrap();
        // The transparent cell is row I1, column 930002.
        let (x, y) = (GUTTER + PAD + (32 + PAD), HEADER + (32 + UNDER + PAD));
        let px = |dx: u32, dy: u32| {
            let i = (((y + dy) * s.width + x + dx) * 4) as usize;
            [s.pixels[i], s.pixels[i + 1], s.pixels[i + 2]]
        };
        assert_eq!(px(1, 1), CHECK_A);
        assert_eq!(px(CHECK + 1, 1), CHECK_B, "the checkerboard alternates");
    }

    #[test]
    fn contact_sheet_scales_nearest_neighbour_keeping_aspect() {
        let s = build(&cells(), 32, "x").unwrap();
        // Row I0 col 930002 is 32x16 red-green: it fills the width, and sits
        // centred vertically with checker above and below.
        let (x, y) = (GUTTER + PAD + (32 + PAD), HEADER);
        let at = |dx: u32, dy: u32| {
            let i = (((y + dy) * s.width + x + dx) * 4) as usize;
            [s.pixels[i], s.pixels[i + 1], s.pixels[i + 2]]
        };
        assert_eq!(at(0, 16), [40, 200, 40], "the image band");
        assert!(
            at(0, 1) == CHECK_A || at(0, 1) == CHECK_B,
            "checker above the band"
        );
    }

    #[test]
    fn contact_sheet_is_byte_reproducible_and_matches_the_golden() {
        let a = sha256_hex(
            &crate::pixel_finish::encode_rgba(&build(&cells(), 32, "I0+I1 v0").unwrap()).unwrap(),
        );
        let b = sha256_hex(
            &crate::pixel_finish::encode_rgba(&build(&cells(), 32, "I0+I1 v0").unwrap()).unwrap(),
        );
        assert_eq!(a, b, "two runs differ");
        assert_eq!(
            a, GOLDEN_SHEET,
            "the sheet differs from the committed golden"
        );
    }

    #[test]
    fn contact_sheet_refuses_an_empty_set_and_an_out_of_range_cell_size() {
        assert!(build(&[], 32, "x").is_err());
        assert!(build(&cells(), 8, "x").is_err());
        assert!(build(&cells(), 2048, "x").is_err());
    }

    #[test]
    fn contact_sheet_names_the_model_from_provenance() {
        let p =
            serde_json::json!({ "models": [{ "file": "I0/sdxs09.safetensors" }], "tier": "I0" });
        assert_eq!(model_of(Some(&p)), "sdxs09");
        assert_eq!(model_of(Some(&serde_json::json!({ "tier": "I2" }))), "I2");
        assert_eq!(model_of(None), "?");
    }

    const GOLDEN_SHEET: &str = "9a8eba8663524258753b87bff43aa691e42fb48b09278de512abdca629982db0";

    /// Writes the fixture sheet for a human look; run explicitly.
    #[test]
    #[ignore]
    fn contact_sheet_write_sample_for_review() {
        let png =
            crate::pixel_finish::encode_rgba(&build(&cells(), 64, "I0+I1 v0").unwrap()).unwrap();
        std::fs::write(
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../target/contact-sheet-sample.png"
            ),
            png,
        )
        .unwrap();
    }
}
