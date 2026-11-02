//! One GPU queue per host, shared by every image engine (1955-rjv3, moved
//! here by 1956-x7xp so `image.generate` and `studio.run_workflow` take turns
//! on the same device; studio-asset-pipeline design D3).
//!
//! A ticket queue: calls wait in arrival order (never a refusal) and report
//! how many jobs are ahead. The turn is held only while an engine is on the
//! device; dropping it wakes the next ticket.
//! @trace order:1955-rjv3, order:1956-x7xp (spec: openspec/changes/studio-asset-pipeline, not yet archived)
#![cfg_attr(not(test), allow(dead_code))]

use std::sync::{Condvar, Mutex, OnceLock};

struct GpuQueue {
    state: Mutex<(u64, u64)>, // (next ticket, now serving)
    turn: Condvar,
}

fn gpu_queue() -> &'static GpuQueue {
    static Q: OnceLock<GpuQueue> = OnceLock::new();
    Q.get_or_init(|| GpuQueue {
        state: Mutex::new((0, 0)),
        turn: Condvar::new(),
    })
}

/// Holds the device until dropped; dropping wakes the next ticket.
pub struct GpuTurn(());

impl Drop for GpuTurn {
    fn drop(&mut self) {
        let q = gpu_queue();
        let mut st = q.state.lock().unwrap_or_else(|e| e.into_inner());
        st.1 += 1;
        q.turn.notify_all();
    }
}

/// Take a ticket and wait for the device. `queued` is told the number of
/// jobs ahead each time it changes (only while waiting; a free device says
/// nothing).
pub fn wait_for_gpu(queued: &mut dyn FnMut(usize)) -> GpuTurn {
    let q = gpu_queue();
    let mut st = q.state.lock().unwrap_or_else(|e| e.into_inner());
    let ticket = st.0;
    st.0 += 1;
    let mut last = None;
    while st.1 != ticket {
        let ahead = (ticket - st.1) as usize;
        if last != Some(ahead) {
            last = Some(ahead);
            queued(ahead);
        }
        st = q.turn.wait(st).unwrap_or_else(|e| e.into_inner());
    }
    GpuTurn(())
}

/// Who holds GPU memory now (nvidia-smi compute apps), when it can say.
pub fn vram_holders() -> Option<String> {
    let out = std::process::Command::new("nvidia-smi")
        .args([
            "--query-compute-apps=pid,process_name,used_memory",
            "--format=csv,noheader",
        ])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !text.is_empty()).then_some(text)
}

/// 1955-rjv3: turn an engine failure into one that says what happened.
pub fn explain_engine_failure(err: &str, holders: Option<String>) -> String {
    if err.contains("cannot make enough memory available")
        || err.contains("CUDA out of memory")
        || err.contains("OutOfMemoryError")
    {
        let who = holders.map_or_else(
            || "another process (nvidia-smi could not say which; an inference container such as ollama is the usual one)".to_string(),
            |h| format!("these processes (pid, name, memory): {}", h.replace('\n', "; ")),
        );
        return format!(
            "gpu_memory_busy: the GPU does not have enough free memory for this model; it is held by {who}. \
             Stop or unload it, or retry later. Engine said: {}",
            err.lines().last().unwrap_or(err)
        );
    }
    if err.contains("exited 139") || err.contains("signal 11") {
        return format!(
            "{err} (the engine crashed; the usual cause is too little free GPU memory)"
        );
    }
    err.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The engine's VRAM refusal names who holds the device.
    #[test]
    fn a_vram_refusal_names_the_holders() {
        let log = "model manager memory on Vulkan0: reported free 180.38 MB / total 24564.00 MB\n\
                   cannot make enough memory available";
        let e = explain_engine_failure(
            &format!("engine_failed: sd-cli exited 1\n{log}"),
            Some("1234, ollama, 23900 MiB".into()),
        );
        assert!(e.starts_with("gpu_memory_busy:"), "{e}");
        assert!(e.contains("ollama"), "{e}");
        let e = explain_engine_failure("engine_failed: sd-cli exited 139", None);
        assert!(e.starts_with("engine_failed:"), "{e}");
        assert!(e.contains("crashed"), "a segfault says so: {e}");
        // ComfyUI's wording of the same failure.
        let e = explain_engine_failure(
            "engine_failed: torch.OutOfMemoryError: CUDA out of memory",
            None,
        );
        assert!(e.starts_with("gpu_memory_busy:"), "{e}");
    }

    #[test]
    fn tickets_are_served_in_order_and_a_waiter_learns_its_position() {
        let first = wait_for_gpu(&mut |_| {});
        let seen = std::sync::Arc::new(Mutex::new(Vec::new()));
        let s2 = seen.clone();
        let h = std::thread::spawn(move || {
            let _t = wait_for_gpu(&mut |p| s2.lock().unwrap().push(p));
        });
        std::thread::sleep(std::time::Duration::from_millis(30));
        assert_eq!(seen.lock().unwrap().as_slice(), &[1]);
        drop(first);
        h.join().unwrap();
    }
}
