// @trace spec:accel-capability-probe
//! Structured hardware capability probe (CPU, GPU, NPU, memory bandwidth)
//! replacing single-string inference tier detection.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Schema version for capabilities.json per spec:accel-capability-probe
///
/// 2 (order 808-43mw) adds host identity to `HostInfo` and workload/locus
/// labels to `MeasurementRecord`. Bumped rather than added silently because
/// `load_or_probe` uses this to decide a cached document is still describable
/// — a v1 cache has no `host_id`, and re-probing is cheaper than reasoning
/// about a document that cannot name itself.
///
/// 3 (order 793-qr4t/793-qc6q) adds `HostInfo::side` — which SIDE of which
/// boundary the probe ran on — and the model dimension on
/// `MeasurementRecord`. Same reasoning as 2, and sharper: a v2 document has
/// no side, so every device it reports is unqualified, and the envelope
/// cannot distinguish "no NPU here" from "the NPU is on the other side of a
/// VM boundary". Serving that from cache would republish the exact confusion
/// 793-qr4t exists to end.
pub const SCHEMA_VERSION: u32 = 3;

/// Derived document describing host execution devices, engine availability, and measurements.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct CapabilityDocument {
    pub schema_version: u32,
    pub legacy_tier: String,
    pub devices: Vec<DeviceRecord>,
    pub engines: Vec<EngineRecord>,
    pub measurements: Vec<MeasurementRecord>,
    pub host: HostInfo,
    pub timestamp: String,
    /// Order 852-dk9z. WHICH PROBE CODE produced this document. Absent on every
    /// document written before that order, which is why it is Option + default:
    /// a legacy cache reads as None, compares unequal to any real identity, and
    /// is therefore re-probed rather than served. It is serialised into
    /// published rows on purpose — the old complaint was that nothing on a row
    /// said which code probed it.
    #[serde(default)]
    pub probe_identity: Option<String>,
    /// Device classes this probe COULD NOT ENUMERATE on this platform, as
    /// opposed to enumerated-and-found-none.
    ///
    /// ORDER 805-r98w / NPU parity, 2026-09-02. Before this existed, both
    /// outcomes produced an empty device list and the envelope rendered either
    /// as `none` — so a probe that had never looked published an affirmative
    /// denial. Measured on native Windows: `accel_npu=none` on a host whose
    /// XDNA2 NPU was serving models at that moment.
    ///
    /// `#[serde(default)]` because documents written before this order have no
    /// such field; an old cache reads as "no gaps", which is the pre-existing
    /// behaviour and no worse than it was.
    #[serde(default)]
    pub enumeration_gaps: Vec<String>,
    /// The derived HARDWARE identity of the machine this document describes, or
    /// `None` when the probe could not identify it.
    ///
    /// ORDER 805-r98w, second half. The fleet matrix is keyed `(host_id,
    /// locus)`: `locus` is the substrate half and already works, but `host_id`
    /// is an ASSERTED machine name, so rows cannot be grouped by hardware and
    /// "these two hosts are the same machine" stays unverifiable — which is the
    /// whole reason this order exists.
    ///
    /// Recorded here rather than recomputed by the matrix reader ON PURPOSE.
    /// A second implementation of an identity function is the bug this order
    /// spent a day removing: yoga and this host briefly had two, they disagreed
    /// on RAM source and rounding, and two hosts running different
    /// implementations would have compared incommensurable strings. So the
    /// probe computes it once, the document carries it, and every consumer
    /// reads the same field.
    ///
    /// `None` IS MEANINGFUL AND MUST NOT BE PAPERED OVER: it means
    /// [`hardware_fingerprint_checked`] refused, i.e. this document cannot
    /// identify its machine. A row with `None` must never be grouped with
    /// another `None` row — two documents that both failed to identify
    /// themselves are not thereby the same hardware.
    #[serde(default)]
    pub hardware_fingerprint: Option<String>,
    /// The container lane's DRM render nodes, each carrying how far the
    /// evidence for it actually goes.
    ///
    /// ORDER 793-zumy REMAINING 2. The `Enumerated < Reachable < Placed` rungs
    /// were modelled, pinned by nine tests, and INERT: nothing produced a rung
    /// above `Enumerated` and nothing carried one off the probe. An honest model
    /// that does no work is only half the fix, and this field is the half that
    /// makes it observable.
    ///
    /// EMPTY IS NOT `none`. A host with no podman, no inference container, or no
    /// render nodes all yield an empty vec, and so does a probe that could not
    /// ask. Read it as "no container-lane placement is PROVEN here", never as
    /// "this machine has no GPU" - `devices` answers that question and
    /// `enumeration_gaps` records where nobody looked.
    ///
    /// APPENDED LAST ON PURPOSE. `scripts/dev-inference-ensure.sh` reads
    /// `legacy_tier` out of this document with `grep -m1` on the RAW
    /// `tillandsias --capabilities` output, so the FIRST `legacy_tier`-looking
    /// line wins; a new block ahead of it would silently downgrade yoga's ROCm
    /// host to cpu with no device flags and no warning. Nothing in here spells
    /// `legacy_tier`, and it serialises after it either way.
    ///
    /// `#[serde(default)]` because every document written before this order has
    /// no such field; an old cache reads as "nothing proven", which is the
    /// pre-existing behaviour and no worse than it was.
    #[serde(default)]
    pub render_nodes: Vec<DrmRenderNode>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct CpuCores {
    pub physical: u32,
    pub logical: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct DeviceRecord {
    pub device_class: String, // "cpu" | "gpu" | "npu"
    pub vendor: String, // "intel" | "amd" | "nvidia" | "apple" | "AMD XDNA" | "Intel NPU" | "unknown"
    pub name: String,
    pub device_node: Option<String>,
    pub fw_version: Option<String>,
    pub driver: Option<String>,
    pub usable: bool,
    pub unusable_reason: Option<String>,
    pub lanes: Vec<String>, // ["container", "host-native"], ["host-native"], or []
    pub memory_bandwidth_gbps: Option<f64>,
    pub memory_bandwidth_source: String, // "soc-table" | "measured" | "unknown"
    pub cpu_flags: Option<Vec<String>>,
    pub cpu_cores: Option<CpuCores>,
    pub system_ram_gb: Option<f64>,

    /// Whether this device's memory is ITS OWN or the host's: `unified` |
    /// `discrete` | `None` (order 964-r98h).
    ///
    /// 793-qr4t could only answer `unknown` for every AMD and Intel GPU in the
    /// fleet, because this struct recorded a memory BANDWIDTH and nothing that
    /// separates an integrated part sharing DRAM from a discrete board with
    /// its own VRAM. That left its unified-memory criterion — one budget, never
    /// summed — demonstrable on Apple silicon and nowhere else.
    ///
    /// `None` IS A REAL ANSWER and must not be papered over: the classifier
    /// looked and could not decide, or could not look at all. It is NOT
    /// "probably unified", and a consumer must decline to sum on `None`
    /// exactly as it does on `unified`.
    ///
    /// Recorded on the DEVICE rather than derived by the envelope on purpose.
    /// This host carries a discrete RTX 3070 and an integrated Vega at once, so
    /// memory model is a property of a device and a host-level field would have
    /// to pick one and be wrong about the other.
    #[serde(default)]
    pub memory_model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct EngineRecord {
    pub name: String,
    pub backend: String,
    pub supported_device_classes: Vec<String>,
    /// Which lanes this engine is reachable on (order 850-bif2). `None` means
    /// every lane — the pre-existing semantics for a host-PATH binary, and the
    /// deserialization default for every row filed before this field existed.
    /// A containerized engine says `Some(["container"])`: the fleet's ollama
    /// lives inside the tillandsias-inference image, which the old host-PATH
    /// probe could not see — that blindness is how a host with a usable RTX
    /// A5000 filed `engines: []` and the matrix read `schedulable: none`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lanes: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct MeasurementRecord {
    pub device: String,
    pub engine: String,
    pub prefill_tps: Option<f64>,
    pub decode_tps: Option<f64>,
    pub joules_per_token: Option<f64>,
    pub degraded: bool,
    pub degraded_reason: Option<String>,

    /// Which workload produced these numbers (order 808-43mw).
    ///
    /// `scripts/bench-accel-lane.sh` ALREADY KNOWS this — it stamps
    /// `workload_suite: "802-2536-v1"` onto its own stdout JSON — and then
    /// drops it when it pipes a record to `--record-measurement`, because
    /// this struct had nowhere to put it. The label existed upstream and
    /// downstream and was discarded in the middle, so every number in a
    /// capability document was unattributable to the workload that produced
    /// it. Comparing two such numbers is not a comparison.
    ///
    /// `Option` + `serde(default)`, NOT required: `--record-measurement`
    /// must keep accepting the payload the bench sends TODAY, or a host
    /// running this binary against the current script silently stops
    /// recording. Widening the reader is the compatible half of the change;
    /// teaching the writer to send it is the other half, and belongs with
    /// the script, not here.
    #[serde(default)]
    pub workload_suite: Option<String>,

    /// WHERE the measurement ran, e.g. `in-guest`, `host-side-via-mirror`
    /// (order 808-43mw; motivated by the measurement in 810-jeg7).
    ///
    /// This host measured the same suite at two loci and the hop cost 5-10%
    /// on the embed arm — the same order as the cross-host differences the
    /// fleet matrix exists to detect. It did not merely add noise: it
    /// INVERTED a reported conclusion, because two errors happened to
    /// cancel. A row without a locus is not under-annotated, it is
    /// potentially wrong in a way no consumer can see.
    #[serde(default)]
    pub locus: Option<String>,

    /// WHICH MODEL produced these numbers, e.g. `qwen2.5:0.5b` (order
    /// 793-qc6q).
    #[serde(default)]
    pub model: Option<String>,

    /// The model's parameter count in BILLIONS, e.g. `0.5` or `3.0`.
    ///
    /// THIS IS THE AXIS THE DECODE CROSSOVER LIVES ON, and without it
    /// 793-qc6q's exit criterion is not merely unmet but inexpressible. That
    /// criterion forbids a hard-coded threshold: the crossover must be
    /// "derived from a bounded per-host measurement cached in
    /// capabilities.json ... not from a constant that happens to fit
    /// windows/Yolanda". A crossover is the point where the CPU and GPU decode
    /// curves cross AS MODEL SIZE VARIES — so deriving one requires ordering
    /// decode rows by size, and this struct had no size. Two `decode_tps`
    /// values with no model dimension cannot be ordered, and the only way to
    /// ship a threshold without this field is to type 1.5 into the source,
    /// which is the thing the criterion rules out.
    ///
    /// Parameters, not bytes: quantisation changes the byte count by 4x
    /// without moving the arithmetic-per-token that decides whether the
    /// per-dispatch cost is absorbed, and it is that ratio the crossover is
    /// about.
    ///
    /// `Option` + `serde(default)` for the same reason `workload_suite` is:
    /// `--record-measurement` must keep accepting the payload
    /// `scripts/bench-accel-lane.sh` sends TODAY. A record without it is
    /// usable for everything except crossover derivation, and
    /// [`decode_crossover_b`] simply does not count it.
    #[serde(default)]
    pub model_params_b: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct HostInfo {
    pub is_battery_present: bool,
    pub kernel_release: String,

    /// WHICH MACHINE this document describes (order 808-43mw).
    ///
    /// Without it a CapabilityDocument cannot say whose capabilities it
    /// reports, which blocks the fleet matrix outright: 808-7yrd folds
    /// `host_id -> LWW-Register(document)`, so this is the FOLD KEY. There is
    /// no matrix without it.
    ///
    /// `kernel_release` is not a substitute and the reason is measurable: two
    /// WSL2 guests share `6.18.33.2-microsoft-standard-WSL2` exactly. Keying
    /// on it would silently merge two machines' rows into one, and LWW would
    /// then arbitrate between hosts that are not in conflict — turning a
    /// design whose whole point is "single writer per key by construction"
    /// into one that quietly drops half the fleet.
    ///
    /// NOT A NEW NAMING SCHEME. This is the identifier the fleet already
    /// uses: `scripts/agent-identity.sh`'s `tillandsias_node_name` (short
    /// hostname, lowercased), the same string that names
    /// `plan/mo-full-attestations.d/<host>.md`. Minting a second name for a
    /// machine that already has one would mean the matrix and the ledger
    /// disagree about who a host is.
    pub host_id: String,

    /// How `host_id` was determined: `input` or `node-name`.
    ///
    /// The packet's complaint is SILENT collision, so a consumer must be able
    /// to distinguish a host that was NAMED from one whose name was inferred
    /// and might collide. Recording only the value would reproduce the
    /// original defect one level up.
    ///
    /// Measured on this host: WSL2 inherits the Windows machine name, so the
    /// guest's `uname -n` is `Yolanda` — the derived chain agrees with the
    /// Windows side for free. That is a DEFAULT, not a guarantee:
    /// `/etc/wsl.conf`'s `network.hostname` can override it, at which point
    /// a guest-produced row would file itself under a second key for the same
    /// machine. `input` is how an operator forecloses that.
    pub host_id_source: String,

    /// OS family of the EXECUTION CONTEXT that produced this document:
    /// `linux` | `windows` | `macos`. A consumer folding the matrix reads
    /// documents produced elsewhere, so it cannot use its own `cfg!` to tell
    /// what it is looking at.
    ///
    /// READ THE NAME CAREFULLY — this is the context, not the machine, and on
    /// Windows those differ. Measured on yolanda 2026-08-18: the probe runs
    /// inside the WSL2 guest and reports `host_kind: "linux"` on a machine
    /// whose hardware spec is a Windows laptop's. That is not a defect in this
    /// field; it is 809-7e4m's two-execution-context finding arriving in the
    /// schema, and the field's value is that it now makes the split VISIBLE
    /// instead of leaving a Windows row indistinguishable from a Linux one.
    ///
    /// Deliberately NOT resolved here by inventing a `windows-wsl2` term. The
    /// guest could detect WSL2 from `kernel_release` and relabel itself, but a
    /// guess made by the context that cannot see the NPU or the machine's real
    /// RAM (the guest reports its 7.3 GB VM slice against 15.2 GB installed)
    /// would be a confident half-answer. The correct fix is the host-side
    /// contribution 809-7e4m specifies, which knows rather than infers.
    pub host_kind: String,

    /// WHICH SIDE OF WHICH BOUNDARY this probe ran on (order 793-qr4t).
    ///
    /// `native-linux` | `wsl2-guest` | `windows-host` | `macos-host` |
    /// `container` | `unknown-side`.
    ///
    /// `host_kind` above deliberately refuses to invent a `windows-wsl2` term,
    /// and that refusal is correct FOR THAT FIELD: it names the execution
    /// context's OS family, and a guest guessing at the machine's OS would be
    /// a confident half-answer. This is the field that was missing when that
    /// note was written. It does not guess at the MACHINE; it records a fact
    /// about the PROBE — where it stood — which the probe is the only party
    /// entitled to state and can state from evidence (`/dev/dxg` plus a
    /// `microsoft` kernel release is WSL2; `/run/.containerenv` is a
    /// container). The two fields answer different questions and a consumer
    /// needs both.
    ///
    /// WHY IT MUST LIVE IN THE DOCUMENT rather than be recomputed by whoever
    /// renders it: the fleet matrix folds documents produced ELSEWHERE, so a
    /// reader's own `cfg!` describes the reader, not the row. This is the same
    /// reasoning `enumeration_gaps` records above, and the same failure it
    /// prevents — a transported document keeps its own facts.
    ///
    /// `Option` + `serde(default)` because every document written before this
    /// order has no side. `None` reads as "this document does not say", which
    /// is true of them and is NOT the same as `unknown-side` (a probe that
    /// looked and could not tell).
    #[serde(default)]
    pub side: Option<String>,
}

/// The env INPUT that names this machine, overriding the derived chain.
///
/// Deliberately the same shape as `TILLANDSIAS_INFERENCE_TIER`: identity, like
/// the tier, is an input corroborated against the machine rather than derived
/// from it. On Windows a single capability row spans two execution contexts
/// (809-7e4m), and the context that can see the NPU is not the one that runs
/// this probe — so the two contributions must agree on a name that neither is
/// solely entitled to invent.
pub const HOST_ID_ENV: &str = "TILLANDSIAS_HOST_ID";

// @trace spec:accel-capability-probe
pub fn capabilities_cache_path() -> PathBuf {
    if let Ok(dir) = std::env::var("TILLANDSIAS_CACHE_DIR") {
        return PathBuf::from(dir).join("capabilities.json");
    }
    // NEVER fall back to "." — that resolves against the CURRENT WORKING
    // DIRECTORY, which during `cargo test` and every build dispatch is the
    // tracked checkout. This module had no caller until now, so the fallback was
    // unreachable and harmless; adding the first one made a HOME-less
    // environment write crates/tillandsias-headless/.cache/tillandsias/
    // capabilities.json into the source tree, which order 495 forbids outright
    // (generated evidence in the worktree fails the forge dirty-start guard for
    // whoever runs next, not for whoever caused it).
    //
    // A cache is by definition discardable, so the temp dir is the correct home
    // for one with nowhere else to live.
    // Order 815-gdjk: XDG-first via the shared resolver (this probe was the
    // measured half of the split: with XDG_CACHE_HOME set it wrote here
    // while every shell consumer resolved under the XDG root).
    tillandsias_core::cache_root::cache_root().join("capabilities.json")
}

// @trace spec:accel-capability-probe
pub fn load_or_probe(effective_tier: &str) -> CapabilityDocument {
    load_or_probe_at(
        &capabilities_cache_path(),
        effective_tier,
        Freshness::Cached,
    )
}

/// Order 852-dk9z. Publication must never be able to emit a cached document.
/// `scripts/host-capability-probe.sh` takes this path, so a published capability
/// row is fresh BY CONSTRUCTION rather than by the operator having remembered to
/// clear a cache directory first.
// @trace order:852-dk9z, spec:accel-capability-probe
pub fn probe_fresh(effective_tier: &str) -> CapabilityDocument {
    load_or_probe_at(&capabilities_cache_path(), effective_tier, Freshness::Force)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// @trace order:852-dk9z, spec:accel-capability-probe
pub enum Freshness {
    /// Serve a cache entry that matches this binary's probe identity.
    Cached,
    /// Probe regardless of what the cache holds (and refresh the cache).
    Force,
}

/// The cache path is a PARAMETER so this is testable without mutating process
/// environment — env-var tests race against every other test in the binary.
// @trace order:852-dk9z, spec:accel-capability-probe
pub fn load_or_probe_at(
    cache_file: &Path,
    effective_tier: &str,
    freshness: Freshness,
) -> CapabilityDocument {
    let identity = probe_identity();
    if freshness == Freshness::Cached
        && let Ok(content) = fs::read_to_string(cache_file)
        && let Ok(doc) = serde_json::from_str::<CapabilityDocument>(&content)
        && doc.schema_version == SCHEMA_VERSION
        && doc.legacy_tier == effective_tier
        // The check 852-dk9z adds. Without it a rebuilt binary republishes its
        // predecessor's document as if it had probed.
        && doc.probe_identity.as_deref() == Some(identity.as_str())
    {
        return doc;
    }
    let doc = run_probe(effective_tier);
    if let Some(parent) = cache_file.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(&doc) {
        let _ = fs::write(cache_file, json);
    }
    doc
}

/// Merge one measurement into the persisted capability document (order 805-wgbb).
///
/// `run_probe` hard-codes `measurements = Vec::new()` under a comment saying
/// microbenchmarks "run on demand" — and no on-demand path existed anywhere in
/// the tree, so `measurements: []` meant NOTHING WRITES rather than nothing has
/// run. 802-2536 asks every host to record cpu/npu/gpu numbers "into the
/// existing MeasurementRecord", which no host could do. This is that path.
///
/// KEYED BY (device, engine), replacing in place. A second run of the same
/// workload on the same lane is a NEW measurement of the same thing, not an
/// additional data point — appending would grow an unbounded log whose newest
/// entry a reader has to find by scanning, and the router reads this document
/// as its input surface, not as history.
///
/// NOTE ON LIFETIME, because it is easy to be surprised by: `load_or_probe`
/// re-probes and overwrites the cache when the schema version or the legacy
/// tier changes. Measurements are dropped then, and that is correct — a tier
/// change means the numbers describe a configuration that no longer exists —
/// but it does mean a measurement is not durable across a tier flip.
pub fn record_measurement(m: MeasurementRecord) -> Result<(), String> {
    let cache_file = capabilities_cache_path();
    let mut doc: CapabilityDocument = match fs::read_to_string(&cache_file) {
        Ok(content) => serde_json::from_str(&content).map_err(|e| {
            format!("capabilities cache is unreadable ({e}); re-run --capabilities")
        })?,
        // No cache yet: probe rather than refuse, so the first thing a fresh
        // host does can be to record a measurement.
        Err(_) => run_probe(crate::effective_inference_tier()),
    };
    match doc
        .measurements
        .iter_mut()
        .find(|e| e.device == m.device && e.engine == m.engine)
    {
        Some(slot) => *slot = m,
        None => doc.measurements.push(m),
    }
    if let Some(parent) = cache_file.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let json = serde_json::to_string_pretty(&doc).map_err(|e| format!("serialize: {e}"))?;
    fs::write(&cache_file, json).map_err(|e| format!("write {}: {e}", cache_file.display()))?;
    Ok(())
}

// @trace spec:accel-capability-probe
/// `effective_tier` NO LONGER REACHES DEVICE ENUMERATION (order 935-jhh5). It
/// used to be threaded down to `enumerate_gpus` and decide `cdi_ok`, which made
/// the GPU record's container lane a restatement of the tier — itself derived
/// from the same `nvidia-smi` that record already runs.
///
/// It is still read HERE, for `legacy_tier`, and that is the right place for it:
/// the document then carries the CLAIMED tier beside INDEPENDENTLY MEASURED
/// devices, so the two can be compared instead of one being manufactured from
/// the other. Enumeration measures the machine; this field records what the
/// tier probe asserted. Do not re-thread it downward.
pub fn run_probe(effective_tier: &str) -> CapabilityDocument {
    let (devices, mut enumeration_gaps) = enumerate_devices();
    // 793-zumy REMAINING 2. "No container to ask" is a GAP, not a finding —
    // the same distinction `enumeration_gaps` already carries for a device
    // class this platform cannot enumerate. Measured by yoga 2026-09-02: with
    // the two collapsed, a host whose container lane was working read
    // identically to a host with no accelerator at all.
    let container_lane = probe_container_render_nodes();
    if container_lane.asked.is_none() {
        enumeration_gaps.push("container-lane".to_string());
    }
    let engines = enumerate_engines();
    let measurements = Vec::new(); // Microbenchmarks run on demand / bounded
    let host = enumerate_host();
    let timestamp = chrono::Utc::now().to_rfc3339();

    let mut doc = CapabilityDocument {
        schema_version: SCHEMA_VERSION,
        legacy_tier: effective_tier.to_string(),
        devices,
        engines,
        measurements,
        host,
        timestamp,
        probe_identity: Some(probe_identity()),
        enumeration_gaps,
        hardware_fingerprint: None,
        // 793-zumy REMAINING 2: PRODUCED, not modelled. Bounded and
        // fail-quiet - a host with no podman, no container or no devices
        // contributes an empty vec rather than a fabricated row, and the
        // gap above says which of those it was.
        render_nodes: container_lane.nodes,
    };
    // Computed from the devices just enumerated, so the document carries its own
    // hardware identity and no consumer has to re-derive it. `checked` rather
    // than the raw hasher: a blind probe must contribute NO identity rather than
    // a plausible-looking constant that would collide with every other blind
    // host.
    doc.hardware_fingerprint = hardware_fingerprint_checked(&doc).ok();
    doc
}

/// Order 852-dk9z. The identity of the probe CODE, not of the host.
///
/// Crate version alone is insufficient and that is not hypothetical: 856-fwyh
/// changed enumeration output on this very crate without moving its version, so
/// a version-keyed cache would still have served the stale document. The
/// revision half is an FNV-1a hash of src/accel_probe.rs computed in build.rs,
/// so ANY edit here changes it and no one has to remember to bump a constant.
pub fn probe_identity() -> String {
    format!(
        "{}+{}",
        env!("CARGO_PKG_VERSION"),
        env!("TILLANDSIAS_PROBE_REVISION")
    )
}

// @trace spec:accel-capability-probe
fn enumerate_devices() -> (Vec<DeviceRecord>, Vec<String>) {
    let mut devices = Vec::new();
    let mut gaps = Vec::new();

    // 1. CPU Device
    devices.push(enumerate_cpu());

    // 2. GPUs
    match enumerate_gpus_checked() {
        Some(g) => devices.extend(g),
        None => gaps.push("gpu".to_string()),
    }

    // 3. NPUs
    match enumerate_npus_checked() {
        Some(n) => devices.extend(n),
        None => gaps.push("npu".to_string()),
    }

    (devices, gaps)
}

/// GPU enumeration that distinguishes "looked and found none" (`Some(vec![])`)
/// from "could not look here" (`None`).
///
/// ORDER 805-r98w. The distinction is the whole point: an empty list rendered
/// as `accel_gpu=none` on a host with a Radeon 860M, because there was no
/// Windows arm and no way for the caller to tell absence from blindness.
fn enumerate_gpus_checked() -> Option<Vec<DeviceRecord>> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        Some(enumerate_gpus())
    }
    #[cfg(target_os = "windows")]
    {
        windows_gpus()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        // An unknown platform has NOT looked. Saying so costs a discriminator;
        // claiming `none` would be a denial we cannot support.
        None
    }
}

/// NPU enumeration, same contract as [`enumerate_gpus_checked`].
fn enumerate_npus_checked() -> Option<Vec<DeviceRecord>> {
    #[cfg(target_os = "linux")]
    {
        Some(enumerate_npus())
    }
    #[cfg(target_os = "windows")]
    {
        windows_npus()
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        None
    }
}

// @trace spec:accel-capability-probe
fn enumerate_cpu() -> DeviceRecord {
    let mut flags = Vec::new();
    let physical_cores;
    let logical_cores;
    // Only the Linux probe mutates these defaults incrementally; the macOS arm
    // overwrites them wholesale, so off-Linux the initializers are never read.
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut))]
    let mut ram_gb = None;
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut, unused_assignments))]
    let mut cpu_name = "Host CPU".to_string();
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut, unused_assignments))]
    let mut vendor = "unknown".to_string();

    #[cfg(target_os = "linux")]
    {
        logical_cores = num_cpus();
        if let Ok(cpuinfo) = fs::read_to_string("/proc/cpuinfo") {
            for line in cpuinfo.lines() {
                if (line.starts_with("model name") || line.starts_with("Processor"))
                    && let Some((_, v)) = line.split_once(':')
                {
                    cpu_name = v.trim().to_string();
                    if cpu_name.contains("Intel") {
                        vendor = "intel".to_string();
                    } else if cpu_name.contains("AMD") {
                        vendor = "amd".to_string();
                    }
                } else if (line.starts_with("flags") || line.starts_with("Features"))
                    && let Some((_, v)) = line.split_once(':')
                {
                    for flag in v.split_whitespace() {
                        let f = flag.to_lowercase();
                        if (f.contains("avx")
                            || f.contains("neon")
                            || f.contains("sve")
                            || f.contains("fma"))
                            && !flags.contains(&f)
                        {
                            flags.push(f);
                        }
                    }
                }
            }
        }
        if let Ok(meminfo) = fs::read_to_string("/proc/meminfo") {
            for line in meminfo.lines() {
                if line.starts_with("MemTotal:")
                    && let Some(kb_str) = line.split_whitespace().nth(1)
                    && let Ok(kb) = kb_str.parse::<u64>()
                {
                    ram_gb = Some((kb as f64) / 1024.0 / 1024.0);
                }
            }
        }
        physical_cores = physical_core_count().unwrap_or(logical_cores);
    }

    #[cfg(target_os = "macos")]
    {
        logical_cores = num_cpus();
        physical_cores = logical_cores;
        vendor = "apple".to_string();
        cpu_name = "Apple Silicon CPU".to_string();
        flags.push("neon".to_string());
    }

    // ORDER 805-r98w / NPU parity, 2026-09-02. Native Windows used to fall
    // through to the generic arm below, which sets physical = logical. On this
    // 8c/16t part that reported 16c16t — a WRONG number, not a missing one, and
    // the CPU model stayed the placeholder "Host CPU". Together those made the
    // hardware fingerprint refuse (correctly) and made the capability document
    // unable to identify the machine at all.
    //
    // Everything here comes from the OS, not from a guess: a query that fails
    // leaves the generic fallback in place rather than inventing a value.
    #[cfg(target_os = "windows")]
    {
        let mut got = None;
        if let Some(lines) = powershell_lines(
            "$c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1; \
             $m = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory; \
             $c.Name + '|' + $c.NumberOfCores + '|' + $c.NumberOfLogicalProcessors + '|' + \
             $c.Manufacturer + '|' + $m",
        ) {
            if let Some(line) = lines.first() {
                let f: Vec<&str> = line.split('|').collect();
                if f.len() >= 5 {
                    let name = f[0].trim().to_string();
                    // Only accept a COMPLETE row. A partial parse that keeps
                    // some real fields and silently defaults the rest is how a
                    // document ends up half-trustworthy, which is worse than a
                    // uniformly unknown one.
                    if let (Ok(phys), Ok(log)) =
                        (f[1].trim().parse::<u32>(), f[2].trim().parse::<u32>())
                    {
                        if !name.is_empty() && phys > 0 && log > 0 {
                            got = Some((
                                name,
                                phys,
                                log,
                                f[3].trim().to_string(),
                                f[4].trim().parse::<u64>().ok(),
                            ));
                        }
                    }
                }
            }
        }
        match got {
            Some((name, phys, log, manufacturer, total_bytes)) => {
                cpu_name = name;
                physical_cores = phys;
                logical_cores = log;
                vendor = match manufacturer.as_str() {
                    "AuthenticAMD" => "amd".to_string(),
                    "GenuineIntel" => "intel".to_string(),
                    other if !other.is_empty() => other.to_ascii_lowercase(),
                    _ => "unknown".to_string(),
                };
                ram_gb = total_bytes.map(|b| b as f64 / (1024.0 * 1024.0 * 1024.0));
            }
            None => {
                // The query could not be run or came back unparseable. Report
                // the little we know for certain and leave the model name as
                // the placeholder, which the fingerprint guard already refuses.
                logical_cores = num_cpus();
                physical_cores = logical_cores;
            }
        }
    }

    // Every other target (653-7rag). Without this arm both bindings are read
    // uninitialized and the crate fails to COMPILE on Windows — a hard error in
    // `cargo build --workspace` for a contributor who touched nothing here.
    //
    // It survived because the commit that introduced it (bd8a47d1) was a Linux
    // host repairing platform-gated code that Linux cannot compile, and
    // `./build.sh --check` does not build the workspace. Both blind spots are
    // real; this arm removes the failure mode rather than relying on either
    // being fixed. Reporting fewer facts is correct here — the probe's contract
    // is "what this host can tell you", and an unknown physical count is a
    // legitimate answer where no enumeration path exists.
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        logical_cores = num_cpus();
        physical_cores = logical_cores;
    }

    DeviceRecord {
        device_class: "cpu".to_string(),
        vendor,
        name: cpu_name,
        device_node: None,
        fw_version: None,
        driver: None,
        usable: true,
        unusable_reason: None,
        lanes: vec!["container".to_string(), "host-native".to_string()],
        memory_bandwidth_gbps: None,
        memory_bandwidth_source: "unknown".to_string(),
        cpu_flags: Some(flags),
        cpu_cores: Some(CpuCores {
            physical: physical_cores,
            logical: logical_cores,
        }),
        system_ram_gb: ram_gb,
        memory_model: None,
    }
}

// @trace spec:accel-capability-probe
/// The WSL2 paravirtual-GPU decision, as a pure function so every combination
/// is testable without a matching host (order 806-2r4s).
///
/// WSL2 presents the GPU as `/dev/dxg` with the D3D12 userspace in
/// `/usr/lib/wsl/lib`, and exposes NO DRI render node. With no branch for that
/// shape the probe emits nothing at all, and `accel_envelope` then reports
/// `accel_gpu=none` — making a machine with a healthy GPU indistinguishable
/// from one that has none. Those are different engineering problems ("buy
/// hardware" versus "ship a lane"), and the fleet capability matrix cannot tell
/// them apart from the envelope alone.
///
/// The device is real and present; it is only unreachable by the engines we
/// ship today. That is exactly the present-unusable state `accel_envelope`
/// already renders — this function supplies the record it needs, and adds no
/// new vocabulary.
///
/// Returns `None` (emit nothing) unless the shape is unambiguously WSL2's:
/// `/dev/dxg` present, no DRI render node, and no better GPU already found.
/// `/dev/dxg` does not exist on bare-metal Linux, and a WSL2 host that DOES
/// expose a render node is handled by the `/dev/dri` arm, so this cannot
/// manufacture a phantom device off-WSL2.
// @trace spec:accel-capability-probe
#[cfg(target_os = "linux")]
fn wsl2_paravirtual_gpu(dxg_present: bool, dri_present: bool, already_found: bool) -> bool {
    dxg_present && !dri_present && !already_found
}

/// Why a WSL2 paravirtual GPU is unusable — as a value, so a test can pin it.
///
/// ORDER 793-zumy, AND THE REASON THIS IS A FUNCTION AT ALL. The literal used
/// to sit inline in `enumerate_gpus`, which reads real `/dev` paths and cannot
/// run in a unit test. The existing envelope test looked like it covered this
/// and did not: it builds its own `DeviceRecord` fixture, so it renders whatever
/// reason the TEST supplies and passes identically against a wrong production
/// value — verified by reverting the literal and watching it stay green. A pure
/// function is the smallest thing that makes the production value assertable.
/// Gated to match its production caller, `enumerate_gpus`, which is
/// `#[cfg(target_os = "linux")]` — plus `test` so the assertion 793-zumy added
/// this function to make possible still runs on every host. Without the `test`
/// arm the macOS gate fails on dead code; without the `linux` arm the Linux
/// build loses the production value. Order 935-6fzk found this from macOS,
/// where the Linux-only caller vanishes and nothing else references it.
#[cfg(any(target_os = "linux", test))]
fn wsl2_paravirtual_gpu_reason() -> &'static str {
    "engine-missing:no-vulkan-icd"
}

/// Order 850-bif2, the pure decision half of the AMD arm (unit-tested):
/// given what the walker observed for an amdgpu card, decide usability,
/// lanes, and the reason for any refusal.
///
/// `rocm-smi` presence alone is deliberately NOT evidence — the tier lattice
/// already learned that on Fedora (see detect_inference_tier's caveat): the
/// admission ticket is a ROCm runtime reporting a gfx agent. Without it the
/// device is present-unusable, which the matrix renders distinctly from
/// absent — that distinction is the whole point of recording it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn amd_gpu_disposition(
    rocm_gfx: bool,
    kfd: bool,
    render_node: bool,
) -> (bool, Vec<String>, Option<String>) {
    if !rocm_gfx {
        return (
            false,
            vec!["host-native".to_string()],
            Some("rocm-runtime-missing".to_string()),
        );
    }
    if !kfd {
        return (
            false,
            vec!["host-native".to_string()],
            Some("kfd-missing".to_string()),
        );
    }
    if !render_node {
        return (false, vec![], Some("render-node-missing".to_string()));
    }
    // ORDER 793-zumy: THE CONTAINER LANE IS NOT CLAIMED HERE, and its absence is
    // the fix rather than an omission.
    //
    // Every input above — rocm_gfx, kfd, render_node — is read from the HOST.
    // MEASURED on yoga 2026-08-30: all three were true, this function therefore
    // advertised `container`, and inside the container /dev/kfd and /dev/dri
    // were absent, size_vram was 0.00GB for every model, and the runtime
    // reported library=cpu. After their passthrough fix put the device nodes
    // IN the container, size_vram was STILL 0.00GB — the image ships no
    // ROCm/HIP backend. The envelope did not move a single character across
    // that entire real change.
    //
    // So host-vantage evidence cannot support a container-lane claim, twice
    // over: it does not know what `--device` flags a launcher will pass, and
    // even when they are passed it does not know whether a runtime inside can
    // drive them. Those are `Proof::Reachable` and `Proof::Placed`
    // respectively, and a sysfs read reaches neither.
    //
    // Unlike NVIDIA there is no CDI spec to read — AMD passthrough is explicit
    // `--device` at launch — so there is nothing host-side to inspect. The
    // honest report is the lane we CAN prove, plus a reason naming what is
    // unverified rather than silently dropping it.
    (
        true,
        vec!["host-native".to_string()],
        Some("container-lane-unverified".to_string()),
    )
}

/// Intel's admission ticket, the sibling of `amd_gpu_disposition`.
///
/// Order 855-wrr3. An i915/xe RENDER NODE PROVES A DISPLAY/MEDIA DRIVER, NEVER
/// A COMPUTE LANE. Alder Lake-N ships /dev/dri/renderD128 on a part no engine
/// in this project can offload to, and Intel was the one vendor with no
/// disposition check at all: it fell through to the last-resort arm, which
/// hardcodes `usable: true` because a DRM card exists. On the fleet's declared
/// LOWER-BOUND host that published `accel_class=workstation-gpu` for a 4-core
/// N150 while the SAME BINARY's `--inference-tier` answered `tier:cpu`.
///
/// The ticket is an Intel compute runtime — Level Zero or an OpenCL ICD — the
/// same shape as ROCm's gfx agent. Without it the device is present-unusable
/// with the reason named, which the matrix renders distinctly from absent.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn intel_gpu_disposition(
    compute_runtime: bool,
    render_node: bool,
) -> (bool, Vec<String>, Option<String>) {
    if !compute_runtime {
        return (
            false,
            vec!["host-native".to_string()],
            Some("intel-compute-runtime-missing".to_string()),
        );
    }
    if !render_node {
        return (false, vec![], Some("render-node-missing".to_string()));
    }
    (
        true,
        vec!["container".to_string(), "host-native".to_string()],
        None,
    )
}

/// Every /sys/class/drm/card<N> as (pci_address, vendor_id, driver), sorted
/// by card number. Reads sysfs only; anything unreadable is skipped rather
/// than guessed.
#[cfg(target_os = "linux")]
fn drm_cards() -> Vec<(String, String, Option<String>)> {
    let mut cards: Vec<(String, String, Option<String>)> = Vec::new();
    let Ok(entries) = fs::read_dir("/sys/class/drm") else {
        return cards;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| {
            n.strip_prefix("card")
                .is_some_and(|rest| !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_digit()))
        })
        .collect();
    names.sort();
    for name in names {
        let dev = Path::new("/sys/class/drm").join(&name).join("device");
        let Ok(target) = fs::canonicalize(&dev) else {
            continue;
        };
        let Some(pci_addr) = target.file_name().map(|f| f.to_string_lossy().to_string()) else {
            continue;
        };
        let Some(vendor_id) = fs::read_to_string(dev.join("vendor"))
            .ok()
            .map(|s| s.trim().to_lowercase())
        else {
            continue;
        };
        let driver = fs::read_to_string(dev.join("uevent")).ok().and_then(|u| {
            u.lines()
                .find_map(|l| l.strip_prefix("DRIVER=").map(|d| d.trim().to_string()))
        });
        cards.push((pci_addr, vendor_id, driver));
    }
    cards
}

/// The /dev/dri/renderD* node whose sysfs device resolves to the same PCI
/// address, if any — the node the container run args would deliver.
#[cfg(target_os = "linux")]
fn drm_render_node_for(pci_addr: &str) -> Option<String> {
    let entries = fs::read_dir("/sys/class/drm").ok()?;
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !name.starts_with("renderD") {
            continue;
        }
        let dev = Path::new("/sys/class/drm").join(&name).join("device");
        if let Ok(target) = fs::canonicalize(&dev)
            && target.file_name().map(|f| f.to_string_lossy().to_string())
                == Some(pci_addr.to_string())
        {
            let node = format!("/dev/dri/{name}");
            if Path::new(&node).exists() {
                return Some(node);
            }
        }
    }
    None
}

/// Marketing name for a PCI device via `lspci -mm -s <addr>`, parsing the
/// QUOTED device field — never a substring of the whole line (the
/// comp-ATI-ble trap). None when lspci is absent or the line is malformed.
#[cfg(target_os = "linux")]
fn pci_device_name_via_lspci(pci_addr: &str) -> Option<String> {
    // lspci speaks the short form (05:00.0); sysfs the long (0000:05:00.0).
    let short = pci_addr.strip_prefix("0000:").unwrap_or(pci_addr);
    let out = Command::new("lspci")
        .args(["-mm", "-s", short])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let line = String::from_utf8_lossy(&out.stdout);
    // Quoted fields: [1]=class, [3]=vendor, [5]=device name.
    let fields: Vec<&str> = line.trim().split('"').collect();
    let name = fields.get(5)?.trim();
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// Does `rocminfo` report a gfx agent? Mirrors detect_inference_tier: the
/// runtime answering for the silicon, not a tool merely being installed.
#[cfg(target_os = "linux")]
fn rocm_gfx_present() -> bool {
    Command::new("rocminfo")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("gfx"))
        .unwrap_or(false)
}

/// Is an Intel COMPUTE runtime installed? Filesystem probe only — no
/// subprocess, and nothing substring-matches prose (the comp-ATI-ble trap).
/// Level Zero is the primary ticket; an Intel OpenCL ICD is accepted as the
/// secondary. Mesa's Vulkan ICD is deliberately NOT evidence here: it is
/// present in the Fedora Silverblue base on every Intel host and would
/// re-admit exactly the display silicon this check exists to exclude.
#[cfg(target_os = "linux")]
fn intel_compute_runtime_present() -> bool {
    const ZE: [&str; 4] = [
        "/usr/lib64/libze_intel_gpu.so.1",
        "/usr/lib64/libze_loader.so.1",
        "/usr/lib/x86_64-linux-gnu/libze_intel_gpu.so.1",
        "/usr/lib/x86_64-linux-gnu/libze_loader.so.1",
    ];
    if ZE.iter().any(|p| Path::new(p).exists()) {
        return true;
    }
    fs::read_dir("/etc/OpenCL/vendors")
        .map(|d| {
            d.flatten()
                .any(|e| e.file_name().to_string_lossy().contains("intel"))
        })
        .unwrap_or(false)
}

/// ORDER 793-zumy — REAL GPU ENUMERATION, replacing file-existence detection.
///
/// THE CLASS THIS EXISTS TO END, in yoga's words: A LABEL THAT SUBSTITUTES FOR
/// THE WIRING IT NAMES. Four measured instances, one shape:
///
///   * accel_probe.rs computed `cdi_ok = effective_tier == "gpu-cuda"` — a label
///     derived from the same `nvidia-smi` the surrounding code had already run.
///     The container lane was advertised on a host where
///     `podman run --device nvidia.com/gpu=all` returned rc=126 (935-jhh5).
///   * WSL2 detection is `dxg_present && !dri_present` — file existence. Nothing
///     enumerates, so the software-rasterizer rejection this packet requires is
///     not merely untested there, it is UNIMPLEMENTABLE (yolanda, 793-zumy).
///   * The inference container announced `TILLANDSIAS_INFERENCE_TIER=gpu-rocm`
///     with `HostConfig.Devices == []` and `size_vram=0` on every model (yoga).
///   * dev-inference-ensure.sh wires `--device` for gpu-cuda only; gpu-rocm falls
///     through empty while the tier label is still passed in (yoga).
///
/// A label that stands in for wiring READS AS EVIDENCE to every later reader,
/// which is why the gap survived three orders unnoticed.
///
/// THE RULE: a lane is proven by what can be STATTED OR PLACED — a device node
/// visible in-container, a nonzero size_vram, a real enumeration — never by a
/// label, an env var, or the presence of a file. The precedent is already
/// in-tree and is a shell script: images/inference/entrypoint.sh refuses a cuda
/// tier when `[ -e /dev/nvidia0 ]` fails INSIDE the container.
///
/// WHY DRM RENDER NODES ARE THE RIGHT PRIMITIVE HERE, measured on lenovinha
/// 2026-08-30 — the fleet's only dual-vendor host:
///
///   renderD128  vendor=0x1002 device=0x1638 driver=amdgpu   (AMD Cezanne iGPU)
///   renderD129  vendor=0x10de device=0x24dd driver=nvidia    (RTX 3070 dGPU)
///
///   1. IT REPRESENTS TWO GPUs. `/dev/dri exists` is one bit and cannot; this is
///      the enumeration gap 793-zumy was filed against, and this host is the
///      fixture that shows it.
///   2. IT CARRIES REAL IDENTITY — PCI vendor/device and the BOUND KERNEL
///      DRIVER, not a guess from a filename.
///   3. IT REJECTS SOFTWARE RASTERIZERS STRUCTURALLY. lavapipe/llvmpipe are
///      USERSPACE-ONLY ICDs: they create no DRM render node, so an enumeration
///      of render nodes cannot see them AT ALL. Criterion 3 is satisfied by
///      construction rather than by a blocklist of driver names — and a
///      blocklist is exactly the shape that rots when a new rasterizer appears.
///
/// WHAT THIS DELIBERATELY DOES NOT COVER, stated so nobody reads it as total:
/// WSL2. /dev/dxg is not a DRM device and creates no render node, so a
/// paravirtualised GPU is invisible here and its arm must keep its own proof.
/// Yolanda's `engine-missing:no-vulkan-icd` reason already carries that case
/// honestly. Enumerating nothing on WSL2 is CORRECT for this primitive; it is
/// the WSL2 arm's job to say what it can prove, not this one's job to guess.
/// WHERE a piece of evidence was gathered. Yoga's tightening of the rule, and it
/// is the dimension whose absence produced their finding: not "proven by what
/// can be statted or placed" but PROVEN BY WHAT CAN BE STATTED FROM WHERE THE
/// WORK HAPPENS.
///
/// Measured on yoga 2026-08-30, one machine, two true statements:
///   host envelope : accel_gpu=usable, /dev/kfd 235,0 and /dev/dri/renderD128 present
///   in-container  : /dev/kfd absent, /dev/dri absent, size_vram=0 for every model
/// "usable" was true of the MACHINE and false of every lane any workload runs
/// in, and nothing in the envelope distinguished those. The node existed the
/// entire time it was missing where it mattered.
///
/// So a record carries its vantage. An enumeration performed on the host is
/// evidence ABOUT THE HOST and must never be read as a container-lane claim —
/// which is exactly the substitution this packet exists to end, one level up
/// from the label.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Vantage {
    /// Observed from the host's own filesystem.
    Host,
    /// Observed from inside a container — the only vantage that can speak for
    /// the container lane. `images/inference/entrypoint.sh` is the in-tree
    /// precedent: it refuses a cuda tier when `[ -e /dev/nvidia0 ]` fails THERE.
    Container,
}

impl Vantage {
    pub fn token(&self) -> &'static str {
        match self {
            Vantage::Host => "host",
            Vantage::Container => "container",
        }
    }
}

/// HOW FAR THE EVIDENCE ACTUALLY GOES. Yoga's second refinement, measured on
/// their host 2026-08-30, and it is a rung this model did not have.
///
/// My rule after their first message was "statted from where the work happens".
/// They then supplied the case that breaks it, and it is the case a
/// label-based probe gets wrong most confidently:
///
///     hardware present                              yes  (real AMD, real PCI ids)
///     device nodes stat-able INSIDE the container   yes  (/dev/kfd, /dev/dri/renderD128)
///     a runtime that can drive them                 NO   (no ROCm/HIP backend in the image)
///     -> size_vram = 0.00GB, decode 12.18 -> 12.22 tok/s, unchanged
///
/// EVERY SIGNAL SHORT OF PLACEMENT SAID YES. The vantage rule was satisfied and
/// the lane still could not run. So: A STAT PROVES THE DEVICE IS REACHABLE FROM
/// WHERE THE WORK HAPPENS; IT DOES NOT PROVE A LANE. ONLY PLACEMENT PROVES A
/// LANE. Two rungs, not one — and the three requirements (hardware, device
/// nodes, a runtime) are INDEPENDENT. The tier label asserted all three.
///
/// THE IN-TREE PROOF THAT THIS DISTINCTION IS ALREADY UNDERSTOOD, and the
/// sharpest thing in yoga's report: on that same envelope the NPU line reads
/// `engine-missing` while the GPU line reads `usable` — the two devices are in
/// the IDENTICAL state. The GPU's verdict came from a label; the NPU's came
/// from something closer to a check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Proof {
    /// The hardware exists and identifies itself. Says nothing about any lane.
    Enumerated,
    /// Its device nodes are stat-able from the vantage the work runs in.
    /// Necessary, and NOT sufficient — this is exactly where yoga's host sat
    /// with size_vram still 0.
    Reachable,
    /// Work was actually placed on it: a runtime reported non-zero residency.
    /// The only rung that proves a lane EXISTS.
    ///
    /// AND IT IS NOT A CLAIM ABOUT CAPACITY — yoga's caveat, recorded here so
    /// this rung does not inherit the problem it fixes. Non-zero residency
    /// proves a runtime placed weights on a device. It does NOT prove the
    /// device is doing the compute (a PARTIAL OFFLOAD reports non-zero VRAM
    /// while most layers run on CPU), and it does not prove the lane works at
    /// the size that matters (a lane that places 200 MB may still fail at
    /// 5 GB).
    ///
    /// PLACED ANSWERS "DID ANY WORK LAND HERE", NOT "WILL THE WORK LAND HERE".
    /// A scheduler reading it as capacity is making the same substitution one
    /// rung up, which is exactly how this family reproduces.
    Placed,
}

impl Proof {
    pub fn token(&self) -> &'static str {
        match self {
            Proof::Enumerated => "enumerated",
            Proof::Reachable => "reachable",
            Proof::Placed => "placed",
        }
    }
    /// A lane may be ADVERTISED only at the top rung. Deliberately not `>=
    /// Reachable`: that is the mistake this whole packet family is about, and
    /// it is one keystroke away, so it is stated as a method rather than left
    /// to each caller's comparison.
    pub fn proves_a_lane(&self) -> bool {
        matches!(self, Proof::Placed)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DrmRenderNode {
    /// e.g. "renderD128"
    pub node: String,
    /// PCI vendor id, e.g. 0x10de
    pub vendor_id: u16,
    /// PCI device id.
    ///
    /// USE THIS WITH `vendor_id`, NEVER ALONE.
    ///
    /// CORRECTED 2026-08-30. This comment previously argued the point with a
    /// FABRICATED counterexample — "0x1638 is BOTH yoga's Krackan Radeon
    /// 840M/860M AND lenovinha's Cezanne". That is false. Measured from each
    /// host's own `lspci -nn`:
    ///
    ///   yoga       04:00.0 Krackan Radeon 840M/860M   [1002:1114]
    ///   lenovinha  05:00.0 Cezanne  Radeon Vega       [1002:1638]
    ///
    /// device_id DISCRIMINATES those two parts; it does not collide. I took the
    /// collision from a peer message rather than from an artifact, and wrote it
    /// into a doc comment that outlives the message — the assertion-not-artifact
    /// error, committed on the very field built to resist it.
    ///
    /// THE CONCLUSION SURVIVES, on a measured argument instead of an invented
    /// one: VENDOR alone collides — yoga's 1002:1114 and lenovinha's 1002:1638
    /// share 0x1002, so vendor identifies a manufacturer, not a part. And on
    /// lenovinha the two render nodes are different vendors AND different
    /// devices (0x1002:0x1638 amdgpu, 0x10de:0x24dd nvidia), so the node index
    /// carries no identity of its own. The PAIR, keyed to the node, is what
    /// names a GPU. Neither half alone is sufficient, and only one half was ever
    /// shown to collide.
    pub device_id: u16,
    /// bound kernel driver, e.g. "amdgpu" / "nvidia" / "i915"
    pub driver: String,
    /// WHERE this was observed. Set by the enumerator, never by a caller: a
    /// record that could be relabelled is a label again.
    pub vantage: Vantage,
    /// HOW FAR the evidence goes. An enumeration can only ever establish
    /// `Enumerated`; reaching `Reachable` needs a stat from the work's vantage
    /// and `Placed` needs a runtime's residency report, neither of which a
    /// sysfs walk can do. Hardcoded here so no caller can inflate it.
    pub proof: Proof,
}

impl DrmRenderNode {
    /// Vendor name from the PCI id. Unknown ids are named as themselves rather
    /// than guessed — an honest "0x1234" beats a wrong "intel".
    pub fn vendor(&self) -> String {
        match self.vendor_id {
            0x10de => "nvidia".to_string(),
            0x1002 => "amd".to_string(),
            0x8086 => "intel".to_string(),
            other => format!("0x{other:04x}"),
        }
    }
}

/// Parse one hex sysfs id file body ("0x10de\n") into a u16.
///
/// Split out because it is the only fiddly part and the whole enumeration is
/// worthless if it silently yields 0 for a value it could not read.
pub fn parse_pci_id(body: &str) -> Option<u16> {
    let t = body.trim();
    let hex = t.strip_prefix("0x").unwrap_or(t);
    u16::from_str_radix(hex, 16).ok()
}

/// Enumerate DRM render nodes under a sysfs root. `root` is a parameter ONLY so
/// tests can point it at a fixture tree — production always passes
/// "/sys/class/drm". A test that read the real /sys would assert whatever this
/// machine happens to be, which is the vacuous-green shape yolanda caught on
/// this very packet: a test that built its own fixture, never touched
/// production, and stayed GREEN when production was reverted to a wrong value.
pub fn enumerate_render_nodes_at(root: &std::path::Path, vantage: Vantage) -> Vec<DrmRenderNode> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return out;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.starts_with("renderD"))
        .collect();
    names.sort();
    for name in names {
        let dev = root.join(&name).join("device");
        let vendor = std::fs::read_to_string(dev.join("vendor")).unwrap_or_default();
        let device = std::fs::read_to_string(dev.join("device")).unwrap_or_default();
        let driver = std::fs::read_link(dev.join("driver"))
            .ok()
            .and_then(|p| p.file_name().and_then(|f| f.to_str()).map(str::to_string))
            .unwrap_or_else(|| "unknown".to_string());
        // This function reads a filesystem. Whose filesystem is the caller's
        // business; what it can honestly say is "I saw this from where I ran".
        // Production passes /sys/class/drm.
        if let Some(n) = assemble_render_node(&name, &vendor, &device, &driver, vantage) {
            out.push(n);
        }
    }
    out
}

/// Build ONE [`DrmRenderNode`] from the four raw sysfs reads that identify it.
///
/// 793-zumy REMAINING 2. Extracted so the two TRANSPORTS that can reach those
/// four values — a direct `read_dir` walk on a filesystem this process can see,
/// and a `podman exec` that cats them from inside the container — share ONE
/// identity implementation. A second implementation of an identity function is
/// the bug order 805-r98w spent a day removing: two hosts briefly had two
/// hardware fingerprint functions, they disagreed on RAM source and rounding,
/// and the strings they produced were incommensurable. The same trap is one
/// copy-paste away here, so the assembly lives in one place and the transports
/// only supply bytes.
///
/// A node whose identity cannot be read is SKIPPED, not defaulted to zero: a
/// record claiming vendor 0x0000 is still a claim, and this packet is about not
/// making claims the evidence does not support.
///
/// The rung is hardcoded to [`Proof::Enumerated`] and there is no parameter for
/// it. Reading four files sees HARDWARE; it cannot see a container's device
/// list and it cannot see `size_vram`, so this is the only rung either
/// transport is entitled to claim, whichever vantage it ran from.
pub fn assemble_render_node(
    node: &str,
    vendor_body: &str,
    device_body: &str,
    driver: &str,
    vantage: Vantage,
) -> Option<DrmRenderNode> {
    let vendor_id = parse_pci_id(vendor_body)?;
    let device_id = parse_pci_id(device_body)?;
    let driver = driver.trim();
    Some(DrmRenderNode {
        node: node.to_string(),
        vendor_id,
        device_id,
        driver: if driver.is_empty() {
            "unknown".to_string()
        } else {
            driver.to_string()
        },
        vantage,
        proof: Proof::Enumerated,
    })
}

/// A stable identifier for the HARDWARE this document describes, so two hosts
/// can be SHOWN identical rather than ASSERTED identical.
///
/// 805-r98w. The cost of not having this was paid on 2026-08-31: an accelerator
/// result measured here was reported as "replicates on a THIRD SUBSTRATE" when
/// nothing could establish that this host and yoga's are the same substrate.
/// Both hosts then had to strike the framing. Two machines each describing
/// themselves and calling the pair a control is precisely what this fixes.
///
/// WHAT IS IN IT — hardware only:
///   cpu:<vendor>/<name>/<physical>c<logical>t
///   gpu:<vendor>/<name>
///   npu:<vendor>/<device_node>
///   ram:<class>
/// Devices are sorted before hashing, because enumeration order is not a
/// property of the machine and a fingerprint that changed with it would fail
/// the one job it has.
///
/// WHAT IS DELIBERATELY OUT, and this is the design rather than an omission:
///
///   * THE OS, KERNEL, AND CONTAINER RUNTIME. Those are the SUBSTRATE, and the
///     packet's whole point is a matrix keyed on (fingerprint, substrate) where
///     same-fingerprint rows isolate the substrate as the only free variable.
///     Folding the OS in would make every row unique and the control impossible.
///     This host and yoga's must fingerprint IDENTICALLY despite one running
///     Windows/WSL2 and the other bare Linux — that equality is the deliverable.
///   * `driver`, for the same reason: a driver version is substrate, not silicon.
///   * `usable` and `lanes`: those are what the matrix MEASURES. Keying on them
///     would let the answer choose the question.
///
/// RAM IS BUCKETED, not exact. Two machines with the same DIMMs report slightly
/// different `system_ram_gb` once firmware reservations differ, and an exact
/// figure would split a twin pair on a number neither user chose.
///
/// NOT A UNIQUENESS CLAIM. Two genuinely identical machines SHOULD collide —
/// that is the point. This says "same hardware", never "same host"; `host_id`
/// remains the identity key and this is deliberately not a substitute for it.
/// Why a fingerprint may not be computed from this document.
///
/// ORDER 805-r98w. Measured on native Windows 2026-09-02: the capability
/// document there carries ONE device — `cpu/unknown/Host CPU`, cores reported
/// 16c16t on an 8c/16t part — with no GPU record, no NPU record, and RAM absent
/// from both `host.ram_gb` and `system_ram_gb`. [`hardware_fingerprint`] hashed
/// that happily and returned `hw1-4714b1195f92e0c6`, which is not an identity:
/// EVERY Windows host reporting 16 logical cores produces that same string.
///
/// A comparison key that silently degrades to a constant is worse than no key,
/// because the failure it produces is a FALSE TWIN — two different machines
/// declared identical — which is the exact failure this order was filed
/// against. So the document must be refused, loudly, naming what is missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FingerprintRefusal {
    pub missing: Vec<String>,
}

impl std::fmt::Display for FingerprintRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "capability document cannot identify this machine (missing: {}) - a fingerprint from it would collide with unrelated hosts",
            self.missing.join(", ")
        )
    }
}

/// The discriminating fields a document must carry before its hash means
/// anything. Deliberately NOT "all of them": a machine with no NPU is still
/// identifiable. The bar is that SOMETHING beyond a placeholder CPU name
/// separates this host from another.
///
/// @trace scripts/hardware-fingerprint.sh (the sibling implementation, whose
/// `compare` mode exists to REFUSE a twin claim rather than bless one)
pub fn hardware_fingerprint_checked(
    doc: &CapabilityDocument,
) -> Result<String, FingerprintRefusal> {
    let mut missing: Vec<String> = Vec::new();

    // A CPU name the probe filled in with a placeholder identifies nothing.
    // "Host CPU" is what the Windows path emits today; "unknown" vendor is the
    // matching tell.
    let cpu_named = doc.devices.iter().any(|d| {
        d.device_class == "cpu" && !d.name.is_empty() && d.name != "Host CPU" && d.name != "unknown"
    });
    if !cpu_named {
        missing.push("cpu model name (probe emitted a placeholder)".to_string());
    }

    let has_gpu = doc.devices.iter().any(|d| d.device_class == "gpu");
    let has_npu = doc.devices.iter().any(|d| d.device_class == "npu");
    let has_ram = doc.devices.iter().any(|d| d.system_ram_gb.is_some());
    if !has_gpu && !has_npu && !has_ram {
        missing.push("every secondary discriminator (no gpu, no npu, no ram)".to_string());
    }

    if missing.is_empty() {
        Ok(hardware_fingerprint(doc))
    } else {
        Err(FingerprintRefusal { missing })
    }
}

/// The outcome of a VALID hardware comparison between two capability documents.
///
/// ORDER 805-r98w. Returned only when the comparison is legitimate; every case
/// where it is not is a [`ComparisonRefusal`], which deliberately carries NO
/// verdict. A refusal that still hands back a hardware answer is worse than
/// either alone — the caller reads the answer and discards the caveat, which is
/// exactly how a false twin gets blessed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FingerprintComparison {
    /// Same fingerprint. NOT a uniqueness claim: two genuinely identical
    /// machine models SHOULD collide, which is the whole point.
    Same(String),
    Different {
        a: String,
        b: String,
    },
}

/// Why two documents may not be compared at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ComparisonRefusal {
    /// One or both documents cannot identify their machine.
    Unidentifiable {
        which: String,
        refusal: FingerprintRefusal,
    },
    /// The documents were produced from different VANTAGES, so their device
    /// records are not commensurable.
    ///
    /// The same machine reports its iGPU as "WSL2 paravirtual GPU (/dev/dxg)"
    /// under WSL2 — the PATH, not the silicon — and emits no GPU device at all
    /// probed natively on Windows. A difference across that boundary is not
    /// evidence of different hardware, so reporting one would be a FALSE
    /// NEGATIVE twin: the mirror of the false positive this order was filed
    /// against, and just as wrong.
    CrossVantage { a_kind: String, b_kind: String },
}

impl std::fmt::Display for ComparisonRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ComparisonRefusal::Unidentifiable { which, refusal } => {
                write!(f, "refused:unidentifiable-document ({which}): {refusal}")
            }
            ComparisonRefusal::CrossVantage { a_kind, b_kind } => write!(
                f,
                "refused:cross-vantage-comparison ({a_kind} vs {b_kind}) - the substrate changes the device records, so a difference here is not evidence of different hardware"
            ),
        }
    }
}

/// Compare two capability documents as HARDWARE, refusing when the comparison
/// would not mean what a reader takes it to mean.
///
/// This is the single implementation of the comparison rule — the shell's
/// `compare` mode calls it rather than restating it, because two copies of an
/// identity rule is the same bug the fingerprint exists to prevent, moved up a
/// layer. Adopted with yoga 2026-09-02.
///
/// Refuses, never guesses:
///   - either document unable to identify its machine (see
///     [`hardware_fingerprint_checked`]),
///   - documents from different `host.host_kind` vantages.
pub fn compare_documents(
    a: &CapabilityDocument,
    b: &CapabilityDocument,
) -> Result<FingerprintComparison, ComparisonRefusal> {
    // Vantage FIRST. A cross-vantage pair must refuse even when both documents
    // are individually fine, and checking identifiability first would let a
    // caller that only inspects the error type believe the vantage was checked.
    if a.host.host_kind != b.host.host_kind {
        return Err(ComparisonRefusal::CrossVantage {
            a_kind: a.host.host_kind.clone(),
            b_kind: b.host.host_kind.clone(),
        });
    }

    let fa =
        hardware_fingerprint_checked(a).map_err(|refusal| ComparisonRefusal::Unidentifiable {
            which: "a".to_string(),
            refusal,
        })?;
    let fb =
        hardware_fingerprint_checked(b).map_err(|refusal| ComparisonRefusal::Unidentifiable {
            which: "b".to_string(),
            refusal,
        })?;

    if fa == fb {
        Ok(FingerprintComparison::Same(fa))
    } else {
        Ok(FingerprintComparison::Different { a: fa, b: fb })
    }
}

/// The version of the FIELD SET the fingerprint is composed from — hashed into
/// the string and carried in its `hw<N>-` prefix. Bump on any change to which
/// fields are included or how they are classed.
pub const FIELD_SET_VERSION: u32 = 2;

// VERSION HISTORY, kept because the reason for the bump is the evidence that
// the mechanism works.
//
// 1 -> 2 (2026-09-02). Version 1 shipped in two INCOMPATIBLE forms and both
// called themselves `hw1-`. The commit that introduced this constant also
// folded `fieldset:N` into the hashed input, which changes the string for
// identical hardware — a field-set change by this constant's own definition —
// and did not bump the version. yoga built off the earlier commit and got
// `hw1-134b5c800683d4d2`; this host on the later one produced a different
// composition under the same tag. Two incomparable strings sharing a version is
// exactly what the constant exists to prevent, and it happened in the commit
// that created it.
//
// Bumping to 2 makes the incompatibility visible instead of silent: every
// string minted before that commit is now distinguishable at a glance. The rule
// stands and is restated here because it was broken once already — bump on ANY
// change to which fields are included, how they are classed, OR how they are
// serialised.
//
// WHY THAT MISS WAS STRUCTURAL, not careless (yoga, 2026-09-02): a version
// constant cannot guard the commit that creates it, because at that moment
// there is no previous version for anything to differ from. The FIRST use of a
// new invariant is the one occurrence the invariant cannot check. Whatever the
// next such guard is, its introducing commit is the one that needs reviewing by
// hand — the guard will cover every case but that one.

pub fn hardware_fingerprint(doc: &CapabilityDocument) -> String {
    fn ram_class(gb: f64) -> String {
        // Nearest power-of-two-ish class. 15.2 and 15.9 are both "16".
        const CLASSES: [f64; 9] = [2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 512.0];
        let best = CLASSES
            .iter()
            .min_by(|a, b| {
                (*a - gb)
                    .abs()
                    .partial_cmp(&(*b - gb).abs())
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .copied()
            .unwrap_or(gb);
        format!("{best:.0}")
    }

    let mut parts: Vec<String> = Vec::new();
    let mut ram: Option<String> = None;
    for d in &doc.devices {
        match d.device_class.as_str() {
            "cpu" => {
                let cores = d
                    .cpu_cores
                    .as_ref()
                    .map(|c| format!("{}c{}t", c.physical, c.logical))
                    .unwrap_or_else(|| "?c?t".to_string());
                parts.push(format!("cpu:{}/{}/{}", d.vendor, d.name, cores));
            }
            "gpu" => parts.push(format!("gpu:{}/{}", d.vendor, d.name)),
            "npu" => parts.push(format!(
                "npu:{}/{}",
                d.vendor,
                d.device_node.as_deref().unwrap_or("-")
            )),
            _ => {}
        }
        // First device carrying a RAM figure wins; `map` keeps this flat, which
        // clippy's collapsible_if requires under the gate's -D warnings.
        if ram.is_none() {
            ram = d.system_ram_gb.map(ram_class);
        }
    }
    parts.sort();
    if let Some(r) = ram {
        parts.push(format!("ram:{r}"));
    }
    // ORDER 805-r98w, adopted from yoga 2026-09-02. The field-set version is
    // HASHED, not merely prefixed. A tag bolted on the front can be stripped,
    // ignored, or compared away by a caller that only looks at the hex; folding
    // it into the input makes a v1 and a v2 string differ EVERYWHERE, so they
    // can never be silently compared even by code that never heard of the tag.
    //
    // Bump FIELD_SET_VERSION whenever the composition of `parts` changes —
    // fields added, removed, or classed differently (the RAM rounding included).
    // That is what makes such a change safe: it becomes a visible
    // incompatibility rather than two hosts quietly disagreeing about what a
    // number means.
    parts.insert(0, format!("fieldset:{FIELD_SET_VERSION}"));
    let joined = parts.join("|");
    // cksum-grade is enough: this is a comparison key, not a security boundary,
    // and a readable prefix beats an opaque digest when a human is asking why
    // two rows did not match.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in joined.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    format!("hw{FIELD_SET_VERSION}-{h:016x}")
}

/// Upgrade a node to [`Proof::Placed`] from a runtime's reported residency.
///
/// 793-zumy REMAINING 2, second half. Takes the residency as a VALUE rather than
/// fetching it, which keeps the only rung that proves a lane decidable without a
/// network round trip and testable without a live runtime. The caller supplies
/// `resident_bytes` — in practice the sum of `size_vram` across
/// `ollama /api/ps` — and the IO stays at the caller's layer where it can be
/// mocked, timed, and refused independently.
///
/// EXACTLY-ONE-CANDIDATE OR NOTHING, and this is the load-bearing rule.
/// `/api/ps` reports residency per MODEL, never per DEVICE. On a host with one
/// candidate node the attribution is unambiguous; with two it is a guess, and a
/// guess recorded as `Placed` is precisely this packet's failure class — a label
/// standing in for the wiring it names, one rung higher and therefore worse.
/// With zero or several candidates this returns `None` and upgrades nothing.
///
/// CANDIDATES ARE `Reachable` NODES, not merely enumerated ones: a runtime
/// cannot have placed weights on a device the work's vantage cannot even stat.
/// That ordering is why the rungs are ordered.
///
/// NOT A CAPACITY CLAIM, restating the enum's own caveat because this is the
/// function that could quietly become one: non-zero residency proves weights
/// landed, not that the device does the compute (a partial offload reports
/// non-zero VRAM with most layers on CPU) and not that a larger model would fit.
///
/// Returns the node index upgraded, or `None` when nothing could be attributed.
pub fn upgrade_placed(nodes: &mut [DrmRenderNode], resident_bytes: u64) -> Option<usize> {
    if resident_bytes == 0 {
        return None;
    }
    let mut candidates = nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.proof >= Proof::Reachable);
    let (idx, _) = candidates.next()?;
    if candidates.next().is_some() {
        // Two or more reachable nodes and a per-model residency figure: the
        // honest answer is that we cannot say WHICH one, so we say nothing.
        return None;
    }
    if nodes[idx].proof < Proof::Placed {
        nodes[idx].proof = Proof::Placed;
    }
    Some(idx)
}

/// Upgrade `Enumerated` nodes to [`Proof::Reachable`] by STATTING them from the
/// vantage the work runs in.
///
/// 793-zumy REMAINING 2, first half. The rungs were modelled but inert: nothing
/// produced anything above `Enumerated`, and an honest model that does no work
/// is only half the fix.
///
/// THE IN-TREE PRECEDENT IS `images/inference/entrypoint.sh`, which refuses a
/// cuda tier when `[ -e /dev/nvidia0 ]` fails INSIDE the container. This is that
/// check, lifted into the probe and given a rung.
///
/// CONTAINER VANTAGE ONLY, and this is the whole point rather than a
/// restriction. [`Vantage::Container`] is documented as the only vantage that
/// can speak for the container lane, so a HOST stat is not weaker evidence for
/// that lane — it is evidence about a different question. A node enumerated on
/// the host and statted on the host stays `Enumerated`; claiming otherwise
/// would be this packet's own failure class, a label standing in for the wiring
/// it names.
///
/// STILL NOT A LANE. Reachable is necessary and NOT sufficient: yoga's host sat
/// exactly here with the device statted and `size_vram` still 0. Only
/// [`Proof::Placed`] proves a lane, and nothing here produces it.
///
/// Never downgrades: a node already at a higher rung is left alone.
pub fn upgrade_reachable_at(nodes: &mut [DrmRenderNode], dev_dri_root: &std::path::Path) -> usize {
    let mut upgraded = 0;
    for n in nodes.iter_mut() {
        if n.vantage != Vantage::Container {
            continue;
        }
        if n.proof >= Proof::Reachable {
            continue;
        }
        // `exists()` follows symlinks, which is what we want: /dev/dri entries
        // are commonly symlinked and the question is whether opening the path
        // would find a device, not whether the entry is itself a node.
        if dev_dri_root.join(&n.node).exists() {
            n.proof = Proof::Reachable;
            upgraded += 1;
        }
    }
    upgraded
}

/// The shell the container-vantage producer runs INSIDE the container.
///
/// 793-zumy REMAINING 2. The in-tree precedent this packet names is
/// `images/inference/entrypoint.sh`, which refuses a cuda tier when
/// `[ -e /dev/nvidia0 ]` fails THERE rather than on the host. This is that
/// check generalised: one bounded, read-only `sh` that cats the four sysfs
/// files identifying each render node and lists `/dev/dri`, emitting a
/// line-oriented blob a pure function can parse.
///
/// WHY BOTH SECTIONS IN ONE EXEC. `/sys` is bind-mounted from the host into a
/// podman container whether or not any device was passed, so a sysfs walk run
/// inside the container still describes the HOST's silicon - it establishes
/// identity, never access. `/dev/dri` is the half that answers the container's
/// own question. Splitting them across two execs would let the two halves
/// describe different moments; taking both in one round trip is also the
/// cheaper thing to do.
///
/// It writes nothing and reads only sysfs and a device directory listing, so it
/// is safe to run against a container serving live inference.
const CONTAINER_PROOF_SH: &str = r#"
for d in /sys/class/drm/renderD*; do
  [ -d "$d/device" ] || continue
  n=${d##*/}
  v=$(cat "$d/device/vendor" 2>/dev/null)
  p=$(cat "$d/device/device" 2>/dev/null)
  dr=$(readlink "$d/device/driver" 2>/dev/null)
  dr=${dr##*/}
  printf 'DRM\t%s\t%s\t%s\t%s\n' "$n" "$v" "$p" "${dr:-unknown}"
done
for e in /dev/dri/*; do
  [ -e "$e" ] || continue
  printf 'DEV\t%s\n' "${e##*/}"
done
"#;

/// Parse [`CONTAINER_PROOF_SH`]'s output into `(render nodes, /dev/dri entries)`.
///
/// Pure, so the whole container-vantage path is testable without podman, a
/// container, or a GPU - which matters because the hosts that must REVIEW this
/// code (a Windows host whose probe runs natively, a macOS host) can never run
/// it. Identity assembly is delegated to [`assemble_render_node`]: this
/// function transports bytes and does not decide what a render node is.
///
/// Unparseable and short lines are SKIPPED rather than defaulted. A blob that
/// arrived truncated must yield fewer nodes, never a node with invented fields.
pub fn parse_container_proof_output(
    text: &str,
    vantage: Vantage,
) -> (Vec<DrmRenderNode>, Vec<String>) {
    let mut nodes = Vec::new();
    let mut dev_entries = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.trim_end().split('\t').collect();
        match f.first().copied() {
            Some("DRM") if f.len() == 5 => {
                if let Some(n) = assemble_render_node(f[1], f[2], f[3], f[4], vantage) {
                    nodes.push(n);
                }
            }
            Some("DEV") if f.len() == 2 && !f[1].is_empty() => {
                dev_entries.push(f[1].to_string());
            }
            _ => {}
        }
    }
    nodes.sort_by(|a, b| a.node.cmp(&b.node));
    (nodes, dev_entries)
}

/// Upgrade `Enumerated` nodes to [`Proof::Reachable`] from a LISTING of the
/// device directory as seen from the work's vantage.
///
/// 793-zumy REMAINING 2, first half, for the vantage that cannot be reached by
/// [`upgrade_reachable_at`]: the container's `/dev/dri` is not a path this
/// process can stat, so the stat happens over there and this consumes its
/// result. The RULES are identical - container vantage only, never downgrades,
/// no rung claimed for a node the listing does not name.
///
/// A HOST-VANTAGE NODE IS SKIPPED even if the listing names it, exactly as in
/// the filesystem sibling. A host stat is not weaker evidence for the container
/// lane; it is evidence about a different question, and blurring the two is
/// this packet's own failure class.
///
/// STILL NOT A LANE. Reachable is necessary and not sufficient: yoga's host sat
/// exactly here, with `/dev/kfd` and `/dev/dri/renderD128` both stat-able
/// inside the container and `size_vram` still 0.00GB because the image shipped
/// no runtime that could drive them.
pub fn upgrade_reachable_from_listing(nodes: &mut [DrmRenderNode], listing: &[String]) -> usize {
    let mut upgraded = 0;
    for n in nodes.iter_mut() {
        if n.vantage != Vantage::Container {
            continue;
        }
        if n.proof >= Proof::Reachable {
            continue;
        }
        if listing.iter().any(|e| e == &n.node) {
            n.proof = Proof::Reachable;
            upgraded += 1;
        }
    }
    upgraded
}

/// Total bytes a runtime reports RESIDENT on an accelerator, from one
/// `ollama /api/ps` body.
///
/// 793-zumy REMAINING 2, second half. [`upgrade_placed`] deliberately takes the
/// figure as a value rather than fetching it; this is the parser that turns a
/// response into that value, kept pure for the same reason.
///
/// `None` MEANS UNKNOWN AND MUST NOT COLLAPSE INTO ZERO. A body that does not
/// parse, or that carries no `models` array, is a runtime we could not ask -
/// which is a different fact from a runtime that answered "nothing is
/// resident", and [`upgrade_placed`] treats zero as a definite refusal.
/// Reporting unknown as zero would be an affirmative denial derived from a
/// failed question, the same shape as the `accel_npu=none` this family already
/// corrected.
///
/// A model row missing `size_vram` contributes 0 rather than poisoning the sum:
/// ollama omits the key for a CPU-resident model, and that genuinely is no
/// accelerator residency.
pub fn parse_ollama_resident_bytes(body: &str) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let models = v.get("models")?.as_array()?;
    let mut total: u64 = 0;
    for m in models {
        total = total.saturating_add(m.get("size_vram").and_then(|b| b.as_u64()).unwrap_or(0));
    }
    Some(total)
}

/// PRODUCE the container lane's proof rungs, with both IO edges injected.
///
/// 793-zumy REMAINING 2, the composition the packet was actually asking for:
/// the rungs were modelled, pinned and inert, because NOTHING CALLED the
/// upgraders outside their own tests. An honest model that does no work is only
/// half the fix. This is the caller.
///
/// `probe` runs [`CONTAINER_PROOF_SH`] inside the container; `residency`
/// fetches `/api/ps` from the runtime in it. Both return `None` when they could
/// not ask. Injected rather than called directly so the composition - which is
/// where the rung ordering actually gets enforced - is testable without podman,
/// a container, a GPU, or a network, on every host in the fleet.
///
/// THE ORDERING IS THE POINT AND IT IS ENFORCED HERE, not documented here:
/// residency is applied only to nodes that reached `Reachable`, and
/// [`upgrade_placed`] refuses when the attribution is ambiguous. A `Placed` this
/// function emits therefore rests on a device the container could stat AND a
/// runtime that reported weights on exactly one candidate.
///
/// An unreachable container yields an EMPTY vec, never a fabricated row: no
/// evidence is not evidence of absence.
pub fn produce_container_proofs_with<P, R>(mut probe: P, mut residency: R) -> Vec<DrmRenderNode>
where
    P: FnMut() -> Option<String>,
    R: FnMut() -> Option<String>,
{
    let Some(blob) = probe() else {
        return Vec::new();
    };
    let (mut nodes, dev_entries) = parse_container_proof_output(&blob, Vantage::Container);
    upgrade_reachable_from_listing(&mut nodes, &dev_entries);
    // Asked ONLY when something could actually carry a placement. With no
    // reachable node the answer cannot change any rung, and this keeps a probe
    // on a CPU-only host from making a round trip to learn nothing.
    if nodes.iter().any(|n| n.proof >= Proof::Reachable)
        && let Some(bytes) = residency().as_deref().and_then(parse_ollama_resident_bytes)
    {
        upgrade_placed(&mut nodes, bytes);
    }
    nodes
}

/// The podman containers the fleet's ollama can run in, most-specific first.
///
/// CORRECTED 2026-09-02, MEASURED BY YOGA, and the correction is the point.
/// This was a single hardcoded `"tillandsias-inference"` while
/// `scripts/dev-inference-ensure.sh:102` creates `tillandsias-dev-inference`
/// on every dev host. So the producer execed into a container that does not
/// exist there, got nothing, and reported the bottom of the scale on a machine
/// where the lane demonstrably works — devices passed, `/api/ps` answering from
/// inside the container that IS running.
///
/// That is the sixth instance this cycle of one name fixed in one place: the
/// plan-binary probe, the hardware fingerprint, this probe's own two
/// transports, the Windows purge clear, the embed endpoint, and now this. The
/// remedy is the same one: not a second hardcoded name beside the first, which
/// is how these drift, but ONE resolution with the environment as the single
/// source when a caller knows better.
///
/// `TILLANDSIAS_INFERENCE_CONTAINER` is that hook: the lane that CREATES the
/// container can name it, and then there is one source rather than a list this
/// file has to keep in sync with a shell script.
const INFERENCE_CONTAINER_CANDIDATES: [&str; 2] =
    ["tillandsias-inference", "tillandsias-dev-inference"];

/// Which inference container is actually present, or `None` when there is none
/// to ask.
///
/// `None` IS THE LOAD-BEARING RETURN. It is the difference between "we asked
/// the container lane and it has nothing" and "there was no container lane to
/// ask", and yoga's measurement is what proved those must not share a token: on
/// their host the envelope read `accel_proof=-` — identical to a machine with
/// no accelerator at all — while the lane was working. The failure was silent
/// and it under-claimed, which is the direction this file already warns is the
/// one that gets missed, because the wasted work it causes looks like
/// diligence.
fn resolve_inference_container() -> Option<String> {
    let exists = |name: &str| -> bool {
        tillandsias_podman::podman_cmd_sync()
            .args(["container", "exists", name])
            .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
            .ok()
            .map(|o| o.status.success())
            .unwrap_or(false)
    };
    if let Ok(name) = std::env::var("TILLANDSIAS_INFERENCE_CONTAINER")
        && !name.trim().is_empty()
    {
        // An EXPLICIT name is the caller naming the container, not a candidate
        // to be judged — the same rule plan-binary-probe.sh applies to
        // TILLANDSIAS_PLAN_BIN, and for the same reason: probing an override
        // collapses "you named the wrong one" into "there is none".
        return Some(name.trim().to_string());
    }
    INFERENCE_CONTAINER_CANDIDATES
        .iter()
        .find(|n| exists(n))
        .map(|n| n.to_string())
}

/// Run one bounded, read-only command inside the resolved inference container.
///
/// Never `--tty` and never attaching stdin: an exec that attaches stdin can
/// wedge a one-shot launch forever absorbing SIGTERM, which `main.rs`'s
/// readiness probe already learned. Any non-success exit reads as "could not
/// ask" - `None`, not an empty answer.
fn inference_container_exec(container: &str, args: &[&str]) -> Option<String> {
    let mut cmd = tillandsias_podman::podman_cmd_sync();
    cmd.args(["exec", container]);
    cmd.args(args);
    let out = cmd
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
        .ok()
        .filter(|o| o.status.success())?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

/// PRODUCTION entry point for the container lane's proof rungs.
///
/// 793-zumy REMAINING 2. Wires [`produce_container_proofs_with`] to the two real
/// IO edges: `podman exec ... sh -c CONTAINER_PROOF_SH` for identity and
/// reachability, and `podman exec ... curl /api/ps` for residency. `127.0.0.1`
/// deliberately - inside the inference container the runtime is local whatever
/// the enclave's DNS is doing, which is the same reason `main.rs`'s readiness
/// probe uses it.
///
/// DO NOT USE `podman inspect ... HostConfig.Devices` AS THE REACHABILITY CHECK.
/// Measured by yoga 2026-09-02 on gfx1152: that field prints `[]` for a
/// container whose `/dev/kfd` and `/dev/dri/*` nodes ARE present inside. It is a
/// label that reads as evidence the wiring happened, which is this packet's
/// entire failure class arriving from the tooling instead of from us. Exec and
/// list the nodes.
///
/// THE DIRECTION MATTERS: it is a FALSE NEGATIVE. The field reads `[]` on a host
/// where the devices WERE passed, so a verifier trusting it concludes "no
/// devices passed" and goes off re-fixing a passthrough that already works -
/// which is what 937-68n4 landed. This family's other four instances all failed
/// the other way, toward an over-claim; this one is worth naming separately
/// because the wasted work it causes looks like diligence.
pub fn probe_container_render_nodes() -> ContainerLaneProbe {
    let Some(container) = resolve_inference_container() else {
        return ContainerLaneProbe {
            nodes: Vec::new(),
            asked: None,
        };
    };
    let nodes = produce_container_proofs_with(
        || inference_container_exec(&container, &["sh", "-c", CONTAINER_PROOF_SH]),
        || {
            inference_container_exec(
                &container,
                &[
                    "curl",
                    "-fsS",
                    "--max-time",
                    "2",
                    "http://127.0.0.1:11434/api/ps",
                ],
            )
        },
    );
    ContainerLaneProbe {
        nodes,
        asked: Some(container),
    }
}

/// What the container-lane probe found AND whether there was anything to ask.
///
/// The second field exists because an empty `nodes` means two different things
/// and the envelope must not render them the same. See
/// [`resolve_inference_container`] for the measurement that forced the split.
pub struct ContainerLaneProbe {
    pub nodes: Vec<DrmRenderNode>,
    /// The container actually probed, or `None` when none was present.
    pub asked: Option<String>,
}

/// Does ONE spec body name the NVIDIA kind AND a usable device node?
///
/// Split out so it is testable without the filesystem: a spec that names the
/// kind but no `/dev/nvidiaN` node cannot deliver a GPU, and neither can one
/// whose node sits under a self-referential `/run/host` prefix — that lands at
/// the wrong in-container path, which is exactly the spec a bad `--dev-root`
/// produced on this host.
#[cfg(target_os = "linux")]
fn spec_body_delivers_nvidia(body: &str) -> bool {
    body.contains("nvidia.com/gpu") && body.contains("/dev/nvidia") && !body.contains("/run/host")
}

#[cfg(target_os = "linux")]
fn spec_file_delivers_nvidia(path: &std::path::Path) -> bool {
    std::fs::read_to_string(path)
        .map(|b| spec_body_delivers_nvidia(&b))
        .unwrap_or(false)
}

#[cfg(target_os = "linux")]
fn nvidia_cdi_deliverable() -> bool {
    // podman's own default search path, plus the user dir a rootless immutable
    // host must use (podman does not search it unless containers.conf declares
    // it — the correction recorded on 665-zddn).
    let mut dirs: Vec<std::path::PathBuf> = vec![
        std::path::PathBuf::from("/etc/cdi"),
        std::path::PathBuf::from("/var/run/cdi"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(std::path::Path::new(&home).join(".config/cdi"));
    }

    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("yaml") {
                continue;
            }
            if spec_file_delivers_nvidia(&path) {
                return true;
            }
        }
    }
    false
}

/// ORDER 935-jhh5: `effective_tier` USED TO BE A PARAMETER HERE and is gone on
/// purpose. Its only consumer was `cdi_ok = effective_tier == "gpu-cuda"`, and
/// that tier is itself derived from the same `nvidia-smi` this function already
/// runs — so the parameter was the circularity, carried in by signature. The
/// compiler flagging it unused the moment the real check landed is the proof
/// that the dependency is severed rather than merely rerouted.
/// The sysfs facts the memory-model classifier decides on (order 964-r98h).
///
/// A struct rather than three parameters so the classifier is a pure function
/// over EVIDENCE, testable without the hardware that produced it — every case
/// below is a real machine somebody has, and only one of them is this one.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
// @trace order:964-r98h, spec:accel-capability-probe
pub struct GpuMemoryEvidence {
    /// `mem_info_vram_total` — amdgpu only; absent for every other driver.
    pub vram_total: Option<u64>,
    /// `mem_info_vis_vram_total` — the CPU-VISIBLE part of the above.
    pub vis_vram_total: Option<u64>,
    /// The largest prefetchable PCI BAR: the device's memory aperture.
    pub largest_prefetchable_bar: Option<u64>,
}

/// A dedicated memory aperture at or above this size cannot be a window onto
/// system RAM — nothing carves a gigabyte-scale prefetchable BAR for an
/// integrated part. Measured on this host: the discrete RTX 3070 exposes an
/// 8192 MiB prefetchable BAR (resizable BAR enabled) and the integrated Vega
/// exposes 256 MiB.
const DISCRETE_BAR_FLOOR_BYTES: u64 = 1024 * 1024 * 1024;

/// Decide a device's memory model from sysfs evidence, or refuse.
///
/// READ THE FIRST RUNG BEFORE ANYTHING ELSE, BECAUSE THIS HOST FALSIFIED THE
/// OBVIOUS RULE — including the one I wrote into 964-r98h's own context, which
/// proposed that `mem_info_vram_total` "is absent or zero for an integrated
/// part". Measured here, it is exactly backwards:
///
///     card0  NVIDIA RTX 3070 (DISCRETE)    no mem_info_vram_total at all
///     card1  AMD Vega iGPU  (INTEGRATED)   mem_info_vram_total = 2 GiB
///
/// The file belongs to `amdgpu`, not to dedicated memory: the proprietary
/// NVIDIA driver does not export it, and an APU DOES, because its BIOS carves a
/// UMA region out of system RAM and amdgpu reports that carve-out as VRAM. A
/// classifier built on "has a VRAM total => discrete" would have labelled both
/// devices on this machine wrongly, in opposite directions, and passed review.
///
/// THE RUNGS, each sound on its own and tried in order:
///
/// 1. `vis_vram < vram` => DISCRETE. Part of the device's memory is not
///    CPU-visible, so there is memory behind an aperture — which only exists
///    when the memory is the device's own. This is the pre-resizable-BAR
///    signature (a 256 MiB window onto 8 GiB of VRAM) and it is decisive.
///
/// 2. A prefetchable BAR >= 1 GiB => DISCRETE. The resizable-BAR case, where
///    rung 1 goes quiet because the whole of VRAM became CPU-visible.
///
/// 3. `vram` known, fully CPU-visible, and NO large aperture => UNIFIED. All of
///    the device's memory is reachable through a small window, which is what a
///    UMA carve-out looks like and what dedicated VRAM never looks like. This
///    is the weakest rung and its limit is stated rather than hidden: a
///    hypothetical discrete board with under a gigabyte of VRAM and no
///    resizable BAR would land here wrongly. No such part is in this fleet, and
///    the rung is guarded by requiring the amdgpu VRAM figure to be present at
///    all — a driver that reports no VRAM never reaches it.
///
/// 4. Otherwise `None`. NOT a vendor lookup. A vendor table would answer for
///    the NVIDIA card above without evidence, and 964-r98h exists precisely
///    because `unified` is wrong for a discrete Radeon and `discrete` is wrong
///    for every iGPU in the fleet — a guess that is right about most hosts is
///    the confident half-answer this packet family keeps removing.
// @trace order:964-r98h, spec:accel-capability-probe
pub fn memory_model_from_evidence(e: &GpuMemoryEvidence) -> Option<&'static str> {
    if let (Some(vram), Some(vis)) = (e.vram_total, e.vis_vram_total)
        && vram > 0
        && vis < vram
    {
        return Some("discrete");
    }
    if e.largest_prefetchable_bar
        .is_some_and(|b| b >= DISCRETE_BAR_FLOOR_BYTES)
    {
        return Some("discrete");
    }
    if let (Some(vram), Some(vis), Some(bar)) =
        (e.vram_total, e.vis_vram_total, e.largest_prefetchable_bar)
        && vram > 0
        && vis >= vram
        && bar < DISCRETE_BAR_FLOOR_BYTES
    {
        return Some("unified");
    }
    None
}

/// Read the evidence for one PCI device from sysfs (order 964-r98h).
///
/// Everything here is best-effort: a missing or unreadable file is `None`, not
/// a zero. Zero is a claim about the hardware and absence is a claim about the
/// probe, and collapsing them is the failure this whole packet family is about.
#[cfg(target_os = "linux")]
// @trace order:964-r98h, spec:accel-capability-probe
fn read_gpu_memory_evidence(pci_addr: &str) -> GpuMemoryEvidence {
    let dev = PathBuf::from("/sys/bus/pci/devices").join(pci_addr);
    let read_u64 = |name: &str| -> Option<u64> {
        fs::read_to_string(dev.join(name))
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
    };
    GpuMemoryEvidence {
        vram_total: read_u64("mem_info_vram_total"),
        vis_vram_total: read_u64("mem_info_vis_vram_total"),
        largest_prefetchable_bar: fs::read_to_string(dev.join("resource"))
            .ok()
            .map(|s| largest_prefetchable_bar(&s)),
    }
}

/// The largest prefetchable BAR in a sysfs `resource` file, in bytes.
///
/// Each line is `<start> <end> <flags>` in hex. A zero-sized BAR reads
/// `0x0 0x0 0x0`, and PREFETCHABLE (bit 3 of the flags) is what distinguishes a
/// memory aperture from an MMIO register window — the RTX 3070's 16 MiB
/// register BAR is not evidence of anything, and counting it would put every
/// GPU over a megabyte-scale floor.
///
/// A pure function over the file's TEXT so the parser is testable without a
/// PCI device, which matters more than usual here: this is the one place a
/// silent misparse would produce a confident wrong classification rather than
/// an honest `None`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
// @trace order:964-r98h, spec:accel-capability-probe
fn largest_prefetchable_bar(resource_file: &str) -> u64 {
    const PCI_PREFETCHABLE: u64 = 0x8;
    let hex = |t: &str| u64::from_str_radix(t.trim_start_matches("0x"), 16).ok();
    resource_file
        .lines()
        .filter_map(|line| {
            let mut f = line.split_whitespace();
            let (start, end, flags) = (hex(f.next()?)?, hex(f.next()?)?, hex(f.next()?)?);
            if end <= start || flags & PCI_PREFETCHABLE == 0 {
                return None;
            }
            Some(end - start + 1)
        })
        .max()
        .unwrap_or(0)
}

fn enumerate_gpus() -> Vec<DeviceRecord> {
    let mut gpus = Vec::new();

    // The tier no longer reaches this function at all (order 935-jhh5). It used
    // to be a parameter whose ONLY consumer was the Linux arm's
    // `cdi_ok = effective_tier == "gpu-cuda"` — a check derived from the same
    // `nvidia-smi` that arm already runs. With that circularity removed the
    // parameter went too, and this `let _ = effective_tier;` — the
    // non-Linux fallback that existed purely to silence the resulting
    // unused-parameter warning — went with it. The cross-target gate (656-spux)
    // caught it: it compiles on the host either way, and only the Windows
    // target proved the line was now referencing something that no longer
    // exists. The macOS arm is host-native only by spec (PROBE-7).

    #[cfg(target_os = "macos")]
    {
        // PROBE-7: macOS Metal is host-native ONLY, container MUST NOT appear
        gpus.push(DeviceRecord {
            device_class: "gpu".to_string(),
            vendor: "apple".to_string(),
            name: "Apple Metal GPU".to_string(),
            device_node: None,
            fw_version: None,
            driver: None,
            usable: true,
            unusable_reason: None,
            lanes: vec!["host-native".to_string()],
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            system_ram_gb: None,
            memory_model: None,
        });
    }

    #[cfg(target_os = "linux")]
    {
        let nvidia_present = Command::new("nvidia-smi")
            .arg("-L")
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty());

        if let Some(nvidia_output) = nvidia_present {
            let cdi_ok = nvidia_cdi_deliverable();
            let lanes = if cdi_ok {
                vec!["container".to_string(), "host-native".to_string()]
            } else {
                vec!["host-native".to_string()]
            };
            let unusable_reason = if cdi_ok {
                None
            } else {
                Some("cdi-spec-missing".to_string())
            };
            let first_line = nvidia_output.lines().next().unwrap_or("NVIDIA GPU");
            // Order 964-r98h. This arm is built from `nvidia-smi`, which knows
            // the card but not its sysfs path, so the memory evidence is
            // fetched via the DRM enumeration's PCI address for the same
            // silicon. Deliberately NOT a vendor shortcut: `0x10de` would give
            // the answer for free and would be a guess, and this host is the
            // one that shows why that matters — the NVIDIA card exports no
            // `mem_info_vram_total` at all, so it is classified from its 8 GiB
            // prefetchable BAR, which is evidence, or it is not classified.
            let nvidia_memory_model = drm_cards()
                .into_iter()
                .find(|(_, vendor_id, _)| vendor_id == "0x10de")
                .and_then(|(pci_addr, _, _)| {
                    memory_model_from_evidence(&read_gpu_memory_evidence(&pci_addr))
                })
                .map(|m| m.to_string());
            gpus.push(DeviceRecord {
                device_class: "gpu".to_string(),
                vendor: "nvidia".to_string(),
                name: nvidia_model_name(first_line),
                device_node: Some("/dev/nvidia0".to_string()),
                fw_version: None,
                driver: None,
                usable: true,
                unusable_reason,
                lanes,
                memory_bandwidth_gbps: None,
                memory_bandwidth_source: "unknown".to_string(),
                cpu_flags: None,
                cpu_cores: None,
                system_ram_gb: None,
                memory_model: nvidia_memory_model,
            });
        }

        // Order 850-bif2: enumerate DRM cards by PCI identity. The old arm
        // fired only when NO GPU had been found yet — an AMD iGPU beside an
        // NVIDIA dGPU was invisible to the matrix — and hardcoded vendor
        // "amd" for whatever it hit. /sys/class/drm/card*/device carries the
        // real vendor id and driver, so nothing here substring-matches prose
        // (the comp-ATI-ble trap; see scripts/derive-host-identity.sh).
        let rocm_gfx = rocm_gfx_present();
        let kfd = Path::new("/dev/kfd").exists();
        let intel_rt = intel_compute_runtime_present();
        for (pci_addr, vendor_id, driver) in drm_cards() {
            let render_node = drm_render_node_for(&pci_addr);
            match (vendor_id.as_str(), driver.as_deref()) {
                // The nvidia-smi arm above owns NVIDIA cards; re-reporting
                // them here would double-count the same silicon.
                ("0x10de", _) => continue,
                ("0x1002", Some("amdgpu")) => {
                    let (usable, lanes, unusable_reason) =
                        amd_gpu_disposition(rocm_gfx, kfd, render_node.is_some());
                    gpus.push(DeviceRecord {
                        device_class: "gpu".to_string(),
                        vendor: "amd".to_string(),
                        name: pci_device_name_via_lspci(&pci_addr)
                            .unwrap_or_else(|| "AMD GPU (amdgpu)".to_string()),
                        device_node: render_node,
                        fw_version: None,
                        driver: Some("amdgpu".to_string()),
                        usable,
                        unusable_reason,
                        lanes,
                        memory_bandwidth_gbps: None,
                        memory_bandwidth_source: "unknown".to_string(),
                        cpu_flags: None,
                        cpu_cores: None,
                        system_ram_gb: None,
                        memory_model: memory_model_from_evidence(&read_gpu_memory_evidence(
                            &pci_addr,
                        ))
                        .map(|m| m.to_string()),
                    });
                }
                // Order 855-wrr3: Intel now has a disposition of its own
                // instead of falling to the last-resort `usable: true` arm.
                ("0x8086", Some("i915")) | ("0x8086", Some("xe")) => {
                    let (usable, lanes, unusable_reason) =
                        intel_gpu_disposition(intel_rt, render_node.is_some());
                    gpus.push(DeviceRecord {
                        device_class: "gpu".to_string(),
                        vendor: "intel".to_string(),
                        name: pci_device_name_via_lspci(&pci_addr)
                            .unwrap_or_else(|| "Intel GPU".to_string()),
                        device_node: render_node,
                        fw_version: None,
                        driver,
                        usable,
                        unusable_reason,
                        lanes,
                        memory_bandwidth_gbps: None,
                        memory_bandwidth_source: "unknown".to_string(),
                        cpu_flags: None,
                        cpu_cores: None,
                        system_ram_gb: None,
                        memory_model: memory_model_from_evidence(&read_gpu_memory_evidence(
                            &pci_addr,
                        ))
                        .map(|m| m.to_string()),
                    });
                }
                // Any other vendor keeps the old last-resort shape — but only
                // when nothing else was found, and with the REAL vendor
                // instead of the old hardcoded "amd".
                (vid, _) if gpus.is_empty() => {
                    gpus.push(DeviceRecord {
                        device_class: "gpu".to_string(),
                        vendor: match vid {
                            "0x8086" => "intel".to_string(),
                            "0x1002" => "amd".to_string(),
                            _ => "unknown".to_string(),
                        },
                        name: pci_device_name_via_lspci(&pci_addr)
                            .unwrap_or_else(|| "Vulkan GPU".to_string()),
                        device_node: render_node
                            .or_else(|| Some(format!("/sys/bus/pci/devices/{pci_addr}"))),
                        fw_version: None,
                        driver,
                        usable: true,
                        unusable_reason: None,
                        lanes: vec!["container".to_string(), "host-native".to_string()],
                        memory_bandwidth_gbps: None,
                        memory_bandwidth_source: "unknown".to_string(),
                        cpu_flags: None,
                        cpu_cores: None,
                        system_ram_gb: None,
                        memory_model: memory_model_from_evidence(&read_gpu_memory_evidence(
                            &pci_addr,
                        ))
                        .map(|m| m.to_string()),
                    });
                }
                _ => {}
            }
        }

        if wsl2_paravirtual_gpu(
            Path::new("/dev/dxg").exists(),
            Path::new("/dev/dri").exists(),
            !gpus.is_empty(),
        ) {
            gpus.push(DeviceRecord {
                device_class: "gpu".to_string(),
                // /dev/dxg is vendor-AGNOSTIC: Intel, AMD and NVIDIA all present
                // through it under WSL2 (measured on two Windows hosts, an Intel
                // UHD and an AMD Radeon 860M). Naming a vendor here would be a
                // guess, and a wrong vendor in the fleet matrix is worse than an
                // honest "unknown".
                vendor: "unknown".to_string(),
                name: "WSL2 paravirtual GPU (/dev/dxg)".to_string(),
                device_node: Some("/dev/dxg".to_string()),
                fw_version: None,
                driver: None,
                usable: false,
                // ORDER 793-zumy. This said `wsl2-no-dri-render-node`, and that
                // reason was a red herring dressed as a diagnosis. WSL2 delivers
                // the GPU through /dev/dxg and is NOT EXPECTED to create a DRI
                // render node at all, so naming the render node's absence as the
                // obstruction describes normal WSL2 rather than anything wrong —
                // while reading, to a scheduler, as a hardware verdict. Measured
                // on yolanda 2026-08-29: /dev/dxg present, /dev/dri absent,
                // /usr/lib/wsl/lib carrying libd3d12/libd3d12core/libdxcore, and
                // NO Vulkan loader — vulkaninfo off PATH, /usr/share/vulkan/icd.d
                // absent entirely. The device is delivered; the translation layer
                // is not installed. That is the real obstruction and it is a
                // PROVISIONING fact, three packages away (793-a8e7), not a
                // statement about the silicon. The same host has already driven
                // this GPU at 2.04x CPU prefill once a loader was present.
                //
                // `engine-missing` is the grammar's existing word for exactly
                // this — hardware present, no runtime to reach it — and is what
                // the packet's criterion 2 requires verbatim. The suffix keeps
                // WHICH engine and therefore what would fix it, matching the
                // sibling `rocm-runtime-missing` / `intel-compute-runtime-missing`
                // shape: a provisioning statement should name its own remedy.
                //
                // THE VERDICT IS DELIBERATELY UNCHANGED. usable stays false and
                // the class stays cpu-only: nothing here makes the GPU reachable
                // today, and inflating the class would place GPU work on a host
                // that cannot run it — the opposite failure, and the worse one.
                unusable_reason: Some(wsl2_paravirtual_gpu_reason().to_string()),
                // No lane: unreachable from the container AND from host-native
                // code in the guest, because no Vulkan ICD is installed to
                // translate onto the dxg path.
                lanes: vec![],
                memory_bandwidth_gbps: None,
                memory_bandwidth_source: "unknown".to_string(),
                cpu_flags: None,
                cpu_cores: None,
                system_ram_gb: None,
                memory_model: None,
            });
        }
    }

    gpus
}

// @trace spec:accel-capability-probe
/// Run a PowerShell query and return its non-empty stdout lines, or `None` when
/// the query could not be RUN at all.
///
/// ORDER 805-r98w. `None` and `Some(vec![])` are different facts and the caller
/// must not be able to confuse them: a PowerShell that failed to launch, exited
/// non-zero, or was blocked by policy has told us NOTHING about the hardware,
/// while an empty result set is a genuine finding. Collapsing the two is the
/// exact defect this order was filed against, one layer down.
#[cfg(target_os = "windows")]
fn powershell_lines(script: &str) -> Option<Vec<String>> {
    let out = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect(),
    )
}

/// Pull `VEN_xxxx` / `DEV_xxxx` out of a Windows PNP instance id.
///
/// Returns the pair as `1002:1114`, vendor and device TOGETHER — never either
/// alone. Vendor collides across parts, and device collides across vendors.
///
/// CAUTION, measured 2026-09-02 and stronger than the fleet assumed: the pair
/// is NOT sufficient to separate two machines either. This host (Radeon 860M)
/// reports 1002:1114, and yoga's host (Radeon 840M) reports 1002:1114 as well —
/// AMD ships the two bins under one device id, not merely one marketing name.
/// So the PCI pair would NOT have separated the hosts the fleet called twins;
/// the CPU model is still what does. Recorded on the accessor so nobody keys a
/// substrate control on it later.
#[cfg(target_os = "windows")]
fn pci_pair(instance_id: &str) -> Option<String> {
    let up = instance_id.to_ascii_uppercase();
    let grab = |key: &str| -> Option<String> {
        let i = up.find(key)? + key.len();
        let v: String = up[i..].chars().take(4).collect();
        (v.len() == 4 && v.chars().all(|c| c.is_ascii_hexdigit())).then_some(v)
    };
    Some(format!(
        "{}:{}",
        grab("VEN_")?.to_lowercase(),
        grab("DEV_")?.to_lowercase()
    ))
}

/// Enumerate GPUs on native Windows via `Win32_VideoController`.
///
/// HOST-NATIVE LANE ONLY, deliberately. Presence of a display adapter says
/// nothing about whether a CONTAINER can reach it, and the container lane on
/// this platform runs inside the WSL2 guest which probes itself. Claiming a
/// container lane from here would manufacture the reachability the accel matrix
/// exists to measure — the `Enumerated < Reachable < Placed` ordering is not
/// decoration.
#[cfg(target_os = "windows")]
fn windows_gpus() -> Option<Vec<DeviceRecord>> {
    let lines = powershell_lines(
        "Get-CimInstance Win32_VideoController -ErrorAction Stop | \
         ForEach-Object { $_.Name + '|' + $_.PNPDeviceID + '|' + $_.DriverVersion }",
    )?;
    Some(
        lines
            .iter()
            .filter_map(|l| {
                let mut f = l.split('|');
                let name = f.next()?.trim().to_string();
                if name.is_empty() {
                    return None;
                }
                let instance = f.next().unwrap_or("").trim();
                let driver = f.next().unwrap_or("").trim();
                let pair = pci_pair(instance);
                Some(DeviceRecord {
                    device_class: "gpu".to_string(),
                    vendor: match pair.as_deref().and_then(|p| p.split(':').next()) {
                        Some("1002") => "amd".to_string(),
                        Some("8086") => "intel".to_string(),
                        Some("10de") => "nvidia".to_string(),
                        _ => "unknown".to_string(),
                    },
                    name,
                    device_node: pair,
                    fw_version: None,
                    driver: (!driver.is_empty()).then(|| driver.to_string()),
                    // ENUMERATED, not reachable: see the doc comment.
                    usable: false,
                    unusable_reason: Some("host-native-only-not-container-reachable".to_string()),
                    lanes: vec!["host-native".to_string()],
                    memory_bandwidth_gbps: None,
                    memory_bandwidth_source: "unknown".to_string(),
                    cpu_flags: None,
                    cpu_cores: None,
                    system_ram_gb: None,
                    memory_model: None,
                })
            })
            .collect(),
    )
}

/// Enumerate NPUs on native Windows via the `ComputeAccelerator` device class.
///
/// Queried BY CLASS rather than by a hardware id, so an Intel NPU enumerates
/// here too without a table of ids to keep current. Verified on this host:
/// VEN_1022 / DEV_17F0, Status OK, FriendlyName "NPU Compute Accelerator
/// Device" — the same 1022:17f0 part yoga enumerates on Linux as amdxdna.
///
/// `usable: false` with `engine-missing` mirrors the Linux arm on purpose. A
/// present, driver-bound NPU still has no runtime this product can dispatch to;
/// yoga's phrase for the Linux side — "not missing the NPU, missing a
/// userspace" — is true on Windows as well, and a probe that flipped this to
/// usable because the device enumerates would be labelling wiring that does not
/// exist.
#[cfg(target_os = "windows")]
fn windows_npus() -> Option<Vec<DeviceRecord>> {
    let lines = powershell_lines(
        "Get-PnpDevice -Class ComputeAccelerator -PresentOnly -ErrorAction Stop | \
         ForEach-Object { $_.Status + '|' + $_.FriendlyName + '|' + $_.InstanceId }",
    )?;
    Some(
        lines
            .iter()
            .filter_map(|l| {
                let mut f = l.split('|');
                let status = f.next()?.trim().to_string();
                let name = f.next().unwrap_or("").trim().to_string();
                let instance = f.next().unwrap_or("").trim();
                let pair = pci_pair(instance);
                let vendor = match pair.as_deref().and_then(|p| p.split(':').next()) {
                    Some("1022") => "AMD XDNA".to_string(),
                    Some("8086") => "Intel NPU".to_string(),
                    _ => "unknown".to_string(),
                };
                // A device the OS reports as not-OK is enumerated but not
                // healthy; say which, rather than folding it into the same
                // engine-missing bucket as a working one.
                let reason = if status.eq_ignore_ascii_case("OK") {
                    "engine-missing"
                } else {
                    "device-not-ok"
                };
                Some(DeviceRecord {
                    device_class: "npu".to_string(),
                    vendor,
                    name: if name.is_empty() {
                        "Unknown Compute Accelerator".to_string()
                    } else {
                        name
                    },
                    device_node: pair,
                    fw_version: None,
                    driver: None,
                    usable: false,
                    unusable_reason: Some(reason.to_string()),
                    lanes: vec!["host-native".to_string()],
                    memory_bandwidth_gbps: None,
                    memory_bandwidth_source: "unknown".to_string(),
                    cpu_flags: None,
                    cpu_cores: None,
                    system_ram_gb: None,
                    memory_model: None,
                })
            })
            .collect(),
    )
}

#[cfg(target_os = "linux")]
fn enumerate_npus() -> Vec<DeviceRecord> {
    let mut npus = Vec::new();
    let accel_dir = Path::new("/sys/class/accel");

    // PROBE-2: Kernel without accel class (e.g. WSL2) yields empty list and succeeds
    //
    // THIS IS A FINDING, NOT A GAP, and the distinction is deliberate (805-r98w,
    // 2026-09-02). The same day's work made native Windows report `unknown`
    // instead of `none`, because there no enumeration code existed at all — the
    // probe had never looked. Linux is not that case: sysfs IS the enumeration
    // mechanism, it was consulted, and an absent accel class is a true statement
    // about this kernel (no accel-class driver is bound). So this arm records no
    // enumeration gap and `none` stands.
    //
    // Measured in the tillandsias-build WSL2 guest: /sys/class/accel absent,
    // /dev/dxg present, amdxdna not loaded — on a machine whose NPU the Windows
    // host enumerates as 1022:17f0. The guest's `none` is vantage-correct: that
    // NPU is not passed through to WSL2 and nothing in the guest can reach it.
    // Cross-vantage disagreement about one machine is expected and is why
    // compare_documents refuses a cross-vantage pair.
    //
    // Do NOT "fix" this into `unknown`. Most Linux hosts genuinely have no NPU;
    // reporting unknown everywhere would trade a correct answer for noise, and
    // would be today's reasoning applied past the case that motivated it.
    if !accel_dir.exists() {
        return npus;
    }

    if let Ok(entries) = fs::read_dir(accel_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("accel") {
                let dev_path = entry.path();
                let uevent_path = dev_path.join("device/uevent");
                let uevent_content = fs::read_to_string(&uevent_path).unwrap_or_default();

                let mut driver_name = None;
                for line in uevent_content.lines() {
                    if let Some(drv) = line.strip_prefix("DRIVER=") {
                        driver_name = Some(drv.trim().to_string());
                        break;
                    }
                }

                let (vendor, name_str) = match driver_name.as_deref() {
                    Some("amdxdna") => ("AMD XDNA".to_string(), "AMD XDNA NPU".to_string()),
                    Some("intel_vpu") => ("Intel NPU".to_string(), "Intel NPU".to_string()),
                    Some(other) => ("unknown".to_string(), format!("Unknown NPU ({other})")),
                    None => ("unknown".to_string(), "Unknown Accel Device".to_string()),
                };

                let fw_version = fs::read_to_string(dev_path.join("device/firmware_version"))
                    .or_else(|_| fs::read_to_string(dev_path.join("device/fw_version")))
                    .ok()
                    .map(|s| s.trim().to_string());

                let node_path = format!("/dev/accel/{name}");

                // PROBE-3: usable: false with unusable_reason: "engine-missing"
                npus.push(DeviceRecord {
                    device_class: "npu".to_string(),
                    vendor,
                    name: name_str,
                    device_node: Some(node_path),
                    fw_version,
                    driver: driver_name,
                    usable: false,
                    unusable_reason: Some("engine-missing".to_string()),
                    lanes: vec!["host-native".to_string()],
                    memory_bandwidth_gbps: None,
                    memory_bandwidth_source: "unknown".to_string(),
                    cpu_flags: None,
                    cpu_cores: None,
                    system_ram_gb: None,
                    memory_model: None,
                });
            }
        }
    }

    npus
}

// @trace spec:accel-capability-probe
fn enumerate_host() -> HostInfo {
    // Only the Linux power-supply scan can flip this; other hosts keep false.
    #[cfg_attr(not(target_os = "linux"), allow(unused_mut))]
    let mut battery = false;

    #[cfg(target_os = "linux")]
    {
        if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
            for entry in entries.flatten() {
                let type_path = entry.path().join("type");
                if let Ok(t) = fs::read_to_string(type_path)
                    && t.trim().eq_ignore_ascii_case("battery")
                {
                    battery = true;
                    break;
                }
            }
        }
    }

    let kernel = Command::new("uname")
        .arg("-r")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let (host_id, host_id_source) = resolve_host_id();

    let side = detect_side(&kernel);

    HostInfo {
        is_battery_present: battery,
        kernel_release: kernel,
        host_id,
        host_id_source,
        host_kind: host_kind().to_string(),
        side: Some(side.to_string()),
    }
}

/// Order 793-qr4t. Which side of which boundary this probe is standing on.
///
/// Evidence, in the order that matters, and the ORDER IS THE DESIGN: a forge
/// inside a container on a WSL2 guest is BOTH, and the answer a consumer needs
/// is the innermost boundary — that is the one whose far side holds the devices
/// it cannot reach. Widening the container test to run second would report
/// `wsl2-guest` for a container and re-open exactly the blind spot this field
/// closes.
///
/// Kernel release is a PARAMETER so the WSL2 arm is testable on a host that is
/// not WSL2. The filesystem probes are not parameterised because they are cheap
/// and their absence is the common case; [`side_from_evidence`] is the pure
/// function the tests drive.
#[cfg_attr(not(target_os = "linux"), allow(unused_variables))]
fn detect_side(kernel_release: &str) -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "macos-host"
    }
    #[cfg(target_os = "windows")]
    {
        "windows-host"
    }
    #[cfg(target_os = "linux")]
    {
        side_from_evidence(
            Path::new("/run/.containerenv").exists() || Path::new("/.dockerenv").exists(),
            Path::new("/dev/dxg").exists(),
            kernel_release,
        )
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        "unknown-side"
    }
}

/// The Linux side decision as a pure function (order 793-qr4t).
///
/// WSL2 wants BOTH signals, not either. `/dev/dxg` alone appears on a Windows
/// host running WSLg-adjacent stacks and, more importantly, is the very node
/// 793-zumy teaches the GPU arm to read — reusing it as a side test would make
/// the side depend on whether a GPU happened to be paravirtualised. A
/// `microsoft` kernel release alone is likewise not decisive: it is the string
/// two WSL2 guests already share verbatim (see `HostInfo::host_id`), and it
/// survives into any image built from that kernel. Together they are the shape
/// only a WSL2 guest has.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn side_from_evidence(in_container: bool, dxg_present: bool, kernel_release: &str) -> &'static str {
    if in_container {
        return "container";
    }
    let microsoft_kernel = kernel_release.to_ascii_lowercase().contains("microsoft");
    if dxg_present && microsoft_kernel {
        return "wsl2-guest";
    }
    "native-linux"
}

// @trace spec:accel-capability-probe
/// Map the compile target onto the fleet's host vocabulary (order 808-43mw).
///
/// The ledger already speaks `linux` / `windows` / `macos`, so the matrix uses
/// those rather than Rust's `macos`-vs-`darwin` spelling of the same idea.
fn host_kind() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        std::env::consts::OS
    }
}

// @trace spec:accel-capability-probe
/// Normalise a node name the way the fleet's shell probe does (order 808-43mw).
///
/// Strip the domain and lowercase — the same two steps `tillandsias_node_name`
/// applies with bash builtins. Kept as a pure function so the agreement with
/// the shell chain is testable without a matching hostname.
fn normalize_node_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let short = trimmed.split('.').next().unwrap_or("");
    if short.is_empty() {
        return None;
    }
    Some(short.to_ascii_lowercase())
}

// @trace spec:accel-capability-probe
/// Resolve `(host_id, host_id_source)` — the input first, then the fleet chain.
///
/// The fallback order mirrors `scripts/agent-identity.sh` deliberately:
/// `hostname` -> `uname -n` -> `/etc/hostname`. It is NOT a fresh guess at how
/// to name a machine; agreeing with the shell probe is the point, because the
/// matrix key and the attestation ledger's filename must be the same string.
///
/// Returns `unknown` rather than an empty string when nothing answers. An empty
/// host_id would fold as a legitimate key and silently collect every
/// unidentifiable host into one row — the exact collision this field exists to
/// prevent, reintroduced through the error path.
fn resolve_host_id() -> (String, String) {
    if let Ok(v) = std::env::var(HOST_ID_ENV)
        && let Some(id) = normalize_node_name(&v)
    {
        return (id, "input".to_string());
    }

    // `hostname -s` is deliberately NOT tried: order 743-mgf3 measured it
    // rejected under MSYS, and the shell probe dropped it for that reason.
    for (prog, args) in [("hostname", &[][..]), ("uname", &["-n"][..])] {
        if let Ok(out) = Command::new(prog).args(args).output()
            && out.status.success()
            && let Some(id) = normalize_node_name(&String::from_utf8_lossy(&out.stdout))
        {
            return (id, "node-name".to_string());
        }
    }

    if let Ok(content) = fs::read_to_string("/etc/hostname")
        && let Some(id) = normalize_node_name(&content)
    {
        return (id, "node-name".to_string());
    }

    ("unknown".to_string(), "unknown".to_string())
}

fn is_binary_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = fs::metadata(path) {
            return meta.is_file() && (meta.permissions().mode() & 0o111 != 0);
        }
        false
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn is_binary_available(binary: &str) -> bool {
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let full = dir.join(binary);
            if is_binary_executable(&full) {
                return true;
            }
        }
    }
    for std_path in ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"] {
        let full = Path::new(std_path).join(binary);
        if is_binary_executable(&full) {
            return true;
        }
    }
    false
}

// @trace order:803-825k, order:850-bif2, spec:accel-capability-probe
fn enumerate_engines() -> Vec<EngineRecord> {
    enumerate_engines_with(is_binary_available, inference_image_present)
}

/// Is the fleet's inference image (`localhost/tillandsias-inference`) present
/// in the local podman store? That image ships ollama, so its presence is the
/// container-lane engine the host-PATH scan is structurally blind to
/// (order 850-bif2). `podman` absent or failing reads as "no image" — an
/// engine we cannot prove is an engine we do not claim.
fn inference_image_present() -> bool {
    tillandsias_podman::podman_cmd_sync()
        .args(["images", "--format", "{{.Repository}}"])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .any(|l| l.trim().ends_with("/tillandsias-inference"))
        })
        .unwrap_or(false)
}

fn enumerate_engines_with<F, G>(mut binary_check: F, mut container_check: G) -> Vec<EngineRecord>
where
    F: FnMut(&str) -> bool,
    G: FnMut() -> bool,
{
    let mut engines = Vec::new();

    if binary_check("ollama") {
        engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "llama-server".to_string(),
            supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
            lanes: None,
        });
    }

    if binary_check("llama-server") {
        engines.push(EngineRecord {
            name: "llama-server".to_string(),
            backend: "llama.cpp".to_string(),
            supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
            lanes: None,
        });
    }

    // Order 850-bif2: the containerized engine. Recorded only when the host
    // has no host-PATH ollama already covering every lane, and scoped to the
    // container lane — claiming host-native reach for a binary inside an
    // image would be the same over-claim in the other direction.
    if !engines.iter().any(|e| e.name == "ollama") && container_check() {
        engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "llama-server".to_string(),
            supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        });
    }

    engines
}

fn num_cpus() -> u32 {
    std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(1)
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn physical_core_count() -> Option<u32> {
    #[cfg(target_os = "linux")]
    {
        if let Ok(content) = fs::read_to_string("/proc/cpuinfo") {
            let mut cores = std::collections::HashSet::new();
            let mut current_socket = None;
            let mut current_core = None;
            for line in content.lines() {
                if line.starts_with("physical id")
                    && let Some((_, v)) = line.split_once(':')
                {
                    current_socket = v.trim().parse::<u32>().ok();
                } else if line.starts_with("core id")
                    && let Some((_, v)) = line.split_once(':')
                {
                    current_core = v.trim().parse::<u32>().ok();
                }
                if let (Some(s), Some(c)) = (current_socket, current_core) {
                    cores.insert((s, c));
                    current_socket = None;
                    current_core = None;
                }
            }
            if !cores.is_empty() {
                return Some(cores.len() as u32);
            }
        }
    }
    None
}

/// Order 480 follow-up: project the capability document into ONE agent-facing
/// line so a forge can state, at launch, what accelerators this node actually
/// offers a container.
///
/// WHY THIS EXISTS: the probe above was implemented, unit-tested, and closed —
/// with NO caller anywhere in the product. `capabilities.json` was never written
/// on any host and nothing reached a forge. That is this project's named
/// recurring failure class ("verified where it was written is not verified where
/// it runs") in its purest form: the module's own tests passed while the feature
/// did not exist at runtime. The envelope is the surface that makes it real.
///
/// PINNED GRAMMAR (a closed vocabulary; agents branch on this, never on prose):
///   accel_class=<workstation-gpu|mobile-npu|hybrid-gpu-npu|cpu-only>
///   accel_gpu=<usable|present-unusable|none> accel_gpu_name=<slug|->
///   accel_npu=<usable|present-unusable|none> accel_npu_name=<slug|->
///   accel_reason=<reason|-> accel_cpu_cores=<n|-> accel_ram_gb=<n|->
///
/// `accel_class` is the TWO-TIER ROUTING SIGNAL: this workstation reports
/// `workstation-gpu`, a mobile host with a working NPU reports `mobile-npu`, and
/// a host whose accelerator cannot be delivered to a container reports
/// `cpu-only` with `accel_reason` naming why. An agent picks model size from the
/// class without probing hardware it cannot see.
///
/// USABILITY IS DECIDED BY THE CONTAINER LANE, not by `usable`. A device record
/// can carry `usable: true` together with `unusable_reason: cdi-spec-missing`
/// (the NVIDIA-without-CDI case constructs exactly that), so `usable` alone
/// would report a GPU this forge cannot touch. `lanes` contains `container`
/// only when the runtime can actually hand the device over, which is precisely
/// the question an agent inside a forge is asking.
// @trace spec:accel-capability-probe
pub fn accel_envelope(doc: &CapabilityDocument) -> String {
    let pick = |class: &str| -> Option<&DeviceRecord> {
        // Prefer a container-deliverable device; otherwise report the best
        // evidence we have, so "present but unusable" never renders as "none".
        doc.devices
            .iter()
            .find(|d| d.device_class == class && d.lanes.iter().any(|l| l == "container"))
            .or_else(|| doc.devices.iter().find(|d| d.device_class == class))
    };

    let state = |d: Option<&DeviceRecord>| match d {
        None => "none",
        Some(d) if d.lanes.iter().any(|l| l == "container") && d.unusable_reason.is_none() => {
            "usable"
        }
        Some(_) => "present-unusable",
    };

    let gpu = pick("gpu");
    let npu = pick("npu");
    let (gpu_state, mut npu_state) = (state(gpu), state(npu));

    // "none" is a FINDING; where the probe could not look it would be a guess
    // wearing a finding's clothes. The document records WHICH classes it failed
    // to enumerate, so this reads the run that produced the document rather than
    // the platform that is rendering it — a cached or transported document
    // keeps its own gaps, which a compile-time constant could never do.
    let gap = |class: &str| doc.enumeration_gaps.iter().any(|g| g == class);

    // ORDER 793-qr4t. A THIRD reason a class can come back empty, and it is not
    // the same as either of the two above.
    //
    // `none` means enumerated-and-absent. `unknown` means this probe has no arm
    // for the class on this platform (the Darwin ANE: present, drivable through
    // CoreML, on THIS side, and invisible only because `enumerate_npus` reads
    // `/sys/class/accel`). Neither describes a WSL2 guest, where the arm exists,
    // ran, and correctly found nothing — because the device is on the far side
    // of a VM boundary. Measured: an XDNA2 NPU healthy on the Windows side
    // (VEN_1022&DEV_17F0, driver 32.0.20102.3930) rendering `accel_npu=none` in
    // the guest, which reads as "this machine cannot do NPU work" and would
    // mis-plan a whole tier.
    //
    // The discriminator is the SIDE, not the class: on a boundary side the
    // probe's enumeration is evidence about the guest, never about the machine.
    // A native-Linux host with no NPU keeps `none`, which is the criterion that
    // stops this from being a blanket relabel.
    let side = accel_side(doc);
    let boundary_side = matches!(side, "wsl2-guest" | "container");
    let absent_state = |gap: bool| -> &'static str {
        if gap {
            "unknown"
        } else if boundary_side {
            "unobservable-from-this-side"
        } else {
            "none"
        }
    };
    if npu.is_none() {
        npu_state = absent_state(gap("npu"));
    }
    let mut gpu_state = gpu_state;
    if gpu.is_none() {
        gpu_state = absent_state(gap("gpu"));
    }

    let class = match (gpu_state, npu_state) {
        ("usable", "usable") => "hybrid-gpu-npu",
        ("usable", _) => "workstation-gpu",
        (_, "usable") => "mobile-npu",
        _ => "cpu-only",
    };

    // The first named obstruction, so `cpu-only` is never a bare verdict.
    let reason = gpu
        .and_then(|d| d.unusable_reason.as_deref())
        .or_else(|| npu.and_then(|d| d.unusable_reason.as_deref()))
        .unwrap_or(match (gpu_state, npu_state) {
            // So `cpu-only` is never a bare verdict on a host that simply could
            // not look for the accelerators it is denying.
            ("unknown", "unknown") => "gpu-and-npu-not-enumerable-on-this-platform",
            ("unknown", _) => "gpu-not-enumerable-on-this-platform",
            (_, "unknown") => "npu-not-enumerable-on-this-platform",
            // Order 793-qr4t: same principle one boundary out. The obstruction
            // is the boundary itself, and naming it is what stops a reader
            // concluding the hardware is absent.
            ("unobservable-from-this-side", "unobservable-from-this-side") => {
                "gpu-and-npu-across-the-boundary-from-this-side"
            }
            ("unobservable-from-this-side", _) => "gpu-across-the-boundary-from-this-side",
            (_, "unobservable-from-this-side") => "npu-across-the-boundary-from-this-side",
            _ => "-",
        });

    let cpu = doc.devices.iter().find(|d| d.device_class == "cpu");
    let cores = cpu
        .and_then(|d| d.cpu_cores.as_ref())
        .map(|c| c.logical.to_string())
        .unwrap_or_else(|| "-".to_string());
    let ram = cpu
        .and_then(|d| d.system_ram_gb)
        .map(|g| format!("{g:.0}"))
        .unwrap_or_else(|| "-".to_string());

    // 793-zumy REMAINING 2. The HIGHEST rung any container-lane render node
    // reached, appended LAST so every existing grep/sed consumer and
    // `litmus:accel-envelope-reaches-the-forge` are unaffected by its arrival.
    //
    // `-` MEANS NOBODY ASKED OR NOTHING ANSWERED, and it is deliberately not
    // `enumerated`: an absent producer and a producer that found a device are
    // different facts, and collapsing them is the substitution this packet
    // exists to end. Only `placed` may be read as a lane - `Proof::proves_a_lane`
    // is the one comparison a consumer should make, and it is one keystroke away
    // from `>= reachable`, which is the mistake this whole family is about.
    let proof = match doc.render_nodes.iter().map(|n| n.proof).max() {
        Some(p) => p.token(),
        // NOBODY TO ASK vs ASKED AND FOUND NOTHING. Yoga measured these
        // collapsed into one token on 2026-09-02 and the envelope on a host
        // with a WORKING container lane was indistinguishable from one with no
        // accelerator — under-claiming, silently. `unknown` is the same word
        // this envelope already uses for a device class the probe could not
        // enumerate, and it is deliberately not `none`.
        None if gap("container-lane") => "unknown",
        None => "none",
    };

    // ORDERS 793-qr4t + 793-qc6q. APPENDED, never interleaved: every key above
    // keeps its name, position and meaning, so 769-w3ma's consumers and
    // `litmus:accel-envelope-reaches-the-forge` read exactly what they read
    // before. A grammar extension that moved an existing key would be a rename
    // wearing an addition's clothes.
    let mem_model = mem_model(side, gpu);
    let routing = routing_summary(doc);

    format!(
        "accel_class={} accel_gpu={} accel_gpu_name={} accel_npu={} accel_npu_name={} \
         accel_reason={} accel_cpu_cores={} accel_ram_gb={} accel_proof={} \
         accel_side={} accel_gpu_path={} accel_gpu_engine={} \
         accel_mem_model={} accel_mem_budget_gb={} \
         accel_prefill_dev={} accel_decode_dev={} accel_decode_crossover_b={}",
        class,
        gpu_state,
        gpu.map(|d| slug(&d.name))
            .unwrap_or_else(|| "-".to_string()),
        npu_state,
        npu.map(|d| slug(&d.name))
            .unwrap_or_else(|| "-".to_string()),
        slug(reason),
        cores,
        ram,
        proof,
        side,
        gpu_path(side, gpu),
        gpu_engine(doc, gpu),
        mem_model,
        // ONE budget, side-scoped, and the whole point of emitting it beside
        // `accel_mem_model` rather than alone. Measured on windows/Yolanda: the
        // probe reported `accel_ram_gb=7` (the guest's slice) while dzn
        // advertised a 7.58 GiB DEVICE_LOCAL heap — the SAME physical DRAM,
        // counted twice, and neither of them the machine's 15.2 GB. A 522
        // sizing consumer that adds a GPU pool to a CPU pool on a
        // `unified` node has doubled a pool that does not exist. There is
        // exactly one number here on purpose: nothing to add.
        ram,
        routing.prefill,
        routing.decode,
        routing.crossover,
    )
}

/// Order 793-qr4t. Which side of which boundary produced this document.
///
/// Read from the DOCUMENT, never from the reader's own `cfg!`: the fleet matrix
/// folds rows probed on other machines, so a renderer that asked itself would
/// answer about itself. `None` (every pre-schema-3 document) reads
/// `unknown-side`, which is honest — those documents genuinely do not say — and
/// is deliberately NOT `native-linux`, since defaulting a missing side to the
/// commonest one would silently re-assert the collapse this field removes.
// @trace order:793-qr4t, spec:accel-capability-probe
pub fn accel_side(doc: &CapabilityDocument) -> &str {
    doc.host.side.as_deref().unwrap_or("unknown-side")
}

/// HOW the GPU is reached: `drm` | `dxg-d3d12` | `metal` | `cuda` | `none`.
///
/// The PATH is not the ENGINE and conflating them is one of the four facts
/// 793-qr4t is unpacking. A WSL2 guest reaches its GPU over `/dev/dxg` and
/// drives it with Vulkan-over-D3D12; the path is a property of the boundary,
/// the engine of the software stack, and a host can have either without the
/// other. Measured on windows/Yolanda: `/dev/dxg` present and ollama logging
/// `library=cpu`, because no Vulkan loader was installed — a real path with no
/// engine on it.
///
/// Decided from the device NODE first, because that is evidence, and only then
/// from the side, which is an inference about a device we could not otherwise
/// place.
// @trace order:793-qr4t, spec:accel-capability-probe
fn gpu_path(side: &str, gpu: Option<&DeviceRecord>) -> &'static str {
    let Some(g) = gpu else {
        return "none";
    };
    let node = g.device_node.as_deref().unwrap_or("");
    if node.starts_with("/dev/dxg") {
        return "dxg-d3d12";
    }
    if node.starts_with("/dev/nvidia") {
        return "cuda";
    }
    if node.starts_with("/dev/dri") || node.starts_with("/dev/kfd") {
        return "drm";
    }
    match side {
        "macos-host" => "metal",
        "windows-host" => "dxg-d3d12",
        "wsl2-guest" => "dxg-d3d12",
        "native-linux" | "container" => "drm",
        _ => "none",
    }
}

/// WHICH ENGINE, IF ANY, CAN DRIVE THE GPU — the third of the four collapsed
/// facts, and the one whose absence made a host with a usable RTX A5000 report
/// `schedulable: none`.
///
/// `engine-missing` and `none` are different answers to different questions and
/// that difference is the whole key: `none` means there is no GPU here (buy
/// hardware); `engine-missing` means there is a GPU and we ship nothing that
/// can drive it (ship a lane). The probe already distinguishes them for the
/// NPU — that record carries `unusable_reason: engine-missing` — and could not
/// for the GPU, because `accel_envelope` never read `doc.engines` at all.
///
/// AN UNRECOGNISED ENGINE RENDERS ITS OWN SLUG rather than being forced into
/// the nearest listed value. The known mappings below cover the stacks the
/// fleet ships; `ollama` is on this very host and is not one of them. Reporting
/// it as, say, `rocm` because it is the closest label would be exactly the
/// confident half-answer this packet is dismantling, and a reader who does not
/// recognise a slug can find out, whereas a reader given a wrong one cannot.
// @trace order:793-qr4t, spec:accel-capability-probe
fn gpu_engine(doc: &CapabilityDocument, gpu: Option<&DeviceRecord>) -> String {
    let Some(_) = gpu else {
        return "none".to_string();
    };
    let Some(e) = doc
        .engines
        .iter()
        .find(|e| e.supported_device_classes.iter().any(|c| c == "gpu"))
    else {
        return "engine-missing".to_string();
    };
    let hay = format!("{} {}", e.name, e.backend).to_ascii_lowercase();
    let known = if hay.contains("rocm") || hay.contains("hip") {
        Some("rocm")
    } else if hay.contains("cuda") {
        Some("cuda")
    } else if hay.contains("metal") {
        Some("metal")
    } else if hay.contains("vulkan") && (hay.contains("dozen") || hay.contains("dzn")) {
        Some("vulkan-dozen")
    } else if hay.contains("vulkan") && hay.contains("radv") {
        Some("vulkan-radv")
    } else {
        None
    };
    known
        .map(|k| k.to_string())
        .unwrap_or_else(|| slug(&e.name))
}

/// What the envelope PRINTS for the memory model, in five distinguishable
/// states (order 964-r98h; the five-way split is yolanda's correction).
///
/// The classifier itself lives on the device now
/// ([`memory_model_from_evidence`]), so this function's only remaining job is
/// the one it was getting wrong: saying WHY there is no answer.
///
/// YOLANDA'S DEFECT, WHICH THEY SHIPPED IN THIS FILE AND YOGA CAUGHT, ARRIVING
/// ONE FIELD OVER. Their `accel_proof` rendered a single token for both "nobody
/// to ask" and "asked and found nothing", so a host whose lane was WORKING read
/// identically to one with no accelerator. My first version had the same hole:
/// "no GPU at all", "a GPU whose evidence path cannot run on this side", and "a
/// GPU whose classifier ran and could not decide" all printed `unknown`. Those
/// are three different engineering problems and only the last is a defect in
/// the classifier.
///
///   `unified`  / `discrete`                  — decided from evidence.
///   `no-gpu`                                 — nothing to sum against.
///   `unobservable-from-this-side`            — a real GPU, and an evidence
///        path this side cannot reach. The WSL2 row is the case: a paravirtual
///        GPU on `/dev/dxg` exposes no DRM sysfs at all, so that host will
///        report this permanently until a Windows-side arm supplies the value.
///        That is a true statement about the boundary, not a gap in the probe.
///   `undetermined`                           — the classifier RAN and refused.
///
/// EVERY NON-DECIDED STATE CARRIES THE SAME OBLIGATION: do not sum a GPU pool
/// with a CPU pool. `unified` is the only value that positively licenses
/// reading `accel_mem_budget_gb` as the whole machine.
// @trace order:964-r98h, spec:accel-capability-probe
fn mem_model(side: &str, gpu: Option<&DeviceRecord>) -> &'static str {
    let Some(g) = gpu else {
        return "no-gpu";
    };
    match g.memory_model.as_deref() {
        Some("unified") => "unified",
        Some("discrete") => "discrete",
        // Apple silicon is unified BY CONSTRUCTION — there is no discrete
        // alternative to confuse it with — and the Darwin arm has no sysfs to
        // read, so this is the one architectural assertion kept in the
        // renderer rather than derived from evidence.
        _ if side == "macos-host" || g.vendor.eq_ignore_ascii_case("apple") => "unified",
        _ if matches!(side, "wsl2-guest" | "container" | "windows-host") => {
            "unobservable-from-this-side"
        }
        _ => "undetermined",
    }
}

/// Where the decode phase's CPU/GPU curves cross, DERIVED from this host's own
/// measurements (order 793-qc6q).
#[derive(Debug, Clone, Copy, PartialEq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub enum DecodeCrossover {
    /// No pair of CPU and GPU decode measurements at a common model size.
    /// The policy MUST NOT invent one: the packet's exit criterion rules out
    /// "a constant that happens to fit windows/Yolanda", and an unmeasured host
    /// routing decode to the GPU on that constant's authority is precisely the
    /// silent 1.23x regression it was written to prevent.
    Unmeasured,
    /// The GPU wins decode at this parameter count (billions) and above.
    AtOrAbove(f64),
    /// Measured across every available size and the CPU won at all of them.
    /// Distinct from `Unmeasured`: this host HAS looked, and the answer is no.
    CpuWinsThroughout,
}

/// Derive the decode crossover from `doc.measurements`.
///
/// WHY THIS READS A CACHE AND NOT A CONSTANT: decode is memory-bandwidth-bound,
/// so on unified memory the iGPU reads the same DRAM as the CPU and brings only
/// compute against a fixed per-dispatch cost. Below some size that cost
/// dominates. WHERE that size falls is a property of one machine's
/// compute-to-bandwidth ratio — measured at between 0.5B and 3B on
/// windows/Yolanda (decode 0.5B: CPU 78.68 vs GPU 63.75 t/s; 3B: CPU 19.64 vs
/// GPU 26.96) — and Apple silicon is a second unified architecture with far
/// higher bandwidth where the same threshold has no reason to hold. Hard-coding
/// Yolanda's number would read one host's hardware ratio as an architectural
/// law.
///
/// The returned threshold is a MEASURED SIZE, never an interpolation between
/// two. Interpolating would manufacture a precision the three-point sample
/// cannot support, and the routing decision only ever compares against it.
// @trace order:793-qc6q, spec:accel-capability-probe
pub fn decode_crossover_b(doc: &CapabilityDocument) -> DecodeCrossover {
    // (params, cpu_tps, gpu_tps) for every size measured on BOTH devices.
    let mut sizes: Vec<(f64, Option<f64>, Option<f64>)> = Vec::new();
    for m in &doc.measurements {
        let (Some(p), Some(tps)) = (m.model_params_b, m.decode_tps) else {
            continue;
        };
        // A degraded run is not evidence about the device; it is evidence the
        // run went wrong, and folding it in would move a threshold on the
        // strength of a failure.
        if m.degraded {
            continue;
        }
        let dev = m.device.to_ascii_lowercase();
        let slot = sizes.iter_mut().find(|(sp, _, _)| (*sp - p).abs() < 1e-9);
        let entry = match slot {
            Some(e) => e,
            None => {
                sizes.push((p, None, None));
                sizes.last_mut().expect("just pushed")
            }
        };
        if dev.starts_with("cpu") {
            entry.1 = Some(entry.1.map_or(tps, |v: f64| v.max(tps)));
        } else if dev.starts_with("gpu") {
            entry.2 = Some(entry.2.map_or(tps, |v: f64| v.max(tps)));
        }
    }

    let mut paired: Vec<(f64, f64, f64)> = sizes
        .into_iter()
        .filter_map(|(p, c, g)| Some((p, c?, g?)))
        .collect();
    if paired.is_empty() {
        return DecodeCrossover::Unmeasured;
    }
    paired.sort_by(|a, b| a.0.partial_cmp(&b.0).expect("finite sizes"));

    match paired.iter().find(|(_, cpu, gpu)| gpu >= cpu) {
        Some((p, _, _)) => DecodeCrossover::AtOrAbove(*p),
        None => DecodeCrossover::CpuWinsThroughout,
    }
}

/// A phase of inference work. The UNIT OF ROUTING (order 793-qc6q).
///
/// Not the host and not the model. Two independent lines of evidence agree that
/// the phases want different devices on the SAME host with the SAME model:
/// ours (prefill is a batched GEMM and compute-bound, so the iGPU wins;
/// decode is bandwidth-bound and on unified memory it does not) and AMD's
/// Lemonade hybrid mode, which puts prompt processing on the NPU and token
/// generation on the GPU. A per-host device choice has to be wrong for one of
/// them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub enum Phase {
    Prefill,
    Decode,
    Embed,
    Rerank,
}

/// Where a phase runs, and WHY it is not running somewhere better.
#[derive(Debug, Clone, PartialEq, Eq)]
// @trace order:793-qc6q, spec:accel-capability-probe
pub struct Placement {
    /// `npu` | `gpu` | `cpu`.
    pub device: &'static str,
    /// Never empty, and never `-` when the device is `cpu`.
    ///
    /// THE PACKET'S THIRD EXIT CRITERION IS ABOUT THIS FIELD: "a fallback is
    /// never silent". The failure it names is the one that cost a day on
    /// windows/Yolanda — ollama logging `library=cpu` while every signal said
    /// GPU, because the loader was absent and nothing said so. A reason string
    /// is the difference between a fallback and a mystery.
    pub reason: String,
}

/// Whether a device class can actually be driven here: a lane AND an engine.
///
/// BOTH HALVES, and this is the engine-qualification 793-qr4t adds being
/// consumed rather than merely published. macuahuitl reported a container-lane
/// RTX A5000 with `engines: []` and the matrix printed `schedulable: none` —
/// correctly, since a device nothing can drive is not a target. Routing that
/// reads only the lane would send work to it and land on the same
/// `library=cpu` silence.
// @trace order:793-qc6q, spec:accel-capability-probe
fn phase_device_usable(doc: &CapabilityDocument, class: &str) -> bool {
    let lane_ok = doc.devices.iter().any(|d| {
        d.device_class == class
            && d.lanes.iter().any(|l| l == "container")
            && d.unusable_reason.is_none()
    });
    let engine_ok = doc
        .engines
        .iter()
        .any(|e| e.supported_device_classes.iter().any(|c| c == class));
    lane_ok && engine_ok
}

/// Route one phase, given the model's size in billions of parameters where the
/// caller knows it (order 793-qc6q).
///
/// THE CPU IS THE FLOOR AND EVERY ARM ENDS THERE. 620-ca7g is preserved
/// literally: there is no input to this function that yields a device the host
/// cannot run on, and no configuration that makes an accelerator a hard
/// requirement — the worst case is `cpu` with a reason naming what was missing.
// @trace order:793-qc6q, spec:accel-capability-probe
pub fn route_phase(
    doc: &CapabilityDocument,
    phase: Phase,
    model_params_b: Option<f64>,
) -> Placement {
    let npu = phase_device_usable(doc, "npu");
    let gpu = phase_device_usable(doc, "gpu");
    let cpu = |reason: &str| Placement {
        device: "cpu",
        reason: reason.to_string(),
    };

    match phase {
        // Compute-bound and batched: every accelerator we have measured wins,
        // so the order is simply best-available.
        Phase::Prefill => {
            if npu {
                Placement {
                    device: "npu",
                    reason: "npu-usable-prefill-is-compute-bound".to_string(),
                }
            } else if gpu {
                Placement {
                    device: "gpu",
                    reason: "no-usable-npu-gpu-wins-compute-bound-prefill".to_string(),
                }
            } else {
                cpu("no-usable-accelerator-for-prefill")
            }
        }
        Phase::Decode => {
            if !gpu {
                return cpu("no-usable-gpu-for-decode");
            }
            match decode_crossover_b(doc) {
                DecodeCrossover::Unmeasured => cpu("decode-crossover-unmeasured-on-this-host"),
                DecodeCrossover::CpuWinsThroughout => {
                    cpu("cpu-wins-decode-at-every-measured-size-on-this-host")
                }
                DecodeCrossover::AtOrAbove(t) => match model_params_b {
                    None => cpu("model-size-unknown-cannot-apply-measured-crossover"),
                    Some(p) if p >= t => Placement {
                        device: "gpu",
                        reason: format!("model-{p}b-at-or-above-measured-crossover-{t}b"),
                    },
                    Some(p) => cpu(&format!("model-{p}b-below-measured-crossover-{t}b")),
                },
            }
        }
        // NEVER THE iGPU, and the guard is unconditional rather than
        // conditioned on `mem_model` reaching `unified`. Measured: embed is
        // CPU 8.7ms vs GPU 10.2ms — the GPU LOSES — and `mem_model` answers
        // `unknown` for every AMD and Intel DRM device in the fleet, so a
        // guard written as "unless unified" would open on exactly the hosts
        // the measurement came from.
        Phase::Embed => {
            if npu {
                Placement {
                    device: "npu",
                    reason: "npu-embedding-engine-usable".to_string(),
                }
            } else {
                cpu("embed-never-routed-to-gpu-measured-slower-than-cpu")
            }
        }
        // Not measured anywhere in the fleet. The floor is the honest answer
        // and it says so, rather than borrowing the embed arm's reasoning for
        // a workload nobody has timed.
        Phase::Rerank => cpu("rerank-on-npu-unverified-cpu-is-the-measured-floor"),
    }
}

/// The three routing keys the envelope renders (order 793-qc6q).
struct RoutingSummary {
    prefill: &'static str,
    decode: &'static str,
    crossover: String,
}

/// WHY `accel_decode_dev` IS NOT A PER-MODEL ANSWER: the envelope is rendered
/// once at forge launch and read by agents choosing models later, so it cannot
/// know a size. It states the POLICY — is the GPU reachable for decode at all
/// on this host — and publishes the threshold beside it as
/// `accel_decode_crossover_b`, so a consumer applies the same comparison
/// [`route_phase`] would. Folding the threshold into the device value would
/// force a size the renderer does not have.
fn routing_summary(doc: &CapabilityDocument) -> RoutingSummary {
    let prefill = route_phase(doc, Phase::Prefill, None).device;
    let crossover = decode_crossover_b(doc);
    let decode = match crossover {
        DecodeCrossover::AtOrAbove(_) if phase_device_usable(doc, "gpu") => "gpu",
        _ => "cpu",
    };
    let crossover = match crossover {
        DecodeCrossover::Unmeasured => "unmeasured".to_string(),
        DecodeCrossover::CpuWinsThroughout => "cpu-wins".to_string(),
        DecodeCrossover::AtOrAbove(t) => format!("{t}"),
    };
    RoutingSummary {
        prefill,
        decode,
        crossover,
    }
}

/// Extract the model name from an `nvidia-smi -L` line.
///
/// The raw line is `GPU 0: NVIDIA RTX A5000 (UUID: GPU-354dc81c-…)`. Storing it
/// verbatim was wrong on two counts. It is noisy — the envelope's bounded name
/// field truncated mid-UUID, so an agent read a mangled identifier instead of a
/// model. And the UUID is a STABLE HARDWARE IDENTIFIER for this machine, which
/// the envelope hands to every forge container and writes into an on-disk
/// context file; a device model is what a consumer needs, so the serial number
/// has no business travelling with it.
///
/// Falls back to the whole line when the shape does not match, so an unexpected
/// `nvidia-smi` format degrades to "noisy" rather than "empty".
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn nvidia_model_name(line: &str) -> String {
    let after_index = line.split_once(": ").map(|(_, rest)| rest).unwrap_or(line);
    let without_uuid = after_index
        .split_once(" (UUID:")
        .map(|(name, _)| name)
        .unwrap_or(after_index);
    let trimmed = without_uuid.trim();
    if trimmed.is_empty() {
        line.trim().to_string()
    } else {
        trimmed.to_string()
    }
}

/// Collapse a free-form device name into one whitespace-free token.
///
/// The envelope is a space-separated `key=value` line, so a raw device name
/// ("NVIDIA RTX A5000", or an `nvidia-smi -L` line carrying a UUID in
/// parentheses) would split into extra fields and silently corrupt every key
/// after it. Bounded length keeps one long name from dominating the line.
fn slug(raw: &str) -> String {
    let mut out: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    // Collapse runs and trim, so "GPU 0: NVIDIA RTX" does not become
    // "GPU_0__NVIDIA_RTX" with meaningless doubled separators.
    while out.contains("__") {
        out = out.replace("__", "_");
    }
    let out = out.trim_matches('_').to_string();
    if out.is_empty() {
        return "-".to_string();
    }
    out.chars().take(48).collect()
}

#[cfg(test)]
mod tests {

    /// YOGA'S SECOND REFINEMENT, pinned as a rule rather than a comment: a stat
    /// proves the DEVICE is reachable; only PLACEMENT proves a lane.
    ///
    /// Their measured case is the reason this rung exists — real AMD hardware,
    /// real render node, correct PCI ids, /dev/kfd and /dev/dri/renderD128
    /// stat-able INSIDE the container, and size_vram still 0.00GB with decode
    /// unchanged at 12.2 tok/s. Every signal short of placement said yes.
    #[cfg(target_os = "linux")]
    #[test]
    fn only_placement_proves_a_lane_reachable_is_not_enough() {
        assert!(!super::Proof::Enumerated.proves_a_lane());
        assert!(
            !super::Proof::Reachable.proves_a_lane(),
            "REACHABLE MUST NOT PROVE A LANE — yoga's host had device nodes in \
             the container and size_vram=0; this is the exact assertion that \
             stops the next reader treating a successful stat as a working lane"
        );
        assert!(super::Proof::Placed.proves_a_lane());
        // The rungs are ordered, so a future caller can ask "at least
        // Reachable" for diagnosis without that ordering implying a lane.
        assert!(super::Proof::Enumerated < super::Proof::Reachable);
        assert!(super::Proof::Reachable < super::Proof::Placed);
    }

    /// 793-zumy REMAINING 2, first half: the Reachable rung now has a producer,
    /// and the rule that makes it mean anything is the vantage restriction.
    ///
    /// Four arms, three of them negative, because a producer that only ever
    /// upgrades is indistinguishable from one that ignores its inputs.
    #[test]
    fn reachable_upgrades_only_from_container_vantage_and_only_when_the_node_exists() {
        use super::{DrmRenderNode, Proof, Vantage};
        let dir = std::env::temp_dir().join(format!("tz-reach-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        std::fs::write(dir.join("renderD128"), b"").expect("node");

        let mk = |node: &str, vantage| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage,
            proof: Proof::Enumerated,
        };

        // ARM 1 — container vantage, node present: UPGRADES.
        let mut a = vec![mk("renderD128", Vantage::Container)];
        assert_eq!(super::upgrade_reachable_at(&mut a, &dir), 1);
        assert_eq!(a[0].proof, Proof::Reachable);

        // ARM 2 — HOST vantage, same node present: STAYS Enumerated. A host stat
        // is not weak evidence for the container lane, it is evidence about a
        // different question.
        let mut b = vec![mk("renderD128", Vantage::Host)];
        assert_eq!(super::upgrade_reachable_at(&mut b, &dir), 0);
        assert_eq!(
            b[0].proof,
            Proof::Enumerated,
            "a host-vantage stat must never claim the container lane's rung"
        );

        // ARM 3 — container vantage, node ABSENT: stays Enumerated.
        let mut c = vec![mk("renderD129", Vantage::Container)];
        assert_eq!(super::upgrade_reachable_at(&mut c, &dir), 0);
        assert_eq!(c[0].proof, Proof::Enumerated);

        // ARM 4 — never downgrades: a node already Placed stays Placed even
        // though this function only ever knows how to reach Reachable.
        let mut d = vec![mk("renderD128", Vantage::Container)];
        d[0].proof = Proof::Placed;
        assert_eq!(super::upgrade_reachable_at(&mut d, &dir), 0);
        assert_eq!(d[0].proof, Proof::Placed);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 793-zumy REMAINING 2, second half. Five arms, four negative, because the
    /// rung that proves a lane is the one where a wrong upgrade costs most.
    #[test]
    fn placed_upgrades_only_on_unambiguous_attribution() {
        use super::{DrmRenderNode, Proof, Vantage};
        let mk = |node: &str, proof| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage: Vantage::Container,
            proof,
        };

        // ARM 1 — one reachable node, non-zero residency: UPGRADES.
        let mut a = vec![mk("renderD128", Proof::Reachable)];
        assert_eq!(super::upgrade_placed(&mut a, 572_228_893), Some(0));
        assert_eq!(a[0].proof, Proof::Placed);

        // ARM 2 — residency ZERO: nothing. This is exactly where yoga's host sat
        // with the device statted and size_vram still 0.
        let mut b = vec![mk("renderD128", Proof::Reachable)];
        assert_eq!(super::upgrade_placed(&mut b, 0), None);
        assert_eq!(b[0].proof, Proof::Reachable);

        // ARM 3 — TWO reachable nodes: refuses. /api/ps reports per MODEL, not
        // per DEVICE, so attributing to one of two would be a guess wearing the
        // only rung that proves a lane.
        let mut c = vec![
            mk("renderD128", Proof::Reachable),
            mk("renderD129", Proof::Reachable),
        ];
        assert_eq!(super::upgrade_placed(&mut c, 572_228_893), None);
        assert!(c.iter().all(|n| n.proof == Proof::Reachable));

        // ARM 4 — only ENUMERATED nodes: refuses. A runtime cannot have placed
        // weights on a device the work's vantage cannot stat.
        let mut d2 = vec![mk("renderD128", Proof::Enumerated)];
        assert_eq!(super::upgrade_placed(&mut d2, 572_228_893), None);
        assert_eq!(d2[0].proof, Proof::Enumerated);

        // ARM 5 — one reachable among unreachable siblings: the enumerated ones
        // are not candidates, so attribution stays unambiguous and it upgrades.
        let mut e = vec![
            mk("renderD128", Proof::Enumerated),
            mk("renderD129", Proof::Reachable),
        ];
        assert_eq!(super::upgrade_placed(&mut e, 1), Some(1));
        assert_eq!(e[1].proof, Proof::Placed);
        assert_eq!(e[0].proof, Proof::Enumerated);
    }

    /// The container blob the producer parses, as one fixture the arms share.
    ///
    /// Shaped exactly like [`super::CONTAINER_PROOF_SH`]'s output: TAB-separated,
    /// `DRM` rows carrying the four sysfs reads and `DEV` rows the `/dev/dri`
    /// listing. Written out here rather than generated, so a change to the shell
    /// that broke the contract would leave this fixture disagreeing with it
    /// instead of silently following it.
    /// Field values carry NO trailing newline, matching the shell: `$(cat ...)`
    /// strips them, so a fixture that kept sysfs's newline would model a blob
    /// the container never sends and split every row across two lines.
    fn container_blob(drm: &[(&str, &str, &str, &str)], dev: &[&str]) -> String {
        let mut out = String::new();
        for (n, v, d, dr) in drm {
            out.push_str(&format!("DRM\t{n}\t{v}\t{d}\t{dr}\n"));
        }
        for e in dev {
            out.push_str(&format!("DEV\t{e}\n"));
        }
        out
    }

    /// 793-zumy REMAINING 2. The transport parses, and it claims the bottom rung
    /// and nothing more - reading four files sees hardware, never access.
    #[test]
    fn the_container_transport_parses_and_claims_only_the_enumerated_rung() {
        let blob = container_blob(
            &[("renderD128", "0x1002", "0x1114", "amdgpu")],
            &["card1", "renderD128"],
        );
        let (nodes, dev) = super::parse_container_proof_output(&blob, super::Vantage::Container);
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].node, "renderD128");
        assert_eq!(nodes[0].vendor_id, 0x1002);
        assert_eq!(nodes[0].device_id, 0x1114);
        assert_eq!(nodes[0].driver, "amdgpu");
        assert_eq!(nodes[0].vantage, super::Vantage::Container);
        assert_eq!(
            nodes[0].proof,
            super::Proof::Enumerated,
            "catting sysfs from inside a container still only sees hardware"
        );
        assert_eq!(dev, vec!["card1".to_string(), "renderD128".to_string()]);
    }

    /// A TRUNCATED blob yields fewer nodes, never a node with invented fields.
    /// The identity rule is [`super::assemble_render_node`]'s and this pins that
    /// the transport did not quietly acquire its own.
    #[test]
    fn the_container_transport_skips_rows_it_cannot_identify() {
        let blob = concat!(
            "DRM\trenderD128\t0x1002\t0x1114\tamdgpu\n",
            "DRM\trenderD129\t\t0x1114\tamdgpu\n", // unreadable vendor
            "DRM\trenderD130\t0x1002\tnothex\tamdgpu\n", // unparseable device
            "DRM\trenderD131\t0x1002\n",           // truncated mid-row
            "garbage\n",
            "DEV\t\n",
        );
        let (nodes, dev) = super::parse_container_proof_output(blob, super::Vantage::Container);
        assert_eq!(
            nodes.iter().map(|n| n.node.as_str()).collect::<Vec<_>>(),
            vec!["renderD128"],
            "a record claiming vendor 0x0000 is still a claim"
        );
        assert!(dev.is_empty());
    }

    /// The listing-based Reachable upgrade obeys the SAME rules as the
    /// filesystem one: container vantage only, only nodes the listing names,
    /// never a downgrade. Four arms, three negative.
    #[test]
    fn reachable_from_a_listing_obeys_the_same_rules_as_the_filesystem_stat() {
        use super::{DrmRenderNode, Proof, Vantage};
        let mk = |node: &str, vantage, proof| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage,
            proof,
        };
        let listing = vec!["card1".to_string(), "renderD128".to_string()];

        // ARM 1 - container vantage, node listed: UPGRADES.
        let mut a = vec![mk("renderD128", Vantage::Container, Proof::Enumerated)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut a, &listing), 1);
        assert_eq!(a[0].proof, Proof::Reachable);

        // ARM 2 - HOST vantage, same node listed: stays Enumerated.
        let mut b = vec![mk("renderD128", Vantage::Host, Proof::Enumerated)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut b, &listing), 0);
        assert_eq!(
            b[0].proof,
            Proof::Enumerated,
            "a host-vantage record must never claim the container lane's rung"
        );

        // ARM 3 - container vantage, node NOT in the listing: stays Enumerated.
        // This is the /dev/dri-not-passed case, which is the whole point.
        let mut c = vec![mk("renderD129", Vantage::Container, Proof::Enumerated)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut c, &listing), 0);
        assert_eq!(c[0].proof, Proof::Enumerated);

        // ARM 4 - never downgrades.
        let mut d = vec![mk("renderD128", Vantage::Container, Proof::Placed)];
        assert_eq!(super::upgrade_reachable_from_listing(&mut d, &listing), 0);
        assert_eq!(d[0].proof, Proof::Placed);
    }

    /// UNKNOWN AND ZERO ARE DIFFERENT FACTS. `upgrade_placed` treats zero as a
    /// definite refusal, so a parser that reported an unanswerable question as
    /// zero would be an affirmative denial derived from a failed question.
    #[test]
    fn residency_reports_unknown_and_zero_as_different_answers() {
        // A real two-model /api/ps body, one offloaded and one not.
        let body = r#"{"models":[
            {"name":"qwen2.5:3b","size":2000000000,"size_vram":572228893},
            {"name":"nomic-embed-text","size":300000000,"size_vram":0}]}"#;
        assert_eq!(super::parse_ollama_resident_bytes(body), Some(572_228_893));

        // Nothing resident on any accelerator: a definite ZERO. This is exactly
        // where yoga's gfx1152 host sat with the device statted.
        let zero = r#"{"models":[{"name":"qwen2.5:3b","size_vram":0}]}"#;
        assert_eq!(super::parse_ollama_resident_bytes(zero), Some(0));

        // No models loaded at all is still an ANSWER: zero.
        assert_eq!(
            super::parse_ollama_resident_bytes(r#"{"models":[]}"#),
            Some(0)
        );

        // A CPU-resident model omits size_vram entirely; it contributes 0
        // rather than poisoning the sum.
        assert_eq!(
            super::parse_ollama_resident_bytes(r#"{"models":[{"name":"x"}]}"#),
            Some(0)
        );

        // UNKNOWN: not JSON, or no `models` key at all. Never Some(0).
        assert_eq!(super::parse_ollama_resident_bytes("not json"), None);
        assert_eq!(super::parse_ollama_resident_bytes("{}"), None);
        assert_eq!(super::parse_ollama_resident_bytes(r#"{"models":{}}"#), None);
    }

    /// 793-zumy REMAINING 2, THE PACKET'S OWN CRITERION: the rungs are no longer
    /// inert. Five arms over the composition, because "something produces
    /// Reachable and Placed" is the claim being made and every way it could be
    /// vacuously true is a way this test could pass while the fix does not
    /// exist.
    #[test]
    fn the_producer_actually_emits_reachable_and_placed() {
        use super::Proof;
        let blob = container_blob(
            &[("renderD128", "0x1002", "0x1114", "amdgpu")],
            &["card1", "renderD128"],
        );
        let ps = r#"{"models":[{"name":"qwen2.5:3b","size_vram":572228893}]}"#;

        // ARM 1 - device passed in AND a runtime with weights on it: PLACED.
        // The rung that proves a lane, produced end to end.
        let placed =
            super::produce_container_proofs_with(|| Some(blob.clone()), || Some(ps.to_string()));
        assert_eq!(placed.len(), 1);
        assert_eq!(placed[0].proof, Proof::Placed);
        assert!(placed[0].proof.proves_a_lane());

        // ARM 2 - YOGA'S MEASURED STATE, and the one that must not inflate:
        // device nodes stat-able inside the container, size_vram still 0 because
        // the image ships no runtime that can drive them. REACHABLE, not Placed.
        let reachable = super::produce_container_proofs_with(
            || Some(blob.clone()),
            || Some(r#"{"models":[{"name":"q","size_vram":0}]}"#.to_string()),
        );
        assert_eq!(reachable[0].proof, Proof::Reachable);
        assert!(
            !reachable[0].proof.proves_a_lane(),
            "reachable is necessary and NOT sufficient"
        );

        // ARM 3 - hardware enumerates but /dev/dri was never passed in: the
        // bottom rung, and the runtime is not even asked.
        let mut asked = false;
        let enumerated = super::produce_container_proofs_with(
            || {
                Some(container_blob(
                    &[("renderD128", "0x1002", "0x1114", "amdgpu")],
                    &[],
                ))
            },
            || {
                asked = true;
                Some(ps.to_string())
            },
        );
        assert_eq!(enumerated[0].proof, Proof::Enumerated);
        assert!(
            !asked,
            "with no reachable node the residency answer cannot change a rung"
        );

        // ARM 4 - the runtime could not be asked at all. UNKNOWN residency must
        // leave the node where it was, never inflate and never downgrade.
        let unknown = super::produce_container_proofs_with(|| Some(blob.clone()), || None);
        assert_eq!(unknown[0].proof, Proof::Reachable);

        // ARM 5 - no container to ask: an EMPTY vec, never a fabricated row.
        let none = super::produce_container_proofs_with(|| None, || Some(ps.to_string()));
        assert!(none.is_empty());
    }

    /// The produced rung REACHES A CONSUMER. Without this the producers would be
    /// as inert as the model was: something computes a rung and nothing can see
    /// it. Also pins `-` for "nobody asked", which must stay distinct from
    /// `enumerated`.
    #[test]
    fn the_envelope_carries_the_highest_produced_rung() {
        use super::{DrmRenderNode, Proof, Vantage};
        let mk = |node: &str, proof| DrmRenderNode {
            node: node.to_string(),
            vendor_id: 0x1002,
            device_id: 0x1114,
            driver: "amdgpu".to_string(),
            vantage: Vantage::Container,
            proof,
        };
        let mut doc = doc_with(Vec::new());

        // ASKED AND FOUND NOTHING. A container lane was present and had no
        // render node to offer: a finding.
        assert!(
            super::accel_envelope(&doc).contains("accel_proof=none"),
            "a probed container lane with no nodes is a finding"
        );

        // NOBODY TO ASK. Yoga measured these two collapsed on 2026-09-02 and a
        // host whose container lane was WORKING read identically to one with no
        // accelerator at all — silent, and under-claiming.
        doc.enumeration_gaps.push("container-lane".to_string());
        assert!(
            super::accel_envelope(&doc).contains("accel_proof=unknown"),
            "no container to ask is a gap, not an affirmative denial"
        );
        doc.enumeration_gaps.clear();

        // The HIGHEST rung wins, not the first node's.
        doc.render_nodes = vec![
            mk("renderD128", Proof::Enumerated),
            mk("renderD129", Proof::Placed),
        ];
        assert!(super::accel_envelope(&doc).contains("accel_proof=placed"));

        doc.render_nodes = vec![mk("renderD128", Proof::Reachable)];
        let env = super::accel_envelope(&doc);
        assert!(env.contains("accel_proof=reachable"));
        // APPENDED, never inserted: every existing grep/sed consumer reads the
        // keys before it at the offsets it has always read them at.
        assert!(
            env.find("accel_ram_gb=").unwrap() < env.find("accel_proof=").unwrap(),
            "accel_proof must stay the last key"
        );
    }

    /// A sysfs walk may claim ONLY the bottom rung. It cannot see a container's
    /// device list and cannot see size_vram, so any higher claim would be the
    /// substitution this packet exists to end.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_sysfs_enumeration_claims_only_the_enumerated_rung() {
        let root = drm_fixture(&[("renderD128", "0x1002\n", "0x1638\n", "amdgpu")]);
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert_eq!(nodes[0].proof, super::Proof::Enumerated);
        assert!(
            !nodes[0].proof.proves_a_lane(),
            "an enumeration must never advertise a lane"
        );
        // Even asked from the container's vantage, a sysfs walk is still only
        // an enumeration — the vantage improves WHERE, not HOW FAR.
        let inside = super::enumerate_render_nodes_at(&root, super::Vantage::Container);
        assert_eq!(inside[0].vantage.token(), "container");
        assert_eq!(
            inside[0].proof,
            super::Proof::Enumerated,
            "vantage and proof are independent axes; a better vantage is not a higher rung"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// ORDER 793-zumy. Fixture trees, never the real /sys — a test that read
    /// this machine would assert whatever it happens to be, which is the
    /// vacuous-green shape yolanda caught on this very packet: a test that
    /// built its own fixture, never touched production, and stayed GREEN when
    /// production was reverted to a wrong value.
    #[cfg(target_os = "linux")]
    fn drm_fixture(spec: &[(&str, &str, &str, &str)]) -> std::path::PathBuf {
        // Key the root on a per-call sequence, NOT on spec.len(): every test
        // in this binary shares one process, so (pid, len) collides for any
        // two tests with same-sized specs — the first line below then deletes
        // the sibling's live fixture, and which victim loses depends on
        // thread interleaving. Latent until 2026-09-01, when an unrelated
        // +1 test shifted the schedule and made the collision deterministic.
        static FIXTURE_SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let seq = FIXTURE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("drm-fixture-{}-{}", std::process::id(), seq));
        let _ = std::fs::remove_dir_all(&root);
        for (node, vendor, device, driver) in spec {
            let dev = root.join(node).join("device");
            std::fs::create_dir_all(&dev).unwrap();
            std::fs::write(dev.join("vendor"), vendor).unwrap();
            std::fs::write(dev.join("device"), device).unwrap();
            if !driver.is_empty() {
                let drv = root.join("drivers").join(driver);
                std::fs::create_dir_all(&drv).unwrap();
                let _ = std::os::unix::fs::symlink(&drv, dev.join("driver"));
            }
        }
        root
    }

    /// THE ENUMERATION GAP 793-zumy WAS FILED AGAINST. `/dev/dri exists` is one
    /// bit and cannot represent two GPUs. This is lenovinha's real hardware,
    /// measured 2026-08-30 — the fleet's only dual-vendor fixture.
    #[cfg(target_os = "linux")]
    #[test]
    fn enumeration_represents_two_gpus_where_file_existence_cannot() {
        let root = drm_fixture(&[
            ("renderD128", "0x1002\n", "0x1638\n", "amdgpu"),
            ("renderD129", "0x10de\n", "0x24dd\n", "nvidia"),
        ]);
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert_eq!(nodes.len(), 2, "two render nodes must yield two records");
        assert_eq!(nodes[0].vendor(), "amd");
        assert_eq!(nodes[0].driver, "amdgpu");
        assert_eq!(nodes[1].vendor(), "nvidia");
        assert_eq!(nodes[1].driver, "nvidia");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// EXIT CRITERION 3, SATISFIED STRUCTURALLY RATHER THAN BY A BLOCKLIST.
    /// lavapipe/llvmpipe are USERSPACE-ONLY Vulkan ICDs: they create no DRM
    /// render node, so an enumeration of render nodes cannot see them at all.
    /// A host with Mesa's full ICD set installed and no GPU enumerates ZERO —
    /// which is why no driver-name blocklist is needed, and why this cannot rot
    /// when a new software rasterizer appears.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_software_rasterizer_cannot_satisfy_the_gpu_check() {
        let root = drm_fixture(&[]);
        std::fs::create_dir_all(&root).unwrap();
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert!(
            nodes.is_empty(),
            "a tree with no render node must enumerate nothing — llvmpipe has no node to find"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A NODE WHOSE IDENTITY CANNOT BE READ IS SKIPPED, NOT DEFAULTED. A record
    /// claiming vendor 0x0000 is still a claim, and the whole packet is about
    /// not making claims the evidence does not support.
    #[cfg(target_os = "linux")]
    #[test]
    fn an_unreadable_node_is_skipped_rather_than_reported_as_vendor_zero() {
        let root = std::env::temp_dir().join(format!("drm-partial-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("renderD128").join("device")).unwrap();
        // vendor present, device absent
        std::fs::write(root.join("renderD128/device/vendor"), "0x10de\n").unwrap();
        let nodes = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert!(
            nodes.is_empty(),
            "a half-readable node must not become a record"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// YOGA'S TIGHTENING, pinned: a record carries WHERE it was observed, and a
    /// host enumeration must never read as a container-lane claim. Their
    /// machine reported accel_gpu=usable from the host while the container had
    /// no /dev/kfd, no /dev/dri and size_vram=0 on every model — both true, and
    /// nothing distinguished them.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_record_carries_the_vantage_it_was_observed_from() {
        let root = drm_fixture(&[("renderD128", "0x1002\n", "0x1638\n", "amdgpu")]);
        let host = super::enumerate_render_nodes_at(&root, super::Vantage::Host);
        assert_eq!(host[0].vantage.token(), "host");
        let inside = super::enumerate_render_nodes_at(&root, super::Vantage::Container);
        assert_eq!(inside[0].vantage.token(), "container");
        assert_ne!(
            super::Vantage::Host,
            super::Vantage::Container,
            "the two vantages must not be interchangeable"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// LIVE, on whatever this host is. Deliberately NOT an assertion about
    /// lenovinha's hardware — it asserts an INVARIANT that must hold on every
    /// host: whatever enumerates, its identity is readable and its vantage is
    /// host. On a machine with no GPU it passes vacuously, which is correct.
    #[cfg(target_os = "linux")]
    #[test]
    fn live_enumeration_is_self_consistent_on_whatever_host_this_is() {
        let nodes = super::enumerate_render_nodes_at(
            std::path::Path::new("/sys/class/drm"),
            super::Vantage::Host,
        );
        for n in &nodes {
            assert_ne!(n.vendor_id, 0, "a reported node must have a real vendor id");
            assert!(!n.node.is_empty());
            assert_eq!(n.vantage.token(), "host");
        }
        eprintln!(
            "[793-zumy] live enumeration on this host: {} node(s)",
            nodes.len()
        );
        for n in &nodes {
            eprintln!(
                "  {} vendor={} (0x{:04x}) device=0x{:04x} driver={} vantage={}",
                n.node,
                n.vendor(),
                n.vendor_id,
                n.device_id,
                n.driver,
                n.vantage.token()
            );
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn pci_ids_parse_with_and_without_the_prefix_and_reject_garbage() {
        assert_eq!(super::parse_pci_id("0x10de\n"), Some(0x10de));
        assert_eq!(super::parse_pci_id("1002"), Some(0x1002));
        assert_eq!(super::parse_pci_id(""), None);
        assert_eq!(super::parse_pci_id("not-a-number"), None);
    }

    /// ORDER 935-jhh5. The old `cdi_ok = effective_tier == "gpu-cuda"` was
    /// CIRCULAR — the tier derives from the same `nvidia-smi` the caller already
    /// ran — so it could never report a missing spec on a host with a working
    /// driver. These pin the replacement against real spec SHAPES, using a
    /// temp dir rather than this machine's state, because on a host where CDI
    /// already works BOTH the broken and the fixed check answer true and a test
    /// that read the live filesystem would pass either way.
    #[cfg(target_os = "linux")]
    #[test]
    fn cdi_deliverable_requires_a_device_node_not_merely_the_kind() {
        use std::io::Write;
        let dir = std::env::temp_dir().join(format!("cdi-probe-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let write = |name: &str, body: &str| {
            let p = dir.join(name);
            let mut f = std::fs::File::create(&p).unwrap();
            f.write_all(body.as_bytes()).unwrap();
            p
        };

        // Names the kind but declares no node: cannot deliver a GPU.
        let bare = write(
            "bare.yaml",
            "kind: nvidia.com/gpu\ndevices:\n  - name: all\n",
        );
        assert!(
            !super::spec_file_delivers_nvidia(&bare),
            "a spec with no /dev/nvidiaN node must not count as deliverable"
        );

        // The shape a bad --dev-root produced here: the node exists but under a
        // self-referential prefix, so it lands at the wrong in-container path
        // and the inference entrypoint's `[ -e /dev/nvidia0 ]` finds nothing.
        let prefixed = write(
            "prefixed.yaml",
            "kind: nvidia.com/gpu\ndevices:\n  - name: all\n    deviceNodes:\n      - path: /run/host/dev/nvidia0\n",
        );
        assert!(
            !super::spec_file_delivers_nvidia(&prefixed),
            "a /run/host-prefixed node lands at the wrong container path — not deliverable"
        );

        // The good shape.
        let good = write(
            "good.yaml",
            "kind: nvidia.com/gpu\ndevices:\n  - name: all\n    deviceNodes:\n      - path: /dev/nvidia0\n",
        );
        assert!(
            super::spec_file_delivers_nvidia(&good),
            "a spec naming the kind and a real /dev/nvidia0 IS deliverable"
        );

        // A spec for someone else's device must not answer for NVIDIA.
        let other = write(
            "other.yaml",
            "kind: amd.com/gpu\ndevices:\n  - name: all\n    deviceNodes:\n      - path: /dev/dri/card0\n",
        );
        assert!(!super::spec_file_delivers_nvidia(&other));

        let _ = std::fs::remove_dir_all(&dir);
    }
    use super::*;

    /// ORDER 880-tdwn: pin the podman seam to /bin/false for a test's
    /// lifetime, under a module lock, restoring the prior value on drop.
    /// `run_probe` reaches `inference_image_present()` → real podman
    /// resolution; /bin/false makes that read a deterministic "no image"
    /// (the function's own documented degraded answer) instead of a
    /// live-daemon read — or, under the CI tripwire, a panic. Every test
    /// that walks run_probe MUST hold this guard.
    fn podman_seam() -> PodmanSeamGuard {
        static SEAM_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let lock = SEAM_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let prev = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", "/bin/false") };
        PodmanSeamGuard { _lock: lock, prev }
    }
    struct PodmanSeamGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
        prev: Option<std::ffi::OsString>,
    }
    impl Drop for PodmanSeamGuard {
        fn drop(&mut self) {
            unsafe {
                match self.prev.take() {
                    Some(v) => std::env::set_var("TILLANDSIAS_PODMAN_BIN", v),
                    None => std::env::remove_var("TILLANDSIAS_PODMAN_BIN"),
                }
            }
        }
    }

    /// Build a document with exactly the devices a case needs.
    fn doc_with(devices: Vec<DeviceRecord>) -> CapabilityDocument {
        CapabilityDocument {
            schema_version: SCHEMA_VERSION,
            legacy_tier: "cpu".to_string(),
            probe_identity: Some(probe_identity()),
            enumeration_gaps: Vec::new(),
            hardware_fingerprint: None,
            render_nodes: Vec::new(),
            devices,
            engines: Vec::new(),
            measurements: Vec::new(),
            host: HostInfo {
                is_battery_present: false,
                kernel_release: "test".to_string(),
                host_id: "test-host".to_string(),
                host_id_source: "input".to_string(),
                host_kind: "linux".to_string(),
                side: Some("native-linux".to_string()),
            },
            timestamp: "1970-01-01T00:00:00Z".to_string(),
        }
    }

    fn device(class: &str, name: &str, lanes: &[&str], reason: Option<&str>) -> DeviceRecord {
        DeviceRecord {
            device_class: class.to_string(),
            vendor: "test".to_string(),
            name: name.to_string(),
            device_node: None,
            fw_version: None,
            driver: None,
            usable: true,
            unusable_reason: reason.map(|r| r.to_string()),
            lanes: lanes.iter().map(|l| l.to_string()).collect(),
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            system_ram_gb: None,
            memory_model: None,
        }
    }

    /// 805-r98w. The fingerprint exists so two hosts can be SHOWN identical
    /// rather than asserted identical. The load-bearing arm is substrate
    /// independence: the SAME device records must hash the same however the
    /// OS, kernel, driver and lanes differ, because the substrate is the other
    /// axis of the matrix, not part of the hardware's identity.
    ///
    /// CORRECTED 2026-09-02. This arm used to name its two documents "yolanda"
    /// and "yoga" and call them "the twin pair". They are NOT twins — measured
    /// by the yoga host: Ryzen AI 5 340 / 6c12t / Radeon 840M against Ryzen AI
    /// 7 350 / 8c16t / Radeon 860M. The fleet asserted that pair was identical
    /// for weeks and this test had quietly become the assertion's last refuge.
    /// The hosts are generic here now; the real pair is the fixture of
    /// `fingerprint_separates_the_hosts_the_fleet_called_twins` below, which
    /// requires them to DIFFER.
    #[test]
    fn hardware_fingerprint_ignores_substrate_and_separates_real_hardware() {
        let gpu = |name: &str| {
            let mut d = device("gpu", name, &["host-native"], None);
            d.vendor = "amd".to_string();
            d.system_ram_gb = Some(15.2);
            d
        };

        // ARM 1 — SUBSTRATE INDEPENDENCE. Identical device records, and
        // everything the substrate owns differs: kernel, host_kind, host_id,
        // driver, usable, lanes. These must fingerprint IDENTICALLY, or a
        // same-hardware pair could never isolate the substrate.
        let mut a = doc_with(vec![gpu("AMD Radeon 860M")]);
        a.host.kernel_release = "6.18.33.2-microsoft-standard-WSL2".to_string();
        a.host.host_kind = "windows".to_string();
        a.host.host_id = "host-a".to_string();
        a.devices[0].driver = Some("amdgpu-wsl".to_string());
        a.devices[0].lanes = vec!["container".to_string()];

        let mut b = doc_with(vec![gpu("AMD Radeon 860M")]);
        b.host.kernel_release = "6.11.0-amd64".to_string();
        b.host.host_kind = "linux".to_string();
        b.host.host_id = "host-b".to_string();
        b.devices[0].driver = Some("amdgpu".to_string());
        b.devices[0].usable = false;

        assert_eq!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&b),
            "the twin pair must fingerprint identically across substrates — \
             otherwise same-fingerprint rows can never isolate the substrate, \
             which is the only thing this fingerprint is for"
        );

        // ARM 2 — DIFFERENT GPU: must differ. A fingerprint that collides on
        // real hardware differences licenses the comparison it exists to gate.
        let c = doc_with(vec![gpu("NVIDIA RTX A5000")]);
        assert_ne!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&c)
        );

        // ARM 3 — RAM IS BUCKETED. 15.2 and 15.9 GB are the same class; firmware
        // reservations must not split a twin pair on a number nobody chose.
        let mut d = doc_with(vec![gpu("AMD Radeon 860M")]);
        d.devices[0].system_ram_gb = Some(15.9);
        assert_eq!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&d)
        );

        // ARM 4 — a genuinely different RAM class DOES separate.
        let mut e = doc_with(vec![gpu("AMD Radeon 860M")]);
        e.devices[0].system_ram_gb = Some(64.0);
        assert_ne!(
            super::hardware_fingerprint(&a),
            super::hardware_fingerprint(&e)
        );

        // ARM 5 — ENUMERATION ORDER IS NOT A PROPERTY OF THE MACHINE.
        let f = doc_with(vec![
            gpu("AMD Radeon 860M"),
            device("npu", "XDNA2", &["host-native"], None),
        ]);
        let g = doc_with(vec![
            device("npu", "XDNA2", &["host-native"], None),
            gpu("AMD Radeon 860M"),
        ]);
        assert_eq!(
            super::hardware_fingerprint(&f),
            super::hardware_fingerprint(&g),
            "device order must not change the fingerprint"
        );
    }

    /// 805-r98w, from the yoga host's measurement 2026-08-30, relayed
    /// 2026-09-02. These two machines were called a twin pair fleet-wide for
    /// weeks. They are not: different SKU, different core counts, different
    /// iGPU bin.
    ///
    /// THE TRAP THIS PINS. AMD ships the Radeon 840M and the 860M under ONE
    /// PCI name, "Krackan [Radeon 840M / 860M Graphics]", so the GPU model
    /// string is IDENTICAL on both hosts and a fingerprint resting on it would
    /// bless a false twin — and every accel number keyed on that control would
    /// have silently inherited a hardware difference. The CPU fields are what
    /// actually separate them. `scripts/hardware-fingerprint.sh` documents the
    /// same trap; this is the Rust side of it.
    #[test]
    fn fingerprint_separates_the_hosts_the_fleet_called_twins() {
        let host = |cpu_name: &str, phys: u32, log: u32| {
            let mut c = device("cpu", cpu_name, &["host-native"], None);
            c.vendor = "amd".to_string();
            c.cpu_cores = Some(CpuCores {
                physical: phys,
                logical: log,
            });
            c.system_ram_gb = Some(15.2);
            // The SHARED, deceiving string: one PCI name for both bins.
            let mut g = device(
                "gpu",
                "Krackan [Radeon 840M / 860M Graphics]",
                &["host-native"],
                None,
            );
            g.vendor = "amd".to_string();
            doc_with(vec![c, g])
        };

        let yoga = host("AMD Ryzen AI 5 340 w/ Radeon 840M", 6, 12);
        let yolanda = host("AMD Ryzen AI 7 350 w/ Radeon 860M", 8, 16);

        assert_ne!(
            super::hardware_fingerprint(&yoga),
            super::hardware_fingerprint(&yolanda),
            "these hosts differ in SKU and core count; a fingerprint that collides on them blesses a false substrate control"
        );

        // CONTROL — the trap is real, not hypothetical. Strip the CPU records
        // and the two documents become indistinguishable, because everything
        // that remains is the shared PCI name. This is what a GPU-keyed
        // fingerprint would have done, and it pins WHICH fields the assertion
        // above is resting on: without it, that assert_ne could pass for a
        // reason unrelated to the CPU.
        let gpu_only = |d: &CapabilityDocument| {
            let mut x = d.clone();
            x.devices.retain(|dev| dev.device_class == "gpu");
            super::hardware_fingerprint(&x)
        };
        assert_eq!(
            gpu_only(&yoga),
            gpu_only(&yolanda),
            "control failed: the GPU name was expected to be identical on both              hosts — if this ever differs, AMD split the PCI name and the              comment above needs revisiting"
        );
    }

    /// 805-r98w. The comparison rule, single-implementation, so the shell's
    /// `compare` mode calls it rather than restating it.
    #[test]
    fn comparison_refuses_cross_vantage_and_carries_no_verdict() {
        let machine = |kind: &str| {
            let mut c = device(
                "cpu",
                "AMD Ryzen AI 7 350 w/ Radeon 860M",
                &["host-native"],
                None,
            );
            c.vendor = "amd".to_string();
            c.cpu_cores = Some(CpuCores {
                physical: 8,
                logical: 16,
            });
            c.system_ram_gb = Some(15.2);
            let mut d = doc_with(vec![c]);
            d.host.host_kind = kind.to_string();
            d
        };

        // Same records, different vantage: MUST refuse, not report "same".
        // Reporting equality here would be as wrong as reporting difference —
        // the documents are not commensurable, whichever way they come out.
        let err = super::compare_documents(&machine("windows"), &machine("linux"))
            .expect_err("a cross-vantage pair must be refused");
        assert!(
            matches!(err, super::ComparisonRefusal::CrossVantage { .. }),
            "wrong refusal: {err:?}"
        );

        // THE PROPERTY yoga asked for: a refusal hands back NO hardware answer.
        // The type enforces it — Err carries no fingerprint — so this asserts
        // the rendering does not leak one either.
        let rendered = err.to_string();
        assert!(
            !rendered.contains("hw"),
            "a refusal must not also emit a verdict: {rendered}"
        );

        // Vantage is checked BEFORE identifiability: a caller inspecting only
        // the error type must not conclude the vantage was validated.
        let mut blind = machine("linux");
        blind.devices[0].name = "Host CPU".to_string();
        blind.devices[0].vendor = "unknown".to_string();
        blind.devices[0].system_ram_gb = None;
        let err = super::compare_documents(&machine("windows"), &blind)
            .expect_err("cross-vantage must win over unidentifiable");
        assert!(
            matches!(err, super::ComparisonRefusal::CrossVantage { .. }),
            "vantage must be checked first: {err:?}"
        );

        // A blind document within ONE vantage refuses as unidentifiable.
        let err = super::compare_documents(&machine("linux"), &blind)
            .expect_err("an unidentifiable document must be refused");
        assert!(
            matches!(err, super::ComparisonRefusal::Unidentifiable { .. }),
            "wrong refusal: {err:?}"
        );

        // CONTROL — a legitimate comparison still succeeds, so the refusals
        // above are not simply refusing everything.
        assert!(matches!(
            super::compare_documents(&machine("linux"), &machine("linux")),
            Ok(super::FingerprintComparison::Same(_))
        ));
    }

    /// 805-r98w / NPU parity, 2026-09-02. `none` must mean "looked and found
    /// nothing", never "could not look".
    ///
    /// MEASURED, not hypothetical: native Windows on this host rendered
    /// `accel_gpu=none accel_npu=none accel_reason=-` while the machine has a
    /// Radeon 860M and an XDNA2 NPU that Lemonade was serving models on at that
    /// moment. enumerate_gpus has Linux and macOS arms and no Windows arm;
    /// enumerate_npus reads /sys/class/accel. Both return empty and SUCCEED.
    #[test]
    fn absent_accelerators_read_unknown_where_the_probe_cannot_look() {
        let bare = || doc_with(vec![device("cpu", "Host CPU", &["host-native"], None)]);

        // LOOKED AND FOUND NOTHING: no gaps recorded, so `none` is a finding.
        let found_none = super::accel_envelope(&bare());
        assert!(found_none.contains("accel_gpu=none"), "{found_none}");
        assert!(found_none.contains("accel_npu=none"), "{found_none}");

        // COULD NOT LOOK: the probe recorded that it failed to enumerate, so
        // the same empty device list must NOT render as an absence.
        let mut blind = bare();
        blind.enumeration_gaps = vec!["gpu".to_string(), "npu".to_string()];
        let env = super::accel_envelope(&blind);
        assert!(
            env.contains("accel_gpu=unknown"),
            "a probe that could not look must not claim none: {env}"
        );
        assert!(
            env.contains("accel_npu=unknown"),
            "a probe that could not look must not claim none: {env}"
        );
        assert!(
            env.contains("not-enumerable-on-this-platform"),
            "cpu-only must never be a bare verdict here: {env}"
        );

        // ONE CLASS ONLY: a gap in gpu must not make the npu unknown too.
        let mut gpu_blind = bare();
        gpu_blind.enumeration_gaps = vec!["gpu".to_string()];
        let env = super::accel_envelope(&gpu_blind);
        assert!(env.contains("accel_gpu=unknown"), "{env}");
        assert!(
            env.contains("accel_npu=none"),
            "an npu that WAS enumerated stays a finding: {env}"
        );

        // A REAL device still reports its own state even when its class was
        // listed as a gap — an enumerated device outranks the gap record, and
        // this pins that the change cannot turn present hardware into unknown.
        let mut gpu = device("gpu", "AMD Radeon 860M", &["container"], None);
        gpu.vendor = "amd".to_string();
        let mut with_gpu = doc_with(vec![device("cpu", "Host CPU", &["host-native"], None), gpu]);
        with_gpu.enumeration_gaps = vec!["gpu".to_string()];
        let env2 = super::accel_envelope(&with_gpu);
        assert!(
            env2.contains("accel_gpu=usable"),
            "an enumerated device must still report its real state: {env2}"
        );
    }

    /// 805-r98w, hazard adopted from yoga 2026-09-02. THIS TEST DOCUMENTS A
    /// LIMITATION, NOT A GUARANTEE — it passes by asserting the fingerprint is
    /// NOT substrate-independent in the case that matters most.
    ///
    /// `hardware_fingerprint_ignores_substrate_and_separates_real_hardware`
    /// asserts that identical device records hash identically however the
    /// kernel, driver and lanes differ. True, and useless on its own: the
    /// substrate does not merely decorate the device records, it CHANGES them.
    /// The same machine reports its iGPU as "WSL2 paravirtual GPU (/dev/dxg)"
    /// under WSL2 — the PATH, not the silicon — and emits no GPU device at all
    /// probed natively on Windows. So that test's premise (identical inputs)
    /// assumes exactly what it is meant to prove.
    ///
    /// Consequence, pinned here so it is never rediscovered as a surprise:
    /// comparing documents from different `host.host_kind` is NOT a valid
    /// hardware comparison, and a mismatch across that boundary is not evidence
    /// of different hardware. The compare path must refuse such a pair rather
    /// than report a difference.
    ///
    /// gpu_model is deliberately NOT dropped to make the invariant hold: on
    /// Linux it is a real discriminator, and trading a loud known limitation
    /// for a quiet loss of signal is the worse bargain.
    #[test]
    fn same_machine_across_substrates_does_not_yet_fingerprint_alike() {
        let cpu = || {
            let mut c = device(
                "cpu",
                "AMD Ryzen AI 7 350 w/ Radeon 860M",
                &["host-native"],
                None,
            );
            c.vendor = "amd".to_string();
            c.cpu_cores = Some(CpuCores {
                physical: 8,
                logical: 16,
            });
            c.system_ram_gb = Some(15.2);
            c
        };

        // ONE machine, seen three ways by three probes.
        let mut native_windows = doc_with(vec![cpu()]);
        native_windows.host.host_kind = "windows".to_string();

        let mut under_wsl2 = doc_with(vec![
            cpu(),
            device(
                "gpu",
                "WSL2 paravirtual GPU (/dev/dxg)",
                &["container"],
                None,
            ),
        ]);
        under_wsl2.host.host_kind = "windows".to_string();

        let mut native_linux = doc_with(vec![
            cpu(),
            device(
                "gpu",
                "Krackan [Radeon 840M / 860M Graphics]",
                &["host-native"],
                None,
            ),
        ]);
        native_linux.host.host_kind = "linux".to_string();

        let w = super::hardware_fingerprint(&native_windows);
        let x = super::hardware_fingerprint(&under_wsl2);
        let l = super::hardware_fingerprint(&native_linux);

        assert_ne!(
            w, x,
            "documented limitation: the WSL2 probe adds a paravirtual GPU record the native probe lacks"
        );
        assert_ne!(
            x, l,
            "documented limitation: the WSL2 GPU string names the PATH, the Linux one names the silicon"
        );

        // The refusal guard does NOT paper over this: all three documents carry
        // a real CPU model, so all three are accepted and hashed. The hazard is
        // therefore live in exactly the case the guard cannot catch, which is
        // why it is written down rather than left to be met in the field.
        for (label, doc) in [
            ("native_windows", &native_windows),
            ("under_wsl2", &under_wsl2),
            ("native_linux", &native_linux),
        ] {
            assert!(
                super::hardware_fingerprint_checked(doc).is_ok(),
                "{label} should be accepted — the guard catches blind probes, not this"
            );
        }
    }

    /// 805-r98w. Measured on native Windows 2026-09-02: the probe emits ONE
    /// device, `cpu/unknown/Host CPU`, no GPU, no NPU, no RAM — and the raw
    /// hasher returned a confident `hw1-...` for it. That string is shared by
    /// every Windows host with the same logical-core count, so publishing it
    /// as an identity manufactures twins that do not exist.
    #[test]
    fn placeholder_document_is_refused_rather_than_hashed() {
        let mut cpu = device("cpu", "Host CPU", &["host-native"], None);
        cpu.vendor = "unknown".to_string();
        cpu.cpu_cores = Some(CpuCores {
            physical: 16,
            logical: 16,
        });
        let windows_today = doc_with(vec![cpu]);

        let refusal = super::hardware_fingerprint_checked(&windows_today)
            .expect_err("a placeholder-only document must be refused");
        assert!(
            refusal.missing.iter().any(|m| m.contains("cpu model name")),
            "the refusal must name the placeholder CPU: {refusal:?}"
        );
        assert!(
            refusal
                .missing
                .iter()
                .any(|m| m.contains("secondary discriminator")),
            "the refusal must name the absent gpu/npu/ram: {refusal:?}"
        );

        // CONTROL: a document that CAN identify the machine still succeeds,
        // so the guard refuses the placeholder and not the feature.
        let mut cpu = device(
            "cpu",
            "AMD Ryzen AI 7 350 w/ Radeon 860M",
            &["host-native"],
            None,
        );
        cpu.vendor = "amd".to_string();
        cpu.cpu_cores = Some(CpuCores {
            physical: 8,
            logical: 16,
        });
        cpu.system_ram_gb = Some(15.2);
        let real = doc_with(vec![cpu]);
        assert!(
            super::hardware_fingerprint_checked(&real).is_ok(),
            "a document carrying a real CPU model and RAM must be accepted"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_reports_workstation_gpu_when_the_container_lane_is_open() {
        let d = doc_with(vec![device(
            "gpu",
            "NVIDIA RTX A5000",
            &["container", "host-native"],
            None,
        )]);
        let env = accel_envelope(&d);
        assert!(
            env.contains("accel_class=workstation-gpu"),
            "a container-deliverable GPU is the workstation tier: {env}"
        );
        assert!(env.contains("accel_gpu=usable"), "{env}");
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_refuses_to_call_a_gpu_usable_when_only_the_host_lane_is_open() {
        // The NVIDIA-without-CDI record this codebase actually constructs:
        // usable=true AND unusable_reason=cdi-spec-missing, host-native only.
        // Reading `usable` would advertise a GPU no forge can touch.
        let d = doc_with(vec![device(
            "gpu",
            "NVIDIA RTX A5000",
            &["host-native"],
            Some("cdi-spec-missing"),
        )]);
        let env = accel_envelope(&d);
        assert!(
            env.contains("accel_class=cpu-only"),
            "a GPU the container cannot receive must not set a GPU class: {env}"
        );
        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(
            env.contains("accel_reason=cdi-spec-missing"),
            "cpu-only must never be a bare verdict — name the obstruction: {env}"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_reports_the_mobile_npu_tier_and_the_hybrid_tier() {
        let npu_only = doc_with(vec![
            device("npu", "AMD XDNA", &["container"], None),
            device("gpu", "iGPU", &["host-native"], Some("engine-missing")),
        ]);
        assert!(
            accel_envelope(&npu_only).contains("accel_class=mobile-npu"),
            "{}",
            accel_envelope(&npu_only)
        );

        let both = doc_with(vec![
            device("npu", "AMD XDNA", &["container"], None),
            device("gpu", "NVIDIA RTX A5000", &["container"], None),
        ]);
        assert!(
            accel_envelope(&both).contains("accel_class=hybrid-gpu-npu"),
            "{}",
            accel_envelope(&both)
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_stays_one_parsable_line_even_with_hostile_device_names() {
        // `nvidia-smi -L` yields names with spaces, colons and parentheses. A
        // raw name would split the space-separated grammar and corrupt every
        // key after it.
        let d = doc_with(vec![device(
            "gpu",
            "GPU 0: NVIDIA RTX A5000 (UUID: GPU-dead beef)",
            &["container"],
            None,
        )]);
        let env = accel_envelope(&d);
        assert_eq!(env.lines().count(), 1, "envelope must be a single line");
        let keys: Vec<&str> = env
            .split(' ')
            .filter(|f| !f.is_empty())
            .map(|f| f.split('=').next().unwrap_or(""))
            .collect();
        assert_eq!(
            keys,
            vec![
                "accel_class",
                "accel_gpu",
                "accel_gpu_name",
                "accel_npu",
                "accel_npu_name",
                "accel_reason",
                "accel_cpu_cores",
                "accel_ram_gb",
                // 793-zumy REMAINING 2, appended last so every offset above it
                // is the one existing consumers already read.
                "accel_proof",
                // Orders 793-qr4t + 793-qc6q, APPENDED. The list is asserted in
                // ORDER, so this test is also the pin that the additive
                // extension stayed additive: any key inserted among the eight
                // above — a rename or a reorder wearing an addition's
                // clothes — fails here rather than at whichever consumer
                // splits on position.
                "accel_side",
                "accel_gpu_path",
                "accel_gpu_engine",
                "accel_mem_model",
                "accel_mem_budget_gb",
                "accel_prefill_dev",
                "accel_decode_dev",
                "accel_decode_crossover_b",
            ],
            "every field must survive a hostile name: {env}"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn cache_path_never_resolves_into_the_working_directory() {
        // Order 495: generated evidence must never land in the tracked checkout.
        // With no HOME the old fallback was ".", so a build or `cargo test`
        // wrote capabilities.json into the crate directory — dirt the NEXT
        // agent's forge dirty-start guard refuses, for a file they did not
        // create. Absolute-and-not-under-CWD is the property that matters.
        let path = capabilities_cache_path();
        assert!(
            path.is_absolute(),
            "cache path must be absolute, got {path:?}"
        );
        if let Ok(cwd) = std::env::current_dir() {
            assert!(
                !path.starts_with(&cwd) || cwd == Path::new("/"),
                "cache path {path:?} must not resolve inside the working directory {cwd:?}"
            );
        }
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn nvidia_model_name_drops_the_index_prefix_and_the_hardware_uuid() {
        // Verbatim shape of `nvidia-smi -L` on this workstation.
        let raw = "GPU 0: NVIDIA RTX A5000 (UUID: GPU-354dc81c-189c-4074-1cb4-6cb1ae80f68b)";
        assert_eq!(nvidia_model_name(raw), "NVIDIA RTX A5000");
        assert!(
            !nvidia_model_name(raw).contains("354dc81c"),
            "the GPU UUID is a stable hardware identifier and must not travel \
             into every forge's env and context file"
        );
        // An unfamiliar format degrades to noisy, never to empty.
        assert_eq!(
            nvidia_model_name("Some Future Format"),
            "Some Future Format"
        );
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn envelope_on_a_bare_cpu_host_is_cpu_only_with_no_phantom_devices() {
        let env = accel_envelope(&doc_with(vec![device("cpu", "CPU", &["container"], None)]));
        assert!(env.contains("accel_class=cpu-only"), "{env}");

        // THE PROPERTY THIS TEST OWNS is that no device is MANUFACTURED: the
        // class stays cpu-only and neither name field names anything.
        assert!(env.contains("accel_gpu_name=-"), "{env}");
        assert!(env.contains("accel_npu_name=-"), "{env}");

        // The STATE, however, is platform-dependent, and asserting `none`
        // unconditionally is what this test used to get wrong (2026-09-02). It
        // silently assumed the running platform can enumerate accelerators. On
        // native Windows it cannot — no Windows arm in enumerate_gpus, and
        // enumerate_npus reads a Linux-only sysfs path — so `none` there was
        // the probe denying hardware it had never looked for. "Looked and found
        // nothing" and "cannot look here" are different facts and only the
        // first is `none`.
        // This document records NO gaps, so an empty device list here is a
        // genuine finding and `none` is the honest rendering on every platform.
        assert!(env.contains("accel_gpu=none"), "{env}");
        assert!(env.contains("accel_npu=none"), "{env}");
    }

    #[test]
    #[cfg(target_os = "linux")]
    // @trace spec:accel-capability-probe
    fn wsl2_paravirtual_gpu_fires_only_on_the_unambiguous_wsl2_shape() {
        // The whole decision table. The one true case: /dev/dxg present, no DRI
        // render node, nothing better already found.
        assert!(wsl2_paravirtual_gpu(true, false, false), "the WSL2 shape");

        // Bare-metal Linux has no /dev/dxg — this must never manufacture a
        // phantom device there, which is what
        // envelope_on_a_bare_cpu_host_is_cpu_only_with_no_phantom_devices pins.
        assert!(!wsl2_paravirtual_gpu(false, false, false), "no dxg, no dri");
        assert!(
            !wsl2_paravirtual_gpu(false, true, false),
            "bare-metal with DRI"
        );
        assert!(
            !wsl2_paravirtual_gpu(false, true, true),
            "bare-metal, gpu found"
        );
        assert!(
            !wsl2_paravirtual_gpu(false, false, true),
            "no dxg, gpu found"
        );

        // A WSL2 host that DOES expose a render node is the /dev/dri arm's job;
        // emitting here too would double-count one GPU.
        assert!(
            !wsl2_paravirtual_gpu(true, true, false),
            "dxg with a DRI node"
        );
        assert!(
            !wsl2_paravirtual_gpu(true, true, true),
            "dxg, DRI, gpu found"
        );

        // nvidia-smi answered first (a WSL2 host with a CUDA passthrough), so a
        // better record already exists and this must defer to it.
        assert!(
            !wsl2_paravirtual_gpu(true, false, true),
            "defers to a found gpu"
        );
    }

    // @trace spec:accel-capability-probe
    /// ORDER 793-zumy criterion 2, pinned against the PRODUCTION value.
    ///
    /// Measured on yolanda 2026-08-29: /dev/dxg present, /dev/dri absent, and no
    /// Vulkan loader at all — vulkaninfo off PATH, /usr/share/vulkan/icd.d
    /// absent. The old reason, `wsl2-no-dri-render-node`, named a render node
    /// WSL2 is never expected to create, so it described normal WSL2 while
    /// reading to a scheduler as a hardware verdict. The real obstruction is a
    /// missing translation layer, which is provisioning, not silicon.
    ///
    /// Read the sibling test below before trusting either: it renders a
    /// TEST-SUPPLIED reason and therefore cannot pin production at all. This one
    /// asserts the shipped value, and was confirmed to go red against the old
    /// literal before it went green.
    #[test]
    fn the_wsl2_unusable_reason_names_the_missing_engine_not_the_missing_render_node() {
        let reason = wsl2_paravirtual_gpu_reason();

        // Criterion 2 requires this word verbatim.
        assert!(
            reason.starts_with("engine-missing"),
            "criterion 2 requires the verbatim word `engine-missing`; got {reason}"
        );
        // The red herring must not come back.
        assert!(
            !reason.contains("dri-render-node"),
            "the reason blames a render node WSL2 never creates: {reason}"
        );
        // A provisioning statement should name its own remedy, like the sibling
        // rocm-runtime-missing / intel-compute-runtime-missing values do.
        assert!(
            reason.contains("vulkan"),
            "the reason should name WHICH engine is missing: {reason}"
        );
    }

    /// NOTE: this test cannot pin the production reason — it supplies its own.
    /// Kept for what it does cover (present-unusable never collapsing to none,
    /// and the class staying cpu-only). See the test above for the reason pin.
    #[test]
    fn a_wsl2_paravirtual_gpu_renders_as_present_unusable_never_as_none() {
        // The point of 806-2r4s: this host has a healthy AMD Radeon 860M that
        // WSL2 exposes only as /dev/dxg. Before the probe emitted this record
        // the envelope read `accel_gpu=none accel_reason=-`, which is
        // indistinguishable from a machine with no GPU at all — and the fleet
        // capability matrix cannot be built on that.
        let mut gpu = device(
            "gpu",
            "WSL2 paravirtual GPU (/dev/dxg)",
            &[],
            Some("engine-missing:no-vulkan-icd"),
        );
        gpu.usable = false;

        let env = accel_envelope(&doc_with(vec![
            device("cpu", "CPU", &["container"], None),
            gpu,
        ]));

        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(!env.contains("accel_gpu=none"), "{env}");
        assert!(env.contains("engine-missing"), "{env}");
        // Capacity is still cpu-only — an unreachable GPU must not inflate the
        // class, or a scheduler would place GPU work on a host that cannot run it.
        assert!(env.contains("accel_class=cpu-only"), "{env}");
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_probe_produces_valid_document() {
        let _seam = podman_seam();
        let doc = run_probe("gpu-cuda");
        assert_eq!(doc.schema_version, SCHEMA_VERSION);
        assert_eq!(doc.legacy_tier, "gpu-cuda");
        assert!(!doc.devices.is_empty());
        let cpu = doc
            .devices
            .iter()
            .find(|d| d.device_class == "cpu")
            .expect("CPU present");
        assert!(cpu.usable);
        assert!(cpu.lanes.contains(&"container".to_string()));
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_serialization_roundtrip() {
        let _seam = podman_seam();
        let doc = run_probe("cpu");
        let json = serde_json::to_string_pretty(&doc).expect("serialize");
        let deserialized: CapabilityDocument = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(doc, deserialized);
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_npu_vendor_resolution() {
        let npu_amd = parse_npu_record(Some("amdxdna"));
        assert_eq!(npu_amd.vendor, "AMD XDNA");
        assert!(!npu_amd.usable);
        assert_eq!(npu_amd.unusable_reason.as_deref(), Some("engine-missing"));

        let npu_intel = parse_npu_record(Some("intel_vpu"));
        assert_eq!(npu_intel.vendor, "Intel NPU");
        assert!(!npu_intel.usable);

        let npu_unknown = parse_npu_record(Some("custom_accel"));
        assert_eq!(npu_unknown.vendor, "unknown");
        assert!(!npu_unknown.usable);
    }

    fn parse_npu_record(driver: Option<&str>) -> DeviceRecord {
        let (vendor, name_str) = match driver {
            Some("amdxdna") => ("AMD XDNA".to_string(), "AMD XDNA NPU".to_string()),
            Some("intel_vpu") => ("Intel NPU".to_string(), "Intel NPU".to_string()),
            Some(other) => ("unknown".to_string(), format!("Unknown NPU ({other})")),
            None => ("unknown".to_string(), "Unknown Accel Device".to_string()),
        };
        DeviceRecord {
            device_class: "npu".to_string(),
            vendor,
            name: name_str,
            device_node: Some("/dev/accel/accel0".to_string()),
            fw_version: None,
            driver: driver.map(|s| s.to_string()),
            usable: false,
            unusable_reason: Some("engine-missing".to_string()),
            lanes: vec!["host-native".to_string()],
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            system_ram_gb: None,
            memory_model: None,
        }
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_macos_metal_lane_isolation() {
        let metal_device = DeviceRecord {
            device_class: "gpu".to_string(),
            vendor: "apple".to_string(),
            name: "Apple Metal GPU".to_string(),
            device_node: None,
            fw_version: None,
            driver: None,
            usable: true,
            unusable_reason: None,
            lanes: vec!["host-native".to_string()],
            memory_bandwidth_gbps: None,
            memory_bandwidth_source: "unknown".to_string(),
            cpu_flags: None,
            cpu_cores: None,
            system_ram_gb: None,
            memory_model: None,
        };
        assert!(!metal_device.lanes.contains(&"container".to_string()));
        assert!(metal_device.lanes.contains(&"host-native".to_string()));
    }

    // ---- order 808-43mw: host identity and measurement labelling ----

    /// THE COMPATIBILITY GUARD, and the reason the new fields are optional.
    ///
    /// This is byte-for-byte the payload `scripts/bench-accel-lane.sh` pipes
    /// into `--record-measurement` today (its `jq -nc` object, same key order).
    /// That script belongs to another host. If widening this struct made the
    /// current payload unparseable, the first host to run a new binary against
    /// the unchanged script would stop recording measurements — and would do it
    /// QUIETLY, because the script's own `|| echo note:...record-failed` arm
    /// keeps the bench exiting 0.
    #[test]
    fn todays_bench_payload_still_deserializes() {
        let payload = r#"{"device":"cpu","engine":"ollama","prefill_tps":1024.5,
            "decode_tps":87.2,"joules_per_token":null,"degraded":false,
            "degraded_reason":null}"#;

        let rec: MeasurementRecord =
            serde_json::from_str(payload).expect("the CURRENT bench payload must still parse");

        assert_eq!(rec.device, "cpu");
        assert_eq!(rec.engine, "ollama");
        assert_eq!(
            rec.workload_suite, None,
            "an unlabelled record must read as UNLABELLED, never as a default suite"
        );
        assert_eq!(rec.locus, None, "same for locus: absent is not a value");
    }

    /// And a labelled payload round-trips, so the writer has something to aim at.
    #[test]
    fn a_labelled_measurement_round_trips() {
        let rec = MeasurementRecord {
            device: "cpu".to_string(),
            engine: "ollama".to_string(),
            prefill_tps: Some(1024.5),
            decode_tps: Some(87.2),
            joules_per_token: None,
            degraded: false,
            degraded_reason: None,
            workload_suite: Some("802-2536-v1".to_string()),
            locus: Some("in-guest".to_string()),
            model: None,
            model_params_b: None,
        };
        let json = serde_json::to_string(&rec).expect("serializes");
        let back: MeasurementRecord = serde_json::from_str(&json).expect("round-trips");
        assert_eq!(back, rec);
    }

    /// A v1 document has no host_id, so it must be REJECTED rather than read
    /// as a host whose name happens to be empty. `load_or_probe` treats a parse
    /// failure as "re-probe", which is the correct outcome: a document that
    /// cannot name itself is not a row the matrix can accept.
    #[test]
    fn a_v1_document_without_host_identity_is_refused() {
        let v1 = r#"{"schema_version":1,"legacy_tier":"cpu","devices":[],
            "engines":[],"measurements":[],
            "host":{"is_battery_present":false,"kernel_release":"6.18.33.2-microsoft-standard-WSL2"},
            "timestamp":"1970-01-01T00:00:00Z"}"#;
        assert!(
            serde_json::from_str::<CapabilityDocument>(v1).is_err(),
            "a document with no host_id must not deserialize into one with a blank host_id"
        );
    }

    /// Two WSL2 guests share a kernel release EXACTLY — measured, not assumed:
    /// this host's guest reports `6.18.33.2-microsoft-standard-WSL2`, and so
    /// does any other guest on the same WSL kernel. This test states why
    /// `kernel_release` could not have been the fold key.
    #[test]
    fn kernel_release_does_not_distinguish_two_wsl2_hosts() {
        let shared = "6.18.33.2-microsoft-standard-WSL2".to_string();
        let a = HostInfo {
            is_battery_present: false,
            kernel_release: shared.clone(),
            host_id: "yolanda".to_string(),
            host_id_source: "node-name".to_string(),
            host_kind: "linux".to_string(),
            side: Some("native-linux".to_string()),
        };
        let b = HostInfo {
            host_id: "esmeraldinha".to_string(),
            ..a.clone()
        };
        assert_eq!(a.kernel_release, b.kernel_release, "the collision is real");
        assert_ne!(a.host_id, b.host_id, "and host_id is what separates them");
    }

    #[test]
    fn node_names_are_shortened_and_lowercased() {
        assert_eq!(normalize_node_name("Yolanda").as_deref(), Some("yolanda"));
        assert_eq!(
            normalize_node_name("YOGA.localdomain\n").as_deref(),
            Some("yoga"),
            "the domain is stripped, matching the shell probe"
        );
        assert_eq!(normalize_node_name("  \n ").as_deref(), None);
        assert_eq!(normalize_node_name(".leading-dot").as_deref(), None);
    }

    /// The INPUT wins over the derived chain, and is normalised on the way in —
    /// otherwise `TILLANDSIAS_HOST_ID=Yolanda` and a derived `yolanda` would be
    /// two keys for one machine, which is the defect this field exists to fix.
    #[test]
    fn the_input_overrides_the_derived_name_and_is_normalised() {
        let prev = std::env::var_os(HOST_ID_ENV);
        unsafe { std::env::set_var(HOST_ID_ENV, "Esmeraldinha.LOCAL") };
        let (id, source) = resolve_host_id();
        match prev {
            Some(v) => unsafe { std::env::set_var(HOST_ID_ENV, v) },
            None => unsafe { std::env::remove_var(HOST_ID_ENV) },
        }
        assert_eq!(id, "esmeraldinha");
        assert_eq!(source, "input");
    }

    /// Whatever this machine is, the probe must produce a usable key: never
    /// empty, always lowercase, and always with a source that says how it was
    /// obtained.
    #[test]
    fn the_probe_always_yields_a_foldable_key() {
        let prev = std::env::var_os(HOST_ID_ENV);
        unsafe { std::env::remove_var(HOST_ID_ENV) };
        let (id, source) = resolve_host_id();
        if let Some(v) = prev {
            unsafe { std::env::set_var(HOST_ID_ENV, v) }
        }
        assert!(
            !id.is_empty(),
            "an empty key would fold every unknown host into one row"
        );
        assert_eq!(id, id.to_ascii_lowercase());
        assert!(
            ["input", "node-name", "unknown"].contains(&source.as_str()),
            "unexpected host_id_source {source}"
        );
    }

    /// `host_kind` speaks the ledger's vocabulary, not Rust's — the ledger says
    /// `macos`, `std::env::consts::OS` says `macos` too but only by luck of
    /// spelling, and a consumer folding the matrix must not have to know which.
    #[test]
    fn host_kind_uses_the_ledgers_vocabulary() {
        assert!(
            ["linux", "windows", "macos"].contains(&host_kind()),
            "host_kind() returned {} which is not a fleet host vocabulary term",
            host_kind()
        );
    }

    /// PINS THE KNOWN GAP so it cannot be mistaken for a bug later, and so the
    /// day someone fixes it the test says what changed.
    ///
    /// A document produced inside a WSL2 guest carries `host_kind: "linux"`
    /// while describing a machine whose spec is a Windows laptop's. The pair
    /// (kernel_release says WSL2, host_kind says linux) is currently the ONLY
    /// in-document signal that a row was observed from a guest — it is not a
    /// substitute for the host-side contribution 809-7e4m specifies, and this
    /// test asserts the gap rather than pretending it is closed.
    #[test]
    fn a_wsl2_row_cannot_yet_say_its_machine_is_windows() {
        let guest_row = HostInfo {
            is_battery_present: true,
            kernel_release: "6.18.33.2-microsoft-standard-WSL2".to_string(),
            host_id: "yolanda".to_string(),
            host_id_source: "node-name".to_string(),
            host_kind: "linux".to_string(),
            side: Some("native-linux".to_string()),
        };
        assert!(
            guest_row.kernel_release.contains("microsoft-standard-WSL2"),
            "the kernel is the only hint the context is a guest"
        );
        assert_eq!(
            guest_row.host_kind, "linux",
            "KNOWN GAP (809-7e4m): the context is linux, the machine is windows"
        );
    }

    /// 808-43mw's `verifiable_closure`, executed rather than asserted:
    /// "a capability document round-trips a host_id, and a measurement carries
    /// suite + locus; two documents from different loci are machine-
    /// distinguishable without reading any prose".
    #[test]
    fn closure_808_43mw_documents_are_machine_distinguishable_by_host_and_locus() {
        let measured_at = |host: &str, locus: &str| CapabilityDocument {
            schema_version: SCHEMA_VERSION,
            legacy_tier: "cpu".to_string(),
            probe_identity: Some(probe_identity()),
            enumeration_gaps: Vec::new(),
            hardware_fingerprint: None,
            render_nodes: Vec::new(),
            devices: Vec::new(),
            engines: Vec::new(),
            measurements: vec![MeasurementRecord {
                device: "cpu".to_string(),
                engine: "ollama".to_string(),
                prefill_tps: Some(1024.0),
                decode_tps: Some(87.0),
                joules_per_token: None,
                degraded: false,
                degraded_reason: None,
                workload_suite: Some("802-2536-v1".to_string()),
                locus: Some(locus.to_string()),
                model: None,
                model_params_b: None,
            }],
            host: HostInfo {
                is_battery_present: true,
                kernel_release: "6.18.33.2-microsoft-standard-WSL2".to_string(),
                host_id: host.to_string(),
                host_id_source: "node-name".to_string(),
                host_kind: "linux".to_string(),
                side: Some("native-linux".to_string()),
            },
            timestamp: "1970-01-01T00:00:00Z".to_string(),
        };

        // (a) the document round-trips its host_id through JSON
        let yolanda = measured_at("yolanda", "in-guest");
        let json = serde_json::to_string(&yolanda).expect("serializes");
        let back: CapabilityDocument = serde_json::from_str(&json).expect("round-trips");
        assert_eq!(back, yolanda);
        assert_eq!(back.host.host_id, "yolanda");

        // (b) the measurement carries suite AND locus
        let m = &back.measurements[0];
        assert_eq!(m.workload_suite.as_deref(), Some("802-2536-v1"));
        assert_eq!(m.locus.as_deref(), Some("in-guest"));

        // (c) two documents at different loci differ in a MACHINE-READABLE
        //     field — not merely in a comment a human has to notice.
        let mirrored = measured_at("yolanda", "host-side-via-mirror");
        assert_eq!(
            yolanda.host.host_id, mirrored.host.host_id,
            "same machine, so the fold key must agree"
        );
        assert_ne!(
            yolanda.measurements[0].locus, mirrored.measurements[0].locus,
            "and the locus is what tells a consumer these are not comparable"
        );

        // (d) and two machines sharing a kernel remain separable
        let esmeraldinha = measured_at("esmeraldinha", "in-guest");
        assert_eq!(
            yolanda.host.kernel_release,
            esmeraldinha.host.kernel_release
        );
        assert_ne!(yolanda.host.host_id, esmeraldinha.host.host_id);
    }

    #[test]
    // @trace order:803-825k, spec:accel-capability-probe
    fn test_enumerate_engines_empty_when_no_engine_available() {
        let engines = enumerate_engines_with(|_| false, || false);
        assert!(
            engines.is_empty(),
            "a host with no inference engine installed must not advertise any engine records"
        );
    }

    #[test]
    // @trace order:803-825k, spec:accel-capability-probe
    fn test_enumerate_engines_detects_ollama_and_llama_server() {
        let only_ollama = enumerate_engines_with(|bin| bin == "ollama", || false);
        assert_eq!(only_ollama.len(), 1);
        assert_eq!(only_ollama[0].name, "ollama");
        assert_eq!(only_ollama[0].backend, "llama-server");
        assert_eq!(only_ollama[0].supported_device_classes, vec!["cpu", "gpu"]);
        assert_eq!(
            only_ollama[0].lanes, None,
            "host-PATH engines cover every lane"
        );

        let only_llama = enumerate_engines_with(|bin| bin == "llama-server", || false);
        assert_eq!(only_llama.len(), 1);
        assert_eq!(only_llama[0].name, "llama-server");
        assert_eq!(only_llama[0].backend, "llama.cpp");
        assert_eq!(only_llama[0].supported_device_classes, vec!["cpu", "gpu"]);

        let both = enumerate_engines_with(|bin| bin == "ollama" || bin == "llama-server", || false);
        assert_eq!(both.len(), 2);
        assert_eq!(both[0].name, "ollama");
        assert_eq!(both[1].name, "llama-server");
    }

    #[test]
    // @trace order:850-bif2, spec:accel-capability-probe
    fn test_containerized_engine_is_container_lane_only_and_never_shadows_host_ollama() {
        // The inference image present with no host binaries: one ollama
        // record, scoped to the container lane. This is the record whose
        // absence made a usable RTX A5000 read "schedulable: none".
        let containerized = enumerate_engines_with(|_| false, || true);
        assert_eq!(containerized.len(), 1);
        assert_eq!(containerized[0].name, "ollama");
        assert_eq!(
            containerized[0].lanes,
            Some(vec!["container".to_string()]),
            "an engine inside an image must not claim host-native reach"
        );

        // Host ollama present too: the host record (all lanes) wins and the
        // container record is not duplicated.
        let host_wins = enumerate_engines_with(|bin| bin == "ollama", || true);
        assert_eq!(host_wins.len(), 1);
        assert_eq!(host_wins[0].lanes, None);
    }

    #[test]
    // @trace order:850-bif2, spec:accel-capability-probe
    fn test_amd_gpu_disposition_fails_closed_without_rocm_runtime() {
        // rocm-smi presence alone is not evidence; without a gfx agent the
        // device is present-unusable with the reason named.
        let (usable, lanes, reason) = amd_gpu_disposition(false, true, true);
        assert!(!usable);
        assert_eq!(lanes, vec!["host-native"]);
        assert_eq!(reason.as_deref(), Some("rocm-runtime-missing"));

        let (usable, _, reason) = amd_gpu_disposition(true, false, true);
        assert!(!usable);
        assert_eq!(reason.as_deref(), Some("kfd-missing"));

        let (usable, lanes, reason) = amd_gpu_disposition(true, true, false);
        assert!(!usable);
        assert!(lanes.is_empty(), "no render node = no lane to reach it on");
        assert_eq!(reason.as_deref(), Some("render-node-missing"));

        // ORDER 793-zumy: THIS ASSERTION CHANGED, AND IT WAS PINNING THE DEFECT.
        //
        // It previously required lanes == ["container", "host-native"] and
        // reason == None for a host with rocm + kfd + a render node. All three
        // of those inputs are read FROM THE HOST, and yoga measured 2026-08-30
        // that a host satisfying all three had, inside the container that
        // actually runs inference: no /dev/kfd, no /dev/dri, size_vram=0.00GB
        // for every model, and a runtime reporting library=cpu. After the
        // device nodes WERE passed in, size_vram was still 0.00GB because the
        // image ships no ROCm backend.
        //
        // So the old expectation encoded exactly the substitution this packet
        // exists to end — host evidence standing in for a container-lane claim
        // — and a test asserting it made the defect look verified. Updating it
        // is the point, not collateral: the probe now reports the lane it can
        // prove and NAMES the one it cannot.
        let (usable, lanes, reason) = amd_gpu_disposition(true, true, true);
        assert!(usable, "the DEVICE is usable — that part was never wrong");
        assert_eq!(
            lanes,
            vec!["host-native"],
            "a host-vantage probe cannot claim the container lane"
        );
        assert_eq!(
            reason.as_deref(),
            Some("container-lane-unverified"),
            "and it must SAY the lane is unverified rather than silently omit it"
        );
    }

    #[test]
    // @trace order:855-wrr3, spec:accel-capability-probe
    fn test_intel_gpu_disposition_fails_closed_without_a_compute_runtime() {
        // A render node is a DISPLAY driver, not a compute lane. Without an
        // Intel compute runtime the device is present-unusable, reason named.
        let (usable, lanes, reason) = intel_gpu_disposition(false, true);
        assert!(!usable);
        assert_eq!(lanes, vec!["host-native"]);
        assert_eq!(reason.as_deref(), Some("intel-compute-runtime-missing"));

        let (usable, lanes, reason) = intel_gpu_disposition(true, false);
        assert!(!usable);
        assert!(lanes.is_empty(), "no render node = no lane to reach it on");
        assert_eq!(reason.as_deref(), Some("render-node-missing"));

        let (usable, lanes, reason) = intel_gpu_disposition(true, true);
        assert!(usable);
        assert_eq!(lanes, vec!["container", "host-native"]);
        assert_eq!(reason, None);
    }

    #[test]
    // @trace order:852-dk9z, spec:accel-capability-probe
    fn test_cache_from_different_probe_code_is_reprobed_not_served() {
        let _seam = podman_seam();
        // The 852-dk9z regression, measured twice for real: a rebuilt binary
        // served its predecessor's document because schema_version and
        // legacy_tier both still matched. Stamp a cache with a FOREIGN probe
        // identity and it must be re-probed.
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = dir.path().join("capabilities.json");

        let mut stale = run_probe("cpu");
        stale.probe_identity = Some("0.0.0+deadbeefdeadbeef".to_string());
        stale.legacy_tier = "cpu".to_string();
        // A marker the real probe can never produce, so "served from cache" is
        // distinguishable from "re-probed and happened to look the same".
        stale.host.host_id = "STALE-CACHE-MARKER".to_string();
        fs::write(&cache, serde_json::to_string_pretty(&stale).unwrap()).unwrap();

        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);
        assert_ne!(
            got.host.host_id, "STALE-CACHE-MARKER",
            "a document from different probe code must never be served"
        );
        assert_eq!(
            got.probe_identity.as_deref(),
            Some(probe_identity().as_str())
        );

        // And a pre-852-dk9z cache (no identity at all) is likewise refused.
        let mut legacy = run_probe("cpu");
        legacy.probe_identity = None;
        legacy.host.host_id = "LEGACY-CACHE-MARKER".to_string();
        fs::write(&cache, serde_json::to_string_pretty(&legacy).unwrap()).unwrap();
        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);
        assert_ne!(got.host.host_id, "LEGACY-CACHE-MARKER");
    }

    #[test]
    // @trace order:852-dk9z, spec:accel-capability-probe
    fn test_negative_control_unchanged_binary_still_serves_its_own_cache() {
        let _seam = podman_seam();
        // The cache must keep working for the server's hot path — this fix is
        // an invalidation rule, not a removal.
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = dir.path().join("capabilities.json");

        let mut mine = run_probe("cpu");
        mine.host.host_id = "MY-OWN-CACHE".to_string();
        assert_eq!(
            mine.probe_identity.as_deref(),
            Some(probe_identity().as_str())
        );
        fs::write(&cache, serde_json::to_string_pretty(&mine).unwrap()).unwrap();

        let got = load_or_probe_at(&cache, "cpu", Freshness::Cached);
        assert_eq!(
            got.host.host_id, "MY-OWN-CACHE",
            "same probe identity must still hit the cache"
        );

        // ...and Freshness::Force ignores it, which is what publication uses.
        let got = load_or_probe_at(&cache, "cpu", Freshness::Force);
        assert_ne!(got.host.host_id, "MY-OWN-CACHE");
    }

    #[test]
    // @trace order:855-wrr3, spec:accel-capability-probe
    fn test_intel_igpu_with_only_a_render_node_is_not_a_workstation_gpu() {
        // The live regression from order 855-wrr3: host pirria, a 4-core
        // Alder Lake-N N150 that is the fleet's declared LOWER BOUND, published
        // accel_class=workstation-gpu because /dev/dri/renderD128 exists — while
        // the same binary's --inference-tier answered `tier:cpu` and the engine
        // reported initial_count=0 devices, total_vram=0 B.
        let mut d = device(
            "gpu",
            "Alder Lake-N [Intel Graphics]",
            &["host-native"],
            Some("intel-compute-runtime-missing"),
        );
        d.usable = false;
        let env = accel_envelope(&doc_with(vec![d]));
        assert!(env.contains("accel_class=cpu-only"), "{env}");
        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(
            env.contains("accel_reason=intel-compute-runtime-missing"),
            "{env}"
        );
    }

    #[test]
    // @trace order:850-bif2, spec:accel-capability-probe
    // EXIT CRITERION 4 (negative control): a host with no accelerator still
    // produces a VALID document — a CPU device and a named host — rather
    // than an empty or absent one. Silence and "nothing here" must stay
    // distinguishable; this runs on every host that gates a push.
    fn test_cpu_only_probe_yields_a_valid_document_not_silence() {
        let _seam = podman_seam();
        let doc = run_probe("cpu");
        assert_eq!(doc.schema_version, SCHEMA_VERSION);
        assert!(
            doc.devices.iter().any(|d| d.device_class == "cpu"),
            "even an accelerator-less host records its CPU"
        );
        assert!(
            !doc.host.host_id.is_empty() && doc.host.host_id != "unknown",
            "a row without a host_id folds to nothing in the matrix"
        );
        let json = serde_json::to_string(&doc).expect("document serializes");
        assert!(json.contains(&format!("\"schema_version\":{SCHEMA_VERSION}")));
        // Order 793-qr4t: the side is part of what makes the document valid
        // rather than merely well-formed. A row that cannot say where it was
        // probed cannot have its `none`s read, which is the whole finding.
        assert!(
            doc.host.side.is_some(),
            "a document must state which side produced it"
        );
    }

    // ================================================================
    // Order 793-qr4t — the envelope is side- and engine-qualified.
    // ================================================================

    fn field<'a>(env: &'a str, key: &str) -> &'a str {
        env.split(' ')
            .find_map(|f| f.strip_prefix(&format!("{key}=")))
            .unwrap_or_else(|| panic!("envelope has no {key}: {env}"))
    }

    fn doc_on_side(side: &str, devices: Vec<DeviceRecord>) -> CapabilityDocument {
        let mut d = doc_with(devices);
        d.host.side = Some(side.to_string());
        d
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// EXIT CRITERION 1, both halves in one test because the criterion is the
    /// DISTINCTION and either half alone is satisfiable by a blanket relabel.
    ///
    /// The guest case is measured: an XDNA2 NPU healthy on the Windows side
    /// (VEN_1022&DEV_17F0, driver 32.0.20102.3930) reported `accel_npu=none`
    /// in the WSL2 guest, because `enumerate_npus` reads `/sys/class/accel`
    /// and a WSL2 kernel has no accel class. `none` reads as "this machine
    /// cannot do NPU work", which is false and mis-plans a whole tier.
    fn an_accelerator_across_a_boundary_is_unobservable_never_none() {
        let guest = doc_on_side(
            "wsl2-guest",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(
            field(&accel_envelope(&guest), "accel_npu"),
            "unobservable-from-this-side",
            "a guest's enumeration is evidence about the guest, not the machine"
        );

        let native = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(
            field(&accel_envelope(&native), "accel_npu"),
            "none",
            "a native host that looked and found nothing keeps its affirmative denial"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The THIRD absent-state, kept distinct from the other two.
    ///
    /// tlatoanis-macbook-air's correction, and it is the reason this is not a
    /// two-value field: the Apple Neural Engine is present, CoreML-drivable and
    /// on the SAME side as the probe. `unobservable-from-this-side` would be as
    /// false there as `none` is. It is `unknown` — recorded as an enumeration
    /// gap — because the probe has no arm for that platform.
    fn a_same_side_device_the_probe_cannot_look_for_is_unknown_not_unobservable() {
        let mut mac = doc_on_side(
            "macos-host",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        mac.enumeration_gaps.push("npu".to_string());
        let env = accel_envelope(&mac);
        assert_eq!(field(&env, "accel_npu"), "unknown", "{env}");
        assert_eq!(
            field(&env, "accel_reason"),
            "npu-not-enumerable-on-this-platform",
            "cpu-only is never a bare verdict: {env}"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// EXIT CRITERION 2. "No GPU here", "a GPU with no driver stack", and "a
    /// GPU that belongs to the other side" are three different engineering
    /// problems — buy hardware, ship a lane, cross a boundary — and the
    /// envelope collapsed all three into one token.
    fn no_gpu_a_driverless_gpu_and_a_far_side_gpu_are_three_answers() {
        let none = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        let env = accel_envelope(&none);
        assert_eq!(field(&env, "accel_gpu"), "none");
        assert_eq!(field(&env, "accel_gpu_engine"), "none", "{env}");

        // A real, container-deliverable GPU that nothing can drive. This is
        // macuahuitl's row: a usable RTX A5000 with `engines: []`, which the
        // matrix rendered as `schedulable: none` while ollama was serving
        // models on that very machine.
        let driverless = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "NVIDIA RTX A5000", &["container"], None),
            ],
        );
        let env = accel_envelope(&driverless);
        assert_eq!(field(&env, "accel_gpu"), "usable");
        assert_eq!(
            field(&env, "accel_gpu_engine"),
            "engine-missing",
            "a present device nothing can drive must say so: {env}"
        );

        let far = doc_on_side(
            "container",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(
            field(&accel_envelope(&far), "accel_gpu"),
            "unobservable-from-this-side"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The engine is named when we recognise it and slugged when we do not.
    ///
    /// An unrecognised engine forced into the nearest known bucket would be
    /// the confident half-answer this packet exists to remove — and `ollama`,
    /// the engine on the host that implemented this, is exactly such a case.
    fn a_recognised_engine_is_named_and_an_unrecognised_one_keeps_its_own_slug() {
        let mut d = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon", &["container"], None),
            ],
        );
        d.engines.push(EngineRecord {
            name: "llama.cpp".to_string(),
            backend: "rocm".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: None,
        });
        assert_eq!(field(&accel_envelope(&d), "accel_gpu_engine"), "rocm");

        d.engines[0] = EngineRecord {
            name: "ollama".to_string(),
            backend: "container".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        };
        assert_eq!(field(&accel_envelope(&d), "accel_gpu_engine"), "ollama");
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// EXIT CRITERION 3. The envelope emits exactly ONE memory number, so a
    /// 522 sizing consumer has nothing to add to it.
    ///
    /// Measured on windows/Yolanda: `accel_ram_gb=7` (the guest's slice) beside
    /// a dzn-advertised 7.58 GiB DEVICE_LOCAL heap — the same physical DRAM
    /// counted twice, and neither of them the machine's installed 15.2 GB.
    fn a_unified_node_publishes_one_budget_and_declares_itself_unified() {
        // Apple silicon: unified BY CONSTRUCTION, with no discrete alternative
        // to confuse it with, and no sysfs for the evidence ladder to read — so
        // it is the one architectural assertion the renderer still makes.
        let mut mac = doc_on_side(
            "macos-host",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Apple Metal GPU", &["container"], None),
            ],
        );
        mac.devices[1].vendor = "apple".to_string();
        let env = accel_envelope(&mac);
        assert_eq!(field(&env, "accel_mem_model"), "unified", "{env}");
        assert_eq!(
            env.split(' ')
                .filter(|f| f.starts_with("accel_mem_budget_gb=") || f.starts_with("accel_ram_gb="))
                .count(),
            2,
            "exactly one budget, rendered under both the old and the new key: {env}"
        );

        let mut nv = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "RTX 3070", &["container"], None),
            ],
        );
        nv.devices[1].vendor = "nvidia".to_string();
        nv.devices[1].memory_model = Some("discrete".to_string());
        assert_eq!(field(&accel_envelope(&nv), "accel_mem_model"), "discrete");

        // An AMD/Intel DRM device is genuinely undecidable from what
        // DeviceRecord records — no VRAM size, no integrated flag — and
        // `unknown` is the answer that keeps a consumer from summing.
        // Order 964-r98h moved this from a VENDOR question to an EVIDENCE
        // question. An AMD device whose record carries no classification is
        // `undetermined` — the classifier ran and refused — which is a
        // different fact from `unobservable-from-this-side` (it could not run)
        // and from `no-gpu` (there was nothing to classify).
        let mut amd = nv.clone();
        amd.devices[1].vendor = "amd".to_string();
        amd.devices[1].memory_model = None;
        assert_eq!(
            field(&accel_envelope(&amd), "accel_mem_model"),
            "undetermined"
        );
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The side is read from the DOCUMENT, so a transported row keeps its own
    /// facts — the same property `enumeration_gaps` already has, and the
    /// reason the fleet matrix can fold rows probed elsewhere at all.
    fn a_pre_schema3_document_reads_unknown_side_never_a_default() {
        let mut old = doc_with(vec![device("cpu", "cpu", &["container"], None)]);
        old.host.side = None;
        assert_eq!(accel_side(&old), "unknown-side");
        // And it must NOT thereby become a boundary side: a document that does
        // not say where it stood cannot have its absences upgraded.
        assert_eq!(field(&accel_envelope(&old), "accel_npu"), "none");
    }

    #[test]
    // @trace order:793-qr4t, spec:accel-capability-probe
    /// The WSL2 test wants BOTH signals. `/dev/dxg` alone is the node the GPU
    /// arm reads, so reusing it would make the SIDE depend on whether a GPU
    /// happened to be paravirtualised; a `microsoft` kernel release alone is
    /// the string two WSL2 guests already share verbatim and survives into any
    /// image built from that kernel.
    fn side_evidence_needs_both_signals_and_container_wins_the_innermost() {
        assert_eq!(
            side_from_evidence(false, true, "6.18.33.2-microsoft-standard-WSL2"),
            "wsl2-guest"
        );
        assert_eq!(
            side_from_evidence(false, true, "6.16.4-200.fc44.x86_64"),
            "native-linux"
        );
        assert_eq!(
            side_from_evidence(false, false, "6.18.33.2-microsoft-standard-WSL2"),
            "native-linux"
        );
        // A forge inside a container on a WSL2 guest is both, and the answer a
        // consumer needs is the INNERMOST boundary — that is the one whose far
        // side holds the devices it cannot reach.
        assert_eq!(
            side_from_evidence(true, true, "6.18.33.2-microsoft-standard-WSL2"),
            "container"
        );
    }

    // ================================================================
    // Order 793-qc6q — per-phase routing from measured crossovers.
    // ================================================================

    fn decode_row(device: &str, params_b: f64, tps: f64) -> MeasurementRecord {
        MeasurementRecord {
            device: device.to_string(),
            engine: "ollama".to_string(),
            prefill_tps: None,
            decode_tps: Some(tps),
            joules_per_token: None,
            degraded: false,
            degraded_reason: None,
            workload_suite: Some("802-2536-v1".to_string()),
            locus: Some("in-guest".to_string()),
            model: Some(format!("qwen2.5:{params_b}b")),
            model_params_b: Some(params_b),
        }
    }

    /// A host whose GPU is both container-deliverable and driveable.
    fn schedulable_gpu_doc() -> CapabilityDocument {
        let mut d = doc_on_side(
            "wsl2-guest",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon 860M", &["container"], None),
            ],
        );
        d.engines.push(EngineRecord {
            name: "ollama".to_string(),
            backend: "vulkan-dozen".to_string(),
            supported_device_classes: vec!["gpu".to_string()],
            lanes: Some(vec!["container".to_string()]),
        });
        d
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// EXIT CRITERION 1. The measured numbers are windows/Yolanda's, medians
    /// of 3 unique-prompt reps on ollama 0.32.9: decode 0.5B is CPU 78.68 vs
    /// GPU 63.75 t/s (the CPU wins by 1.23x) and decode 3B is CPU 19.64 vs GPU
    /// 26.96 (the GPU wins by 1.37x). Routing 0.5B decode to the iGPU is a
    /// silent 1.23x REGRESSION on exactly the model class the semantic-layer
    /// floor work depends on.
    fn a_small_models_decode_is_not_sent_to_the_igpu() {
        let mut d = schedulable_gpu_doc();
        d.measurements = vec![
            decode_row("cpu", 0.5, 78.68),
            decode_row("gpu", 0.5, 63.75),
            decode_row("cpu", 3.0, 19.64),
            decode_row("gpu", 3.0, 26.96),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::AtOrAbove(3.0));

        let small = route_phase(&d, Phase::Decode, Some(0.5));
        assert_eq!(small.device, "cpu", "{}", small.reason);
        let large = route_phase(&d, Phase::Decode, Some(3.0));
        assert_eq!(large.device, "gpu", "{}", large.reason);

        // Prefill is compute-bound and goes to the accelerator at BOTH sizes —
        // which is the point of routing per phase rather than per host: the
        // same host and the same 0.5B model want different devices for the two
        // phases.
        assert_eq!(route_phase(&d, Phase::Prefill, Some(0.5)).device, "gpu");
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// EXIT CRITERION 4: the threshold is DERIVED, so it moves when the
    /// measurements move. A hard-coded 1.5 would pass the test above and fail
    /// this one — that is the whole reason this test exists beside it.
    fn the_crossover_follows_the_measurements_and_is_never_a_constant() {
        let mut d = schedulable_gpu_doc();
        // A machine whose GPU wins decode from 1B upward.
        d.measurements = vec![
            decode_row("cpu", 0.5, 80.0),
            decode_row("gpu", 0.5, 60.0),
            decode_row("cpu", 1.0, 40.0),
            decode_row("gpu", 1.0, 55.0),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::AtOrAbove(1.0));
        assert_eq!(route_phase(&d, Phase::Decode, Some(1.0)).device, "gpu");

        // A machine where the CPU wins at every size measured. Distinct from
        // never having looked, and it must not become a licence to guess.
        d.measurements = vec![
            decode_row("cpu", 0.5, 80.0),
            decode_row("gpu", 0.5, 60.0),
            decode_row("cpu", 3.0, 20.0),
            decode_row("gpu", 3.0, 15.0),
        ];
        assert_eq!(decode_crossover_b(&d), DecodeCrossover::CpuWinsThroughout);
        assert_eq!(route_phase(&d, Phase::Decode, Some(70.0)).device, "cpu");

        // An unmeasured host: the GPU is usable and decode still goes to the
        // CPU, because the only threshold available would be a constant.
        let unmeasured = schedulable_gpu_doc();
        assert_eq!(decode_crossover_b(&unmeasured), DecodeCrossover::Unmeasured);
        let p = route_phase(&unmeasured, Phase::Decode, Some(3.0));
        assert_eq!(p.device, "cpu");
        assert_eq!(p.reason, "decode-crossover-unmeasured-on-this-host");

        // A degraded run is evidence the run went wrong, not evidence about
        // the device; folding it in would move a threshold on a failure.
        let mut degraded = schedulable_gpu_doc();
        degraded.measurements = vec![decode_row("cpu", 3.0, 19.64), {
            let mut m = decode_row("gpu", 3.0, 26.96);
            m.degraded = true;
            m.degraded_reason = Some("cold-load-stall".to_string());
            m
        }];
        assert_eq!(decode_crossover_b(&degraded), DecodeCrossover::Unmeasured);
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// EXIT CRITERION 2 (620-ca7g preserved). There is no input that yields a
    /// device this host cannot run on. The doc below has no accelerator, no
    /// engine and no measurement — the worst case — and every phase still
    /// lands somewhere runnable.
    fn the_cpu_is_the_floor_for_every_phase_and_no_accelerator_is_ever_required() {
        let bare = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        for phase in [Phase::Prefill, Phase::Decode, Phase::Embed, Phase::Rerank] {
            let p = route_phase(&bare, phase, Some(70.0));
            assert_eq!(p.device, "cpu", "{phase:?} must fall to the floor");
            assert!(
                !p.reason.is_empty() && p.reason != "-",
                "EXIT CRITERION 3: a fallback is never silent, {phase:?} said {:?}",
                p.reason
            );
        }
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// A device with a container lane and NO engine is not a routing target.
    ///
    /// This is 793-qr4t's engine-qualification being consumed rather than
    /// merely published. Routing that read only the lane would send work to
    /// macuahuitl's RTX A5000 and land on the same `library=cpu` silence that
    /// cost windows/Yolanda a day.
    fn a_lane_without_an_engine_is_not_a_routing_target() {
        let mut d = schedulable_gpu_doc();
        d.engines.clear();
        d.measurements = vec![decode_row("cpu", 3.0, 19.64), decode_row("gpu", 3.0, 26.96)];
        let p = route_phase(&d, Phase::Decode, Some(3.0));
        assert_eq!(p.device, "cpu", "{}", p.reason);
        assert_eq!(p.reason, "no-usable-gpu-for-decode");
        assert_eq!(route_phase(&d, Phase::Prefill, None).device, "cpu");
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// Embed NEVER goes to the GPU, and the guard is unconditional rather than
    /// conditioned on `accel_mem_model` reaching `unified` — which it does not
    /// on any AMD or Intel DRM host, i.e. on exactly the host the measurement
    /// (CPU 8.7ms vs GPU 10.2ms) came from.
    fn embed_never_reaches_the_gpu_even_on_a_host_whose_memory_model_is_unknown() {
        let mut d = schedulable_gpu_doc();
        d.measurements = vec![decode_row("cpu", 0.5, 60.0), decode_row("gpu", 0.5, 90.0)];
        // Not `unified` — this WSL2 row cannot reach the evidence at all — and
        // the embed guard must hold anyway. That is the point of it being
        // unconditional rather than keyed on the memory model.
        assert_eq!(
            field(&accel_envelope(&d), "accel_mem_model"),
            "unobservable-from-this-side"
        );
        let p = route_phase(&d, Phase::Embed, Some(0.5));
        assert_eq!(p.device, "cpu", "{}", p.reason);
    }

    #[test]
    // @trace order:793-qc6q, spec:accel-capability-probe
    /// The envelope's routing keys state the POLICY and publish the threshold
    /// beside it, because the renderer does not know a model size.
    fn the_envelope_states_the_policy_and_publishes_the_threshold() {
        let unmeasured = schedulable_gpu_doc();
        let env = accel_envelope(&unmeasured);
        assert_eq!(field(&env, "accel_prefill_dev"), "gpu", "{env}");
        assert_eq!(field(&env, "accel_decode_dev"), "cpu", "{env}");
        assert_eq!(
            field(&env, "accel_decode_crossover_b"),
            "unmeasured",
            "{env}"
        );

        let mut measured = schedulable_gpu_doc();
        measured.measurements = vec![decode_row("cpu", 3.0, 19.64), decode_row("gpu", 3.0, 26.96)];
        let env = accel_envelope(&measured);
        assert_eq!(field(&env, "accel_decode_dev"), "gpu", "{env}");
        assert_eq!(field(&env, "accel_decode_crossover_b"), "3", "{env}");
        assert_eq!(field(&env, "accel_gpu_path"), "dxg-d3d12", "{env}");
        assert_eq!(field(&env, "accel_side"), "wsl2-guest", "{env}");
    }

    // ================================================================
    // Order 964-r98h — a device says whether its memory is its own.
    // ================================================================

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// THE TWO DEVICES IN THIS MACHINE, AS SYSFS ACTUALLY REPORTS THEM, and
    /// they falsify the rule 964-r98h's own context proposed ("mem_info_vram_
    /// total is absent or zero for an integrated part"). It is backwards here:
    /// the DISCRETE card has no such file and the INTEGRATED one has 2 GiB,
    /// because the file belongs to `amdgpu` rather than to dedicated memory and
    /// an APU's BIOS carves a UMA region that amdgpu reports as VRAM.
    ///
    /// A classifier built on that rule would have mislabelled both devices on
    /// this host, in opposite directions, and passed review. This test is the
    /// pin that keeps it from being reintroduced.
    fn the_two_gpus_in_this_machine_classify_from_real_sysfs_values() {
        // card0: NVIDIA RTX 3070. No amdgpu VRAM files at all; an 8192 MiB
        // prefetchable BAR (resizable BAR enabled).
        let rtx3070 = GpuMemoryEvidence {
            vram_total: None,
            vis_vram_total: None,
            largest_prefetchable_bar: Some(8192 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&rtx3070), Some("discrete"));

        // card1: AMD Cezanne Vega iGPU. 2 GiB "VRAM", ALL of it CPU-visible,
        // largest prefetchable BAR 256 MiB.
        let vega = GpuMemoryEvidence {
            vram_total: Some(2 * 1024 * 1024 * 1024),
            vis_vram_total: Some(2 * 1024 * 1024 * 1024),
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&vega), Some("unified"));
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// The rung that catches a discrete card whose whole VRAM is NOT
    /// CPU-visible — the pre-resizable-BAR configuration, where a 256 MiB
    /// window looks onto 8 GiB. Rung 2 cannot see it (the BAR is small) and
    /// rung 3 would call it unified, so rung 1 has to run first.
    fn a_partially_visible_vram_is_discrete_even_behind_a_small_aperture() {
        let non_rebar_dgpu = GpuMemoryEvidence {
            vram_total: Some(8 * 1024 * 1024 * 1024),
            vis_vram_total: Some(256 * 1024 * 1024),
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(
            memory_model_from_evidence(&non_rebar_dgpu),
            Some("discrete"),
            "memory behind an aperture is memory the device owns"
        );
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// EXIT CRITERION 2: no evidence, no answer — and specifically NOT a
    /// vendor-derived guess. This is the case a vendor table would answer for
    /// free and would be wrong about for a discrete Radeon.
    fn a_device_with_no_evidence_refuses_rather_than_guessing() {
        assert_eq!(
            memory_model_from_evidence(&GpuMemoryEvidence::default()),
            None
        );
        // A driver that reports no VRAM never reaches the unified rung, even
        // with a small aperture — a small BAR alone is not evidence of sharing.
        let small_bar_only = GpuMemoryEvidence {
            vram_total: None,
            vis_vram_total: None,
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&small_bar_only), None);
        // A zero VRAM total is a driver quirk, not a machine with no memory.
        let zero_vram = GpuMemoryEvidence {
            vram_total: Some(0),
            vis_vram_total: Some(0),
            largest_prefetchable_bar: Some(256 * 1024 * 1024),
        };
        assert_eq!(memory_model_from_evidence(&zero_vram), None);
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// The BAR parser reads this host's real `resource` files. A register
    /// window is not an aperture: the RTX 3070's 16 MiB non-prefetchable BAR0
    /// must not count, or every GPU clears a megabyte-scale floor.
    fn the_bar_parser_ignores_register_windows_and_empty_bars() {
        // Verbatim from /sys/bus/pci/devices/0000:01:00.0/resource (RTX 3070):
        // BAR0 16 MiB non-prefetchable, BAR1 8192 MiB prefetchable.
        let rtx = "0x00000000b3000000 0x00000000b3ffffff 0x0000000000040200\n\
                   0x0000004000000000 0x00000041ffffffff 0x000000000014220c\n\
                   0x0000000000000000 0x0000000000000000 0x0000000000000000\n";
        assert_eq!(largest_prefetchable_bar(rtx), 8192 * 1024 * 1024);

        // An all-empty file is 0, never a panic and never a phantom aperture.
        assert_eq!(
            largest_prefetchable_bar("0x0000000000000000 0x0000000000000000 0x0000000000000000\n"),
            0
        );
        assert_eq!(largest_prefetchable_bar(""), 0);
        // Malformed input yields 0 rather than a misparse: a silent wrong
        // number here would produce a confident wrong classification, which is
        // the one outcome worse than `None`.
        assert_eq!(largest_prefetchable_bar("garbage\nalso garbage\n"), 0);
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// YOLANDA'S CORRECTION, and the reason this is five states rather than
    /// three. Their `accel_proof` rendered one token for both "nobody to ask"
    /// and "asked and found nothing", so a working lane read identically to an
    /// absent one. My first version had the same hole one field over.
    fn the_envelope_distinguishes_no_gpu_from_unreachable_from_undecided() {
        let no_gpu = doc_on_side(
            "native-linux",
            vec![device("cpu", "cpu", &["container"], None)],
        );
        assert_eq!(field(&accel_envelope(&no_gpu), "accel_mem_model"), "no-gpu");

        // A real GPU on a host whose evidence path this side cannot reach. WSL2
        // is the live case: a paravirtual GPU on /dev/dxg exposes no DRM sysfs,
        // so this is permanent until a Windows-side arm supplies the value —
        // a true statement about the boundary, not a gap in the probe.
        let guest = doc_on_side(
            "wsl2-guest",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon 860M", &["container"], None),
            ],
        );
        assert_eq!(
            field(&accel_envelope(&guest), "accel_mem_model"),
            "unobservable-from-this-side"
        );

        // Same GPU, native side: the classifier ran and refused. THIS is the
        // only one of the three that is a defect in the classifier.
        let native = doc_on_side(
            "native-linux",
            vec![
                device("cpu", "cpu", &["container"], None),
                device("gpu", "Radeon 860M", &["container"], None),
            ],
        );
        assert_eq!(
            field(&accel_envelope(&native), "accel_mem_model"),
            "undetermined"
        );
    }

    #[test]
    // @trace order:964-r98h, spec:accel-capability-probe
    /// EXIT CRITERION 3: the budget is still exactly one number, and `unified`
    /// remains the only value that licenses reading it as the whole machine.
    fn a_classified_device_reaches_the_envelope_and_the_budget_stays_singular() {
        for (model, expected) in [("unified", "unified"), ("discrete", "discrete")] {
            let mut d = doc_on_side(
                "native-linux",
                vec![
                    device("cpu", "cpu", &["container"], None),
                    device("gpu", "Radeon Vega", &["container"], None),
                ],
            );
            d.devices[1].memory_model = Some(model.to_string());
            let env = accel_envelope(&d);
            assert_eq!(field(&env, "accel_mem_model"), expected, "{env}");
            assert_eq!(
                env.split(' ')
                    .filter(|f| f.starts_with("accel_mem_budget_gb="))
                    .count(),
                1,
                "exactly one budget, nothing to add it to: {env}"
            );
        }
    }
}
