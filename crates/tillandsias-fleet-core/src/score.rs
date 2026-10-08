//! Host score: measured availability class first, then buckets, so a
//! transient laptop never outranks an always-on host (operator ruling 3).
//!
//! @trace plan:1548-dylo

use serde::Deserialize;
use std::cmp::Ordering;
use std::collections::BTreeMap;

/// Seconds between heartbeats (operator ruling 4).
pub const HEARTBEAT_SECS: u64 = 900;
/// Seconds a lease stays live without renewal.
pub const LEASE_TTL_SECS: u64 = 3600;
/// Continuous presence required before a host is eligible: 4 h.
pub const MIN_PRESENCE_SECS: u64 = 4 * 3600;
/// Fifteen-minute slots in 7 days.
pub const SLOTS_7D: u32 = 672;
/// Observation needed before any class above 0: 24 h.
pub const OBSERVATION_MIN_SECS: u64 = 24 * 3600;

/// Availability class: 0 transient, 1 usually-on, 2 always-on.
pub type Class = u8;

/// `class_measured` from presence slots out of [`SLOTS_7D`] and how long
/// the host has been observed. 0 before 24 h observed.
pub fn class_measured(present_slots: u32, observed_secs: u64) -> Class {
    if observed_secs < OBSERVATION_MIN_SECS {
        return 0;
    }
    let present = present_slots.min(SLOTS_7D) as u64;
    // availability >= 0.95  <=>  present * 100 >= 95 * 672 (integer, exact).
    let total = SLOTS_7D as u64;
    if present * 100 >= 95 * total {
        2
    } else if present * 100 >= 60 * total {
        1
    } else {
        0
    }
}

/// `class_effective = min(declared, measured)`; declaring never helps.
pub fn class_effective(declared: Class, measured: Class) -> Class {
    declared.min(measured)
}

/// Reachability bucket from the round-trip time in ms (`None` = unreachable).
/// Higher is better; jitter inside a bucket never changes the bucket.
pub fn reach_bucket(rtt_ms: Option<u32>) -> u8 {
    match rtt_ms {
        None => 0,
        Some(r) if r <= 20 => 3,
        Some(r) if r <= 100 => 2,
        Some(_) => 1,
    }
}

/// Bare metal outranks a guest.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Substrate {
    Guest,
    Bare,
}

/// Everything the score reads about a host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostAttrs {
    pub host: String,
    pub class_declared: Class,
    pub present_slots: u32,
    pub observed_secs: u64,
    pub rtt_ms: Option<u32>,
    pub substrate: Substrate,
    pub ram_gib: u32,
    pub disk_free_gib: u32,
    pub fedora_family: bool,
}

/// `floor(log2 x)`, with 0 for x <= 1 (and for 0, which has no log).
pub fn log2_floor(x: u32) -> u8 {
    if x <= 1 {
        0
    } else {
        (31 - x.leading_zeros()) as u8
    }
}

/// The score tuple; larger fields are better, host id is the final tiebreak
/// (the lexicographically smaller id wins, handled in [`rank`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Score {
    pub class_effective: Class,
    pub reach_bucket: u8,
    pub substrate: u8,
    pub ram_log2: u8,
    pub disk_log2: u8,
    pub os: u8,
    pub host: String,
}

/// Derive the score tuple for a host.
pub fn score(a: &HostAttrs) -> Score {
    let measured = class_measured(a.present_slots, a.observed_secs);
    Score {
        class_effective: class_effective(a.class_declared, measured),
        reach_bucket: reach_bucket(a.rtt_ms),
        substrate: match a.substrate {
            Substrate::Bare => 2,
            Substrate::Guest => 1,
        },
        ram_log2: log2_floor(a.ram_gib),
        disk_log2: log2_floor(a.disk_free_gib),
        os: u8::from(a.fedora_family),
        host: a.host.clone(),
    }
}

/// Total order, best first: `Less` means `a` outranks `b`.
pub fn rank(a: &Score, b: &Score) -> Ordering {
    (
        b.class_effective,
        b.reach_bucket,
        b.substrate,
        b.ram_log2,
        b.disk_log2,
        b.os,
    )
        .cmp(&(
            a.class_effective,
            a.reach_bucket,
            a.substrate,
            a.ram_log2,
            a.disk_log2,
            a.os,
        ))
        .then_with(|| a.host.cmp(&b.host))
}

/// Sort hosts best first. Total and stable: the host id is part of the
/// order, so no two distinct hosts tie.
pub fn order(hosts: &[HostAttrs]) -> Vec<String> {
    let mut s: Vec<Score> = hosts.iter().map(score).collect();
    s.sort_by(rank);
    s.into_iter().map(|x| x.host).collect()
}

/// One service row of `plan/fleet/services.yaml`.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ServiceAffinity {
    #[serde(default)]
    pub preferred: Vec<String>,
    #[serde(default = "any")]
    pub eligible: String,
    pub min_presence: String,
}

fn any() -> String {
    "any".to_string()
}

#[derive(Debug, Deserialize)]
struct ServicesFile {
    services: BTreeMap<String, ServiceAffinity>,
}

/// Parse `plan/fleet/services.yaml` text.
pub fn parse_services(yaml: &str) -> Result<BTreeMap<String, ServiceAffinity>, String> {
    serde_yaml::from_str::<ServicesFile>(yaml)
        .map(|f| f.services)
        .map_err(|e| e.to_string())
}

/// `"4h"`, `"30m"`, `"90s"` to seconds.
pub fn parse_duration_secs(s: &str) -> Result<u64, String> {
    let s = s.trim();
    let (num, unit) = s.split_at(s.len().saturating_sub(1));
    let n: u64 = num.parse().map_err(|_| format!("bad duration: {s}"))?;
    match unit {
        "h" => Ok(n * 3600),
        "m" => Ok(n * 60),
        "s" => Ok(n),
        _ => Err(format!("bad duration unit: {s}")),
    }
}

#[cfg(test)]
mod score_tests {
    use super::*;

    /// xorshift64; deterministic, no dependency.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545F4914F6CDD1D)
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    fn random_host(r: &mut Rng, i: usize) -> HostAttrs {
        HostAttrs {
            host: format!("h{i:03}"),
            class_declared: r.below(3) as u8,
            present_slots: r.below(673) as u32,
            observed_secs: r.below(10 * 86400),
            rtt_ms: if r.below(8) == 0 {
                None
            } else {
                Some(r.below(400) as u32)
            },
            substrate: if r.below(2) == 0 {
                Substrate::Guest
            } else {
                Substrate::Bare
            },
            ram_gib: 1 + r.below(256) as u32,
            disk_free_gib: r.below(4096) as u32,
            fedora_family: r.below(2) == 0,
        }
    }

    #[test]
    fn score_class_zero_never_outranks_class_two() {
        let mut r = Rng(0x9E3779B97F4A7C15);
        let mut saw_pair = 0u32;
        for _ in 0..10_000 {
            let n = 2 + r.below(6) as usize;
            let hosts: Vec<HostAttrs> = (0..n).map(|i| random_host(&mut r, i)).collect();
            let scores: Vec<Score> = hosts.iter().map(score).collect();
            for a in &scores {
                for b in &scores {
                    if a.class_effective == 0 && b.class_effective == 2 {
                        saw_pair += 1;
                        assert_eq!(rank(a, b), Ordering::Greater, "class 0 outranked class 2");
                    }
                }
            }
        }
        assert!(
            saw_pair > 0,
            "premise: the generator must produce class-0/class-2 pairs"
        );
    }

    #[test]
    fn score_transient_laptop_with_more_ram_never_outranks_always_on() {
        let always_on = HostAttrs {
            host: "macuahuitl".into(),
            class_declared: 2,
            present_slots: 672,
            observed_secs: 7 * 86400,
            rtt_ms: Some(150),
            substrate: Substrate::Guest,
            ram_gib: 2,
            disk_free_gib: 1,
            fedora_family: false,
        };
        let mut r = Rng(7);
        for i in 0..10_000 {
            let mut laptop = random_host(&mut r, i);
            laptop.host = "laptop".into();
            laptop.class_declared = 2; // declares the best, measures worse
            laptop.present_slots = r.below(403) as u32; // < 0.60: class 0
            laptop.observed_secs = 7 * 86400;
            laptop.ram_gib = 64 + r.below(1024) as u32;
            laptop.substrate = Substrate::Bare;
            laptop.rtt_ms = Some(1);
            let o = order(&[laptop.clone(), always_on.clone()]);
            assert_eq!(
                o[0], "macuahuitl",
                "laptop {laptop:?} outranked the always-on host"
            );
        }
    }

    #[test]
    fn score_class_effective_is_min_of_declared_and_measured() {
        for declared in 0..=2u8 {
            for slots in [0u32, 100, 403, 404, 500, 638, 639, 672] {
                for observed in [0u64, 86399, 86400, 7 * 86400] {
                    let m = class_measured(slots, observed);
                    assert_eq!(class_effective(declared, m), declared.min(m));
                    assert!(class_effective(declared, m) <= declared);
                    assert!(class_effective(declared, m) <= m);
                }
            }
        }
    }

    #[test]
    fn score_declared_two_with_half_availability_scores_as_class_zero() {
        let h = HostAttrs {
            host: "x".into(),
            class_declared: 2,
            present_slots: 336, // 0.5
            observed_secs: 7 * 86400,
            rtt_ms: Some(5),
            substrate: Substrate::Bare,
            ram_gib: 8,
            disk_free_gib: 100,
            fedora_family: true,
        };
        assert_eq!(score(&h).class_effective, 0);
    }

    #[test]
    fn score_class_measured_thresholds_and_observation_floor() {
        assert_eq!(class_measured(672, 86399), 0, "0 before 24 h observed");
        assert_eq!(class_measured(672, 86400), 2);
        assert_eq!(class_measured(639, 86400), 2); // 639/672 = 0.9509
        assert_eq!(class_measured(638, 86400), 1); // 0.9494
        assert_eq!(class_measured(404, 86400), 1); // 0.6012
        assert_eq!(class_measured(403, 86400), 0); // 0.5997
    }

    #[test]
    fn score_bucketing_means_jitter_never_reorders() {
        let mut r = Rng(42);
        for _ in 0..10_000 {
            let n = 2 + r.below(6) as usize;
            let hosts: Vec<HostAttrs> = (0..n).map(|k| random_host(&mut r, k)).collect();
            let before = order(&hosts);
            let jittered: Vec<HostAttrs> = hosts
                .iter()
                .map(|h| {
                    let mut j = h.clone();
                    if let Some(rtt) = h.rtt_ms {
                        let b = reach_bucket(Some(rtt));
                        let (lo, hi) = match b {
                            3 => (0, 20),
                            2 => (21, 100),
                            _ => (101, 400),
                        };
                        j.rtt_ms = Some(lo + r.below((hi - lo + 1) as u64) as u32);
                        assert_eq!(reach_bucket(j.rtt_ms), b);
                    }
                    j
                })
                .collect();
            assert_eq!(order(&jittered), before);
        }
    }

    #[test]
    fn score_ordering_is_total_and_stable() {
        let mut r = Rng(1234);
        for _ in 0..2_000 {
            let n = 2 + r.below(8) as usize;
            let hosts: Vec<HostAttrs> = (0..n).map(|i| random_host(&mut r, i)).collect();
            let scores: Vec<Score> = hosts.iter().map(score).collect();
            for a in &scores {
                assert_eq!(rank(a, a), Ordering::Equal);
                for b in &scores {
                    assert_eq!(rank(a, b), rank(b, a).reverse());
                    if a.host != b.host {
                        assert_ne!(rank(a, b), Ordering::Equal);
                    }
                    for c in &scores {
                        if rank(a, b) != Ordering::Greater && rank(b, c) != Ordering::Greater {
                            assert_ne!(rank(a, c), Ordering::Greater, "not transitive");
                        }
                    }
                }
            }
            let mut rev = hosts.clone();
            rev.reverse();
            assert_eq!(order(&hosts), order(&rev), "input order changed the result");
        }
    }

    #[test]
    fn score_log2_floor_values() {
        assert_eq!(log2_floor(0), 0);
        assert_eq!(log2_floor(1), 0);
        assert_eq!(log2_floor(2), 1);
        assert_eq!(log2_floor(3), 1);
        assert_eq!(log2_floor(64), 6);
        assert_eq!(log2_floor(127), 6);
    }

    #[test]
    fn score_services_yaml_prefers_macuahuitl_with_four_hours() {
        let yaml = include_str!("../../../plan/fleet/services.yaml");
        let s = parse_services(yaml).expect("services.yaml parses");
        for svc in ["git-mirror", "local-experts"] {
            let row = s.get(svc).unwrap_or_else(|| panic!("{svc} missing"));
            assert_eq!(row.preferred, vec!["macuahuitl".to_string()]);
            assert_eq!(row.eligible, "any");
            assert_eq!(
                parse_duration_secs(&row.min_presence),
                Ok(MIN_PRESENCE_SECS)
            );
        }
        assert!(s.get("status").expect("status").preferred.is_empty());
    }
}
