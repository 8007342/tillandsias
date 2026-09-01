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
pub const SCHEMA_VERSION: u32 = 2;

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
    let devices = enumerate_devices();
    let engines = enumerate_engines();
    let measurements = Vec::new(); // Microbenchmarks run on demand / bounded
    let host = enumerate_host();
    let timestamp = chrono::Utc::now().to_rfc3339();

    CapabilityDocument {
        schema_version: SCHEMA_VERSION,
        legacy_tier: effective_tier.to_string(),
        devices,
        engines,
        measurements,
        host,
        timestamp,
        probe_identity: Some(probe_identity()),
    }
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
fn enumerate_devices() -> Vec<DeviceRecord> {
    let mut devices = Vec::new();

    // 1. CPU Device
    devices.push(enumerate_cpu());

    // 2. GPUs
    devices.extend(enumerate_gpus());

    // 3. NPUs
    devices.extend(enumerate_npus());

    devices
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
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
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

#[derive(Debug, Clone, PartialEq, Eq)]
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
        let vendor_id = std::fs::read_to_string(dev.join("vendor"))
            .ok()
            .as_deref()
            .and_then(parse_pci_id);
        let device_id = std::fs::read_to_string(dev.join("device"))
            .ok()
            .as_deref()
            .and_then(parse_pci_id);
        // A node whose identity cannot be read is SKIPPED, not defaulted to
        // zero: a record claiming vendor 0x0000 is still a claim, and this
        // packet is about not making claims the evidence does not support.
        let (Some(vendor_id), Some(device_id)) = (vendor_id, device_id) else {
            continue;
        };
        let driver = std::fs::read_link(dev.join("driver"))
            .ok()
            .and_then(|p| p.file_name().and_then(|f| f.to_str()).map(str::to_string))
            .unwrap_or_else(|| "unknown".to_string());
        out.push(DrmRenderNode {
            node: name,
            vendor_id,
            device_id,
            driver,
            // This function reads a filesystem. Whose filesystem is the
            // caller's business; what it can honestly say is "I saw this from
            // where I ran". Production passes /sys/class/drm on the host.
            vantage,
            // A sysfs walk sees hardware. It cannot see a container's device
            // list and it cannot see size_vram, so this is the ONLY rung it is
            // entitled to claim.
            proof: Proof::Enumerated,
        });
    }
    out
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
            });
        }
    }

    gpus
}

// @trace spec:accel-capability-probe
fn enumerate_npus() -> Vec<DeviceRecord> {
    let mut npus = Vec::new();
    let accel_dir = Path::new("/sys/class/accel");

    // PROBE-2: Kernel without accel class (e.g. WSL2) yields empty list and succeeds
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

    HostInfo {
        is_battery_present: battery,
        kernel_release: kernel,
        host_id,
        host_id_source,
        host_kind: host_kind().to_string(),
    }
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
    let (gpu_state, npu_state) = (state(gpu), state(npu));

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
        .unwrap_or("-");

    let cpu = doc.devices.iter().find(|d| d.device_class == "cpu");
    let cores = cpu
        .and_then(|d| d.cpu_cores.as_ref())
        .map(|c| c.logical.to_string())
        .unwrap_or_else(|| "-".to_string());
    let ram = cpu
        .and_then(|d| d.system_ram_gb)
        .map(|g| format!("{g:.0}"))
        .unwrap_or_else(|| "-".to_string());

    format!(
        "accel_class={} accel_gpu={} accel_gpu_name={} accel_npu={} accel_npu_name={} \
         accel_reason={} accel_cpu_cores={} accel_ram_gb={}",
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
    )
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
            devices,
            engines: Vec::new(),
            measurements: Vec::new(),
            host: HostInfo {
                is_battery_present: false,
                kernel_release: "test".to_string(),
                host_id: "test-host".to_string(),
                host_id_source: "input".to_string(),
                host_kind: "linux".to_string(),
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
        }
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
            }],
            host: HostInfo {
                is_battery_present: true,
                kernel_release: "6.18.33.2-microsoft-standard-WSL2".to_string(),
                host_id: host.to_string(),
                host_id_source: "node-name".to_string(),
                host_kind: "linux".to_string(),
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
        assert_eq!(doc.schema_version, 2);
        assert!(
            doc.devices.iter().any(|d| d.device_class == "cpu"),
            "even an accelerator-less host records its CPU"
        );
        assert!(
            !doc.host.host_id.is_empty() && doc.host.host_id != "unknown",
            "a row without a host_id folds to nothing in the matrix"
        );
        let json = serde_json::to_string(&doc).expect("document serializes");
        assert!(json.contains("\"schema_version\":2"));
    }
}
