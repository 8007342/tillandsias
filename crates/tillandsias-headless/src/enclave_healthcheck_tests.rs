//! 1919-hlth: the enclave HEALTHCHECKs must run as a NUMERIC user, probe at
//! 30-60 s steady, and get a 2 s startup probe from the launcher.
//! @trace order:1919-hlth

use super::*;

const IMAGES: [(&str, &str, &str); 4] = [
    (
        "vault",
        include_str!("../../../images/vault/Containerfile"),
        VAULT_HEALTH_CMD,
    ),
    (
        "proxy",
        include_str!("../../../images/proxy/Containerfile"),
        PROXY_HEALTH_CMD,
    ),
    (
        "git",
        include_str!("../../../images/git/Containerfile"),
        GIT_HEALTH_CMD,
    ),
    (
        "inference",
        include_str!("../../../images/inference/Containerfile"),
        INFERENCE_HEALTH_CMD,
    ),
];

/// The HEALTHCHECK instruction with its `\` continuations joined.
fn healthcheck_instruction(containerfile: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    for line in containerfile.lines() {
        if line.starts_with("HEALTHCHECK ") {
            inside = true;
        }
        if inside {
            let t = line.trim();
            let (body, more) = match t.strip_suffix('\\') {
                Some(b) => (b.trim(), true),
                None => (t, false),
            };
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(body);
            if !more {
                break;
            }
        }
    }
    assert!(!out.is_empty(), "no HEALTHCHECK instruction found");
    out
}

/// The last USER instruction: the one podman exec and HEALTHCHECK run as.
fn final_user(containerfile: &str) -> String {
    containerfile
        .lines()
        .rev()
        .find_map(|l| l.strip_prefix("USER "))
        .unwrap_or("")
        .trim()
        .to_string()
}

fn seconds(instr: &str, flag: &str) -> u64 {
    let v = instr
        .split_whitespace()
        .find_map(|w| w.strip_prefix(flag))
        .unwrap_or_else(|| panic!("{flag} missing from {instr}"));
    v.trim_end_matches('s').parse().expect("seconds")
}

/// `podman exec` resolves a user NAME through the rootfs as mounted in
/// podman's own namespace; when that mount is gone (measured on macuahuitl,
/// 47 h of rc=125 "unable to find user vault") every probe fails. A numeric
/// uid:gid needs no lookup. Fails on the pre-fix `USER vault`.
#[test]
fn enclave_images_run_as_a_numeric_user() {
    for (name, cf, _) in IMAGES {
        let user = final_user(cf);
        let numeric = user
            .split(':')
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()));
        assert!(
            numeric,
            "{name}: USER must be numeric uid:gid, got {user:?}"
        );
    }
}

/// Operator-approved steady cadence 30-60 s (was 2 s / 5 s).
#[test]
fn enclave_healthchecks_probe_every_30_to_60_seconds() {
    for (name, cf, _) in IMAGES {
        let instr = healthcheck_instruction(cf);
        let interval = seconds(&instr, "--interval=");
        assert!(
            (30..=60).contains(&interval),
            "{name}: HEALTHCHECK interval must be 30-60 s, got {interval}s: {instr}"
        );
    }
}

/// The launcher's startup probe must run the image's own command.
#[test]
fn enclave_health_cmds_match_the_containerfiles() {
    for (name, cf, cmd) in IMAGES {
        let instr = healthcheck_instruction(cf);
        let image_cmd = instr
            .split_once(" CMD ")
            .map(|(_, c)| c.trim())
            .unwrap_or("");
        assert_eq!(
            image_cmd, cmd,
            "{name}: launcher health cmd drifted from the image"
        );
    }
}

#[test]
fn enclave_run_args_carry_a_two_second_startup_probe() {
    let certs = Path::new("/nonexistent-certs");
    let want = |cmd: &str| startup_health_args(cmd).to_vec();
    let has = |args: &[String], cmd: &str| want(cmd).iter().all(|w| args.contains(w));
    let proxy = build_proxy_run_args(certs, "img");
    assert!(has(&proxy, PROXY_HEALTH_CMD), "proxy: {proxy:?}");
    let mirror = build_git_run_args("p", None, certs, "img", None, None, None, None);
    assert!(has(&mirror, GIT_HEALTH_CMD), "mirror: {mirror:?}");
    let inf = build_inference_run_args(certs, "img", true);
    assert!(has(&inf, INFERENCE_HEALTH_CMD), "inference: {inf:?}");
    for args in [&proxy, &mirror, &inf] {
        let img = args.iter().position(|a| a == "img").expect("image");
        let probe = args
            .iter()
            .position(|a| a.starts_with("--health-startup-cmd="))
            .expect("startup probe");
        assert!(
            probe < img,
            "startup probe must precede the image: {args:?}"
        );
    }
    // The vault argv is assembled inline in launch_vault_container (which also
    // runs podman), so no builder exists to call; the call site IS the subject.
    let vault_src = include_str!("vault_bootstrap.rs");
    assert!(
        // source-pin-ok: launch_vault_container builds its argv inline with side effects; no pure builder to call
        vault_src.contains("run_args.extend(crate::startup_health_args(crate::VAULT_HEALTH_CMD));"),
        "vault launch must add the startup probe"
    );
    assert!(want("x").contains(&"--health-startup-interval=2s".to_string()));
}
