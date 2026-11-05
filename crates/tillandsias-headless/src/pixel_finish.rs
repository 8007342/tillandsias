//! 1959-xsy5, design D12 (openspec/changes/studio-asset-pipeline/design.md):
//! the pixel finish. A pure post-process in INTEGER arithmetic, so the same
//! inputs give the same bytes on every host and every run. No model, no GPU,
//! no container.
//!
//! Steps, in this order and only this order:
//! 1. alpha: from the input's own alpha (`engine`), a `matte` PNG, or a
//!    `colour-key` (Chebyshev distance within `tolerance` of `key`);
//!    binarised at 128.
//! 2. grid snap to the native size: `centre` (default; the source pixel at
//!    each cell's centre, nearest-neighbour) or `majority` (the palette index
//!    most source pixels in the cell quantise to, ties to the lowest index;
//!    transparent when more than half the cell is).
//! 3. quantise each opaque pixel to the nearest palette colour by squared
//!    distance in 8-bit sRGB, ties to the lowest index; dither `none`
//!    (default) or `ordered-bayer4`.
//! 4. write: an indexed PNG when the palette names a `transparent` entry and
//!    has at most 255 colours, else 8-bit RGBA. Fixed encoder settings; no
//!    time, text or gamma chunks.
//!
//! There is no interpolation anywhere, and no float.

use std::io::Cursor;

/// One `tillandsias.palette/v1` file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Palette {
    pub name: String,
    pub colours: Vec<[u8; 3]>,
    pub transparent: Option<[u8; 3]>,
}

pub(crate) const PALETTE_SCHEMA: &str = "tillandsias.palette/v1";

fn hex_colour(s: &str) -> Result<[u8; 3], String> {
    let h = s
        .strip_prefix('#')
        .filter(|h| h.len() == 6 && h.chars().all(|c| c.is_ascii_hexdigit()))
        .ok_or_else(|| format!("colour {s:?} is not #RRGGBB"))?;
    let b = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).expect("checked hex");
    Ok([b(0), b(2), b(4)])
}

impl Palette {
    /// Parse and validate a palette file's JSON.
    pub(crate) fn parse(json: &str) -> Result<Self, String> {
        let v: serde_json::Value =
            serde_json::from_str(json).map_err(|e| format!("palette is not JSON: {e}"))?;
        if v["schema"] != PALETTE_SCHEMA {
            return Err(format!(
                "palette schema must be {PALETTE_SCHEMA:?}, got {}",
                v["schema"]
            ));
        }
        let name = v["name"].as_str().unwrap_or("").to_string();
        let list = v["colours"]
            .as_array()
            .ok_or("palette colours must be a list")?;
        if list.is_empty() || list.len() > 256 {
            return Err(format!(
                "palette must hold 1 to 256 colours, has {}",
                list.len()
            ));
        }
        let colours = list
            .iter()
            .map(|c| hex_colour(c.as_str().ok_or("a palette colour is not a string")?))
            .collect::<Result<Vec<_>, _>>()?;
        let transparent = match &v["transparent"] {
            serde_json::Value::Null => None,
            serde_json::Value::String(s) => Some(hex_colour(s)?),
            other => {
                return Err(format!(
                    "palette transparent must be null or #RRGGBB, got {other}"
                ));
            }
        };
        Ok(Self {
            name,
            colours,
            transparent,
        })
    }

    /// The nearest colour's index: squared distance in 8-bit sRGB, ties to
    /// the lowest index.
    pub(crate) fn nearest(&self, rgb: [u8; 3]) -> usize {
        let mut best = (u32::MAX, 0usize);
        for (i, c) in self.colours.iter().enumerate() {
            let d: u32 = (0..3)
                .map(|k| {
                    let e = rgb[k] as i32 - c[k] as i32;
                    (e * e) as u32
                })
                .sum();
            if d < best.0 {
                best = (d, i);
            }
        }
        best.1
    }
}

/// Where alpha comes from (step 1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AlphaSource {
    Engine,
    /// A matte, one byte per pixel (its luminance or alpha), the input's size.
    Matte(Vec<u8>),
    ColourKey {
        key: [u8; 3],
        tolerance: u8,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Sample {
    Centre,
    Majority,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Dither {
    None,
    OrderedBayer4,
}

/// An RGBA image, row-major, 4 bytes per pixel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Rgba {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

impl Rgba {
    fn px(&self, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * self.width + x) * 4) as usize;
        [
            self.pixels[i],
            self.pixels[i + 1],
            self.pixels[i + 2],
            self.pixels[i + 3],
        ]
    }
}

/// The finished image: one palette index per pixel, `None` for transparent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Finished {
    pub width: u32,
    pub height: u32,
    pub indices: Vec<Option<u8>>,
}

/// Step 1: binary alpha per source pixel.
fn opaque_mask(img: &Rgba, alpha: &AlphaSource) -> Result<Vec<bool>, String> {
    let n = (img.width * img.height) as usize;
    match alpha {
        AlphaSource::Engine => Ok((0..n).map(|i| img.pixels[i * 4 + 3] >= 128).collect()),
        AlphaSource::Matte(m) => {
            if m.len() != n {
                return Err(format!("matte has {} pixels, the input {n}", m.len()));
            }
            Ok(m.iter().map(|&a| a >= 128).collect())
        }
        AlphaSource::ColourKey { key, tolerance } => Ok((0..n)
            .map(|i| {
                let p = &img.pixels[i * 4..i * 4 + 3];
                let cheb = (0..3)
                    .map(|k| (p[k] as i32 - key[k] as i32).unsigned_abs())
                    .max()
                    .unwrap_or(0);
                cheb > *tolerance as u32
            })
            .collect()),
    }
}

/// The fixed 4x4 Bayer matrix, values 0..=15.
const BAYER4: [[i32; 4]; 4] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

/// Step 3 for one pixel at native (x, y). Ordered dither offsets each channel
/// by (2*M - 15) * 4, a symmetric step of 8 in -60..=60, clamped to 0..=255.
fn quantise(p: &Palette, rgb: [u8; 3], x: u32, y: u32, dither: Dither) -> u8 {
    let rgb = match dither {
        Dither::None => rgb,
        Dither::OrderedBayer4 => {
            let d = (2 * BAYER4[(y % 4) as usize][(x % 4) as usize] - 15) * 4;
            [0, 1, 2].map(|k| (rgb[k] as i32 + d).clamp(0, 255) as u8)
        }
    };
    p.nearest(rgb) as u8
}

/// The source span [lo, hi) of native cell `i` along an axis: fixed point,
/// floor(i * canvas / native).
fn span(i: u32, canvas: u32, native: u32) -> (u32, u32) {
    let lo = (i as u64 * canvas as u64 / native as u64) as u32;
    let hi = ((i as u64 + 1) * canvas as u64 / native as u64) as u32;
    (lo, hi.max(lo + 1).min(canvas))
}

/// The source coordinate at native cell `i`'s centre:
/// floor((2i + 1) * canvas / (2 * native)).
fn centre(i: u32, canvas: u32, native: u32) -> u32 {
    (((2 * i as u64 + 1) * canvas as u64) / (2 * native as u64)) as u32
}

/// Steps 1-3. `native` is the output size; it must not exceed the input.
pub(crate) fn finish(
    img: &Rgba,
    alpha: &AlphaSource,
    native: (u32, u32),
    sample: Sample,
    dither: Dither,
    palette: &Palette,
) -> Result<Finished, String> {
    let (nw, nh) = native;
    if nw == 0 || nh == 0 || nw > img.width || nh > img.height {
        return Err(format!(
            "native {nw}x{nh} must be 1..= the input {}x{}",
            img.width, img.height
        ));
    }
    if img.pixels.len() != (img.width * img.height * 4) as usize {
        return Err("input is not RGBA of its stated size".into());
    }
    let opaque = opaque_mask(img, alpha)?;
    let mut indices = Vec::with_capacity((nw * nh) as usize);
    for y in 0..nh {
        for x in 0..nw {
            let cell = match sample {
                Sample::Centre => {
                    let (sx, sy) = (centre(x, img.width, nw), centre(y, img.height, nh));
                    if opaque[(sy * img.width + sx) as usize] {
                        let p = img.px(sx, sy);
                        Some(quantise(palette, [p[0], p[1], p[2]], x, y, dither))
                    } else {
                        None
                    }
                }
                Sample::Majority => {
                    let (x0, x1) = span(x, img.width, nw);
                    let (y0, y1) = span(y, img.height, nh);
                    let mut votes = vec![0u32; palette.colours.len()];
                    let (mut clear, mut total) = (0u32, 0u32);
                    for sy in y0..y1 {
                        for sx in x0..x1 {
                            total += 1;
                            if !opaque[(sy * img.width + sx) as usize] {
                                clear += 1;
                                continue;
                            }
                            let p = img.px(sx, sy);
                            votes[quantise(palette, [p[0], p[1], p[2]], x, y, dither) as usize] +=
                                1;
                        }
                    }
                    if clear * 2 > total {
                        None
                    } else {
                        // Most votes, ties to the lowest index.
                        let mut best = (0u32, 0usize);
                        for (i, &v) in votes.iter().enumerate() {
                            if v > best.0 {
                                best = (v, i);
                            }
                        }
                        Some(best.1 as u8)
                    }
                }
            };
            indices.push(cell);
        }
    }
    Ok(Finished {
        width: nw,
        height: nh,
        indices,
    })
}

/// Step 4: the PNG bytes, with fixed encoder settings and no ancillary
/// chunks. Indexed (with a tRNS entry for the palette's `transparent`) when
/// the palette names one and has at most 255 colours; else 8-bit RGBA.
pub(crate) fn encode(f: &Finished, palette: &Palette) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(Cursor::new(&mut out), f.width, f.height);
        enc.set_compression(png::Compression::Balanced);
        enc.set_filter(png::Filter::NoFilter);
        let data: Vec<u8> = match palette.transparent {
            Some(t) if palette.colours.len() <= 255 => {
                let clear = palette.colours.len() as u8;
                let mut plte: Vec<u8> = palette.colours.iter().flatten().copied().collect();
                plte.extend_from_slice(&t);
                let mut trns = vec![255u8; palette.colours.len()];
                trns.push(0);
                enc.set_color(png::ColorType::Indexed);
                enc.set_depth(png::BitDepth::Eight);
                enc.set_palette(plte);
                enc.set_trns(trns);
                f.indices.iter().map(|i| i.unwrap_or(clear)).collect()
            }
            _ => {
                enc.set_color(png::ColorType::Rgba);
                enc.set_depth(png::BitDepth::Eight);
                f.indices
                    .iter()
                    .flat_map(|i| match i {
                        Some(i) => {
                            let c = palette.colours[*i as usize];
                            [c[0], c[1], c[2], 255]
                        }
                        None => [0, 0, 0, 0],
                    })
                    .collect()
            }
        };
        let mut w = enc.write_header().map_err(|e| format!("png header: {e}"))?;
        w.write_image_data(&data)
            .map_err(|e| format!("png data: {e}"))?;
    }
    Ok(out)
}

/// An RGBA image as PNG bytes with the same fixed settings and no ancillary
/// chunks as [`encode`]. The D13 contact sheet writes through this.
pub(crate) fn encode_rgba(img: &Rgba) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(Cursor::new(&mut out), img.width, img.height);
        enc.set_compression(png::Compression::Balanced);
        enc.set_filter(png::Filter::NoFilter);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut w = enc.write_header().map_err(|e| format!("png header: {e}"))?;
        w.write_image_data(&img.pixels)
            .map_err(|e| format!("png data: {e}"))?;
    }
    Ok(out)
}

/// The sha256 of some bytes, lowercase hex.
pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The finish parameters a family spec carries (D12 "Contract"): the
/// optional `finish` block (`alpha`, `sample`, `dither`, `native`) and the
/// native size for `room`. A spec without `finish` means engine alpha,
/// `centre`, `none`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FamilyFinish {
    pub palette_path: String,
    pub alpha: String,
    pub key: Option<[u8; 3]>,
    pub tolerance: u8,
    pub sample: Sample,
    pub dither: Dither,
    pub native: (u32, u32),
}

fn size_of(v: &serde_json::Value) -> Option<(u32, u32)> {
    let w = v.get("width")?.as_u64()?;
    let h = v.get("height")?.as_u64()?;
    (w > 0 && h > 0 && w <= 16384 && h <= 16384).then_some((w as u32, h as u32))
}

impl FamilyFinish {
    pub(crate) fn from_spec(spec: &serde_json::Value, room: Option<&str>) -> Result<Self, String> {
        let palette_path = spec["palette"]["locked"]
            .as_str()
            .ok_or("family_has_no_locked_palette: palette.locked names no palette file")?
            .to_string();
        let f = &spec["finish"];
        let alpha = f["alpha"]["source"]
            .as_str()
            .unwrap_or("engine")
            .to_string();
        let key = match f["alpha"]["key"].as_str() {
            Some(s) => Some(hex_colour(s)?),
            None => None,
        };
        if alpha == "colour-key" && key.is_none() {
            return Err(
                "finish.alpha.key is required when finish.alpha.source is colour-key".into(),
            );
        }
        if !["engine", "matte", "colour-key"].contains(&alpha.as_str()) {
            return Err(format!(
                "finish.alpha.source must be engine, matte or colour-key, got {alpha:?}"
            ));
        }
        let tolerance = f["alpha"]["tolerance"].as_u64().unwrap_or(0).min(255) as u8;
        let sample = match f["sample"].as_str().unwrap_or("centre") {
            "centre" => Sample::Centre,
            "majority" => Sample::Majority,
            other => {
                return Err(format!(
                    "finish.sample must be centre or majority, got {other:?}"
                ));
            }
        };
        let dither = match f["dither"].as_str().unwrap_or("none") {
            "none" => Dither::None,
            "ordered-bayer4" => Dither::OrderedBayer4,
            other => {
                return Err(format!(
                    "finish.dither must be none or ordered-bayer4, got {other:?}"
                ));
            }
        };
        let frame = &spec["frame"]["native"];
        let native = if frame["perRoom"] == true {
            let r = room.ok_or("this family's native size is per room; pass room")?;
            size_of(&frame[r]).ok_or_else(|| format!("frame.native has no size for room {r:?}"))?
        } else if let Some(s) = size_of(frame) {
            s
        } else {
            size_of(&f["native"]).ok_or("no native size: set frame.native or finish.native")?
        };
        Ok(Self {
            palette_path,
            alpha,
            key,
            tolerance,
            sample,
            dither,
            native,
        })
    }
}

fn decode_rgba(bytes: &[u8]) -> Result<Rgba, String> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png)
        .map_err(|e| format!("input is not a PNG: {e}"))?
        .to_rgba8();
    Ok(Rgba {
        width: img.width(),
        height: img.height(),
        pixels: img.into_raw(),
    })
}

/// One byte per pixel from a matte PNG: its alpha when it has one, else its
/// luminance (integer Rec. 601 weights).
fn decode_matte(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png)
        .map_err(|e| format!("matte is not a PNG: {e}"))?;
    let has_alpha = img.color().has_alpha();
    Ok(img
        .to_rgba8()
        .pixels()
        .map(|p| {
            if has_alpha {
                p[3]
            } else {
                ((p[0] as u32 * 299 + p[1] as u32 * 587 + p[2] as u32 * 114) / 1000) as u8
            }
        })
        .collect())
}

pub(crate) fn descriptor() -> serde_json::Value {
    serde_json::json!({
        "name": "studio.finish_pixels",
        "description": format!(
            "The GPU-free pixel finish (design D12): alpha (engine | matte | colour-key, \
             binarised at 128), nearest-neighbour grid snap to the family's native size \
             (finish.sample: centre, the default, or majority), quantise to the family's \
             locked tillandsias.palette/v1 file (finish.dither: none or ordered-bayer4), then \
             a fixed-settings PNG and a <out>.finish.json sidecar. Integer arithmetic only: \
             the same inputs give the same bytes on every host. input, matte and out are \
             paths under {}/; family is project-relative.",
            crate::imagegen_tool::FORGE_SCRATCH
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "input":  { "type": "string" },
                "family": { "type": "string", "description": "e.g. art/families/gatekeeper-v3.json" },
                "room":   { "type": "string", "description": "required when frame.native is per room" },
                "matte":  { "type": "string", "description": "required when finish.alpha.source is matte" },
                "out":    { "type": "string" }
            },
            "required": ["input", "family", "out"]
        }
    })
}

/// The tool call: read, finish, write the PNG and its `.finish.json`.
pub(crate) fn call(
    project: &str,
    instance: &str,
    args: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    use crate::studio_tool::{read_checkout_file, scratch_dir, scratch_relative};
    let arg = |k: &str| args.get(k).and_then(serde_json::Value::as_str);
    let input = arg("input").ok_or("invalid_arguments: input is required")?;
    let family = arg("family").ok_or("invalid_arguments: family is required")?;
    let out = arg("out").ok_or("invalid_arguments: out is required")?;
    if !out.ends_with(".png") {
        return Err("invalid_arguments: out must end in .png".into());
    }
    let scratch = scratch_dir(project, instance)?;
    let input_host = scratch.join(scratch_relative(input)?);
    let out_host = scratch.join(scratch_relative(out)?);
    let spec_text = read_checkout_file(project, instance, family)?;
    let spec: serde_json::Value =
        serde_json::from_str(&spec_text).map_err(|e| format!("family is not JSON: {e}"))?;
    let ff = FamilyFinish::from_spec(&spec, arg("room"))?;
    let palette_text = read_checkout_file(project, instance, &ff.palette_path)?;
    let palette = Palette::parse(&palette_text)?;
    let input_bytes = std::fs::read(&input_host).map_err(|e| format!("{input}: {e}"))?;
    let img = decode_rgba(&input_bytes)?;
    let (alpha, matte_sha) = match ff.alpha.as_str() {
        "matte" => {
            let m = arg("matte")
                .ok_or("invalid_arguments: matte is required by finish.alpha.source matte")?;
            let bytes = std::fs::read(scratch.join(scratch_relative(m)?))
                .map_err(|e| format!("{m}: {e}"))?;
            (
                AlphaSource::Matte(decode_matte(&bytes)?),
                Some(sha256_hex(&bytes)),
            )
        }
        "colour-key" => (
            AlphaSource::ColourKey {
                key: ff.key.expect("checked"),
                tolerance: ff.tolerance,
            },
            None,
        ),
        _ => (AlphaSource::Engine, None),
    };
    let finished = finish(&img, &alpha, ff.native, ff.sample, ff.dither, &palette)?;
    let png = encode(&finished, &palette)?;
    if let Some(dir) = out_host.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(&out_host, &png).map_err(|e| format!("{out}: {e}"))?;
    let sha = sha256_hex(&png);
    let sidecar = serde_json::json!({
        "schema": "tillandsias.finish/v1",
        "output": out, "output_sha256": sha,
        "input": input, "input_sha256": sha256_hex(&input_bytes),
        // 1996-pvpr: the source's own sidecar, so the chain resolves across tools.
        "tool": "studio.finish_pixels",
        "parents": crate::provenance::parents_of([input_host.as_path()]),
        "matte": arg("matte"), "matte_sha256": matte_sha,
        "family": family, "family_sha256": sha256_hex(spec_text.as_bytes()),
        "palette": ff.palette_path, "palette_sha256": sha256_hex(palette_text.as_bytes()),
        "room": arg("room"),
        "params": {
            "alpha": ff.alpha, "tolerance": ff.tolerance,
            "sample": match ff.sample { Sample::Centre => "centre", Sample::Majority => "majority" },
            "dither": match ff.dither { Dither::None => "none", Dither::OrderedBayer4 => "ordered-bayer4" },
            "native": [ff.native.0, ff.native.1],
        }
    });
    let sidecar_host = out_host.with_extension("finish.json");
    std::fs::write(&sidecar_host, format!("{sidecar:#}\n"))
        .map_err(|e| format!("{}: {e}", sidecar_host.display()))?;
    Ok(serde_json::json!({
        "output": out, "sha256": sha,
        "finish_json": format!("{}.finish.json", out.trim_end_matches(".png")),
        "native": [ff.native.0, ff.native.1],
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PALETTE: &str = r##"{ "schema": "tillandsias.palette/v1", "name": "gatekeeper",
        "colours": ["#1A1018", "#F2E6C8", "#5A2A6B", "#2FA3A0"], "transparent": null }"##;

    /// A deterministic 64x64 fixture: a gradient body, a one-pixel outline
    /// ring, and a transparent corner. No file: the bytes ARE the fixture.
    fn fixture() -> Rgba {
        let (w, h) = (64u32, 64u32);
        let mut pixels = Vec::with_capacity((w * h * 4) as usize);
        for y in 0..h {
            for x in 0..w {
                let ring = x == 8 || x == 55 || y == 8 || y == 55;
                let corner = x < 6 && y < 6;
                let p = if corner {
                    [0, 0, 0, 0]
                } else if ring {
                    [0x1A, 0x10, 0x18, 255]
                } else {
                    [(x * 4) as u8, (y * 4) as u8, ((x + y) * 2) as u8, 255]
                };
                pixels.extend_from_slice(&p);
            }
        }
        Rgba {
            width: w,
            height: h,
            pixels,
        }
    }

    fn run(sample: Sample, dither: Dither, palette: &str) -> Vec<u8> {
        let p = Palette::parse(palette).expect("palette");
        let f = finish(
            &fixture(),
            &AlphaSource::Engine,
            (16, 16),
            sample,
            dither,
            &p,
        )
        .expect("finish");
        encode(&f, &p).expect("encode")
    }

    #[test]
    fn pixel_finish_palette_parses_and_refuses_what_v1_forbids() {
        let p = Palette::parse(PALETTE).expect("valid");
        assert_eq!(p.colours.len(), 4);
        assert_eq!(p.colours[0], [0x1A, 0x10, 0x18]);
        assert!(Palette::parse(r##"{"schema":"x","colours":["#000000"]}"##).is_err());
        assert!(Palette::parse(r#"{"schema":"tillandsias.palette/v1","colours":[]}"#).is_err());
        assert!(
            Palette::parse(r#"{"schema":"tillandsias.palette/v1","colours":["red"]}"#).is_err()
        );
        let too_many = format!(
            r#"{{"schema":"tillandsias.palette/v1","colours":[{}]}}"#,
            vec!["\"#000000\""; 257].join(",")
        );
        assert!(Palette::parse(&too_many).is_err());
    }

    #[test]
    fn pixel_finish_nearest_breaks_ties_to_the_lowest_index() {
        let p = Palette::parse(
            r##"{"schema":"tillandsias.palette/v1","colours":["#000000","#020000"],"transparent":null}"##,
        )
        .unwrap();
        // [1,0,0] is distance 1 from both: the lower index wins.
        assert_eq!(p.nearest([1, 0, 0]), 0);
        assert_eq!(p.nearest([2, 0, 0]), 1);
    }

    #[test]
    fn pixel_finish_centre_sampling_keeps_a_one_pixel_outline() {
        // A 1-pixel vertical line on the cell-centre column of an 8x8 -> 2x2
        // snap survives under centre sampling and loses the vote under majority.
        let (w, h) = (8u32, 8u32);
        let mut pixels = Vec::new();
        for _y in 0..h {
            for x in 0..w {
                pixels.extend_from_slice(if x == 2 {
                    &[0x1A, 0x10, 0x18, 255]
                } else {
                    &[0xF2, 0xE6, 0xC8, 255]
                });
            }
        }
        let img = Rgba {
            width: w,
            height: h,
            pixels,
        };
        let p = Palette::parse(PALETTE).unwrap();
        let c = finish(
            &img,
            &AlphaSource::Engine,
            (2, 2),
            Sample::Centre,
            Dither::None,
            &p,
        )
        .unwrap();
        assert_eq!(c.indices[0], Some(0), "centre keeps the outline colour");
        let m = finish(
            &img,
            &AlphaSource::Engine,
            (2, 2),
            Sample::Majority,
            Dither::None,
            &p,
        )
        .unwrap();
        assert_eq!(m.indices[0], Some(1), "majority lets the body colour win");
    }

    #[test]
    fn pixel_finish_alpha_sources_and_majority_transparency() {
        let p = Palette::parse(PALETTE).unwrap();
        let img = fixture();
        let f = finish(
            &img,
            &AlphaSource::Engine,
            (16, 16),
            Sample::Centre,
            Dither::None,
            &p,
        )
        .unwrap();
        assert_eq!(
            f.indices[0], None,
            "the transparent corner stays transparent"
        );
        let key = AlphaSource::ColourKey {
            key: [0x1A, 0x10, 0x18],
            tolerance: 0,
        };
        let k = finish(&img, &key, (64, 64), Sample::Centre, Dither::None, &p).unwrap();
        assert_eq!(
            k.indices[(8 * 64 + 20) as usize],
            None,
            "the keyed outline is cleared"
        );
        let matte = AlphaSource::Matte(vec![0; 64 * 64]);
        let m = finish(&img, &matte, (16, 16), Sample::Majority, Dither::None, &p).unwrap();
        assert!(
            m.indices.iter().all(|i| i.is_none()),
            "an all-black matte clears everything"
        );
        assert!(
            finish(
                &img,
                &AlphaSource::Matte(vec![0; 3]),
                (16, 16),
                Sample::Centre,
                Dither::None,
                &p
            )
            .is_err()
        );
        assert!(
            finish(
                &img,
                &AlphaSource::Engine,
                (65, 16),
                Sample::Centre,
                Dither::None,
                &p
            )
            .is_err()
        );
    }

    /// D12: "Determinism is tested, not promised." Twice-run equality, and a
    /// committed golden sha256 per mode. A host whose output differs fails
    /// here, which is the signal to find the float.
    #[test]
    fn pixel_finish_is_byte_reproducible_and_matches_the_golden() {
        let indexed = PALETTE.replace(r#""transparent": null"#, r##""transparent": "#FF00FF""##);
        for (label, sample, dither, pal, golden) in [
            (
                "centre/none/rgba",
                Sample::Centre,
                Dither::None,
                PALETTE,
                GOLDEN_CENTRE_NONE_RGBA,
            ),
            (
                "majority/bayer4/rgba",
                Sample::Majority,
                Dither::OrderedBayer4,
                PALETTE,
                GOLDEN_MAJORITY_BAYER_RGBA,
            ),
            (
                "centre/none/indexed",
                Sample::Centre,
                Dither::None,
                indexed.as_str(),
                GOLDEN_CENTRE_NONE_INDEXED,
            ),
        ] {
            let a = sha256_hex(&run(sample, dither, pal));
            let b = sha256_hex(&run(sample, dither, pal));
            assert_eq!(a, b, "{label}: two runs differ");
            assert_eq!(
                a, golden,
                "{label}: output differs from the committed golden"
            );
        }
    }

    /// D12 "Contract": the finish block's keys, the per-room native size, and
    /// the defaults (engine alpha, centre, none) for a spec without `finish`.
    #[test]
    fn pixel_finish_reads_the_family_finish_block_and_native_size() {
        let spec = serde_json::json!({
            "palette": { "locked": "art/palettes/gatekeeper.json" },
            "frame": { "native": { "perRoom": true, "plaza": { "width": 96, "height": 64, "pixelScale": 4 } } },
            "finish": { "alpha": { "source": "colour-key", "key": "#FF00FF", "tolerance": 8 },
                        "sample": "majority", "dither": "ordered-bayer4" }
        });
        let f = FamilyFinish::from_spec(&spec, Some("plaza")).unwrap();
        assert_eq!(f.palette_path, "art/palettes/gatekeeper.json");
        assert_eq!(
            (f.alpha.as_str(), f.key, f.tolerance),
            ("colour-key", Some([0xFF, 0, 0xFF]), 8)
        );
        assert_eq!(
            (f.sample, f.dither, f.native),
            (Sample::Majority, Dither::OrderedBayer4, (96, 64))
        );
        assert!(
            FamilyFinish::from_spec(&spec, None)
                .unwrap_err()
                .contains("per room")
        );
        assert!(FamilyFinish::from_spec(&spec, Some("cellar")).is_err());

        let plain = serde_json::json!({
            "palette": { "locked": "p.json" },
            "frame": { "native": { "width": 32, "height": 32, "pixelScale": 1 } }
        });
        let d = FamilyFinish::from_spec(&plain, None).unwrap();
        assert_eq!(
            (d.alpha.as_str(), d.sample, d.dither, d.native),
            ("engine", Sample::Centre, Dither::None, (32, 32))
        );
        let no_palette = serde_json::json!({ "frame": { "native": { "width": 1, "height": 1 } } });
        assert!(
            FamilyFinish::from_spec(&no_palette, None)
                .unwrap_err()
                .starts_with("family_has_no_locked_palette")
        );
        let bad = serde_json::json!({ "palette": { "locked": "p.json" }, "finish": { "native": { "width": 8, "height": 8 }, "dither": "floyd" } });
        assert!(
            FamilyFinish::from_spec(&bad, None)
                .unwrap_err()
                .contains("ordered-bayer4"),
            "error-diffusion is refused"
        );
    }

    #[test]
    fn pixel_finish_png_has_no_time_text_or_gamma_chunks() {
        let bytes = run(Sample::Centre, Dither::None, PALETTE);
        for chunk in [b"tIME", b"tEXt", b"iTXt", b"zTXt", b"gAMA"] {
            assert!(
                !bytes.windows(4).any(|w| w == chunk),
                "{} present",
                String::from_utf8_lossy(chunk)
            );
        }
    }

    const GOLDEN_CENTRE_NONE_RGBA: &str =
        "817c2a47927ae875040f3371503a362641222daf4c241ae73c6eebb03fe71f56";
    const GOLDEN_MAJORITY_BAYER_RGBA: &str =
        "f82c36a37891f1830044b6c287b0d9e68530736df757d7583b1362506534bea1";
    const GOLDEN_CENTRE_NONE_INDEXED: &str =
        "4e60f39f74b5e76c0083fe4b54697e8cd2a5cbfd371a7e0f73b7ae12f4ae2178";
}
