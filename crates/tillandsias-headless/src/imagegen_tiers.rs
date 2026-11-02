//! The imagegen tier LADDER (I0-I3) and the host's CEILING on it (order 1874-bair).
//!
//! Rows live in `images/imagegen/tiers.tsv`, declarative and read like
//! `images/inference/tiers/tier-table.tsv`. This module only reads them: it
//! never probes. The ceiling is computed from the one-line accel envelope
//! (`accel_probe::accel_envelope`, what a forge receives as
//! TILLANDSIAS_ACCEL_ENVELOPE), so there is no second hardware probe.
//!
//! SMALLEST FIRST (design.md section 3, operator 2026-10-25). Every host
//! STARTS at I0 whatever its hardware; `ceiling` only says how far up the
//! ladder a host may be OFFERED, one tier at a time (section 5, 1874-p8w7).
//! Nothing here picks a tier above I0 by default.
//!
//! LICENCES. Only permissive or open licences may appear in a row; the
//! fixture below refuses any row naming a revenue-capped or non-commercial
//! licence, and any model on the never-shippable list.
//!
//! @trace order:1874-bair (spec: openspec/changes/local-image-generation, not yet archived)
// The consumer (`image.generate`, 1874-kkrc) is not wired yet; until it is,
// only the tests read this module.
#![cfg_attr(not(test), allow(dead_code))]

const TIERS_TSV: &str = include_str!("../../../images/imagegen/tiers.tsv");

/// Licence ids a row may carry: permissive or open, no revenue cap, no
/// non-commercial term (operator ruling 2026-10-25).
pub const PERMISSIVE_LICENCES: &[&str] = &[
    "apache-2.0",
    "mit",
    "bsd-2-clause",
    "bsd-3-clause",
    "creativeml-openrail-m",
    "openrail++",
];

/// Never shippable, whatever a row's licence column claims (design.md section 3).
pub const NEVER_SHIPPABLE: &[&str] = &[
    "sd-turbo",
    "sdxl-turbo",
    "sd3.5",
    "flux.1-dev",
    "rmbg-1.4",
    "rmbg-2.0",
];

#[derive(Debug, Clone, PartialEq)]
pub struct TierRow {
    pub tier: String,
    /// A discrete GPU with at least this much VRAM may be offered this tier.
    pub min_vram_gb: Option<f64>,
    /// A unified-memory GPU (Apple) with at least this budget may be offered it.
    pub min_unified_gb: Option<f64>,
    /// A host with no usable GPU but at least this much RAM may be offered it.
    pub min_ram_gb: Option<f64>,
    pub model: String,
    pub licence: String,
    pub licence_source: String,
    pub size: u32,
    pub cpu_size: u32,
    pub steps: u32,
}

fn floor(cell: &str) -> Result<Option<f64>, String> {
    match cell {
        "-" => Ok(None),
        n => n
            .parse::<f64>()
            .map(Some)
            .map_err(|_| format!("not a number or '-': {n:?}")),
    }
}

fn whole(cell: &str) -> Result<u32, String> {
    cell.parse::<u32>()
        .map_err(|_| format!("not a whole number: {cell:?}"))
}

/// Parse a tiers.tsv body: `#` lines and blank lines are skipped, every other
/// line is ten TAB-separated cells.
pub fn parse_tiers(body: &str) -> Result<Vec<TierRow>, String> {
    let mut rows = Vec::new();
    for (i, line) in body.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != 10 {
            return Err(format!(
                "tiers.tsv line {}: {} cells, want 10",
                i + 1,
                c.len()
            ));
        }
        let at = |e: String| format!("tiers.tsv line {}: {e}", i + 1);
        rows.push(TierRow {
            tier: c[0].to_string(),
            min_vram_gb: floor(c[1]).map_err(at)?,
            min_unified_gb: floor(c[2]).map_err(at)?,
            min_ram_gb: floor(c[3]).map_err(at)?,
            model: c[4].to_string(),
            licence: c[5].to_string(),
            licence_source: c[6].to_string(),
            size: whole(c[7]).map_err(at)?,
            cpu_size: whole(c[8]).map_err(at)?,
            steps: whole(c[9]).map_err(at)?,
        });
    }
    Ok(rows)
}

/// The shipped ladder, smallest first.
pub fn ladder() -> Vec<TierRow> {
    parse_tiers(TIERS_TSV).expect("images/imagegen/tiers.tsv parses (fixture-checked)")
}

/// What the ceiling reads from the envelope. Every field comes from a key
/// `accel_envelope` emits; nothing is measured here.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct EnvelopeFacts {
    /// `accel_gpu=usable`: a GPU the container lane can actually reach.
    pub gpu_usable: bool,
    /// `accel_mem_model=unified`.
    pub unified: bool,
    /// `accel_mem_budget_gb`: the one side-scoped memory budget.
    pub mem_budget_gb: Option<f64>,
    /// `accel_ram_gb`.
    pub ram_gb: Option<f64>,
    /// `accel_vram_gb`, a discrete GPU's own memory. The probe does not emit
    /// it yet; without it a discrete GPU is offered nothing above what RAM
    /// alone earns, because a guessed VRAM figure is how a tier gets offered
    /// that the card cannot place.
    pub vram_gb: Option<f64>,
}

pub fn envelope_facts(envelope: &str) -> EnvelopeFacts {
    let get = |key: &str| {
        envelope
            .split_whitespace()
            .find_map(|kv| kv.strip_prefix(key).and_then(|r| r.strip_prefix('=')))
    };
    let num = |key: &str| get(key).and_then(|v| v.parse::<f64>().ok());
    EnvelopeFacts {
        gpu_usable: get("accel_gpu") == Some("usable"),
        unified: get("accel_mem_model") == Some("unified"),
        mem_budget_gb: num("accel_mem_budget_gb"),
        ram_gb: num("accel_ram_gb"),
        vram_gb: num("accel_vram_gb"),
    }
}

fn meets(row: &TierRow, f: &EnvelopeFacts) -> bool {
    let at_least =
        |have: Option<f64>, need: Option<f64>| matches!((have, need), (Some(h), Some(n)) if h >= n);
    if row.min_vram_gb.is_none() && row.min_unified_gb.is_none() && row.min_ram_gb.is_none() {
        return true; // the floor: every host
    }
    let gpu = f.gpu_usable
        && if f.unified {
            at_least(f.mem_budget_gb, row.min_unified_gb)
        } else {
            at_least(f.vram_gb, row.min_vram_gb)
        };
    gpu || at_least(f.ram_gb, row.min_ram_gb)
}

/// The highest tier this host may be OFFERED. Never the starting tier: every
/// request starts at the ladder's first row (`ladder()[0]`, I0).
pub fn ceiling<'a>(ladder: &'a [TierRow], envelope: &str) -> &'a TierRow {
    let f = envelope_facts(envelope);
    let mut top = &ladder[0];
    for row in ladder {
        if meets(row, &f) {
            top = row;
        } else {
            break; // a ladder: no skipping a rung
        }
    }
    top
}

/// 1957-8hkf: the next rung above `above` (a ladder index), up to and including
/// `upto`, that is installed or installable — i.e. has pinned files in
/// models.tsv. Unpinned rungs are skipped: an offer the host cannot honour is
/// a broken resource gate. `None` when no such rung exists.
pub fn next_offerable<'a>(
    ladder: &'a [TierRow],
    above: usize,
    upto: usize,
    manifest: &[crate::imagegen_models::ModelFile],
) -> Option<&'a TierRow> {
    ladder
        .iter()
        .enumerate()
        .skip(above + 1)
        .take_while(|(i, _)| *i <= upto)
        .map(|(_, t)| t)
        .find(|t| manifest.iter().any(|m| m.tier == t.tier))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tier(envelope: &str) -> String {
        ceiling(&ladder(), envelope).tier.clone()
    }

    /// The four envelopes of the exit criterion, as `accel_envelope` renders them.
    #[test]
    fn four_envelopes_classify_to_i0_through_i3() {
        assert_eq!(
            tier(
                "accel_class=cpu-only accel_gpu=none accel_ram_gb=8 accel_mem_model=no-gpu accel_mem_budget_gb=8"
            ),
            "I0"
        );
        assert_eq!(
            tier(
                "accel_class=cpu-only accel_gpu=none accel_ram_gb=32 accel_mem_model=no-gpu accel_mem_budget_gb=32"
            ),
            "I1"
        );
        assert_eq!(
            tier(
                "accel_class=workstation-gpu accel_gpu=usable accel_ram_gb=16 accel_mem_model=discrete accel_mem_budget_gb=16 accel_vram_gb=8"
            ),
            "I2"
        );
        assert_eq!(
            tier(
                "accel_class=workstation-gpu accel_gpu=usable accel_ram_gb=64 accel_mem_model=discrete accel_mem_budget_gb=64 accel_vram_gb=24"
            ),
            "I3"
        );
    }

    #[test]
    fn every_host_starts_at_i0() {
        let l = ladder();
        assert_eq!(l[0].tier, "I0");
        assert!(
            l[0].min_vram_gb.is_none()
                && l[0].min_unified_gb.is_none()
                && l[0].min_ram_gb.is_none()
        );
    }

    #[test]
    fn the_ladder_is_i0_to_i3_in_order() {
        let names: Vec<String> = ladder().into_iter().map(|r| r.tier).collect();
        assert_eq!(names, ["I0", "I1", "I2", "I3"]);
    }

    #[test]
    fn no_row_carries_a_non_permissive_licence_or_a_never_shippable_model() {
        for r in ladder() {
            assert!(
                PERMISSIVE_LICENCES.contains(&r.licence.as_str()),
                "{}: licence {:?} is not on the permissive list",
                r.tier,
                r.licence
            );
            assert!(
                r.licence_source.starts_with("https://"),
                "{}: licence has no source",
                r.tier
            );
            let m = r.model.to_ascii_lowercase();
            for bad in NEVER_SHIPPABLE {
                assert!(
                    !m.contains(bad),
                    "{}: {} is never shippable",
                    r.tier,
                    r.model
                );
            }
        }
    }

    /// The fixture must be able to fail: a non-commercial row is refused.
    #[test]
    fn negative_control_a_non_commercial_row_is_caught() {
        let rows = parse_tiers(
            "I0\t-\t-\t-\tflux.1-dev\tflux-1-dev-non-commercial\thttps://x\t1024\t768\t4\n",
        )
        .unwrap();
        assert!(!PERMISSIVE_LICENCES.contains(&rows[0].licence.as_str()));
        assert!(NEVER_SHIPPABLE.iter().any(|b| rows[0].model.contains(b)));
    }

    /// A usable discrete GPU whose VRAM the envelope does not state earns only
    /// what its RAM earns: no guessed VRAM.
    #[test]
    fn a_discrete_gpu_without_a_vram_figure_is_offered_only_what_ram_earns() {
        assert_eq!(
            tier(
                "accel_class=workstation-gpu accel_gpu=usable accel_ram_gb=8 accel_mem_model=discrete accel_mem_budget_gb=8"
            ),
            "I0"
        );
    }

    /// A GPU the container lane cannot reach is not a GPU for this purpose.
    #[test]
    fn a_present_unusable_gpu_earns_nothing() {
        assert_eq!(
            tier(
                "accel_class=cpu-only accel_gpu=present-unusable accel_ram_gb=8 accel_mem_model=discrete accel_vram_gb=24"
            ),
            "I0"
        );
    }

    /// Apple unified memory reads the one budget, never VRAM plus RAM.
    #[test]
    fn unified_memory_reads_the_one_budget() {
        let mac = |gb: u32| {
            tier(&format!(
                "accel_class=workstation-gpu accel_gpu=usable accel_ram_gb={gb} accel_mem_model=unified accel_mem_budget_gb={gb}"
            ))
        };
        assert_eq!(mac(8), "I0");
        assert_eq!(mac(16), "I2");
        assert_eq!(mac(32), "I3");
    }

    fn pins(tiers: &[&str]) -> Vec<crate::imagegen_models::ModelFile> {
        tiers
            .iter()
            .map(|t| crate::imagegen_models::ModelFile {
                tier: t.to_string(),
                role: "model".into(),
                repo: "r/r".into(),
                revision: "0".repeat(40),
                file: format!("{t}.safetensors"),
                sha256: "0".repeat(64),
                bytes: 2_500_000_000,
                licence: "apache-2.0".into(),
            })
            .collect()
    }

    /// 1957-8hkf verifiable closure. Pre-fix: FAILS (the next rung is offered
    /// whether or not anything is pinned for it).
    #[test]
    fn a_tier_without_pinned_files_is_never_offered() {
        let l = ladder();
        // I1 pinned, I2 not, I3 pinned: from I0 the offer is I1.
        let m = pins(&["I0", "I1", "I3"]);
        assert_eq!(
            next_offerable(&l, 0, 3, &m).map(|t| t.tier.as_str()),
            Some("I1")
        );
        // From I1 the unpinned I2 is skipped for the installable I3.
        assert_eq!(
            next_offerable(&l, 1, 3, &m).map(|t| t.tier.as_str()),
            Some("I3")
        );
        // Nothing pinned above: no offer at all.
        let m = pins(&["I0", "I1"]);
        assert_eq!(next_offerable(&l, 1, 3, &m), None);
        // Never above the cap (the host ceiling or the asked tier).
        let m = pins(&["I0", "I1", "I2", "I3"]);
        assert_eq!(next_offerable(&l, 1, 1, &m), None);
    }

    /// 1957-8hkf sibling: an installable offer says what it costs to fetch.
    #[cfg(feature = "host-services")]
    #[test]
    fn an_installable_offer_states_download_gb_and_minutes() {
        crate::imagegen_consent::reset_for_test();
        let l = ladder();
        let o = crate::imagegen_consent::offer("x/y", "req", &l[2], 9_907_763_780);
        let ask = o["ask"].as_str().unwrap();
        assert!(ask.contains("9.9 GB"), "size in GB: {ask}");
        assert!(ask.contains(" min"), "minutes: {ask}");
        assert_eq!(o["download_bytes"], 9_907_763_780u64);
    }
}
