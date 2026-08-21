//! Refuse to downgrade an enclave's images with an older application binary.
//!
//! @trace spec:default-image
//!
//! THE HAZARD, and it is a development-machine hazard first. A host
//! accumulates tray binaries: the installed one under
//! `%LOCALAPPDATA%\Programs\Tillandsias`, whatever `target/release` last
//! built, and any number of unpacked `release-artifacts/` trees. Launching the
//! wrong one is a two-click mistake — and because image freshness is decided
//! by CONTENT identity (`decide_image_build`, order 702-griq), an older binary
//! carrying older embedded assets does not see a newer image as newer. It sees
//! a source-digest mismatch and rebuilds, silently replacing a newer enclave
//! with an older one. The operator's next launch is then running yesterday's
//! runtime with no indication anything moved backwards.
//!
//! WHY A VERSION COMPARE IS LEGITIMATE HERE, when content identity is the rule
//! everywhere else: `methodology/versioning.yaml` declares this scheme
//! monotonic by construction — Major and Minor never decrease, `YYMMDD`
//! "always increases with time", and Build is "globally monotonic across all
//! machines and branches", incremented "on every local build". Monotonicity is
//! the whole point of the build counter. So "an image is tagged with a version
//! greater than mine" is a sound statement that I am the older artifact, and it
//! is the ONLY question this module answers. It never decides what to build —
//! that stays with `decide_image_build`.
//!
//! The guard is deliberately a REFUSAL, not a silent no-op: continuing without
//! rebuilding would leave the operator running a new enclave under an old
//! binary, which is a different kind of skew and no better.

use std::cmp::Ordering;
use std::fmt;

/// A parsed Tillandsias CalVer: `Major.Minor.YYMMDD.Build`.
///
/// Ordering is component-wise and numeric, which is what makes the
/// monotonicity `methodology/versioning.yaml` declares usable as a decision.
/// String ordering would be wrong the moment Build reaches double digits
/// (`"10" < "9"` lexically), which is exactly when a development machine
/// starts accumulating builds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct AppVersion {
    pub major: u64,
    pub minor: u64,
    pub date: u64,
    pub build: u64,
}

impl fmt::Display for AppVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}.{}.{}.{}",
            self.major, self.minor, self.date, self.build
        )
    }
}

/// Parse `0.4.260817.1`, tolerating a leading `v` and surrounding whitespace.
///
/// Returns `None` for anything that is not exactly four numeric components.
/// A `None` is NEVER treated as "older" or "newer" by the decision below — an
/// unparseable tag is unknown, and acting on unknown is how a guard turns into
/// a new failure mode.
pub fn parse_app_version(raw: &str) -> Option<AppVersion> {
    let trimmed = raw.trim();
    let trimmed = trimmed.strip_prefix('v').unwrap_or(trimmed);
    let mut parts = trimmed.split('.');
    let mut next = || parts.next()?.parse::<u64>().ok();
    let major = next()?;
    let minor = next()?;
    let date = next()?;
    let build = next()?;
    if parts.next().is_some() {
        return None;
    }
    Some(AppVersion {
        major,
        minor,
        date,
        build,
    })
}

/// What the launcher should do about the images it found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DowngradeVerdict {
    /// No image is newer than this binary. Carry on.
    Proceed,
    /// At least one image is newer. Refuse, and name the newest.
    Refuse {
        /// This binary's version.
        app: AppVersion,
        /// The newest version found among the images.
        image: AppVersion,
        /// The tag that carried it, for a message the operator can act on.
        tag: String,
    },
    /// Newer images exist but the operator passed the override.
    ForcedProceed {
        app: AppVersion,
        image: AppVersion,
        tag: String,
    },
}

/// Decide whether this binary may touch the enclave's images.
///
/// `image_tags` are full tags as podman reports them, e.g.
/// `localhost/tillandsias-forge:v0.4.260817.1`. Tags whose version does not
/// parse — `:latest`, `:sha256-…`, anything hand-made — are IGNORED rather
/// than guessed at. `latest` in particular must never participate: it is an
/// alias that moves, so reading it as a version would make the verdict depend
/// on retag order.
pub fn decide_downgrade(
    app_version: &str,
    image_tags: &[String],
    force: bool,
) -> Option<DowngradeVerdict> {
    let app = parse_app_version(app_version)?;

    let newest = image_tags
        .iter()
        .filter_map(|tag| {
            let version_part = tag.rsplit_once(':')?.1;
            parse_app_version(version_part).map(|v| (v, tag.clone()))
        })
        .max_by(|a, b| a.0.cmp(&b.0));

    let Some((image, tag)) = newest else {
        return Some(DowngradeVerdict::Proceed);
    };

    match image.cmp(&app) {
        Ordering::Greater if force => Some(DowngradeVerdict::ForcedProceed { app, image, tag }),
        Ordering::Greater => Some(DowngradeVerdict::Refuse { app, image, tag }),
        _ => Some(DowngradeVerdict::Proceed),
    }
}

/// The operator-facing refusal text.
///
/// Written to be actionable from the message alone: it names both versions,
/// the tag that proves it, what the app would otherwise have done, and the two
/// ways out. The `--force-downgrade` mention is deliberate — hiding the escape
/// hatch does not stop a determined operator, it just makes them use
/// `--force-rebuild` or delete images by hand, which is worse.
pub fn refusal_message(app: &AppVersion, image: &AppVersion, tag: &str) -> String {
    format!(
        "This Tillandsias app is OLDER than the enclave it is pointed at.\n\
         \n  this app : {app}\n  images   : {image}  (from {tag})\n\n\
         Continuing would rebuild the enclave's images from this older app's embedded assets, \
         silently replacing a newer runtime with an older one — image freshness is decided by \
         content identity, so an older app does not recognise a newer image as newer.\n\n\
         Please update the Tillandsias app, or launch the newer build you already have.\n\
         If you really mean to roll the enclave back, re-run with --force-downgrade."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tags(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_with_and_without_the_v_prefix() {
        let expected = AppVersion {
            major: 0,
            minor: 4,
            date: 260817,
            build: 1,
        };
        assert_eq!(parse_app_version("0.4.260817.1"), Some(expected));
        assert_eq!(parse_app_version("v0.4.260817.1"), Some(expected));
        assert_eq!(parse_app_version("  v0.4.260817.1 "), Some(expected));
    }

    #[test]
    fn refuses_to_parse_anything_that_is_not_four_numbers() {
        for bad in [
            "latest",
            "sha256-abc",
            "0.4.260817",
            "0.4.260817.1.2",
            "",
            "0.4.x.1",
        ] {
            assert_eq!(parse_app_version(bad), None, "{bad:?} must not parse");
        }
    }

    /// THE COUNTER IS THE POINT. String ordering breaks at exactly the moment a
    /// development machine starts to matter — the tenth build of the day.
    #[test]
    fn build_counter_compares_numerically_not_lexically() {
        let nine = parse_app_version("0.4.260817.9").unwrap();
        let ten = parse_app_version("0.4.260817.10").unwrap();
        assert!(ten > nine, "build 10 must outrank build 9");
        assert!("0.4.260817.10" < "0.4.260817.9", "string order is the trap");
    }

    #[test]
    fn newer_images_are_refused() {
        let v = decide_downgrade(
            "0.4.260817.1",
            &tags(&["localhost/tillandsias-forge:v0.4.260819.2"]),
            false,
        )
        .unwrap();
        match v {
            DowngradeVerdict::Refuse { image, tag, .. } => {
                assert_eq!(image.build, 2);
                assert!(tag.ends_with("v0.4.260819.2"));
            }
            other => panic!("expected Refuse, got {other:?}"),
        }
    }

    /// CONTROL: equal versions are the normal case and must not be refused, or
    /// every ordinary launch breaks.
    #[test]
    fn equal_versions_proceed() {
        assert_eq!(
            decide_downgrade(
                "0.4.260817.1",
                &tags(&["localhost/tillandsias-forge:v0.4.260817.1"]),
                false
            ),
            Some(DowngradeVerdict::Proceed)
        );
    }

    /// The forward case: a NEWER app over older images is an upgrade, which is
    /// the thing this guard must never obstruct.
    #[test]
    fn newer_app_over_older_images_proceeds() {
        assert_eq!(
            decide_downgrade(
                "0.4.260819.1",
                &tags(&["localhost/tillandsias-forge:v0.4.260817.3"]),
                false
            ),
            Some(DowngradeVerdict::Proceed)
        );
    }

    #[test]
    fn the_override_converts_a_refusal_into_a_forced_proceed() {
        let v = decide_downgrade(
            "0.4.260817.1",
            &tags(&["localhost/tillandsias-forge:v0.4.260819.2"]),
            true,
        )
        .unwrap();
        assert!(matches!(v, DowngradeVerdict::ForcedProceed { .. }));
    }

    /// `latest` and digest tags MOVE. Reading them as versions would make the
    /// verdict depend on retag order, so they must be ignored — and ignoring
    /// them must not accidentally hide a real newer tag alongside.
    #[test]
    fn unparseable_tags_are_ignored_but_do_not_mask_a_real_one() {
        assert_eq!(
            decide_downgrade(
                "0.4.260817.1",
                &tags(&[
                    "localhost/tillandsias-forge:latest",
                    "localhost/tillandsias-git:sha256-deadbeef",
                ]),
                false
            ),
            Some(DowngradeVerdict::Proceed)
        );
        let v = decide_downgrade(
            "0.4.260817.1",
            &tags(&[
                "localhost/tillandsias-forge:latest",
                "localhost/tillandsias-git:v0.4.260820.1",
            ]),
            false,
        )
        .unwrap();
        assert!(matches!(v, DowngradeVerdict::Refuse { .. }));
    }

    /// The MAX across images decides, not the first or last seen — a host mid
    /// upgrade legitimately holds a mix.
    #[test]
    fn the_newest_image_decides_not_the_first_seen() {
        let v = decide_downgrade(
            "0.4.260817.1",
            &tags(&[
                "localhost/tillandsias-git:v0.4.260810.1",
                "localhost/tillandsias-forge:v0.4.260822.7",
                "localhost/tillandsias-proxy:v0.4.260817.1",
            ]),
            false,
        )
        .unwrap();
        match v {
            DowngradeVerdict::Refuse { image, .. } => assert_eq!(image.date, 260822),
            other => panic!("expected Refuse, got {other:?}"),
        }
    }

    /// No images at all is a first run, not a downgrade.
    #[test]
    fn an_empty_enclave_proceeds() {
        assert_eq!(
            decide_downgrade("0.4.260817.1", &[], false),
            Some(DowngradeVerdict::Proceed)
        );
    }

    /// An app version this module cannot parse yields None — the caller must
    /// then carry on rather than refuse. A guard that blocks every launch
    /// because it could not read its own version is worse than no guard.
    #[test]
    fn an_unparseable_app_version_yields_no_verdict() {
        assert_eq!(
            decide_downgrade("dev", &tags(&["x:v9.9.999999.9"]), false),
            None
        );
    }
}
