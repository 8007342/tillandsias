//! Order 1879-5jkt: the approval broker. A request for a costly action
//! becomes a signed, action-bound approval record (openspec change
//! os-verified-approval-gates, design D1 to D4).
//!
//! `tillandsias approval request` builds the canonical statement (D3), checks
//! it carries no personal data (operator PII amendment 2026-10-27), takes the
//! user check, signs it as SSHSIG with the host's approval key
//! (`ssh-keygen -Y sign -n tillandsias-approval@v1`, D2), verifies its own
//! signature against the enrolled signers, then writes the record: a file in
//! the broker's state, a line in its journal and, for a git action, a note on
//! the approved commit under `refs/notes/tillandsias/approvals` (D4).
//!
//! `tillandsias approval verify <record>` admits a record once: the signature
//! verifies against the enrolled signers, it has not expired, the fields the
//! caller names match, and its nonce has not been used. The nonce is consumed
//! by creating `used/<nonce>` with `create_new`, so two racing verifiers
//! cannot both admit it.
//!
//! The user check is the key's own when the key is a FIDO2 security key
//! (`sk-*`: the authenticator asks for touch and PIN while signing). For any
//! other key it is polkit: `pkcheck --action-id org.tillandsias.approve
//! --allow-user-interaction` must pass before anything is signed, and the
//! statement then says `software-password`. A denied or unavailable check
//! signs nothing and writes nothing. Enrolment (creating the key and writing
//! allowed_signers) is order 1880-9wpd.
//!
//! No hostname, home path or email ever reaches a statement or note: `host`
//! is an opaque enrolment id derived from the public key, and a request
//! carrying personal data is refused before signing.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use base64::Engine as _;
use chrono::{DateTime, Duration, SubsecRound as _, Timelike as _, Utc};
use sha2::{Digest, Sha256};

use crate::licence_consent::{NAMESPACE, Verifier};

/// The first line of every approval statement (D3).
pub const STATEMENT_HEAD: &str = "tillandsias-approval v1";
/// The principal every approval is verified as (an opaque name, never an
/// email: PII amendment item 5).
pub const PRINCIPAL: &str = "operator";
/// The polkit action the software path checks.
pub const POLKIT_ACTION: &str = "org.tillandsias.approve";
/// An approval lasts ten minutes from issue (D3).
pub const LIFETIME_MINUTES: i64 = 10;

/// The action kinds the broker signs, each with its plain note sentence.
/// The sentence names no hash; `{branch}` is the target's short name.
const ACTIONS: &[(&str, &str)] = &[
    (
        "merge-into-integration",
        "The operator approved merging into {branch}.",
    ),
    (
        "push-to-integration",
        "The operator approved pushing to {branch}.",
    ),
    (
        "open-pull-request",
        "The operator approved opening a pull request into {branch}.",
    ),
    (
        "workflow-dispatch",
        "The operator approved running a GitHub workflow.",
    ),
    (
        "create-remote-worker",
        "The operator approved starting a remote worker.",
    ),
    (
        "cloudflare-write",
        "The operator approved a change to Cloudflare.",
    ),
];

/// What the user check that released the key was (D1). Only the path
/// actually taken is ever written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Strength {
    HardwareBiometric,
    HardwarePin,
    HardwarePresence,
    SoftwarePassword,
}

impl Strength {
    pub fn as_str(self) -> &'static str {
        match self {
            Strength::HardwareBiometric => "hardware-biometric",
            Strength::HardwarePin => "hardware-pin",
            Strength::HardwarePresence => "hardware-presence",
            Strength::SoftwarePassword => "software-password",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        Ok(match s {
            "hardware-biometric" => Strength::HardwareBiometric,
            "hardware-pin" => Strength::HardwarePin,
            "hardware-presence" => Strength::HardwarePresence,
            "software-password" => Strength::SoftwarePassword,
            other => return Err(format!("unknown strength '{other}'")),
        })
    }
}

/// The canonical statement (D3). Optional fields are omitted, never empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    pub action: String,
    pub project: String,
    pub target: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub detail: String,
    /// An opaque enrolment id, never a host name.
    pub host: String,
    pub forge_instance: Option<String>,
    pub forge_agent: Option<String>,
    pub forge_project: Option<String>,
    pub forge_launched: Option<String>,
    pub strength: Strength,
    pub nonce: String,
    pub issued: DateTime<Utc>,
    pub expires: DateTime<Utc>,
}

/// The fields in their signed order.
const FIELDS: &[&str] = &[
    "action",
    "project",
    "target",
    "from",
    "to",
    "detail",
    "host",
    "forge_instance",
    "forge_agent",
    "forge_project",
    "forge_launched",
    "strength",
    "nonce",
    "issued",
    "expires",
];

fn stamp(t: &DateTime<Utc>) -> String {
    t.format("%Y-%m-%dT%H:%MZ").to_string()
}

fn parse_stamp(s: &str) -> Result<DateTime<Utc>, String> {
    chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%MZ")
        .map(|n| n.and_utc())
        .map_err(|e| format!("bad time '{s}': {e}"))
}

impl Statement {
    fn pairs(&self) -> Vec<(&'static str, String)> {
        let mut v: Vec<(&'static str, String)> = vec![
            ("action", self.action.clone()),
            ("project", self.project.clone()),
        ];
        let opt = |v: &mut Vec<(&'static str, String)>, k: &'static str, o: &Option<String>| {
            if let Some(x) = o {
                v.push((k, x.clone()));
            }
        };
        opt(&mut v, "target", &self.target);
        opt(&mut v, "from", &self.from);
        opt(&mut v, "to", &self.to);
        v.push(("detail", self.detail.clone()));
        v.push(("host", self.host.clone()));
        opt(&mut v, "forge_instance", &self.forge_instance);
        opt(&mut v, "forge_agent", &self.forge_agent);
        opt(&mut v, "forge_project", &self.forge_project);
        opt(&mut v, "forge_launched", &self.forge_launched);
        v.push(("strength", self.strength.as_str().to_string()));
        v.push(("nonce", self.nonce.clone()));
        v.push(("issued", stamp(&self.issued)));
        v.push(("expires", stamp(&self.expires)));
        v
    }

    /// The bytes that are signed: line-oriented UTF-8, one trailing newline.
    pub fn text(&self) -> String {
        let mut s = format!("{STATEMENT_HEAD}\n");
        for (k, v) in self.pairs() {
            s.push_str(&format!("{k}: {v}\n"));
        }
        s
    }

    /// Parse a statement, strictly: the head line, known fields in the signed
    /// order, each at most once, the required ones present.
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut lines = text.lines();
        if lines.next() != Some(STATEMENT_HEAD) {
            return Err(format!(
                "the statement does not start with '{STATEMENT_HEAD}'"
            ));
        }
        let mut got: Vec<(String, String)> = Vec::new();
        let mut at = 0usize;
        for l in lines {
            let (k, v) = l
                .split_once(": ")
                .ok_or_else(|| format!("malformed line '{l}'"))?;
            let pos = FIELDS
                .iter()
                .position(|f| *f == k)
                .ok_or_else(|| format!("unknown field '{k}'"))?;
            if pos < at {
                return Err(format!("field '{k}' is out of order or repeated"));
            }
            at = pos + 1;
            got.push((k.to_string(), v.to_string()));
        }
        let get = |k: &str| got.iter().find(|(x, _)| x == k).map(|(_, v)| v.clone());
        let need = |k: &str| get(k).ok_or_else(|| format!("missing field '{k}'"));
        let st = Statement {
            action: need("action")?,
            project: need("project")?,
            target: get("target"),
            from: get("from"),
            to: get("to"),
            detail: need("detail")?,
            host: need("host")?,
            forge_instance: get("forge_instance"),
            forge_agent: get("forge_agent"),
            forge_project: get("forge_project"),
            forge_launched: get("forge_launched"),
            strength: Strength::parse(&need("strength")?)?,
            nonce: need("nonce")?,
            issued: parse_stamp(&need("issued")?)?,
            expires: parse_stamp(&need("expires")?)?,
        };
        if st.text() != text {
            return Err("the statement is not in canonical form".into());
        }
        Ok(st)
    }
}

/// The host's name, for the personal-data check only; it is never written.
fn host_name() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer outlives the call and its length is passed.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return None;
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let s = String::from_utf8_lossy(&buf[..end]).trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn looks_like_email(s: &str) -> bool {
    s.split(|c: char| c.is_whitespace() || c == '<' || c == '>' || c == '(' || c == ')')
        .any(|w| {
            let Some((local, domain)) = w.split_once('@') else {
                return false;
            };
            !local.is_empty() && domain.contains('.') && !domain.starts_with('.')
        })
}

/// Why a value carries personal data, or None (PII amendment items 3 and 4).
pub fn personal_data(value: &str, host: Option<&str>) -> Option<&'static str> {
    let lower = value.to_lowercase();
    if lower.contains("/home/")
        || lower.contains("/users/")
        || lower.contains("c:\\users\\")
        || lower.contains("/var/home/")
    {
        return Some("a home directory path");
    }
    if looks_like_email(value) {
        return Some("an email address");
    }
    if let Some(h) = host {
        let short = h.split('.').next().unwrap_or(h).to_lowercase();
        if short.len() >= 3 && lower.contains(&short) {
            return Some("this host's name");
        }
    }
    None
}

/// An opaque id for a public key: `k` and ten letters from g..z, so it can
/// never read as a hexadecimal hash (PII amendment item 1).
pub fn enrolment_id(public_key_line: &str) -> String {
    let blob = public_key_line
        .split_whitespace()
        .nth(1)
        .unwrap_or(public_key_line);
    let raw = base64::engine::general_purpose::STANDARD
        .decode(blob)
        .unwrap_or_else(|_| blob.as_bytes().to_vec());
    let digest = Sha256::digest(&raw);
    const ALPHA: &[u8] = b"ghijklmnopqrstuvwxyz";
    let mut id = String::from("k");
    for b in digest.iter().take(10) {
        id.push(ALPHA[(*b as usize) % ALPHA.len()] as char);
    }
    id
}

/// `Approved-by: operator (<enrolment id>)`: who approved, with no host name,
/// no biometric name and no hash (PII amendment item 2).
pub fn approved_by_trailer(enrolment: &str) -> String {
    format!("Approved-by: {PRINCIPAL} ({enrolment})")
}

/// The note's first line: a plain sentence with no hash in it.
pub fn note_sentence(action: &str, target: Option<&str>) -> Option<String> {
    let (_, tmpl) = ACTIONS.iter().find(|(a, _)| *a == action)?;
    let branch = target
        .map(|t| t.strip_prefix("refs/heads/").unwrap_or(t).to_string())
        .unwrap_or_else(|| "the branch".into());
    let s = tmpl.replace("{branch}", &branch);
    if has_hex_run(&s) {
        // A branch named like a hash would put a hash on the first line.
        return Some(tmpl.replace("{branch}", "the branch"));
    }
    Some(s)
}

/// True when `s` has seven or more hexadecimal characters in a row.
pub fn has_hex_run(s: &str) -> bool {
    let mut run = 0;
    for c in s.chars() {
        if c.is_ascii_hexdigit() {
            run += 1;
            if run >= 7 {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

/// The broker's state: `TILLANDSIAS_APPROVAL_STATE_DIR`, or
/// `<state dir>/approvals` (the directory allowed_signers lives in).
pub fn state_dir() -> PathBuf {
    std::env::var_os("TILLANDSIAS_APPROVAL_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| tillandsias_core::config::state_dir().join("approvals"))
}

/// The note body, which is also the record file: the sentence, a blank line,
/// the statement, then the armored signature.
pub fn note_body(sentence: &str, statement: &str, armored: &str) -> String {
    format!("{sentence}\n\n{statement}{armored}")
}

/// Split a record or note body into its statement and armored signature.
pub fn split_record(body: &str) -> Result<(String, String), String> {
    let start = body
        .find(&format!("{STATEMENT_HEAD}\n"))
        .ok_or("the record holds no approval statement")?;
    let sig_at = body[start..]
        .find("-----BEGIN SSH SIGNATURE-----")
        .ok_or("the record holds no signature")?
        + start;
    let end_marker = "-----END SSH SIGNATURE-----";
    let sig_end = body[sig_at..]
        .find(end_marker)
        .ok_or("the signature is not terminated")?
        + sig_at
        + end_marker.len();
    Ok((
        body[start..sig_at].to_string(),
        format!("{}\n", &body[sig_at..sig_end]),
    ))
}

/// A refusal: the token's last segment and one plain sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: String,
    pub why: String,
}

fn refuse(code: &str, why: impl Into<String>) -> Refusal {
    Refusal {
        code: code.into(),
        why: why.into(),
    }
}

/// What the request names; the broker adds host, strength, nonce and times.
#[derive(Debug, Clone, Default)]
pub struct Request {
    pub action: String,
    pub project: String,
    pub target: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub detail: String,
    pub forge_instance: Option<String>,
    pub forge_agent: Option<String>,
    pub forge_project: Option<String>,
    pub forge_launched: Option<String>,
    pub key: PathBuf,
    pub repo: Option<PathBuf>,
}

/// The user check before a software key is used. Returns Ok when polkit
/// authorised this process for [`POLKIT_ACTION`].
fn polkit_check() -> Result<(), Refusal> {
    let out = Command::new("pkcheck")
        .args(["--action-id", POLKIT_ACTION, "--process"])
        .arg(std::process::id().to_string())
        .arg("--allow-user-interaction")
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| {
            refuse(
                "user-check-unavailable",
                format!("polkit's pkcheck could not run ({e}), so no user check was made"),
            )
        })?;
    if out.status.success() {
        Ok(())
    } else {
        let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(refuse(
            "user-check-denied",
            format!("polkit did not authorise {POLKIT_ACTION}: {msg}"),
        ))
    }
}

fn random_nonce() -> String {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("the OS random source is available");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Issue, sign and record an approval. Returns the record path and the
/// statement. Nothing is written unless every check passed and the signature
/// verified.
pub fn request(req: &Request, now: DateTime<Utc>) -> Result<(PathBuf, Statement), Refusal> {
    let sentence = note_sentence(&req.action, req.target.as_deref()).ok_or_else(|| {
        refuse(
            "unknown-action",
            format!(
                "'{}' is not an action the broker approves (known: {})",
                req.action,
                ACTIONS
                    .iter()
                    .map(|(a, _)| *a)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        )
    })?;
    if req.project.trim().is_empty() || req.detail.trim().is_empty() {
        return Err(refuse(
            "incomplete",
            "a request needs --project and --detail",
        ));
    }
    if req.project.starts_with('/') || req.project.contains('\\') {
        return Err(refuse(
            "personal-data",
            "the project is a repository slug, never a local path",
        ));
    }
    let host = host_name();
    let named: Vec<(&str, &str)> = [
        ("project", Some(req.project.as_str())),
        ("target", req.target.as_deref()),
        ("detail", Some(req.detail.as_str())),
        ("forge_instance", req.forge_instance.as_deref()),
        ("forge_agent", req.forge_agent.as_deref()),
        ("forge_project", req.forge_project.as_deref()),
    ]
    .into_iter()
    .filter_map(|(k, v)| v.map(|v| (k, v)))
    .collect();
    for (k, v) in &named {
        if v.contains('\n') {
            return Err(refuse(
                "malformed",
                format!("the {k} spans more than one line"),
            ));
        }
        if let Some(why) = personal_data(v, host.as_deref()) {
            return Err(refuse(
                "personal-data",
                format!("the {k} carries {why}; an approval record publishes no personal data"),
            ));
        }
    }

    // Enrolled? Nothing is asked of the user for a key no one can verify.
    let verifier = Verifier::for_host();
    if !verifier.allowed_signers.is_file() {
        return Err(refuse(
            "not-enrolled",
            format!(
                "no enrolled approval key at {} (enrol the host's approval key first)",
                verifier.allowed_signers.display()
            ),
        ));
    }
    let pub_path = PathBuf::from(format!("{}.pub", req.key.display()));
    let public = std::fs::read_to_string(&pub_path)
        .map_err(|e| refuse("no-key", format!("{}: {e}", pub_path.display())))?;
    let key_type = public.split_whitespace().next().unwrap_or("");
    let strength = if key_type.starts_with("sk-") {
        // The authenticator's touch and PIN are the check (enrolled with
        // -O verify-required by 1880-9wpd).
        Strength::HardwarePin
    } else {
        polkit_check()?;
        Strength::SoftwarePassword
    };

    let issued = now.trunc_subsecs(0).with_second(0).unwrap_or(now);
    let st = Statement {
        action: req.action.clone(),
        project: req.project.clone(),
        target: req.target.clone(),
        from: req.from.clone(),
        to: req.to.clone(),
        detail: req.detail.clone(),
        host: enrolment_id(&public),
        forge_instance: req.forge_instance.clone(),
        forge_agent: req.forge_agent.clone(),
        forge_project: req.forge_project.clone(),
        forge_launched: req.forge_launched.clone(),
        strength,
        nonce: random_nonce(),
        issued,
        expires: issued + Duration::minutes(LIFETIME_MINUTES),
    };
    let text = st.text();

    // Sign in a private scratch dir; nothing lands in the state until the
    // signature verified.
    let scratch = tempfile::Builder::new()
        .prefix("tillandsias-approval-")
        .tempdir()
        .map_err(|e| refuse("io", format!("scratch dir: {e}")))?;
    let stmt_path = scratch.path().join("statement");
    std::fs::write(&stmt_path, &text).map_err(|e| refuse("io", format!("statement: {e}")))?;
    let out = Command::new("ssh-keygen")
        .args(["-q", "-Y", "sign", "-n", NAMESPACE, "-f"])
        .arg(&req.key)
        .arg(&stmt_path)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| refuse("sign-failed", format!("ssh-keygen: {e}")))?;
    if !out.status.success() {
        return Err(refuse(
            "sign-failed",
            format!(
                "ssh-keygen -Y sign: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        ));
    }
    let armored = std::fs::read_to_string(scratch.path().join("statement.sig"))
        .map_err(|e| refuse("sign-failed", format!("signature: {e}")))?;
    verifier.verify(&text, &armored, PRINCIPAL).map_err(|e| {
        refuse(
            "not-enrolled-key",
            format!("the key that signed is not the enrolled one: {e}"),
        )
    })?;

    // Record it.
    let body = note_body(&sentence, &text, &armored);
    let dir = state_dir();
    let records = dir.join("records");
    std::fs::create_dir_all(&records)
        .map_err(|e| refuse("io", format!("{}: {e}", records.display())))?;
    let path = records.join(format!(
        "{}-{}.approval",
        issued.format("%Y%m%dt%H%Mz"),
        &st.nonce[..12]
    ));
    std::fs::write(&path, &body).map_err(|e| refuse("io", format!("{}: {e}", path.display())))?;
    let line = serde_json::json!({
        "nonce": st.nonce,
        "action": st.action,
        "issued": stamp(&st.issued),
        "expires": stamp(&st.expires),
        "record": path.file_name().map(|n| n.to_string_lossy().to_string()),
        "statement": text,
        "signature": armored,
    });
    let mut journal = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("journal.jsonl"))
        .map_err(|e| refuse("io", format!("journal: {e}")))?;
    writeln!(journal, "{line}").map_err(|e| refuse("io", format!("journal: {e}")))?;

    if let (Some(repo), Some(to)) = (&req.repo, &req.to) {
        let note = scratch.path().join("note");
        std::fs::write(&note, &body).map_err(|e| refuse("io", format!("note: {e}")))?;
        // Append-only per commit: a second approval on the same commit is
        // appended, never written over the first.
        let out = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(["notes", "--ref=tillandsias/approvals", "append", "-F"])
            .arg(&note)
            .arg(to)
            .output()
            .map_err(|e| refuse("note-failed", format!("git notes: {e}")))?;
        if !out.status.success() {
            return Err(refuse(
                "note-failed",
                format!(
                    "the record is at {} but the note was not written: {}",
                    path.display(),
                    String::from_utf8_lossy(&out.stderr).trim()
                ),
            ));
        }
    }
    Ok((path, st))
}

/// What a verifier expects the approval to cover; `None` means not checked.
#[derive(Debug, Clone, Default)]
pub struct Expect {
    pub action: Option<String>,
    pub project: Option<String>,
    pub target: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
}

/// Admit a record once. The nonce is consumed only after every other check
/// passed.
pub fn verify(body: &str, expect: &Expect, now: DateTime<Utc>) -> Result<Statement, Refusal> {
    let (text, armored) = split_record(body).map_err(|e| refuse("malformed", e))?;
    let st = Statement::parse(&text).map_err(|e| refuse("malformed", e))?;
    let verifier = Verifier::for_host();
    if !verifier.allowed_signers.is_file() {
        return Err(refuse(
            "not-enrolled",
            format!(
                "no enrolled approval key at {}, so no approval can be verified",
                verifier.allowed_signers.display()
            ),
        ));
    }
    verifier
        .verify(&text, &armored, PRINCIPAL)
        .map_err(|e| refuse("bad-signature", e))?;
    let checks: [(&str, &Option<String>, Option<&String>); 5] = [
        ("action", &expect.action, Some(&st.action)),
        ("project", &expect.project, Some(&st.project)),
        ("target", &expect.target, st.target.as_ref()),
        ("from", &expect.from, st.from.as_ref()),
        ("to", &expect.to, st.to.as_ref()),
    ];
    for (k, want, got) in checks {
        if let Some(w) = want
            && got != Some(w)
        {
            return Err(refuse(
                &format!("mismatch:{k}"),
                format!("the approval covers a different {k}"),
            ));
        }
    }
    if now >= st.expires {
        return Err(refuse("expired", "the approval has expired; ask again"));
    }
    let used = state_dir().join("used");
    std::fs::create_dir_all(&used).map_err(|e| refuse("io", format!("{}: {e}", used.display())))?;
    if !st.nonce.chars().all(|c| c.is_ascii_hexdigit()) || st.nonce.len() != 32 {
        return Err(refuse("malformed", "the nonce is not 128 bits of hex"));
    }
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(used.join(&st.nonce))
    {
        Ok(_) => Ok(st),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Err(refuse(
            "nonce-used",
            "this approval was already used; each approval admits one action",
        )),
        Err(e) => Err(refuse("io", format!("nonce: {e}"))),
    }
}

const USAGE: &str = "usage: tillandsias approval request --action <kind> --project <owner/name> --detail <sentence> --key <private key> [--target <ref>] [--from <sha>] [--to <sha>] [--repo <path>] [--forge-instance <id>] [--forge-agent <name>] [--forge-project <label>] [--forge-launched <time>]\n       tillandsias approval verify <record> [--action <kind>] [--project <owner/name>] [--target <ref>] [--from <sha>] [--to <sha>]";

/// Positional arguments, and `--name value` pairs in order.
type Parsed = (Vec<String>, Vec<(String, String)>);

fn take_flags(args: &[String], known: &[&str]) -> Result<Parsed, String> {
    let mut pos = Vec::new();
    let mut flags = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if let Some(name) = a.strip_prefix("--") {
            if !known.contains(&name) {
                return Err(format!("unknown option --{name}"));
            }
            let v = args
                .get(i + 1)
                .ok_or_else(|| format!("--{name} needs a value"))?;
            flags.push((name.to_string(), v.clone()));
            i += 2;
        } else {
            pos.push(a.clone());
            i += 1;
        }
    }
    Ok((pos, flags))
}

fn flag(flags: &[(String, String)], k: &str) -> Option<String> {
    flags
        .iter()
        .rev()
        .find(|(n, _)| n == k)
        .map(|(_, v)| v.clone())
}

fn print_refusal(verb: &str, r: &Refusal) -> i32 {
    println!("refused:approval-{verb}:{}", r.code);
    eprintln!("  why: {}", r.why);
    1
}

/// `tillandsias approval request|verify ...`. Exit 0 on success, 1 on a
/// refusal, 2 on a usage error.
pub fn run_cli(args: &[String]) -> i32 {
    let Some(verb) = args.first() else {
        eprintln!("{USAGE}");
        return 2;
    };
    match verb.as_str() {
        "request" => {
            let known = [
                "action",
                "project",
                "target",
                "from",
                "to",
                "detail",
                "key",
                "repo",
                "forge-instance",
                "forge-agent",
                "forge-project",
                "forge-launched",
            ];
            let (pos, flags) = match take_flags(&args[1..], &known) {
                Ok(x) => x,
                Err(e) => {
                    eprintln!("approval request: {e}\n{USAGE}");
                    return 2;
                }
            };
            let (Some(action), Some(project), Some(detail), Some(key)) = (
                flag(&flags, "action"),
                flag(&flags, "project"),
                flag(&flags, "detail"),
                flag(&flags, "key"),
            ) else {
                eprintln!(
                    "approval request: --action, --project, --detail and --key are required\n{USAGE}"
                );
                return 2;
            };
            if !pos.is_empty() {
                eprintln!("approval request: unexpected argument\n{USAGE}");
                return 2;
            }
            let req = Request {
                action,
                project,
                target: flag(&flags, "target"),
                from: flag(&flags, "from"),
                to: flag(&flags, "to"),
                detail,
                forge_instance: flag(&flags, "forge-instance"),
                forge_agent: flag(&flags, "forge-agent"),
                forge_project: flag(&flags, "forge-project"),
                forge_launched: flag(&flags, "forge-launched"),
                key: PathBuf::from(key),
                repo: flag(&flags, "repo").map(PathBuf::from),
            };
            match request(&req, Utc::now()) {
                Ok((path, st)) => {
                    println!("ok:approval-request:{}", path.display());
                    println!("trailer: {}", approved_by_trailer(&st.host));
                    println!("strength: {}", st.strength.as_str());
                    println!("expires: {}", stamp(&st.expires));
                    0
                }
                Err(r) => print_refusal("request", &r),
            }
        }
        "verify" => {
            let known = ["action", "project", "target", "from", "to"];
            let (pos, flags) = match take_flags(&args[1..], &known) {
                Ok(x) => x,
                Err(e) => {
                    eprintln!("approval verify: {e}\n{USAGE}");
                    return 2;
                }
            };
            let [record] = pos.as_slice() else {
                eprintln!("approval verify: name exactly one record\n{USAGE}");
                return 2;
            };
            let body = match std::fs::read_to_string(Path::new(record)) {
                Ok(b) => b,
                Err(e) => {
                    return print_refusal("verify", &refuse("no-record", format!("{record}: {e}")));
                }
            };
            let expect = Expect {
                action: flag(&flags, "action"),
                project: flag(&flags, "project"),
                target: flag(&flags, "target"),
                from: flag(&flags, "from"),
                to: flag(&flags, "to"),
            };
            match verify(&body, &expect, Utc::now()) {
                Ok(st) => {
                    println!("ok:approval-verify:{}:{}", st.action, st.host);
                    0
                }
                Err(r) => print_refusal("verify", &r),
            }
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Statement {
        let issued = parse_stamp("2026-11-11T01:02Z").unwrap();
        Statement {
            action: "merge-into-integration".into(),
            project: "8007342/tillandsias".into(),
            target: Some("refs/heads/linux-next".into()),
            from: Some("a".repeat(40)),
            to: Some("b".repeat(40)),
            detail: "Merge work/1879-5jkt into linux-next".into(),
            host: "kghijklmnop".into(),
            forge_instance: None,
            forge_agent: None,
            forge_project: None,
            forge_launched: None,
            strength: Strength::SoftwarePassword,
            nonce: "0".repeat(32),
            issued,
            expires: issued + Duration::minutes(LIFETIME_MINUTES),
        }
    }

    #[test]
    fn a_statement_round_trips_and_a_reordered_one_is_refused() {
        let st = sample();
        let t = st.text();
        assert!(t.starts_with("tillandsias-approval v1\naction: merge-into-integration\n"));
        assert!(t.ends_with("expires: 2026-11-11T01:12Z\n"));
        assert_eq!(Statement::parse(&t).unwrap(), st);
        let swapped = t.replace(
            "action: merge-into-integration\nproject: 8007342/tillandsias\n",
            "project: 8007342/tillandsias\naction: merge-into-integration\n",
        );
        assert!(Statement::parse(&swapped).is_err());
        assert!(Statement::parse(&t.replace("\n", "\n\n")).is_err());
    }

    #[test]
    fn personal_data_is_named_and_plain_ref_text_is_not() {
        assert_eq!(
            personal_data("Merge /home/x/p", None),
            Some("a home directory path")
        );
        assert_eq!(
            personal_data("C:\\Users\\x\\p", None),
            Some("a home directory path")
        );
        assert_eq!(
            personal_data("for someone@example.org", None),
            Some("an email address")
        );
        assert_eq!(
            personal_data("built on yoga today", Some("yoga.local")),
            Some("this host's name")
        );
        assert_eq!(
            personal_data("Merge work/1879-5jkt into linux-next", Some("yoga")),
            None
        );
        // `@` in a ref spelling is not an email.
        assert_eq!(personal_data("HEAD@{1}", None), None);
    }

    #[test]
    fn the_enrolment_id_and_sentences_never_read_as_a_hash() {
        let id = enrolment_id("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq0 c");
        assert_eq!(id.len(), 11);
        assert!(!has_hex_run(&id));
        assert_eq!(
            id,
            enrolment_id("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq0 other-comment")
        );
        assert_eq!(
            note_sentence("merge-into-integration", Some("refs/heads/linux-next")).unwrap(),
            "The operator approved merging into linux-next."
        );
        let s = note_sentence("merge-into-integration", Some("refs/heads/deadbeefcafe")).unwrap();
        assert!(!has_hex_run(&s), "{s}");
        assert!(note_sentence("rm-rf", None).is_none());
        assert_eq!(
            approved_by_trailer(&id),
            format!("Approved-by: operator ({id})")
        );
    }

    #[test]
    fn a_record_splits_into_its_statement_and_signature() {
        let st = sample().text();
        let sig = "-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n";
        let body = note_body("The operator approved merging into linux-next.", &st, sig);
        let (t, s) = split_record(&body).unwrap();
        assert_eq!(t, st);
        assert_eq!(s, sig);
        assert!(split_record("no statement").is_err());
    }
}
