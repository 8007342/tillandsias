//! Device catalogue and resolver (order 1643-q3at).
//!
//! "iphone 12 pro max", "galaxy s24 ultra", "xperia", "desktop landscape" →
//! one catalogue device with a fixed viewport, screen, dpr, engine and UA.
//!
//! The catalogue is `data/devices/catalogue.json`, built by
//! `scripts/lua/build-device-catalogue.lua` from vendored Playwright
//! (Apache-2.0) and Chrome DevTools (BSD-3-Clause) device lists plus a
//! hand-written manufacturer overlay; each device records its source and
//! licence. `viewport` is the PORTRAIT CSS screen for mobile devices and the
//! browser window for desktops.
//!
//! Resolution rules:
//! 1. Normalise: lowercase, `+` → plus, split glued tokens (`iphone12`),
//!    `s24u` → `s24 ultra`, brand synonyms (sony→xperia, google→pixel,
//!    samsung→galaxy). A trailing `landscape` swaps the dimensions (rule 6).
//! 2. An exact alias (or id) wins.
//! 3. Otherwise every requested token must be present; the fewest extra
//!    tokens wins, a modifier extra (pro, max, plus, ultra, mini, e, fold,
//!    flip, cover) always outweighing any other extra.
//! 4. A brand or family alone gives the newest base flagship by release date
//!    (never an e/mini/fold/flip/cover model).
//! 5. A tie, or a near miss inside a named brand, returns the best match plus
//!    alternatives, flagged as approximated. A match never changes brand, and
//!    a query that names no known brand and matches nothing is no match.
//!
//! @trace order:1643-q3at

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::sync::OnceLock;

const CATALOGUE_JSON: &str = include_str!("../data/devices/catalogue.json");

/// Width × height in CSS px (or physical px where the field says so).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
pub struct Size {
    pub w: u32,
    pub h: u32,
}

impl Size {
    fn swapped(self) -> Self {
        Size {
            w: self.h,
            h: self.w,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Os {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
pub struct Insets {
    pub top: u32,
    pub right: u32,
    pub bottom: u32,
    pub left: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SafeArea {
    pub portrait: Option<Insets>,
    pub landscape: Option<Insets>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Source {
    pub kind: String,
    pub url: String,
    pub license: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub derivation: Option<String>,
}

/// One catalogue device.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Device {
    pub id: String,
    pub brand: String,
    pub family: String,
    pub model: String,
    pub aliases: Vec<String>,
    #[serde(default)]
    pub released: Option<String>,
    #[serde(default)]
    pub flagship: bool,
    pub form: String,
    pub os: Os,
    pub engine: String,
    pub screen: Size,
    pub viewport: Size,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser_viewport: Option<Size>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen_px: Option<Size>,
    pub dpr: f64,
    pub ua: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ua_metadata: Option<serde_json::Value>,
    pub mobile: bool,
    pub touch: bool,
    pub max_touch_points: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub safe_area: Option<SafeArea>,
    pub source: Source,
}

#[derive(Debug, Deserialize)]
struct Catalogue {
    devices: Vec<Device>,
}

fn catalogue() -> &'static [Device] {
    static CAT: OnceLock<Catalogue> = OnceLock::new();
    &CAT.get_or_init(|| {
        serde_json::from_str(CATALOGUE_JSON).expect("embedded device catalogue is valid JSON")
    })
    .devices
}

/// Every catalogue device, sorted by id.
pub fn all() -> &'static [Device] {
    catalogue()
}

/// A resolved device in the requested orientation.
#[derive(Debug, Clone, Serialize)]
pub struct Resolution {
    pub query: String,
    pub id: String,
    pub model: String,
    pub brand: String,
    pub orientation: &'static str,
    pub viewport: Size,
    pub screen: Size,
    pub dpr: f64,
    pub engine: String,
    pub ua: String,
    pub mobile: bool,
    pub touch: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub safe_area: Option<Insets>,
    /// Which rule decided: alias | tokens | newest-flagship | near-miss.
    pub rule: &'static str,
    pub approximated: bool,
    pub alternatives: Vec<String>,
    pub device: Device,
}

const MODIFIERS: &[&str] = &[
    "pro", "max", "plus", "ultra", "mini", "e", "fold", "flip", "cover",
];
const NOT_BASE: &[&str] = &["e", "mini", "fold", "flip", "cover"];

/// Split one lowercase word into tokens: a letter run of two or more meets
/// digits (`iphone12` → iphone 12); digits meet letters (`16e` → 16 e). A
/// single letter before digits stays glued (`s24`, `a55`), which is how such
/// models are named.
fn split_word(word: &str) -> Vec<String> {
    let mut runs: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut cur_digit: Option<bool> = None;
    for c in word.chars() {
        let d = c.is_ascii_digit();
        if cur_digit.is_some_and(|cd| cd != d) {
            runs.push(std::mem::take(&mut cur));
        }
        cur.push(c);
        cur_digit = Some(d);
    }
    if !cur.is_empty() {
        runs.push(cur);
    }
    let mut out: Vec<String> = Vec::new();
    for run in runs {
        let is_digits = run.chars().all(|c| c.is_ascii_digit());
        if is_digits
            && let Some(last) = out.last_mut()
            && last.chars().count() == 1
            && last.chars().all(|c| c.is_ascii_alphabetic())
        {
            last.push_str(&run);
            continue;
        }
        out.push(run);
    }
    out
}

/// Rule 1. Returns (tokens, landscape).
fn normalise(query: &str) -> (Vec<String>, bool) {
    let lowered = query.to_lowercase().replace('+', " plus ");
    let cleaned: String = lowered
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect();
    let mut tokens = Vec::new();
    for word in cleaned.split_whitespace() {
        // s24u → s24 ultra (before splitting, so the u is not lost).
        if word.len() > 2
            && word.starts_with('s')
            && word.ends_with('u')
            && word[1..word.len() - 1].chars().all(|c| c.is_ascii_digit())
        {
            tokens.push(word[..word.len() - 1].to_string());
            tokens.push("ultra".to_string());
            continue;
        }
        tokens.extend(split_word(word));
    }
    let mut landscape = false;
    let tokens = tokens
        .into_iter()
        .filter(|t| {
            if t == "landscape" {
                landscape = true;
                false
            } else {
                t != "portrait"
            }
        })
        .map(|t| match t.as_str() {
            "sony" => "xperia".to_string(),
            "google" => "pixel".to_string(),
            "samsung" => "galaxy".to_string(),
            _ => t,
        })
        .collect();
    (tokens, landscape)
}

fn model_tokens(d: &Device) -> BTreeSet<String> {
    normalise(&d.model).0.into_iter().collect()
}

fn names_brand(token: &str, d: &Device) -> bool {
    token == d.brand || token == d.family
}

fn is_brand_token(token: &str) -> bool {
    catalogue().iter().any(|d| names_brand(token, d))
}

/// (modifier extras, other extras) beyond the query, brand/family excluded.
fn extras(d: &Device, query: &BTreeSet<String>) -> (usize, usize) {
    let mut m = 0;
    let mut o = 0;
    for t in model_tokens(d) {
        if query.contains(&t) || names_brand(&t, d) {
            continue;
        }
        if MODIFIERS.contains(&t.as_str()) {
            m += 1;
        } else {
            o += 1;
        }
    }
    (m, o)
}

fn released_key(d: &Device) -> &str {
    d.released.as_deref().unwrap_or("")
}

fn oriented(
    query: &str,
    d: &Device,
    landscape: bool,
    rule: &'static str,
    alts: Vec<String>,
) -> Resolution {
    let (viewport, screen) = if landscape {
        (d.viewport.swapped(), d.screen.swapped())
    } else {
        (d.viewport, d.screen)
    };
    let safe_area = d
        .safe_area
        .as_ref()
        .and_then(|s| if landscape { s.landscape } else { s.portrait });
    Resolution {
        query: query.to_string(),
        id: d.id.clone(),
        model: d.model.clone(),
        brand: d.brand.clone(),
        orientation: if landscape { "landscape" } else { "portrait" },
        viewport,
        screen,
        dpr: d.dpr,
        engine: d.engine.clone(),
        ua: d.ua.clone(),
        mobile: d.mobile,
        touch: d.touch,
        safe_area,
        rule,
        approximated: !alts.is_empty() || rule == "near-miss",
        alternatives: alts,
        device: d.clone(),
    }
}

/// Resolve a free-form device query. `None` is "no match", never a guess
/// from another brand.
pub fn resolve(query: &str) -> Option<Resolution> {
    let (tokens, landscape) = normalise(query);
    if tokens.is_empty() {
        return None;
    }
    let devices = catalogue();
    let joined = tokens.join(" ");

    // Rule 2: exact alias or id.
    if let Some(d) = devices.iter().find(|d| {
        d.id.replace('-', " ") == joined
            || d.aliases.iter().any(|a| normalise(a).0.join(" ") == joined)
    }) {
        return Some(oriented(query, d, landscape, "alias", Vec::new()));
    }

    let q: BTreeSet<String> = tokens.iter().cloned().collect();

    // Rule 4: a brand or family alone → its newest base flagship.
    if q.iter().all(|t| is_brand_token(t)) {
        let mut pool: Vec<&Device> = devices
            .iter()
            .filter(|d| q.iter().all(|t| names_brand(t, d)))
            .filter(|d| d.flagship && d.released.is_some())
            .filter(|d| {
                !model_tokens(d)
                    .iter()
                    .any(|t| NOT_BASE.contains(&t.as_str()))
            })
            .collect();
        pool.sort_by(|a, b| released_key(b).cmp(released_key(a)).then(a.id.cmp(&b.id)));
        if let Some(best) = pool.first() {
            return Some(oriented(
                query,
                best,
                landscape,
                "newest-flagship",
                Vec::new(),
            ));
        }
    }

    // Rule 3: every requested token present; fewest extras, modifiers first.
    let mut hits: Vec<(&Device, (usize, usize))> = devices
        .iter()
        .filter(|d| {
            let have = model_tokens(d);
            q.iter().all(|t| have.contains(t) || names_brand(t, d))
        })
        .map(|d| (d, extras(d, &q)))
        .collect();
    if !hits.is_empty() {
        hits.sort_by(|(a, ea), (b, eb)| {
            ea.cmp(eb)
                .then(released_key(b).cmp(released_key(a)))
                .then(a.id.cmp(&b.id))
        });
        let best_score = hits[0].1;
        let alts: Vec<String> = hits
            .iter()
            .skip(1)
            .filter(|(_, e)| *e == best_score)
            .take(4)
            .map(|(d, _)| d.id.clone())
            .collect();
        return Some(oriented(query, hits[0].0, landscape, "tokens", alts));
    }

    // Rule 5: a near miss, only inside ONE brand: the one the query named, or
    // the only brand whose models carry the query's model tokens (`s24` is
    // only ever a Galaxy). Otherwise no match.
    let brand_tokens: Vec<&String> = q.iter().filter(|t| is_brand_token(t)).collect();
    let implied: Option<String> = if brand_tokens.is_empty() {
        let brands: BTreeSet<&str> = devices
            .iter()
            .filter(|d| {
                let have = model_tokens(d);
                q.iter()
                    .any(|t| !MODIFIERS.contains(&t.as_str()) && have.contains(t))
            })
            .map(|d| d.brand.as_str())
            .collect();
        if brands.len() != 1 {
            return None;
        }
        brands.into_iter().next().map(str::to_string)
    } else {
        None
    };
    let mut near: Vec<(&Device, usize, (usize, usize))> = devices
        .iter()
        .filter(|d| match &implied {
            Some(b) => &d.brand == b,
            None => brand_tokens.iter().all(|t| names_brand(t, d)),
        })
        .map(|d| {
            let have = model_tokens(d);
            let missing = q
                .iter()
                .filter(|t| !have.contains(*t) && !names_brand(t, d))
                .count();
            (d, missing, extras(d, &q))
        })
        .collect();
    near.sort_by(|(a, ma, ea), (b, mb, eb)| {
        ma.cmp(mb)
            .then(ea.cmp(eb))
            .then(released_key(b).cmp(released_key(a)))
            .then(a.id.cmp(&b.id))
    });
    let best = near.first()?;
    let alts = near
        .iter()
        .skip(1)
        .take(4)
        .map(|(d, _, _)| d.id.clone())
        .collect();
    Some(oriented(query, best.0, landscape, "near-miss", alts))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(q: &str) -> Resolution {
        resolve(q).unwrap_or_else(|| panic!("{q:?} must resolve"))
    }

    #[test]
    fn iphone_12_pro_max_is_428x926_dpr3_webkit() {
        let m = r("iphone 12 pro max");
        assert_eq!(m.id, "apple-iphone-12-pro-max");
        assert_eq!(m.viewport, Size { w: 428, h: 926 });
        assert_eq!(m.screen, Size { w: 428, h: 926 });
        assert_eq!(m.dpr, 3.0);
        assert_eq!(m.engine, "webkit");
        assert_eq!(m.orientation, "portrait");
        assert!(!m.approximated);
    }

    #[test]
    fn iphone_alone_is_the_newest_iphone_flagship() {
        let m = r("iphone");
        assert_eq!(m.rule, "newest-flagship");
        let newest = all()
            .iter()
            .filter(|d| d.family == "iphone" && d.flagship)
            .filter_map(|d| d.released.clone())
            .max()
            .expect("dated iPhone flagships");
        assert_eq!(m.device.released.as_deref(), Some(newest.as_str()));
        assert_eq!(m.id, "apple-iphone-17");
    }

    #[test]
    fn iphone_12_and_12_pro_and_12_pro_max_are_three_models() {
        let a = r("iphone 12");
        let b = r("iphone 12 pro");
        let c = r("12 pro max");
        assert_eq!(a.id, "apple-iphone-12");
        assert_eq!(b.id, "apple-iphone-12-pro");
        assert_eq!(c.id, "apple-iphone-12-pro-max");
        assert!(a.viewport != c.viewport && b.id != c.id);
    }

    #[test]
    fn xperia_and_oneplus_resolve_through_the_overlay() {
        let x = r("xperia");
        assert_eq!(x.id, "sony-xperia-1-vi");
        assert_eq!(x.device.source.kind, "manufacturer-spec");
        assert_eq!(r("sony").id, "sony-xperia-1-vi");
        let o = r("oneplus");
        assert_eq!(o.id, "oneplus-13", "newest OnePlus flagship");
        assert_eq!(o.device.source.kind, "manufacturer-spec");
        assert_eq!(r("oneplus 12").id, "oneplus-12");
    }

    #[test]
    fn nonsense_is_no_match_and_a_near_miss_never_changes_brand() {
        assert!(resolve("blorp 9000").is_none());
        assert!(resolve("zzz").is_none());
        assert!(resolve("").is_none());
        let s = r("galaxy s24 ultra");
        assert_eq!(s.brand, "samsung");
        assert!(s.approximated, "no S24 Ultra in the data: approximated");
        assert_eq!(s.id, "samsung-galaxy-s24");
        assert!(s.alternatives.iter().all(|id| id.starts_with("samsung-")));
        let i = r("iphone 99 ultra");
        assert_eq!(i.brand, "apple");
        assert!(i.approximated);
    }

    #[test]
    fn normalisation_rules() {
        assert_eq!(r("iphone12").id, "apple-iphone-12");
        assert_eq!(r("iPhone 12 Pro+Max").id, "apple-iphone-12-pro-max");
        assert_eq!(r("galaxy s9+").id, "samsung-galaxy-s9-plus");
        assert_eq!(r("samsung s24").id, "samsung-galaxy-s24");
        assert_eq!(r("google").id, "google-pixel-10");
        let s = r("s24u");
        assert_eq!((s.brand.as_str(), s.approximated), ("samsung", true));
        assert!(
            resolve("9000 ultra").is_none(),
            "a modifier plus nonsense implies no brand"
        );
        assert_eq!(r("iphone 16e").id, "apple-iphone-16e");
        assert_eq!(r("desktop").id, "desktop-chrome");
        assert_eq!(r("desktop safari").engine, "webkit");
    }

    #[test]
    fn landscape_swaps_and_takes_the_landscape_safe_area() {
        let p = r("iphone 12 pro");
        let l = r("iphone 12 pro landscape");
        assert_eq!(l.orientation, "landscape");
        assert_eq!(
            l.viewport,
            Size {
                w: p.viewport.h,
                h: p.viewport.w
            }
        );
        assert_eq!(p.safe_area.expect("portrait insets").top, 47);
        assert_eq!(l.safe_area.expect("landscape insets").left, 47);
    }

    #[test]
    fn every_device_records_a_source_and_licence() {
        assert!(all().len() > 100);
        for d in all() {
            assert!(!d.source.license.is_empty(), "{} has no licence", d.id);
            assert!(!d.source.url.is_empty(), "{} has no source", d.id);
            assert!(
                d.viewport.w > 0 && d.viewport.h > 0 && d.dpr > 0.0,
                "{}",
                d.id
            );
        }
    }
}
