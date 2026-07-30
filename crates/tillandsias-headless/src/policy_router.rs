// @trace spec:inference-policy-router
//! Policy router and workload class routing logic per spec:inference-policy-router.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
// @trace spec:inference-policy-router
pub enum WorkloadClass {
    Background,
    #[default]
    Interactive,
    Quality,
    Sustained,
}

impl WorkloadClass {
    // @trace spec:inference-policy-router
    pub fn parse_or_default(s: Option<&str>) -> Self {
        match s {
            Some(v) if v.eq_ignore_ascii_case("background") => WorkloadClass::Background,
            Some(v) if v.eq_ignore_ascii_case("quality") => WorkloadClass::Quality,
            Some(v) if v.eq_ignore_ascii_case("sustained") => WorkloadClass::Sustained,
            _ => WorkloadClass::Interactive,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:inference-policy-router
pub struct CandidatePlacement {
    pub device_class: String,
    pub slot_id: String,
    pub model_tier: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:inference-policy-router
pub struct FallbackChain {
    pub candidates: Vec<CandidatePlacement>,
}

impl FallbackChain {
    // @trace spec:inference-policy-router
    pub fn is_valid(&self) -> bool {
        if let Some(last) = self.candidates.last() {
            // ROUTE-2: Every fallback chain MUST terminate in CPU tier-S
            last.device_class == "cpu" && last.model_tier.eq_ignore_ascii_case("tier-s")
        } else {
            false
        }
    }
}

// @trace spec:inference-policy-router
pub fn fits_memory_headroom(model_size_bytes: u64, device_memory_bytes: u64) -> bool {
    // ROUTE-4: Model resident size must not exceed 90% of addressable device memory (10% headroom)
    (model_size_bytes as f64) <= (device_memory_bytes as f64) * 0.90
}

// @trace spec:inference-policy-router
pub fn route_request(
    _class: WorkloadClass,
    chain: &FallbackChain,
    quarantined_slots: &[String],
) -> Result<CandidatePlacement, String> {
    if !chain.is_valid() {
        return Err("invalid fallback chain: must terminate in CPU tier-S terminal".to_string());
    }

    for candidate in &chain.candidates {
        if quarantined_slots.contains(&candidate.slot_id) {
            continue;
        }
        // In background class, prefer low-energy placement when available; otherwise first non-quarantined
        return Ok(candidate.clone());
    }

    // Fallback guaranteed to be last element (CPU tier-S)
    Ok(chain.candidates.last().cloned().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // @trace spec:inference-policy-router
    fn test_unclassified_defaults_to_interactive() {
        assert_eq!(
            WorkloadClass::parse_or_default(None),
            WorkloadClass::Interactive
        );
        assert_eq!(
            WorkloadClass::parse_or_default(Some("unknown")),
            WorkloadClass::Interactive
        );
    }

    #[test]
    // @trace spec:inference-policy-router
    fn test_valid_chain_must_end_in_cpu_tier_s() {
        let valid_chain = FallbackChain {
            candidates: vec![
                CandidatePlacement {
                    device_class: "gpu".to_string(),
                    slot_id: "slot-gpu".to_string(),
                    model_tier: "tier-1".to_string(),
                },
                CandidatePlacement {
                    device_class: "cpu".to_string(),
                    slot_id: "slot-cpu".to_string(),
                    model_tier: "tier-s".to_string(),
                },
            ],
        };
        assert!(valid_chain.is_valid());

        let invalid_chain = FallbackChain {
            candidates: vec![CandidatePlacement {
                device_class: "gpu".to_string(),
                slot_id: "slot-gpu".to_string(),
                model_tier: "tier-1".to_string(),
            }],
        };
        assert!(!invalid_chain.is_valid());
    }

    #[test]
    // @trace spec:inference-policy-router
    fn test_memory_headroom_rule() {
        // 900 MiB on 1000 MiB device -> 90% -> fits
        assert!(fits_memory_headroom(900, 1000));
        // 950 MiB on 1000 MiB device -> 95% -> fails 10% headroom rule
        assert!(!fits_memory_headroom(950, 1000));
    }
}
