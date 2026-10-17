//! ORDER 1761-bvyn: install the preview CA into the operator's USER-SCOPE
//! browser trust stores, so a forge's https://www.<project>.localhost:18443/
//! opens with no certificate warning (operator ruling 2026-10-17:
//! "Automatic, user scope": no prompt, no menu item, removed by the
//! uninstaller). Never a system store (/etc/pki, update-ca-trust), and never
//! the enclave CA: only `preview_ca`'s, which is name-constrained to
//! `localhost`.
//!
//! The stores are NSS databases (`cert9.db`), Linux only:
//! - `~/.pki/nssdb`, read by Chrome and Chromium; created when absent if one of
//!   them is installed;
//! - `~/.var/app/<id>/.pki/nssdb` for an installed Chromium-family Flatpak
//!   (they persist `.pki` in their app directory), created when absent;
//! - every existing Firefox profile's own `cert9.db` (Firefox keeps one per
//!   profile and reads no shared store); a profile is never created.
//!
//! `certutil` (NSS tools) runs from the host when installed, otherwise from
//! the router image, which ships nss-tools for this (measured on lenovinha,
//! 2026-10-17: no certutil on the host or in any local image). Rootless podman
//! maps the container's root to the operator, so the files stay theirs.
//!
//! The outcome is recorded in `<preview-ca>/host-trust.json` so publish_local
//! reports `tls.host_trust` from a read-back of the stores, not "unknown".

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Chromium-family Flatpaks that persist `.pki/nssdb` in their app directory.
const CHROMIUM_FLATPAKS: &[&str] = &[
    "com.brave.Browser",
    "org.chromium.Chromium",
    "io.github.ungoogled_software.ungoogled_chromium",
    "com.google.Chrome",
    "com.microsoft.Edge",
    "com.vivaldi.Vivaldi",
    "com.opera.Opera",
];
/// Host binaries that read `~/.pki/nssdb`.
const CHROMIUM_BINARIES: &[&str] = &[
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "brave-browser",
    "microsoft-edge",
    "vivaldi",
];
/// Directories that hold Firefox profiles, relative to HOME.
const FIREFOX_PROFILE_ROOTS: &[&str] = &[
    ".mozilla/firefox",
    ".config/mozilla/firefox",
    ".var/app/org.mozilla.firefox/.mozilla/firefox",
    ".var/app/org.mozilla.firefox/config/mozilla/firefox",
    "snap/firefox/common/.mozilla/firefox",
];
pub(crate) const STATE_FILE: &str = "host-trust.json";

/// One NSS database the preview CA belongs in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Store {
    /// What a person would call it: "chrome", "flatpak:com.brave.Browser",
    /// "firefox:<profile dir>".
    pub label: String,
    pub db: PathBuf,
    /// Create the database when it does not exist yet.
    pub create: bool,
}

/// The user-scope stores under `home`. `on_path` answers whether a binary is
/// installed (a seam for the tests).
pub(crate) fn discover(home: &Path, on_path: &dyn Fn(&str) -> bool) -> Vec<Store> {
    let mut stores = Vec::new();
    let shared = home.join(".pki/nssdb");
    if shared.join("cert9.db").is_file() || CHROMIUM_BINARIES.iter().any(|b| on_path(b)) {
        stores.push(Store {
            label: "chrome".into(),
            db: shared,
            create: true,
        });
    }
    for id in CHROMIUM_FLATPAKS {
        let app = home.join(".var/app").join(id);
        if app.is_dir() {
            stores.push(Store {
                label: format!("flatpak:{id}"),
                db: app.join(".pki/nssdb"),
                create: true,
            });
        }
    }
    for root in FIREFOX_PROFILE_ROOTS {
        let Ok(entries) = std::fs::read_dir(home.join(root)) else {
            continue;
        };
        let mut profiles: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.join("cert9.db").is_file())
            .collect();
        profiles.sort();
        for profile in profiles {
            let name = profile
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("?")
                .to_string();
            stores.push(Store {
                label: format!("firefox:{name}"),
                db: profile,
                create: false,
            });
        }
    }
    stores
}

/// One certutil operation on one database.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Op {
    /// Create an empty database (no password, as Chrome does).
    Init,
    /// The PEM of the certificate under `preview_ca::NICKNAME`, if any.
    Show,
    /// Delete one certificate under the nickname.
    Delete,
    /// Add the preview CA as a trusted TLS issuer ("C,,").
    Add,
}

/// Runs `op` on `db` with `ca` as the certificate to add; returns whether
/// certutil succeeded and its stdout. A seam for the tests.
pub(crate) type Certutil<'a> = &'a dyn Fn(&Path, &Path, Op) -> Result<(bool, String), String>;

/// certutil's arguments for `op`, with `db` and `ca` as certutil will see them.
pub(crate) fn certutil_args(db: &str, ca: &str, op: Op) -> Vec<String> {
    let nick = crate::preview_ca::NICKNAME;
    let mut args = vec!["-d".to_string(), format!("sql:{db}")];
    let rest: Vec<&str> = match op {
        Op::Init => vec!["-N", "--empty-password"],
        Op::Show => vec!["-L", "-n", nick, "-a"],
        Op::Delete => vec!["-D", "-n", nick],
        // host-trust-ok: 1761-bvyn preview CA, name-constrained to DNS localhost (preview_ca::NAME_CONSTRAINTS)
        Op::Add => vec!["-A", "-t", "C,,", "-n", nick, "-i", ca],
    };
    args.extend(rest.into_iter().map(str::to_string));
    args
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Report {
    pub installed: Vec<String>,
    pub already: Vec<String>,
    pub failed: Vec<String>,
}

/// Normalised PEM body, so line endings and trailing blanks do not matter.
fn pem_body(pem: &str) -> String {
    pem.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Put exactly `ca` under the nickname in every store: kept where it is
/// already there, otherwise every older certificate under the nickname (a
/// previous preview CA) is deleted and `ca` added, then read back.
pub(crate) fn install(stores: &[Store], ca: &Path, certutil: Certutil) -> Report {
    let mut report = Report::default();
    let Ok(want) = std::fs::read_to_string(ca) else {
        report.failed = stores
            .iter()
            .map(|s| format!("{}: preview CA unreadable", s.label))
            .collect();
        return report;
    };
    let want = pem_body(&want);
    for store in stores {
        match install_one(store, ca, &want, certutil) {
            Ok(true) => report.installed.push(store.label.clone()),
            Ok(false) => report.already.push(store.label.clone()),
            Err(e) => report.failed.push(format!("{}: {e}", store.label)),
        }
    }
    report
}

fn install_one(store: &Store, ca: &Path, want: &str, certutil: Certutil) -> Result<bool, String> {
    if !store.db.join("cert9.db").is_file() {
        if !store.create {
            return Err("no cert9.db".into());
        }
        std::fs::create_dir_all(&store.db)
            .map_err(|e| format!("cannot create the database directory: {e}"))?;
        if !certutil(&store.db, ca, Op::Init)?.0 {
            return Err("certutil could not create the database".into());
        }
    }
    let shown = certutil(&store.db, ca, Op::Show)?;
    if shown.0 && pem_body(&shown.1) == want {
        return Ok(false);
    }
    remove_one(store, ca, certutil)?;
    if !certutil(&store.db, ca, Op::Add)?.0 {
        return Err("certutil could not add the preview CA".into());
    }
    let shown = certutil(&store.db, ca, Op::Show)?;
    if !(shown.0 && pem_body(&shown.1) == want) {
        return Err("the preview CA did not read back after the add".into());
    }
    Ok(true)
}

/// Delete every certificate under the nickname (at most 8: a bound, not a
/// count anyone expects to reach).
fn remove_one(store: &Store, ca: &Path, certutil: Certutil) -> Result<usize, String> {
    let mut removed = 0;
    while removed < 8 && certutil(&store.db, ca, Op::Show)?.0 {
        if !certutil(&store.db, ca, Op::Delete)?.0 {
            return Err("certutil could not delete an older preview CA".into());
        }
        removed += 1;
    }
    Ok(removed)
}

/// The uninstaller's half: remove the nickname from every existing store.
/// `installed` lists the stores it was removed from, `already` those that
/// did not hold it.
pub(crate) fn uninstall(stores: &[Store], ca: &Path, certutil: Certutil) -> Report {
    let mut report = Report::default();
    for store in stores.iter().filter(|s| s.db.join("cert9.db").is_file()) {
        match remove_one(store, ca, certutil) {
            Ok(0) => report.already.push(store.label.clone()),
            Ok(_) => report.installed.push(store.label.clone()),
            Err(e) => report.failed.push(format!("{}: {e}", store.label)),
        }
    }
    report
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Record `report` for the CA whose bytes are `ca_bytes`.
pub(crate) fn record(dir: &Path, ca_bytes: &[u8], report: &Report) {
    let value = json!({
        "ca_sha256": sha256_hex(ca_bytes),
        "stores": report.installed.iter().chain(&report.already).collect::<Vec<_>>(),
        "failed": report.failed,
        "ts": chrono::Utc::now().to_rfc3339(),
    });
    let _ = std::fs::write(dir.join(STATE_FILE), value.to_string());
}

/// What publish_local reports as `tls.host_trust` (the spec's enum), and why:
/// - "verified": the CA serving now read back from every store found;
/// - "untrusted": no user-scope store exists, or every store refused it;
/// - "unknown": no record for this CA yet (it is installed at launch, and
///   retried in the background), or only some stores took it.
pub(crate) fn state(dir: &Path) -> (&'static str, String) {
    let ca = std::fs::read(dir.join(crate::preview_ca::CRT)).unwrap_or_default();
    let record: Option<Value> = std::fs::read_to_string(dir.join(STATE_FILE))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());
    let Some(record) = record.filter(|r| !ca.is_empty() && r["ca_sha256"] == sha256_hex(&ca))
    else {
        return ("unknown", "The localhost-only preview CA is not in a browser trust store yet; Tillandsias installs it at user scope in the background.".into());
    };
    let list = |key: &str| -> Vec<String> {
        record[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect()
    };
    let (stores, failed) = (list("stores"), list("failed"));
    match (stores.is_empty(), failed.is_empty()) {
        (false, true) => ("verified", format!("The localhost-only preview CA is trusted at user scope by: {}.", stores.join(", "))),
        (false, false) => ("unknown", format!("Trusted by: {}. Not by: {}.", stores.join(", "), failed.join("; "))),
        (true, true) => ("untrusted", "No user-scope browser trust store was found (Chrome, Chromium-family Flatpaks, Firefox profiles).".into()),
        (true, false) => ("untrusted", format!("Every browser store refused the preview CA: {}.", failed.join("; "))),
    }
}

fn on_path(binary: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(binary).is_file()))
        .unwrap_or(false)
}

/// certutil on the host, else in the router image (this version's, then
/// `latest`). Bounded: 20 s per call.
fn real_certutil(db: &Path, ca: &Path, op: Op) -> Result<(bool, String), String> {
    let budget = Duration::from_secs(20);
    if on_path("certutil") {
        let args = certutil_args(&db.display().to_string(), &ca.display().to_string(), op);
        let out = std::process::Command::new("certutil")
            .args(&args)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("certutil did not start: {e}"))?;
        return Ok((
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        ));
    }
    let image = [
        // launch-images-ok: a probe for certutil, never a launch; it falls back
        // to :latest, and the install retries once a launch built the router.
        crate::versioned_image_tag("router", crate::VERSION.trim()),
        "localhost/tillandsias-router:latest".to_string(),
    ]
    .into_iter()
    .find(|image| {
        let mut cmd = crate::podman_command();
        cmd.args(["image", "exists", image]);
        cmd.output_bounded(budget)
            .map(|o| o.status.success())
            .unwrap_or(false)
    })
    .ok_or("no certutil on the host and the router image is not built yet")?;
    let mut args: Vec<String> = [
        "run",
        "--rm",
        "--network=none",
        "--security-opt",
        "label=disable",
        "--entrypoint",
        "certutil",
    ]
    .into_iter()
    .map(str::to_string)
    .collect();
    args.push("-v".into());
    args.push(format!("{}:/nssdb", db.display()));
    args.push("-v".into());
    args.push(format!("{}:/preview-ca.crt:ro", ca.display()));
    args.push(image);
    args.extend(certutil_args("/nssdb", "/preview-ca.crt", op));
    let mut cmd = crate::podman_command();
    cmd.args(
        args.iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .as_slice(),
    );
    let out = cmd
        .output_bounded(budget)
        .map_err(|e| format!("certutil in {}: {e}", "the router image"))?;
    Ok((
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    ))
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute())
}

/// Install the preview CA in `dir` into every user-scope store and record the
/// outcome. Silent unless debug; a failure is a warn line, never a prompt.
fn install_dir(dir: &Path, debug: bool) {
    let Some(home) = home() else {
        return;
    };
    let stores = discover(&home, &on_path);
    let ca = dir.join(crate::preview_ca::CRT);
    let report = install(&stores, &ca, &real_certutil);
    record(dir, &std::fs::read(&ca).unwrap_or_default(), &report);
    if !report.failed.is_empty() {
        eprintln!(
            "[tillandsias] warn:preview-ca-host-trust: {}",
            report.failed.join("; ")
        );
    } else if debug || !report.installed.is_empty() {
        eprintln!(
            "[tillandsias] ok:preview-ca-host-trust:installed={}:kept={}",
            report.installed.join(","),
            report.already.join(",")
        );
    }
}

#[cfg(feature = "tray")]
/// The launch step: ensure the preview CA (re-minting it inside the 60-day
/// margin, as the enclave CA is) and install it.
pub(crate) fn install_at_launch(debug: bool) {
    if !cfg!(target_os = "linux") {
        return;
    }
    match crate::preview_ca::ensure(crate::CERT_MIN_REMAINING_SECS) {
        Ok(dir) => install_dir(&dir, debug),
        Err(e) => eprintln!("[tillandsias] warn:preview-ca-unavailable: {e}"),
    }
}

/// Retry in the background when the CA serving now is not verified yet: on a
/// fresh machine the router image (certutil's fallback) is first built by a
/// publish, after launch tried. Never re-mints, never blocks the caller.
pub(crate) fn retry_in_background(debug: bool) {
    if !cfg!(target_os = "linux") {
        return;
    }
    let dir = crate::preview_ca::dir();
    if state(&dir).0 == "verified" {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("preview-ca-trust".into())
        .spawn(move || install_dir(&dir, debug));
}

/// `tillandsias --internal-remove-preview-trust`, run by scripts/uninstall.sh:
/// remove the nickname from every existing user-scope store. Exit 0 when
/// nothing is left behind (including when there was nothing to remove), 1
/// naming each store that refused.
pub(crate) fn remove_cli() -> i32 {
    let Some(home) = home() else {
        println!("ok:preview-ca-host-trust-removed:no-home");
        return 0;
    };
    let stores = discover(&home, &on_path);
    let report = uninstall(
        &stores,
        &crate::preview_ca::dir().join(crate::preview_ca::CRT),
        &real_certutil,
    );
    if report.failed.is_empty() {
        println!(
            "ok:preview-ca-host-trust-removed:{}",
            report.installed.join(",")
        );
        0
    } else {
        println!(
            "warn:preview-ca-host-trust-not-removed: {}",
            report.failed.join("; ")
        );
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    /// An in-memory certutil: each db holds a list of PEMs under the nickname.
    #[derive(Default)]
    struct FakeNss {
        dbs: RefCell<HashMap<PathBuf, Vec<String>>>,
        calls: RefCell<Vec<(String, Op)>>,
        refuse_add: Option<PathBuf>,
    }
    impl FakeNss {
        fn run(&self, db: &Path, ca: &Path, op: Op) -> Result<(bool, String), String> {
            self.calls.borrow_mut().push((db.display().to_string(), op));
            let mut dbs = self.dbs.borrow_mut();
            match op {
                Op::Init => {
                    std::fs::write(db.join("cert9.db"), b"").unwrap();
                    dbs.insert(db.to_path_buf(), Vec::new());
                    Ok((true, String::new()))
                }
                Op::Show => Ok(dbs
                    .get(db)
                    .and_then(|v| v.first())
                    .map_or((false, String::new()), |p| (true, p.clone()))),
                Op::Delete => Ok((
                    dbs.get_mut(db)
                        .map(|v| {
                            if v.is_empty() {
                                false
                            } else {
                                v.remove(0);
                                true
                            }
                        })
                        .unwrap_or(false),
                    String::new(),
                )),
                Op::Add if self.refuse_add.as_deref() == Some(db) => Ok((false, String::new())),
                Op::Add => {
                    dbs.entry(db.to_path_buf())
                        .or_default()
                        .push(std::fs::read_to_string(ca).unwrap());
                    Ok((true, String::new()))
                }
            }
        }
    }

    fn pem(dir: &Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        std::fs::write(
            &p,
            format!("-----BEGIN CERTIFICATE-----\n{body}\n-----END CERTIFICATE-----\n"),
        )
        .unwrap();
        p
    }

    #[test]
    fn discover_finds_chrome_flatpaks_and_existing_firefox_profiles_only() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        std::fs::create_dir_all(h.join(".var/app/com.brave.Browser")).unwrap();
        std::fs::create_dir_all(h.join(".var/app/org.gnome.Calculator")).unwrap();
        std::fs::create_dir_all(h.join(".mozilla/firefox/ab12.default-release")).unwrap();
        std::fs::write(
            h.join(".mozilla/firefox/ab12.default-release/cert9.db"),
            b"",
        )
        .unwrap();
        std::fs::create_dir_all(h.join(".mozilla/firefox/no-db-yet")).unwrap();
        let stores = discover(h, &|b| b == "google-chrome");
        let labels: Vec<_> = stores.iter().map(|s| s.label.as_str()).collect();
        assert_eq!(
            labels,
            [
                "chrome",
                "flatpak:com.brave.Browser",
                "firefox:ab12.default-release"
            ]
        );
        assert!(stores[0].create && stores[1].create && !stores[2].create);
        assert_eq!(
            stores[1].db,
            h.join(".var/app/com.brave.Browser/.pki/nssdb")
        );
        // No Chromium installed and no shared database: no chrome store.
        assert!(discover(h, &|_| false).iter().all(|s| s.label != "chrome"));
    }

    #[test]
    fn install_creates_adds_and_reads_back_then_keeps_on_the_next_launch() {
        let work = tempfile::tempdir().unwrap();
        let ca = pem(work.path(), "ca.crt", "AAAA");
        let stores = vec![Store {
            label: "chrome".into(),
            db: work.path().join("nssdb"),
            create: true,
        }];
        let nss = FakeNss::default();
        let run = |d: &Path, c: &Path, o: Op| nss.run(d, c, o);
        let first = install(&stores, &ca, &run);
        assert_eq!(first.installed, ["chrome"]);
        assert!(nss.calls.borrow().iter().any(|(_, o)| *o == Op::Init));
        let second = install(&stores, &ca, &run);
        assert_eq!(
            second.already,
            ["chrome"],
            "an identical CA is kept, not re-added"
        );
        assert_eq!(nss.dbs.borrow()[&work.path().join("nssdb")].len(), 1);
    }

    #[test]
    fn a_rotated_ca_replaces_every_older_one_under_the_nickname() {
        let work = tempfile::tempdir().unwrap();
        let old = pem(work.path(), "old.crt", "OLD");
        let new = pem(work.path(), "new.crt", "NEW");
        let stores = vec![Store {
            label: "chrome".into(),
            db: work.path().join("nssdb"),
            create: true,
        }];
        let nss = FakeNss::default();
        let run = |d: &Path, c: &Path, o: Op| nss.run(d, c, o);
        install(&stores, &old, &run);
        nss.dbs
            .borrow_mut()
            .get_mut(&work.path().join("nssdb"))
            .unwrap()
            .push("stray".into());
        assert_eq!(install(&stores, &new, &run).installed, ["chrome"]);
        let db = &nss.dbs.borrow()[&work.path().join("nssdb")];
        assert_eq!(db.len(), 1);
        assert!(db[0].contains("NEW"));
    }

    #[test]
    fn a_firefox_profile_is_never_created_and_a_refusal_is_named() {
        let work = tempfile::tempdir().unwrap();
        let ca = pem(work.path(), "ca.crt", "AAAA");
        std::fs::create_dir_all(work.path().join("chrome")).unwrap();
        let stores = vec![
            Store {
                label: "firefox:gone".into(),
                db: work.path().join("gone"),
                create: false,
            },
            Store {
                label: "chrome".into(),
                db: work.path().join("chrome"),
                create: true,
            },
        ];
        let nss = FakeNss {
            refuse_add: Some(work.path().join("chrome")),
            ..Default::default()
        };
        let run = |d: &Path, c: &Path, o: Op| nss.run(d, c, o);
        let report = install(&stores, &ca, &run);
        assert!(report.installed.is_empty());
        assert_eq!(report.failed.len(), 2);
        assert!(report.failed[0].starts_with("firefox:gone: no cert9.db"));
        assert!(report.failed[1].starts_with("chrome: certutil could not add"));
        assert!(!work.path().join("gone").exists());
    }

    #[test]
    fn uninstall_removes_the_nickname_and_leaves_missing_stores_alone() {
        let work = tempfile::tempdir().unwrap();
        let ca = pem(work.path(), "ca.crt", "AAAA");
        let stores = vec![
            Store {
                label: "chrome".into(),
                db: work.path().join("nssdb"),
                create: true,
            },
            Store {
                label: "flatpak:x".into(),
                db: work.path().join("absent"),
                create: true,
            },
        ];
        let nss = FakeNss::default();
        let run = |d: &Path, c: &Path, o: Op| nss.run(d, c, o);
        install(&stores[..1], &ca, &run);
        let report = uninstall(&stores, &ca, &run);
        assert_eq!(report.installed, ["chrome"]);
        assert!(nss.dbs.borrow()[&work.path().join("nssdb")].is_empty());
        assert!(!work.path().join("absent").exists());
    }

    #[test]
    fn host_trust_state_is_reported_for_the_ca_serving_now() {
        let dir = tempfile::tempdir().unwrap();
        let ca = pem(dir.path(), crate::preview_ca::CRT, "AAAA");
        assert_eq!(state(dir.path()).0, "unknown");
        let bytes = std::fs::read(&ca).unwrap();
        record(
            dir.path(),
            &bytes,
            &Report {
                installed: vec!["chrome".into()],
                ..Default::default()
            },
        );
        let (s, why) = state(dir.path());
        assert_eq!(s, "verified");
        assert!(why.contains("chrome"));
        record(
            dir.path(),
            &bytes,
            &Report {
                already: vec!["chrome".into()],
                failed: vec!["firefox:x: no".into()],
                ..Default::default()
            },
        );
        assert_eq!(
            state(dir.path()).0,
            "unknown",
            "some stores refused: not verified"
        );
        record(dir.path(), &bytes, &Report::default());
        assert_eq!(state(dir.path()).0, "untrusted", "no store at all");
        // A rotated CA: the record names the old one, so nothing is claimed.
        record(
            dir.path(),
            &bytes,
            &Report {
                installed: vec!["chrome".into()],
                ..Default::default()
            },
        );
        pem(dir.path(), crate::preview_ca::CRT, "BBBB");
        assert_eq!(state(dir.path()).0, "unknown");
    }

    #[test]
    fn the_add_trusts_for_tls_only_under_the_nickname() {
        let args = certutil_args("/nssdb", "/preview-ca.crt", Op::Add);
        // Joined, so this test names no NSS add of its own for the
        // host-trust guard to count.
        assert_eq!(
            args.join(" "),
            format!(
                "-d sql:/nssdb -A -t C,, -n {} -i /preview-ca.crt",
                crate::preview_ca::NICKNAME
            )
        );
    }
}
