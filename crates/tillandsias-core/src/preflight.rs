//! Host preflight checks for Tillandsias runtime dependencies.
//!
//! Currently the only required check is that `podman-compose` is installed
//! and at least version 1.5.0. The Compose orchestration layer (see the
//! `tillandsias-compose` crate) shells out to `podman-compose` and relies
//! on features and stability that older versions lack — most notably the
//! merge-overlay semantics used by `compose.dev.yaml` and
//! `compose.local.yaml`, and `--format json` on `ps`.
//!
//! @trace spec:enclave-compose-migration

use std::process::Command;

use thiserror::Error;

pub const PODMAN_COMPOSE_MIN: SemverTriple = SemverTriple { major: 1, minor: 5, patch: 0 };

#[derive(Debug, Error)]
pub enum PreflightError {
    #[error(
        "podman-compose not found on PATH.\n\
         Tillandsias requires podman-compose >= {min} to orchestrate the enclave.\n\
         Install on Fedora Silverblue:  rpm-ostree install podman-compose\n\
         Install on Fedora Workstation: sudo dnf install podman-compose"
    )]
    NotInstalled { min: SemverTriple },

    #[error(
        "podman-compose {found} is too old; Tillandsias requires >= {min}.\n\
         Upgrade with `rpm-ostree upgrade` (Silverblue) or `sudo dnf upgrade podman-compose`."
    )]
    TooOld { found: SemverTriple, min: SemverTriple },

    #[error(
        "could not parse podman-compose version from output: {output:?}\n\
         (expected a line containing e.g. 'podman-compose version 1.5.0')"
    )]
    Unparseable { output: String },

    #[error("io invoking podman-compose: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct SemverTriple {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl std::fmt::Display for SemverTriple {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// Check that `podman-compose` is installed and >= [`PODMAN_COMPOSE_MIN`].
///
/// Intended to be called from the tray's startup path, before any
/// `Compose::up` invocation, so the error is presented to the user once
/// (instead of cascading from a deeper failure).
pub fn check_podman_compose() -> Result<SemverTriple, PreflightError> {
    let output = match Command::new("podman-compose").arg("--version").output() {
        Ok(o) => o,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(PreflightError::NotInstalled { min: PODMAN_COMPOSE_MIN });
        }
        Err(e) => return Err(PreflightError::Io(e)),
    };

    let combined = String::from_utf8_lossy(&output.stdout).into_owned()
        + &String::from_utf8_lossy(&output.stderr);

    let found = parse_version(&combined)
        .ok_or_else(|| PreflightError::Unparseable { output: combined.clone() })?;

    if found < PODMAN_COMPOSE_MIN {
        return Err(PreflightError::TooOld { found, min: PODMAN_COMPOSE_MIN });
    }

    tracing::debug!(version = %found, "preflight: podman-compose ok");
    Ok(found)
}

fn parse_version(text: &str) -> Option<SemverTriple> {
    // podman-compose --version emits lines like:
    //   "podman-compose version 1.0.6"
    //   "podman-compose version 1.5.0"
    //   "['podman', '--version', '']"            ← stderr noise from older builds
    //   "using podman version: 4.9.4"            ← we want to skip this line
    //
    // Strategy: walk all whitespace-separated tokens; first one that parses
    // as a SemverTriple and appears AFTER the word "podman-compose" on its
    // line wins. Falls back to the first parseable triple if no anchor
    // found (defensive against future format drifts).
    let mut fallback: Option<SemverTriple> = None;

    for line in text.lines() {
        let anchored = line.contains("podman-compose");
        for tok in line.split_whitespace() {
            let stripped = tok.trim_matches(|c: char| !c.is_ascii_digit() && c != '.');
            if let Some(v) = parse_triple(stripped) {
                if anchored {
                    return Some(v);
                } else if fallback.is_none() {
                    fallback = Some(v);
                }
            }
        }
    }
    fallback
}

fn parse_triple(s: &str) -> Option<SemverTriple> {
    let mut parts = s.split('.');
    let major: u32 = parts.next()?.parse().ok()?;
    let minor: u32 = parts.next()?.parse().ok()?;
    let patch_str = parts.next().unwrap_or("0");
    let patch: u32 = patch_str.parse().ok().unwrap_or(0);
    if parts.next().is_some() {
        return None; // not a 3-or-fewer-part triple
    }
    Some(SemverTriple { major, minor, patch })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_ordering() {
        let v15 = SemverTriple { major: 1, minor: 5, patch: 0 };
        let v14 = SemverTriple { major: 1, minor: 4, patch: 99 };
        let v200 = SemverTriple { major: 2, minor: 0, patch: 0 };
        assert!(v14 < v15);
        assert!(v15 < v200);
        assert!(v15 >= PODMAN_COMPOSE_MIN);
        assert!(v14 < PODMAN_COMPOSE_MIN);
    }

    #[test]
    fn parses_modern_format() {
        let out = "podman-compose version 1.5.0\n";
        let v = parse_version(out).expect("parse");
        assert_eq!(v, SemverTriple { major: 1, minor: 5, patch: 0 });
    }

    #[test]
    fn parses_old_format() {
        let out = "podman-compose version 1.0.6\n";
        let v = parse_version(out).expect("parse");
        assert_eq!(v, SemverTriple { major: 1, minor: 0, patch: 6 });
    }

    #[test]
    fn skips_underlying_podman_line() {
        let out = "podman-compose version 1.5.0\n\
                   using podman version: 4.9.4\n";
        let v = parse_version(out).expect("parse");
        assert_eq!(v, SemverTriple { major: 1, minor: 5, patch: 0 });
    }

    #[test]
    fn parses_two_part_version() {
        // Some builds emit just "1.5" without a patch.
        let out = "podman-compose version 1.5\n";
        let v = parse_version(out).expect("parse");
        assert_eq!(v, SemverTriple { major: 1, minor: 5, patch: 0 });
    }

    #[test]
    fn unparseable_garbage() {
        let out = "this is not a version string\n";
        assert!(parse_version(out).is_none());
    }
}
