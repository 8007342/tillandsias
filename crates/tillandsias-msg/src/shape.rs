// @trace order:1506-nvqt, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
//
// @trace order:1506-q7ab (moved here from tillandsias-plan so the mover can link it)
//
// shape — the PURE half of the fleet message bus (1506-nvqt): the body
// budget, the secret-shaped refusal and the TTL bounds. No I/O, no clock, no
// environment. Two sites run these checks — `tillandsias-plan msg send` and
// the mover (`tillandsias --msg-serve`, 1506-q7ab), because a lane can write
// its outbox directory directly — so the rule lives in ONE place both link.
//
// Sources: openspec/changes/fleet-messaging-poc/design.md Decisions 2 and 5a;
// methodology/distributed-work.yaml sibling_heads_up_protocol.size_budget.

use regex::Regex;
use std::sync::OnceLock;

/// The KIND vocabulary of the heads-up protocol, the only legal first tokens.
pub const KINDS: &[&str] = &["HEADS-UP", "ACK", "LANDED", "BLOCKED", "ASK", "FYI"];
pub const BODY_MAX_BYTES: usize = 600;
pub const BODY_MAX_LINES: usize = 8;
/// The whole serialized envelope, body included.
pub const ENVELOPE_MAX_BYTES: usize = 4096;

/// Operator ruling 2026-09-29 (Decision 5a): default one day, 60 s … 7 d.
pub const TTL_DEFAULT_S: u64 = 86_400;
pub const TTL_MIN_S: u64 = 60;
pub const TTL_MAX_S: u64 = 604_800;
/// Receipts outlive their terminal state by this much, then `status` answers
/// `unknown:receipt-expired`.
pub const RECEIPT_RETENTION_S: u64 = 604_800;

/// A shape refusal: `reason` is the token after `refused:msg:shape:`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShapeError {
    pub reason: String,
    pub why: &'static str,
    pub remedy: &'static str,
}

/// Strip trailing line endings: a body piped from `printf '...\n'` is the
/// same message as one without the final newline.
pub fn normalize_body(body: &str) -> String {
    body.trim_end_matches(['\n', '\r']).replace("\r\n", "\n")
}

fn re(cell: &'static OnceLock<Regex>, pat: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pat).expect("static regex compiles"))
}

/// True when `line` carries a ref: 7+ hex, an order token, `work/<order>` or a
/// path (a token with a `/` between two path characters).
pub fn has_ref(line: &str) -> bool {
    static HEX: OnceLock<Regex> = OnceLock::new();
    static ORDER: OnceLock<Regex> = OnceLock::new();
    static PATH: OnceLock<Regex> = OnceLock::new();
    re(&HEX, r"\b[0-9a-f]{7,}\b").is_match(line)
        || re(&ORDER, r"\b[0-9]{3,5}-[a-z0-9]{4}\b").is_match(line)
        || re(&PATH, r"[A-Za-z0-9_.~-]/[A-Za-z0-9_.*-]").is_match(line)
}

/// The budget: ≤ 600 bytes, ≤ 8 lines, line 1 `<KIND>:<subject>:<clause>`,
/// every other line `- ` plus a ref. Returns the KIND on success.
pub fn check_shape(body: &str) -> Result<&'static str, ShapeError> {
    let body = normalize_body(body);
    if body.trim().is_empty() {
        return Err(ShapeError {
            reason: "empty".into(),
            why: "a message with no body carries nothing a reader can act on",
            remedy: "pipe a body on stdin or pass --body-file <path>; line 1 is <KIND>:<subject>:<clause>",
        });
    }
    if body.len() > BODY_MAX_BYTES {
        return Err(ShapeError {
            reason: format!("bytes>{BODY_MAX_BYTES}"),
            why: "the heads-up budget is 600 bytes (distributed-work.yaml size_budget); a longer body is a document, not a message",
            remedy: "shorten the body and move detail to a plan/issues note or a commit, then cite it on a `- ` ref line",
        });
    }
    let lines: Vec<&str> = body.split('\n').collect();
    if lines.len() > BODY_MAX_LINES {
        return Err(ShapeError {
            reason: format!("lines>{BODY_MAX_LINES}"),
            why: "the heads-up budget is 8 lines (distributed-work.yaml size_budget); it is refused, never truncated",
            remedy: "fold the body into at most 8 lines: one <KIND>:<subject>:<clause> line plus up to 7 `- <ref>` lines",
        });
    }
    let first = lines[0];
    let mut parts = first.splitn(3, ':');
    let kind_tok = parts.next().unwrap_or("");
    let subject = parts.next().unwrap_or("");
    let clause = parts.next().unwrap_or("");
    let Some(kind) = KINDS.iter().copied().find(|k| *k == kind_tok) else {
        return Err(ShapeError {
            reason: "first-line-kind".into(),
            why: "line 1 must start with a KIND from HEADS-UP|ACK|LANDED|BLOCKED|ASK|FYI so a reader can triage without parsing prose",
            remedy: "start the body with <KIND>:<subject>:<clause>, e.g. `FYI:1506-nvqt:store landed`",
        });
    };
    if subject.trim().is_empty() || clause.trim().is_empty() {
        return Err(ShapeError {
            reason: "first-line-shape".into(),
            why: "line 1 is <KIND>:<subject>:<clause>; a missing subject or clause leaves the reader guessing",
            remedy: "write line 1 as <KIND>:<subject>:<clause> with both parts non-empty",
        });
    }
    for (i, line) in lines.iter().enumerate().skip(1) {
        let Some(rest) = line.strip_prefix("- ") else {
            return Err(ShapeError {
                reason: format!("line{}-not-dash", i + 1),
                why: "every line after the first is an evidence line starting with `- `",
                remedy: "prefix the line with `- ` and give it a ref (7+ hex, an order token, work/<order> or a path)",
            });
        };
        if !has_ref(rest) {
            return Err(ShapeError {
                reason: format!("line{}-no-ref", i + 1),
                why: "an evidence line with no ref cannot be checked by the reader",
                remedy: "add a ref to the line: a commit (7+ hex), an order token, work/<order> or a repo path",
            });
        }
    }
    Ok(kind)
}

/// The pattern name when `body` looks like it carries a credential.
///
/// Order matters only for the name reported: the specific vendor shapes are
/// tried before the generic runs, so a GitHub token reads `github-token`, not
/// `base64-run`.
pub fn secret_shaped(body: &str) -> Option<&'static str> {
    static PATTERNS: OnceLock<Vec<(&'static str, Regex)>> = OnceLock::new();
    let pats = PATTERNS.get_or_init(|| {
        [
            (
                "github-token",
                r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}",
            ),
            ("vault-token", r"hv[sb]\.[A-Za-z0-9_-]{20,}"),
            ("aws-access-key", r"\bAKIA[0-9A-Z]{16}"),
            ("sk-api-key", r"\bsk-[A-Za-z0-9_-]{16,}"),
            ("private-key", r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY"),
            ("bearer-token", r"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"),
            (
                "jwt",
                r"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*",
            ),
            ("hex-run", r"[0-9a-fA-F]{40,}"),
        ]
        .into_iter()
        .map(|(n, p)| (n, Regex::new(p).expect("static secret regex compiles")))
        .collect()
    });
    for (name, re) in pats {
        if re.is_match(body) {
            return Some(name);
        }
    }
    base64_run(body).then_some("base64-run")
}

/// A run of 40+ base64 characters mixing at least two of lower, upper and
/// digit. The mixing rule keeps an all-lowercase slash path out; any real
/// 40-character credential mixes classes with overwhelming probability.
fn base64_run(body: &str) -> bool {
    static RUN: OnceLock<Regex> = OnceLock::new();
    re(&RUN, r"[A-Za-z0-9+/]{40,}").find_iter(body).any(|m| {
        let s = m.as_str();
        let classes = [
            s.bytes().any(|b| b.is_ascii_lowercase()),
            s.bytes().any(|b| b.is_ascii_uppercase()),
            s.bytes().any(|b| b.is_ascii_digit()),
        ];
        classes.iter().filter(|c| **c).count() >= 2
    })
}

/// Why and remedy for a secret refusal, shared by the CLI and the mover.
pub fn secret_affordance(pattern: &str) -> (&'static str, String) {
    let why = "the bus carries coordination, never credentials: a body matching a secret shape is refused before anything is written (design Decision 2)";
    let remedy = if pattern == "hex-run" {
        "abbreviate a commit to 12 hex characters; if it really is a secret, rotate it and send the Vault path that holds it instead".to_string()
    } else {
        format!(
            "remove the {pattern}-shaped string; name the Vault path or the file that holds it instead, and rotate it if it was ever real"
        )
    };
    (why, remedy)
}

/// `Ok(ttl)` inside 60 … 604800; `Err(token)` = the full refusal token.
pub fn check_ttl(ttl: u64) -> Result<u64, String> {
    if (TTL_MIN_S..=TTL_MAX_S).contains(&ttl) {
        Ok(ttl)
    } else {
        Err(format!(
            "refused:msg:ttl-out-of-bounds:{ttl}:min={TTL_MIN_S}:max={TTL_MAX_S}"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &str =
        "FYI:1506-nvqt:store landed\n- crates/tillandsias-plan/src/msg_store.rs\n- abc1234";

    #[test]
    fn a_well_formed_body_passes_and_names_its_kind() {
        assert_eq!(check_shape(GOOD), Ok("FYI"));
        assert_eq!(check_shape(&format!("{GOOD}\n")), Ok("FYI"));
    }

    #[test]
    fn nine_lines_are_refused_eight_pass() {
        let eight: String = std::iter::once("ASK:x:y".to_string())
            .chain((0..7).map(|i| format!("- 1506-nvq{i}")))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(check_shape(&eight).is_ok());
        let nine = format!("{eight}\n- abcdef0");
        assert_eq!(check_shape(&nine).unwrap_err().reason, "lines>8");
    }

    #[test]
    fn over_600_bytes_is_refused() {
        let long = format!("FYI:x:{}", "a".repeat(600));
        assert_eq!(check_shape(&long).unwrap_err().reason, "bytes>600");
    }

    #[test]
    fn first_line_needs_a_known_kind_and_three_parts() {
        assert_eq!(
            check_shape("NOTE:x:y").unwrap_err().reason,
            "first-line-kind"
        );
        assert_eq!(check_shape("FYI:x").unwrap_err().reason, "first-line-shape");
        assert_eq!(check_shape("").unwrap_err().reason, "empty");
    }

    #[test]
    fn evidence_lines_need_a_dash_and_a_ref() {
        assert_eq!(
            check_shape("FYI:x:y\nno dash abc1234").unwrap_err().reason,
            "line2-not-dash"
        );
        assert_eq!(
            check_shape("FYI:x:y\n- just words here")
                .unwrap_err()
                .reason,
            "line2-no-ref"
        );
        for ok in [
            "- abc1234",
            "- see 1506-nvqt",
            "- work/1506-nvqt",
            "- plan/index.d",
        ] {
            assert!(check_shape(&format!("FYI:x:y\n{ok}")).is_ok(), "{ok}");
        }
    }

    #[test]
    fn each_secret_shape_is_named() {
        let cases = [
            (format!("ghp_{}", "A1b2".repeat(9)), "github-token"),
            (format!("github_pat_{}", "x".repeat(30)), "github-token"),
            (format!("hvs.{}", "a".repeat(24)), "vault-token"),
            ("AKIAABCDEFGHIJKLMNOP".to_string(), "aws-access-key"),
            (format!("sk-ant-{}", "a".repeat(20)), "sk-api-key"),
            (
                "-----BEGIN OPENSSH PRIVATE KEY-----".to_string(),
                "private-key",
            ),
            (format!("Bearer {}", "a".repeat(20)), "bearer-token"),
            ("eyJhbGciOi.eyJzdWIiOi.sig".to_string(), "jwt"),
            ("a".repeat(20) + &"0".repeat(20), "hex-run"),
            ("Xy9".repeat(14), "base64-run"),
        ];
        for (body, want) in cases {
            assert_eq!(
                secret_shaped(&format!("FYI:x:{body}")),
                Some(want),
                "{body}"
            );
        }
    }

    /// NEGATIVE CONTROL for the secret patterns: prose that mentions the
    /// prefixes, a 12-hex commit, and a long all-lowercase path must pass, or
    /// the check would refuse ordinary coordination traffic.
    #[test]
    fn ordinary_prose_is_not_secret_shaped() {
        for body in [
            GOOD,
            "FYI:tokens:ghp_ and hvs. prefixes are refused\n- abcdef012345",
            "ASK:task-runner:the Bearer header\n- plan/issues/fleet-messaging-poc-design-2026-09-29.md",
            "FYI:x:y\n- openspec/changes/fleetmessagingpoc/specs/fleetmessaging/spec",
        ] {
            assert_eq!(secret_shaped(body), None, "{body}");
        }
    }

    #[test]
    fn ttl_bounds_are_60_to_604800() {
        assert_eq!(check_ttl(60), Ok(60));
        assert_eq!(check_ttl(604_800), Ok(604_800));
        assert_eq!(
            check_ttl(30).unwrap_err(),
            "refused:msg:ttl-out-of-bounds:30:min=60:max=604800"
        );
        assert_eq!(
            check_ttl(700_000).unwrap_err(),
            "refused:msg:ttl-out-of-bounds:700000:min=60:max=604800"
        );
    }
}
