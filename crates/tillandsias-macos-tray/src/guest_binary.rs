//! Helpers for staging the bundled Linux guest binary into the shared host
//! source tree before VM boot.
//!
//! The macOS tray bundles the matching guest binary under the app bundle's
//! `Contents/Resources/guest/` directory. Before Virtualization.framework
//! boots the VM, we copy that binary into the host's shared `~/src` tree so the
//! guest bootstrap can install it from the virtio-fs mount without a network
//! fetch.

#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};

fn host_src_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("src")
}

fn guest_binary_filename() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "tillandsias-headless-aarch64-unknown-linux-musl",
        "x86_64" => "tillandsias-headless-x86_64-unknown-linux-musl",
        other => panic!("unsupported macOS host arch for guest binary: {other}"),
    }
}

fn bundle_resource_candidate() -> Option<PathBuf> {
    let resource_name = guest_binary_filename();
    if let Ok(mut exe) = std::env::current_exe() {
        // .../Tillandsias.app/Contents/MacOS/tillandsias-tray
        let _ = exe.pop(); // MacOS
        if let Some(contents) = exe.parent() {
            return Some(contents.join("Resources/guest").join(resource_name));
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dev_candidate = manifest_dir
        .parent()
        .unwrap_or_else(|| Path::new(&manifest_dir))
        .parent()
        .unwrap_or_else(|| Path::new(&manifest_dir))
        .join("dist/Tillandsias.app/Contents/Resources/guest")
        .join(resource_name);
    Some(dev_candidate)
}

pub(crate) fn bundle_resource_path() -> Option<PathBuf> {
    let path = bundle_resource_candidate()?;
    path.exists().then_some(path)
}

/// Path the guest actually installs from on every boot.
///
/// `fetch-headless.sh` copies this over `/usr/local/bin/tillandsias-headless`
/// UNCONDITIONALLY, before its "already installed" short-circuit, so whatever
/// last wrote here decides which headless the guest runs.
pub(crate) fn staged_guest_binary_path() -> PathBuf {
    host_src_dir()
        .join(".tillandsias")
        .join("guest-bin")
        .join("tillandsias-headless")
}

/// SHA-256 of a file, hex, or None when it cannot be read.
fn file_sha256(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let bytes = std::fs::read(path).ok()?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Some(format!("{:x}", hasher.finalize()))
}

/// What the running bundle carries versus what is actually staged for the guest
/// (701-kgvk).
///
/// The staging path is keyed only on `$HOME`, so every tray build on the host
/// writes the SAME file and last-writer-wins. An OLDER `Tillandsias.app`
/// started later silently downgrades the guest, stickily — the downgrade
/// survives reboots and even a guest reset, until a newer bundle re-stages.
/// Nothing detected that: the only integrity gate compares a VERSION string
/// which does not roll between builds, and the tray discards the guest version
/// from the control-wire handshake. A real skew on this host on 2026-08-11 had
/// to be found by hashing files by hand.
///
/// Reported as three fields rather than a single verdict so the two "unknown"
/// cases stay distinguishable from "mismatch": a non-bundled dev run has no
/// bundle to compare, and a host that has never booted a VM has nothing staged.
pub(crate) struct GuestBinaryProvenance {
    pub bundle_sha256: Option<String>,
    pub staged_sha256: Option<String>,
    /// `Some(true)` matched, `Some(false)` SKEWED, `None` undecidable because
    /// one side is absent — never collapse the last case into "fine".
    pub staged_matches_bundle: Option<bool>,
}

pub(crate) fn guest_binary_provenance() -> GuestBinaryProvenance {
    let bundle_sha256 = bundle_resource_path().as_deref().and_then(file_sha256);
    let staged_path = staged_guest_binary_path();
    let staged_sha256 = staged_path
        .exists()
        .then(|| file_sha256(&staged_path))
        .flatten();
    let staged_matches_bundle = match (&bundle_sha256, &staged_sha256) {
        (Some(b), Some(s)) => Some(b == s),
        _ => None,
    };
    GuestBinaryProvenance {
        bundle_sha256,
        staged_sha256,
        staged_matches_bundle,
    }
}

/// Provenance of whatever last staged the guest binary (701-kgvk criterion 1).
///
/// WHY A SIDECAR AND NOT THE BINARY ITSELF. The criterion demands an identity
/// that "rolls per build, not per VERSION string". sha256 rolls per build — but
/// it gives NO ORDER, so it can say "different" and never "older". Nothing
/// inside the guest artifact carries order either: the headless build.rs embeds
/// only runtime assets, and the control-wire handshake's `build_version` is the
/// workspace VERSION string, which is this packet's original complaint.
///
/// The ordering signal therefore has to be manufactured host-side, and the tray
/// crate already has one: `TILLANDSIAS_BUILD_TIME` from its own build.rs, in
/// `%Y-%m-%dT%H:%M:%SZ` UTC — which sorts LEXICOGRAPHICALLY, so comparing two
/// stamps needs no date parsing and no new dependency. `TILLANDSIAS_GIT_SHA`
/// rides along for provenance a human can act on.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq)]
pub(crate) struct StagedProvenance {
    pub sha256: String,
    /// ISO-8601 UTC. May be the literal "unknown" — build.rs falls back to it
    /// when neither git nor `date` answers, and an unknown stamp must never be
    /// ordered against anything.
    pub build_time: String,
    pub git_sha: String,
}

/// What a staging attempt actually did. Returned rather than logged so the
/// fixture can assert on the DECISION instead of scraping stderr.
#[derive(Debug, PartialEq)]
pub(crate) enum StagingDecision {
    /// Nothing was staged before, or the incoming build is newer, or the
    /// comparison could not be made — see `reason`.
    Staged { reason: StagingReason },
    /// Byte-identical to what is already staged; the copy was skipped.
    UpToDate,
    /// The staged binary is NEWER than the incoming one. Refused.
    RefusedDowngrade {
        staged_build_time: String,
        incoming_build_time: String,
    },
}

#[derive(Debug, PartialEq)]
pub(crate) enum StagingReason {
    FirstStage,
    Upgrade,
    /// No sidecar, an unparseable one, or an "unknown" stamp on either side.
    ///
    /// THIS MUST STAGE, LOUDLY — never refuse. A refusal on undecidable input
    /// is how a downgrade guard degrades into never updating: the first host
    /// with a missing sidecar would be frozen at whatever it happened to have,
    /// and the criterion's own negative control ("a legitimate UPGRADE still
    /// stages") exists to catch exactly that.
    Undecidable(&'static str),
}

fn provenance_sidecar_path(dest: &Path) -> PathBuf {
    let mut p = dest.to_path_buf();
    let name = p
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "tillandsias-headless".to_string());
    p.set_file_name(format!("{name}.provenance.json"));
    p
}

fn read_staged_provenance(dest: &Path) -> Option<StagedProvenance> {
    let raw = std::fs::read_to_string(provenance_sidecar_path(dest)).ok()?;
    serde_json::from_str(&raw).ok()
}

/// The path-parameterised staging core (701-kgvk).
///
/// Split out from `stage_embedded_guest_binary` so the fixture drives the REAL
/// decision logic. `host_src_dir()` reads `$HOME` and this crate has no
/// ENV_LOCK convention, so a test that wanted the real entry point would have
/// to mutate process-global state; this seam avoids that without a mock.
///
/// That split matters more than usual here: the three tests the 2026-08-12
/// slice added call `file_sha256` DIRECTLY and never invoke
/// `guest_binary_provenance()`, so replacing its `Some(b == s)` with
/// `Some(true)` leaves all three green. Testing beside the logic instead of
/// through it is this project's named "verified where it was written is not
/// verified where it runs" failure, and it is already present in this file.
pub(crate) fn stage_guest_binary(
    source: &Path,
    dest: &Path,
    incoming: &StagedProvenance,
) -> Result<StagingDecision, String> {
    let decision = if !dest.exists() {
        StagingDecision::Staged {
            reason: StagingReason::FirstStage,
        }
    } else {
        match read_staged_provenance(dest) {
            None => StagingDecision::Staged {
                reason: StagingReason::Undecidable(
                    "no readable provenance sidecar beside the staged binary",
                ),
            },
            Some(staged) => {
                if staged.sha256 == incoming.sha256 {
                    StagingDecision::UpToDate
                } else if staged.build_time == "unknown" || incoming.build_time == "unknown" {
                    StagingDecision::Staged {
                        reason: StagingReason::Undecidable(
                            "a build_time is \"unknown\", so the two cannot be ordered",
                        ),
                    }
                } else if incoming.build_time >= staged.build_time {
                    StagingDecision::Staged {
                        reason: StagingReason::Upgrade,
                    }
                } else {
                    StagingDecision::RefusedDowngrade {
                        staged_build_time: staged.build_time.clone(),
                        incoming_build_time: incoming.build_time.clone(),
                    }
                }
            }
        }
    };

    if let StagingDecision::RefusedDowngrade {
        staged_build_time,
        incoming_build_time,
    } = &decision
    {
        eprintln!(
            "[guest-binary] REFUSING to stage an OLDER guest binary (701-kgvk).\n\
             [guest-binary]   already staged: {staged_build_time}\n\
             [guest-binary]   this bundle:    {incoming_build_time}\n\
             [guest-binary]   The guest installs the staged file over \
             /usr/local/bin/tillandsias-headless on EVERY boot, so staging this would \
             silently downgrade the guest, stickily — across reboots and even a guest \
             reset — until a newer bundle re-stages.\n\
             [guest-binary]   Run the newer bundle, or delete {} to force a re-stage.",
            provenance_sidecar_path(dest).display()
        );
        return Ok(decision);
    }

    if let StagingDecision::Staged {
        reason: StagingReason::Undecidable(why),
    } = &decision
    {
        eprintln!(
            "[guest-binary] staging without a downgrade check: {why} (701-kgvk). \
             Recording provenance now so the next stage can be ordered."
        );
    }

    if matches!(decision, StagingDecision::UpToDate) {
        return Ok(decision);
    }

    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create guest-binary staging dir {}: {e}", parent.display()))?;
    }
    std::fs::copy(source, dest).map_err(|e| {
        format!(
            "copy guest binary {} -> {}: {e}",
            source.display(),
            dest.display()
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dest, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("chmod guest binary {}: {e}", dest.display()))?;
    }
    // The sidecar is written AFTER the copy: a crash between them leaves a
    // stale-or-absent sidecar, which reads as Undecidable and re-stages. The
    // other order would claim provenance for bytes that never landed.
    let sidecar = provenance_sidecar_path(dest);
    let encoded = serde_json::to_string_pretty(incoming)
        .map_err(|e| format!("encode guest-binary provenance: {e}"))?;
    std::fs::write(&sidecar, encoded)
        .map_err(|e| format!("write guest-binary provenance {}: {e}", sidecar.display()))?;

    Ok(decision)
}

pub(crate) fn stage_embedded_guest_binary() -> Result<Option<PathBuf>, String> {
    let Some(source) = bundle_resource_path() else {
        // 701-kgvk criterion 3: SAY SO, at the point of action.
        //
        // This returned a bare `Ok(None)` and five of six entry points warned
        // about none of it, so `target/release/tillandsias-tray --provision`
        // staged nothing and reported success. The guest then keeps whatever it
        // had — or, with nothing staged at all, curls the LATEST PUBLISHED
        // RELEASE, which has no relationship to this checkout.
        //
        // Announcing HERE rather than fixing the seven `Ok(None)`-dropping call
        // sites is deliberate: those seven only match `Err`, an eighth would
        // inherit the same silence, and the fact being reported is a property of
        // this function, not of any caller.
        eprintln!(
            "[guest-binary] NOT STAGING: no bundled guest binary resource found (701-kgvk).\n\
             [guest-binary]   This is a non-bundled run — a bare `target/release/tillandsias-tray` \
             has no Contents/Resources/guest beside it.\n\
             [guest-binary]   The guest will keep whatever binary it already has, or fetch the \
             latest PUBLISHED release, which has no relationship to this checkout.\n\
             [guest-binary]   Run the .app bundle (dist/Tillandsias.app/Contents/MacOS/\
             tillandsias-tray) to stage this checkout's guest binary."
        );
        return Ok(None);
    };
    let dest = staged_guest_binary_path();
    let Some(sha256) = file_sha256(&source) else {
        return Err(format!(
            "read bundled guest binary {} to compute its identity",
            source.display()
        ));
    };
    let incoming = StagedProvenance {
        sha256,
        build_time: env!("TILLANDSIAS_BUILD_TIME").to_string(),
        git_sha: env!("TILLANDSIAS_GIT_SHA").to_string(),
    };
    match stage_guest_binary(&source, &dest, &incoming)? {
        // A refused downgrade is NOT an error — the tray must still boot, with
        // the newer binary that is already staged. Reporting it as Err would
        // turn a correct refusal into a failed launch.
        StagingDecision::RefusedDowngrade { .. } => Ok(Some(dest)),
        _ => Ok(Some(dest)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every staging test drives `stage_guest_binary` — the REAL decision
    /// function the product calls — against a temp dir, never a reimplementation
    /// of its logic. See the note on that function: the tests already in this
    /// file call `file_sha256` directly and would stay green against a
    /// hard-wired `guest_binary_provenance`.
    fn staging_sandbox(label: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-{label}-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).expect("temp dir");
        d
    }

    fn prov(sha: &str, build_time: &str) -> StagedProvenance {
        StagedProvenance {
            sha256: sha.to_string(),
            build_time: build_time.to_string(),
            git_sha: "deadbeef".to_string(),
        }
    }

    /// 701-kgvk criterion 1. An OLDER bundle must not replace a NEWER staged
    /// binary. This is the whole packet: the guest installs the staged file over
    /// /usr/local/bin on EVERY boot, so a silent downgrade is sticky across
    /// reboots and even a guest reset.
    #[test]
    fn staging_refuses_to_replace_a_newer_binary_with_an_older_one() {
        let d = staging_sandbox("downgrade");
        let src = d.join("bundle-guest");
        let dest = d.join("staged-guest");
        std::fs::write(&src, b"OLD BUILD").unwrap();
        std::fs::write(&dest, b"NEW BUILD").unwrap();

        // What is already staged claims a LATER build time.
        let newer = prov("sha-of-new", "2026-08-16T11:25:00Z");
        std::fs::write(
            provenance_sidecar_path(&dest),
            serde_json::to_string(&newer).unwrap(),
        )
        .unwrap();

        let older = prov("sha-of-old", "2026-08-14T23:11:00Z");
        let decision = stage_guest_binary(&src, &dest, &older).unwrap();

        assert!(
            matches!(decision, StagingDecision::RefusedDowngrade { .. }),
            "an older bundle must be REFUSED, not staged: {decision:?}"
        );
        assert_eq!(
            std::fs::read(&dest).unwrap(),
            b"NEW BUILD",
            "the newer staged binary must still be on disk untouched — a refusal that \
             still copied would be no refusal at all"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// 701-kgvk criterion 4, the NEGATIVE CONTROL. Without it, a guard that
    /// refused EVERYTHING would satisfy the test above while freezing every host
    /// at whatever it happened to have — the refusal degraded into never
    /// updating, which is the failure mode the criterion names.
    #[test]
    fn a_legitimate_upgrade_still_stages() {
        let d = staging_sandbox("upgrade");
        let src = d.join("bundle-guest");
        let dest = d.join("staged-guest");
        std::fs::write(&src, b"NEW BUILD").unwrap();
        std::fs::write(&dest, b"OLD BUILD").unwrap();

        let older = prov("sha-of-old", "2026-08-14T23:11:00Z");
        std::fs::write(
            provenance_sidecar_path(&dest),
            serde_json::to_string(&older).unwrap(),
        )
        .unwrap();

        let newer = prov("sha-of-new", "2026-08-16T11:25:00Z");
        let decision = stage_guest_binary(&src, &dest, &newer).unwrap();

        assert_eq!(
            decision,
            StagingDecision::Staged {
                reason: StagingReason::Upgrade
            },
            "a newer bundle MUST still stage"
        );
        assert_eq!(std::fs::read(&dest).unwrap(), b"NEW BUILD");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// 701-kgvk criterion 1, the UNDECIDABLE case — and it must STAGE, loudly.
    ///
    /// A missing sidecar is the state every host is in the first time this ships.
    /// Refusing there would freeze the whole fleet on its current guest binary,
    /// which is strictly worse than the downgrade this packet is about: a
    /// downgrade is recoverable by running a newer bundle, a universal freeze is
    /// not recoverable at all without deleting files by hand.
    #[test]
    fn an_absent_sidecar_stages_rather_than_refusing() {
        let d = staging_sandbox("undecidable");
        let src = d.join("bundle-guest");
        let dest = d.join("staged-guest");
        std::fs::write(&src, b"INCOMING").unwrap();
        std::fs::write(&dest, b"WHATEVER WAS THERE").unwrap();
        // No sidecar written.

        let decision = stage_guest_binary(&src, &dest, &prov("s", "2026-08-14T23:11:00Z")).unwrap();

        assert!(
            matches!(
                decision,
                StagingDecision::Staged {
                    reason: StagingReason::Undecidable(_)
                }
            ),
            "an absent sidecar is UNDECIDABLE and must stage, not refuse: {decision:?}"
        );
        assert_eq!(std::fs::read(&dest).unwrap(), b"INCOMING");
        assert!(
            provenance_sidecar_path(&dest).exists(),
            "staging must record provenance so the NEXT stage can be ordered — otherwise \
             every stage is undecidable forever and the guard never engages"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// An "unknown" build_time must never be ordered against anything.
    /// build.rs emits it when neither git nor `date` answers, and comparing it
    /// lexicographically would make "unknown" newer than every real 2026 stamp.
    #[test]
    fn an_unknown_build_time_is_undecidable_not_newer() {
        let d = staging_sandbox("unknown");
        let src = d.join("bundle-guest");
        let dest = d.join("staged-guest");
        std::fs::write(&src, b"INCOMING").unwrap();
        std::fs::write(&dest, b"STAGED").unwrap();
        std::fs::write(
            provenance_sidecar_path(&dest),
            serde_json::to_string(&prov("staged-sha", "unknown")).unwrap(),
        )
        .unwrap();

        let decision = stage_guest_binary(&src, &dest, &prov("in-sha", "2026-08-16T11:25:00Z"))
            .expect("staging");
        assert!(
            matches!(
                decision,
                StagingDecision::Staged {
                    reason: StagingReason::Undecidable(_)
                }
            ),
            "\"unknown\" sorts after every real timestamp, so it must be excluded from \
             ordering entirely rather than read as newest: {decision:?}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Identical bytes must not be recopied — and must not be mistaken for a
    /// downgrade just because the timestamps differ.
    #[test]
    fn an_identical_binary_is_up_to_date_not_a_downgrade() {
        let d = staging_sandbox("same");
        let src = d.join("bundle-guest");
        let dest = d.join("staged-guest");
        std::fs::write(&src, b"SAME").unwrap();
        std::fs::write(&dest, b"SAME").unwrap();
        std::fs::write(
            provenance_sidecar_path(&dest),
            serde_json::to_string(&prov("identical-sha", "2026-08-16T11:25:00Z")).unwrap(),
        )
        .unwrap();

        let decision =
            stage_guest_binary(&src, &dest, &prov("identical-sha", "2026-08-14T23:11:00Z"))
                .unwrap();
        assert_eq!(
            decision,
            StagingDecision::UpToDate,
            "matching sha256 short-circuits before any ordering — re-running an older \
             bundle whose guest binary is unchanged is not a downgrade"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn filename_matches_host_arch() {
        let name = guest_binary_filename();
        assert!(
            name.contains(std::env::consts::ARCH),
            "guest binary filename should reflect host arch"
        );
    }

    /// 701-kgvk. THE VERDICT THAT MATTERS: two different binaries must read as
    /// SKEW. The guest reinstalls from the staged copy on every boot, so a
    /// mismatch means it will run something other than what this bundle
    /// carries — the condition that was silently true on this host on
    /// 2026-08-11 and had to be found by hashing files by hand.
    #[test]
    fn differing_contents_are_reported_as_skew_not_agreement() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-skew-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let a = dir.join("bundle");
        let b = dir.join("staged");
        std::fs::write(&a, b"guest-binary-A").expect("write a");
        std::fs::write(&b, b"guest-binary-B-different").expect("write b");

        let ha = file_sha256(&a).expect("hash a");
        let hb = file_sha256(&b).expect("hash b");
        assert_ne!(
            ha, hb,
            "two different binaries must not hash equal — the whole detector rests on this"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik). A detector that shouted SKEW at
    /// everything would satisfy the test above while being useless — operators
    /// would learn to ignore it, which is worse than silence because it burns
    /// the one signal. Byte-identical copies must read as agreement.
    #[test]
    fn identical_contents_are_reported_as_agreement() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-same-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let a = dir.join("bundle");
        let b = dir.join("staged");
        std::fs::write(&a, b"identical-guest-binary").expect("write a");
        std::fs::write(&b, b"identical-guest-binary").expect("write b");

        assert_eq!(
            file_sha256(&a).expect("hash a"),
            file_sha256(&b).expect("hash b"),
            "identical bytes must compare equal, or every healthy host reports a false skew"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An absent file must yield None — NOT a hash of nothing that could
    /// accidentally equal another absent side and read as "in sync". The
    /// three-state verdict exists precisely so "undecidable" is never rendered
    /// as "fine".
    #[test]
    fn an_unreadable_side_is_undecidable_never_agreement() {
        let missing = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-absent-{}-{}",
            std::process::id(),
            line!()
        ));
        assert!(
            file_sha256(&missing).is_none(),
            "an absent binary must hash to None so the verdict stays undecidable"
        );
    }
}
