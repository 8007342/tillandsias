// @trace order:2284-p6is
//! What an imagegen container does when podman cannot attach the CDI GPU.
//!
//! MEASURED on lenovinha (driver 620.70.06, 2026-11-24): `--device
//! nvidia.com/gpu=all` with any keep-id mapping exits 126 (`crun: mount_setattr
//! ... Operation not permitted`); without the mapping it starts. 2283-u8m6 fixed
//! inference. Three lanes share the flags and need different answers: the studio
//! and the sd.cpp engine can run without the card, CorridorKey cannot.

pub const CDI_GPU: &str = "nvidia.com/gpu=all";

pub fn carries_cdi(argv: &[String]) -> bool {
    argv.iter().any(|a| a == CDI_GPU)
}

/// `argv` without `--device nvidia.com/gpu=all`, with `--device <instead>` in
/// its place when given.
pub fn without_cdi(argv: &[String], instead: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(argv.len());
    let mut i = 0;
    while i < argv.len() {
        if argv[i] == "--device" && argv.get(i + 1).is_some_and(|d| d == CDI_GPU) {
            if let Some(d) = instead {
                out.extend(["--device".to_string(), d.to_string()]);
            }
            i += 2;
        } else {
            out.push(argv[i].clone());
            i += 1;
        }
    }
    out
}

/// podman's own exit codes for a container that never ran: 125 (podman) and 126
/// (the runtime could not start it). An engine that ran and failed is neither,
/// and a render must not be repeated because of it.
#[cfg(any(test, feature = "host-services"))]
pub fn never_started(code: Option<i32>) -> bool {
    matches!(code, Some(125 | 126))
}

/// The sd.cpp engine's second device: the render nodes, as `sandbox_args` picks
/// on a host with no CDI spec; none where there are none (its CPU backend).
#[cfg(feature = "host-services")]
pub fn engine_second_device() -> Option<&'static str> {
    std::path::Path::new("/dev/dri")
        .exists()
        .then_some("/dev/dri")
}

pub fn notice(what: &str, cause: &str, now: &str) {
    eprintln!(
        "[tillandsias] {what} could not start with the GPU ({}); {now}",
        cause.trim()
    );
}

/// A failed retry names both causes.
pub fn both(second: String, first: &str) -> String {
    format!("{second}\n(first attempt, with the GPU: {})", first.trim())
}

/// ComfyUI exits at start with no CUDA device unless it is given `--cpu`
/// (images/imagegen-studio/probe-placement.py, measured on v0.40.0), so the flag
/// goes after the image whenever the argv carries no card.
pub fn studio_argv(mut podman_args: Vec<String>, tag: &str) -> Vec<String> {
    let cpu = !carries_cdi(&podman_args);
    podman_args.push(tag.to_string());
    if cpu {
        podman_args.push("--cpu".to_string());
    }
    podman_args
}

/// One retry without the card, for a lane that can run without it.
pub async fn start_studio<R, F>(with: Vec<String>, tag: &str, mut run: R) -> Result<(), String>
where
    R: FnMut(Vec<String>) -> F,
    F: std::future::Future<Output = Result<String, String>>,
{
    match run(studio_argv(with.clone(), tag)).await {
        Err(err) if carries_cdi(&with) => {
            let cause = crate::launch_failure_cause(&err).to_string();
            notice(
                "the studio",
                &cause,
                "running it on CPU, where images are very slow",
            );
            run(studio_argv(without_cdi(&with, None), tag))
                .await
                .map(|_| ())
                .map_err(|e| both(e, &cause))
        }
        other => other.map(|_| ()),
    }
}

/// CorridorKey has no CPU path: the same start failure, refused by name.
#[cfg(feature = "host-services")]
pub fn corridorkey_refusal(code: Option<i32>, stderr: &str) -> Option<String> {
    // 125 also covers a missing image or a name clash; only the runtime's
    // refusal of the container is called a GPU failure.
    if code != Some(126) {
        return None;
    }
    let cause = stderr.lines().map(str::trim).rfind(|l| !l.is_empty());
    Some(format!(
        "corridorkey_gpu_unavailable: podman could not start the container with the NVIDIA GPU ({}); \
         CorridorKey runs only on the GPU, so it is not retried on CPU",
        cause.unwrap_or("no message")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_cdi_device_is_removed_or_replaced_and_nothing_else_moves() {
        let a = v(&["--userns=keep-id", "--device", CDI_GPU, "--mount", "x"]);
        assert_eq!(
            without_cdi(&a, None),
            v(&["--userns=keep-id", "--mount", "x"])
        );
        assert_eq!(
            without_cdi(&a, Some("/dev/dri")),
            v(&["--userns=keep-id", "--device", "/dev/dri", "--mount", "x"])
        );
        let dri = v(&["--device", "/dev/dri", "img"]);
        assert_eq!(without_cdi(&dri, None), dri);
    }

    async fn drive(
        args: &[&str],
        answers: Vec<Result<String, String>>,
    ) -> (Result<(), String>, Vec<Vec<String>>) {
        let seen = RefCell::new(Vec::new());
        let answers = RefCell::new(answers);
        let r = start_studio(v(args), "img", |a| {
            seen.borrow_mut().push(a);
            let next = answers.borrow_mut().remove(0);
            async move { next }
        })
        .await;
        (r, seen.into_inner())
    }

    #[tokio::test]
    async fn the_studio_retries_once_on_cpu_and_only_when_the_card_was_attached() {
        let gpu = ["--device", CDI_GPU];
        let (r, seen) = drive(
            &gpu,
            vec![Err("stderr: crun: mount_setattr".into()), Ok("id".into())],
        )
        .await;
        assert!(r.is_ok());
        assert_eq!(
            seen,
            vec![v(&["--device", CDI_GPU, "img"]), v(&["img", "--cpu"])]
        );

        let (r, seen) = drive(&gpu, vec![Ok("id".into())]).await;
        assert!(r.is_ok() && seen.len() == 1);

        // No card: unchanged failure, no retry, and --cpu from the start.
        let (r, seen) = drive(&["-d"], vec![Err("boom".into())]).await;
        assert_eq!(r, Err("boom".to_string()));
        assert_eq!(seen, vec![v(&["-d", "img", "--cpu"])]);

        let (r, seen) = drive(
            &gpu,
            vec![Err("stderr: first".into()), Err("second".into())],
        )
        .await;
        let e = r.unwrap_err();
        assert!(
            e.contains("second") && e.contains("first") && seen.len() == 2,
            "{e}"
        );
    }

    #[test]
    fn only_a_container_that_never_ran_is_retried() {
        assert!(never_started(Some(125)) && never_started(Some(126)));
        for ran in [Some(0), Some(1), Some(127), Some(137), Some(139), None] {
            assert!(!never_started(ran), "{ran:?}");
        }
    }

    #[cfg(feature = "host-services")]
    #[test]
    fn corridorkey_names_a_runtime_refusal_and_nothing_else() {
        let e = corridorkey_refusal(Some(126), "x\nError: crun: mount_setattr\n\n").unwrap();
        assert!(
            e.starts_with("corridorkey_gpu_unavailable:") && e.contains("mount_setattr"),
            "{e}"
        );
        assert!(corridorkey_refusal(Some(1), "CUDA out of memory").is_none());
        assert!(corridorkey_refusal(Some(125), "image not known").is_none());
        assert!(corridorkey_refusal(None, "").is_none());
    }
}
