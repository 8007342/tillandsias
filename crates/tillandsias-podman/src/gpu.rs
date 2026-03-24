use std::path::Path;

use tracing::debug;

/// Detect GPU devices available for container passthrough.
/// Returns `--device=` flag values for podman.
pub fn detect_gpu_devices() -> Vec<String> {
    let mut devices = Vec::new();

    // NVIDIA devices
    for dev in &[
        "/dev/nvidia0",
        "/dev/nvidia1",
        "/dev/nvidia2",
        "/dev/nvidia3",
        "/dev/nvidiactl",
        "/dev/nvidia-uvm",
        "/dev/nvidia-uvm-tools",
    ] {
        if Path::new(dev).exists() {
            devices.push(format!("--device={dev}"));
        }
    }

    // AMD ROCm devices
    for dev in &["/dev/kfd", "/dev/dri/renderD128", "/dev/dri/renderD129"] {
        if Path::new(dev).exists() {
            devices.push(format!("--device={dev}"));
        }
    }

    if !devices.is_empty() {
        debug!(?devices, "GPU devices detected");
    }

    devices
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_gpu_returns_vec() {
        // On most CI/dev systems, no GPU devices exist
        let devices = detect_gpu_devices();
        // Just verify it returns a vec (contents depend on hardware)
        assert!(devices.iter().all(|d| d.starts_with("--device=")));
    }
}
