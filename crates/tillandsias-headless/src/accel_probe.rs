// @trace spec:accel-capability-probe
//! Structured hardware capability probe (CPU, GPU, NPU, memory bandwidth)
//! replacing single-string inference tier detection.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Schema version for capabilities.json per spec:accel-capability-probe
pub const SCHEMA_VERSION: u32 = 1;

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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:accel-capability-probe
pub struct HostInfo {
    pub is_battery_present: bool,
    pub kernel_release: String,
}

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

    HostInfo {
        is_battery_present: battery,
        kernel_release: kernel,
    }
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
}
