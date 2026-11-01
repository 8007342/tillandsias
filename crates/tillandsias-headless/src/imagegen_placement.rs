//! Where an sd.cpp run actually put the model (order 1874-b9tg).
//!
//! @trace order:1874-b9tg (spec: openspec/changes/local-image-generation, not yet archived)
//!
//! The 917-zkge lesson: a backend that is installed is not a backend that
//! loads. The verdict is read from two things the engine logs at the pinned
//! tag, and from nothing else:
//!
//! - the ggml device line (`Device 0: … VRAM:` for CUDA, `ggml_vulkan: 0 = …`
//!   for Vulkan), naming the device;
//! - every `model manager prepared params backend buffers (…, VRAM) on <dev>`
//!   line, naming where each weight block went.
//!
//! Never the auto-fit warning: on radv (a uma iGPU) the engine logs
//! `auto-fit: no GPU devices; using the default backend` while the run IS on
//! Vulkan0 with its weights in VRAM (measured on lenovinha 2026-10-27). Never
//! the exit code: a CPU fallback exits 0 too.
#![cfg_attr(not(test), allow(dead_code))]

/// Where the weights went.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Placement {
    /// Every weight block is in VRAM on one GPU device.
    Gpu { backend: String, device: String },
    /// Every weight block is in system RAM on the CPU.
    Cpu,
    /// Some blocks on a GPU, some not, or a GPU backend with no device line.
    Mixed(String),
    /// No placement lines at all: the run never loaded a model.
    Unknown,
}

impl Placement {
    /// The `backend` field of an image.generate result.
    pub fn backend_label(&self) -> &str {
        match self {
            Placement::Gpu { backend, .. } => backend,
            Placement::Cpu => "cpu",
            Placement::Mixed(_) => "mixed",
            Placement::Unknown => "unknown",
        }
    }
}

/// `(memory, device)` from one params-buffer placement line.
fn placement_line(line: &str) -> Option<(&str, &str)> {
    let rest = line.split("prepared params backend buffers (").nth(1)?;
    let (inside, after) = rest.split_once(')')?;
    let memory = inside.rsplit(',').next()?.trim();
    let device = after
        .trim()
        .strip_prefix("on ")?
        .split_whitespace()
        .next()?;
    Some((memory, device))
}

/// The device name from a ggml device line, for the backend it belongs to.
fn device_line(line: &str) -> Option<(&'static str, String)> {
    let t = line.trim();
    if let Some(rest) = t.strip_prefix("ggml_vulkan: 0 = ") {
        let name = rest.split(" | ").next()?.trim();
        return Some(("vulkan", name.to_string()));
    }
    if let Some(rest) = t.strip_prefix("Device 0: ")
        && t.contains("VRAM:")
    {
        return Some(("cuda", rest.split(',').next()?.trim().to_string()));
    }
    None
}

/// The placement verdict for one engine log.
pub fn placement_from_log(log: &str) -> Placement {
    let mut devices: Vec<(&'static str, String)> = Vec::new();
    let mut blocks: Vec<(String, String)> = Vec::new();
    for line in log.lines() {
        if let Some(d) = device_line(line) {
            devices.push(d);
        }
        if let Some((mem, dev)) = placement_line(line) {
            blocks.push((mem.to_string(), dev.to_string()));
        }
    }
    if blocks.is_empty() {
        return Placement::Unknown;
    }
    if blocks.iter().all(|(m, d)| m == "RAM" && d == "CPU") {
        return Placement::Cpu;
    }
    let first = &blocks[0].1;
    let all_vram_one_device = blocks.iter().all(|(m, d)| m == "VRAM" && d == first);
    if !all_vram_one_device {
        let summary = blocks
            .iter()
            .map(|(m, d)| format!("{m}@{d}"))
            .collect::<Vec<_>>()
            .join(",");
        return Placement::Mixed(summary);
    }
    let backend = if first.starts_with("CUDA") {
        "cuda"
    } else if first.starts_with("Vulkan") {
        "vulkan"
    } else {
        return Placement::Mixed(format!("VRAM@{first}"));
    };
    match devices.iter().find(|(b, _)| *b == backend) {
        Some((_, name)) => Placement::Gpu {
            backend: backend.to_string(),
            device: name.clone(),
        },
        None => Placement::Mixed(format!("VRAM@{first} without a {backend} device line")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CPU: &str = include_str!("testdata/imagegen/cpu.log");
    const CUDA: &str = include_str!("testdata/imagegen/cuda.log");
    const VK_NVIDIA: &str = include_str!("testdata/imagegen/vulkan-nvidia.log");
    const VK_RADV: &str = include_str!("testdata/imagegen/vulkan-radv.log");

    #[test]
    fn cuda_run_is_on_the_rtx_3070() {
        assert_eq!(
            placement_from_log(CUDA),
            Placement::Gpu {
                backend: "cuda".into(),
                device: "NVIDIA GeForce RTX 3070 Laptop GPU".into()
            }
        );
    }

    #[test]
    fn vulkan_nvidia_run_is_on_the_rtx_3070() {
        assert_eq!(
            placement_from_log(VK_NVIDIA),
            Placement::Gpu {
                backend: "vulkan".into(),
                device: "NVIDIA GeForce RTX 3070 Laptop GPU (NVIDIA)".into()
            }
        );
    }

    /// The radv log carries `auto-fit: no GPU devices`; the run is on the GPU.
    #[test]
    fn radv_run_is_on_the_igpu_despite_the_auto_fit_warning() {
        assert!(VK_RADV.contains("auto-fit: no GPU devices"));
        assert_eq!(
            placement_from_log(VK_RADV),
            Placement::Gpu {
                backend: "vulkan".into(),
                device: "AMD Radeon Graphics (RADV RENOIR) (radv)".into()
            }
        );
    }

    #[test]
    fn cpu_run_is_cpu() {
        assert_eq!(placement_from_log(CPU), Placement::Cpu);
        assert_eq!(placement_from_log(CPU).backend_label(), "cpu");
    }

    /// Negative controls: one block falling back to RAM, or a VRAM placement
    /// with the device line gone, is never reported as a clean GPU run.
    #[test]
    fn a_partial_fallback_or_a_missing_device_line_is_not_gpu() {
        let partial = VK_NVIDIA.replacen("VRAM) on Vulkan0", "RAM) on CPU", 1);
        assert!(matches!(placement_from_log(&partial), Placement::Mixed(_)));
        let no_device: String = VK_RADV
            .lines()
            .filter(|l| !l.starts_with("ggml_vulkan:"))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(matches!(
            placement_from_log(&no_device),
            Placement::Mixed(_)
        ));
        assert_eq!(placement_from_log("exit 0\n"), Placement::Unknown);
    }
}
