//! 1959-xsy5, design D11 (openspec/changes/studio-asset-pipeline/design.md):
//! image-to-image, inpaint and a layout mask on the sd.cpp tiers.
//!
//! `image.generate` takes four optional keys:
//! - `init_image`: the starting picture (a PNG under the lane scratch, the
//!   job's size). Alone it is image-to-image over the whole canvas.
//! - `mask`: a greyscale PNG the size of the canvas. White is repainted,
//!   black is kept, grey is blended. One convention for the caller.
//! - `strength`: 0..=1, how far the result may leave the init image.
//! - `layout`: a family's reserved regions (`<checkout path>#layout`), or a
//!   mask PNG under the scratch, unioned with `mask` as KEPT area.
//!
//! Kept pixels are kept: whatever the engine does at a soft mask edge, every
//! pixel under a fully black effective mask is composited back from the init
//! image after the run, byte-identical, and every pixel inside a reserved
//! region is set to the region's `fill` (alpha 0 for `transparent`). So an
//! empty centre lane stays empty whichever model drew the part.
//!
//! Pure functions over RGBA buffers; the tool call does the file I/O.

use crate::pixel_finish::Rgba;
use serde_json::Value;

/// A region's fill: alpha 0, or an opaque colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Fill {
    Transparent,
    Colour([u8; 3]),
}

/// One reserved region, as millionths of the canvas: [x0, y0, x1, y1].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Region {
    pub id: String,
    pub rect_ppm: [u32; 4],
    pub fill: Fill,
}

impl Region {
    /// The region's pixel rectangle [x0, x1) x [y0, y1) on a w x h canvas.
    fn pixels(&self, w: u32, h: u32) -> (u32, u32, u32, u32) {
        let s = |ppm: u32, n: u32| ((ppm as u64 * n as u64) / 1_000_000) as u32;
        (
            s(self.rect_ppm[0], w),
            s(self.rect_ppm[2], w),
            s(self.rect_ppm[1], h),
            s(self.rect_ppm[3], h),
        )
    }
    fn contains(&self, x: u32, y: u32, w: u32, h: u32) -> bool {
        let (x0, x1, y0, y1) = self.pixels(w, h);
        x >= x0 && x < x1 && y >= y0 && y < y1
    }
}

/// Parse a family's `layout` block (`{reserved: [...], units:
/// "fraction-of-generation-canvas"}`).
pub(crate) fn parse_layout(layout: &Value) -> Result<Vec<Region>, String> {
    if layout["units"] != "fraction-of-generation-canvas" {
        return Err("layout.units must be \"fraction-of-generation-canvas\"".into());
    }
    let list = layout["reserved"]
        .as_array()
        .ok_or("layout.reserved must be a list")?;
    list.iter()
        .enumerate()
        .map(|(i, r)| {
            let id = r["id"].as_str().unwrap_or("").to_string();
            let rect = r["rect"]
                .as_array()
                .filter(|a| a.len() == 4)
                .ok_or_else(|| format!("layout.reserved[{i}].rect must be [x0, y0, x1, y1]"))?;
            let mut ppm = [0u32; 4];
            for (k, v) in rect.iter().enumerate() {
                let f = v
                    .as_f64()
                    .filter(|f| (0.0..=1.0).contains(f))
                    .ok_or_else(|| {
                        format!("layout.reserved[{i}].rect values are fractions 0..=1")
                    })?;
                // Fractions become integer millionths once, here; every later
                // step is integer.
                ppm[k] = (f * 1_000_000.0).round() as u32;
            }
            if ppm[0] >= ppm[2] || ppm[1] >= ppm[3] {
                return Err(format!(
                    "layout.reserved[{i}].rect must have x0 < x1 and y0 < y1"
                ));
            }
            let fill = match r["fill"].as_str().unwrap_or("transparent") {
                "transparent" => Fill::Transparent,
                s => {
                    let h = s
                        .strip_prefix('#')
                        .filter(|h| h.len() == 6 && h.chars().all(|c| c.is_ascii_hexdigit()))
                        .ok_or_else(|| {
                            format!("layout.reserved[{i}].fill must be transparent or #RRGGBB")
                        })?;
                    let b = |j: usize| u8::from_str_radix(&h[j..j + 2], 16).expect("hex");
                    Fill::Colour([b(0), b(2), b(4)])
                }
            };
            Ok(Region {
                id,
                rect_ppm: ppm,
                fill,
            })
        })
        .collect()
}

/// The parsed request keys.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Request {
    pub init: String,
    pub mask: Option<String>,
    pub strength: Option<f32>,
    /// `<checkout path>#layout`, or a mask PNG path under the scratch.
    pub layout: Option<String>,
}

fn scratch_path(args: &Value, key: &str) -> Result<Option<String>, String> {
    match args.get(key).and_then(Value::as_str) {
        None => Ok(None),
        Some(p) => {
            crate::studio_tool::scratch_relative(p).map_err(|_| {
                format!(
                    "invalid_arguments: {key} must be a file under {}/",
                    crate::imagegen_tool::FORGE_SCRATCH
                )
            })?;
            Ok(Some(p.to_string()))
        }
    }
}

/// Parse the D11 keys. `None` when the request uses none of them.
pub(crate) fn parse(args: &Value) -> Result<Option<Request>, String> {
    let init = scratch_path(args, "init_image")?;
    let mask = scratch_path(args, "mask")?;
    let strength = match args.get("strength") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_f64()
                .filter(|s| (0.0..=1.0).contains(s))
                .ok_or("invalid_arguments: strength must be a number 0..=1")? as f32,
        ),
    };
    let layout = args
        .get("layout")
        .and_then(Value::as_str)
        .map(str::to_string);
    let Some(init) = init else {
        if mask.is_some() || strength.is_some() || layout.is_some() {
            return Err("invalid_arguments: mask, strength and layout need init_image".into());
        }
        return Ok(None);
    };
    Ok(Some(Request {
        init,
        mask,
        strength,
        layout,
    }))
}

/// The effective mask, one byte per pixel (0 kept, 255 repainted): the
/// caller's mask (or all-repaint when none, i.e. image-to-image), with every
/// black pixel of a layout mask and every reserved region forced to KEPT.
pub(crate) fn effective_mask(
    w: u32,
    h: u32,
    user: Option<&[u8]>,
    layout_mask: Option<&[u8]>,
    regions: &[Region],
) -> Vec<u8> {
    let n = (w * h) as usize;
    let mut m: Vec<u8> = user.map_or_else(|| vec![255; n], <[u8]>::to_vec);
    if let Some(l) = layout_mask {
        for (i, &v) in l.iter().enumerate().take(n) {
            if v == 0 {
                m[i] = 0;
            }
        }
    }
    for y in 0..h {
        for x in 0..w {
            if regions.iter().any(|r| r.contains(x, y, w, h)) {
                m[(y * w + x) as usize] = 0;
            }
        }
    }
    m
}

/// The init image the engine receives: each reserved region filled with its
/// fill (black for `transparent`; alpha is restored after the run).
pub(crate) fn prepare_init(init: &Rgba, regions: &[Region]) -> Rgba {
    let mut out = init.clone();
    for y in 0..init.height {
        for x in 0..init.width {
            if let Some(r) = regions
                .iter()
                .find(|r| r.contains(x, y, init.width, init.height))
            {
                let i = ((y * init.width + x) * 4) as usize;
                let c = match r.fill {
                    Fill::Transparent => [0, 0, 0],
                    Fill::Colour(c) => c,
                };
                out.pixels[i..i + 3].copy_from_slice(&c);
                out.pixels[i + 3] = 255;
            }
        }
    }
    out
}

/// After the run: every fully kept pixel comes back from the ORIGINAL init
/// image byte for byte; then every reserved region takes its fill. The
/// output must be the init image's size.
pub(crate) fn composite(
    out: &Rgba,
    init: &Rgba,
    mask: &[u8],
    regions: &[Region],
) -> Result<Rgba, String> {
    if (out.width, out.height) != (init.width, init.height) {
        return Err(format!(
            "the engine wrote {}x{}, the init image is {}x{}",
            out.width, out.height, init.width, init.height
        ));
    }
    let (w, h) = (out.width, out.height);
    let mut r = out.clone();
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            if mask[(y * w + x) as usize] == 0 {
                r.pixels[i..i + 4].copy_from_slice(&init.pixels[i..i + 4]);
            }
            if let Some(reg) = regions.iter().find(|g| g.contains(x, y, w, h)) {
                match reg.fill {
                    Fill::Transparent => r.pixels[i..i + 4].copy_from_slice(&[0, 0, 0, 0]),
                    Fill::Colour(c) => {
                        r.pixels[i..i + 3].copy_from_slice(&c);
                        r.pixels[i + 3] = 255;
                    }
                }
            }
        }
    }
    Ok(r)
}

/// D11's `reserved_regions_empty` check on one output: every pixel inside a
/// reserved region is alpha 0, or equals its fill.
pub(crate) fn reserved_regions_empty(img: &Rgba, regions: &[Region]) -> Result<(), String> {
    for reg in regions {
        let (x0, x1, y0, y1) = reg.pixels(img.width, img.height);
        for y in y0..y1 {
            for x in x0..x1 {
                let i = ((y * img.width + x) * 4) as usize;
                let p = &img.pixels[i..i + 4];
                let ok =
                    p[3] == 0 || matches!(reg.fill, Fill::Colour(c) if p[..3] == c && p[3] == 255);
                if !ok {
                    return Err(format!(
                        "reserved_regions_empty:{}: pixel ({x},{y}) is painted",
                        if reg.id.is_empty() { "region" } else { &reg.id }
                    ));
                }
            }
        }
    }
    Ok(())
}

/// Luminance (integer Rec. 601) of a PNG, one byte per pixel.
fn decode_grey(bytes: &[u8], what: &str) -> Result<(u32, u32, Vec<u8>), String> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png)
        .map_err(|e| format!("{what} is not a PNG: {e}"))?
        .to_rgba8();
    let (w, h) = (img.width(), img.height());
    let g = img
        .pixels()
        .map(|p| ((p[0] as u32 * 299 + p[1] as u32 * 587 + p[2] as u32 * 114) / 1000) as u8)
        .collect();
    Ok((w, h, g))
}

fn decode_rgba(bytes: &[u8], what: &str) -> Result<Rgba, String> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png)
        .map_err(|e| format!("{what} is not a PNG: {e}"))?
        .to_rgba8();
    Ok(Rgba {
        width: img.width(),
        height: img.height(),
        pixels: img.into_raw(),
    })
}

fn encode_grey(w: u32, h: u32, g: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(std::io::Cursor::new(&mut out), w, h);
        enc.set_color(png::ColorType::Grayscale);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Balanced);
        enc.set_filter(png::Filter::NoFilter);
        let mut wr = enc.write_header().map_err(|e| format!("mask png: {e}"))?;
        wr.write_image_data(g)
            .map_err(|e| format!("mask png: {e}"))?;
    }
    Ok(out)
}

/// A request read, checked and staged for one job: the original init image,
/// the effective mask and the regions, plus the engine's view of the files.
#[derive(Debug)]
pub(crate) struct Staged {
    init: Rgba,
    mask: Vec<u8>,
    regions: Vec<Region>,
    /// (init path, mask path, strength) as the engine sees them (/out/...).
    pub engine: (String, Option<String>, Option<f32>),
    /// sha256 of the init image and of the effective mask, for provenance.
    pub init_sha256: String,
    pub mask_sha256: Option<String>,
}

impl Staged {
    /// Read the files, check the init image is the job's size, render the
    /// effective mask, and write the prepared init and mask under `in/` in
    /// the lane scratch (`out_dir`), where the engine reads them at /out.
    pub(crate) fn stage(
        project: &str,
        instance: &str,
        req: &Request,
        size: (u32, u32),
        out_dir: &std::path::Path,
        stamp: u128,
    ) -> Result<Self, String> {
        use crate::studio_tool::{read_checkout_file, scratch_relative};
        let read = |p: &str| -> Result<Vec<u8>, String> {
            std::fs::read(out_dir.join(scratch_relative(p)?)).map_err(|e| format!("{p}: {e}"))
        };
        let init_bytes = read(&req.init)?;
        let init = decode_rgba(&init_bytes, "init_image")?;
        if (init.width, init.height) != size {
            return Err(format!(
                "invalid_arguments: init_image is {}x{}, the job is {}x{}; pass the init image's size",
                init.width, init.height, size.0, size.1
            ));
        }
        let user = match &req.mask {
            Some(m) => {
                let (w, h, g) = decode_grey(&read(m)?, "mask")?;
                if (w, h) != size {
                    return Err(format!(
                        "invalid_arguments: mask is {w}x{h}, the canvas is {}x{}",
                        size.0, size.1
                    ));
                }
                Some(g)
            }
            None => None,
        };
        let (mut regions, mut layout_mask) = (Vec::new(), None);
        if let Some(l) = &req.layout {
            if l.ends_with(".png") {
                let (w, h, g) = decode_grey(&read(l)?, "layout")?;
                if (w, h) != size {
                    return Err(format!(
                        "invalid_arguments: layout mask is {w}x{h}, the canvas is {}x{}",
                        size.0, size.1
                    ));
                }
                layout_mask = Some(g);
            } else {
                let (path, pointer) = l.split_once('#').unwrap_or((l.as_str(), "layout"));
                let spec: Value =
                    serde_json::from_str(&read_checkout_file(project, instance, path)?)
                        .map_err(|e| format!("{path} is not JSON: {e}"))?;
                let block = spec
                    .pointer(&format!("/{}", pointer.trim_start_matches('/')))
                    .ok_or_else(|| format!("invalid_arguments: {path} has no #{pointer}"))?;
                regions = parse_layout(block)?;
            }
        }
        let mask = effective_mask(
            size.0,
            size.1,
            user.as_deref(),
            layout_mask.as_deref(),
            &regions,
        );
        let dir = out_dir.join("in");
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let prepared = crate::pixel_finish::encode_rgba(&prepare_init(&init, &regions))?;
        std::fs::write(dir.join(format!("{stamp}-init.png")), &prepared)
            .map_err(|e| format!("init: {e}"))?;
        let repaint_all = mask.iter().all(|&v| v == 255);
        let (mask_engine, mask_sha) = if repaint_all {
            (None, None) // image-to-image over the whole canvas: no mask flag
        } else {
            let bytes = encode_grey(size.0, size.1, &mask)?;
            std::fs::write(dir.join(format!("{stamp}-mask.png")), &bytes)
                .map_err(|e| format!("mask: {e}"))?;
            (
                Some(format!("/out/in/{stamp}-mask.png")),
                Some(crate::pixel_finish::sha256_hex(&bytes)),
            )
        };
        Ok(Self {
            init,
            mask,
            regions,
            engine: (
                format!("/out/in/{stamp}-init.png"),
                mask_engine,
                req.strength,
            ),
            init_sha256: crate::pixel_finish::sha256_hex(&init_bytes),
            mask_sha256: mask_sha,
        })
    }

    /// Composite one written output in place (D11 "Kept pixels are kept").
    pub(crate) fn composite_file(&self, path: &std::path::Path) -> Result<(), String> {
        let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let out = composite(
            &decode_rgba(&bytes, "output")?,
            &self.init,
            &self.mask,
            &self.regions,
        )?;
        reserved_regions_empty(&out, &self.regions)?;
        std::fs::write(path, crate::pixel_finish::encode_rgba(&out)?)
            .map_err(|e| format!("{}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn noise(w: u32, h: u32, seed: u32) -> Rgba {
        let mut s = seed;
        let pixels = (0..w * h * 4)
            .map(|_| {
                s = s.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                (s >> 16) as u8
            })
            .collect();
        Rgba {
            width: w,
            height: h,
            pixels,
        }
    }

    fn lane() -> Vec<Region> {
        parse_layout(&json!({ "reserved": [ { "id": "centre-lane", "rect": [0.40, 0.0, 0.60, 1.0], "fill": "transparent" } ],
                              "units": "fraction-of-generation-canvas" })).unwrap()
    }

    #[test]
    fn imagegen_init_mask_parses_the_keys_and_refuses_what_d11_forbids() {
        assert_eq!(parse(&json!({ "prompt": "x" })).unwrap(), None);
        let r = parse(&json!({ "init_image": "/work/tmp/imagegen/in/a.png", "mask": "/work/tmp/imagegen/in/m.png",
                                "strength": 0.55, "layout": "art/families/ship-v4.json#layout" })).unwrap().unwrap();
        assert_eq!(r.strength, Some(0.55));
        assert_eq!(
            r.layout.as_deref(),
            Some("art/families/ship-v4.json#layout")
        );
        assert!(
            parse(&json!({ "mask": "/work/tmp/imagegen/m.png" }))
                .unwrap_err()
                .contains("need init_image")
        );
        assert!(parse(&json!({ "init_image": "/etc/passwd" })).is_err());
        assert!(parse(&json!({ "init_image": "/work/tmp/imagegen/../x.png" })).is_err());
        assert!(
            parse(&json!({ "init_image": "/work/tmp/imagegen/a.png", "strength": 1.5 })).is_err()
        );
    }

    #[test]
    fn imagegen_init_mask_layout_regions_parse_in_integer_millionths() {
        let r = lane();
        assert_eq!(r[0].rect_ppm, [400_000, 0, 600_000, 1_000_000]);
        assert_eq!(r[0].pixels(100, 50), (40, 60, 0, 50));
        let bad = |l: Value| parse_layout(&l).is_err();
        assert!(bad(json!({ "reserved": [], "units": "px" })));
        assert!(bad(
            json!({ "reserved": [ { "rect": [0.6, 0, 0.4, 1] } ], "units": "fraction-of-generation-canvas" })
        ));
        assert!(bad(
            json!({ "reserved": [ { "rect": [0, 0, 1.2, 1] } ], "units": "fraction-of-generation-canvas" })
        ));
        assert!(bad(
            json!({ "reserved": [ { "rect": [0, 0, 1, 1], "fill": "navy" } ], "units": "fraction-of-generation-canvas" })
        ));
    }

    #[test]
    fn imagegen_init_mask_effective_mask_keeps_regions_and_layout_black() {
        let (w, h) = (10, 2);
        let user = vec![255u8; 20];
        let mut layout = vec![255u8; 20];
        layout[0] = 0;
        let m = effective_mask(w, h, Some(&user), Some(&layout), &lane());
        assert_eq!(m[0], 0, "layout black is kept");
        assert_eq!(&m[4..6], &[0, 0], "the centre lane (x 4..6) is kept");
        assert_eq!(m[3], 255);
        assert_eq!(
            effective_mask(w, h, None, None, &[]),
            vec![255; 20],
            "no mask: image-to-image"
        );
    }

    /// D11 "Kept pixels are kept": whatever the engine paints, every pixel
    /// under a black mask and every reserved pixel is byte-identical to the
    /// input (or the fill) after the composite.
    #[test]
    fn imagegen_init_mask_kept_pixels_are_byte_identical_after_the_run() {
        let (w, h) = (64, 32);
        let init = noise(w, h, 7);
        // The caller keeps the left quarter (black) and repaints the rest.
        let user: Vec<u8> = (0..w * h)
            .map(|i| if i % w < 16 { 0 } else { 255 })
            .collect();
        let regions = lane();
        let mask = effective_mask(w, h, Some(&user), None, &regions);
        let engine_out = noise(w, h, 99); // the engine repaints EVERYTHING
        let out = composite(&engine_out, &init, &mask, &regions).unwrap();
        for y in 0..h {
            for x in 0..w {
                let i = ((y * w + x) * 4) as usize;
                if regions[0].contains(x, y, w, h) {
                    assert_eq!(
                        &out.pixels[i..i + 4],
                        &[0, 0, 0, 0],
                        "lane ({x},{y}) is empty"
                    );
                } else if x < 16 {
                    assert_eq!(
                        &out.pixels[i..i + 4],
                        &init.pixels[i..i + 4],
                        "kept ({x},{y}) is the input"
                    );
                } else {
                    assert_eq!(
                        &out.pixels[i..i + 4],
                        &engine_out.pixels[i..i + 4],
                        "repainted ({x},{y}) is the engine's"
                    );
                }
            }
        }
        reserved_regions_empty(&out, &regions).expect("the lane is empty");
        assert!(
            reserved_regions_empty(&engine_out, &regions)
                .unwrap_err()
                .starts_with("reserved_regions_empty:centre-lane:")
        );
        assert!(
            composite(&noise(8, 8, 1), &init, &mask, &regions).is_err(),
            "size mismatch refused"
        );
    }

    /// The staged path end to end on real files: stage writes the prepared
    /// init and the effective mask where the engine reads them; an "engine"
    /// then repaints the whole output; composite_file restores every kept
    /// pixel byte for byte on disk. A layout mask PNG keeps its black area.
    #[test]
    fn imagegen_init_mask_staged_files_round_trip_through_a_repainting_engine() {
        let dir = tempfile::tempdir().unwrap();
        let (w, h) = (32u32, 16u32);
        let init = noise(w, h, 11);
        std::fs::create_dir_all(dir.path().join("in")).unwrap();
        std::fs::write(
            dir.path().join("in/hull.png"),
            crate::pixel_finish::encode_rgba(&init).unwrap(),
        )
        .unwrap();
        // The caller's mask repaints everything; the layout keeps x < 8.
        std::fs::write(
            dir.path().join("in/m.png"),
            encode_grey(w, h, &vec![255; (w * h) as usize]).unwrap(),
        )
        .unwrap();
        let layout: Vec<u8> = (0..w * h)
            .map(|i| if i % w < 8 { 0 } else { 255 })
            .collect();
        std::fs::write(
            dir.path().join("in/lay.png"),
            encode_grey(w, h, &layout).unwrap(),
        )
        .unwrap();
        let req = Request {
            init: "/work/tmp/imagegen/in/hull.png".into(),
            mask: Some("/work/tmp/imagegen/in/m.png".into()),
            strength: Some(0.4),
            layout: Some("/work/tmp/imagegen/in/lay.png".into()),
        };
        let s = Staged::stage("p", "i", &req, (w, h), dir.path(), 42).unwrap();
        assert_eq!(
            s.engine,
            (
                "/out/in/42-init.png".into(),
                Some("/out/in/42-mask.png".into()),
                Some(0.4)
            )
        );
        assert!(
            dir.path().join("in/42-init.png").exists()
                && dir.path().join("in/42-mask.png").exists()
        );
        assert!(
            Staged::stage("p", "i", &req, (w + 1, h), dir.path(), 43)
                .unwrap_err()
                .contains("the job is")
        );

        let out = dir.path().join("img-0.png");
        let engine = noise(w, h, 77);
        std::fs::write(&out, crate::pixel_finish::encode_rgba(&engine).unwrap()).unwrap();
        s.composite_file(&out).unwrap();
        let after = decode_rgba(&std::fs::read(&out).unwrap(), "after").unwrap();
        for y in 0..h {
            for x in 0..w {
                let i = ((y * w + x) * 4) as usize;
                let want = if x < 8 {
                    &init.pixels[i..i + 4]
                } else {
                    &engine.pixels[i..i + 4]
                };
                assert_eq!(&after.pixels[i..i + 4], want, "({x},{y})");
            }
        }
    }

    /// The live arm's independent check: decodes the files a REAL sd.cpp run
    /// left in target/d11-live (init.png, mask.png, out.png) and verifies
    /// every kept pixel and the centre lane itself, not via the tool's own
    /// success line. Run explicitly after the live run copies them there.
    #[test]
    #[ignore]
    fn imagegen_init_mask_live_verify() {
        // Read at run time (1590-j20f: never compile-time env!).
        let dir = std::path::PathBuf::from(
            std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"),
        )
        .join("../../target/d11-live");
        let rd = |n: &str| std::fs::read(dir.join(n)).unwrap_or_else(|e| panic!("{n}: {e}"));
        let init = decode_rgba(&rd("init.png"), "init").unwrap();
        let (_, _, mask) = decode_grey(&rd("mask.png"), "mask").unwrap();
        let out = decode_rgba(&rd("out.png"), "out").unwrap();
        let lane = lane();
        let eff = effective_mask(init.width, init.height, Some(&mask), None, &lane);
        let (mut kept, mut repainted_changed, mut repainted) = (0u32, 0u32, 0u32);
        for y in 0..init.height {
            for x in 0..init.width {
                let i = ((y * init.width + x) * 4) as usize;
                if lane[0].contains(x, y, init.width, init.height) {
                    assert_eq!(out.pixels[i + 3], 0, "lane ({x},{y}) is not empty");
                } else if eff[(y * init.width + x) as usize] == 0 {
                    assert_eq!(
                        &out.pixels[i..i + 4],
                        &init.pixels[i..i + 4],
                        "kept ({x},{y}) changed"
                    );
                    kept += 1;
                } else {
                    repainted += 1;
                    if out.pixels[i..i + 3] != init.pixels[i..i + 3] {
                        repainted_changed += 1;
                    }
                }
            }
        }
        reserved_regions_empty(&out, &lane).expect("reserved_regions_empty");
        eprintln!(
            "live-verify: kept={kept} byte-identical; repainted={repainted} of which changed={repainted_changed}; lane empty"
        );
        assert!(
            repainted_changed > repainted / 10,
            "the engine barely repainted: is the mask honoured?"
        );
    }

    #[test]
    fn imagegen_init_mask_prepare_fills_regions_before_the_run() {
        let init = noise(10, 2, 3);
        let regions = parse_layout(
            &json!({ "reserved": [ { "id": "lane", "rect": [0.4, 0, 0.6, 1], "fill": "#0A0B0C" } ],
                                            "units": "fraction-of-generation-canvas" }),
        )
        .unwrap();
        let p = prepare_init(&init, &regions);
        assert_eq!(&p.pixels[4 * 4..4 * 4 + 4], &[0x0A, 0x0B, 0x0C, 255]);
        assert_eq!(
            &p.pixels[0..4],
            &init.pixels[0..4],
            "outside the region is untouched"
        );
    }
}
