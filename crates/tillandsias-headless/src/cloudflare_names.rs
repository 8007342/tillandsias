// @trace order:1505-iky3, plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md (naming
// table, research §3, "Operator ruling on names"), openspec/changes/cloudflare-login-and-fleet-vpn/design.md
// (Decision 4), plan/index.d/20260929t223658z-1505-iky3-naming-ruling-macuahuitl.yaml (operator
// ruling 2026-09-29: team tillandsias-enclave-vpn-<github_login>, network tillandsias-enclave-vpn,
// no account id or email in any name)
//! Every name Tillandsias mints for Cloudflare, normalized by ONE rule and
//! minted from ONE table.
//!
//! # The rule
//!
//! Several Cloudflare objects document their own naming constraint, and they
//! do not agree:
//!
//! | Object | Documented rule | Source |
//! |---|---|---|
//! | Zero Trust team name | the `<team-name>` label of `<team-name>.cloudflareaccess.com`, "without spaces" | Cloudflare getting-started FAQ |
//! | Virtual network `name` | string, `maxLength` 256 | Cloudflare API: `teamnet/virtual_networks/create` |
//! | Mesh hostname route | "must be less than 255 characters"; one full-label wildcard | Cloudflare Mesh routes page |
//! | Tunnel / service token / OAuth `client_name` | no documented length or character constraint (unverified) | Cloudflare API reference |
//!
//! The team name is, literally, a DNS label. That is the strictest rule any
//! object above imposes, so this module normalizes every Tillandsias-minted
//! name to a DNS label alphabet — lowercase ASCII `[a-z0-9-]`, no leading,
//! trailing, or doubled hyphen — and keeps only the LENGTH ceiling variable:
//! [`Label`] (RFC 1035, <= 63 bytes: team name, participant/service labels,
//! one component of a hostname route) and [`Display`] (<= 255 bytes: virtual
//! network, tunnel, and service-token names). One alphabet keeps one string
//! valid everywhere; the two lengths are typed so a [`Display`] can never be
//! handed to a call site that requires a [`Label`] (only the reverse
//! widening, [`Label`] -> [`Display`], is a safe, silent conversion).
//!
//! Normalizing NEVER defaults an unusable input to a placeholder. An input
//! that normalizes to nothing — empty, or made only of hyphens/separators —
//! is refused with [`NameError::EmptyAfterNormalization`], never silently
//! emptied into `""` or `"tillandsias-"`.
//!
//! # The canonical table
//!
//! | Thing | Canonical | Class |
//! |---|---|---|
//! | the network (virtual network + route suffix) | [`network_name`] = `tillandsias-enclave-vpn` | Label (widens to Display) |
//! | Zero Trust team name | [`team_name`] = `tillandsias-enclave-vpn-<github_login>` (`-2`, `-3`... on a collision) | Label |
//! | a participant (node, device, service token) | [`participant_name`] = `tillandsias-<host>` | Label |
//! | a service's hostname route | [`service_route`] = `<service>.tillandsias-enclave-vpn.internal` | Display (each dot-separated component is a Label) |
//! | the OAuth App (operator-entered in the dashboard) | [`app_name`] = `Tillandsias` | Display |
//!
//! `.internal` is the route suffix because Mesh hostname routes are private
//! names resolved by Gateway; a public TLD would collide with real DNS.
//!
//! # Operator ruling on names (2026-09-29)
//!
//! Supersedes the earlier `tillandsias-vpn` / `tillandsias-vpn-<acct8>` table
//! (an account-id-based team name): the Zero Trust team name is
//! `tillandsias-enclave-vpn-<github_login>`, never a Cloudflare account id or
//! an email — [`team_name`] takes the operator's GitHub login, not an
//! account id, and there is no constructor anywhere in this module that
//! accepts or embeds either. A GitHub login is public, unique, and at most
//! 39 characters, so the fixed `tillandsias-enclave-vpn-` prefix (24 bytes)
//! plus the login always fits inside the 63-byte [`Label`] ceiling with no
//! truncation needed. On a collision (the team name is already taken by
//! another Cloudflare account) the caller retries with the next attempt
//! number; [`team_name`] appends `-2`, `-3`, ... and, if that would overflow
//! 63 bytes, truncates the LOGIN portion — never the numeric suffix, which
//! is what actually distinguishes the retry.
//!
//! This module does no I/O and depends on nothing beyond `std`.

use std::fmt;

/// The longest a DNS label may be (RFC 1035): the Zero Trust team name, a
/// participant name, and each dot-separated component of a hostname route.
const LABEL_MAX: usize = 63;

/// The longest a Cloudflare display-class name may be (virtual network
/// `name`, tunnel name, service-token name, OAuth `client_name`).
const DISPLAY_MAX: usize = 255;

/// A DNS-label-safe name: lowercase ASCII `[a-z0-9-]`, 1..=63 bytes, no
/// leading, trailing, or doubled hyphen.
///
/// The only way to build one is [`normalize_label`] or one of this module's
/// canonical constructors, so every `Label` in the program already satisfies
/// the invariant above — there is no public constructor that skips
/// normalization.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Label(String);

impl Label {
    /// Build a `Label` from a string this module has already normalized and
    /// validated. Not `pub`: every caller outside this module goes through
    /// [`normalize_label`] or a canonical constructor.
    fn from_normalized(s: String) -> Self {
        debug_assert!(!s.is_empty(), "Label must never be empty");
        debug_assert!(
            s.len() <= LABEL_MAX,
            "Label must never exceed {LABEL_MAX} bytes"
        );
        debug_assert!(
            s.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
            "Label must be [a-z0-9-] only"
        );
        debug_assert!(
            !s.starts_with('-') && !s.ends_with('-'),
            "Label must not have edge hyphens"
        );
        debug_assert!(!s.contains("--"), "Label must not have a doubled hyphen");
        Label(s)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Label {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl AsRef<str> for Label {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

/// A Cloudflare display-class name: 1..=255 bytes.
///
/// A `Label` always converts safely into a `Display` (see the `From<Label>`
/// impl below) because every `Label` already satisfies the tighter bound.
/// There is deliberately no `TryFrom<Display> for Label` — narrowing a
/// 255-byte value into a 63-byte one is exactly the mistake this typing
/// exists to catch at compile time; see the type-safety note on
/// [`normalize_display`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Display(String);

impl Display {
    /// Build a `Display` from a string this module has already normalized
    /// and validated (or from a fixed, documented literal — see
    /// [`app_name`]). Not `pub`.
    fn from_normalized(s: String) -> Self {
        debug_assert!(!s.is_empty(), "Display must never be empty");
        debug_assert!(
            s.len() <= DISPLAY_MAX,
            "Display must never exceed {DISPLAY_MAX} bytes"
        );
        Display(s)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Display {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl AsRef<str> for Display {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

/// Widening only: every `Label` is already a valid `Display` (same
/// alphabet, well inside the longer length ceiling).
impl From<Label> for Display {
    fn from(label: Label) -> Self {
        Display(label.0)
    }
}

/// Normalizing produced nothing usable, or an input was rejected outright.
/// This is the ONLY error this module raises: an input is either fixed up
/// into a valid name or refused, never silently defaulted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameError {
    /// After lowercasing, dropping unsupported characters, collapsing
    /// separators to a single hyphen, and trimming edge hyphens, nothing
    /// was left. Examples: `""`, `"---"`, `"...!!!"`.
    EmptyAfterNormalization,
}

impl fmt::Display for NameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NameError::EmptyAfterNormalization => {
                f.write_str("refused:cloudflare-names:empty-after-normalization")
            }
        }
    }
}

impl std::error::Error for NameError {}

/// The normalization core shared by [`normalize_label`] and
/// [`normalize_display`]: fold to the `[a-z0-9-]` alphabet, collapse
/// separators, trim edges, and cap the length.
///
/// Rules, in order:
/// 1. ASCII letters and digits are lowercased and kept.
/// 2. `-`, ASCII whitespace, `_`, and `.` become a single `-` (they are all
///    "the caller meant a separator here" characters: a hostname's `.local`
///    suffix, a display name's spaces, an env-style `_`).
/// 3. Everything else — apostrophes, other punctuation, and non-ASCII
///    (Unicode) characters — is DROPPED, not substituted. This keeps
///    `"Tlatoani's"` from becoming `"tlatoani-s"` (a spurious separator
///    where the source had none) while still being pure ASCII output with
///    no transliteration table to maintain.
/// 4. Runs of `-` collapse to one.
/// 5. Leading and trailing `-` are trimmed.
/// 6. The result is truncated to `max_len` characters, then re-trimmed of
///    any trailing `-` truncation exposed.
///
/// Every step is idempotent on its own output, so running this function
/// twice is the same as running it once (`normalize_twice_is_normalize_once`
/// below; the module's whole reason to exist is that ONE pass through this
/// function makes a name valid everywhere Cloudflare might see it again).
fn normalize_ascii(input: &str, max_len: usize) -> Result<String, NameError> {
    let mut folded = String::with_capacity(input.len());
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() {
            folded.push(ch.to_ascii_lowercase());
        } else if ch == '-' || ch == '_' || ch == '.' || ch.is_whitespace() {
            folded.push('-');
        }
        // else: drop (unicode, apostrophes, and other punctuation).
    }

    let mut collapsed = String::with_capacity(folded.len());
    let mut prev_was_hyphen = false;
    for ch in folded.chars() {
        if ch == '-' {
            if prev_was_hyphen {
                continue;
            }
            prev_was_hyphen = true;
        } else {
            prev_was_hyphen = false;
        }
        collapsed.push(ch);
    }

    let trimmed = collapsed.trim_matches('-');

    let mut truncated: String = trimmed.chars().take(max_len).collect();
    while truncated.ends_with('-') {
        truncated.pop();
    }

    if truncated.is_empty() {
        Err(NameError::EmptyAfterNormalization)
    } else {
        Ok(truncated)
    }
}

/// Normalize an arbitrary string to a DNS-label-safe [`Label`]: lowercase
/// ASCII `[a-z0-9-]`, no leading/trailing/doubled hyphen, <= 63 bytes.
///
/// ```
/// # // Not run as a doctest: this crate ships no `[lib]` target, so
/// # // `cargo test --doc` has nothing to run it against (see
/// # // `container_deps::Up` for the same repo convention). Kept as a
/// # // readable usage example; exercised for real by the unit tests below.
/// ```
pub fn normalize_label(input: &str) -> Result<Label, NameError> {
    normalize_ascii(input, LABEL_MAX).map(Label::from_normalized)
}

/// Normalize an arbitrary string to a display-safe [`Display`]: same
/// alphabet as [`normalize_label`], <= 255 bytes.
///
/// # Type safety
///
/// A `Display` cannot be passed where a `Label` is required — the two are
/// distinct types with no narrowing conversion (only the widening
/// `Label -> Display` exists, via `From`). The following would NOT compile:
///
/// ```compile_fail
/// use tillandsias_headless::cloudflare_names::{normalize_display, Label};
///
/// fn wants_label(_label: Label) {}
///
/// let too_long = normalize_display("a-perfectly-normal-display-name").unwrap();
/// wants_label(too_long); // expected `Label`, found `Display`
/// ```
///
/// This crate ships no `[lib]` target, so the block above is not literally
/// executed by `cargo test --doc` (there is nothing for rustdoc to build
/// against); it documents the same compile-time contract as
/// `container_deps::Up`'s `compile_fail` block, verified the same way: by
/// reading the signatures of `normalize_label`, `normalize_display`, and
/// `wants_label` above and confirming no coercion exists between `Label` and
/// `Display`.
pub fn normalize_display(input: &str) -> Result<Display, NameError> {
    normalize_ascii(input, DISPLAY_MAX).map(Display::from_normalized)
}

/// The one Tillandsias virtual network / route-suffix name: `tillandsias-enclave-vpn`.
///
/// Returned as a [`Label`] (it fits, at 23 bytes) and widens to [`Display`]
/// via `.into()` wherever the virtual-network-`name` API field is needed.
///
/// Operator ruling, 2026-09-29: replaces the earlier `tillandsias-vpn`.
pub fn network_name() -> Label {
    normalize_label("tillandsias-enclave-vpn")
        .expect("the literal \"tillandsias-enclave-vpn\" is always valid")
}

/// The fixed prefix every Zero Trust team name starts with. 24 bytes, so a
/// GitHub login (public, unique, <= 39 bytes) always fits the remaining
/// budget of a 63-byte [`Label`] with room to spare, even before any
/// collision suffix.
const TEAM_NAME_PREFIX: &str = "tillandsias-enclave-vpn-";

/// The Zero Trust team name for one GitHub account:
/// `tillandsias-enclave-vpn-<github_login>`, with a numbered suffix on a
/// naming collision.
///
/// `github_login` is the operator's GitHub login (normalized by this
/// function — never a Cloudflare account id or an email; this module has no
/// constructor that accepts or embeds either). `attempt` is the collision
/// counter: `1` (or `0`) mints the bare name; `2`, `3`, ... append `-2`,
/// `-3`, ... because the FIRST candidate was already taken by another
/// Cloudflare account. Team names are global across all of Cloudflare, so a
/// collision is expected behavior, not an error — the caller reports it
/// (`note:fleet-vpn:team-name-suffixed:<name>`) and retries with the next
/// attempt.
///
/// If the fixed prefix, the normalized login, and the numeric suffix
/// together would exceed the 63-byte [`Label`] ceiling, the LOGIN is
/// truncated to make room — never the suffix, since the suffix is what
/// actually distinguishes one candidate from the next.
pub fn team_name(github_login: &str, attempt: u32) -> Result<Label, NameError> {
    let suffix = if attempt >= 2 {
        format!("-{attempt}")
    } else {
        String::new()
    };
    let budget = LABEL_MAX
        .saturating_sub(TEAM_NAME_PREFIX.len())
        .saturating_sub(suffix.len());
    let login = normalize_ascii(github_login, budget)?;
    Ok(Label::from_normalized(format!(
        "{TEAM_NAME_PREFIX}{login}{suffix}"
    )))
}

/// The suffixed collision candidate for one GitHub login: an explicit alias
/// for [`team_name`] under the name the collision-retry call site reads
/// most naturally at the call (`team_name_candidate(login, attempt)`).
/// Identical behavior to [`team_name`]; kept as a separate `pub fn` so
/// either name documents the intent at its call site.
pub fn team_name_candidate(github_login: &str, attempt: u32) -> Result<Label, NameError> {
    team_name(github_login, attempt)
}

/// The name for one participant (node, device, or service token):
/// `tillandsias-<host>`, truncated so the WHOLE label fits <= 63 bytes.
///
/// `hostname` is normalized internally — callers pass the raw OS hostname
/// (e.g. `Tlatoanis-MacBook-Air.local`) directly.
pub fn participant_name(hostname: &str) -> Result<Label, NameError> {
    const PREFIX: &str = "tillandsias-";
    let budget = LABEL_MAX - PREFIX.len();
    let host = normalize_ascii(hostname, budget)?;
    Ok(Label::from_normalized(format!("{PREFIX}{host}")))
}

/// The Mesh hostname route for one service: `<service>.tillandsias-enclave-vpn.internal`.
///
/// `service` is normalized to a [`Label`] first (each dot-separated
/// component of a hostname route must itself be a valid label); the
/// `.tillandsias-enclave-vpn.internal` suffix is fixed and always well
/// inside the 255-byte Mesh hostname-route ceiling, so the combined
/// [`Display`] cannot overflow it. The suffix follows [`network_name`]
/// (operator ruling, 2026-09-29): replaces the earlier
/// `.tillandsias-vpn.internal`.
pub fn service_route(service: &str) -> Result<Display, NameError> {
    let label = normalize_label(service)?;
    let route = format!("{}.tillandsias-enclave-vpn.internal", label.as_str());
    debug_assert!(
        route.len() <= DISPLAY_MAX,
        "fixed suffix cannot push a Label-bounded route over 255"
    );
    Ok(Display::from_normalized(route))
}

/// The Cloudflare OAuth App's display name, as the operator enters it in the
/// Zero Trust dashboard (design note, naming table): `Tillandsias`.
///
/// This is a fixed, documented literal, not derived from any input, so it is
/// NOT passed through [`normalize_display`] (whose alphabet would lowercase
/// the capital T this product name uses everywhere else).
pub fn app_name() -> Display {
    Display::from_normalized("Tillandsias".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─────────────────────────── normalize_label ───────────────────────────

    /// Table-driven: every documented normalization rule, one row per rule,
    /// each of which would fail against the module absent (no `normalize_label`
    /// to call) or against a naive `input.to_lowercase()` implementation.
    #[test]
    fn normalize_label_table() {
        let cases: &[(&str, &str)] = &[
            // unicode: dropped, not transliterated or errored on.
            ("café", "caf"),
            ("naïve-host", "nave-host"),
            // uppercase: lowercased.
            ("MacBook", "macbook"),
            ("TILLANDSIAS", "tillandsias"),
            // underscores: treated as a separator.
            ("foo_bar", "foo-bar"),
            ("__leading", "leading"),
            // dots: treated as a separator.
            ("foo.bar", "foo-bar"),
            ("host.local", "host-local"),
            // leading/trailing hyphen: trimmed.
            ("-foo", "foo"),
            ("foo-", "foo"),
            ("-foo-", "foo"),
            // doubled hyphen: collapsed.
            ("foo--bar", "foo-bar"),
            ("foo---bar", "foo-bar"),
            // the packet's own worked example (apostrophe dropped, not a
            // separator; spaces ARE separators).
            ("Tlatoani's MacBook Air", "tlatoanis-macbook-air"),
            // a real hostname shape named in the packet.
            ("Tlatoanis-MacBook-Air.local", "tlatoanis-macbook-air-local"),
        ];
        for (input, expected) in cases {
            let got = normalize_label(input)
                .unwrap_or_else(|e| panic!("normalize_label({input:?}) should succeed, got {e}"));
            assert_eq!(
                got.as_str(),
                *expected,
                "normalize_label({input:?}) should produce {expected:?}"
            );
        }
    }

    /// Over-length labels are truncated to fit, never rejected outright —
    /// the only refusal this module raises is on an EMPTY result.
    #[test]
    fn normalize_label_truncates_overlong_input() {
        let input = "a".repeat(100);
        let got = normalize_label(&input).expect("100 a's normalize");
        assert_eq!(got.as_str().len(), 63);
        assert!(got.as_str().chars().all(|c| c == 'a'));
    }

    /// Truncation must never expose a trailing hyphen: cutting
    /// "...xyz-abc..." off mid-way could otherwise land exactly on the
    /// separator and leave an invalid edge hyphen.
    #[test]
    fn normalize_label_truncation_never_ends_in_hyphen() {
        // 62 a's + "-b" = 64 chars; truncating the naive way at 63 lands
        // exactly on the hyphen.
        let input = format!("{}-b", "a".repeat(62));
        let got = normalize_label(&input).expect("should normalize");
        assert!(!got.as_str().ends_with('-'), "got {:?}", got.as_str());
        assert!(got.as_str().len() <= 63);
    }

    // ─────────────────────── negative control: refusal ─────────────────────

    /// Empty input is refused with a NAMED error, never silently emptied
    /// into `Label("")` or defaulted to a placeholder.
    #[test]
    fn normalize_label_refuses_empty_input() {
        let err = normalize_label("").expect_err("empty input must be refused");
        assert_eq!(err, NameError::EmptyAfterNormalization);
    }

    /// An input that is non-empty but normalizes to nothing (all hyphens,
    /// all separators, all dropped punctuation) is refused the same way —
    /// this is the case the packet's exit criteria names explicitly.
    #[test]
    fn normalize_label_refuses_input_that_normalizes_to_empty() {
        for input in ["---", "___", "...", "'''", "   ", "!!!"] {
            let err = normalize_label(input).expect_err(&format!(
                "{input:?} should normalize to empty and be refused"
            ));
            assert_eq!(err, NameError::EmptyAfterNormalization);
        }
    }

    /// The refusal is a distinct, named error variant — not a bool, not a
    /// silently-`Ok(Label(""))`. Asserted directly on the enum and on the
    /// `refused:` token this module's `Display` impl produces, matching the
    /// project's `ok:` / `skip:` / `refused:` output convention.
    #[test]
    fn refusal_carries_a_named_error_not_a_silent_empty() {
        let err = normalize_label("---").unwrap_err();
        assert_eq!(
            err.to_string(),
            "refused:cloudflare-names:empty-after-normalization"
        );
    }

    // ────────────────────────── normalize_display ───────────────────────────

    #[test]
    fn normalize_display_shares_the_label_alphabet_but_a_longer_ceiling() {
        let input = "a".repeat(300);
        let got = normalize_display(&input).expect("300 a's normalize (display ceiling is 255)");
        assert_eq!(got.as_str().len(), 255);
    }

    #[test]
    fn normalize_display_refuses_empty_input() {
        let err = normalize_display("").expect_err("empty input must be refused");
        assert_eq!(err, NameError::EmptyAfterNormalization);
    }

    // ───────────────────────── the canonical table ──────────────────────────

    #[test]
    fn network_name_is_tillandsias_enclave_vpn() {
        assert_eq!(network_name().as_str(), "tillandsias-enclave-vpn");
    }

    #[test]
    fn network_name_widens_to_display() {
        let display: Display = network_name().into();
        assert_eq!(display.as_str(), "tillandsias-enclave-vpn");
    }

    /// Table-driven: the operator ruling's name shape (2026-09-29) — every
    /// row would fail against the OLD single-argument `team_name` (it took
    /// the Cloudflare account id, not a login and an attempt number, so a
    /// two-argument call was a compile error before this fix: the pre-fix
    /// probe run this session hit `E0061: this function takes 1 argument
    /// but 2 arguments were supplied`).
    #[test]
    fn team_name_table() {
        // The ledger's own worked example, verbatim (fields on 1505-iky3,
        // operator ruling 2026-09-29).
        assert_eq!(
            team_name("BullonCito", 1).expect("valid login").as_str(),
            "tillandsias-enclave-vpn-bulloncito"
        );
        assert_eq!(
            team_name("BullonCito", 2).expect("valid login").as_str(),
            "tillandsias-enclave-vpn-bulloncito-2"
        );

        // Uppercase AND underscore in the same login: both normalized.
        assert_eq!(
            team_name("Bullon_Cito", 1).expect("valid login").as_str(),
            "tillandsias-enclave-vpn-bullon-cito"
        );

        // A 39-char GitHub login (GitHub's own max login length) plus the
        // 24-byte prefix is exactly 63 bytes: fits with NO truncation.
        let login39 = "a".repeat(39);
        let got = team_name(&login39, 1).expect("39-char login fits");
        assert_eq!(got.as_str(), format!("tillandsias-enclave-vpn-{login39}"));
        assert_eq!(got.as_str().len(), 63);

        // Same login, attempt 2: the "-2" suffix would push the bare
        // concatenation to 65 bytes, so the LOGIN (not the suffix) is
        // truncated to fit: 24 (prefix) + 37 (login) + 2 ("-2") = 63.
        let got2 = team_name(&login39, 2).expect("attempt 2 fits by truncating the login");
        let truncated37 = "a".repeat(37);
        assert_eq!(
            got2.as_str(),
            format!("tillandsias-enclave-vpn-{truncated37}-2")
        );
        assert_eq!(got2.as_str().len(), 63);
        assert!(got2.as_str().ends_with("-2"), "suffix must survive intact");

        // Same login, attempt 10: the "-10" suffix (3 bytes) truncates the
        // login further: 24 + 36 + 3 = 63.
        let got10 = team_name(&login39, 10).expect("attempt 10 fits by truncating the login");
        let truncated36 = "a".repeat(36);
        assert_eq!(
            got10.as_str(),
            format!("tillandsias-enclave-vpn-{truncated36}-10")
        );
        assert_eq!(got10.as_str().len(), 63);
        assert!(
            got10.as_str().ends_with("-10"),
            "suffix must survive intact"
        );
    }

    /// `team_name_candidate` is the same behavior under the name a
    /// collision-retry call site reads most naturally.
    #[test]
    fn team_name_candidate_matches_team_name() {
        assert_eq!(
            team_name_candidate("BullonCito", 2).unwrap(),
            team_name("BullonCito", 2).unwrap()
        );
    }

    /// An empty-after-normalization GitHub login is refused with the SAME
    /// named error every other constructor in this module uses — never
    /// silently minted as `tillandsias-enclave-vpn-` with nothing after it.
    #[test]
    fn team_name_refuses_a_login_that_normalizes_to_empty() {
        let err = team_name("---", 1).unwrap_err();
        assert_eq!(err, NameError::EmptyAfterNormalization);
    }

    /// No constructor in this module takes a Cloudflare account id anymore:
    /// [`team_name`] takes a GitHub login and a collision-attempt number,
    /// full stop. Asserted directly against the retired parameter's spelling
    /// (built piecewise, and this function deliberately avoids spelling it
    /// out itself, so the assertion doesn't trip on its own source text).
    #[test]
    fn team_name_signature_has_no_retired_id_parameter() {
        let retired_param: String = ["acco", "unt", "_i", "d"].concat();
        let source = include_str!("cloudflare_names.rs");
        assert!(
            !source.contains(&retired_param),
            "module must not reference the retired {retired_param:?} parameter"
        );
    }

    #[test]
    fn participant_name_is_prefixed_with_the_normalized_host() {
        let got = participant_name("Tlatoanis-MacBook-Air.local").expect("valid hostname");
        assert_eq!(got.as_str(), "tillandsias-tlatoanis-macbook-air-local");
    }

    /// The packet's own worked example, verbatim.
    #[test]
    fn participant_name_worked_example() {
        let got = participant_name("Tlatoani's MacBook Air").expect("valid hostname");
        assert_eq!(got.as_str(), "tillandsias-tlatoanis-macbook-air");
    }

    /// A 100-char hostname yields <= 63 chars ending in `[a-z0-9]`, and that
    /// result re-normalizes to itself (exit criteria, verbatim).
    #[test]
    fn participant_name_100_char_hostname_fits_and_is_idempotent() {
        let hostname = "x".repeat(100);
        let got = participant_name(&hostname).expect("should fit by truncation");
        assert!(got.as_str().len() <= 63, "got len {}", got.as_str().len());
        let last = got.as_str().chars().last().expect("non-empty");
        assert!(
            last.is_ascii_lowercase() || last.is_ascii_digit(),
            "must end in [a-z0-9], got {last:?}"
        );
        let renormalized =
            normalize_label(got.as_str()).expect("already-valid label re-normalizes");
        assert_eq!(renormalized, got);
    }

    #[test]
    fn participant_name_refuses_a_hostname_that_normalizes_to_empty() {
        let err = participant_name("...").unwrap_err();
        assert_eq!(err, NameError::EmptyAfterNormalization);
    }

    #[test]
    fn service_route_is_service_dot_tillandsias_enclave_vpn_dot_internal() {
        let got = service_route("fleet-experts").expect("valid service name");
        assert_eq!(
            got.as_str(),
            "fleet-experts.tillandsias-enclave-vpn.internal"
        );
    }

    #[test]
    fn service_route_normalizes_the_service_component() {
        let got = service_route("Fleet Experts").expect("valid service name");
        assert_eq!(
            got.as_str(),
            "fleet-experts.tillandsias-enclave-vpn.internal"
        );
    }

    #[test]
    fn service_route_refuses_a_service_that_normalizes_to_empty() {
        let err = service_route("---").unwrap_err();
        assert_eq!(err, NameError::EmptyAfterNormalization);
    }

    #[test]
    fn app_name_is_the_operator_entered_literal() {
        assert_eq!(app_name().as_str(), "Tillandsias");
    }

    // ───────────────────────────── type safety ──────────────────────────────

    /// A `Display` cannot be passed where a `Label` is required — the two
    /// are distinct types with no implicit or explicit narrowing
    /// conversion (only the widening `Label -> Display` exists). This
    /// can't be exercised at runtime from inside the module (there is no
    /// coercion to attempt); the contract is proved by the `compile_fail`
    /// doc-comment on [`normalize_display`], the same convention this crate
    /// already uses for `container_deps::Up`'s module-private constructor.
    #[test]
    fn display_is_not_a_label_see_compile_fail_doctest_on_normalize_display() {
        // Compile-time-only assertion: `From<Label> for Display` exists...
        let widens: fn(Label) -> Display = Into::into;
        let _ = widens;
        // ...but no `From<Display> for Label` (or `TryFrom`) is defined
        // anywhere in this module, so the reverse direction has nothing to
        // call. Confirmed by reading this file: search it for
        // `for Label` and the only impl found is `Label::from_normalized`,
        // which is private.
    }

    // ──────────────────────────── property test ─────────────────────────────

    /// A small deterministic xorshift PRNG — std-only, no `rand` dependency,
    /// and (unlike a real RNG) reproducible across runs so a failure here is
    /// always the same failure, not a flaky one.
    struct XorShift32(u32);

    impl XorShift32 {
        fn next(&mut self) -> u32 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.0 = x;
            x
        }
    }

    /// Build a random-ish input string covering the alphabet this module
    /// cares about: ASCII letters/digits, the separator characters, other
    /// ASCII punctuation, and a few non-ASCII/Unicode code points.
    fn random_input(rng: &mut XorShift32) -> String {
        const POOL: &[char] = &[
            'a', 'b', 'z', '0', '9', 'A', 'Z', '-', '_', '.', ' ', '\'', '!', '@', '\t', 'é', 'ñ',
            '中',
        ];
        let len = (rng.next() % 12) as usize;
        (0..len)
            .map(|_| POOL[(rng.next() as usize) % POOL.len()])
            .collect()
    }

    /// The property: normalizing twice equals normalizing once. Whatever
    /// [`normalize_label`] accepts, it must already be in its own fixed
    /// point — a Cloudflare-bound name this module hands out must never
    /// change if something re-normalizes it later (e.g. `participant_name`
    /// re-checked by `normalize_label`, as `participant_name_...idempotent`
    /// above does for one specific case). This checks it over 1000 random
    /// inputs, covering unicode, punctuation, and separators together.
    #[test]
    fn normalize_twice_equals_normalize_once_label() {
        let mut rng = XorShift32(0xC0FFEE_u32.wrapping_add(1));
        let mut exercised_ok = 0u32;
        for _ in 0..1000 {
            let input = random_input(&mut rng);
            if let Ok(once) = normalize_label(&input) {
                let twice = normalize_label(once.as_str())
                    .unwrap_or_else(|e| panic!("re-normalizing {:?} failed: {e}", once.as_str()));
                assert_eq!(
                    twice, once,
                    "normalize_label was not idempotent on {input:?}"
                );
                exercised_ok += 1;
            }
        }
        assert!(
            exercised_ok > 0,
            "the random corpus never produced a single Ok(_); the generator or the normalizer is broken"
        );
    }

    #[test]
    fn normalize_twice_equals_normalize_once_display() {
        let mut rng = XorShift32(0xC0FFEE_u32.wrapping_add(2));
        let mut exercised_ok = 0u32;
        for _ in 0..1000 {
            let input = random_input(&mut rng);
            if let Ok(once) = normalize_display(&input) {
                let twice = normalize_display(once.as_str())
                    .unwrap_or_else(|e| panic!("re-normalizing {:?} failed: {e}", once.as_str()));
                assert_eq!(
                    twice, once,
                    "normalize_display was not idempotent on {input:?}"
                );
                exercised_ok += 1;
            }
        }
        assert!(
            exercised_ok > 0,
            "the random corpus never produced a single Ok(_); the generator or the normalizer is broken"
        );
    }
}
