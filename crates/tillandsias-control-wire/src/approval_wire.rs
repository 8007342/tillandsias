//! Orders 2022-ygqj / 2022-89hm: the contract between the forge's approval
//! MCP tool and the host signer that shows the window and takes the biometric.
//!
//! The flow (operator UX ruling 2026-11-14): one vague utterance, ONE native
//! window listing every acknowledgeable in the batch, approve disabled until
//! the user has scrolled to the bottom, ONE biometric that signs the whole
//! batch, then the window closes. Nothing is printed for anyone to copy.
//!
//! The statements are built by the guest headless from register rows
//! (`licence_consent::Acknowledgement::statement_text`); the agent never
//! supplies statement bytes. The signer signs exactly the statements it is
//! handed, and shows the clauses it is handed, verbatim.
//!
//! This module is plain data plus a trait so the tool contract can be tested
//! on every host with a stub signer; the macOS Touch ID signer lives in the
//! tray (`approval_signer.rs`).
//!
//! Design: openspec/changes/os-verified-approval-gates (approval-attestation).

use serde::{Deserialize, Serialize};

/// One acknowledgeable: what the window shows and what gets signed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalItem {
    /// Human heading, e.g. "Demucs weights (htdemucs, htdemucs_6s)".
    pub title: String,
    /// The licence id from the register (`demucs-weights-unstated`).
    pub licence: String,
    /// Verbatim clauses, shown as written.
    pub clauses: Vec<String>,
    /// The artefacts the acknowledgement covers (repo ids).
    pub artefacts: Vec<String>,
    /// Scope in plain words ("only the demon_attack project").
    pub scope_plain: String,
    /// Use in plain words ("not for sale").
    pub use_plain: String,
    /// The canonical statement, signed byte for byte.
    pub statement: String,
}

/// One request = one window = one biometric.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalRequest {
    /// Repo slug `owner/name`; selects (and silently enrols) the per-repo key.
    pub repo_slug: String,
    /// Project label shown in the window header.
    pub project: String,
    pub items: Vec<ApprovalItem>,
}

/// What the signer returns. Never partial: approved means every item in the
/// batch is signed, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum ApprovalOutcome {
    Approved {
        /// The per-repo key's allowed-signers line, written by the enrol path.
        allowed_signers_line: String,
        /// One armored SSHSIG per item, same order as the request.
        signatures: Vec<String>,
        /// os-verified-approval-gates D1 strength word (`biometric`, `presence`).
        strength: String,
    },
    /// The user cancelled, closed the window, or the biometric failed.
    /// Nothing was signed and nothing may be written.
    Denied { reason: String },
    /// This host has no signer (e.g. Linux before 2022-hn2k).
    Unsupported { reason: String },
}

/// The host signer behind the approval tool.
pub trait ApprovalSigner: Send + Sync {
    fn sign_batch(&self, request: &ApprovalRequest) -> ApprovalOutcome;
}

impl ApprovalRequest {
    /// Refuse a malformed request before any window opens.
    pub fn validate(&self) -> Result<(), String> {
        if self.items.is_empty() {
            return Err("an approval request needs at least one item".into());
        }
        for (i, it) in self.items.iter().enumerate() {
            if it.statement.trim().is_empty() {
                return Err(format!("item {i} ({}) has no statement", it.licence));
            }
            if it.clauses.is_empty() {
                return Err(format!(
                    "item {i} ({}) has no clauses to show; the window must show what is signed",
                    it.licence
                ));
            }
        }
        Ok(())
    }

    /// The text the window shows, in order, for every item. The window
    /// renders exactly this so a test can pin what the user read.
    pub fn display_text(&self) -> String {
        let mut s = format!(
            "Licences for {}\n\nRead to the end, then approve with Touch ID.\n",
            self.project
        );
        for it in &self.items {
            s.push_str(&format!("\n\u{2014} {} \u{2014}\n", it.title));
            s.push_str(&format!("Licence: {}\n", it.licence));
            s.push_str(&format!("Covers: {}\n", it.artefacts.join(", ")));
            s.push_str(&format!("Who: {}\n", it.scope_plain));
            s.push_str(&format!("Use: {}\n\n", it.use_plain));
            for c in &it.clauses {
                s.push_str(c);
                s.push_str("\n\n");
            }
            // What is signed is shown, byte for byte: a caller that reached
            // the signer directly cannot get bytes signed the user never saw.
            s.push_str("What your Touch ID signs:\n");
            s.push_str(&it.statement);
            s.push('\n');
        }
        s.push_str("\n\u{2014} End \u{2014}\n");
        s
    }
}

/// Upper bound on one request line: a batch of licence texts, not a stream.
pub const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;

/// Host side: read one JSON-line request, sign it, write one JSON-line
/// outcome. A malformed request is answered `Denied`, never signed.
pub fn serve_one<S: std::io::Read + std::io::Write>(
    stream: &mut S,
    signer: &dyn ApprovalSigner,
) -> std::io::Result<()> {
    let line = read_line_bounded(stream, MAX_REQUEST_BYTES)?;
    let outcome = match serde_json::from_slice::<ApprovalRequest>(&line) {
        Ok(req) => match req.validate() {
            Ok(()) => signer.sign_batch(&req),
            Err(reason) => ApprovalOutcome::Denied { reason },
        },
        Err(e) => ApprovalOutcome::Denied {
            reason: format!("malformed approval request: {e}"),
        },
    };
    write_json_line(stream, &outcome)
}

/// Guest side: send one request, read the outcome.
pub fn request_over<S: std::io::Read + std::io::Write>(
    stream: &mut S,
    request: &ApprovalRequest,
) -> std::io::Result<ApprovalOutcome> {
    write_json_line(stream, request)?;
    let line = read_line_bounded(stream, MAX_REQUEST_BYTES)?;
    serde_json::from_slice(&line).map_err(std::io::Error::other)
}

fn write_json_line<S: std::io::Write, T: Serialize>(s: &mut S, v: &T) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(v).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    s.write_all(&bytes)?;
    s.flush()
}

fn read_line_bounded<S: std::io::Read>(s: &mut S, max: usize) -> std::io::Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut b = [0u8; 1];
    loop {
        if s.read(&mut b)? == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "approval channel closed mid-line",
            ));
        }
        if b[0] == b'\n' {
            return Ok(out);
        }
        out.push(b[0]);
        if out.len() > max {
            return Err(std::io::Error::other("approval line too long"));
        }
    }
}

/// A signer that is not there. Linux and tests use it.
pub struct UnsupportedSigner(pub String);

impl ApprovalSigner for UnsupportedSigner {
    fn sign_batch(&self, _request: &ApprovalRequest) -> ApprovalOutcome {
        ApprovalOutcome::Unsupported {
            reason: self.0.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(l: &str) -> ApprovalItem {
        ApprovalItem {
            title: format!("{l} weights"),
            licence: l.into(),
            clauses: vec![format!("{l} clause one, verbatim.")],
            artefacts: vec![format!("acme/{l}")],
            scope_plain: "only this project".into(),
            use_plain: "not for sale".into(),
            statement: format!("tillandsias-licence-ack v1\nlicence: {l}\n"),
        }
    }

    #[test]
    fn display_lists_every_item_and_its_verbatim_clauses() {
        let r = ApprovalRequest {
            repo_slug: "acme/game".into(),
            project: "game".into(),
            items: vec![item("depry"), item("herpy")],
        };
        r.validate().unwrap();
        let t = r.display_text();
        for l in ["depry", "herpy"] {
            assert!(t.contains(&format!("{l} clause one, verbatim.")), "{t}");
            assert!(t.contains(&format!("acme/{l}")), "{t}");
        }
        assert!(t.find("depry").unwrap() < t.find("herpy").unwrap());
    }

    #[test]
    fn empty_batches_and_clause_less_items_are_refused() {
        let mut r = ApprovalRequest {
            repo_slug: "acme/game".into(),
            project: "game".into(),
            items: vec![],
        };
        assert!(r.validate().is_err());
        let mut it = item("x");
        it.clauses.clear();
        r.items.push(it);
        assert!(r.validate().unwrap_err().contains("no clauses"));
    }

    struct Recording(std::sync::Mutex<Vec<String>>);
    impl ApprovalSigner for Recording {
        fn sign_batch(&self, r: &ApprovalRequest) -> ApprovalOutcome {
            let sigs: Vec<String> = r
                .items
                .iter()
                .map(|i| format!("SIG({})", i.statement))
                .collect();
            self.0.lock().unwrap().extend(sigs.clone());
            ApprovalOutcome::Approved {
                allowed_signers_line: "operator ecdsa AAAA tillandsias-approval/acme/game".into(),
                signatures: sigs,
                strength: "test".into(),
            }
        }
    }

    #[test]
    fn one_request_over_a_socket_pair_signs_the_whole_batch_once() {
        let (mut a, mut b) = std::os::unix::net::UnixStream::pair().unwrap();
        let signer = std::sync::Arc::new(Recording(Default::default()));
        let s2 = signer.clone();
        let host = std::thread::spawn(move || serve_one(&mut b, &*s2).unwrap());
        let req = ApprovalRequest {
            repo_slug: "acme/game".into(),
            project: "game".into(),
            items: vec![item("depry"), item("herpy")],
        };
        let out = request_over(&mut a, &req).unwrap();
        host.join().unwrap();
        let ApprovalOutcome::Approved { signatures, .. } = out else {
            panic!("{out:?}")
        };
        assert_eq!(signatures.len(), 2);
        assert_eq!(signer.0.lock().unwrap().len(), 2);
    }

    #[test]
    fn a_malformed_or_empty_request_is_denied_and_never_reaches_the_signer() {
        for line in [
            &b"not json\n"[..],
            br#"{"repo_slug":"a/b","project":"b","items":[]}"#,
        ] {
            let (mut a, mut b) = std::os::unix::net::UnixStream::pair().unwrap();
            let signer = Recording(Default::default());
            use std::io::Write as _;
            a.write_all(line).unwrap();
            if !line.ends_with(b"\n") {
                a.write_all(b"\n").unwrap();
            }
            serve_one(&mut b, &signer).unwrap();
            let got = read_line_bounded(&mut a, MAX_REQUEST_BYTES).unwrap();
            let o: ApprovalOutcome = serde_json::from_slice(&got).unwrap();
            assert!(matches!(o, ApprovalOutcome::Denied { .. }), "{o:?}");
            assert!(signer.0.lock().unwrap().is_empty());
        }
    }

    #[test]
    fn the_window_shows_the_exact_signed_statement() {
        let r = ApprovalRequest {
            repo_slug: "a/b".into(),
            project: "b".into(),
            items: vec![item("depry")],
        };
        assert!(r.display_text().contains(&r.items[0].statement));
    }

    #[test]
    fn outcome_round_trips_as_tagged_json() {
        let o = ApprovalOutcome::Denied {
            reason: "cancelled".into(),
        };
        let j = serde_json::to_string(&o).unwrap();
        assert!(j.contains("\"outcome\":\"denied\""), "{j}");
        assert_eq!(serde_json::from_str::<ApprovalOutcome>(&j).unwrap(), o);
        let u = UnsupportedSigner("no signer".into()).sign_batch(&ApprovalRequest {
            repo_slug: "a/b".into(),
            project: "b".into(),
            items: vec![item("x")],
        });
        assert!(matches!(u, ApprovalOutcome::Unsupported { .. }));
    }
}
