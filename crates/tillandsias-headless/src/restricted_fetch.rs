//! The restricted-weights fetch (order 2068-ypgq): a row of
//! images/models/licence-register-restricted.tsv is downloaded only after the
//! licence gate admits it for the requesting project AND the user said yes to
//! this download with a single-use consent token, through the model-hubs
//! egress tier, verified by suffix and sha256, into the shared model cache at
//! `<models_dir>/<subdir>/<file>`, which a studio mounts read-only.
//!
//! @trace order:2068-ypgq, order:1956-ecpb, order:2055-d9sa
//!
//! Refusals, in order, before any byte moves:
//! - `model_refused`: a file outside `ALLOWED_SUFFIXES` (.safetensors, .gguf;
//!   a pickle is never fetched or loaded, coordinator ruling 2026-11-10), an
//!   unsafe path, or an artefact matching no restricted row;
//! - `model_cache_volatile`: the cache is on tmpfs;
//! - the row's own gate: `licence_acknowledgement_required` (no matching,
//!   verifying acknowledgement for this project), `licence_text_unpinned`,
//!   `licence_forbids_use`, `model_refused` (gated);
//! - `consent_required` (an `Ok` result carrying the offer): files are missing
//!   and no live token for exactly this lane, request and file set was given.
//!
//! A file whose sha256 differs from the register is discarded
//! (`model_digest_mismatch`) and leaves nothing in the cache.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::imagegen_consent::{self, Refusal};
use crate::imagegen_models::{
    ALLOWED_SUFFIXES, FetchEvent, FileLock, ModelFile, Transport, is_volatile, sha256_file,
};
use crate::licence_consent::{self, GateRefusal, RestrictedArtefact, Verifier};

/// Where the gate reads: the restricted register, the project's
/// acknowledgement records, and the host's enrolled signers.
pub struct Gate<'a> {
    pub register: &'a str,
    pub ack_dir: &'a Path,
    pub verifier: &'a Verifier,
}

/// Who asks, and with which token.
pub struct Ask<'a> {
    pub project: &'a str,
    /// `imagegen_consent::lane_key(project, instance)`.
    pub lane: &'a str,
    /// What the token is bound to besides the lane: the tool's request hash.
    pub request: &'a str,
    pub token: Option<&'a str>,
}

/// The outcome of a fetch that was not refused.
#[derive(Debug, Clone, PartialEq)]
pub enum Fetch {
    /// Every file is in the cache and verified; one path per row, in order.
    Ready {
        paths: Vec<PathBuf>,
        /// One acknowledgement id per row, for the provenance `consent` field.
        consent: Vec<String>,
    },
    /// Files are missing and the user has not said yes to this download.
    /// Nothing was fetched.
    ConsentRequired(Value),
}

/// Where a row lives in the cache: `<models_dir>/<tier>/<file>`, keeping the
/// row's relative path (studio_key reads `<models>/corridorkey/weights/...`).
pub fn dest_for(models_dir: &Path, m: &ModelFile) -> PathBuf {
    models_dir.join(&m.tier).join(&m.file)
}

fn sidecar_for(dest: &Path) -> PathBuf {
    let name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download");
    dest.with_file_name(format!("{name}.sha256"))
}

/// Usable only when the size equals the pin AND the sidecar written after a
/// verified fetch names the pinned digest.
fn cached_and_verified(dest: &Path, m: &ModelFile) -> bool {
    fs::metadata(dest).is_ok_and(|md| md.is_file() && md.len() == m.bytes)
        && fs::read_to_string(sidecar_for(dest)).is_ok_and(|s| s.trim() == m.sha256)
}

fn safe_relative(p: &str) -> bool {
    !p.is_empty()
        && !p.starts_with('/')
        && p.split('/').all(|c| !c.is_empty() && c != "." && c != "..")
}

/// The shape checks that need no register: the suffix list and the paths.
fn refuse_shape(m: &ModelFile) -> Result<(), String> {
    if !ALLOWED_SUFFIXES.iter().any(|s| m.file.ends_with(s)) {
        return Err(format!(
            "model_refused: {} is not one of {}; a pickle executes code when loaded, so it is never fetched. \
             Convert it to safetensors and register the converted file.",
            m.label(),
            ALLOWED_SUFFIXES.join(", ")
        ));
    }
    if !safe_relative(&m.file) || !safe_relative(&m.tier) {
        return Err(format!(
            "model_refused: {} (cache dir {}) is not a plain relative path",
            m.label(),
            m.tier
        ));
    }
    Ok(())
}

fn artefact(m: &ModelFile) -> RestrictedArtefact {
    RestrictedArtefact {
        licence: m.licence.clone(),
        repo: m.repo.clone(),
        revision: m.revision.clone(),
        file: m.file.clone(),
        sha256: m.sha256.clone(),
    }
}

fn consent_required(offer: Value, refusal: Refusal) -> Value {
    json!({
        "status": "consent_required",
        "reason": match refusal {
            Refusal::Missing => "these licensed weights must be downloaded first, which needs the user's yes",
            Refusal::Unknown => "that consent_token was already used, expired or never issued",
            Refusal::Mismatch => "that consent_token was issued for a different download",
        },
        "offer": offer,
        "ran": false,
    })
}

/// The fetch against the shipped register, this host's acknowledgement copy
/// and signers, the shared model cache and the model-hubs tier.
pub fn fetch_restricted(
    ask: &Ask,
    rows: &[ModelFile],
    on_event: &mut dyn FnMut(FetchEvent),
) -> Result<Fetch, String> {
    let ack_dir = licence_consent::project_acknowledgement_dir(ask.project);
    let verifier = Verifier::for_host();
    fetch_restricted_in(
        &Gate {
            register: licence_consent::restricted_register_tsv(),
            ack_dir: &ack_dir,
            verifier: &verifier,
        },
        &crate::imagegen_models::models_dir(),
        &crate::imagegen_models::ProxyTransport::model_hubs_for_this_build(),
        ask,
        rows,
        on_event,
    )
}

/// [`fetch_restricted`] against an explicit gate, cache and transport.
pub fn fetch_restricted_in(
    gate: &Gate,
    models_dir: &Path,
    transport: &dyn Transport,
    ask: &Ask,
    rows: &[ModelFile],
    on_event: &mut dyn FnMut(FetchEvent),
) -> Result<Fetch, String> {
    if rows.is_empty() {
        return Err("model_refused: no file named (nothing to fetch)".into());
    }
    for m in rows {
        refuse_shape(m)?;
    }
    if is_volatile(models_dir) {
        return Err(format!(
            "model_cache_volatile: {} is on tmpfs or ramfs; model weights are never kept in RAM. \
             Point XDG_CACHE_HOME at a disk-backed directory.",
            models_dir.display()
        ));
    }
    let artefacts: Vec<RestrictedArtefact> = rows.iter().map(artefact).collect();
    let consent = licence_consent::admit_artefacts_in(
        gate.register,
        ask.project,
        &artefacts,
        gate.ack_dir,
        gate.verifier,
    )
    .map_err(|r| match r {
        GateRefusal::Unmatched(e) => format!("model_refused: {e}"),
        GateRefusal::Row(e) => format!("{e} Nothing was fetched."),
    })?;

    let missing: Vec<&ModelFile> = rows
        .iter()
        .filter(|m| !cached_and_verified(&dest_for(models_dir, m), m))
        .collect();
    if !missing.is_empty() {
        let shas: Vec<String> = missing.iter().map(|m| m.sha256.clone()).collect();
        let subject = imagegen_consent::restricted_subject(&shas);
        if let Err(refusal) =
            imagegen_consent::redeem_restricted(ask.token, ask.lane, &subject, ask.request)
        {
            let bytes = missing.iter().map(|m| m.bytes).sum();
            let offer = imagegen_consent::offer_restricted(ask.lane, ask.request, &subject, bytes);
            return Ok(Fetch::ConsentRequired(consent_required(offer, refusal)));
        }
    }

    for m in &missing {
        fetch_one(models_dir, transport, m, on_event)?;
    }
    Ok(Fetch::Ready {
        paths: rows.iter().map(|m| dest_for(models_dir, m)).collect(),
        consent,
    })
}

fn fetch_one(
    models_dir: &Path,
    transport: &dyn Transport,
    m: &ModelFile,
    on_event: &mut dyn FnMut(FetchEvent),
) -> Result<(), String> {
    let dest = dest_for(models_dir, m);
    let dir = dest.parent().unwrap_or(models_dir).to_path_buf();
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download")
        .to_string();
    let _lock = FileLock::acquire(&dir.join(format!(".{name}.lock")))?;
    if cached_and_verified(&dest, m) {
        return Ok(());
    }
    let part = dir.join(format!("{name}.part"));
    let label = m.label();
    on_event(FetchEvent::Started {
        model: label.clone(),
        bytes: m.bytes,
    });
    transport
        .fetch(&m.url(), &part, &mut |p| {
            on_event(FetchEvent::Percent {
                model: label.clone(),
                percent: p,
            })
        })
        .map_err(|e| format!("model_fetch_failed: {label}: {e}"))?;
    let digest = match sha256_file(&part) {
        Ok(d) => d,
        Err(e) => {
            let _ = fs::remove_file(&part);
            return Err(format!("model_fetch_failed: {label}: {e}"));
        }
    };
    if digest != m.sha256 {
        let _ = fs::remove_file(&part);
        return Err(format!(
            "model_digest_mismatch: {label} sha256 {digest} differs from the register's {}; the file was discarded",
            m.sha256
        ));
    }
    fs::rename(&part, &dest).map_err(|e| format!("{}: {e}", dest.display()))?;
    let mut sidecar =
        fs::File::create(sidecar_for(&dest)).map_err(|e| format!("{}: {e}", dir.display()))?;
    let _ = writeln!(sidecar, "{}", m.sha256);
    on_event(FetchEvent::Verified { model: label });
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::licence_consent::Acknowledgement;
    use crate::licence_consent::tests::{disk_scratch, enrol, sign};
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use std::io::{BufRead, BufReader, Read};
    use std::net::{TcpListener, TcpStream};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};

    const REV: &str = "1111111111111111111111111111111111111111";
    const LICENCE: &str = "cc-by-nc-sa-4.0";
    const LICENCE_HASH: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    fn hex(b: &[u8]) -> String {
        format!("{:x}", Sha256::digest(b))
    }

    /// A stand-in Hugging Face: `GET /<repo>/resolve/<rev>/<file>` answers the
    /// bytes it was given, anything else 404. Counts every request.
    pub(crate) struct Hub {
        pub(crate) port: u16,
        pub(crate) hits: Arc<AtomicUsize>,
    }

    pub(crate) fn hub(files: HashMap<String, Vec<u8>>) -> Hub {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        std::thread::spawn(move || {
            for s in l.incoming().flatten() {
                h.fetch_add(1, SeqCst);
                let mut r = BufReader::new(s.try_clone().unwrap());
                let mut line = String::new();
                let _ = r.read_line(&mut line);
                loop {
                    let mut hdr = String::new();
                    if r.read_line(&mut hdr).unwrap_or(0) == 0 || hdr == "\r\n" {
                        break;
                    }
                }
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                let mut s = s;
                match files.get(&path) {
                    Some(b) => {
                        let _ = write!(s, "HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n", b.len());
                        let _ = s.write_all(b);
                    }
                    None => {
                        let _ = s.write_all(b"HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                    }
                }
            }
        });
        Hub { port, hits }
    }

    /// Moves the bytes of the pinned URL from the stand-in hub, as curl would
    /// through the tier port; verifying is the fetcher's job, not this one's.
    pub(crate) struct HubTransport {
        pub(crate) port: u16,
    }
    impl Transport for HubTransport {
        fn fetch(&self, url: &str, dest: &Path, on: &mut dyn FnMut(u8)) -> Result<(), String> {
            let path = url
                .strip_prefix("https://huggingface.co")
                .ok_or_else(|| format!("not a hub url: {url}"))?;
            let mut s = TcpStream::connect(("127.0.0.1", self.port)).map_err(|e| e.to_string())?;
            write!(s, "GET {path} HTTP/1.0\r\nHost: huggingface.co\r\n\r\n")
                .map_err(|e| e.to_string())?;
            let mut all = Vec::new();
            s.read_to_end(&mut all).map_err(|e| e.to_string())?;
            let at = all
                .windows(4)
                .position(|w| w == b"\r\n\r\n")
                .ok_or("no header end")?;
            if !all.starts_with(b"HTTP/1.0 200") {
                return Err(format!(
                    "hub answered {}",
                    String::from_utf8_lossy(&all[..at])
                ));
            }
            fs::write(dest, &all[at + 4..]).map_err(|e| e.to_string())?;
            on(100);
            Ok(())
        }
    }

    fn row(tier: &str, repo: &str, file: &str, bytes: &[u8]) -> ModelFile {
        ModelFile {
            tier: tier.into(),
            role: "studio:fixture".into(),
            repo: repo.into(),
            revision: REV.into(),
            file: file.into(),
            sha256: hex(bytes),
            bytes: bytes.len() as u64,
            licence: LICENCE.into(),
        }
    }

    fn register_line(m: &ModelFile) -> String {
        format!(
            "fixture\t{}\t{}\t{}\t{}\t{LICENCE}\tfalse\thttps://example.invalid/card\tattribution{{fixture}};share-alike;non-commercial\t{LICENCE_HASH}\n",
            m.repo, m.revision, m.file, m.sha256
        )
    }

    fn ack(repos: &[&str], scope: &str) -> Acknowledgement {
        Acknowledgement {
            licence: LICENCE.into(),
            licence_sha256: LICENCE_HASH.into(),
            covers: repos.iter().map(|r| r.to_string()).collect(),
            grantor: "operator".into(),
            scope: scope.into(),
            r#use: "non-sale".into(),
            expiry: "standing".into(),
            signed_at: "2026-11-10T00:00:00Z".into(),
            strength: "software-password".into(),
            host: "fixture-host".into(),
            signature: String::new(),
        }
    }

    pub(crate) fn files_under(dir: &Path) -> Vec<String> {
        let mut out = Vec::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            for e in fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else if !p.file_name().unwrap().to_string_lossy().starts_with('.') {
                    out.push(p.strip_prefix(dir).unwrap().display().to_string());
                }
            }
        }
        out.sort();
        out
    }

    /// 2068-ypgq verifiable closure: refused without the acknowledgement,
    /// refused without the token, fetched and hash-verified with both, refused
    /// on a wrong hash or a .th suffix; and the layout is the one studio_key
    /// reads. Pre-fix: FAILS, no restricted fetch exists.
    #[test]
    fn a_restricted_row_is_fetched_only_with_its_acknowledgement_and_a_live_token() {
        let dir = disk_scratch("restricted-fetch");
        let (key, signers) = enrol(&dir, "operator");
        let verifier = Verifier::new(&signers);
        let models = dir.join("models");
        fs::create_dir_all(&models).unwrap();

        let good = b"safetensors bytes for the separation weights".to_vec();
        let other = b"the bytes the hub actually serves for the bad pin".to_vec();
        let th = b"PK\x03\x04 a torch pickle".to_vec();
        let sep = row(
            "demucs",
            "fixture/sep-weights",
            "htdemucs.safetensors",
            &good,
        );
        // Registered under a hash the hub's bytes will not match.
        let mut badpin = row("demucs", "fixture/bad-pin", "bad.safetensors", &good);
        badpin.sha256 = hex(b"what the register expects");
        let pickle = row("demucs", "fixture/sep-weights", "htdemucs.th", &th);
        // A studio_key-shaped row: nested path under the corridorkey subdir.
        let ck = row(
            crate::studio_key::CACHE_SUBDIR,
            "fixture/ck",
            "weights/corridorkey_v2.safetensors",
            &good,
        );
        let mut served = HashMap::new();
        for (m, b) in [
            (&sep, &good),
            (&badpin, &other),
            (&pickle, &th),
            (&ck, &good),
        ] {
            served.insert(
                format!("/{}/resolve/{}/{}", m.repo, m.revision, m.file),
                b.clone(),
            );
        }
        let hub = hub(served);
        let transport = HubTransport { port: hub.port };
        let register = format!(
            "#name\trepo\trevision\tfile\tsha256\tspdx\tgated\tcard\tobligations\tlicence_sha256\n{}{}{}{}",
            register_line(&sep),
            register_line(&badpin),
            register_line(&pickle),
            register_line(&ck)
        );
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let gate = Gate {
            register: &register,
            ack_dir: &acks,
            verifier: &verifier,
        };
        let mut ev = |_: FetchEvent| {};
        // The lane is the key image.generate's tokens are bound to.
        assert_eq!(imagegen_consent::lane_key("sep-proj", "a"), "sep-proj/a");
        fn ask<'a>(request: &'a str, token: Option<&'a str>) -> Ask<'a> {
            Ask {
                project: "sep-proj",
                lane: "sep-proj/a",
                request,
                token,
            }
        }

        // 1. No acknowledgement: refused by name, nothing fetched.
        let err = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap_err();
        assert!(
            err.starts_with("licence_acknowledgement_required:"),
            "{err}"
        );
        assert!(err.contains("accept-licence"), "{err}");
        assert_eq!(hub.hits.load(SeqCst), 0);
        assert!(
            files_under(&models).is_empty(),
            "{:?}",
            files_under(&models)
        );

        // 1b. An acknowledgement for ANOTHER project does not cover this one.
        let theirs = sign(
            &dir,
            &key,
            ack(&["fixture/sep-weights"], "project:other-proj"),
        );
        fs::write(acks.join("theirs.yaml"), theirs.to_yaml()).unwrap();
        let err = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap_err();
        assert!(
            err.starts_with("licence_acknowledgement_required:"),
            "{err}"
        );
        assert!(err.contains("project:other-proj"), "{err}");
        assert_eq!(hub.hits.load(SeqCst), 0);
        fs::remove_file(acks.join("theirs.yaml")).unwrap();

        // With this project's acknowledgement (covering every fixture repo).
        let mine = sign(
            &dir,
            &key,
            ack(
                &["fixture/sep-weights", "fixture/bad-pin", "fixture/ck"],
                "project:sep-proj",
            ),
        );
        fs::write(acks.join("mine.yaml"), mine.to_yaml()).unwrap();

        // 2. Acknowledged, no token: consent_required with an offer, nothing fetched.
        let out = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap();
        let Fetch::ConsentRequired(v) = out else {
            panic!("want consent_required, got {out:?}")
        };
        assert_eq!(v["status"], "consent_required", "{v}");
        assert_eq!(v["ran"], false, "{v}");
        let token = v["offer"]["consent_token"].as_str().unwrap().to_string();
        assert_eq!(token.len(), 32, "{v}");
        assert_eq!(v["offer"]["download_bytes"], good.len() as u64, "{v}");
        assert_eq!(hub.hits.load(SeqCst), 0);
        assert!(files_under(&models).is_empty());

        // 2b. A token for another request does not admit this one (and is spent).
        let other_req = Ask {
            request: "req-2",
            token: Some(token.as_str()),
            ..ask("req-1", None)
        };
        let out = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &other_req,
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap();
        assert!(
            matches!(out, Fetch::ConsentRequired(ref v) if v["reason"].as_str().unwrap().contains("different")),
            "{out:?}"
        );
        assert_eq!(hub.hits.load(SeqCst), 0);

        // 3. Acknowledged + a live token: fetched through the transport and verified.
        let Fetch::ConsentRequired(v) = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap() else {
            panic!("want a fresh offer")
        };
        let t = v["offer"]["consent_token"].as_str().unwrap().to_string();
        let out = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", Some(t.as_str())),
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap();
        let Fetch::Ready { paths, consent } = out else {
            panic!("want ready, got {out:?}")
        };
        assert_eq!(paths, vec![models.join("demucs/htdemucs.safetensors")]);
        assert_eq!(consent, vec!["mine".to_string()]);
        assert_eq!(fs::read(&paths[0]).unwrap(), good);
        assert_eq!(hex(&fs::read(&paths[0]).unwrap()), sep.sha256);
        assert_eq!(hub.hits.load(SeqCst), 1);

        // 3b. The token was single use; the cached, verified file needs none.
        let out = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", Some(t.as_str())),
            std::slice::from_ref(&sep),
            &mut ev,
        )
        .unwrap();
        assert!(matches!(out, Fetch::Ready { .. }), "{out:?}");
        assert_eq!(
            hub.hits.load(SeqCst),
            1,
            "a cached file is not fetched again"
        );
        let out = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", Some(t.as_str())),
            std::slice::from_ref(&ck),
            &mut ev,
        )
        .unwrap();
        assert!(
            matches!(out, Fetch::ConsentRequired(ref v) if v["reason"].as_str().unwrap().contains("already used")),
            "{out:?}"
        );
        assert_eq!(hub.hits.load(SeqCst), 1);

        // 4. A sha256 mismatch is discarded and leaves no file.
        let before = files_under(&models);
        let Fetch::ConsentRequired(v) = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&badpin),
            &mut ev,
        )
        .unwrap() else {
            panic!("want an offer")
        };
        let t2 = v["offer"]["consent_token"].as_str().unwrap().to_string();
        let err = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", Some(t2.as_str())),
            std::slice::from_ref(&badpin),
            &mut ev,
        )
        .unwrap_err();
        assert!(err.starts_with("model_digest_mismatch:"), "{err}");
        assert_eq!(
            hub.hits.load(SeqCst),
            2,
            "the bad pin was fetched once, then discarded"
        );
        assert_eq!(
            files_under(&models),
            before,
            "nothing new is left in the cache"
        );

        // 5. A .th pickle is refused before the gate, the token or the hub.
        let err = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&pickle),
            &mut ev,
        )
        .unwrap_err();
        assert!(
            err.starts_with("model_refused:") && err.contains("htdemucs.th"),
            "{err}"
        );
        assert_eq!(hub.hits.load(SeqCst), 2);
        assert_eq!(files_under(&models), before);

        // 6. Criterion 3 (amended): the layout is the one studio_key reads.
        assert_eq!(
            crate::studio_key::missing_weights(&models, std::slice::from_ref(&ck)).len(),
            1,
            "premise: studio_key sees the CorridorKey-shaped row as missing before the fetch"
        );
        let Fetch::ConsentRequired(v) = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", None),
            std::slice::from_ref(&ck),
            &mut ev,
        )
        .unwrap() else {
            panic!("want an offer")
        };
        let t3 = v["offer"]["consent_token"].as_str().unwrap().to_string();
        let out = fetch_restricted_in(
            &gate,
            &models,
            &transport,
            &ask("req-1", Some(t3.as_str())),
            std::slice::from_ref(&ck),
            &mut ev,
        )
        .unwrap();
        assert!(matches!(out, Fetch::Ready { .. }), "{out:?}");
        assert!(
            crate::studio_key::missing_weights(&models, std::slice::from_ref(&ck)).is_empty(),
            "{:?}",
            files_under(&models)
        );

        let _ = fs::remove_dir_all(&dir);
    }

    /// The production transport is held to the model-hubs tier port, never
    /// the plain proxy.
    #[test]
    fn the_restricted_transport_goes_through_the_model_hubs_tier() {
        let t = crate::imagegen_models::ProxyTransport {
            image: "img:tag".into(),
            proxy_port: crate::imagegen_models::MODEL_HUBS_PORT,
            hf_auth: false,
        };
        let a = t.podman_args(
            "https://huggingface.co/x",
            Path::new("/c/models/demucs/f.part"),
        );
        let joined = a.join(" ");
        assert!(joined.contains("https_proxy=http://proxy:3134"), "{joined}");
        assert!(joined.contains("HTTPS_PROXY=http://proxy:3134"), "{joined}");
        assert!(!joined.contains(":3128"), "{joined}");
        assert_eq!(
            crate::imagegen_models::ProxyTransport::model_hubs_for_this_build().proxy_port,
            3134
        );
        // The port is the one the generated squid config gives the tier.
        let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../..");
        let conf = fs::read_to_string(root.join("images/proxy/tier-ports.conf")).unwrap();
        assert!(
            conf.contains("http_port 3134 ssl-bump name=tier_model_hubs"),
            "tier-ports.conf no longer serves model-hubs on 3134"
        );
    }
}
