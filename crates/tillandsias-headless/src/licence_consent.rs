//! Third-party licence consent (order 1956-ecpb, implementing 1954-dvz9).
//!
//! @trace order:1956-ecpb, order:1954-dvz9 (spec: openspec/changes/studio-asset-pipeline, design D6)
//!
//! Three things, in the operator's own words: "users should durably record
//! their consent to the third party license", the skill "parses the license
//! and turns it into a spec for the agreeing project", and "we cannot enforce
//! anything". So this module:
//!
//! - reads `images/models/licence-register-restricted.tsv`, the register of
//!   weights whose licence is outside the permissive list, each row carrying
//!   its obligation classes and the sha256 of the licence text it was read
//!   from (D6 "Gate");
//! - classifies a licence into obligation classes from a table keyed by
//!   licence id, quoting the clause verbatim where the table holds it. An
//!   unknown licence is one obligation: review (design "Risks");
//! - builds the acknowledgement record (statement, signature, grantor, time,
//!   scope, expiry, artefacts) and renders the obligations spec, valid
//!   OpenSpec, that the `accept-licence` skill commits into the agreeing
//!   project (D6 "Record");
//! - gates a fetch: a permissive row is admitted as today; a restricted row
//!   only with a matching acknowledgement in the project's checkout whose
//!   SSHSIG an enrolled per-host key signed; a licence whose terms forbid the
//!   use outright stays refused.
//!
//! Signing reuses os-verified-approval-gates: SSHSIG (its D2) in the one
//! namespace `tillandsias-approval@v1`, verified with stock
//! `ssh-keygen -Y verify` against the host's enrolled allowed-signers file
//! (its D5). Nothing here signs; the tray's signer does, after the OS check.

#![cfg_attr(not(test), allow(dead_code))]

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::imagegen_models::{ModelFile, register_admits};

/// The SSHSIG namespace every Tillandsias approval is signed in
/// (os-verified-approval-gates D2; the same constant the macOS signer uses).
pub const NAMESPACE: &str = "tillandsias-approval@v1";

/// The first line of every acknowledgement statement.
pub const STATEMENT_KIND: &str = "tillandsias-licence-acknowledgement v1";

/// The shipped restricted register (D6).
const RESTRICTED_REGISTER_TSV: &str =
    include_str!("../../../images/models/licence-register-restricted.tsv");

pub fn restricted_register_tsv() -> &'static str {
    RESTRICTED_REGISTER_TSV
}

// ---------------------------------------------------------------------------
// Obligation classes
// ---------------------------------------------------------------------------

/// What a licence asks of the project that depends on the artefact. The
/// rendered form (`attribution{CorridorKey}`) is the register column and the
/// statement line; `;` separates classes, so no detail may contain one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ObligationClass {
    /// Credit, with the exact text the licence requires where it names one.
    Attribution { text: String },
    /// Carry the licence text or a notice referring to it.
    Notice,
    /// Modifications go out under the same licence.
    ShareAlike,
    NonCommercial,
    /// OpenRAIL Attachment A and kin: the use restrictions pass downstream.
    UseRestrictionPassdown,
    /// Named uses the licence forbids or conditions.
    FieldOfUse,
    SeatOrRevenueThreshold { detail: String },
    NoRedistribution,
    /// GPL-3.0 and kin: conveying object code means conveying the source.
    SourceAvailability,
    /// A clause nobody classified: the project reads it before relying on it.
    Review { clause: String },
}

impl ObligationClass {
    pub fn id(&self) -> &'static str {
        match self {
            Self::Attribution { .. } => "attribution",
            Self::Notice => "notice",
            Self::ShareAlike => "share-alike",
            Self::NonCommercial => "non-commercial",
            Self::UseRestrictionPassdown => "use-restriction-passdown",
            Self::FieldOfUse => "field-of-use",
            Self::SeatOrRevenueThreshold { .. } => "seat-or-revenue-threshold",
            Self::NoRedistribution => "no-redistribution",
            Self::SourceAvailability => "source-availability",
            Self::Review { .. } => "review",
        }
    }

    /// The requirement heading in the generated spec.
    pub fn title(&self) -> &'static str {
        match self {
            Self::Attribution { .. } => "Attribution",
            Self::Notice => "Notice",
            Self::ShareAlike => "Share-alike",
            Self::NonCommercial => "Non-commercial",
            Self::UseRestrictionPassdown => "Use-restriction passdown",
            Self::FieldOfUse => "Field of use",
            Self::SeatOrRevenueThreshold { .. } => "Seat or revenue threshold",
            Self::NoRedistribution => "No redistribution",
            Self::SourceAvailability => "Source availability",
            Self::Review { .. } => "Review",
        }
    }

    /// `id` or `id{detail}`.
    pub fn render(&self) -> String {
        match self {
            Self::Attribution { text } if !text.is_empty() => format!("attribution{{{text}}}"),
            Self::SeatOrRevenueThreshold { detail } if !detail.is_empty() => {
                format!("seat-or-revenue-threshold{{{detail}}}")
            }
            Self::Review { clause } if !clause.is_empty() => format!("review{{{clause}}}"),
            other => other.id().to_string(),
        }
    }

    /// The inverse of [`render`](Self::render). An unknown id is an error, not
    /// a review: the register is written by people and a typo must show.
    pub fn parse(s: &str) -> Result<Self, String> {
        let s = s.trim();
        if s.is_empty() {
            return Err("empty obligation class".into());
        }
        let (id, detail) = match s.find('{') {
            Some(i) if s.ends_with('}') => (&s[..i], &s[i + 1..s.len() - 1]),
            Some(_) => return Err(format!("unbalanced braces in obligation {s:?}")),
            None => (s, ""),
        };
        Ok(match id {
            "attribution" => Self::Attribution { text: detail.to_string() },
            "notice" => Self::Notice,
            "share-alike" => Self::ShareAlike,
            "non-commercial" => Self::NonCommercial,
            "use-restriction-passdown" => Self::UseRestrictionPassdown,
            "field-of-use" => Self::FieldOfUse,
            "seat-or-revenue-threshold" => Self::SeatOrRevenueThreshold { detail: detail.to_string() },
            "no-redistribution" => Self::NoRedistribution,
            "source-availability" => Self::SourceAvailability,
            "review" => Self::Review { clause: detail.to_string() },
            other => return Err(format!("unknown obligation class {other:?}")),
        })
    }

    /// `a;b;c` from the register column.
    pub fn parse_list(s: &str) -> Result<Vec<Self>, String> {
        let s = s.trim();
        if s.is_empty() {
            return Err("no obligation classes".into());
        }
        s.split(';').map(Self::parse).collect()
    }

    pub fn render_list(list: &[Self]) -> String {
        list.iter().map(Self::render).collect::<Vec<_>>().join(";")
    }
}

/// One obligation with the clause it came from, quoted verbatim from the
/// licence text where the table holds it (empty when it does not).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Obligation {
    pub class: ObligationClass,
    pub clause: &'static str,
}

fn ob(class: ObligationClass, clause: &'static str) -> Obligation {
    Obligation { class, clause }
}

// Verbatim clauses. Sources, read 2026-11-02: the CC BY 4.0 legalcode (SPDX
// text, sha256 d557539d…); the CORRIDOR KEY LICENCE v2.0 LICENSE file at Hub
// revision cf44a8db (sha256 c92ce56f…), which embeds CC BY-NC-SA 4.0; the
// CreativeML OpenRAIL-M text (CompVis/stable-diffusion-license, sha256
// be351ebe…); the GPL-3.0 text (SPDX, sha256 fb981668…).
const CC_ATTRIBUTION: &str = "retain the following if it is supplied by the Licensor with the Licensed Material: i. identification of the creator(s) of the Licensed Material and any others designated to receive attribution, in any reasonable manner requested by the Licensor (including by pseudonym if designated);";
const CC_NOTICE: &str = "iii. a notice that refers to this Public License;";
const CC_NC: &str = "NonCommercial means not primarily intended for or directed towards commercial advantage or monetary compensation.";
const CC_SA: &str = "The Adapter's License You apply must be a Creative Commons license with the same License Elements, this version or later, or a BY-NC-SA Compatible License.";
const OPENRAIL_PASSDOWN: &str = "Use-based restrictions as referenced in paragraph 5 MUST be included as an enforceable provision by You in any type of legal agreement (e.g. a license) governing the use and/or distribution of the Model or Derivatives of the Model, and You shall give notice to subsequent users You Distribute to, that the Model or Derivatives of the Model are subject to paragraph 5. (Attachment A, Use Restrictions)";
const OPENRAIL_NOTICE: &str = "You must give any Third Party recipients of the Model or Derivatives of the Model a copy of this License;";
const OPENRAIL_ATTRIBUTION: &str = "You must retain all copyright, patent, trademark, and attribution notices excluding those notices that do not pertain to any part of the Model, Derivatives of the Model.";
const GPL_SOURCE: &str = "You may convey a covered work in object code form under the terms of sections 4 and 5, provided that you also convey the machine-readable Corresponding Source under the terms of this License, in one of these ways:";
const GPL_NOTICE: &str = "You may convey verbatim copies of the Program's source code as you receive it, in any medium, provided that you conspicuously and appropriately publish on each copy an appropriate copyright notice;";
const GPL_SA: &str = "You must license the entire work, as a whole, under this License to anyone who comes into possession of a copy.";
const CK_ATTRIBUTION: &str = "In addition to the attribution requirements set out in Section 3(a) of the CC BY-NC-SA 4.0 licence, You must include the name \"CorridorKey\" in any attribution notice.";
const CK_SA: &str = "Any variations, improvements, derivative works, or modified versions of this tool that are publicly released must be distributed under this same licence, including these Additional Terms, or a licence with substantially equivalent terms.";
const CK_NO_REDIST: &str = "You may not repackage, redistribute, sublicense, or sell this tool, in whole or in part, as a standalone product or as part of a competing product, and You may not charge for access to this tool's code or model weights.";
const CK_FIELD: &str = "You may not use this tool to provide inference as a paid API service, whether directly or indirectly. [...] If you operate a commercial software package or inference service and wish to incorporate this tool into your software, you must obtain a separate written agreement from the Licensor.";
const CK_SEATS: &str = "If You are, or are using this tool on behalf of, a Legal Entity whose total gross revenue exceeded US $20,000,000 (twenty million US dollars) in its most recently completed fiscal year, the permissions in Section 1 do not apply unless that Legal Entity has purchased a seat of the CorridorKey plugin from the Licensor for each individual who uses this tool.";
const CK_NC: &str = "This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International Public License [...] Use CorridorKey for whatever you'd like, including processing footage for commercial projects.";
const MIT_NOTICE: &str = "The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.";
const NVIDIA_UNREAD: &str = "the NVIDIA Open Model License Agreement (June 2024) is published only as a PDF at developer.download.nvidia.com, which this host could not fetch; its clauses are classed from the licence as remembered and are not quoted. Read it before relying on these classes.";

/// The obligation table, keyed by licence id as the register spells it.
/// An unknown id yields one review obligation naming it.
pub fn obligations_for(licence_id: &str) -> Vec<Obligation> {
    use ObligationClass as C;
    let id = licence_id.trim().to_ascii_lowercase();
    match id.as_str() {
        "cc-by-4.0" => vec![
            ob(C::Attribution { text: String::new() }, CC_ATTRIBUTION),
            ob(C::Notice, CC_NOTICE),
        ],
        "cc-by-nc-sa-4.0" => vec![
            ob(C::Attribution { text: String::new() }, CC_ATTRIBUTION),
            ob(C::Notice, CC_NOTICE),
            ob(C::ShareAlike, CC_SA),
            ob(C::NonCommercial, CC_NC),
        ],
        // Operator ruling 2026-11-01: the OpenRAIL family's Attachment A use
        // restrictions MUST pass downstream, alongside attribution.
        "openrail" | "openrail-m" | "creativeml-openrail-m" | "openrail++" => vec![
            ob(C::UseRestrictionPassdown, OPENRAIL_PASSDOWN),
            ob(C::Notice, OPENRAIL_NOTICE),
            ob(C::Attribution { text: String::new() }, OPENRAIL_ATTRIBUTION),
        ],
        // Operator ruling 2026-11-02: GPL-3.0 plugin code carries a
        // source-availability obligation, met because the Tillandsias source
        // is public and each node is pinned to a public upstream commit.
        "gpl-3.0" | "gpl-3.0-only" | "gpl-3.0-or-later" => vec![
            ob(C::SourceAvailability, GPL_SOURCE),
            ob(C::Notice, GPL_NOTICE),
            ob(C::ShareAlike, GPL_SA),
        ],
        "nvidia-open-model-license" => vec![
            ob(
                C::Attribution {
                    text: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License".into(),
                },
                "",
            ),
            ob(C::Notice, ""),
            ob(C::UseRestrictionPassdown, ""),
            ob(C::FieldOfUse, ""),
            ob(C::Review { clause: NVIDIA_UNREAD.into() }, NVIDIA_UNREAD),
        ],
        "corridor-key-licence-v2" => vec![
            ob(C::Attribution { text: "CorridorKey".into() }, CK_ATTRIBUTION),
            ob(C::Notice, CC_NOTICE),
            ob(C::ShareAlike, CK_SA),
            ob(C::NonCommercial, CK_NC),
            ob(C::NoRedistribution, CK_NO_REDIST),
            ob(C::FieldOfUse, CK_FIELD),
            ob(
                C::SeatOrRevenueThreshold {
                    detail: "US $20,000,000 gross revenue: a seat per user".into(),
                },
                CK_SEATS,
            ),
        ],
        "mit" => vec![ob(C::Notice, MIT_NOTICE)],
        _ => vec![ob(
            C::Review {
                clause: format!(
                    "licence {licence_id:?} is not in the obligation table; read its text and classify it before relying on the artefact"
                ),
            },
            "",
        )],
    }
}

/// Licences whose terms forbid the use outright (research-only), so no
/// acknowledgement admits them (1954-dvz9 exit criterion 4). From the
/// 2026-10-28 deny-list review of the cards.
const FORBIDDEN_OUTRIGHT: &[(&str, &str)] = &[
    (
        "qwen-research",
        "the Qwen RESEARCH LICENSE permits non-commercial research use only",
    ),
    (
        "sdxl-turbo-research",
        "the Stability AI Non-Commercial Research Community License permits research use only",
    ),
    (
        "insightface-non-commercial",
        "InsightFace weights are for non-commercial research purposes only",
    ),
];

pub fn forbidden_outright(licence_id: &str) -> Option<&'static str> {
    let id = licence_id.trim().to_ascii_lowercase();
    FORBIDDEN_OUTRIGHT
        .iter()
        .find(|(l, _)| *l == id)
        .map(|(_, why)| *why)
}

// ---------------------------------------------------------------------------
// The restricted register
// ---------------------------------------------------------------------------

/// One row of `licence-register-restricted.tsv`: the permissive register's
/// columns plus `obligations` and `licence_sha256`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestrictedRow {
    pub name: String,
    pub repo: String,
    pub revision: String,
    pub file: String,
    pub sha256: String,
    pub spdx: String,
    pub gated: String,
    pub card: String,
    pub obligations: Vec<ObligationClass>,
    /// 64 hex of the licence text, or `pending:<url>` when the text could not
    /// be fetched where the row was written. A pending row is never admitted.
    pub licence_sha256: String,
}

pub fn parse_restricted(register: &str) -> Result<Vec<RestrictedRow>, String> {
    let mut rows = Vec::new();
    for (n, line) in register.lines().enumerate() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != 10 {
            return Err(format!(
                "licence-register-restricted.tsv line {}: {} columns, want 10",
                n + 1,
                c.len()
            ));
        }
        let obligations = ObligationClass::parse_list(c[8]).map_err(|e| {
            format!(
                "licence-register-restricted.tsv line {} ({}): {e}",
                n + 1,
                c[0]
            )
        })?;
        let lh = c[9].trim();
        let hex64 = lh.len() == 64 && lh.chars().all(|ch| ch.is_ascii_hexdigit());
        if !hex64 && !lh.starts_with("pending:") {
            return Err(format!(
                "licence-register-restricted.tsv line {} ({}): licence_sha256 is neither 64 hex nor pending:<url>",
                n + 1,
                c[0]
            ));
        }
        rows.push(RestrictedRow {
            name: c[0].into(),
            repo: c[1].into(),
            revision: c[2].into(),
            file: c[3].into(),
            sha256: c[4].to_ascii_lowercase(),
            spdx: c[5].to_ascii_lowercase(),
            gated: c[6].into(),
            card: c[7].into(),
            obligations,
            licence_sha256: lh.to_ascii_lowercase(),
        });
    }
    Ok(rows)
}

// ---------------------------------------------------------------------------
// The acknowledgement record
// ---------------------------------------------------------------------------

/// `licences/acknowledgements/<slug>.yaml` in the agreeing project (D6
/// "Record"). Flat YAML, written and read here without a YAML crate so the
/// mirror's pre-receive hook can read it the same way.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Acknowledgement {
    pub licence: String,
    pub licence_sha256: String,
    /// The artefact repos this acknowledgement covers.
    pub covers: Vec<String>,
    /// The allowed-signers principal (`operator`, or a project owner).
    pub grantor: String,
    /// `project:<name>` or `operator-projects`.
    pub scope: String,
    /// `non-sale` or `commercial`.
    pub r#use: String,
    /// `standing` or an RFC 3339 instant.
    pub expiry: String,
    pub signed_at: String,
    /// os-verified-approval-gates D1 strength word.
    pub strength: String,
    pub host: String,
    /// The armored SSHSIG over [`statement_text`](Self::statement_text);
    /// empty until signed.
    pub signature: String,
}

fn slugify(s: &str) -> String {
    let mut out = String::new();
    for ch in s.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').to_string()
}

impl Acknowledgement {
    /// The file stem: the artefact slug, or grantor-scope-expiry for a grant
    /// covering several artefacts.
    pub fn slug(&self) -> String {
        if self.covers.len() == 1 {
            slugify(&self.covers[0])
        } else {
            slugify(&format!("{}-{}-{}", self.grantor, self.scope, self.expiry))
        }
    }

    /// The canonical statement that is signed byte for byte (D3's shape).
    pub fn statement_text(&self) -> String {
        format!(
            "{STATEMENT_KIND}\nlicence: {}\nlicence_sha256: {}\ncovers: {}\ngrantor: {}\nscope: {}\nuse: {}\nexpiry: {}\nhost: {}\nstrength: {}\nissued: {}\n",
            self.licence,
            self.licence_sha256,
            self.covers.join(", "),
            self.grantor,
            self.scope,
            self.r#use,
            self.expiry,
            self.host,
            self.strength,
            self.signed_at
        )
    }

    pub fn to_yaml(&self) -> String {
        let block = |s: &str| {
            let mut out = String::new();
            for l in s.lines() {
                out.push_str("  ");
                out.push_str(l);
                out.push('\n');
            }
            out
        };
        let mut y = String::new();
        y.push_str("# Third-party licence acknowledgement (order 1956-ecpb, implements 1954-dvz9).\n");
        y.push_str("# Signed over `statement` as SSHSIG in namespace tillandsias-approval@v1; verify with\n");
        y.push_str("#   ssh-keygen -Y verify -n tillandsias-approval@v1 -I <grantor> -f <allowed_signers> -s <sig> < <statement>\n");
        y.push_str(&format!("record: {STATEMENT_KIND}\n"));
        y.push_str(&format!("licence: {}\n", self.licence));
        y.push_str(&format!("licence_sha256: {}\n", self.licence_sha256));
        y.push_str(&format!("covers: [{}]\n", self.covers.join(", ")));
        y.push_str(&format!("grantor: {}\n", self.grantor));
        y.push_str(&format!("scope: {}\n", self.scope));
        y.push_str(&format!("use: {}\n", self.r#use));
        y.push_str(&format!("expiry: \"{}\"\n", self.expiry));
        y.push_str(&format!("signed_at: \"{}\"\n", self.signed_at));
        y.push_str(&format!("strength: {}\n", self.strength));
        y.push_str(&format!("host: {}\n", self.host));
        y.push_str("statement: |\n");
        y.push_str(&block(&self.statement_text()));
        if self.signature.trim().is_empty() {
            y.push_str("signature: \"\"\n");
        } else {
            y.push_str("signature: |\n");
            y.push_str(&block(self.signature.trim_end()));
        }
        y
    }

    pub fn from_yaml(text: &str) -> Result<Self, String> {
        let mut kv: Vec<(String, String)> = Vec::new();
        let mut lines = text.lines().peekable();
        while let Some(line) = lines.next() {
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let Some((k, v)) = line.split_once(':') else {
                return Err(format!("acknowledgement: not key: value: {line:?}"));
            };
            let k = k.trim().to_string();
            let v = v.trim();
            if v == "|" {
                let mut body = String::new();
                while let Some(next) = lines.peek() {
                    if let Some(rest) = next.strip_prefix("  ") {
                        body.push_str(rest);
                        body.push('\n');
                        lines.next();
                    } else if next.trim().is_empty() {
                        body.push('\n');
                        lines.next();
                    } else {
                        break;
                    }
                }
                kv.push((k, body));
            } else {
                let v = v
                    .strip_prefix('"')
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(v);
                kv.push((k, v.to_string()));
            }
        }
        let get = |k: &str| -> Result<String, String> {
            kv.iter()
                .find(|(kk, _)| kk == k)
                .map(|(_, v)| v.clone())
                .ok_or_else(|| format!("acknowledgement: missing {k}"))
        };
        if get("record")? != STATEMENT_KIND {
            return Err(format!("acknowledgement: record is not {STATEMENT_KIND}"));
        }
        let covers_raw = get("covers")?;
        let covers: Vec<String> = covers_raw
            .trim()
            .trim_start_matches('[')
            .trim_end_matches(']')
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        let ack = Acknowledgement {
            licence: get("licence")?,
            licence_sha256: get("licence_sha256")?.to_ascii_lowercase(),
            covers,
            grantor: get("grantor")?,
            scope: get("scope")?,
            r#use: get("use")?,
            expiry: get("expiry")?,
            signed_at: get("signed_at")?,
            strength: get("strength")?,
            host: get("host")?,
            signature: get("signature")?.trim().to_string(),
        };
        // The stored statement is what was signed; the fields must still say
        // the same thing, or the record was edited after signing.
        let stored = get("statement")?;
        if stored.trim_end() != ack.statement_text().trim_end() {
            return Err("acknowledgement: statement does not match its fields".into());
        }
        Ok(ack)
    }

    /// `standing`, or an RFC 3339 instant still in the future.
    pub fn in_force(&self, now: chrono::DateTime<chrono::Utc>) -> bool {
        if self.expiry == "standing" {
            return true;
        }
        chrono::DateTime::parse_from_rfc3339(&self.expiry)
            .map(|t| t.with_timezone(&chrono::Utc) > now)
            .unwrap_or(false)
    }
}

/// Acknowledgement #1: the operator's standing approval, 2026-11-01,
/// verbatim: "For our own projects we shall have a standing approval to use
/// all of those free models, we'll not be selling any of those assets."
/// Scope operator-projects, use non-sale, expiry standing. It does not cover
/// redistribution, or clicking through gated terms on the operator's behalf.
/// It is unsigned here: the operator signs it with an enrolled key through
/// the accept-licence skill, and the signed record lives in each project.
pub fn operator_standing_acknowledgement() -> Acknowledgement {
    Acknowledgement {
        licence: "corridor-key-licence-v2".into(),
        licence_sha256: "c92ce56f64162b231c7ce08ce3ed7d8cae15f01a560ca05a8e8db67878eb0065".into(),
        covers: vec![
            "nikopueringer/CorridorKey2.0".into(),
            "nvidia/C-RADIOv4-SO400M".into(),
            "Ruicheng/moge-2-vitb-normal".into(),
            "google-deepmind/representations4d".into(),
        ],
        grantor: "operator".into(),
        scope: "operator-projects".into(),
        r#use: "non-sale".into(),
        expiry: "standing".into(),
        signed_at: "2026-11-01T23:45:35Z".into(),
        strength: "software-password".into(),
        host: "calmecacpilli".into(),
        signature: String::new(),
    }
}

// ---------------------------------------------------------------------------
// The obligations spec
// ---------------------------------------------------------------------------

/// `openspec/specs/third-party-licence-<id>/spec.md` for the agreeing
/// project: "This project depends on <artefact> and must now adhere to
/// <obligations>", one requirement per obligation, each with a scenario, the
/// clause quoted verbatim, and a "how this project honours it" line the
/// project fills in. Tillandsias records; it does not enforce.
pub fn obligations_spec(artefact: &str, licence_id: &str, obligations: &[Obligation]) -> String {
    let names: Vec<String> = obligations
        .iter()
        .map(|o| o.class.title().to_lowercase())
        .collect();
    let list = match names.len() {
        0 => "no recorded obligations".to_string(),
        1 => names[0].clone(),
        n => format!("{} and {}", names[..n - 1].join(", "), names[n - 1]),
    };
    let mut s = String::new();
    s.push_str(&format!("# Third-party licence: {licence_id}\n\n"));
    s.push_str(&format!(
        "@trace spec:third-party-licence-{}\n\n",
        slugify(licence_id)
    ));
    s.push_str("## Purpose\n\n");
    s.push_str(&format!(
        "This project depends on {artefact} and must now adhere to {list}, the obligations its licence `{licence_id}` carries. \
         The acknowledgement that accepted the licence is under `licences/acknowledgements/`, signed with an OS-verified key and committed with this spec. \
         Tillandsias records these obligations; honouring them over the project's lifetime is the project's own work, and each requirement below says how.\n\n"
    ));
    s.push_str("## Requirements\n\n");
    for o in obligations {
        s.push_str(&format!("### Requirement: {}\n\n", o.class.title()));
        s.push_str(&requirement_sentence(o, artefact));
        s.push('\n');
        if !o.clause.is_empty() {
            s.push_str(&format!(
                "\nThe licence says, verbatim: \"{}\"\n",
                o.clause
            ));
        }
        s.push_str("\nHow this project honours it: _to be written by the project owner; for example \"the credits screen shows 'CorridorKey'\"._\n\n");
        s.push_str(&format!("#### Scenario: {}\n", scenario_title(o)));
        s.push_str(&scenario_body(o, artefact));
        s.push('\n');
    }
    s
}

fn requirement_sentence(o: &Obligation, artefact: &str) -> String {
    use ObligationClass as C;
    match &o.class {
        C::Attribution { text } if !text.is_empty() => format!(
            "The project SHALL show the attribution \"{text}\" wherever it credits the work it is built on, for as long as it depends on {artefact}."
        ),
        C::Attribution { .. } => format!(
            "The project SHALL credit the creators of {artefact} as the licence requires wherever it credits the work it is built on."
        ),
        C::Notice => format!(
            "The project SHALL carry the licence text of {artefact}, or a notice that refers to it, with every copy it distributes."
        ),
        C::ShareAlike => format!(
            "Any modification of {artefact} the project releases SHALL go out under the same licence."
        ),
        C::NonCommercial => format!(
            "The project SHALL NOT use {artefact} for commercial advantage or monetary compensation beyond what the licence permits; the acknowledgement records use `non-sale`."
        ),
        C::UseRestrictionPassdown => format!(
            "The project SHALL pass the use restrictions of {artefact} (OpenRAIL Attachment A or its equivalent) to anyone who receives the model, its derivatives or the project's distribution of them, as an enforceable provision."
        ),
        C::FieldOfUse => format!(
            "The project SHALL NOT use {artefact} for a use the licence forbids or conditions, such as a paid inference service or integration into commercial software without the licensor's written agreement."
        ),
        C::SeatOrRevenueThreshold { detail } => format!(
            "If the project's legal entity crosses the licence's threshold ({detail}), the project SHALL hold the seats or licence the terms require before continuing to use {artefact}."
        ),
        C::NoRedistribution => format!(
            "The project SHALL NOT bundle, repackage, redistribute or sell {artefact}; it is fetched on each user's machine, after that user's acknowledgement."
        ),
        C::SourceAvailability => format!(
            "The project SHALL keep the corresponding source of {artefact}, and of its own work that conveys it, available to everyone who receives the object code."
        ),
        C::Review { clause } => format!(
            "The project owner SHALL read this clause of the licence of {artefact} and classify it before relying on the artefact: {clause}"
        ),
    }
}

fn scenario_title(o: &Obligation) -> &'static str {
    use ObligationClass as C;
    match o.class {
        C::Attribution { .. } => "The project credits the work",
        C::Notice => "A copy carries the notice",
        C::ShareAlike => "A modification is released",
        C::NonCommercial => "The project is offered to users",
        C::UseRestrictionPassdown => "A user receives the model or a derivative",
        C::FieldOfUse => "A new use is proposed",
        C::SeatOrRevenueThreshold { .. } => "The entity's revenue is reviewed",
        C::NoRedistribution => "A release or image is built",
        C::SourceAvailability => "Object code is conveyed",
        C::Review { .. } => "The owner reviews the clause",
    }
}

fn scenario_body(o: &Obligation, artefact: &str) -> String {
    use ObligationClass as C;
    let (when, then) = match &o.class {
        C::Attribution { text } if !text.is_empty() => (
            "the project shows its credits".to_string(),
            format!("\"{text}\" is among them"),
        ),
        C::Attribution { .. } => (
            "the project shows its credits".to_string(),
            format!("the creators of {artefact} are named as the licence requires"),
        ),
        C::Notice => (
            "a copy of the project is distributed".to_string(),
            "it carries the licence text or a notice referring to it".to_string(),
        ),
        C::ShareAlike => (
            format!("the project releases a modified {artefact}"),
            "the release is under the same licence".to_string(),
        ),
        C::NonCommercial => (
            "the project is offered to users".to_string(),
            "it is offered without sale of the artefact or of outputs the licence reserves".to_string(),
        ),
        C::UseRestrictionPassdown => (
            format!("someone receives {artefact} or a derivative from the project"),
            "the same use restrictions bind them, in the agreement that governs the transfer".to_string(),
        ),
        C::FieldOfUse => (
            format!("a use of {artefact} is proposed"),
            "it is checked against the licence's forbidden and conditioned uses before it ships".to_string(),
        ),
        C::SeatOrRevenueThreshold { .. } => (
            "the project's legal entity is reviewed against the threshold".to_string(),
            "the seats or licence the terms require are held, or the use stops".to_string(),
        ),
        C::NoRedistribution => (
            "a release, image or shared cache of the project is built".to_string(),
            format!("{artefact} is not in it"),
        ),
        C::SourceAvailability => (
            "object code that includes the artefact is conveyed".to_string(),
            "the corresponding source is available to the recipient".to_string(),
        ),
        C::Review { .. } => (
            "the owner reads the clause".to_string(),
            "this requirement is rewritten into the obligation classes it names".to_string(),
        ),
    };
    format!("- **WHEN** {when}\n- **THEN** {then}\n")
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

/// Verifies an acknowledgement's SSHSIG with stock `ssh-keygen -Y verify`
/// against the host's enrolled allowed-signers file (os-verified-approval-gates
/// D5). The file is written by enrolment on the host; the forge never writes it.
#[derive(Debug, Clone)]
pub struct Verifier {
    pub allowed_signers: PathBuf,
}

impl Verifier {
    pub fn new(allowed_signers: &Path) -> Self {
        Self {
            allowed_signers: allowed_signers.to_path_buf(),
        }
    }

    /// The host's enrolled signers: `TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS`, or
    /// `<state dir>/approvals/allowed_signers`.
    pub fn for_host() -> Self {
        let p = std::env::var_os("TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                tillandsias_core::config::state_dir()
                    .join("approvals")
                    .join("allowed_signers")
            });
        Self::new(&p)
    }

    pub fn verify(&self, statement: &str, armored: &str, principal: &str) -> Result<(), String> {
        if armored.trim().is_empty() {
            return Err("unsigned".into());
        }
        if !self.allowed_signers.is_file() {
            return Err(format!(
                "no enrolled signers at {} (enrol the host's approval key)",
                self.allowed_signers.display()
            ));
        }
        let mut sig = tempfile::Builder::new()
            .prefix("tillandsias-ack-")
            .suffix(".sig")
            .tempfile()
            .map_err(|e| format!("sig tempfile: {e}"))?;
        sig.write_all(armored.as_bytes())
            .and_then(|_| sig.flush())
            .map_err(|e| format!("sig tempfile: {e}"))?;
        let mut child = Command::new("ssh-keygen")
            .args(["-Y", "verify", "-n", NAMESPACE, "-I", principal, "-f"])
            .arg(&self.allowed_signers)
            .arg("-s")
            .arg(sig.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("ssh-keygen: {e}"))?;
        child
            .stdin
            .take()
            .ok_or("ssh-keygen stdin")?
            .write_all(statement.as_bytes())
            .map_err(|e| format!("ssh-keygen stdin: {e}"))?;
        let out = child
            .wait_with_output()
            .map_err(|e| format!("ssh-keygen: {e}"))?;
        if out.status.success() {
            Ok(())
        } else {
            Err(format!(
                "signature not verified: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }
}

/// What an admitted fetch carries into provenance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Admission {
    pub licence: String,
    /// `None` for a permissive row; the grantor for an acknowledged one.
    pub acknowledged_by: Option<String>,
    pub acknowledgement_slug: Option<String>,
    pub obligations: Vec<ObligationClass>,
}

/// Read every `*.yaml` under `dir` that parses as an acknowledgement.
pub fn read_acknowledgements(dir: &Path) -> Vec<(String, Acknowledgement)> {
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir(dir) else {
        return out;
    };
    let mut paths: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    paths.sort();
    for p in paths {
        if p.extension().and_then(|e| e.to_str()) != Some("yaml") {
            continue;
        }
        let Ok(text) = fs::read_to_string(&p) else {
            continue;
        };
        if let Ok(a) = Acknowledgement::from_yaml(&text) {
            let slug = p
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            out.push((slug, a));
        }
    }
    out
}

/// D6 "Gate" against the shipped registers. `project_ack_dir` is the agreeing
/// project's `licences/acknowledgements/`; `requester_scope` is
/// `project:<name>` for the requesting project, or `operator-projects` when the
/// request comes from one of the operator's own projects.
pub fn register_admits_with_consent(
    row: &ModelFile,
    project_ack_dir: &Path,
    requester_scope: &str,
    verifier: &Verifier,
) -> Result<Admission, String> {
    register_admits_with_consent_in(
        crate::imagegen_models::register_tsv(),
        RESTRICTED_REGISTER_TSV,
        row,
        project_ack_dir,
        requester_scope,
        verifier,
    )
}

/// [`register_admits_with_consent`] against explicit registers (fixtures).
pub fn register_admits_with_consent_in(
    permissive_register: &str,
    restricted_register: &str,
    row: &ModelFile,
    project_ack_dir: &Path,
    requester_scope: &str,
    verifier: &Verifier,
) -> Result<Admission, String> {
    // A permissive row is admitted as today.
    let permissive_err = match register_admits(permissive_register, row) {
        Ok(()) => {
            return Ok(Admission {
                licence: row.licence.clone(),
                acknowledged_by: None,
                acknowledgement_slug: None,
                obligations: Vec::new(),
            });
        }
        Err(e) => e,
    };
    let rows = parse_restricted(restricted_register)?;
    let Some(r) = rows.iter().find(|r| {
        r.repo == row.repo
            && r.revision == row.revision
            && r.file == row.file
            && r.sha256.eq_ignore_ascii_case(&row.sha256)
    }) else {
        return Err(format!(
            "{permissive_err}; nor in images/models/licence-register-restricted.tsv"
        ));
    };
    if r.gated != "false" {
        return Err(format!(
            "model_refused: {} is gated; clicking through gated terms on a user's behalf is never authorised",
            row.label()
        ));
    }
    if let Some(why) = forbidden_outright(&r.spdx) {
        return Err(format!(
            "licence_forbids_use: {} licence {}: {why}",
            row.label(),
            r.spdx
        ));
    }
    if r.licence_sha256.starts_with("pending:") {
        return Err(format!(
            "licence_text_unpinned: {} licence {} has no licence text hash in the register ({}); nothing can be acknowledged against it",
            row.label(),
            r.spdx,
            r.licence_sha256
        ));
    }
    let now = chrono::Utc::now();
    let mut reasons: Vec<String> = Vec::new();
    for (slug, ack) in read_acknowledgements(project_ack_dir) {
        if !ack.covers.iter().any(|c| c == &r.repo) {
            continue;
        }
        if ack.licence != r.spdx {
            reasons.push(format!(
                "{slug}: licence {} is not {}",
                ack.licence, r.spdx
            ));
            continue;
        }
        if ack.licence_sha256 != r.licence_sha256 {
            reasons.push(format!(
                "{slug}: licence text hash differs from the register's"
            ));
            continue;
        }
        if ack.scope != requester_scope {
            reasons.push(format!(
                "{slug}: scope {} does not cover the requester's scope {requester_scope}",
                ack.scope
            ));
            continue;
        }
        if !ack.in_force(now) {
            reasons.push(format!("{slug}: expired at {}", ack.expiry));
            continue;
        }
        match verifier.verify(&ack.statement_text(), &ack.signature, &ack.grantor) {
            Ok(()) => {
                return Ok(Admission {
                    licence: r.spdx.clone(),
                    acknowledged_by: Some(ack.grantor.clone()),
                    acknowledgement_slug: Some(slug),
                    obligations: r.obligations.clone(),
                });
            }
            Err(e) => reasons.push(format!("{slug}: {e}")),
        }
    }
    let detail = if reasons.is_empty() {
        format!(
            "no acknowledgement covers {} in {}",
            r.repo,
            project_ack_dir.display()
        )
    } else {
        reasons.join("; ")
    };
    Err(format!(
        "licence_acknowledgement_required: {} licence {} ({}): {detail}. Run the accept-licence skill in the project.",
        row.label(),
        r.spdx,
        ObligationClass::render_list(&r.obligations)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::imagegen_models::ModelFile;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    /// A disk-backed scratch dir beside the test binary (never /tmp, which is
    /// tmpfs on the fleet's Fedora hosts).
    fn disk_scratch(tag: &str) -> PathBuf {
        let exe = std::env::current_exe().expect("test exe");
        let dir = exe
            .parent()
            .expect("deps dir")
            .join(format!("licence-consent-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("scratch");
        dir
    }

    /// An enrolled test key (D1, Linux fallback strength) and its
    /// allowed-signers file naming `grantor` as the principal.
    fn enrol(dir: &Path, grantor: &str) -> (PathBuf, PathBuf) {
        let key = dir.join("approval-key");
        let st = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", grantor, "-f"])
            .arg(&key)
            .status()
            .expect("ssh-keygen");
        assert!(st.success());
        let pubkey = fs::read_to_string(dir.join("approval-key.pub")).unwrap();
        let mut it = pubkey.split_whitespace();
        let line = format!(
            "{grantor} namespaces=\"{NAMESPACE}\" {} {}\n",
            it.next().unwrap(),
            it.next().unwrap()
        );
        let signers = dir.join("allowed_signers");
        fs::write(&signers, line).unwrap();
        (key, signers)
    }

    /// Sign `ack`'s statement with the enrolled key (D2: `ssh-keygen -Y sign`
    /// is the Linux signer) and return the record carrying the armored SSHSIG.
    fn sign(dir: &Path, key: &Path, mut ack: Acknowledgement) -> Acknowledgement {
        let msg = dir.join("statement");
        fs::write(&msg, ack.statement_text()).unwrap();
        let st = Command::new("ssh-keygen")
            .args(["-Y", "sign", "-n", NAMESPACE, "-f"])
            .arg(key)
            .arg(&msg)
            .stderr(std::process::Stdio::null())
            .status()
            .expect("ssh-keygen sign");
        assert!(st.success());
        ack.signature = fs::read_to_string(dir.join("statement.sig")).unwrap();
        ack
    }

    const RESTRICTED: &str = "#name\trepo\trevision\tfile\tsha256\tspdx\tgated\tcard\tobligations\tlicence_sha256\n\
        nc-weights\tfixture/nc-weights\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tmodel.safetensors\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tcc-by-nc-sa-4.0\tfalse\thttps://example.invalid/nc\tattribution{fixture};share-alike;non-commercial\tcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n\
        research-only\tfixture/research-only\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tmodel.safetensors\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\tqwen-research\tfalse\thttps://example.invalid/r\tnon-commercial;field-of-use\teeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n";

    fn nc_row() -> ModelFile {
        ModelFile {
            tier: "I1/studio-nc".into(),
            role: "studio:nc".into(),
            repo: "fixture/nc-weights".into(),
            revision: "a".repeat(40),
            file: "model.safetensors".into(),
            sha256: "b".repeat(64),
            bytes: 1,
            licence: "cc-by-nc-sa-4.0".into(),
        }
    }

    fn nc_ack(scope: &str) -> Acknowledgement {
        Acknowledgement {
            licence: "cc-by-nc-sa-4.0".into(),
            licence_sha256: "c".repeat(64),
            covers: vec!["fixture/nc-weights".into()],
            grantor: "operator".into(),
            scope: scope.into(),
            r#use: "non-sale".into(),
            expiry: "standing".into(),
            signed_at: "2026-11-02T00:00:00Z".into(),
            strength: "software-password".into(),
            host: "fixture-host".into(),
            signature: String::new(),
        }
    }

    /// 1954-dvz9's named test: the same non-commercial row is refused without
    /// an acknowledgement in the project and admitted with a signed one.
    #[test]
    fn register_admits_nc_row_only_with_recorded_acknowledgement() {
        let dir = disk_scratch("nc");
        let (key, signers) = enrol(&dir, "operator");
        let verifier = Verifier::new(&signers);
        let acks = dir.join("licences").join("acknowledgements");
        fs::create_dir_all(&acks).unwrap();
        let row = nc_row();

        // The permissive register never carried it, and the project holds no record.
        let err = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &row,
            &acks,
            "project:demo",
            &verifier,
        )
        .unwrap_err();
        assert!(err.contains("licence_acknowledgement_required"), "{err}");
        assert!(err.contains("cc-by-nc-sa-4.0"), "{err}");

        // An unsigned record is not an acknowledgement.
        let unsigned = nc_ack("project:demo");
        fs::write(acks.join(unsigned.slug() + ".yaml"), unsigned.to_yaml()).unwrap();
        let err = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &row,
            &acks,
            "project:demo",
            &verifier,
        )
        .unwrap_err();
        assert!(err.contains("licence_acknowledgement_required"), "{err}");

        // A signed one, by an enrolled key, admits it.
        let signed = sign(&dir, &key, nc_ack("project:demo"));
        fs::write(acks.join(signed.slug() + ".yaml"), signed.to_yaml()).unwrap();
        let admitted = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &row,
            &acks,
            "project:demo",
            &verifier,
        )
        .unwrap();
        assert_eq!(admitted.licence, "cc-by-nc-sa-4.0");
        assert_eq!(admitted.acknowledged_by.as_deref(), Some("operator"));

        // A record whose licence hash differs from the register's is a different
        // licence text: it does not count.
        let mut stale = nc_ack("project:demo");
        stale.licence_sha256 = "f".repeat(64);
        let stale = sign(&dir, &key, stale);
        fs::remove_file(acks.join(signed.slug() + ".yaml")).unwrap();
        fs::write(acks.join(stale.slug() + ".yaml"), stale.to_yaml()).unwrap();
        let err = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &row,
            &acks,
            "project:demo",
            &verifier,
        )
        .unwrap_err();
        assert!(err.contains("licence_acknowledgement_required"), "{err}");

        // A permissive row is admitted as today, with no record at all.
        let permissive = ModelFile {
            tier: "I0".into(),
            role: "unet".into(),
            repo: "IDKiro/sdxs-512-0.9".into(),
            revision: "c332f05f60eb4b453de513be52c2a18c48d8cfe6".into(),
            file: "unet/diffusion_pytorch_model.safetensors".into(),
            sha256: "c2afb7dbea11b64d0bfbc4d1a45854aa65408b8a74a732438225d3f2ec85c71c".into(),
            bytes: 1,
            licence: "openrail++".into(),
        };
        let ok = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &permissive,
            &dir.join("no-such-dir"),
            "project:demo",
            &verifier,
        )
        .unwrap();
        assert!(ok.acknowledged_by.is_none());
    }

    /// A licence whose terms forbid the use outright (research-only) stays
    /// refused even with a signed acknowledgement.
    #[test]
    fn a_research_only_licence_stays_refused_with_an_acknowledgement() {
        let dir = disk_scratch("forbidden");
        let (key, signers) = enrol(&dir, "operator");
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let mut ack = nc_ack("project:demo");
        ack.licence = "qwen-research".into();
        ack.licence_sha256 = "e".repeat(64);
        ack.covers = vec!["fixture/research-only".into()];
        let ack = sign(&dir, &key, ack);
        fs::write(acks.join(ack.slug() + ".yaml"), ack.to_yaml()).unwrap();
        let mut row = nc_row();
        row.repo = "fixture/research-only".into();
        row.sha256 = "d".repeat(64);
        row.licence = "qwen-research".into();
        let err = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &row,
            &acks,
            "project:demo",
            &Verifier::new(&signers),
        )
        .unwrap_err();
        assert!(err.contains("licence_forbids_use"), "{err}");
    }

    /// An attribution licence yields an attribution requirement, quoting the
    /// required text, in the generated OpenSpec spec.
    #[test]
    fn an_attribution_licence_yields_an_attribution_requirement_in_the_spec() {
        let obligations = obligations_for("corridor-key-licence-v2");
        assert!(obligations.iter().any(|o| matches!(
            &o.class,
            ObligationClass::Attribution { text } if text == "CorridorKey"
        )));
        let spec = obligations_spec(
            "nikopueringer/CorridorKey2.0@cf44a8db3f024bb49fd59daa408848ccf05f7477/corridorkey_v2.safetensors",
            "corridor-key-licence-v2",
            &obligations,
        );
        assert!(spec.contains("This project depends on nikopueringer/CorridorKey2.0"), "{spec}");
        assert!(spec.contains("and must now adhere to"), "{spec}");
        assert!(spec.contains("### Requirement: Attribution"), "{spec}");
        assert!(spec.contains("\"CorridorKey\""), "{spec}");
        // Valid OpenSpec: every requirement has a scenario, and the clause is quoted verbatim.
        let reqs = spec.matches("### Requirement:").count();
        let scenarios = spec.matches("#### Scenario:").count();
        assert!(reqs >= 4 && scenarios >= reqs, "reqs={reqs} scenarios={scenarios}\n{spec}");
        assert!(spec.contains("include the name \"CorridorKey\" in any attribution notice"), "{spec}");
        assert!(spec.contains("### Requirement: Share-alike"), "{spec}");
        assert!(spec.contains("### Requirement: Seat or revenue threshold"), "{spec}");
        assert!(spec.contains("US $20,000,000"), "{spec}");
        assert!(spec.contains("### Requirement: No redistribution"), "{spec}");
    }

    /// Every OpenRAIL id passes its Attachment A use restrictions downstream.
    #[test]
    fn openrail_yields_use_restriction_passdown() {
        for id in ["openrail", "openrail-m", "creativeml-openrail-m", "openrail++"] {
            let obligations = obligations_for(id);
            assert!(
                obligations
                    .iter()
                    .any(|o| matches!(o.class, ObligationClass::UseRestrictionPassdown)),
                "{id}: {obligations:?}"
            );
            let spec = obligations_spec("fixture/openrail-model", id, &obligations);
            assert!(spec.contains("### Requirement: Use-restriction passdown"), "{spec}");
            assert!(spec.contains("Attachment A"), "{spec}");
        }
    }

    /// GPL-3.0 plugin code carries a source-availability obligation.
    #[test]
    fn gpl_3_0_yields_source_availability() {
        let obligations = obligations_for("gpl-3.0");
        assert!(obligations
            .iter()
            .any(|o| matches!(o.class, ObligationClass::SourceAvailability)));
        let spec = obligations_spec("fixture/some-node", "gpl-3.0", &obligations);
        assert!(spec.contains("### Requirement: Source availability"), "{spec}");
        assert!(spec.contains("Corresponding Source"), "{spec}");
    }

    /// An unknown clause (licence) becomes review, never silence.
    #[test]
    fn an_unknown_licence_becomes_review() {
        let obligations = obligations_for("some-licence-nobody-read");
        assert_eq!(obligations.len(), 1);
        assert!(matches!(obligations[0].class, ObligationClass::Review { .. }));
        assert_eq!(
            ObligationClass::parse("attribution{CorridorKey}").unwrap(),
            ObligationClass::Attribution { text: "CorridorKey".into() }
        );
        assert!(ObligationClass::parse("").is_err());
        assert!(ObligationClass::parse("made-up").is_err());
    }

    /// The operator's standing grant (acknowledgement #1) admits CorridorKey
    /// for scope operator-projects and refuses a scope of another user.
    #[test]
    fn the_operator_standing_grant_admits_corridorkey_for_operator_projects_only() {
        let dir = disk_scratch("standing");
        let (key, signers) = enrol(&dir, "operator");
        let verifier = Verifier::new(&signers);
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let seed = operator_standing_acknowledgement();
        assert_eq!(seed.scope, "operator-projects");
        assert_eq!(seed.r#use, "non-sale");
        assert_eq!(seed.expiry, "standing");
        assert!(seed.covers.iter().any(|c| c == "nikopueringer/CorridorKey2.0"));
        let signed = sign(&dir, &key, seed);
        fs::write(acks.join(signed.slug() + ".yaml"), signed.to_yaml()).unwrap();

        let restricted = restricted_register_tsv();
        let rows = parse_restricted(restricted).unwrap();
        let ck = rows
            .iter()
            .find(|r| r.repo == "nikopueringer/CorridorKey2.0" && r.file.ends_with("corridorkey_v2.safetensors"))
            .expect("CorridorKey row in the restricted register");
        let row = ModelFile {
            tier: "I1/corridorkey".into(),
            role: "studio:corridorkey".into(),
            repo: ck.repo.clone(),
            revision: ck.revision.clone(),
            file: ck.file.clone(),
            sha256: ck.sha256.clone(),
            bytes: 1,
            licence: ck.spdx.clone(),
        };
        let ok = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            restricted,
            &row,
            &acks,
            "operator-projects",
            &verifier,
        )
        .unwrap();
        assert_eq!(ok.acknowledged_by.as_deref(), Some("operator"));

        let err = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            restricted,
            &row,
            &acks,
            "project:someone-elses-game",
            &verifier,
        )
        .unwrap_err();
        assert!(err.contains("licence_acknowledgement_required"), "{err}");
        assert!(err.contains("scope"), "{err}");
    }

    /// The production entry point uses the shipped registers and the host's
    /// enrolled signers: a permissive row needs neither, and the shipped
    /// CorridorKey row, with no record in the project, is refused and names
    /// the skill.
    #[test]
    fn the_shipped_gate_admits_permissive_rows_and_names_the_skill_for_restricted_ones() {
        let dir = disk_scratch("shipped");
        let signers = dir.join("allowed_signers");
        fs::write(&signers, "").unwrap();
        // SAFETY: tests in this module run in one process; the variable is
        // read back immediately and only names a path inside the scratch dir.
        unsafe { std::env::set_var("TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS", &signers) };
        let verifier = Verifier::for_host();
        assert_eq!(verifier.allowed_signers, signers);
        let permissive = ModelFile {
            tier: "I0".into(),
            role: "unet".into(),
            repo: "IDKiro/sdxs-512-0.9".into(),
            revision: "c332f05f60eb4b453de513be52c2a18c48d8cfe6".into(),
            file: "unet/diffusion_pytorch_model.safetensors".into(),
            sha256: "c2afb7dbea11b64d0bfbc4d1a45854aa65408b8a74a732438225d3f2ec85c71c".into(),
            bytes: 1,
            licence: "openrail++".into(),
        };
        let ok = register_admits_with_consent(&permissive, &dir, "project:demo", &verifier).unwrap();
        assert!(ok.acknowledged_by.is_none());
        let ck = parse_restricted(restricted_register_tsv())
            .unwrap()
            .into_iter()
            .find(|r| r.file == "corridorkey_v2.safetensors")
            .unwrap();
        let row = ModelFile {
            tier: "I1/corridorkey".into(),
            role: "studio:corridorkey".into(),
            repo: ck.repo,
            revision: ck.revision,
            file: ck.file,
            sha256: ck.sha256,
            bytes: 1,
            licence: ck.spdx,
        };
        let err = register_admits_with_consent(&row, &dir, "operator-projects", &verifier).unwrap_err();
        assert!(err.starts_with("licence_acknowledgement_required:"), "{err}");
        assert!(err.contains("attribution{CorridorKey}"), "{err}");
        assert!(err.contains("accept-licence"), "{err}");
    }

    /// The shipped restricted register parses, every row has obligation
    /// classes and a licence hash (or an explicit pending marker), and none of
    /// its rows is in the permissive register.
    #[test]
    fn the_shipped_restricted_register_is_well_formed() {
        let rows = parse_restricted(restricted_register_tsv()).unwrap();
        assert!(rows.len() >= 4, "{rows:?}");
        for r in &rows {
            assert!(!r.obligations.is_empty(), "{}: no obligation classes", r.name);
            assert!(
                r.licence_sha256.len() == 64 || r.licence_sha256.starts_with("pending:"),
                "{}: licence hash {:?}",
                r.name,
                r.licence_sha256
            );
            assert!(
                !crate::imagegen_tiers::PERMISSIVE_LICENCES.contains(&r.spdx.as_str())
                    || r.spdx == "mit"
                    || r.spdx == "cc-by-4.0",
                "{}: {} is permissive; it belongs in the permissive register unless it is a CorridorKey foundation model",
                r.name,
                r.spdx
            );
        }
        // The yaml record round-trips, and the committed seed is that record.
        let ack = operator_standing_acknowledgement();
        let back = Acknowledgement::from_yaml(&ack.to_yaml()).unwrap();
        assert_eq!(back, ack);
        let seed = Acknowledgement::from_yaml(include_str!(
            "../../../licences/acknowledgements/operator-standing-approval.yaml"
        ))
        .unwrap();
        assert_eq!(seed, ack);
        assert!(seed.signature.is_empty(), "the seed is signed by the operator, not by a build");
    }
}
