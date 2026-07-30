// @trace spec:inference-policy-router
//! Pure, data-driven inference placement policy.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Default)]
#[serde(rename_all = "lowercase")]
// @trace spec:inference-policy-router
pub enum WorkloadClass {
    Background,
    #[default]
    Interactive,
    Quality,
    Sustained,
}

impl WorkloadClass {
    pub const ALL: [Self; 4] = [
        Self::Background,
        Self::Interactive,
        Self::Quality,
        Self::Sustained,
    ];

    // @trace spec:inference-policy-router
    pub fn parse_or_default(value: Option<&str>) -> Self {
        match value {
            Some(value) if value.eq_ignore_ascii_case("background") => Self::Background,
            Some(value) if value.eq_ignore_ascii_case("quality") => Self::Quality,
            Some(value) if value.eq_ignore_ascii_case("sustained") => Self::Sustained,
            _ => Self::Interactive,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Background => "background",
            Self::Interactive => "interactive",
            Self::Quality => "quality",
            Self::Sustained => "sustained",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
// @trace spec:inference-policy-router
pub struct CandidatePlacement {
    pub device_id: String,
    pub device_class: String,
    pub slot_id: String,
    pub model_tier: String,
}

impl CandidatePlacement {
    fn is_cpu_tier_s(&self) -> bool {
        self.device_class.eq_ignore_ascii_case("cpu")
            && self.model_tier.eq_ignore_ascii_case("tier-s")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
// @trace spec:inference-policy-router
pub struct FallbackChain {
    pub candidates: Vec<CandidatePlacement>,
}

impl FallbackChain {
    // @trace spec:inference-policy-router
    pub fn validate(&self) -> Result<(), String> {
        match self.candidates.last() {
            Some(last) if last.is_cpu_tier_s() => Ok(()),
            _ => Err(
                "invalid fallback chain: final candidate must be the CPU tier-S terminal"
                    .to_string(),
            ),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
// @trace spec:inference-policy-router
pub struct RoutingTable {
    pub version: u32,
    pub classes: BTreeMap<String, FallbackChain>,
}

impl RoutingTable {
    // @trace spec:inference-policy-router
    pub fn parse_toml(input: &str) -> Result<Self, String> {
        let table: Self =
            toml::from_str(input).map_err(|error| format!("invalid routing TOML: {error}"))?;
        table.validate()?;
        Ok(table)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version != 1 {
            return Err(format!(
                "unsupported inference policy table version {}",
                self.version
            ));
        }

        let expected = WorkloadClass::ALL
            .into_iter()
            .map(|class| class.as_str())
            .collect::<BTreeSet<_>>();
        let actual = self
            .classes
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        if actual != expected {
            return Err(format!(
                "routing table must define exactly background, interactive, quality, sustained; got {}",
                actual.into_iter().collect::<Vec<_>>().join(",")
            ));
        }

        for (class, chain) in &self.classes {
            chain
                .validate()
                .map_err(|error| format!("{class}: {error}"))?;
        }
        Ok(())
    }

    fn chain(&self, class: WorkloadClass) -> Result<&FallbackChain, String> {
        self.classes
            .get(class.as_str())
            .ok_or_else(|| format!("routing table has no {} chain", class.as_str()))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:inference-policy-router
pub struct PlacementFacts {
    pub placement: CandidatePlacement,
    pub usable: bool,
    pub unusable_reason: Option<String>,
    pub device_memory_bytes: u64,
    pub model_resident_bytes: u64,
    pub context_ceiling: Option<u32>,
    pub resident: bool,
    pub degraded: bool,
    pub measured_joules_per_token: Option<f64>,
    pub measured_ttft_ms: Option<f64>,
    pub measured_sustained_tps: Option<f64>,
    pub measured_capability_score: Option<f64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
// @trace spec:inference-policy-router
pub struct SignalSnapshot {
    pub on_ac: bool,
    pub thermal_nominal: bool,
    pub power_saver: bool,
}

impl Default for SignalSnapshot {
    fn default() -> Self {
        Self {
            on_ac: true,
            thermal_nominal: true,
            power_saver: false,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
// @trace spec:inference-policy-router
pub struct ModelRequest {
    pub context_tokens: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
// @trace spec:inference-policy-router
pub struct PlacementKey {
    pub device_id: String,
    pub slot_id: String,
}

impl From<&CandidatePlacement> for PlacementKey {
    fn from(placement: &CandidatePlacement) -> Self {
        Self {
            device_id: placement.device_id.clone(),
            slot_id: placement.slot_id.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:inference-policy-router
pub struct RoutingDecision {
    pub selected: CandidatePlacement,
    pub preferred_loading: Option<CandidatePlacement>,
    pub reason: String,
    pub signals: SignalSnapshot,
}

// @trace spec:inference-policy-router
pub fn fits_memory_headroom(model_size_bytes: u64, device_memory_bytes: u64) -> bool {
    device_memory_bytes > 0
        && u128::from(model_size_bytes) * 10 <= u128::from(device_memory_bytes) * 9
}

fn is_small_resident_tier(tier: &str) -> bool {
    ["tier-s", "t0", "t1"]
        .iter()
        .any(|small| tier.eq_ignore_ascii_case(small))
}

fn metric_order(class: WorkloadClass, left: &PlacementFacts, right: &PlacementFacts) -> Ordering {
    fn ascending(left: Option<f64>, right: Option<f64>) -> Ordering {
        match (left, right) {
            (Some(left), Some(right)) => left.total_cmp(&right),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        }
    }

    fn descending(left: Option<f64>, right: Option<f64>) -> Ordering {
        ascending(right, left)
    }

    match class {
        WorkloadClass::Background => ascending(
            left.measured_joules_per_token,
            right.measured_joules_per_token,
        ),
        WorkloadClass::Interactive => ascending(left.measured_ttft_ms, right.measured_ttft_ms),
        WorkloadClass::Quality => descending(
            left.measured_capability_score,
            right.measured_capability_score,
        ),
        WorkloadClass::Sustained => {
            descending(left.measured_sustained_tps, right.measured_sustained_tps)
        }
    }
}

fn decision_reason(class: WorkloadClass, facts: &PlacementFacts) -> String {
    let metric = match class {
        WorkloadClass::Background => facts
            .measured_joules_per_token
            .map(|value| format!("measured-joules-per-token={value}")),
        WorkloadClass::Interactive => facts
            .measured_ttft_ms
            .map(|value| format!("measured-ttft-ms={value}")),
        WorkloadClass::Quality => facts
            .measured_capability_score
            .map(|value| format!("measured-capability-score={value}")),
        WorkloadClass::Sustained => facts
            .measured_sustained_tps
            .map(|value| format!("measured-sustained-tps={value}")),
    }
    .unwrap_or_else(|| "table-order:no-measurement".to_string());
    format!("class={} {metric}", class.as_str())
}

/// Pure decision boundary. Loading the TOML table and collecting capability or
/// power signals happen outside this function; identical inputs always produce
/// the same placement.
// @trace spec:inference-policy-router
pub fn route_request(
    class: WorkloadClass,
    table: &RoutingTable,
    facts: &[PlacementFacts],
    signals: SignalSnapshot,
    request: ModelRequest,
    quarantined: &BTreeSet<PlacementKey>,
) -> Result<RoutingDecision, String> {
    let chain = table.chain(class)?;
    chain.validate()?;

    let mut viable = Vec::new();
    for (table_index, candidate) in chain.candidates.iter().enumerate() {
        let Some(candidate_facts) = facts.iter().find(|facts| facts.placement == *candidate) else {
            continue;
        };
        if !candidate_facts.usable
            || quarantined.contains(&PlacementKey::from(candidate))
            || !fits_memory_headroom(
                candidate_facts.model_resident_bytes,
                candidate_facts.device_memory_bytes,
            )
            || candidate_facts
                .context_ceiling
                .is_some_and(|ceiling| request.context_tokens > ceiling)
        {
            continue;
        }
        viable.push((table_index, candidate_facts));
    }

    if viable.is_empty() {
        return Err("no viable placement, including the CPU tier-S terminal".to_string());
    }

    if viable.iter().any(|(_, facts)| !facts.degraded) {
        viable.retain(|(_, facts)| !facts.degraded);
    }
    viable.sort_by(|(left_index, left), (right_index, right)| {
        metric_order(class, left, right).then_with(|| left_index.cmp(right_index))
    });

    let preferred = viable[0].1;
    let mut selected = preferred;
    let mut preferred_loading = None;
    if !preferred.resident
        && let Some((_, resident_small)) = viable.iter().find(|(_, facts)| {
            facts.resident && is_small_resident_tier(&facts.placement.model_tier)
        })
    {
        selected = resident_small;
        preferred_loading = Some(preferred.placement.clone());
    }

    Ok(RoutingDecision {
        selected: selected.placement.clone(),
        preferred_loading,
        reason: decision_reason(class, selected),
        signals,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT_TABLE: &str = include_str!("../../../images/inference/policy-router.toml");

    fn facts(placement: CandidatePlacement, resident: bool, joules: Option<f64>) -> PlacementFacts {
        PlacementFacts {
            placement,
            usable: true,
            unusable_reason: None,
            device_memory_bytes: 10_000,
            model_resident_bytes: 5_000,
            context_ceiling: Some(32_768),
            resident,
            degraded: false,
            measured_joules_per_token: joules,
            measured_ttft_ms: joules,
            measured_sustained_tps: joules.map(|value| 100.0 - value),
            measured_capability_score: joules.map(|value| 100.0 - value),
        }
    }

    #[test]
    // @trace spec:inference-policy-router
    fn unclassified_defaults_to_interactive() {
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
    fn default_toml_defines_exactly_four_valid_chains() {
        let table = RoutingTable::parse_toml(DEFAULT_TABLE).expect("default table");
        assert_eq!(table.classes.len(), 4);
        for class in WorkloadClass::ALL {
            assert!(
                table
                    .chain(class)
                    .expect("class chain")
                    .candidates
                    .last()
                    .expect("terminal")
                    .is_cpu_tier_s()
            );
        }
    }

    #[test]
    // @trace spec:inference-policy-router
    fn table_without_cpu_tier_s_is_rejected_at_load() {
        let invalid = DEFAULT_TABLE.replace("model_tier = \"tier-s\"", "model_tier = \"t1\"");
        let error = RoutingTable::parse_toml(&invalid).expect_err("missing terminal must fail");
        assert!(error.contains("CPU tier-S terminal"), "{error}");
    }

    #[test]
    // @trace spec:inference-policy-router
    fn memory_headroom_uses_exact_integer_boundary() {
        assert!(fits_memory_headroom(900, 1000));
        assert!(!fits_memory_headroom(901, 1000));
        assert!(!fits_memory_headroom(0, 0));
        assert!(fits_memory_headroom(u64::MAX / 2, u64::MAX));
    }

    #[test]
    // @trace spec:inference-policy-router
    fn serialized_facts_drive_energy_choice_and_degraded_lane_loses() {
        let table = RoutingTable::parse_toml(DEFAULT_TABLE).expect("default table");
        let chain = table.chain(WorkloadClass::Background).expect("chain");
        let gpu = chain.candidates[0].clone();
        let cpu = chain.candidates[1].clone();
        let serialized = serde_json::to_string(&vec![
            facts(gpu.clone(), true, Some(4.0)),
            facts(cpu.clone(), true, Some(2.0)),
        ])
        .expect("serialize fixture");
        let parsed: Vec<PlacementFacts> =
            serde_json::from_str(&serialized).expect("deserialize fixture");
        let decision = route_request(
            WorkloadClass::Background,
            &table,
            &parsed,
            SignalSnapshot::default(),
            ModelRequest {
                context_tokens: 4096,
            },
            &BTreeSet::new(),
        )
        .expect("route");
        assert_eq!(decision.selected, cpu);
        assert!(decision.reason.contains("measured-joules-per-token=2"));

        let mut degraded_cpu = parsed;
        degraded_cpu[1].degraded = true;
        let decision = route_request(
            WorkloadClass::Background,
            &table,
            &degraded_cpu,
            SignalSnapshot::default(),
            ModelRequest {
                context_tokens: 4096,
            },
            &BTreeSet::new(),
        )
        .expect("route");
        assert_eq!(decision.selected, gpu);
    }

    #[test]
    // @trace spec:inference-policy-router
    fn all_four_classes_select_by_their_declared_measured_objective() {
        let table = RoutingTable::parse_toml(DEFAULT_TABLE).expect("default table");
        for (class, expected_index, reason_field) in [
            (WorkloadClass::Background, 1, "measured-joules-per-token"),
            (WorkloadClass::Interactive, 0, "measured-ttft-ms"),
            (WorkloadClass::Quality, 1, "measured-capability-score"),
            (WorkloadClass::Sustained, 0, "measured-sustained-tps"),
        ] {
            let chain = table.chain(class).expect("class chain");
            let mut first = facts(chain.candidates[0].clone(), true, None);
            let mut second = facts(chain.candidates[1].clone(), true, None);
            match class {
                WorkloadClass::Background => {
                    first.measured_joules_per_token = Some(5.0);
                    second.measured_joules_per_token = Some(1.0);
                }
                WorkloadClass::Interactive => {
                    first.measured_ttft_ms = Some(1.0);
                    second.measured_ttft_ms = Some(10.0);
                }
                WorkloadClass::Quality => {
                    first.measured_capability_score = Some(10.0);
                    second.measured_capability_score = Some(20.0);
                }
                WorkloadClass::Sustained => {
                    first.measured_sustained_tps = Some(100.0);
                    second.measured_sustained_tps = Some(20.0);
                }
            }
            let serialized =
                serde_json::to_string(&vec![first, second]).expect("serialize fixture");
            let parsed: Vec<PlacementFacts> =
                serde_json::from_str(&serialized).expect("deserialize fixture");
            let decision = route_request(
                class,
                &table,
                &parsed,
                SignalSnapshot::default(),
                ModelRequest {
                    context_tokens: 4096,
                },
                &BTreeSet::new(),
            )
            .expect("route");
            assert_eq!(decision.selected, chain.candidates[expected_index]);
            assert!(
                decision.reason.contains(reason_field),
                "{}",
                decision.reason
            );
        }
    }

    #[test]
    // @trace spec:inference-policy-router
    fn oversize_and_context_ceiling_advance_to_cpu_terminal() {
        let table = RoutingTable::parse_toml(DEFAULT_TABLE).expect("default table");
        let chain = table.chain(WorkloadClass::Interactive).expect("chain");
        let mut gpu = facts(chain.candidates[0].clone(), true, Some(1.0));
        gpu.model_resident_bytes = 9_001;
        gpu.context_ceiling = Some(2048);
        let cpu = facts(chain.candidates[1].clone(), true, Some(10.0));
        let decision = route_request(
            WorkloadClass::Interactive,
            &table,
            &[gpu, cpu.clone()],
            SignalSnapshot::default(),
            ModelRequest {
                context_tokens: 4096,
            },
            &BTreeSet::new(),
        )
        .expect("CPU terminal serves");
        assert_eq!(decision.selected, cpu.placement);
    }

    #[test]
    // @trace spec:inference-policy-router
    fn cold_preferred_uses_resident_small_model_without_switching_in_flight() {
        let table = RoutingTable::parse_toml(DEFAULT_TABLE).expect("default table");
        let chain = table.chain(WorkloadClass::Quality).expect("chain");
        let preferred = facts(chain.candidates[0].clone(), false, Some(1.0));
        let resident = facts(chain.candidates[1].clone(), true, Some(10.0));
        let decision = route_request(
            WorkloadClass::Quality,
            &table,
            &[preferred.clone(), resident.clone()],
            SignalSnapshot::default(),
            ModelRequest {
                context_tokens: 4096,
            },
            &BTreeSet::new(),
        )
        .expect("resident fallback");
        assert_eq!(decision.selected, resident.placement);
        assert_eq!(decision.preferred_loading, Some(preferred.placement));
    }
}
