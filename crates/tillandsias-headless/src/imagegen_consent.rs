//! 1874-p8w7: smallest first, one tier up at a time (design.md section 5).
//!
//! Every lane starts on the smallest tier. A result whose tier is below the
//! host ceiling carries `bigger_tier_offer`: the NEXT tier only, one curated
//! sentence, and a host-minted single-use token bound to the lane, the tier and
//! the request (its prompt). A request above the lane's accepted tier runs only
//! when it presents that token; without one it gets `consent_required` and the
//! engine is never invoked. User-facing text carries no sizes or times.
//! @trace order:1874-p8w7

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::imagegen_tiers::TierRow;

/// How long an offer's token stays valid.
pub const TOKEN_TTL: Duration = Duration::from_secs(600);

/// The ask when the next tier's files are already on this computer.
pub const ASK_CACHED: &str = "There are bigger models that give better results, but they are slower. Want to try the next one?";
/// The ask when trying the next tier means fetching its files first.
pub const ASK_DOWNLOAD: &str =
    "We only download the big files if you're OK waiting longer for better results.";

#[derive(Debug, Clone)]
struct Grant {
    lane: String,
    tier: String,
    request: String,
    minted: Instant,
}

#[derive(Default)]
struct State {
    /// lane -> index of the highest tier the user accepted.
    accepted: HashMap<String, usize>,
    /// token -> what it allows, removed on first use.
    grants: HashMap<String, Grant>,
}

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(Mutex::default)
}

/// The lane key a grant is bound to.
pub fn lane_key(project: &str, instance: &str) -> String {
    format!("{project}/{instance}")
}

/// The request a grant is bound to: the prompt pair, so a yes to "this
/// picture, bigger" cannot be spent on a different picture.
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

/// What the lane may run without a token.
pub fn accepted_index(lane: &str) -> usize {
    state()
        .lock()
        .map(|s| s.accepted.get(lane).copied().unwrap_or(0))
        .unwrap_or(0)
}

/// Mint an offer of `next` for `lane`/`request`. `cached` picks the sentence.
pub fn offer(lane: &str, request: &str, next: &TierRow, cached: bool) -> Value {
    let token = mint_token();
    if let Ok(mut s) = state().lock() {
        let now = Instant::now();
        s.grants
            .retain(|_, g| now.duration_since(g.minted) < TOKEN_TTL);
        s.grants.insert(
            token.clone(),
            Grant {
                lane: lane.to_string(),
                tier: next.tier.clone(),
                request: request.to_string(),
                minted: now,
            },
        );
    }
    json!({
        "tier": next.tier,
        "model": next.model,
        "consent_token": token,
        "ask": if cached { ASK_CACHED } else { ASK_DOWNLOAD },
        "how": format!(
            "Show `ask` to the user exactly as written. Only if they say yes, call image.generate again \
             with the same prompt, tier \"{}\" and this consent_token.",
            next.tier
        ),
        "expires_in_s": TOKEN_TTL.as_secs(),
    })
}

/// Why a token was not honoured.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    Missing,
    Unknown,
    Mismatch,
}

/// Spend `token` for `lane`/`tier`/`request`. Single use: a token is removed
/// whether or not it matches, so a guessed or replayed token never runs twice.
pub fn redeem(
    token: Option<&str>,
    lane: &str,
    tier: &TierRow,
    tier_index: usize,
    request: &str,
) -> Result<(), Refusal> {
    let token = token.filter(|t| !t.is_empty()).ok_or(Refusal::Missing)?;
    let mut s = state().lock().map_err(|_| Refusal::Unknown)?;
    let grant = s.grants.remove(token).ok_or(Refusal::Unknown)?;
    if grant.minted.elapsed() >= TOKEN_TTL {
        return Err(Refusal::Unknown);
    }
    if grant.lane != lane || grant.tier != tier.tier || grant.request != request {
        return Err(Refusal::Mismatch);
    }
    let accepted = s.accepted.entry(lane.to_string()).or_insert(0);
    *accepted = (*accepted).max(tier_index);
    Ok(())
}

/// The `consent_required` result: the offer of the next tier above what the
/// lane accepted (never a jump of two), and nothing run.
pub fn consent_required(offer: Value, refusal: Refusal) -> Value {
    json!({
        "status": "consent_required",
        "reason": match refusal {
            Refusal::Missing => "a bigger model needs the user's yes first",
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
