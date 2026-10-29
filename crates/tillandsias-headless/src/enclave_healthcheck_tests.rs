//! 1919-hlth: the enclave HEALTHCHECKs must run as a NUMERIC user, probe at
//! 30-60 s steady. No launcher startup probe: readiness is an event the
//! launcher subscribes to (operator ruling 2026-10-28), not a faster poll.
//! @trace order:1919-hlth

const IMAGES: [(&str, &str); 4] = [
    ("vault", include_str!("../../../images/vault/Containerfile")),
    ("proxy", include_str!("../../../images/proxy/Containerfile")),
    ("git", include_str!("../../../images/git/Containerfile")),
    (
        "inference",
        include_str!("../../../images/inference/Containerfile"),
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
    for (name, cf) in IMAGES {
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
    for (name, cf) in IMAGES {
        let instr = healthcheck_instruction(cf);
        let interval = seconds(&instr, "--interval=");
        assert!(
            (30..=60).contains(&interval),
            "{name}: HEALTHCHECK interval must be 30-60 s, got {interval}s: {instr}"
        );
    }
}
