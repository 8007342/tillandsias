//! SHIM for the licence consent gate of order 1956-ecpb (design D6 of
//! openspec/changes/studio-asset-pipeline).
//!
//! TODO(1956-ecpb): replace this file with the real module from that order —
//! the restricted register (images/models/licence-register-restricted.tsv),
//! the signed acknowledgement store and the operator's standing grant
//! (acknowledgement #1, scope operator-projects, standing). Until it lands
//! this shim ADMITS NOTHING, so every restricted artefact is refused with a
//! named reason and nothing is fetched or queued. It is deliberately not a
//! second gate: it has the one entry point the real module exposes, and the
//! callers (studio_key.rs) change nothing when the real module replaces it.
//!
//! @trace order:1956-ecpb, order:1956-ucix (spec: openspec/changes/studio-asset-pipeline, not yet archived)
#![cfg_attr(not(test), allow(dead_code))]

/// One restricted artefact a job wants to use: enough to match an
/// acknowledgement row (licence id + repo/revision/file/sha256).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestrictedArtefact {
    pub licence: String,
    pub repo: String,
    pub revision: String,
    pub file: String,
    pub sha256: String,
}

/// Does a recorded acknowledgement admit every artefact for `project`?
/// `Ok(ids)` carries one acknowledgement id per artefact, in order, for the
/// provenance `consent` field; `Err` names the first artefact refused.
///
/// SHIM: refuses everything. TODO(1956-ecpb) — the real gate reads the
/// acknowledgement store and the operator's standing grant.
pub fn admits_restricted(
    project: &str,
    artefacts: &[RestrictedArtefact],
) -> Result<Vec<String>, String> {
    let first = artefacts.first().ok_or_else(|| {
        format!("consent_required: {project}: no artefact named (nothing to admit)")
    })?;
    Err(format!(
        "consent_required: {project}: no acknowledgement admits {} ({}@{} {}, sha256 {}); the \
         licence consent gate (order 1956-ecpb) is not on this build yet, so no restricted \
         artefact is admitted. Run the accept-licence skill once it lands; nothing was fetched \
         or queued.",
        first.licence, first.repo, first.revision, first.file, first.sha256
    ))
}
