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
    let base = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir());
    base.join(".cache")
        .join("tillandsias")
        .join("capabilities.json")
}

// @trace spec:accel-capability-probe
pub fn load_or_probe(effective_tier: &str) -> CapabilityDocument {
    let cache_file = capabilities_cache_path();
    if let Ok(content) = fs::read_to_string(&cache_file)
        && let Ok(doc) = serde_json::from_str::<CapabilityDocument>(&content)
        && doc.schema_version == SCHEMA_VERSION
        && doc.legacy_tier == effective_tier
    {
        return doc;
    }
    let doc = run_probe(effective_tier);
    if let Some(parent) = cache_file.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(&doc) {
        let _ = fs::write(&cache_file, json);
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
pub fn run_probe(effective_tier: &str) -> CapabilityDocument {
    let devices = enumerate_devices(effective_tier);
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
    }
}

// @trace spec:accel-capability-probe
fn enumerate_devices(effective_tier: &str) -> Vec<DeviceRecord> {
    let mut devices = Vec::new();

    // 1. CPU Device
    devices.push(enumerate_cpu());

    // 2. GPUs
    devices.extend(enumerate_gpus(effective_tier));

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

fn enumerate_gpus(effective_tier: &str) -> Vec<DeviceRecord> {
    let mut gpus = Vec::new();

    // Only the Linux arm consults the tier (CDI container-deliverability);
    // the macOS arm is host-native only by spec (PROBE-7).
    #[cfg(not(target_os = "linux"))]
    let _ = effective_tier;

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
            let cdi_ok = effective_tier == "gpu-cuda";
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

        if Path::new("/dev/dri").exists() {
            let mut dri_name = "Vulkan / DRM GPU".to_string();
            if let Ok(entries) = fs::read_dir("/dev/dri") {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.starts_with("renderD") || name.starts_with("card") {
                        dri_name = format!("/dev/dri/{}", name);
                        break;
                    }
                }
            }
            if gpus.is_empty() {
                gpus.push(DeviceRecord {
                    device_class: "gpu".to_string(),
                    vendor: "amd".to_string(), // Or intel/generic drm
                    name: "Vulkan GPU".to_string(),
                    device_node: Some(dri_name),
                    fw_version: None,
                    driver: None,
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
                unusable_reason: Some("wsl2-no-dri-render-node".to_string()),
                // No lane: unreachable from the container AND from host-native
                // code in the guest, because there is no render node to open.
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

// @trace spec:accel-capability-probe
fn enumerate_engines() -> Vec<EngineRecord> {
    vec![EngineRecord {
        name: "ollama".to_string(),
        backend: "llama-server".to_string(),
        supported_device_classes: vec!["cpu".to_string(), "gpu".to_string()],
    }]
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
    use super::*;

    /// Build a document with exactly the devices a case needs.
    fn doc_with(devices: Vec<DeviceRecord>) -> CapabilityDocument {
        CapabilityDocument {
            schema_version: SCHEMA_VERSION,
            legacy_tier: "cpu".to_string(),
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

    #[test]
    // @trace spec:accel-capability-probe
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
            Some("wsl2-no-dri-render-node"),
        );
        gpu.usable = false;

        let env = accel_envelope(&doc_with(vec![
            device("cpu", "CPU", &["container"], None),
            gpu,
        ]));

        assert!(env.contains("accel_gpu=present-unusable"), "{env}");
        assert!(!env.contains("accel_gpu=none"), "{env}");
        assert!(env.contains("wsl2-no-dri-render-node"), "{env}");
        // Capacity is still cpu-only — an unreachable GPU must not inflate the
        // class, or a scheduler would place GPU work on a host that cannot run it.
        assert!(env.contains("accel_class=cpu-only"), "{env}");
    }

    #[test]
    // @trace spec:accel-capability-probe
    fn test_probe_produces_valid_document() {
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
}
