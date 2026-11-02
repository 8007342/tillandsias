//! 1874-p8w7: smallest first, one tier up at a time (design.md section 5).
//!
//! Every lane starts on the smallest tier. A result whose tier is below the
//! host ceiling carries `bigger_tier_offer`: the NEXT tier only, one curated
//! sentence, and a host-minted single-use token bound to the lane, the tier and
//! the request (its prompt). A request above the lane's accepted tier runs only
//! when it presents that token; without one it gets `consent_required` and the
//! engine is never invoked.
//!
//! 1957-5m8g: a tier prompt is a RESOURCE gate protecting the host (memory,
//! disk, time), not a quality choice. A redeemed token becomes a GRANT
//! {tier, scope, expiry}. Operator ruling 2026-11-01: approvals are standing;
//! expiry is per session or by time, and until expiry is enforced the grant is
//! held for the session (lane). A call at or below the granted tier needs no
//! token and no ladder walk; a never-granted tier still asks, one rung at a time.
//!
//! 1957-8hkf: an offer for a tier whose files are not on this computer says what
//! the download costs (GB from the pinned sizes, minutes at an assumed rate).
//! @trace order:1874-p8w7, order:1957-5m8g, order:1957-8hkf

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::imagegen_tiers::TierRow;

/// How long an offer's token stays valid.
pub const TOKEN_TTL: Duration = Duration::from_secs(600);

/// The ask when the next tier's files are already on this computer: what it
/// costs the host, asked once for the session.
pub const ASK_CACHED: &str = "The next model is bigger: it uses more of this computer's memory and takes longer per picture. Allow it for this session?";

/// Assumed fetch rate for the minutes estimate (no link-rate measurement yet).
pub const ASSUMED_DOWNLOAD_BYTES_PER_S: u64 = 10_000_000;

/// The ask when trying the next tier means fetching its files first.
pub fn ask_download(bytes: u64) -> String {
    let gb = bytes as f64 / 1e9;
    let min = bytes.div_ceil(ASSUMED_DOWNLOAD_BYTES_PER_S * 60).max(1);
    format!(
        "The next model is bigger: it needs a download of {gb:.1} GB (about {min} min), more of this computer's memory and disk, and longer per picture. Allow it for this session?"
    )
}

/// What a session's yes allows (1957-5m8g).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grant {
    pub tier: String,
    pub tier_index: usize,
}

impl Grant {
    /// How a result names the grant it ran under.
    pub fn to_json(&self) -> Value {
        json!({
            "tier": self.tier,
            "scope": "session",
            "expiry": "session",
            "expiry_enforced": false,
        })
    }
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
    /// lane -> the highest tier the user granted for that session.
    grants: HashMap<String, Grant>,
    /// token -> what it offers, removed on first use.
    offers: HashMap<String, Offered>,
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

/// The session grant of `lane`, if the user said yes to a tier above I0.
pub fn grant_for(lane: &str) -> Option<Grant> {
    state()
        .lock()
        .ok()
        .and_then(|s| s.grants.get(lane).cloned())
}

/// What the lane may run without a token.
pub fn accepted_index(lane: &str) -> usize {
    grant_for(lane).map_or(0, |g| g.tier_index)
}

/// Mint an offer of `next` for `lane`/`request`. `download_bytes` is `None`
/// when the tier's files are already here, else what fetching them costs.
pub fn offer(lane: &str, request: &str, next: &TierRow, download_bytes: Option<u64>) -> Value {
    let token = mint_token();
    if let Ok(mut s) = state().lock() {
        let now = Instant::now();
        s.offers
            .retain(|_, g| now.duration_since(g.minted) < TOKEN_TTL);
        s.offers.insert(
            token.clone(),
            Offered {
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
        "ask": download_bytes.map_or_else(|| ASK_CACHED.to_string(), ask_download),
        "download_bytes": download_bytes,
        "how": format!(
            "Show `ask` to the user exactly as written. Only if they say yes, call image.generate again \
             with the same prompt, tier \"{}\" and this consent_token. The yes is a grant for this \
             session: later calls at that tier need no token.",
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

/// Spend `token` for `lane`/`tier`/`request`; on success the session holds a
/// grant for `tier`. Single use: a token is removed
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
    let grant = s.offers.remove(token).ok_or(Refusal::Unknown)?;
    if grant.minted.elapsed() >= TOKEN_TTL {
        return Err(Refusal::Unknown);
    }
    if grant.lane != lane || grant.tier != tier.tier || grant.request != request {
        return Err(Refusal::Mismatch);
    }
    let held = s.grants.get(lane).map_or(0, |g| g.tier_index);
    if tier_index > held {
        s.grants.insert(
            lane.to_string(),
            Grant {
                tier: tier.tier.clone(),
                tier_index,
            },
        );
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::imagegen_tool::{self, Engine, EngineOut, Job, Progress, SEAM_TEST_LOCK, Seam};
    use std::path::Path;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Counting(AtomicUsize);
    impl Engine for Counting {
        fn generate(
            &self,
            job: &Job,
            out_dir: &Path,
            names: &[String],
            _progress: &mut dyn FnMut(Progress),
        ) -> Result<EngineOut, String> {
            self.0.fetch_add(1, Ordering::SeqCst);
            for n in names {
                image::RgbImage::new(job.width, job.height)
                    .save(out_dir.join(n))
                    .map_err(|e| e.to_string())?;
            }
            Ok(EngineOut {
                backend: "cuda".into(),
                first_use: false,
            })
        }
    }

    /// 1957-5m8g verifiable closure. Pre-fix: FAILS (a yes is spent on one
    /// picture; the result names no grant and an untiered call walks back to I0).
    #[test]
    fn grant_at_approved_tier_admits_a_direct_call_without_a_token() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let engine = Arc::new(Counting(Default::default()));
        imagegen_tool::install_seam(Some(Seam {
            engine: engine.clone(),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I3".into(),
        }));
        let runs = || engine.0.load(Ordering::SeqCst);
        let (p, i) = ("5m8g-proj", "a");
        let mut sink = |_: Progress| {};
        let small = |prompt: &str, tier: Option<&str>| {
            let mut a = json!({"prompt": prompt, "width": 64, "height": 64});
            if let Some(t) = tier {
                a["tier"] = json!(t);
            }
            a
        };

        // The ask names the host resource it protects, not image quality.
        let r = imagegen_tool::call(p, i, &small("a fox", None), &mut sink).unwrap();
        let offer = &r["bigger_tier_offer"];
        let ask = offer["ask"].as_str().unwrap().to_ascii_lowercase();
        assert!(
            ask.contains("memory") && !ask.contains("better"),
            "the ask is about the host's resources: {ask}"
        );
        let token = offer["consent_token"].as_str().unwrap().to_string();

        // The user says yes once: the token is redeemed into a grant.
        let mut yes = small("a fox", Some("I1"));
        yes["consent_token"] = json!(token);
        let r = imagegen_tool::call(p, i, &yes, &mut sink).unwrap();
        assert_eq!(r["tier"], "I1", "{r}");
        assert_eq!(r["grant"]["tier"], "I1", "the result names its grant: {r}");
        assert_eq!(r["grant"]["scope"], "session");
        assert_eq!(runs(), 2);

        // A different picture at the granted tier: no token, no I0 run first.
        let r = imagegen_tool::call(p, i, &small("a castle", Some("I1")), &mut sink).unwrap();
        assert_eq!(r["tier"], "I1", "a granted tier runs directly: {r}");
        assert_eq!(r["grant"]["tier"], "I1", "{r}");
        assert_eq!(runs(), 3, "exactly one run, no ladder walk");

        // An untiered call runs at the granted tier, not back at I0.
        let r = imagegen_tool::call(p, i, &small("a boat", None), &mut sink).unwrap();
        assert_eq!(r["tier"], "I1", "{r}");
        assert_eq!(runs(), 4);

        // Above the grant still asks, one rung at a time.
        let r = imagegen_tool::call(p, i, &small("a boat", Some("I3")), &mut sink).unwrap();
        assert_eq!(r["status"], "consent_required", "{r}");
        assert_eq!(r["bigger_tier_offer"]["tier"], "I2");
        assert_eq!(runs(), 4);

        // The grant is per session (lane): another forge session still asks.
        let r = imagegen_tool::call(p, "b", &small("a fox", Some("I1")), &mut sink).unwrap();
        assert_eq!(r["status"], "consent_required", "{r}");
        imagegen_tool::install_seam(None);
    }

    /// 1957-5m8g field report (demon_attack-forge): a granted tier is never
    /// re-offered. Grant I2, grant I3, then three I3 calls with no token and no
    /// offer. Pre-fix: FAILS (an I2 result re-offered the granted I3).
    #[test]
    fn a_granted_tier_is_never_re_offered_and_the_top_grant_needs_no_token() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let engine = Arc::new(Counting(Default::default()));
        imagegen_tool::install_seam(Some(Seam {
            engine: engine.clone(),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I3".into(),
        }));
        let runs = || engine.0.load(Ordering::SeqCst);
        let (p, i) = ("5m8g-reoffer", "a");
        let mut sink = |_: Progress| {};
        let call = |tier: Option<&str>, token: Option<&str>, sink: &mut dyn FnMut(Progress)| {
            let mut a = json!({"prompt": "a demon", "width": 64, "height": 64});
            if let Some(t) = tier {
                a["tier"] = json!(t);
            }
            if let Some(t) = token {
                a["consent_token"] = json!(t);
            }
            imagegen_tool::call(p, i, &a, sink).unwrap()
        };
        let token_of = |r: &Value, tier: &str| {
            assert_eq!(r["bigger_tier_offer"]["tier"], tier, "{r}");
            r["bigger_tier_offer"]["consent_token"]
                .as_str()
                .unwrap()
                .to_string()
        };

        // Walk up once: I0 -> grant I1 -> grant I2 -> grant I3.
        let r = call(None, None, &mut sink);
        let t1 = token_of(&r, "I1");
        let r = call(Some("I1"), Some(&t1), &mut sink);
        let t2 = token_of(&r, "I2");
        let r = call(Some("I2"), Some(&t2), &mut sink);
        assert_eq!(r["grant"]["tier"], "I2", "{r}");
        let t3 = token_of(&r, "I3");
        let r = call(Some("I3"), Some(&t3), &mut sink);
        assert_eq!(r["tier"], "I3", "{r}");
        assert_eq!(r["grant"]["tier"], "I3", "{r}");
        assert!(r["bigger_tier_offer"].is_null(), "null at the ceiling: {r}");
        let before = runs();

        // Three I3 calls: no token, no offer, each runs once.
        for n in 1..=3 {
            let r = call(Some("I3"), None, &mut sink);
            assert_eq!(r["tier"], "I3", "call {n}: {r}");
            assert_eq!(r["grant"]["tier"], "I3", "call {n}: {r}");
            assert!(r["bigger_tier_offer"].is_null(), "call {n} re-offered: {r}");
            assert_eq!(runs(), before + n);
        }
        // From a granted lower tier the offer skips every granted rung: I2 and
        // I1 calls offer nothing once I3 is granted.
        for t in ["I1", "I2"] {
            let r = call(Some(t), None, &mut sink);
            assert_eq!(r["tier"], t, "{r}");
            assert!(
                r["bigger_tier_offer"].is_null(),
                "{t} re-offered a granted tier: {r}"
            );
        }
        imagegen_tool::install_seam(None);
    }
}
