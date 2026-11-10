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
//! With the weights cached and verified, the separator itself is order
//! 2068-cqis; until it lands the call answers `separator_not_built`, having
//! changed nothing but the model cache.

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

/// The call against an explicit weights manifest and fetch (fixtures).
pub fn separate_with(
    weights: &[ModelFile],
    project: &str,
    instance: &str,
    args: &Value,
    fetch: &mut FetchFn,
) -> Result<Value, String> {
    let req = request(args)?;
    let rows = rows_for(weights, &req.model);
    if rows.is_empty() {
        return Err(format!(
            "model_refused: no weights row for {} in images/audio-studio/weights.tsv",
            req.model
        ));
    }
    let lane = imagegen_consent::lane_key(project, instance);
    let key = request_key(&req.model);
    let ask = Ask {
        project,
        lane: &lane,
        request: &key,
        token: args["consent_token"].as_str(),
    };
    match fetch(&ask, &rows)? {
        Fetch::ConsentRequired(offer) => Ok(offer),
        Fetch::Ready { paths, consent } => Err(format!(
            "separator_not_built: the {} weights are cached and verified ({}; acknowledgement {}), \
             but the {}-stem separator is order 2068-cqis and has not landed. Nothing was separated \
             from {}.",
            req.model,
            paths
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", "),
            consent.join(", "),
            req.stems,
            req.input
        )),
    }
}

/// Production: the shipped manifest and the restricted fetch.
pub fn separate(project: &str, instance: &str, args: &Value) -> Result<Value, String> {
    let weights = parse_weights(WEIGHTS_TSV)?;
    separate_with(&weights, project, instance, args, &mut |ask, rows| {
        restricted_fetch::fetch_restricted(ask, rows, &mut |_e: FetchEvent| {})
    })
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
             download the weights once. The separator itself is not built yet (order 2068-cqis).",
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

        // 1. Bad arguments are refused before the gate.
        let e = separate_with(
            &weights,
            "my-game",
            "",
            &json!({ "input": "/etc/passwd" }),
            &mut fetch,
        )
        .unwrap_err();
        assert!(e.starts_with("invalid_arguments:"), "{e}");
        let e = separate_with(
            &weights,
            "my-game",
            "",
            &json!({ "input": "/work/tmp/audio/mix.wav", "model": "mdx_extra" }),
            &mut fetch,
        )
        .unwrap_err();
        assert!(e.starts_with("invalid_arguments:"), "{e}");

        // 2. No acknowledgement: refused, naming the skill; nothing contacted.
        let e = separate_with(&weights, "my-game", "", &args, &mut fetch).unwrap_err();
        assert!(e.starts_with("licence_acknowledgement_required:"), "{e}");
        assert!(e.contains("accept-licence"), "{e}");
        assert!(e.contains("demucs-weights-unstated"), "{e}");
        assert_eq!(hub.hits.load(SeqCst), 0);
        assert!(files_under(&models).is_empty());

        // 2b. Another project's acknowledgement does not cover this one.
        let other = sign(&dir, &key, demucs_ack("project:other-game"));
        fs::write(acks.join("adefossez-htdemucs.yaml"), other.to_yaml()).unwrap();
        let e = separate_with(&weights, "my-game", "", &args, &mut fetch).unwrap_err();
        assert!(e.starts_with("licence_acknowledgement_required:"), "{e}");
        assert_eq!(hub.hits.load(SeqCst), 0);

        // 3. With this project's acknowledgement: the fetch's consent offer.
        let mine = sign(&dir, &key, demucs_ack("project:my-game"));
        fs::write(acks.join("adefossez-htdemucs.yaml"), mine.to_yaml()).unwrap();
        let offer = separate_with(&weights, "my-game", "", &args, &mut fetch).unwrap();
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
        )
        .unwrap();
        assert_eq!(e["status"], "consent_required", "{e}");
        assert_eq!(hub.hits.load(SeqCst), 0);

        // 4. With the token: the pinned Hub URL is fetched, and the stand-in's
        // bytes fail the register's sha256, leaving nothing in the cache.
        let offer = separate_with(&weights, "my-game", "", &args, &mut fetch).unwrap();
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
}
