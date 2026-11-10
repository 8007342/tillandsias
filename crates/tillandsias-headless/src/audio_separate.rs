//! `audio.separate` (order 2068-eeti, slice 2 of 2055-d9sa): split a mix into
//! stems with Demucs, behind the licence gate.
//!
//! @trace order:2068-eeti, order:2055-d9sa, order:2068-ypgq
//!
//! The weights (images/audio-studio/weights.tsv) are the maintainer's own
//! safetensors on the Hub, registered restricted as `demucs-weights-unstated`
//! (operator ruling 2026-11-09: non-commercial, acknowledged per project, no
//! standing grant). A call goes through the restricted fetch of 2068-ypgq and
//! nothing else, so the refusals are that fetch's, in its order:
//! - `invalid_arguments`: an unknown model, or an input outside /work/tmp/audio/;
//! - `licence_acknowledgement_required`: the project holds no acknowledgement
//!   of the Demucs weights; the message names the accept-licence skill;
//! - `consent_required` (an `Ok` carrying the offer): the weights are not yet
//!   cached and the user has not said yes to this download.
//!
//! With the weights cached and verified (2068-cqis), the studio runs Demucs on
//! CPU with exactly that one file bind-mounted READ-ONLY at /models/<file>
//! and the registered sha256 on its argv; audio-tool re-hashes the bytes it
//! loads, refuses anything that is not that safetensors file, and disables
//! torch.load before Demucs is imported. The stems land under
//! /work/tmp/audio/out/separate/<name>-<ticket>/<source>.wav, each with a
//! provenance sidecar naming the weights row (model, sha256), the input's
//! sha256 and the acknowledgement, and the answer carries the measured
//! reconstruction (the stems' sum against the input).

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::audio_studio;
use crate::imagegen_consent;
use crate::imagegen_models::{FetchEvent, ModelFile};
use crate::restricted_fetch::{self, Ask, Fetch};

/// The shipped manifest.
pub const WEIGHTS_TSV: &str = include_str!("../../../images/audio-studio/weights.tsv");
/// The cache subdirectory under the models dir: `<models_dir>/audio/demucs/<file>`.
pub const CACHE_SUBDIR: &str = "audio/demucs";
/// The models audio.separate offers, with their stem counts.
pub const MODELS: &[(&str, u8)] = &[("htdemucs", 4), ("htdemucs_6s", 6)];

/// Parse weights.tsv: `model repo revision file sha256 bytes licence source`.
pub fn parse_weights(body: &str) -> Result<Vec<ModelFile>, String> {
    let mut rows = Vec::new();
    for (n, line) in body.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != 8 {
            return Err(format!(
                "weights.tsv line {}: {} columns, want 8",
                n + 1,
                c.len()
            ));
        }
        if !MODELS.iter().any(|(m, _)| *m == c[0]) {
            return Err(format!(
                "weights.tsv line {}: model {:?} is not one of audio.separate's",
                n + 1,
                c[0]
            ));
        }
        let row = ModelFile {
            tier: CACHE_SUBDIR.to_string(),
            role: format!("studio:demucs:{}", c[0]),
            repo: c[1].to_string(),
            revision: c[2].to_string(),
            file: c[3].to_string(),
            sha256: c[4].to_ascii_lowercase(),
            bytes: c[5]
                .parse()
                .map_err(|e| format!("weights.tsv line {}: bytes: {e}", n + 1))?,
            licence: c[6].to_string(),
        };
        if row.sha256.len() != 64 || !row.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("weights.tsv line {}: sha256 is not 64 hex", n + 1));
        }
        if row.licence.is_empty() || c[7].is_empty() {
            return Err(format!(
                "weights.tsv line {}: licence and source are required",
                n + 1
            ));
        }
        rows.push(row);
    }
    Ok(rows)
}

/// The rows one model needs.
pub fn rows_for(all: &[ModelFile], model: &str) -> Vec<ModelFile> {
    let role = format!("studio:demucs:{model}");
    all.iter().filter(|m| m.role == role).cloned().collect()
}

/// The validated request: the model, its stem count, the input.
struct Request {
    model: String,
    stems: u8,
    input: String,
}

fn request(args: &Value) -> Result<Request, String> {
    let model = args["model"].as_str().unwrap_or("htdemucs");
    let stems = MODELS
        .iter()
        .find(|(m, _)| *m == model)
        .map(|(_, s)| *s)
        .ok_or_else(|| {
            format!(
                "invalid_arguments: model must be one of {}, got {model:?}",
                MODELS
                    .iter()
                    .map(|(m, _)| *m)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;
    let input = args["input"]
        .as_str()
        .ok_or("invalid_arguments: input is required")?;
    audio_studio::forge_rel("input", input)?;
    Ok(Request {
        model: model.to_string(),
        stems,
        input: input.to_string(),
    })
}

/// What a consent token is bound to besides the lane: the download, which is
/// the model, not the input (one yes fetches the weights for every input).
fn request_key(model: &str) -> String {
    format!("audio.separate:{model}")
}

/// How a call fetches its rows: the restricted fetch, or a fixture's.
pub type FetchFn<'a> = dyn FnMut(&Ask, &[ModelFile]) -> Result<Fetch, String> + 'a;

/// How a call reaches the studio once the weights are verified: given the
/// read-only (host file, container path) mounts, the appliance that runs
/// audio-tool and the host directory holding the lane's audio. Production
/// builds the image and mounts the lane volume; fixtures stub both.
pub type StudioFn<'a> = dyn FnMut(Vec<(PathBuf, String)>) -> Result<(Box<dyn audio_studio::Appliance>, PathBuf), String>
    + 'a;

/// Where the weights appear inside the studio: `/models/<file>`.
pub const MODELS_MOUNT: &str = "/models";

/// The call against an explicit weights manifest, fetch and studio (fixtures).
pub fn separate_with(
    weights: &[ModelFile],
    project: &str,
    instance: &str,
    args: &Value,
    fetch: &mut FetchFn,
    studio: &mut StudioFn,
) -> Result<Value, String> {
    let req = request(args)?;
    let rows = rows_for(weights, &req.model);
    if rows.len() != 1 {
        return Err(format!(
            "model_refused: {} has {} weights rows in images/audio-studio/weights.tsv; want exactly one",
            req.model,
            rows.len()
        ));
    }
    let row = &rows[0];
    let lane = imagegen_consent::lane_key(project, instance);
    let key = request_key(&req.model);
    let ask = Ask {
        project,
        lane: &lane,
        request: &key,
        token: args["consent_token"].as_str(),
    };
    let (paths, consent) = match fetch(&ask, &rows)? {
        Fetch::ConsentRequired(offer) => return Ok(offer),
        Fetch::Ready { paths, consent } => (paths, consent),
    };
    let [host_weights] = paths.as_slice() else {
        return Err(format!(
            "engine_failed: the fetch returned {} paths for one weights row",
            paths.len()
        ));
    };
    // Only the one verified file is mounted, read-only, under its own name.
    let inside = format!("{MODELS_MOUNT}/{}", row.file);
    let (app, host_dir) = studio(vec![(host_weights.clone(), inside.clone())])?;
    let in_rel = audio_studio::forge_rel("input", &req.input)?;
    let (inp, in_host) = audio_studio::input_record(&host_dir, &req.input, &in_rel)?;
    let output = format!(
        "{}/out/separate/{}-{}",
        audio_studio::FORGE_AUDIO,
        audio_studio::stem(&in_rel),
        audio_studio::ticket()
    );
    let out_rel = audio_studio::forge_rel("output", &output)?;
    if host_dir.join(&out_rel).exists() {
        return Err(format!("output_exists: {output}"));
    }
    let argv: Vec<String> = [
        "separate",
        "--model",
        &req.model,
        "--weights",
        &inside,
        "--sha256",
        &row.sha256,
        "--input",
        &req.input,
        "--output",
        &output,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let res: Value = serde_json::from_str(&app.run(&argv)?)
        .map_err(|e| format!("engine_failed: audio-tool printed no JSON: {e}"))?;
    // The studio's answer is checked, not trusted: the hash it loaded, and
    // exactly the model's stem count, each a file on the lane.
    if res["weights_sha256"].as_str() != Some(row.sha256.as_str()) {
        return Err(format!(
            "engine_failed: the studio loaded weights {}, not the registered {}",
            res["weights_sha256"], row.sha256
        ));
    }
    let sources: Vec<String> = res["sources"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    if sources.len() != usize::from(req.stems) {
        return Err(format!(
            "engine_failed: {} answered {} stems, want {}",
            req.model,
            sources.len(),
            req.stems
        ));
    }
    let mut full_argv = vec!["audio-tool".to_string()];
    full_argv.extend(argv);
    let params = json!({ "model": req.model, "sources": sources });
    let mut versions = res["versions"].clone();
    versions["engine"] = res["engine"].clone();
    let mut stems = Vec::new();
    for s in &sources {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') {
            return Err(format!("engine_failed: malformed source name {s:?}"));
        }
        let path = format!("{output}/{s}.wav");
        let host = host_dir.join(format!("{out_rel}/{s}.wav"));
        if !host.is_file() {
            return Err(format!("engine_failed: separate wrote no {path}"));
        }
        let mut rec = audio_studio::record(
            "audio.separate",
            inp.clone(),
            &in_host,
            versions.clone(),
            "separate",
            params.clone(),
            full_argv.clone(),
        );
        rec.models = rows.clone();
        rec.consent = Some(consent.clone());
        let prov = rec.write_beside(&host)?;
        stems.push(json!({
            "source": s,
            "path": path,
            "provenance_path": format!("{path}.provenance.json"),
            "provenance": prov,
        }));
    }
    Ok(json!({
        "model": req.model,
        "input": req.input,
        "output": output,
        "sample_rate": res["sample_rate"].clone(),
        "stems": stems,
        "reconstruction": res["reconstruction"].clone(),
        "weights": { "repo": row.repo, "revision": row.revision, "file": row.file, "sha256": row.sha256 },
        "consent": consent,
    }))
}

/// Production: the shipped manifest, the restricted fetch, and the studio
/// image (built on first use) on this lane's volume.
pub fn separate(project: &str, instance: &str, args: &Value) -> Result<Value, String> {
    let weights = parse_weights(WEIGHTS_TSV)?;
    separate_with(
        &weights,
        project,
        instance,
        args,
        &mut |ask, rows| restricted_fetch::fetch_restricted(ask, rows, &mut |_e: FetchEvent| {}),
        &mut |ro| {
            let version = crate::VERSION.trim();
            let root = crate::resolve_runtime_asset_root(version, false)?;
            let tag = crate::versioned_image_tag(audio_studio::IMAGE, version);
            crate::ensure_image_exists(&root, audio_studio::IMAGE, &tag, false)?;
            let host_dir = audio_studio::lane_host_dir(project, instance)?;
            let app = audio_studio::PodmanAppliance {
                volume: audio_studio::lane_volume(project, instance),
                image_tag: tag,
                ro,
            };
            Ok((Box::new(app) as Box<dyn audio_studio::Appliance>, host_dir))
        },
    )
}

pub fn tool_descriptor() -> Value {
    json!({
        "name": "audio.separate",
        "description": format!(
            "Split a mix under {}/ into stems with Demucs: model htdemucs (drums, bass, other, vocals) \
             or htdemucs_6s (adds guitar, piano). The weights are licensed for NON-COMMERCIAL use only \
             and need this project's acknowledgement first: a call without one answers \
             licence_acknowledgement_required (run the accept-licence skill). The first call then answers \
             consent_required with an offer: ask the user, and call again with its consent_token to \
             download the weights once. Runs on CPU. Returns the stems' paths \
             under {}/out/separate/, each with a provenance sidecar, and the reconstruction (how closely \
             the stems sum back to the input, in dB).",
            audio_studio::FORGE_AUDIO,
            audio_studio::FORGE_AUDIO
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "input": { "type": "string" },
                "model": { "type": "string", "enum": MODELS.iter().map(|(m, _)| *m).collect::<Vec<_>>(), "default": "htdemucs" },
                "consent_token": { "type": "string" }
            },
            "required": ["input"]
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::imagegen_models::ProxyTransport;
    use crate::licence_consent::tests::{disk_scratch, enrol, sign};
    use crate::licence_consent::{self, Acknowledgement, Verifier};
    use crate::restricted_fetch::tests::{files_under, hub};
    use crate::restricted_fetch::{Gate, fetch_restricted_in};
    use std::collections::HashMap;
    use std::fs;
    use std::sync::atomic::Ordering::SeqCst;

    /// The shipped Demucs register rows, as a project acknowledges them.
    fn demucs_ack(scope: &str) -> Acknowledgement {
        let reg =
            licence_consent::parse_restricted(licence_consent::restricted_register_tsv()).unwrap();
        let r = reg
            .iter()
            .find(|r| r.name == "htdemucs")
            .expect("shipped register has an htdemucs row");
        Acknowledgement {
            licence: r.spdx.clone(),
            licence_sha256: r.licence_sha256.clone(),
            covers: vec!["adefossez/HTDemucs".into(), "adefossez/HTDemucs-6s".into()],
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

    #[test]
    fn the_shipped_demucs_manifest_agrees_with_the_restricted_register() {
        let rows = parse_weights(WEIGHTS_TSV).unwrap();
        for (m, _) in MODELS {
            assert_eq!(rows_for(&rows, m).len(), 1, "{m}: one safetensors row");
        }
        let reg =
            licence_consent::parse_restricted(licence_consent::restricted_register_tsv()).unwrap();
        for m in &rows {
            assert!(
                m.file.ends_with(".safetensors"),
                "{}: safetensors only",
                m.file
            );
            let r = reg
                .iter()
                .find(|r| r.repo == m.repo && r.file == m.file)
                .unwrap_or_else(|| panic!("{} {}: no register row", m.repo, m.file));
            assert_eq!(
                (&r.revision, &r.sha256, &r.spdx),
                (&m.revision, &m.sha256, &m.licence),
                "{}: manifest and register disagree",
                m.file
            );
            assert_eq!(r.gated, "false");
            assert_eq!(
                r.licence_sha256.len(),
                64,
                "{}: licence text pinned",
                m.file
            );
            let classes: Vec<&str> = r.obligations.iter().map(|o| o.id()).collect();
            assert!(
                classes.contains(&"non-commercial"),
                "{}: {classes:?}",
                m.file
            );
        }
        // The obligation table quotes the maintainer for the id the rows use.
        let ob = licence_consent::obligations_for("demucs-weights-unstated");
        assert!(
            ob.iter()
                .any(|o| o.clause.contains("The license of the weights is not clear"))
        );
    }

    /// The lane socket routes audio.separate to this module: an MCP tools/call
    /// from a project with no acknowledgement answers the gate's refusal, never
    /// "unknown tool". (The first draft advertised the tool and left it out of
    /// mcp_socket's match; the descriptor tests could not see that.) A host
    /// whose model cache is on tmpfs refuses one step earlier, still here.
    #[test]
    fn audio_separate_is_dispatched_over_the_lane_socket() {
        let project = format!("eeti-socket-fixture-{}", std::process::id());
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = crate::mcp_socket::lane_browser_server(&project, "", None, true);
        let req = json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "audio.separate", "arguments": { "input": "/work/tmp/audio/mix.wav" } },
        });
        let reply = crate::mcp_socket::handle_mcp_jsonrpc(&project, "", &req, &browser, &rt)
            .expect("a reply");
        let msg = reply["error"]["message"].as_str().unwrap_or("");
        assert!(
            msg.starts_with("licence_acknowledgement_required:")
                || msg.starts_with("model_cache_volatile:"),
            "{reply}"
        );
        assert!(!msg.contains("unknown tool"), "{reply}");
    }

    /// 2068-eeti verifiable closure. Pre-fix: FAILS, no audio.separate tool
    /// exists. Against the SHIPPED manifest and register (the fixture supplies
    /// only the acknowledgement records, the signers, the cache and a stand-in
    /// hub): no acknowledgement refuses licence_acknowledgement_required naming
    /// accept-licence and contacts nothing; with one, the call reaches the fetch
    /// (consent_required, then with the token a download of the pinned Hub URL,
    /// whose bytes the stand-in cannot match, so model_digest_mismatch).
    #[test]
    fn audio_separate_refuses_without_the_acknowledgement_and_reaches_the_fetch_with_one() {
        let dir = disk_scratch("audio-separate");
        let (key, signers) = enrol(&dir, "operator");
        let verifier = Verifier::new(&signers);
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let models = dir.join("models");
        fs::create_dir_all(&models).unwrap();
        let weights = parse_weights(WEIGHTS_TSV).unwrap();
        let m = &rows_for(&weights, "htdemucs")[0];
        let hub_path = format!("/{}/resolve/{}/{}", m.repo, m.revision, m.file);
        let hub = hub(HashMap::from([(
            hub_path,
            b"not the demucs weights".to_vec(),
        )]));
        let transport = crate::restricted_fetch::tests::HubTransport { port: hub.port };
        let gate = Gate {
            register: licence_consent::restricted_register_tsv(),
            ack_dir: &acks,
            verifier: &verifier,
        };
        let mut fetch = |ask: &Ask, rows: &[ModelFile]| {
            fetch_restricted_in(&gate, &models, &transport, ask, rows, &mut |_| {})
        };
        let args = json!({ "input": "/work/tmp/audio/mix.wav" });
        // No arm here reaches the studio: every one stops at the gate or fetch.
        let mut no_studio = |_ro: Vec<(std::path::PathBuf, String)>| {
            Err::<(Box<dyn audio_studio::Appliance>, std::path::PathBuf), String>(
                "studio_reached: the gate let this call through".into(),
            )
        };

        // 1. Bad arguments are refused before the gate.
        let e = separate_with(
            &weights,
            "my-game",
            "",
            &json!({ "input": "/etc/passwd" }),
            &mut fetch,
            &mut no_studio,
        )
        .unwrap_err();
        assert!(e.starts_with("invalid_arguments:"), "{e}");
        let e = separate_with(
            &weights,
            "my-game",
            "",
            &json!({ "input": "/work/tmp/audio/mix.wav", "model": "mdx_extra" }),
            &mut fetch,
            &mut no_studio,
        )
        .unwrap_err();
        assert!(e.starts_with("invalid_arguments:"), "{e}");

        // 2. No acknowledgement: refused, naming the skill; nothing contacted.
        let e =
            separate_with(&weights, "my-game", "", &args, &mut fetch, &mut no_studio).unwrap_err();
        assert!(e.starts_with("licence_acknowledgement_required:"), "{e}");
        assert!(e.contains("accept-licence"), "{e}");
        assert!(e.contains("demucs-weights-unstated"), "{e}");
        assert_eq!(hub.hits.load(SeqCst), 0);
        assert!(files_under(&models).is_empty());

        // 2b. Another project's acknowledgement does not cover this one.
        let other = sign(&dir, &key, demucs_ack("project:other-game"));
        fs::write(acks.join("adefossez-htdemucs.yaml"), other.to_yaml()).unwrap();
        let e =
            separate_with(&weights, "my-game", "", &args, &mut fetch, &mut no_studio).unwrap_err();
        assert!(e.starts_with("licence_acknowledgement_required:"), "{e}");
        assert_eq!(hub.hits.load(SeqCst), 0);

        // 3. With this project's acknowledgement: the fetch's consent offer.
        let mine = sign(&dir, &key, demucs_ack("project:my-game"));
        fs::write(acks.join("adefossez-htdemucs.yaml"), mine.to_yaml()).unwrap();
        let offer =
            separate_with(&weights, "my-game", "", &args, &mut fetch, &mut no_studio).unwrap();
        assert_eq!(offer["status"], "consent_required", "{offer}");
        assert_eq!(offer["ran"], false);
        assert_eq!(hub.hits.load(SeqCst), 0);
        let token = offer["offer"]["consent_token"]
            .as_str()
            .unwrap()
            .to_string();

        // 3b. The 6-source model is a different download: this token is not its.
        let e = separate_with(
            &weights,
            "my-game",
            "",
            &json!({ "input": "/work/tmp/audio/mix.wav", "model": "htdemucs_6s", "consent_token": token }),
            &mut fetch,
            &mut no_studio,
        )
        .unwrap();
        assert_eq!(e["status"], "consent_required", "{e}");
        assert_eq!(hub.hits.load(SeqCst), 0);

        // 4. With the token: the pinned Hub URL is fetched, and the stand-in's
        // bytes fail the register's sha256, leaving nothing in the cache.
        let offer =
            separate_with(&weights, "my-game", "", &args, &mut fetch, &mut no_studio).unwrap();
        let token = offer["offer"]["consent_token"]
            .as_str()
            .unwrap()
            .to_string();
        let e = separate_with(
            &weights,
            "my-game",
            "",
            &json!({ "input": "/work/tmp/audio/mix.wav", "consent_token": token }),
            &mut fetch,
            &mut no_studio,
        )
        .unwrap_err();
        assert!(e.starts_with("model_digest_mismatch:"), "{e}");
        assert_eq!(hub.hits.load(SeqCst), 1);
        assert!(
            files_under(&models).is_empty(),
            "{:?}",
            files_under(&models)
        );

        // 5. Production wiring: the descriptor names the tool and the skill,
        // and the production transport is the model-hubs tier.
        let d = tool_descriptor();
        assert_eq!(d["name"], "audio.separate");
        assert!(
            d["description"]
                .as_str()
                .unwrap()
                .contains("accept-licence")
        );
        assert_eq!(
            ProxyTransport::model_hubs_for_this_build().proxy_port,
            crate::imagegen_models::MODEL_HUBS_PORT
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// A stub studio: records the mounts and argv, writes one file per source
    /// it answers under the requested output, and answers like audio-tool.
    struct StubStudio {
        root: std::path::PathBuf,
        calls: std::rc::Rc<std::cell::RefCell<Vec<Vec<String>>>>,
        reply: Value,
    }

    impl audio_studio::Appliance for StubStudio {
        fn run(&self, a: &[String]) -> Result<String, String> {
            self.calls.borrow_mut().push(a.to_vec());
            let out = &a[a.iter().position(|x| x == "--output").unwrap() + 1];
            let rel = audio_studio::forge_rel("output", out).unwrap();
            fs::create_dir_all(self.root.join(&rel)).unwrap();
            for s in self.reply["sources"].as_array().unwrap() {
                fs::write(
                    self.root.join(format!("{rel}/{}.wav", s.as_str().unwrap())),
                    b"RIFF....WAVE",
                )
                .unwrap();
            }
            Ok(self.reply.to_string())
        }
    }

    /// 2068-cqis: past the gate. Pre-fix: FAILS, a Ready fetch answered
    /// separator_not_built. The studio gets exactly the verified file,
    /// read-only, under /models with the registered sha256 on its argv; each
    /// stem gets a sidecar naming the weights row, the input's sha256 and the
    /// acknowledgement; and the studio's answer is checked, not trusted.
    #[test]
    fn a_ready_separation_mounts_only_the_verified_weights_and_writes_stems_with_provenance() {
        let dir = disk_scratch("audio-separate-ready");
        let lane = dir.join("lane");
        fs::create_dir_all(lane.join("in")).unwrap();
        fs::write(lane.join("in/mix.wav"), b"RIFF-mix-WAVE").unwrap();
        let cached = dir.join("models/audio/demucs/955717e8.safetensors");
        fs::create_dir_all(cached.parent().unwrap()).unwrap();
        fs::write(&cached, b"verified by the fetch").unwrap();
        let weights = parse_weights(WEIGHTS_TSV).unwrap();
        let row = rows_for(&weights, "htdemucs")[0].clone();
        let args = json!({ "input": "/work/tmp/audio/in/mix.wav" });
        let good = json!({
            "weights_sha256": row.sha256,
            "sources": ["drums", "bass", "other", "vocals"],
            "sample_rate": 44100,
            "reconstruction": { "snr_db": 31.2 },
            "versions": { "audio_tool": "3" },
            "engine": { "torch": "2.9.1+cpu", "demucs": "4.1.0" },
        });
        let run = |reply: Value, model: &str| {
            let calls = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
            let mounts = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
            let mut fetch = |_: &Ask, rows: &[ModelFile]| {
                assert_eq!(rows.len(), 1);
                Ok(Fetch::Ready {
                    paths: vec![cached.clone()],
                    consent: vec!["licences/acknowledgements/adefossez-htdemucs.yaml".into()],
                })
            };
            let (c2, m2, root) = (calls.clone(), mounts.clone(), lane.clone());
            let mut studio = move |ro: Vec<(std::path::PathBuf, String)>| {
                m2.borrow_mut().extend(ro);
                Ok((
                    Box::new(StubStudio {
                        root: root.clone(),
                        calls: c2.clone(),
                        reply: reply.clone(),
                    }) as Box<dyn audio_studio::Appliance>,
                    root.clone(),
                ))
            };
            let mut a = args.clone();
            a["model"] = json!(model);
            let r = separate_with(&weights, "my-game", "", &a, &mut fetch, &mut studio);
            let calls = calls.borrow().clone();
            let mounts = mounts.borrow().clone();
            (r, calls, mounts)
        };

        let (r, calls, mounts) = run(good.clone(), "htdemucs");
        let v = r.unwrap();
        assert_eq!(
            mounts,
            vec![(cached.clone(), "/models/955717e8.safetensors".to_string())]
        );
        let argv = &calls[0];
        let after = |flag: &str| argv[argv.iter().position(|x| x == flag).unwrap() + 1].clone();
        assert_eq!(argv[0], "separate");
        assert_eq!(after("--weights"), "/models/955717e8.safetensors");
        assert_eq!(after("--sha256"), row.sha256);
        assert_eq!(after("--model"), "htdemucs");
        let stems = v["stems"].as_array().unwrap();
        assert_eq!(stems.len(), 4, "{v}");
        let input_sha = crate::provenance::sha256_file(&lane.join("in/mix.wav")).unwrap();
        for s in stems {
            let path = s["path"].as_str().unwrap();
            let rel = audio_studio::forge_rel("path", path).unwrap();
            let side = lane.join(format!("{rel}.provenance.json"));
            let p: Value = serde_json::from_slice(&fs::read(&side).unwrap()).unwrap();
            assert_eq!(p["tool"], "audio.separate");
            assert_eq!(p["models"][0]["sha256"], row.sha256.as_str(), "{p}");
            assert_eq!(p["models"][0]["repo"], "adefossez/HTDemucs");
            assert!(p["models"][0]["consent"].is_string(), "{p}");
            assert_eq!(p["inputs"][0]["sha256"], input_sha.as_str());
            assert_eq!(p["placement"], "cpu");
        }
        assert_eq!(v["reconstruction"]["snr_db"], 31.2);

        // The studio claiming other weights is refused.
        let mut lie = good.clone();
        lie["weights_sha256"] = json!("0".repeat(64));
        let e = run(lie, "htdemucs").0.unwrap_err();
        assert!(
            e.starts_with("engine_failed:") && e.contains("not the registered"),
            "{e}"
        );

        // Fewer stems than the model's is refused.
        let mut short = good.clone();
        short["sources"] = json!(["drums", "bass", "other"]);
        let e = run(short, "htdemucs").0.unwrap_err();
        assert!(e.contains("answered 3 stems, want 4"), "{e}");

        // htdemucs_6s wants six and mounts its own file name.
        let (r, _, mounts) = run(good.clone(), "htdemucs_6s");
        assert!(r.unwrap_err().starts_with("engine_failed:"));
        assert_eq!(mounts[0].1, "/models/5c90dfd2.safetensors");

        // A missing input is refused before the studio runs.
        let mut gone = args.clone();
        gone["input"] = json!("/work/tmp/audio/in/absent.wav");
        let (calls, _) = {
            let mut fetch = |_: &Ask, _: &[ModelFile]| {
                Ok(Fetch::Ready {
                    paths: vec![cached.clone()],
                    consent: vec!["a".into()],
                })
            };
            let calls = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
            let (c2, root) = (calls.clone(), lane.clone());
            let mut studio = move |_ro: Vec<(std::path::PathBuf, String)>| {
                Ok((
                    Box::new(StubStudio {
                        root: root.clone(),
                        calls: c2.clone(),
                        reply: json!({}),
                    }) as Box<dyn audio_studio::Appliance>,
                    root.clone(),
                ))
            };
            let e =
                separate_with(&weights, "my-game", "", &gone, &mut fetch, &mut studio).unwrap_err();
            assert!(e.starts_with("input_missing:"), "{e}");
            let n = calls.borrow().len();
            (n, ())
        };
        assert_eq!(calls, 0);
        let _ = fs::remove_dir_all(&dir);
    }
}
