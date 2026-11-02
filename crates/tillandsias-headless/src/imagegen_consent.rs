//! 1874-p8w7 / 1957-5m8g: the image.generate consent gate is a DOWNLOAD gate.
//!
//! Operator ruling 2026-11-01 (on #825): "the bigger models gate should be
//! asked only for downloading models the first time". A tier whose pinned files
//! are on this computer runs on request with no consent; a direct request for
//! any tier up to the host ceiling is allowed (no I0 -> I1 -> I2 walk). Only a
//! tier whose files are missing asks, once: the offer states the download
//! (GB from the pinned sizes, minutes at an assumed rate, 1957-8hkf) and carries
//! a host-minted single-use token bound to the lane, the tier and the request.
//! Redeeming it records a HOST grant for that tier's download, so it is never
//! asked again on this host (approvals are standing; expiry is not enforced).
//! @trace order:1874-p8w7, order:1957-5m8g, order:1957-8hkf

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::imagegen_tiers::TierRow;

/// How long an offer's token stays valid.
pub const TOKEN_TTL: Duration = Duration::from_secs(600);

/// Assumed fetch rate for the minutes estimate (no link-rate measurement yet).
pub const ASSUMED_DOWNLOAD_BYTES_PER_S: u64 = 10_000_000;

/// The ask for a tier whose files must be fetched first.
pub fn ask_download(bytes: u64) -> String {
    let gb = bytes as f64 / 1e9;
    let min = bytes.div_ceil(ASSUMED_DOWNLOAD_BYTES_PER_S * 60).max(1);
    format!(
        "This model is not on this computer yet: it needs a one-time download of {gb:.1} GB (about {min} min, it may take a while) and that much disk. On a slow or metered connection you may prefer to say no. Download it?"
    )
}

/// How a result names the download grant it ran under.
pub fn grant_json(tier: &str) -> Value {
    json!({
        "tier": tier,
        "kind": "download",
        "scope": "host",
        "expiry": "none",
        "expiry_enforced": false,
    })
}

#[derive(Debug, Clone)]
struct Offered {
    lane: String,
    tier: String,
    request: String,
    minted: Instant,
}

#[derive(Default)]
struct State {
    /// Tiers whose download the user granted on this host.
    downloads: HashSet<String>,
    /// token -> what it offers, removed on first use.
    offers: HashMap<String, Offered>,
}

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(Mutex::default)
}

/// The lane key a token is bound to.
pub fn lane_key(project: &str, instance: &str) -> String {
    format!("{project}/{instance}")
}

/// The request a token is bound to: the prompt pair.
pub fn request_hash(args: &Value) -> String {
    let field = |k: &str| {
        args.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string()
    };
    let mut h = Sha256::new();
    h.update(field("prompt").as_bytes());
    h.update([0]);
    h.update(field("negative_prompt").as_bytes());
    format!("{:x}", h.finalize())
}

fn mint_token() -> String {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("the OS random source is available");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Whether the user granted `tier`'s download on this host.
pub fn download_granted(tier: &str) -> bool {
    state()
        .lock()
        .map(|s| s.downloads.contains(tier))
        .unwrap_or(false)
}

/// Mint a download offer of `tier` for `lane`/`request`, costing `bytes`.
pub fn offer(lane: &str, request: &str, tier: &TierRow, bytes: u64) -> Value {
    let token = mint_token();
    if let Ok(mut s) = state().lock() {
        let now = Instant::now();
        s.offers
            .retain(|_, g| now.duration_since(g.minted) < TOKEN_TTL);
        s.offers.insert(
            token.clone(),
            Offered {
                lane: lane.to_string(),
                tier: tier.tier.clone(),
                request: request.to_string(),
                minted: now,
            },
        );
    }
    json!({
        "tier": tier.tier,
        "model": tier.model,
        "consent_token": token,
        "ask": ask_download(bytes),
        "download_bytes": bytes,
        "how": format!(
            "Show `ask` to the user exactly as written. Only if they say yes, call image.generate again \
             with the same prompt, tier \"{}\" and this consent_token. The yes holds for this computer: \
             that tier never asks again. If they say no, call again with this consent_token and \
             decline: true; nothing is downloaded.",
            tier.tier
        ),
        "expires_in_s": TOKEN_TTL.as_secs(),
    })
}

/// The user said no: spend the token, grant nothing.
pub fn decline(token: Option<&str>) {
    if let (Some(t), Ok(mut s)) = (token, state().lock()) {
        s.offers.remove(t);
    }
}

/// Why a token was not honoured.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    Missing,
    Unknown,
    Mismatch,
}

/// Spend `token` for `lane`/`tier`/`request`; on success this host holds a
/// download grant for `tier`. Single use: a token is removed whether or not it
/// matches, so a guessed or replayed token never runs twice.
pub fn redeem(
    token: Option<&str>,
    lane: &str,
    tier: &TierRow,
    request: &str,
) -> Result<(), Refusal> {
    let token = token.filter(|t| !t.is_empty()).ok_or(Refusal::Missing)?;
    let mut s = state().lock().map_err(|_| Refusal::Unknown)?;
    let offered = s.offers.remove(token).ok_or(Refusal::Unknown)?;
    if offered.minted.elapsed() >= TOKEN_TTL {
        return Err(Refusal::Unknown);
    }
    if offered.lane != lane || offered.tier != tier.tier || offered.request != request {
        return Err(Refusal::Mismatch);
    }
    s.downloads.insert(tier.tier.clone());
    Ok(())
}

/// The `consent_required` result: the download offer, and nothing run.
pub fn consent_required(offer: Value, refusal: Refusal) -> Value {
    json!({
        "status": "consent_required",
        "reason": match refusal {
            Refusal::Missing => "this model must be downloaded first, which needs the user's yes",
            Refusal::Unknown => "that consent_token was already used, expired or never issued",
            Refusal::Mismatch => "that consent_token was issued for a different picture or model",
        },
        "bigger_tier_offer": offer,
        "ran": false,
    })
}

#[cfg(test)]
pub fn reset_for_test() {
    if let Ok(mut s) = state().lock() {
        *s = State::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::imagegen_tiers::ladder;

    /// 1957-5m8g verifiable closure (download-gate form): a redeemed token is a
    /// standing host grant; the tier is then callable without a token.
    #[test]
    fn grant_at_approved_tier_admits_a_direct_call_without_a_token() {
        let _g = crate::imagegen_tool::SEAM_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let l = ladder();
        assert!(!download_granted("I3"));
        let o = offer("p/a", "req", &l[3], 18_300_000_000);
        let t = o["consent_token"].as_str().unwrap().to_string();
        assert_eq!(redeem(Some(&t), "p/a", &l[3], "req"), Ok(()));
        assert!(download_granted("I3"));
        // Single use, and bound to its lane/tier/picture.
        assert_eq!(redeem(Some(&t), "p/a", &l[3], "req"), Err(Refusal::Unknown));
        let o = offer("p/a", "req", &l[2], 1);
        let t = o["consent_token"].as_str().unwrap().to_string();
        assert_eq!(
            redeem(Some(&t), "p/a", &l[2], "other"),
            Err(Refusal::Mismatch)
        );
        assert!(!download_granted("I2"));
    }
}
