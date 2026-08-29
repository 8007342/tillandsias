//! ORDER 718-ja7g — the expert inference ENDPOINT CONTRACT, and one probe that
//! says which tier is actually live.
//!
//! WHY THIS EXISTS. Three endpoint variables were READ in five places and
//! WRITTEN in none: `TILLANDSIAS_INFERENCE_ENDPOINT` (semantic_expert.rs,
//! lib-inference-state.sh, project-info.sh), `TILLANDSIAS_EMBED_ENDPOINT` and
//! `TILLANDSIAS_SPEC_EXPERT_ENDPOINT` (pipeline.rs, forge-plan.sh). The contract
//! existed only as orphan reads, so a dev host could not satisfy it: nothing
//! stated what satisfying it MEANT. This module is that statement, in code, with
//! the precedence taken from `InferenceConfig::default` rather than re-invented
//! beside it.
//!
//! THE TIERS, and what each actually needs:
//!
//!   L0  plan/ + methodology/ + spec ENVELOPE lookups. File-backed: the engine
//!       reads the working tree at query time. Needs NO endpoint and is ALWAYS
//!       ready. This is why a host with nothing configured still answers with
//!       citations — degradation here must be silent-free, never answer-free.
//!   L1  RETRIEVAL over the prose corpus. Needs an embeddings base
//!       (TILLANDSIAS_EMBED_ENDPOINT). Without it the grounded pipeline refuses
//!       typed (`confidence=unsupported`); the raw model is NOT a fallback.
//!   L2  SYNTHESIS and adversarial decomposition. Needs a chat-completions base
//!       (TILLANDSIAS_SPEC_EXPERT_ENDPOINT, defaulting through the chain below).
//!
//! L2 without L1 is a real and legitimate state — a host can synthesise without
//! retrieving — so the verdict reports the tiers INDEPENDENTLY rather than as a
//! single ladder. Collapsing them to one number is what made the previous
//! situation unreadable.
//!
//! THE TRANSPORT IS `http://` ONLY, BY CONSTRUCTION, and this is the constraint
//! the packet asked to be fixed or documented rather than left as folklore.
//! `pipeline::parse_base` — the crate's single URL parser, used by every model
//! call — begins `url.strip_prefix("http://")?`, so an `https://` base yields
//! `None` at the first hop. That is not local to one call site: it is the
//! transport the whole crate speaks. Documented here and NAMED by the probe
//! (`scheme-unsupported`) instead of being discovered as a silent nothing.
//!
//! THE OTHER TRAP IN THE PACKET IS ALREADY FIXED, and saying so is part of the
//! job: 718-ja7g was filed citing `addr.parse::<SocketAddr>()` in
//! semantic_expert.rs, which made hostnames — including the enclave's own
//! `inference:11434` — silently unusable. Order 920-pxg6 (D6) routed that path
//! through `pipeline::chat_completion`, whose `http_post_json` resolves
//! hostnames via `to_socket_addrs`. Verified by test below rather than by
//! reading the comment that claims it.

/// What a configured base URL is, before anything tries to reach it.
///
/// Separating SHAPE from REACHABILITY is the point: "you typed an https URL"
/// and "the server is down" are different problems with different fixes, and
/// the pre-718-ja7g code answered both with the same silence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BaseShape {
    /// No value, or an empty/whitespace one. Not an error — a tier that needs
    /// it is simply not configured.
    Unset,
    /// Parses as an `http://` base this crate can dispatch to.
    Usable { host: String, port: u16 },
    /// A scheme the crate cannot speak. Carries the scheme so the message can
    /// name it. `https` is the common case and the one that fails silently.
    SchemeUnsupported(String),
    /// `http://` but not parseable as host[:port] — an empty host, or a port
    /// that is not a number.
    Malformed,
}

impl BaseShape {
    /// The closed-vocabulary token for this shape. Kept next to the enum so a
    /// new variant cannot be added without a token being chosen for it.
    pub fn token(&self) -> &'static str {
        match self {
            BaseShape::Unset => "unset",
            BaseShape::Usable { .. } => "usable",
            BaseShape::SchemeUnsupported(_) => "scheme-unsupported",
            BaseShape::Malformed => "malformed",
        }
    }
}

/// Classify a base URL WITHOUT touching the network.
///
/// Pure on purpose: the env-reading wrapper is untestable in a parallel test
/// runner (std::env is process-global and Rust runs tests concurrently), and
/// every interesting case here is about the STRING. `parse_inference_endpoint`
/// had no tests at all, which is how both traps survived.
pub fn classify_base(raw: Option<&str>) -> BaseShape {
    let raw = match raw.map(str::trim) {
        None | Some("") => return BaseShape::Unset,
        Some(v) => v,
    };

    let rest = match raw.strip_prefix("http://") {
        Some(r) => r,
        None => {
            // Name the scheme rather than saying "not http". A caller who set
            // https:// needs to be told THAT, not told nothing.
            let scheme = raw
                .split_once("://")
                .map(|(s, _)| s.to_ascii_lowercase())
                .unwrap_or_else(|| "none".to_string());
            return BaseShape::SchemeUnsupported(scheme);
        }
    };

    // Path is irrelevant to reachability shape (`/v1` vs root is a ROUTE
    // question, handled by the caller that appends `/models` or
    // `/chat/completions`), so trim it before reading host:port.
    let hostport = match rest.find('/') {
        Some(i) => &rest[..i],
        None => rest,
    };
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => match p.parse::<u16>() {
            Ok(n) => (h, n),
            Err(_) => return BaseShape::Malformed,
        },
        None => (hostport, 80u16),
    };
    if host.is_empty() {
        return BaseShape::Malformed;
    }
    BaseShape::Usable {
        host: host.to_string(),
        port,
    }
}

/// THE `/v1`-VS-ROOT DISTINCTION, which the macbook asked be named in any
/// refusal this contract produces — and it is the single most common way a
/// correctly-running Ollama still yields a dead expert tier.
///
/// Ollama serves its NATIVE api at the root (`/api/tags`, `/api/generate`) and
/// an OpenAI-COMPATIBLE api under `/v1` (`/v1/models`, `/v1/chat/completions`,
/// `/v1/embeddings`). This crate speaks only the OpenAI shape. So
/// `http://host:11434` is a perfectly live Ollama and a broken value for these
/// variables; `http://host:11434/v1` is the same server and a working one.
///
/// Returns Some(advice) when the base looks like a root URL that should have
/// been a `/v1` base. Deliberately advisory: a non-Ollama OpenAI server may
/// legitimately serve at the root, so this NEVER refuses on its own — it
/// annotates a failure that has already happened.
pub fn v1_advice(base: &str) -> Option<String> {
    let trimmed = base.trim_end_matches('/');
    if trimmed.ends_with("/v1") {
        return None;
    }
    Some(format!(
        "{trimmed} has no /v1 path — if that is an Ollama ROOT url its OpenAI-compatible \
         base is {trimmed}/v1 (the root serves Ollama's NATIVE api, which this crate does \
         not speak); set the variable to the /v1 base"
    ))
}

/// Liveness of one tier, after shape classification passed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TierState {
    /// Answering the OpenAI-shape liveness route.
    Ready,
    /// Shape said it could never work; carries the shape token.
    Shape(&'static str),
    /// Shape was fine, the endpoint did not answer.
    Unreachable,
    /// L1 ONLY. The embedding endpoint answers, but no usable spec index
    /// exists, so retrieval still cannot happen.
    ///
    /// THIS VARIANT IS A SELF-CORRECTION AND THE PACKET'S OWN LESSON APPLIED
    /// TO ITSELF. The first cut of this probe reported `l1=ready` from endpoint
    /// reachability alone — the identical over-optimism it was written to
    /// expose in lib-inference-state.sh, which answers "is there an Ollama"
    /// and gets read as "can the experts work". L1 retrieval needs BOTH halves:
    /// an embeddings endpoint AND a built index. Caught on lenovinha
    /// 2026-08-29, where `spec-index-ensure.sh --where` reports
    /// serving-exists=yes with entries=0 — the serving root is present and
    /// nothing has ever been published into it. A cold tier, not a lost index,
    /// and emphatically not a ready one.
    NoIndex,
}

impl TierState {
    pub fn token(&self) -> &str {
        match self {
            TierState::Ready => "ready",
            TierState::Shape(t) => t,
            TierState::Unreachable => "unreachable",
            TierState::NoIndex => "no-index",
        }
    }
    pub fn is_ready(&self) -> bool {
        matches!(self, TierState::Ready)
    }
}

/// The resolved contract for a host: what each variable is, and what it unlocks.
///
/// PRECEDENCE IS READ FROM `InferenceConfig::default`, not restated. A second
/// copy of a precedence chain is a copy that drifts, and the drift would make
/// this probe report a configuration the engine does not actually use — the
/// worst possible failure for a diagnostic.
#[derive(Debug, Clone)]
pub struct ContractView {
    pub embed_raw: Option<String>,
    pub synth_raw: String,
    pub embed_shape: BaseShape,
    pub synth_shape: BaseShape,
}

impl ContractView {
    /// Build from an already-resolved `InferenceConfig`, so the probe and the
    /// engine cannot disagree about what is configured.
    pub fn from_config(cfg: &crate::pipeline::InferenceConfig) -> Self {
        let embed_raw = cfg.embed_base.clone();
        let synth_raw = cfg.synth_base.clone();
        Self {
            embed_shape: classify_base(embed_raw.as_deref()),
            synth_shape: classify_base(Some(&synth_raw)),
            embed_raw,
            synth_raw,
        }
    }
}

/// Render the one-line verdict.
///
/// GRAMMAR (exactly one line on stdout), in the field=value style
/// lib-inference-state.sh already uses so a shell reader can keep using the
/// same `case` idiom:
///
///   experts_probe: l0=<ready> l1=<token> l2=<token> embed=<url|-> synth=<url> advice=<name|->
///
/// l0 is `ready` unconditionally and that is not a placeholder — it is the
/// packet's negative control expressed as data. A host with nothing configured
/// must still answer L0 questions with citations, and the probe must SAY so
/// rather than reporting a uniformly dead expert system.
pub fn render_verdict(view: &ContractView, l1: &TierState, l2: &TierState) -> String {
    let embed = view.embed_raw.as_deref().unwrap_or("-");
    let advice = first_advice(view, l1, l2).unwrap_or_else(|| "-".to_string());
    format!(
        "experts_probe: l0=ready l1={} l2={} embed={} synth={} advice={}",
        l1.token(),
        l2.token(),
        embed,
        view.synth_raw,
        advice
    )
}

/// The single most useful next action, or None when everything is ready.
///
/// ONE advice, not a list: a diagnostic that emits three suggestions invites
/// the reader to try all three, and two of them will be wrong. Ordered by which
/// failure blocks the most.
fn first_advice(view: &ContractView, l1: &TierState, l2: &TierState) -> Option<String> {
    if let BaseShape::SchemeUnsupported(scheme) = &view.synth_shape {
        return Some(format!(
            "synth-scheme-{scheme}: this crate dispatches over http:// only (pipeline::parse_base); \
             an {scheme}:// base is dropped before any request is made"
        ));
    }
    if let BaseShape::SchemeUnsupported(scheme) = &view.embed_shape {
        return Some(format!(
            "embed-scheme-{scheme}: this crate dispatches over http:// only (pipeline::parse_base); \
             an {scheme}:// base is dropped before any request is made"
        ));
    }
    if matches!(view.embed_shape, BaseShape::Unset) {
        return Some(
            "embed-unset: set TILLANDSIAS_EMBED_ENDPOINT to a /v1 base to unlock L1 retrieval; \
             L0 plan and methodology answers work without it"
                .to_string(),
        );
    }
    if matches!(l1, TierState::NoIndex) {
        return Some(
            "no-spec-index: the embeddings endpoint answers but no usable index is published \
             (needs vectors.jsonl) — build it with scripts/spec-index-ensure.sh; L1 retrieval \
             needs BOTH an endpoint and an index"
                .to_string(),
        );
    }
    if !l1.is_ready()
        && let Some(raw) = view.embed_raw.as_deref()
        && let Some(a) = v1_advice(raw)
    {
        return Some(format!("embed-unreachable: {a}"));
    }
    if !l2.is_ready()
        && let Some(a) = v1_advice(&view.synth_raw)
    {
        return Some(format!("synth-unreachable: {a}"));
    }
    if !l1.is_ready() {
        return Some(
            "embed-unreachable: the base is well-formed but did not answer /models".to_string(),
        );
    }
    if !l2.is_ready() {
        return Some(
            "synth-unreachable: the base is well-formed but did not answer /models".to_string(),
        );
    }
    None
}

/// Probe one base for liveness on the OpenAI-shape `/models` route.
///
/// `/models` and not `/chat/completions`: it is a GET, it costs the endpoint
/// nothing, and every OpenAI-compatible server serving a `/v1` base answers it.
/// The same route `_tillandsias_expert_embed_state` in lib-expert-capability.sh
/// already uses, so the shell and the binary agree about what "reachable" means.
pub fn probe_base(
    shape: &BaseShape,
    base: Option<&str>,
    timeout: std::time::Duration,
) -> TierState {
    match shape {
        BaseShape::Usable { .. } => {
            let Some(b) = base else {
                return TierState::Shape("unset");
            };
            if crate::pipeline::http_get_ok(b, "/models", timeout) {
                TierState::Ready
            } else {
                TierState::Unreachable
            }
        }
        // A shape that can never dispatch is reported as itself. Trying anyway
        // would turn a typo into a three-second timeout and then report
        // `unreachable`, sending the reader to look at a server that is fine.
        other => TierState::Shape(match other {
            BaseShape::Unset => "unset",
            BaseShape::SchemeUnsupported(_) => "scheme-unsupported",
            BaseShape::Malformed => "malformed",
            BaseShape::Usable { .. } => unreachable!(),
        }),
    }
}

/// The whole probe: resolve the contract from the engine's own config, probe
/// both tiers, render one line. `timeout` is deliberately short — this is a
/// diagnostic and a hung endpoint must not hang the tool that reports it.
pub fn run(timeout: std::time::Duration) -> (String, bool) {
    let cfg = crate::pipeline::InferenceConfig::default();
    let view = ContractView::from_config(&cfg);
    // L1 = endpoint AND index. Checked in that order so the message names the
    // half that is actually missing rather than the first one looked at.
    let mut l1 = probe_base(&view.embed_shape, view.embed_raw.as_deref(), timeout);
    if l1.is_ready() && crate::spec_index::resolve_dir().is_none() {
        l1 = TierState::NoIndex;
    }
    let l2 = probe_base(&view.synth_shape, Some(&view.synth_raw), timeout);
    let all_ready = l1.is_ready() && l2.is_ready();
    (render_verdict(&view, &l1, &l2), all_ready)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── the two traps 718-ja7g was filed about ─────────────────────────────

    #[test]
    fn hostname_endpoints_are_usable_the_socketaddr_trap_is_gone() {
        // The packet cites `addr.parse::<SocketAddr>()`, which accepts only
        // numeric IP:port and so made the enclave's own DNS alias unusable.
        // 920-pxg6 (D6) removed it. Asserted rather than trusted: this is the
        // exact value the forge sets.
        assert_eq!(
            classify_base(Some("http://inference:11434/v1")),
            BaseShape::Usable {
                host: "inference".to_string(),
                port: 11434
            }
        );
    }

    #[test]
    fn https_is_named_not_silently_dropped() {
        // The live trap. Before this, an https base produced None and the
        // caller fell back to a default endpoint the operator never chose,
        // with nothing said.
        assert_eq!(
            classify_base(Some("https://models.example:443/v1")),
            BaseShape::SchemeUnsupported("https".to_string())
        );
        let view = ContractView {
            embed_raw: Some("https://models.example/v1".to_string()),
            synth_raw: "http://inference:11434/v1".to_string(),
            embed_shape: classify_base(Some("https://models.example/v1")),
            synth_shape: classify_base(Some("http://inference:11434/v1")),
        };
        let line = render_verdict(
            &view,
            &TierState::Shape("scheme-unsupported"),
            &TierState::Ready,
        );
        assert!(line.contains("l1=scheme-unsupported"), "{line}");
        assert!(
            line.contains("http:// only"),
            "advice must name the constraint: {line}"
        );
    }

    // ── the /v1-vs-root distinction the macbook asked to be named ──────────

    #[test]
    fn root_url_advice_names_the_v1_distinction() {
        let a = v1_advice("http://host:11434").expect("a root url should draw advice");
        assert!(a.contains("/v1"), "{a}");
        assert!(
            a.contains("NATIVE"),
            "the advice must explain WHY the root fails: {a}"
        );
        assert!(v1_advice("http://host:11434/v1").is_none());
        assert!(
            v1_advice("http://host:11434/v1/").is_none(),
            "a trailing slash is still a /v1 base"
        );
    }

    // ── shape classification ───────────────────────────────────────────────

    #[test]
    fn unset_and_blank_are_unset_not_malformed() {
        assert_eq!(classify_base(None), BaseShape::Unset);
        assert_eq!(classify_base(Some("")), BaseShape::Unset);
        assert_eq!(classify_base(Some("   ")), BaseShape::Unset);
    }

    #[test]
    fn malformed_is_distinguished_from_unset_and_from_scheme() {
        assert_eq!(classify_base(Some("http://:11434")), BaseShape::Malformed);
        assert_eq!(
            classify_base(Some("http://host:notaport")),
            BaseShape::Malformed
        );
        // No scheme at all is a scheme problem, not a malformed host — the
        // fix is different ("add http://"), so the token must differ.
        assert_eq!(
            classify_base(Some("inference:11434")),
            BaseShape::SchemeUnsupported("none".to_string())
        );
    }

    #[test]
    fn default_port_is_applied_when_absent() {
        assert_eq!(
            classify_base(Some("http://host/v1")),
            BaseShape::Usable {
                host: "host".to_string(),
                port: 80
            }
        );
    }

    // ── the negative control, as a test rather than a promise ──────────────

    #[test]
    fn l0_is_ready_even_with_nothing_configured() {
        // The packet's negative control: with no endpoint set, L0 still answers.
        // The verdict must SAY that, or an operator reading a wall of `unset`
        // concludes the whole expert system is dead and stops asking it
        // questions it can still answer.
        let view = ContractView {
            embed_raw: None,
            synth_raw: "http://inference:11434/v1".to_string(),
            embed_shape: BaseShape::Unset,
            synth_shape: classify_base(Some("http://inference:11434/v1")),
        };
        let line = render_verdict(&view, &TierState::Shape("unset"), &TierState::Unreachable);
        assert!(line.starts_with("experts_probe: l0=ready"), "{line}");
        assert!(line.contains("l1=unset"), "{line}");
        assert!(
            line.contains("embed=-"),
            "an unset embed base renders as '-': {line}"
        );
        assert!(
            line.contains("L0 plan and methodology answers work without it"),
            "the advice must not imply the whole system is down: {line}"
        );
    }

    #[test]
    fn l1_needs_an_index_not_just_an_endpoint() {
        // The self-correction, pinned. A reachable embeddings endpoint with no
        // published index is NOT ready for retrieval, and reporting it as ready
        // would repeat — inside the very tool built to expose it — the
        // over-optimism this packet is about.
        let view = ContractView {
            embed_raw: Some("http://h:1/v1".to_string()),
            synth_raw: "http://h:1/v1".to_string(),
            embed_shape: classify_base(Some("http://h:1/v1")),
            synth_shape: classify_base(Some("http://h:1/v1")),
        };
        let line = render_verdict(&view, &TierState::NoIndex, &TierState::Ready);
        assert!(line.contains("l1=no-index"), "{line}");
        assert!(
            line.contains("BOTH an endpoint and an index"),
            "the advice must say which half is missing: {line}"
        );
        // no-index is distinct from unreachable: different half, different fix.
        assert_ne!(TierState::NoIndex.token(), TierState::Unreachable.token());
        assert!(!TierState::NoIndex.is_ready());
    }

    #[test]
    fn verdict_is_exactly_one_line() {
        let view = ContractView {
            embed_raw: Some("http://h:1/v1".to_string()),
            synth_raw: "http://h:1/v1".to_string(),
            embed_shape: classify_base(Some("http://h:1/v1")),
            synth_shape: classify_base(Some("http://h:1/v1")),
        };
        let line = render_verdict(&view, &TierState::Ready, &TierState::Ready);
        assert_eq!(line.lines().count(), 1, "{line}");
        assert!(
            line.contains("advice=-"),
            "all-ready emits no advice: {line}"
        );
    }

    #[test]
    fn scheme_advice_prefers_synth_then_embed_and_never_emits_two() {
        let view = ContractView {
            embed_raw: Some("https://e/v1".to_string()),
            synth_raw: "https://s/v1".to_string(),
            embed_shape: classify_base(Some("https://e/v1")),
            synth_shape: classify_base(Some("https://s/v1")),
        };
        let line = render_verdict(
            &view,
            &TierState::Shape("scheme-unsupported"),
            &TierState::Shape("scheme-unsupported"),
        );
        assert!(line.contains("advice=synth-scheme-https"), "{line}");
        assert!(
            !line.contains("embed-scheme"),
            "one advice, not a list: {line}"
        );
    }
}
