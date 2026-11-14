//! Orders 2022-ygqj / 2022-89hm: `licence.acknowledge`, the forge MCP tool
//! that gets a batch of licence acknowledgements signed by the host with ONE
//! window and ONE biometric, and returns the records over MCP.
//!
//! The agent names register rows (by row name or artefact repo) and may
//! propose scope/use/expiry; it supplies NO statement text. This module
//! builds every statement itself (`Acknowledgement::statement_text`), so an
//! agent cannot get arbitrary bytes signed; any extra argument is ignored.
//!
//! On approval the signer's allowed-signers line arrives over the host
//! channel (vsock from the tray's own enrol path, never a paste: 2083-nfne),
//! is installed with provenance, every signature is verified with stock
//! `ssh-keygen -Y verify`, and only then are records written where the gate
//! reads them. A denial writes nothing.
//!
//! Design: openspec/changes/os-verified-approval-gates (approval-attestation).

use std::collections::BTreeMap;
use std::path::Path;

use tillandsias_control_wire::approval_wire::{
    ApprovalItem, ApprovalOutcome, ApprovalRequest, ApprovalSigner,
};

use crate::licence_consent::{
    Acknowledgement, RestrictedRow, Verifier, obligations_for, obligations_spec, parse_restricted,
};

pub const TOOL_NAME: &str = "licence.acknowledge";

/// The provenance comment written above every line this module installs.
pub const PROVENANCE_PREFIX: &str = "# enrolled-by: host-approval-signer";

pub fn descriptor() -> serde_json::Value {
    serde_json::json!({
        "name": TOOL_NAME,
        "description": "Accept one or more third-party licences for this project with ONE approval window on the host and ONE Touch ID (or OS biometric). Pass the restricted-register rows you resolved from the user's words (row names or artefact repos, e.g. [\"htdemucs\", \"nikopueringer/CorridorKey2.0\"]); never ask the user for ids, scope, use or expiry. The host shows every licence verbatim, the user scrolls to the end and approves, and the signed records come back here; commit each `record_yaml` at `record_path` and each `spec_markdown` at `spec_path` in the project. Unknown rows are answered with the list of known rows so you can resolve them yourself.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "rows": { "type": "array", "items": { "type": "string" }, "minItems": 1,
                          "description": "Restricted-register row names or artefact repos." },
                "repo_slug": { "type": "string", "description": "The project's owner/name (from its git remote). Selects the per-repo approval key." },
                "scope": { "type": "string", "enum": ["project", "operator-projects"], "default": "project" },
                "use": { "type": "string", "enum": ["non-sale", "commercial"], "default": "non-sale" },
                "expiry": { "type": "string", "description": "RFC 3339 instant or 'standing'. Default: one year from now; 'standing' only with scope operator-projects." }
            },
            "required": ["rows"]
        }
    })
}

/// Everything the call needs from its host, so tests run without one.
pub struct Env<'a> {
    pub register: &'a str,
    pub signer: &'a dyn ApprovalSigner,
    pub verifier: &'a Verifier,
    pub ack_dir: &'a Path,
    pub host: &'a str,
    pub now: chrono::DateTime<chrono::Utc>,
}

fn plain_scope(scope: &str, project: &str) -> String {
    if scope == "operator-projects" {
        "all of the operator's own projects".into()
    } else {
        format!("only the {project} project")
    }
}

fn plain_use(u: &str) -> String {
    if u == "commercial" {
        "commercial use allowed".into()
    } else {
        "not for sale".into()
    }
}

/// Build the batch: one acknowledgement per licence text.
pub fn build(
    project: &str,
    args: &serde_json::Value,
    env: &Env<'_>,
) -> Result<(String, Vec<Acknowledgement>), String> {
    let rows = parse_restricted(env.register)?;
    let wanted: Vec<String> = args["rows"]
        .as_array()
        .ok_or("rows: a list of register row names or repos is required")?
        .iter()
        .filter_map(|v| v.as_str().map(|s| s.trim().to_ascii_lowercase()))
        .filter(|s| !s.is_empty())
        .collect();
    if wanted.is_empty() {
        return Err("rows: name at least one register row".into());
    }
    let mut picked: Vec<&RestrictedRow> = Vec::new();
    let mut unknown = Vec::new();
    for w in &wanted {
        let hits: Vec<&RestrictedRow> = rows
            .iter()
            .filter(|r| r.name.to_ascii_lowercase() == *w || r.repo.to_ascii_lowercase() == *w)
            .collect();
        if hits.is_empty() {
            unknown.push(w.clone());
        }
        picked.extend(hits);
    }
    if !unknown.is_empty() {
        let mut known: Vec<String> = rows
            .iter()
            .map(|r| format!("{} ({})", r.name, r.repo))
            .collect();
        known.dedup();
        return Err(format!(
            "unknown_rows: {}. Known restricted rows: {}",
            unknown.join(", "),
            known.join("; ")
        ));
    }
    let scope_kind = args["scope"].as_str().unwrap_or("project");
    let scope = match scope_kind {
        "project" => format!("project:{project}"),
        "operator-projects" => "operator-projects".into(),
        other => return Err(format!("scope {other:?}: use project or operator-projects")),
    };
    let r#use = match args["use"].as_str().unwrap_or("non-sale") {
        u @ ("non-sale" | "commercial") => u.to_string(),
        other => return Err(format!("use {other:?}: use non-sale or commercial")),
    };
    let expiry = match args["expiry"].as_str() {
        None => (env.now + chrono::Duration::days(365))
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        Some("standing") if scope == "operator-projects" => "standing".into(),
        Some("standing") => {
            return Err("expiry standing is only for scope operator-projects".into());
        }
        Some(t) => chrono::DateTime::parse_from_rfc3339(t)
            .map_err(|e| format!("expiry {t:?}: {e}"))?
            .with_timezone(&chrono::Utc)
            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    };
    // One acknowledgement per (licence id, licence text).
    let mut by_text: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
    for r in picked {
        if r.licence_sha256.starts_with("pending:") {
            return Err(format!(
                "licence_text_unpinned: {} ({}) licence {} has no pinned text ({}); it cannot be acknowledged until the text is pinned",
                r.name, r.repo, r.spdx, r.licence_sha256
            ));
        }
        let covers = by_text
            .entry((r.spdx.clone(), r.licence_sha256.clone()))
            .or_default();
        if !covers.contains(&r.repo) {
            covers.push(r.repo.clone());
        }
    }
    let signed_at = env.now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let acks = by_text
        .into_iter()
        .map(|((licence, licence_sha256), covers)| Acknowledgement {
            licence,
            licence_sha256,
            covers,
            grantor: "operator".into(),
            scope: scope.clone(),
            r#use: r#use.clone(),
            expiry: expiry.clone(),
            signed_at: signed_at.clone(),
            strength: "hardware-biometric".into(),
            host: env.host.into(),
            signature: String::new(),
        })
        .collect();
    Ok((scope_kind.to_string(), acks))
}

fn item_for(ack: &Acknowledgement, scope_kind: &str, project: &str) -> ApprovalItem {
    ApprovalItem {
        title: format!("{} \u{2014} {}", ack.licence, ack.covers.join(", ")),
        licence: ack.licence.clone(),
        clauses: obligations_for(&ack.licence)
            .iter()
            .map(|o| format!("{}: {}", o.class.title(), o.clause))
            .collect(),
        artefacts: ack.covers.clone(),
        scope_plain: plain_scope(scope_kind, project),
        use_plain: plain_use(&ack.r#use),
        statement: ack.statement_text(),
    }
}

fn default_repo_slug(project: &str) -> String {
    let name: String = project
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '-'
            }
        })
        .collect();
    format!("local/{name}")
}

/// Install `line` in the host allowed-signers file with provenance, once.
pub fn install_signers_line(path: &Path, line: &str, now: &str) -> Result<(), String> {
    let line = line.trim();
    if line.contains('\n') || !line.starts_with("operator ") {
        return Err("the signer returned a malformed allowed-signers line".into());
    }
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = existing.lines().collect();
    let attested = |i: usize| i > 0 && lines[i - 1].starts_with(PROVENANCE_PREFIX);
    let mut out = String::new();
    let mut found = false;
    for (i, l) in lines.iter().enumerate() {
        if l.trim() == line {
            if found {
                continue;
            }
            found = true;
            // 2083-nfne: a line that arrived by paste is attested only now,
            // because the host's own signer returned the same key over the
            // host channel and its signatures verified against it.
            if !attested(i) {
                out.push_str(&format!(
                    "{PROVENANCE_PREFIX} {now} (re-attested; was unattested)\n"
                ));
            }
        }
        out.push_str(l);
        out.push('\n');
    }
    if found && out == existing {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    if !found {
        out.push_str(&format!("{PROVENANCE_PREFIX} {now}\n{line}\n"));
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, out).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

/// The tool call.
pub fn call(
    project: &str,
    args: &serde_json::Value,
    env: &Env<'_>,
) -> Result<serde_json::Value, String> {
    let (scope_kind, mut acks) = build(project, args, env)?;
    let repo_slug = args["repo_slug"]
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| default_repo_slug(project));
    let request = ApprovalRequest {
        repo_slug: repo_slug.clone(),
        project: project.into(),
        items: acks
            .iter()
            .map(|a| item_for(a, &scope_kind, project))
            .collect(),
    };
    match env.signer.sign_batch(&request) {
        ApprovalOutcome::Denied { reason } => Ok(serde_json::json!({
            "outcome": "denied", "reason": reason, "written": []
        })),
        ApprovalOutcome::Unsupported { reason } => Err(format!(
            "approval_unavailable: {reason}. Tell the user accepting licences from here is not available on this machine yet."
        )),
        ApprovalOutcome::Approved {
            allowed_signers_line,
            signatures,
            ..
        } => {
            if signatures.len() != acks.len() {
                return Err(format!(
                    "the signer returned {} signatures for {} licences; nothing was written",
                    signatures.len(),
                    acks.len()
                ));
            }
            let now = env.now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
            // Verify against the returned line BEFORE installing anything, so
            // a bad signature leaves the host's signers untouched.
            let scratch = tempfile::tempdir().map_err(|e| e.to_string())?;
            let probe = scratch.path().join("allowed_signers");
            std::fs::write(&probe, format!("{}\n", allowed_signers_line.trim()))
                .map_err(|e| e.to_string())?;
            let probe_v = Verifier::new(&probe);
            for (a, s) in acks.iter_mut().zip(signatures) {
                a.signature = s;
                probe_v
                    .verify(&a.statement_text(), &a.signature, &a.grantor)
                    .map_err(|e| {
                        format!("{} did not verify ({e}); nothing was written", a.licence)
                    })?;
            }
            install_signers_line(&env.verifier.allowed_signers, &allowed_signers_line, &now)?;
            std::fs::create_dir_all(env.ack_dir)
                .map_err(|e| format!("{}: {e}", env.ack_dir.display()))?;
            let mut records = Vec::new();
            for a in &acks {
                env.verifier
                    .verify(&a.statement_text(), &a.signature, &a.grantor)?;
                let yaml = a.to_yaml();
                let file = format!("{}.yaml", a.slug());
                std::fs::write(env.ack_dir.join(&file), &yaml).map_err(|e| e.to_string())?;
                let artefact = a.covers.join(", ");
                records.push(serde_json::json!({
                    "licence": a.licence,
                    "covers": a.covers,
                    "record_path": format!("licences/acknowledgements/{file}"),
                    "record_yaml": yaml,
                    "spec_path": format!("openspec/specs/third-party-licence-{}/spec.md", a.licence),
                    "spec_markdown": obligations_spec(&artefact, &a.licence, &obligations_for(&a.licence)),
                }));
            }
            Ok(serde_json::json!({
                "outcome": "approved",
                "repo_slug": repo_slug,
                "allowed_signers_line": allowed_signers_line.trim(),
                "records": records,
                "commit_trailers": acks.iter().map(|a| format!("Licence-Acknowledgement: {} {}", a.licence, a.licence_sha256)).collect::<Vec<_>>(),
            }))
        }
    }
}

/// The tool on this host: the vsock signer on Linux guests, none elsewhere.
pub fn call_on_host(project: &str, args: &serde_json::Value) -> Result<serde_json::Value, String> {
    #[cfg(target_os = "linux")]
    let signer: Box<dyn ApprovalSigner> = Box::new(VsockSigner);
    #[cfg(not(target_os = "linux"))]
    let signer: Box<dyn ApprovalSigner> =
        Box::new(tillandsias_control_wire::approval_wire::UnsupportedSigner(
            "no approval signer on this host".into(),
        ));
    let verifier = Verifier::for_host();
    let ack_dir = crate::licence_consent::project_acknowledgement_dir(project);
    let host = std::fs::read_to_string("/etc/hostname")
        .map(|h| h.trim().to_string())
        .ok()
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "tillandsias-vm".into());
    call(
        project,
        args,
        &Env {
            register: crate::licence_consent::restricted_register_tsv(),
            signer: &*signer,
            verifier: &verifier,
            ack_dir: &ack_dir,
            host: &host,
            now: chrono::Utc::now(),
        },
    )
}

/// The guest's way to the host signer: AF_VSOCK to CID 2.
#[cfg(target_os = "linux")]
pub struct VsockSigner;

#[cfg(target_os = "linux")]
impl ApprovalSigner for VsockSigner {
    fn sign_batch(&self, request: &ApprovalRequest) -> ApprovalOutcome {
        use std::os::fd::FromRawFd as _;
        let port = tillandsias_control_wire::transport::APPROVAL_SIGNER_VSOCK_PORT;
        // SAFETY: plain socket syscalls on a fd this function owns.
        let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
        if fd < 0 {
            return ApprovalOutcome::Unsupported {
                reason: format!(
                    "no vsock in this guest: {}",
                    std::io::Error::last_os_error()
                ),
            };
        }
        let mut addr: libc::sockaddr_vm = unsafe { std::mem::zeroed() };
        addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        addr.svm_cid = libc::VMADDR_CID_HOST;
        addr.svm_port = port;
        let rc = unsafe {
            libc::connect(
                fd,
                &addr as *const libc::sockaddr_vm as *const libc::sockaddr,
                std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
            )
        };
        // SAFETY: fd is open and owned from here on.
        let mut stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
        if rc != 0 {
            return ApprovalOutcome::Unsupported {
                reason: format!(
                    "the host approval signer is not reachable (vsock CID 2 port {port}: {}); this host has no signer yet",
                    std::io::Error::last_os_error()
                ),
            };
        }
        match tillandsias_control_wire::approval_wire::request_over(&mut stream, request) {
            Ok(o) => o,
            Err(e) => ApprovalOutcome::Denied {
                reason: format!("the approval channel failed: {e}; nothing was signed"),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    const REG: &str = "# name\trepo\trev\tfile\tsha\tspdx\tgated\tcard\tobligations\tlicence_sha256\n\
htdemucs\tadefossez/demucs\tabc\thtdemucs.th\taaaa\tdemucs-weights-unstated\tno\tcard\treview\t2abed9c9aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\
htdemucs_6s\tadefossez/demucs-6s\tabc\t6s.th\tbbbb\tdemucs-weights-unstated\tno\tcard\treview\t2abed9c9aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\
CorridorKey\tniko/CK\tabc\tck.pt\tcccc\tcorridor-key-licence-2.0\tno\tcard\treview\tc92ce56f64162b231c7ce08ce3ed7d8cae15f01a560ca05a8e8db67878eb0065\n\
Radio\tnvidia/radio\tabc\tr.pt\tdddd\tnvidia-open-model-license\tno\tcard\treview\tpending:https://example\n";

    /// A software P-256 key behind ssh-keygen, standing in for the enclave.
    struct SshKeySigner {
        key: std::path::PathBuf,
        line: String,
        seen: Mutex<Vec<ApprovalRequest>>,
        approve: bool,
    }

    impl SshKeySigner {
        fn new(dir: &Path, approve: bool) -> Self {
            let key = dir.join("k");
            assert!(
                std::process::Command::new("ssh-keygen")
                    .args(["-q", "-t", "ecdsa", "-b", "256", "-N", "", "-f"])
                    .arg(&key)
                    .status()
                    .unwrap()
                    .success()
            );
            let pubk = std::fs::read_to_string(key.with_extension("pub")).unwrap();
            let mut parts = pubk.split_whitespace();
            let (t, b) = (parts.next().unwrap(), parts.next().unwrap());
            let line = format!(
                "operator namespaces=\"tillandsias-approval@v1\" {t} {b} tillandsias-approval/acme/game"
            );
            Self {
                key,
                line,
                seen: Mutex::new(vec![]),
                approve,
            }
        }
    }

    impl ApprovalSigner for SshKeySigner {
        fn sign_batch(&self, r: &ApprovalRequest) -> ApprovalOutcome {
            self.seen.lock().unwrap().push(r.clone());
            if !self.approve {
                return ApprovalOutcome::Denied {
                    reason: "cancelled".into(),
                };
            }
            let sigs = r
                .items
                .iter()
                .map(|i| {
                    use std::io::Write as _;
                    let mut c = std::process::Command::new("ssh-keygen")
                        .args(["-q", "-Y", "sign", "-n", "tillandsias-approval@v1", "-f"])
                        .arg(&self.key)
                        .stdin(std::process::Stdio::piped())
                        .stdout(std::process::Stdio::piped())
                        .spawn()
                        .unwrap();
                    c.stdin
                        .take()
                        .unwrap()
                        .write_all(i.statement.as_bytes())
                        .unwrap();
                    String::from_utf8(c.wait_with_output().unwrap().stdout).unwrap()
                })
                .collect();
            ApprovalOutcome::Approved {
                allowed_signers_line: self.line.clone(),
                signatures: sigs,
                strength: "test".into(),
            }
        }
    }

    fn env<'a>(signer: &'a dyn ApprovalSigner, v: &'a Verifier, ack: &'a Path) -> Env<'a> {
        Env {
            register: REG,
            signer,
            verifier: v,
            ack_dir: ack,
            host: "test-host",
            now: chrono::DateTime::parse_from_rfc3339("2026-11-14T23:00:00Z")
                .unwrap()
                .with_timezone(&chrono::Utc),
        }
    }

    /// The headline contract: two rows of one licence plus one of another
    /// make ONE request with two items (one window, one touch), records
    /// verify with ssh-keygen, land where the gate reads, and the host's
    /// signers line is installed with provenance.
    #[test]
    fn one_call_signs_the_batch_once_and_writes_verified_records() {
        let d = tempfile::tempdir().unwrap();
        let signer = SshKeySigner::new(d.path(), true);
        let v = Verifier::new(&d.path().join("approvals/allowed_signers"));
        let ack = d.path().join("acks");
        let out = call(
            "demon_attack",
            &serde_json::json!({"rows": ["htdemucs", "HTDEMUCS_6S", "niko/CK"], "repo_slug": "acme/game",
                                "statement": "EVIL bytes the agent wants signed"}),
            &env(&signer, &v, &ack),
        )
        .unwrap();
        assert_eq!(out["outcome"], "approved", "{out}");
        let seen = signer.seen.lock().unwrap();
        assert_eq!(seen.len(), 1, "one window per request");
        assert_eq!(seen[0].items.len(), 2, "one item per licence text");
        assert!(!seen[0].items.iter().any(|i| i.statement.contains("EVIL")));
        assert!(!seen[0].display_text().contains("EVIL"));
        assert_eq!(out["records"].as_array().unwrap().len(), 2);
        let signers = std::fs::read_to_string(&v.allowed_signers).unwrap();
        assert!(signers.contains(PROVENANCE_PREFIX), "{signers}");
        assert_eq!(std::fs::read_dir(&ack).unwrap().count(), 2);
        for (_, a) in crate::licence_consent::read_acknowledgements(&ack) {
            v.verify(&a.statement_text(), &a.signature, "operator")
                .unwrap();
            assert_eq!(a.scope, "project:demon_attack");
            assert_eq!(a.expiry, "2027-11-14T23:00:00Z");
        }
    }

    /// 2083-nfne: the pasted demon_attack line gets provenance once the host
    /// signer returns the same key; an attested line is left as is.
    #[test]
    fn a_pasted_line_is_attested_when_the_host_signer_returns_it() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("allowed_signers");
        let line = "operator namespaces=\"tillandsias-approval@v1\" ecdsa-sha2-nistp256 AAAA tillandsias-approval/8007342/demon_attack";
        std::fs::write(&p, format!("{line}\n")).unwrap();
        install_signers_line(&p, line, "T1").unwrap();
        let t = std::fs::read_to_string(&p).unwrap();
        assert_eq!(
            t,
            format!("{PROVENANCE_PREFIX} T1 (re-attested; was unattested)\n{line}\n")
        );
        install_signers_line(&p, line, "T2").unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), t);
    }

    #[test]
    fn cancel_writes_nothing() {
        let d = tempfile::tempdir().unwrap();
        let signer = SshKeySigner::new(d.path(), false);
        let v = Verifier::new(&d.path().join("approvals/allowed_signers"));
        let ack = d.path().join("acks");
        let out = call(
            "g",
            &serde_json::json!({"rows": ["htdemucs"]}),
            &env(&signer, &v, &ack),
        )
        .unwrap();
        assert_eq!(out["outcome"], "denied");
        assert!(!v.allowed_signers.exists());
        assert!(!ack.exists());
    }

    #[test]
    fn unknown_or_unpinned_rows_are_refused_before_any_window() {
        let d = tempfile::tempdir().unwrap();
        let signer = SshKeySigner::new(d.path(), true);
        let v = Verifier::new(&d.path().join("s"));
        let ack = d.path().join("a");
        let e = call(
            "g",
            &serde_json::json!({"rows": ["depry"]}),
            &env(&signer, &v, &ack),
        )
        .unwrap_err();
        assert!(
            e.starts_with("unknown_rows: depry") && e.contains("htdemucs"),
            "{e}"
        );
        let e = call(
            "g",
            &serde_json::json!({"rows": ["radio"]}),
            &env(&signer, &v, &ack),
        )
        .unwrap_err();
        assert!(e.starts_with("licence_text_unpinned"), "{e}");
        let e = call(
            "g",
            &serde_json::json!({"rows": ["htdemucs"], "expiry": "standing"}),
            &env(&signer, &v, &ack),
        )
        .unwrap_err();
        assert!(e.contains("operator-projects"), "{e}");
        assert!(signer.seen.lock().unwrap().is_empty());
    }

    /// A signer that returns a signature from a different key than its line
    /// gets nothing installed and nothing written.
    #[test]
    fn a_signature_that_does_not_match_the_returned_line_installs_nothing() {
        let d = tempfile::tempdir().unwrap();
        let mut signer = SshKeySigner::new(d.path(), true);
        let other = tempfile::tempdir().unwrap();
        signer.line = SshKeySigner::new(other.path(), true).line;
        let v = Verifier::new(&d.path().join("approvals/allowed_signers"));
        let ack = d.path().join("acks");
        let e = call(
            "g",
            &serde_json::json!({"rows": ["htdemucs"]}),
            &env(&signer, &v, &ack),
        )
        .unwrap_err();
        assert!(e.contains("did not verify"), "{e}");
        assert!(!v.allowed_signers.exists());
        assert!(!ack.exists());
    }
}
