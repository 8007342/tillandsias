// @trace order:1548-cii8, openspec/changes/fleet-wan-rendezvous/design.md (Decision 6)
//
//! `tillandsias fleet peers check [--peers DIR]`: the loud form of the checks
//! the peer directory reader (`msg_identity::PeerDirectory`) applies quietly.
//!
//! `plan/fleet/peers/<host>.yaml` is ONE record shared by two orders: 1506-32k5
//! writes `host`, `noise_pub`, `noise_fp`, `minted` and keeps every other key
//! on `--mint --rotate`; 1548-cii8 owns the full schema below. The checker
//! reuses the same helpers as the reader (`parse_static_hex`,
//! `static_fingerprint`) rather than restating them, and the fingerprint field
//! is `noise_fp` (the fleet-messaging delta still says `fp`; that conflict is
//! unresolved and no second name is added here).
//!
//! # Schema (every field required unless marked)
//!
//! | field | rule |
//! |---|---|
//! | `host` | canonical DNS label (`cloudflare_names::normalize_label` leaves it unchanged, so it is valid in `<host>.fleet.tlatoani.net`) and equals the file name |
//! | `announce_pub` | Ed25519 public key, 64 lowercase hex |
//! | `noise_pub` | X25519 public key, 64 lowercase hex |
//! | `noise_fp` | BLAKE2s-128 of the `noise_pub` bytes, 32 lowercase hex |
//! | `ssh_host_ca_pub`, `ssh_user_ca_pub` | OpenSSH public key line `<type> <base64> [comment]` |
//! | `class_declared`, `substrate` | non-empty string |
//! | `admitted` | mapping `{date: YYYY-MM-DD, by: <non-empty string>}` |
//! | `minted`, `lan_hints`, `mesh_ip`, others | optional, ignored here |
//!
//! No value anywhere in a record may contain an email address, and no two
//! records may share a `noise_pub`. `plan/fleet/owner.yaml` (the directory
//! above the peers directory), when present, is checked too: `github_user_id`
//! numeric, `cloudflare_user_sha256` and `salt` lowercase hex.

use std::path::{Path, PathBuf};

use serde_yaml::Value;
use tillandsias_secure_channel::{parse_static_hex, static_fingerprint};

use crate::cloudflare_names;

/// One refusal: the record it is about and a stable machine name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub subject: String,
    pub name: String,
}

impl Refusal {
    pub fn verdict(&self) -> String {
        format!("refused:fleet-peers:{}:{}", self.subject, self.name)
    }

    /// `(why, remedy)` for the refusal's kind (the part of the name before
    /// the first `:`).
    pub fn affordance(&self) -> (&'static str, &'static str) {
        let kind = self.name.split(':').next().unwrap_or("");
        match kind {
            "missing-field" => (
                "a peer needs every public key and attribute in its record to be trusted and reached",
                "add the field (see plan/fleet/README.md); `tillandsias --msg-serve --mint` writes the noise fields, `fleet enroll` the rest",
            ),
            "malformed-field" => (
                "the field is present but not in the shape its consumer parses",
                "rewrite it as plan/fleet/README.md specifies (lowercase hex keys, an OpenSSH public key line, YYYY-MM-DD)",
            ),
            "non-canonical-host" => (
                "the host label is also a DNS label in <host>.fleet.tlatoani.net and normalizes to something else",
                "use the lowercase [a-z0-9-] form named after `want:` as host and as the file name",
            ),
            "host-is-not-file-name" => (
                "the file name is the host's identity in the directory; a record filed under another name is ambiguous",
                "rename the file to <host>.yaml or correct `host`",
            ),
            "noise-fp-mismatch" => (
                "noise_fp is what a refused handshake prints; if it does not hash noise_pub the record names a different key than it carries",
                "re-run `tillandsias --msg-serve --mint --rotate` on that host, or restore the record it wrote",
            ),
            "email-in-field" => (
                "no account id or email may appear in a tree-visible record",
                "remove the address (an SSH key comment is the usual place) and land the record again",
            ),
            "duplicate-noise-pub-of" => (
                "two hosts claiming one key cannot be told apart by the handshake",
                "re-mint on the host that copied the other's record",
            ),
            "not-yaml" | "not-a-mapping" | "unreadable" => (
                "the record could not be read as a YAML mapping",
                "fix the file; a record is a flat mapping of the fields in plan/fleet/README.md",
            ),
            "no-records" => (
                "an empty directory proves nothing, so a check over it is refused rather than passed",
                "point --peers at a directory holding <host>.yaml records, or run from a checkout",
            ),
            _ => (
                "the record failed a schema check",
                "see plan/fleet/README.md",
            ),
        }
    }
}

#[derive(Debug, Default)]
pub struct Report {
    pub checked: usize,
    pub refusals: Vec<Refusal>,
}

/// The fingerprint check is skipped ONLY by the debug-build seam
/// TILLANDSIAS_FLEET_PEERS_LAX=1 (the mutation control of the fixture, which
/// proves its fp arm reaches the check). A release build never reads it.
fn lax_fp() -> bool {
    #[cfg(debug_assertions)]
    {
        std::env::var("TILLANDSIAS_FLEET_PEERS_LAX").as_deref() == Ok("1")
    }
    #[cfg(not(debug_assertions))]
    {
        false
    }
}

fn is_hex_len(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_ssh_pub(s: &str) -> bool {
    let mut it = s.split_whitespace();
    let (Some(ty), Some(b64)) = (it.next(), it.next()) else {
        return false;
    };
    (ty.starts_with("ssh-") || ty.starts_with("ecdsa-sha2-") || ty.starts_with("sk-"))
        && !b64.is_empty()
        && b64
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
}

fn is_date(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            _ => c.is_ascii_digit(),
        })
}

fn has_email(s: &str) -> bool {
    s.split_whitespace().any(|tok| {
        tok.find('@')
            .is_some_and(|p| p > 0 && tok[p + 1..].contains('.') && !tok[p + 1..].starts_with('.'))
    })
}

/// Every scalar string in the value, with its dotted path.
fn scalars(prefix: &str, v: &Value, out: &mut Vec<(String, String)>) {
    match v {
        Value::String(s) => out.push((prefix.to_string(), s.clone())),
        Value::Mapping(m) => {
            for (k, v) in m {
                let k = k.as_str().unwrap_or("?");
                let p = if prefix.is_empty() {
                    k.to_string()
                } else {
                    format!("{prefix}.{k}")
                };
                scalars(&p, v, out);
            }
        }
        Value::Sequence(s) => {
            for (i, v) in s.iter().enumerate() {
                scalars(&format!("{prefix}[{i}]"), v, out);
            }
        }
        _ => {}
    }
}

/// Look up a required string field; pushes `missing-field` / `malformed-field`.
fn req_str<'a>(v: &'a Value, k: &str, bad: &mut Vec<String>) -> Option<&'a str> {
    match v.get(k) {
        None | Some(Value::Null) => {
            bad.push(format!("missing-field:{k}"));
            None
        }
        Some(Value::String(s)) if !s.trim().is_empty() => Some(s),
        Some(_) => {
            bad.push(format!("malformed-field:{k}"));
            None
        }
    }
}

/// Check one record's parsed value. Returns its refusal names (empty = good)
/// and its `noise_pub` for the cross-record duplicate check.
fn check_record(stem: &str, v: &Value) -> (Vec<String>, Option<[u8; 32]>) {
    let mut bad: Vec<String> = Vec::new();
    let mut key = None;

    if let Some(host) = req_str(v, "host", &mut bad) {
        let canonical = cloudflare_names::normalize_label(host)
            .map(|l| l.as_str() == host)
            .unwrap_or(false);
        if !canonical {
            let want = cloudflare_names::normalize_label(host)
                .map(|l| l.as_str().to_string())
                .unwrap_or_else(|_| "<nothing usable>".into());
            bad.push(format!("non-canonical-host:{host}:want:{want}"));
        } else if host != stem {
            bad.push(format!("host-is-not-file-name:{host}"));
        }
    }
    if let Some(a) = req_str(v, "announce_pub", &mut bad)
        && !is_hex_len(a, 64)
    {
        bad.push("malformed-field:announce_pub".into());
    }
    if let Some(p) = req_str(v, "noise_pub", &mut bad) {
        match parse_static_hex(p) {
            Some(k) => key = Some(k),
            None => bad.push("malformed-field:noise_pub".into()),
        }
    }
    if let Some(fp) = req_str(v, "noise_fp", &mut bad) {
        if let Some(k) = key {
            if fp != static_fingerprint(&k) && !lax_fp() {
                bad.push("noise-fp-mismatch".into());
            }
        } else if !is_hex_len(fp, 32) {
            bad.push("malformed-field:noise_fp".into());
        }
    }
    for k in ["ssh_host_ca_pub", "ssh_user_ca_pub"] {
        if let Some(s) = req_str(v, k, &mut bad)
            && !is_ssh_pub(s)
        {
            bad.push(format!("malformed-field:{k}"));
        }
    }
    for k in ["class_declared", "substrate"] {
        req_str(v, k, &mut bad);
    }
    match v.get("admitted") {
        None | Some(Value::Null) => bad.push("missing-field:admitted".into()),
        Some(m @ Value::Mapping(_)) => {
            match m.get("date") {
                None | Some(Value::Null) => bad.push("missing-field:admitted.date".into()),
                // serde_yaml reads an unquoted 2026-10-03 as a string.
                Some(d) => {
                    if !d.as_str().is_some_and(is_date) {
                        bad.push("malformed-field:admitted.date".into());
                    }
                }
            }
            match m.get("by") {
                None | Some(Value::Null) => bad.push("missing-field:admitted.by".into()),
                Some(Value::String(s)) if !s.trim().is_empty() => {}
                Some(_) => bad.push("malformed-field:admitted.by".into()),
            }
        }
        Some(_) => bad.push("malformed-field:admitted".into()),
    }

    let mut all = Vec::new();
    scalars("", v, &mut all);
    for (path, s) in all {
        if has_email(&s) {
            bad.push(format!("email-in-field:{path}"));
        }
    }
    (bad, key)
}

fn read_mapping(path: &Path) -> Result<Value, &'static str> {
    let b = std::fs::read(path).map_err(|_| "unreadable")?;
    match serde_yaml::from_slice::<Value>(&b) {
        Ok(v @ Value::Mapping(_)) => Ok(v),
        Ok(_) => Err("not-a-mapping"),
        Err(_) => Err("not-yaml"),
    }
}

fn check_owner(path: &Path, rep: &mut Report) {
    rep.checked += 1;
    let v = match read_mapping(path) {
        Ok(v) => v,
        Err(w) => {
            rep.refusals.push(Refusal {
                subject: "owner".into(),
                name: w.into(),
            });
            return;
        }
    };
    let mut bad = Vec::new();
    // github_user_id is a number in YAML; a digit string is accepted too.
    match v.get("github_user_id") {
        None | Some(Value::Null) => bad.push("missing-field:github_user_id".to_string()),
        Some(Value::Number(n)) if n.is_u64() => {}
        Some(Value::String(s)) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {}
        Some(_) => bad.push("malformed-field:github_user_id".into()),
    }
    if let Some(s) = req_str(&v, "cloudflare_user_sha256", &mut bad)
        && !is_hex_len(s, 64)
    {
        bad.push("malformed-field:cloudflare_user_sha256".into());
    }
    if let Some(s) = req_str(&v, "salt", &mut bad)
        && (s.len() < 16 || !is_hex_len(s, s.len()))
    {
        bad.push("malformed-field:salt".into());
    }
    let mut all = Vec::new();
    scalars("", &v, &mut all);
    for (p, s) in all {
        if has_email(&s) {
            bad.push(format!("email-in-field:{p}"));
        }
    }
    for name in bad {
        rep.refusals.push(Refusal {
            subject: "owner".into(),
            name,
        });
    }
}

/// Check every `*.yaml` in `dir` (and `<dir>/../owner.yaml` when present).
pub fn check_dir(dir: &Path) -> Result<Report, String> {
    let rd = std::fs::read_dir(dir).map_err(|e| {
        format!(
            "refused:fleet-peers:peers-dir:{}:{}",
            dir.display(),
            e.kind()
        )
    })?;
    let mut files: Vec<PathBuf> = rd
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "yaml"))
        .collect();
    files.sort();
    let mut rep = Report::default();
    let mut seen: Vec<([u8; 32], String)> = Vec::new();
    for f in files {
        let stem = f
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        rep.checked += 1;
        let v = match read_mapping(&f) {
            Ok(v) => v,
            Err(w) => {
                rep.refusals.push(Refusal {
                    subject: stem,
                    name: w.into(),
                });
                continue;
            }
        };
        let (bad, key) = check_record(&stem, &v);
        let mut names = bad;
        if let (true, Some(k)) = (names.is_empty(), key) {
            if let Some((_, other)) = seen.iter().find(|(sk, _)| *sk == k) {
                names.push(format!("duplicate-noise-pub-of:{other}"));
            } else {
                seen.push((k, stem.clone()));
            }
        }
        for name in names {
            rep.refusals.push(Refusal {
                subject: stem.clone(),
                name,
            });
        }
    }
    if rep.checked == 0 {
        rep.refusals.push(Refusal {
            subject: "-".into(),
            name: "no-records".into(),
        });
    }
    if let Some(owner) = dir
        .parent()
        .map(|p| p.join("owner.yaml"))
        .filter(|p| p.is_file())
    {
        check_owner(&owner, &mut rep);
    }
    Ok(rep)
}

/// `tillandsias fleet peers check [--peers DIR]`. 0 ok, 1 refused, 2 usage.
/// `args` is everything after `fleet`.
pub fn run_cli(args: &[String]) -> i32 {
    if args.len() < 2 || args[0] != "peers" || args[1] != "check" {
        eprintln!("refused:fleet:usage:{}", args.join(" "));
        eprintln!("  why: the only fleet verb here is `fleet peers check [--peers DIR]`");
        eprintln!("  remedy: tillandsias fleet peers check [--peers DIR]");
        return 2;
    }
    let mut peers: Option<String> = None;
    let mut it = args[2..].iter();
    while let Some(a) = it.next() {
        match (a.as_str(), it.next()) {
            ("--peers", Some(v)) => peers = Some(v.clone()),
            _ => {
                eprintln!("refused:fleet:usage:{a}");
                eprintln!("  why: `fleet peers check` takes only --peers DIR");
                eprintln!("  remedy: tillandsias fleet peers check [--peers DIR]");
                return 2;
            }
        }
    }
    let dir = match crate::msg_identity::peers_dir(peers.as_deref()) {
        Ok(d) => d,
        Err(_) => {
            eprintln!("refused:fleet-peers:no-peers-dir");
            eprintln!("  why: the peer directory is the trust root and none was named");
            eprintln!(
                "  remedy: run from a checkout (./plan/fleet exists), or pass --peers <dir> / TILLANDSIAS_MSG_PEERS_DIR"
            );
            return 1;
        }
    };
    let rep = match check_dir(&dir) {
        Ok(r) => r,
        Err(why) => {
            eprintln!("{why}");
            eprintln!("  why: the peers directory could not be read");
            eprintln!("  remedy: pass --peers <dir> naming an existing directory");
            return 1;
        }
    };
    if rep.refusals.is_empty() {
        println!("ok:fleet-peers:{}-records", rep.checked);
        return 0;
    }
    for r in &rep.refusals {
        let (why, remedy) = r.affordance();
        eprintln!("{}", r.verdict());
        eprintln!("  why: {why}");
        eprintln!("  remedy: {remedy}");
    }
    eprintln!("refused:fleet-peers:{}-refusals", rep.refusals.len());
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "0101010101010101010101010101010101010101010101010101010101010101";

    fn good(host: &str) -> String {
        let k = parse_static_hex(KEY).unwrap();
        format!(
            "host: {host}\nannounce_pub: {KEY}\nnoise_pub: {KEY}\nnoise_fp: {}\n\
ssh_host_ca_pub: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGhvc3Q=\n\
ssh_user_ca_pub: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVzZXI=\n\
class_declared: laptop\nsubstrate: podman\nadmitted:\n  date: 2026-10-03\n  by: cloudflare-login\n",
            static_fingerprint(&k)
        )
    }

    fn names(stem: &str, body: &str) -> Vec<String> {
        check_record(stem, &serde_yaml::from_str(body).unwrap()).0
    }

    #[test]
    fn a_good_record_passes() {
        assert!(names("yoga", &good("yoga")).is_empty());
    }

    #[test]
    fn each_defect_has_one_named_refusal() {
        let g = good("yoga");
        let no_ca = g.replace("ssh_host_ca_pub:", "x_ca:");
        assert_eq!(names("yoga", &no_ca), vec!["missing-field:ssh_host_ca_pub"]);
        let fp = static_fingerprint(&parse_static_hex(KEY).unwrap());
        assert_eq!(
            names("yoga", &g.replace(&fp, &"0".repeat(32))),
            vec!["noise-fp-mismatch"]
        );
        assert_eq!(
            names("yoga", &g.replace("laptop", "me@example.com")),
            vec!["email-in-field:class_declared"]
        );
        assert_eq!(
            names("Yoga_Laptop", &good("Yoga_Laptop")),
            vec!["non-canonical-host:Yoga_Laptop:want:yoga-laptop"]
        );
        assert_eq!(
            names("other", &g),
            vec!["host-is-not-file-name:yoga".to_string()]
        );
    }

    #[test]
    fn malformed_shapes_are_refused() {
        let g = good("yoga");
        assert_eq!(
            names(
                "yoga",
                &g.replace("announce_pub: 0101", "announce_pub: ZZ01")
            ),
            vec!["malformed-field:announce_pub"]
        );
        assert_eq!(
            names("yoga", &g.replace("date: 2026-10-03", "date: yesterday")),
            vec!["malformed-field:admitted.date"]
        );
        assert_eq!(
            names(
                "yoga",
                &g.replace("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVzZXI=", "notakey")
            ),
            vec!["malformed-field:ssh_user_ca_pub"]
        );
    }

    #[test]
    fn email_detector_ignores_non_addresses() {
        assert!(has_email("ca for bob@example.com"));
        assert!(!has_email("ssh-ed25519 AAAA host"));
        assert!(!has_email("@handle"));
        assert!(!has_email("a@b"));
    }
}
