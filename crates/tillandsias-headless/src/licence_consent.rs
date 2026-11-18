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
    Attribution {
        text: String,
    },
    /// Carry the licence text or a notice referring to it.
    Notice,
    /// Modifications go out under the same licence.
    ShareAlike,
    NonCommercial,
    /// OpenRAIL Attachment A and kin: the use restrictions pass downstream.
    UseRestrictionPassdown,
    /// Named uses the licence forbids or conditions.
    FieldOfUse,
    SeatOrRevenueThreshold {
        detail: String,
    },
    NoRedistribution,
    /// GPL-3.0 and kin: conveying object code means conveying the source.
    SourceAvailability,
    /// A clause nobody classified: the project reads it before relying on it.
    Review {
        clause: String,
    },
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
            "attribution" => Self::Attribution {
                text: detail.to_string(),
            },
            "notice" => Self::Notice,
            "share-alike" => Self::ShareAlike,
            "non-commercial" => Self::NonCommercial,
            "use-restriction-passdown" => Self::UseRestrictionPassdown,
            "field-of-use" => Self::FieldOfUse,
            "seat-or-revenue-threshold" => Self::SeatOrRevenueThreshold {
                detail: detail.to_string(),
            },
            "no-redistribution" => Self::NoRedistribution,
            "source-availability" => Self::SourceAvailability,
            "review" => Self::Review {
                clause: detail.to_string(),
            },
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
// The Demucs README "License" section at adefossez/demucs commit 829d2189
// (README sha256 2abed9c9…), quoted verbatim (2068-eeti).
const DEMUCS_UNCLEAR: &str = "The license of the weights is not clear: MusDB contains some data that were only usable for research purpose. I sadly cannot help granting a license, both coming from Meta custom data, or from the original MusDB data.";
const DEMUCS_6S: &str = "The 6 source variant of htdemucs was trained only on Meta internal dataset, which likely means CC-NC-BY license is applicable, as it was the case for all models released by FAIR.";
const NVIDIA_UNREAD: &str = "the NVIDIA Open Model License Agreement (June 2024) is published only as a PDF at developer.download.nvidia.com, which this host could not fetch; its clauses are classed from the licence as remembered and are not quoted. Read it before relying on these classes.";

// 2094-h3rq: Fish Audio Research License Agreement (fishaudio/s2-pro
// LICENSE.md, Last Updated March 7, 2026), quoted without its Markdown bold.
const FISH_NC: &str = "Any use of the Fish Audio Materials or Derivative Works for a Commercial Purpose requires a separate written license agreement from Fish Audio. No commercial rights are granted under this Agreement.";
const FISH_ATTRIBUTION: &str = "(iii) prominently display \"Built with Fish Audio\" on a related website, user interface, blogpost, about page, or product documentation.";
const FISH_NOTICE: &str = "(i) provide a copy of this Agreement to that third party, (ii) retain the following attribution notice within a \"Notice\" text file distributed as a part of such copies: \"This model is licensed under the Fish Audio Research License, Copyright © 39 AI, INC. All Rights Reserved.\"";
const FISH_FIELD: &str = "Furthermore, You will not use the Fish Audio Materials or Derivative Works, or any output or results of the Fish Audio Materials or Derivative Works, to create or improve any foundational generative AI model (excluding the Models or Derivative Works).";
const FISH_AUP: &str = "Your use of the Fish Audio Materials and Derivative Works, including any output or results of the Fish Audio Materials or Derivative Works, must comply with applicable laws and regulations (including Trade Control Laws and equivalent regulations) and adhere to Fish Audio's Acceptable Use Policy, which is hereby incorporated by reference. (The Acceptable Use Policy text is not pinned here.)";
// 2094-h3rq: Boson Higgs Audio 2 Community License Agreement (June 20, 2025).
const HIGGS_ATTRIBUTION: &str = "(B) prominently display \u{201c}Built with Higgs Materials licensed from Boson AI USA, Inc., Copyright Boson AI USA, Inc., All Rights Reserved and Meta Llama 3 licensed under the Meta Llama 3 Community License, Copyright Meta Platforms, Inc., All Right Reserved\". based on Meta Llama 3\u{201d} on a related website, user interface, blogpost, about page, or product documentation.";
const HIGGS_NOTICE: &str = "(A) provide a copy of this Agreement and the of Meta License \u{2019}s Llama 3 agreement with any such Higgs Materials";
const HIGGS_FIELD: &str = "v. You will not use the Higgs Materials or any output or results of the Higgs Materials to improve any other large language model (excluding Boson Higgs Audio 2 or derivative works thereof).";
const HIGGS_THRESHOLD: &str = "If the annual active users of the products or services made available by or for Licensee, or Licensee\u{2019}s affiliates, is greater than 100,000 annual active users in the preceding calendar year, you must request an expanded license from Boson AI";
// 2094-h3rq: Meta Llama 3 Community License (meta-llama/llama3 LICENSE at
// a0940f9c, April 18, 2024) and its Acceptable Use Policy (USE_POLICY.md).
const LLAMA_ATTRIBUTION: &str = "(B) prominently display \u{201c}Built with Meta Llama 3\u{201d} on a related website, user interface, blogpost, about page, or product documentation.";
const LLAMA_NOTICE: &str = "iii. You must retain in all copies of the Llama Materials that you distribute the following attribution notice within a \u{201c}Notice\u{201d} text file distributed as a part of such copies: \u{201c}Meta Llama 3 is licensed under the Meta Llama 3 Community License, Copyright \u{a9} Meta Platforms, Inc. All Rights Reserved.\u{201d}";
const LLAMA_FIELD: &str = "v. You will not use the Llama Materials or any output or results of the Llama Materials to improve any other large language model (excluding Meta Llama 3 or derivative works thereof).";
const LLAMA_THRESHOLD: &str = "If, on the Meta Llama 3 version release date, the monthly active users of the products or services made available by or for Licensee, or Licensee\u{2019}s affiliates, is greater than 700 million monthly active users in the preceding calendar month, you must request a license from Meta";
const LLAMA_AUP: &str = "We want everyone to use Llama 3 safely and responsibly. You agree you will not use, or allow others to use, Llama 3 to: ";
/// The obligation table, keyed by licence id as the register spells it.
/// An unknown id yields one review obligation naming it.
pub fn obligations_for(licence_id: &str) -> Vec<Obligation> {
    use ObligationClass as C;
    let id = licence_id.trim().to_ascii_lowercase();
    match id.as_str() {
        "cc-by-4.0" => vec![
            ob(
                C::Attribution {
                    text: String::new(),
                },
                CC_ATTRIBUTION,
            ),
            ob(C::Notice, CC_NOTICE),
        ],
        "cc-by-nc-sa-4.0" => vec![
            ob(
                C::Attribution {
                    text: String::new(),
                },
                CC_ATTRIBUTION,
            ),
            ob(C::Notice, CC_NOTICE),
            ob(C::ShareAlike, CC_SA),
            ob(C::NonCommercial, CC_NC),
        ],
        // Operator ruling 2026-11-01: the OpenRAIL family's Attachment A use
        // restrictions MUST pass downstream, alongside attribution.
        "openrail" | "openrail-m" | "creativeml-openrail-m" | "openrail++" => vec![
            ob(C::UseRestrictionPassdown, OPENRAIL_PASSDOWN),
            ob(C::Notice, OPENRAIL_NOTICE),
            ob(
                C::Attribution {
                    text: String::new(),
                },
                OPENRAIL_ATTRIBUTION,
            ),
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
                    text: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License"
                        .into(),
                },
                "",
            ),
            ob(C::Notice, ""),
            ob(C::UseRestrictionPassdown, ""),
            ob(C::FieldOfUse, ""),
            ob(
                C::Review {
                    clause: NVIDIA_UNREAD.into(),
                },
                NVIDIA_UNREAD,
            ),
        ],
        // The id images/imagegen-corridorkey/weights.tsv (1956-ucix) spells,
        // and the older spelling of the same licence.
        "corridor-key-licence-2.0" | "corridor-key-licence-v2" => vec![
            ob(
                C::Attribution {
                    text: "CorridorKey".into(),
                },
                CK_ATTRIBUTION,
            ),
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
        // 2068-eeti: Demucs htdemucs and htdemucs_6s. No licence is stated
        // for the weights; the clauses are the maintainer's README "License"
        // section (adefossez/demucs 829d2189). Operator ruling 2026-11-09:
        // treat both as non-commercial, acknowledged per project.
        "demucs-weights-unstated" => vec![
            ob(
                C::Attribution {
                    text: "Demucs, Alexandre Défossez".into(),
                },
                DEMUCS_6S,
            ),
            ob(C::NonCommercial, DEMUCS_6S),
            ob(
                C::Review {
                    clause: DEMUCS_UNCLEAR.into(),
                },
                DEMUCS_UNCLEAR,
            ),
        ],
        // 2094-h3rq: Fish S2-Pro. Research AND non-commercial use is granted
        // (hobbyist, evaluation), so it is not forbidden outright.
        "fish-audio-research-license-2026-03-07" => vec![
            ob(
                C::Attribution {
                    text: "Built with Fish Audio".into(),
                },
                FISH_ATTRIBUTION,
            ),
            ob(C::Notice, FISH_NOTICE),
            ob(C::NonCommercial, FISH_NC),
            ob(C::FieldOfUse, FISH_FIELD),
            ob(
                C::Review {
                    clause: "the Fish Audio Acceptable Use Policy is incorporated by reference and is not pinned".into(),
                },
                FISH_AUP,
            ),
        ],
        // 2094-h3rq: Higgs Audio v2, a Meta Llama 3 derivative.
        "boson-higgs-audio-2-community" => vec![
            ob(
                C::Attribution {
                    text: "Built with Higgs Materials licensed from Boson AI USA, Inc. and Meta Llama 3".into(),
                },
                HIGGS_ATTRIBUTION,
            ),
            ob(C::Notice, HIGGS_NOTICE),
            ob(C::FieldOfUse, HIGGS_FIELD),
            ob(
                C::SeatOrRevenueThreshold {
                    detail: "100,000 annual active users: an expanded licence from Boson AI".into(),
                },
                HIGGS_THRESHOLD,
            ),
        ],
        // 2094-h3rq: the two texts Higgs Audio 2 incorporates, each its own
        // licence as demon_attack recorded them.
        "meta-llama-3-community" => vec![
            ob(
                C::Attribution {
                    text: "Built with Meta Llama 3".into(),
                },
                LLAMA_ATTRIBUTION,
            ),
            ob(C::Notice, LLAMA_NOTICE),
            ob(C::FieldOfUse, LLAMA_FIELD),
            ob(
                C::SeatOrRevenueThreshold {
                    detail: "700 million monthly active users: a licence from Meta".into(),
                },
                LLAMA_THRESHOLD,
            ),
        ],
        "meta-llama-3-acceptable-use-policy" => vec![ob(C::FieldOfUse, LLAMA_AUP)],
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

/// Licences acknowledged per project only: no standing operator grant covers
/// them (Demucs: operator ruling 2026-11-09, 2068-eeti; Fish S2-Pro and Higgs
/// v2: the licence PR flow, 2094-h3rq).
pub const PER_PROJECT_ONLY: &[&str] = &[
    "demucs-weights-unstated",
    "fish-audio-research-license-2026-03-07",
    "boson-higgs-audio-2-community",
    "meta-llama-3-community",
    "meta-llama-3-acceptable-use-policy",
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
    /// The file stem: `<licence-id>--` then the artefact slug, or
    /// grantor-scope-expiry for a grant covering several artefacts.
    pub fn slug(&self) -> String {
        // `<licence-id>--<artefact-slug>` (2094-h3rq): one repo can need
        // several licence texts (Higgs v2: Boson, Llama 3), and a name keyed
        // on the artefact alone made their PRs write one file.
        let what = if self.covers.len() == 1 {
            slugify(&self.covers[0])
        } else {
            slugify(&format!("{}-{}-{}", self.grantor, self.scope, self.expiry))
        };
        format!("{}--{what}", slugify(&self.licence))
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
        y.push_str(
            "# Third-party licence acknowledgement (order 1956-ecpb, implements 1954-dvz9).\n",
        );
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
///
/// One record per licence TEXT (a record binds one licence hash), so the one
/// grant is four records: CorridorKey 2.0 and its three foundation models.
/// They are the seeds in `licences/acknowledgements/`.
/// 2068-eeti, operator rulings 2026-11-09 and 2026-11-11: Demucs has no
/// standing grant. A Demucs record must name one project and a dated expiry.
/// Returns the reason a record breaks that rule, or None.
pub fn demucs_grant_refusal(ack: &Acknowledgement) -> Option<String> {
    if ack.licence != "demucs-weights-unstated" {
        return None;
    }
    if ack.expiry == "standing" {
        return Some("demucs: no standing grant; give a dated expiry".into());
    }
    if !ack.scope.starts_with("project:") {
        return Some(format!(
            "demucs: scope {:?} is not one project; acknowledge per project",
            ack.scope
        ));
    }
    None
}

pub fn operator_standing_acknowledgements() -> Vec<Acknowledgement> {
    let seed = |licence: &str, licence_sha256: &str, repo: &str| Acknowledgement {
        licence: licence.into(),
        licence_sha256: licence_sha256.into(),
        covers: vec![repo.into()],
        grantor: "operator".into(),
        scope: "operator-projects".into(),
        r#use: "non-sale".into(),
        expiry: "standing".into(),
        signed_at: "2026-11-01T23:45:35Z".into(),
        strength: "software-password".into(),
        host: "calmecacpilli".into(),
        signature: String::new(),
    };
    vec![
        seed(
            "corridor-key-licence-2.0",
            "c92ce56f64162b231c7ce08ce3ed7d8cae15f01a560ca05a8e8db67878eb0065",
            "nikopueringer/CorridorKey2.0",
        ),
        seed(
            "nvidia-open-model-license",
            "pending:https://developer.download.nvidia.com/licenses/nvidia-open-model-license-agreement-june-2024.pdf",
            "nvidia/C-RADIOv4-SO400M",
        ),
        seed(
            "mit",
            "ad7d951c80c5fc2b2bce035f2041bc0a0dbf9028c8ecc4c9a8e1fba8130b6b59",
            "Ruicheng/moge-2-vitb-normal",
        ),
        seed(
            "cc-by-4.0",
            "d557539df68e771cc1eedcc91d13f70fca930e508d11eedcafa4b15db49e3744",
            "google-deepmind/representations4d",
        ),
    ]
}

/// The CorridorKey record of acknowledgement #1.
pub fn operator_standing_acknowledgement() -> Acknowledgement {
    operator_standing_acknowledgements().swap_remove(0)
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
    // The trace names a spec in the AGREEING project, not in Tillandsias, so
    // the id is assembled here and the ghost-trace check does not read it as
    // a reference into this checkout.
    s.push_str(&format!(
        "@trace {}:third-party-licence-{}\n\n",
        "spec",
        slugify(licence_id)
    ));
    s.push_str("## Purpose\n\n");
    s.push_str(&format!(
        "This project depends on {artefact} and must now adhere to {list}, the obligations its licence `{licence_id}` carries. \
         The acknowledgement that accepted the licence is under `licences/acknowledgements/`, approved by a human (the merge of its licence pull request, or an OS-verified signature) and committed with this spec. \
         Tillandsias records these obligations; honouring them over the project's lifetime is the project's own work, and each requirement below says how.\n\n"
    ));
    s.push_str("## Requirements\n\n");
    for o in obligations {
        s.push_str(&format!("### Requirement: {}\n\n", o.class.title()));
        s.push_str(&requirement_sentence(o, artefact));
        s.push('\n');
        if !o.clause.is_empty() {
            s.push_str(&format!("\nThe licence says, verbatim: \"{}\"\n", o.clause));
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
            "it is offered without sale of the artefact or of outputs the licence reserves"
                .to_string(),
        ),
        C::UseRestrictionPassdown => (
            format!("someone receives {artefact} or a derivative from the project"),
            "the same use restrictions bind them, in the agreement that governs the transfer"
                .to_string(),
        ),
        C::FieldOfUse => (
            format!("a use of {artefact} is proposed"),
            "it is checked against the licence's forbidden and conditioned uses before it ships"
                .to_string(),
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
// The licence pull request (order 2094-h3rq)
// ---------------------------------------------------------------------------

/// What the accept-licence skill opens in the PROJECT repo: head
/// `licences/<licence id>`, base the default branch. The skill only opens
/// it; the human merge in the GitHub web UI is the approval.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LicencePr {
    pub head: String,
    pub title: String,
    pub body: String,
    /// `(path in the project repo, content)`.
    pub files: Vec<(String, String)>,
}

/// The licence text file the PR quotes, beside the record.
pub fn licence_text_path(licence_id: &str) -> String {
    format!("licences/texts/{}.md", slugify(licence_id))
}

/// Render the licence PR. `licence_text` must hash to `ack.licence_sha256`
/// (a record against other bytes is refused here, not at merge time);
/// `promises` is the plain-language list of what the user agrees to, one
/// sentence each.
pub fn licence_pr(
    ack: &Acknowledgement,
    artefact: &str,
    licence_text: &[u8],
    licence_url: &str,
    obligations: &[Obligation],
    promises: &[String],
    incorporated: &[IncorporatedText],
) -> Result<LicencePr, String> {
    use sha2::Digest as _;
    let got = format!("{:x}", sha2::Sha256::digest(licence_text));
    if got != ack.licence_sha256 {
        return Err(format!(
            "licence text hashes to {got}, not the pinned {}; nothing rendered",
            ack.licence_sha256
        ));
    }
    let text = String::from_utf8_lossy(licence_text);
    let id = slugify(&ack.licence);
    let record_path = format!("{ACK_REPO_DIR}/{}.yaml", ack.slug());
    let spec_path = format!("openspec/specs/third-party-licence-{id}/spec.md");
    let text_path = licence_text_path(&ack.licence);
    let mut body = String::new();
    body.push_str(&format!(
        "## Accept the {} licence for {artefact}\n\n",
        ack.licence
    ));
    body.push_str("**Pressing Merge on this pull request is your acceptance.** Nothing else asks you; nobody can press it for you (agents are refused).\n\n");
    body.push_str("### What you promise, in plain words\n\n");
    for p in promises {
        body.push_str(&format!("- {p}\n"));
    }
    body.push_str(&format!(
        "\nScope: `{}` · use: `{}` · until: `{}`\n\n",
        ack.scope, ack.r#use, ack.expiry
    ));
    body.push_str("### What this records\n\n");
    body.push_str(&format!(
        "| File | What it is |\n|---|---|\n| `{record_path}` | the acknowledgement the licence gate reads once merged |\n| `{spec_path}` | the obligations this project now carries, one requirement each |\n| `{text_path}` | the licence text, verbatim |\n\n"
    ));
    body.push_str(&format!(
        "The licence text is pinned: sha256 `{}`, from <{licence_url}>. If the text below differs by one byte, the hash differs and the gate refuses the record.\n\n",
        ack.licence_sha256
    ));
    body.push_str("### Obligations\n\n");
    for o in obligations {
        if o.clause.is_empty() {
            body.push_str(&format!("- **{}**\n", o.class.title()));
        } else {
            body.push_str(&format!("- **{}**: \"{}\"\n", o.class.title(), o.clause));
        }
    }
    body.push_str("\n<details><summary>The licence, verbatim</summary>\n\n");
    body.push_str("````text\n");
    body.push_str(&text);
    if !text.ends_with('\n') {
        body.push('\n');
    }
    body.push_str("````\n\n</details>\n\n");
    let mut extra_files = Vec::new();
    if !incorporated.is_empty() {
        body.push_str("### Incorporated by reference\n\nThis licence makes these texts part of its terms; pressing Merge accepts them too.\n\n");
    }
    for inc in incorporated {
        let got = format!("{:x}", sha2::Sha256::digest(inc.text));
        if got != inc.sha256 {
            return Err(format!(
                "incorporated text {} hashes to {got}, not the pinned {}; nothing rendered",
                inc.id, inc.sha256
            ));
        }
        let t = String::from_utf8_lossy(inc.text);
        body.push_str(&format!(
            "<details><summary>{}, verbatim (sha256 <code>{}</code>, from {})</summary>\n\n````text\n{}{}````\n\n</details>\n\n",
            inc.id,
            inc.sha256,
            inc.url,
            t,
            if t.ends_with('\n') { "" } else { "\n" }
        ));
        extra_files.push((licence_text_path(inc.id), t.into_owned()));
    }
    body.push_str("---\nOpened by the accept-licence skill. Until a human merges this in the GitHub web UI, the licence gate admits nothing. Closing it unmerged declines.\n");
    let mut files = vec![
        (record_path, ack.to_yaml()),
        (
            spec_path,
            obligations_spec(artefact, &ack.licence, obligations),
        ),
        (text_path, text.into_owned()),
    ];
    files.extend(extra_files);
    Ok(LicencePr {
        // `licences/<record file stem>`: one licence can cover several
        // artefacts (Higgs model + tokenizer), and a head named after the
        // licence alone collides (demon_attack #13-#15).
        head: format!("{LICENCE_HEAD_PREFIX}{}", ack.slug()),
        title: format!("Accept the {} licence for {artefact}", ack.licence),
        body,
        files,
    })
}

/// A text the licence incorporates by reference (Higgs Audio 2 incorporates
/// the Meta Llama 3 Community License), quoted and pinned beside it.
#[derive(Debug, Clone, Copy)]
pub struct IncorporatedText<'a> {
    pub id: &'a str,
    pub url: &'a str,
    pub sha256: &'a str,
    pub text: &'a [u8],
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
    /// When set (order 2094-h3rq), the approval is a human GitHub merge, not
    /// a signature: records are read from the gate's default branch, and the
    /// project dir and `signature` are not consulted. When unset, the SSHSIG
    /// path is unchanged: an unsigned record admits nothing.
    pub merge_gate: Option<MergeGate>,
}

impl Verifier {
    pub fn new(allowed_signers: &Path) -> Self {
        Self {
            allowed_signers: allowed_signers.to_path_buf(),
            merge_gate: None,
        }
    }

    /// The merge gate over `gate` (order 2094-h3rq).
    pub fn merged(gate: MergeGate) -> Self {
        Self {
            allowed_signers: PathBuf::new(),
            merge_gate: Some(gate),
        }
    }

    /// The gate `project`'s request goes through on this host, chosen from
    /// HOST state only (never from the forge's environment or request): when
    /// the project's git mirror answers, the merge gate over its default
    /// branch, with GitHub's confirmation required; a mirror that answers
    /// but whose default branch cannot be resolved REFUSES (never a fall
    /// back). With no mirror, the SSHSIG gate, where an unsigned record
    /// admits nothing.
    pub fn for_project_host(project: &str) -> Result<Self, String> {
        let probe = git_out(
            &GitSource::Mirror(project.to_string()),
            &["rev-parse", "--is-bare-repository"],
        );
        match probe {
            Ok(_) => Ok(Self {
                merge_gate: Some(MergeGate::for_mirror(project)?),
                ..Self::for_host()
            }),
            Err(_) => Ok(Self::for_host()),
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

// ---------------------------------------------------------------------------
// The merge gate (order 2094-h3rq)
// ---------------------------------------------------------------------------

/// Where acknowledgement records live inside a project repo.
pub const ACK_REPO_DIR: &str = "licences/acknowledgements";

/// The head-branch prefix the accept-licence skill opens its PRs from.
pub const LICENCE_HEAD_PREFIX: &str = "licences/";

/// The approval behind an admitted record when the gate is the merge gate:
/// a human merged the project's `licences/<id>` pull request into the default
/// branch. Everything but `merged_by` is read from the repo, offline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeEvidence {
    pub pr: u64,
    pub merge_sha: String,
    /// The merge commit's committer date (GitHub writes it at merge time).
    pub merged_at: String,
    /// Only from the online check (`gh api .../pulls/<n>`). `None` offline:
    /// git does not carry who pressed Merge, and the gate never guesses.
    pub merged_by: Option<String>,
    /// `offline`, `online-confirmed`, or `online-unavailable: <why>`.
    pub check: String,
}

/// The merge gate: admits only a record present on `default_ref` of `repo`
/// (the project's checkout or mirror clone) that arrived there in a GitHub
/// pull-request merge and is unchanged since. A record only in the working
/// tree, or only on an unmerged branch, admits nothing.
#[derive(Debug, Clone)]
pub struct MergeGate {
    pub repo: GitSource,
    /// e.g. `origin/main`, or `main` in the bare mirror.
    pub default_ref: String,
    /// `owner/name` for the online check.
    pub github_repo: Option<String>,
    pub online: Online,
}

/// Where the merge gate reads git. HOST-SIDE ONLY: nothing a forge sends or
/// sets chooses it (no environment variable; order 2094-h3rq, coordinator
/// ruling 2026-11-17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitSource {
    /// A repository on this host's filesystem (fixtures, a host checkout).
    Local(PathBuf),
    /// The project's git mirror, `tillandsias-git-<project>` at
    /// `/srv/git/<project>`, reached through the host's podman.
    Mirror(String),
}

/// How the gate uses the GitHub API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Online {
    /// Offline evidence only; merged_by unknown.
    Off,
    /// Confirm when reachable; unreachable leaves the offline evidence,
    /// labelled `online-unavailable`.
    Optional,
    /// Admit nothing without GitHub's confirmation. The mirror accepts forge
    /// pushes (relayed to GitHub), and a forge can push a commit that LOOKS
    /// like a GitHub merge (committer name and a gpgsig header are just
    /// bytes; nothing here verifies GitHub's key), so a mirror-read record
    /// needs GitHub to say the PR merged at that sha.
    Required,
}

fn git_out(src: &GitSource, args: &[&str]) -> Result<String, String> {
    match src {
        GitSource::Local(repo) => {
            let out = Command::new("git")
                .arg("-C")
                .arg(repo)
                .args(args)
                .stdin(Stdio::null())
                .output()
                .map_err(|e| format!("git: {e}"))?;
            if !out.status.success() {
                return Err(format!(
                    "git {}: {}",
                    args.join(" "),
                    String::from_utf8_lossy(&out.stderr).trim()
                ));
            }
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        }
        GitSource::Mirror(project) => {
            let mut c = crate::podman_command();
            c.args(mirror_git_argv(project, args));
            crate::podman_command_output(c, false)
                .map_err(|e| format!("mirror git {}: {e}", args.join(" ")))
        }
    }
}

/// `owner/name` from the source's `origin` URL when it is GitHub.
fn github_repo_of(src: &GitSource) -> Option<String> {
    let url = git_out(src, &["remote", "get-url", "origin"]).ok()?;
    url.trim()
        .trim_end_matches(".git")
        .split_once("github.com")
        .map(|(_, r)| r.trim_start_matches([':', '/']).to_string())
        .filter(|r| r.split('/').count() == 2)
}

/// The podman argv that runs `git <args>` in `project`'s mirror.
pub fn mirror_git_argv(project: &str, args: &[&str]) -> Vec<String> {
    let mut v = vec![
        "exec".to_string(),
        format!("tillandsias-git-{project}"),
        "git".to_string(),
        "-C".to_string(),
        format!("/srv/git/{project}"),
    ];
    v.extend(args.iter().map(|a| a.to_string()));
    v
}

/// `#123` from `Merge pull request #123 from owner/licences/x` (a merge
/// commit, whose head must be a licences/ branch) or from a squash subject
/// ending `(#123)`.
fn pr_from_subject(subject: &str, parents: usize) -> Option<u64> {
    if parents == 2 {
        let rest = subject.strip_prefix("Merge pull request #")?;
        let (num, from) = rest.split_once(" from ")?;
        let (_owner, head) = from.split_once('/')?;
        if !head.starts_with(LICENCE_HEAD_PREFIX) {
            return None;
        }
        return num.parse().ok();
    }
    if parents == 1 {
        let s = subject.trim_end();
        let inner = s.strip_suffix(')')?;
        let idx = inner.rfind("(#")?;
        return inner[idx + 2..].parse().ok();
    }
    None
}

impl MergeGate {
    /// `repo` with its default branch resolved from `origin/HEAD`, and the
    /// GitHub `owner/name` read from the `origin` URL when it is GitHub.
    pub fn for_repo(repo: &Path) -> Result<Self, String> {
        let src = GitSource::Local(repo.to_path_buf());
        let head = git_out(
            &src,
            &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        )
        .map_err(|e| format!("cannot resolve the default branch (origin/HEAD): {e}"))?;
        let online = if std::env::var_os("TILLANDSIAS_LICENCE_ACK_ONLINE").is_some() {
            Online::Optional
        } else {
            Online::Off
        };
        Ok(Self {
            github_repo: github_repo_of(&src),
            repo: src,
            default_ref: head.trim().to_string(),
            online,
        })
    }

    /// `project`'s git mirror: a bare repository whose `HEAD` is the default
    /// branch. Online confirmation is REQUIRED (see [`Online::Required`]).
    pub fn for_mirror(project: &str) -> Result<Self, String> {
        let src = GitSource::Mirror(project.to_string());
        let head = git_out(&src, &["symbolic-ref", "--short", "HEAD"])
            .map_err(|e| format!("cannot resolve the mirror's default branch: {e}"))?;
        Ok(Self {
            github_repo: github_repo_of(&src),
            repo: src,
            default_ref: head.trim().to_string(),
            online: Online::Required,
        })
    }

    /// Every record on the default branch (NOT the working tree).
    pub fn records(&self) -> Vec<(String, Acknowledgement)> {
        let mut out = Vec::new();
        let Ok(list) = git_out(
            &self.repo,
            &[
                "ls-tree",
                "--name-only",
                &format!("{}:{ACK_REPO_DIR}", self.default_ref),
            ],
        ) else {
            return out;
        };
        for name in list.lines() {
            let Some(slug) = name.strip_suffix(".yaml") else {
                continue;
            };
            let spec = format!("{}:{ACK_REPO_DIR}/{name}", self.default_ref);
            if let Ok(text) = git_out(&self.repo, &["show", &spec])
                && let Ok(a) = Acknowledgement::from_yaml(&text)
            {
                out.push((slug.to_string(), a));
            }
        }
        out
    }

    /// The evidence that `slug`'s record reached the default branch through a
    /// GitHub PR merge, or why it did not.
    pub fn evidence(&self, slug: &str) -> Result<MergeEvidence, String> {
        let path = format!("{ACK_REPO_DIR}/{slug}.yaml");
        let log = git_out(
            &self.repo,
            &[
                "log",
                "--first-parent",
                "--diff-filter=AM",
                "-n1",
                "--format=%H%x00%P%x00%cn%x00%ce%x00%cI%x00%s",
                &self.default_ref,
                "--",
                &path,
            ],
        )?;
        let line = log.trim_end_matches('\n');
        if line.is_empty() {
            return Err(format!(
                "{path} is not on the default branch {}: an unmerged pull request admits nothing",
                self.default_ref
            ));
        }
        let f: Vec<&str> = line.split('\0').collect();
        if f.len() != 6 {
            return Err(format!("unreadable git log line for {path}"));
        }
        let (sha, parents, cn, ce, date, subject) = (f[0], f[1], f[2], f[3], f[4], f[5]);
        let nparents = parents.split_whitespace().count();
        if cn != "GitHub" || ce != "noreply@github.com" {
            return Err(format!(
                "{path} last changed on {} in {sha} committed by {cn} <{ce}>, not by a GitHub pull-request merge",
                self.default_ref
            ));
        }
        let raw = git_out(&self.repo, &["cat-file", "commit", sha])?;
        if !raw.lines().any(|l| l.starts_with("gpgsig ")) {
            return Err(format!(
                "{sha} claims GitHub as committer but carries no GitHub signature"
            ));
        }
        let Some(pr) = pr_from_subject(subject, nparents) else {
            return Err(format!(
                "{sha} is not a merge of a {LICENCE_HEAD_PREFIX} pull request (subject {subject:?})"
            ));
        };
        let mut ev = MergeEvidence {
            pr,
            merge_sha: sha.to_string(),
            merged_at: date.to_string(),
            merged_by: None,
            check: "offline".into(),
        };
        if self.online == Online::Off {
            return Ok(ev);
        }
        let Some(gh) = &self.github_repo else {
            return match self.online {
                Online::Required => Err(format!(
                    "{sha}: GitHub must confirm PR #{pr}, and the repo names no GitHub origin"
                )),
                _ => {
                    ev.check = "online-unavailable: no GitHub origin".into();
                    Ok(ev)
                }
            };
        };
        {
            match online_pr(gh, pr) {
                Ok((merged, merge_sha, by)) => {
                    if !merged || merge_sha != ev.merge_sha {
                        return Err(format!(
                            "GitHub says PR #{pr} merged={merged} merge_commit_sha={merge_sha}, not {}",
                            ev.merge_sha
                        ));
                    }
                    ev.merged_by = Some(by);
                    ev.check = "online-confirmed".into();
                }
                // No network is not a pass and not a refusal: the offline
                // evidence stands, labelled, and merged_by stays unknown.
                Err(e) if self.online == Online::Required => {
                    return Err(format!(
                        "GitHub could not confirm PR #{pr} ({e}); a mirror-read record admits only with that confirmation, retry when GitHub is reachable"
                    ));
                }
                Err(e) => ev.check = format!("online-unavailable: {e}"),
            }
        }
        Ok(ev)
    }
}

/// `(merged, merge_commit_sha, merged_by)` for PR `n` of `owner/name`, read
/// through `gh api` (a read; never a merge).
fn online_pr(github_repo: &str, n: u64) -> Result<(bool, String, String), String> {
    let out = Command::new("gh")
        .args([
            "api",
            &format!("repos/{github_repo}/pulls/{n}"),
            "--jq",
            "[.merged, .merge_commit_sha, (.merged_by.login // \"\")] | @tsv",
        ])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("gh: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let f: Vec<&str> = s.trim_end().split('\t').collect();
    if f.len() != 3 {
        return Err(format!("unexpected gh api output {s:?}"));
    }
    Ok((f[0] == "true", f[1].to_string(), f[2].to_string()))
}

/// What an admitted fetch carries into provenance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Admission {
    pub licence: String,
    /// `None` for a permissive row; the grantor for an acknowledged one.
    pub acknowledged_by: Option<String>,
    pub acknowledgement_slug: Option<String>,
    pub obligations: Vec<ObligationClass>,
    /// The merge that approved the record, under the merge gate.
    pub merge: Option<MergeEvidence>,
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
                merge: None,
            });
        }
        Err(e) => e,
    };
    let rows = parse_restricted(restricted_register)?;
    let matched = find_restricted(&rows, &row.repo, &row.revision, &row.file, &row.sha256);
    if matched.is_empty() {
        return Err(format!(
            "{permissive_err}; nor in images/models/licence-register-restricted.tsv"
        ));
    }
    // Every licence the file is registered under must admit it (2094-h3rq).
    let mut first = None;
    for r in matched {
        let a = admit_restricted_row(
            r,
            &row.label(),
            project_ack_dir,
            &[requester_scope],
            verifier,
        )?;
        first.get_or_insert(a);
    }
    Ok(first.expect("matched is non-empty"))
}

fn find_restricted<'a>(
    rows: &'a [RestrictedRow],
    repo: &str,
    revision: &str,
    file: &str,
    sha256: &str,
) -> Vec<&'a RestrictedRow> {
    rows.iter()
        .filter(|r| {
            r.repo == repo
                && r.revision == revision
                && r.file == file
                && r.sha256.eq_ignore_ascii_case(sha256)
        })
        .collect()
}

/// The D6 gate for one restricted row: not gated, not forbidden outright, its
/// licence text pinned, and an acknowledgement in `project_ack_dir` that
/// covers the repo, names the same licence id and text hash, carries one of
/// `requester_scopes`, is in force, and whose SSHSIG verifies.
fn admit_restricted_row(
    r: &RestrictedRow,
    label: &str,
    project_ack_dir: &Path,
    requester_scopes: &[&str],
    verifier: &Verifier,
) -> Result<Admission, String> {
    if r.gated != "false" {
        return Err(format!(
            "model_refused: {label} is gated; clicking through gated terms on a user's behalf is never authorised"
        ));
    }
    if let Some(why) = forbidden_outright(&r.spdx) {
        return Err(format!(
            "licence_forbids_use: {label} licence {}: {why}",
            r.spdx
        ));
    }
    if r.licence_sha256.starts_with("pending:") {
        return Err(format!(
            "licence_text_unpinned: {label} licence {} has no licence text hash in the register ({}); nothing can be acknowledged against it",
            r.spdx, r.licence_sha256
        ));
    }
    let now = chrono::Utc::now();
    let mut reasons: Vec<String> = Vec::new();
    // Under the merge gate the MERGED records come from the default branch,
    // never from the working tree (order 2094-h3rq). Signed records in the
    // project dir still verify by their SSHSIG against the host's enrolled
    // signers: the signature gate is replaced only for unsigned records, and
    // an unsigned record outside the default branch admits nothing.
    let mut records: Vec<(String, Acknowledgement, bool)> = Vec::new();
    if let Some(g) = &verifier.merge_gate {
        records.extend(g.records().into_iter().map(|(s, a)| (s, a, true)));
    }
    records.extend(
        read_acknowledgements(project_ack_dir)
            .into_iter()
            .map(|(s, a)| (s, a, false)),
    );
    for (slug, ack, merged) in records {
        if !ack.covers.iter().any(|c| c == &r.repo) {
            continue;
        }
        if ack.licence != r.spdx {
            reasons.push(format!("{slug}: licence {} is not {}", ack.licence, r.spdx));
            continue;
        }
        if ack.licence_sha256 != r.licence_sha256 {
            reasons.push(format!(
                "{slug}: licence text hash differs from the register's"
            ));
            continue;
        }
        if !requester_scopes.contains(&ack.scope.as_str()) {
            reasons.push(format!(
                "{slug}: scope {} does not cover the requester's scope {}",
                ack.scope,
                requester_scopes.join(" or ")
            ));
            continue;
        }
        if !ack.in_force(now) {
            reasons.push(format!("{slug}: expired at {}", ack.expiry));
            continue;
        }
        let approved = match (&verifier.merge_gate, merged) {
            (Some(g), true) => g.evidence(&slug).map(Some),
            _ => verifier
                .verify(&ack.statement_text(), &ack.signature, &ack.grantor)
                .map(|()| None),
        };
        match approved {
            Ok(merge) => {
                return Ok(Admission {
                    licence: r.spdx.clone(),
                    acknowledged_by: Some(
                        merge
                            .as_ref()
                            .and_then(|m| m.merged_by.clone())
                            .unwrap_or_else(|| ack.grantor.clone()),
                    ),
                    acknowledgement_slug: Some(slug),
                    obligations: r.obligations.clone(),
                    merge,
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
        "licence_acknowledgement_required: {label} licence {} ({}): {detail}. Run the accept-licence skill in the project.",
        r.spdx,
        ObligationClass::render_list(&r.obligations)
    ))
}

// ---------------------------------------------------------------------------
// The one-call gate studio jobs use (1956-ucix: studio_key.rs)
// ---------------------------------------------------------------------------

/// One restricted artefact a job wants to use: enough to match a register row
/// (repo, revision, file, sha256) and the acknowledgement that covers it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestrictedArtefact {
    pub licence: String,
    pub repo: String,
    pub revision: String,
    pub file: String,
    pub sha256: String,
}

/// Where the gate reads `project`'s acknowledgement records on this host:
/// `TILLANDSIAS_LICENCE_ACK_DIR`, or
/// `<state dir>/licence-acknowledgements/<project slug>/`. The durable record
/// is the one committed in the project (D6); the tray keeps this copy when it
/// signs, because the host has no checkout handle for a bare project label.
pub fn project_acknowledgement_dir(project: &str) -> PathBuf {
    if let Some(p) = std::env::var_os("TILLANDSIAS_LICENCE_ACK_DIR") {
        return PathBuf::from(p);
    }
    tillandsias_core::config::state_dir()
        .join("licence-acknowledgements")
        .join(slugify(project))
}

/// Does a recorded acknowledgement admit every artefact for `project`?
/// `Ok(ids)` carries one acknowledgement id (the record's slug) per artefact,
/// in order, for the provenance `consent` field; `Err` names the first
/// artefact refused, prefixed `consent_required:`. A request from `project`
/// is covered by a record of scope `project:<project>` or, for the operator's
/// own projects, `operator-projects` (acknowledgement #1).
pub fn admits_restricted(
    project: &str,
    artefacts: &[RestrictedArtefact],
) -> Result<Vec<String>, String> {
    let verifier = Verifier::for_project_host(project).map_err(|e| {
        format!("consent_required: {project}: the licence gate cannot read its repo: {e}")
    })?;
    admits_restricted_in(
        RESTRICTED_REGISTER_TSV,
        project,
        artefacts,
        &project_acknowledgement_dir(project),
        &verifier,
    )
}

/// [`admits_restricted`] against an explicit register, record dir and
/// verifier (fixtures).
pub fn admits_restricted_in(
    restricted_register: &str,
    project: &str,
    artefacts: &[RestrictedArtefact],
    project_ack_dir: &Path,
    verifier: &Verifier,
) -> Result<Vec<String>, String> {
    admit_artefacts_in(
        restricted_register,
        project,
        artefacts,
        project_ack_dir,
        verifier,
    )
    .map_err(|r| match r {
        GateRefusal::Unmatched(e) => format!("consent_required: {project}: {e}"),
        GateRefusal::Row(e) => {
            format!("consent_required: {project}: {e} Nothing was fetched or queued.")
        }
    })
}

/// Why [`admit_artefacts_in`] refused, before the caller words it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GateRefusal {
    /// No artefact, an unreadable register, or an artefact that matches no
    /// row (or names another licence than its row).
    Unmatched(String),
    /// The row's own gate refused: `model_refused`, `licence_forbids_use`,
    /// `licence_text_unpinned` or `licence_acknowledgement_required`.
    Row(String),
}

/// The gate behind [`admits_restricted_in`], with the refusal unworded, so
/// the restricted fetch (order 2068-ypgq) answers the row's own refusal
/// (`licence_acknowledgement_required: ...`) and a studio job its
/// `consent_required:` sentence, from ONE decision.
pub fn admit_artefacts_in(
    restricted_register: &str,
    project: &str,
    artefacts: &[RestrictedArtefact],
    project_ack_dir: &Path,
    verifier: &Verifier,
) -> Result<Vec<String>, GateRefusal> {
    if artefacts.is_empty() {
        return Err(GateRefusal::Unmatched(
            "no artefact named (nothing to admit)".into(),
        ));
    }
    let rows = parse_restricted(restricted_register).map_err(GateRefusal::Unmatched)?;
    let project_scope = format!("project:{project}");
    let scopes = [project_scope.as_str(), "operator-projects"];
    let mut ids = Vec::with_capacity(artefacts.len());
    for a in artefacts {
        let label = format!("{}@{} {}", a.repo, a.revision, a.file);
        let matched = find_restricted(&rows, &a.repo, &a.revision, &a.file, &a.sha256);
        if matched.is_empty() {
            return Err(GateRefusal::Unmatched(format!(
                "{label} (sha256 {}) is not in images/models/licence-register-restricted.tsv; nothing was fetched or queued",
                a.sha256
            )));
        }
        if !matched
            .iter()
            .any(|r| r.spdx.eq_ignore_ascii_case(&a.licence))
        {
            return Err(GateRefusal::Unmatched(format!(
                "{label} is registered under licence {} but the job names {}; nothing was fetched or queued",
                matched
                    .iter()
                    .map(|r| r.spdx.as_str())
                    .collect::<Vec<_>>()
                    .join(" + "),
                a.licence
            )));
        }
        // A file under several licences (Higgs v2: Boson, Llama 3, its AUP)
        // is admitted only when EVERY one is acknowledged (2094-h3rq).
        let mut slugs = Vec::with_capacity(matched.len());
        for r in matched {
            let admitted = admit_restricted_row(r, &label, project_ack_dir, &scopes, verifier)
                .map_err(GateRefusal::Row)?;
            slugs.push(
                admitted
                    .acknowledgement_slug
                    .unwrap_or_else(|| "permissive".to_string()),
            );
        }
        ids.push(slugs.join("+"));
    }
    Ok(ids)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::imagegen_models::ModelFile;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    /// A disk-backed scratch dir beside the test binary (never /tmp, which is
    /// tmpfs on the fleet's Fedora hosts).
    pub(crate) fn disk_scratch(tag: &str) -> PathBuf {
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
    pub(crate) fn enrol(dir: &Path, grantor: &str) -> (PathBuf, PathBuf) {
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
    pub(crate) fn sign(dir: &Path, key: &Path, mut ack: Acknowledgement) -> Acknowledgement {
        let msg = dir.join("statement");
        // ssh-keygen -Y sign keeps an existing .sig; a stale one would be
        // read back as this record's signature.
        let _ = fs::remove_file(dir.join("statement.sig"));
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
    fn git(repo: &Path, committer: (&str, &str), args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args([
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ])
            .args(args)
            .env("GIT_AUTHOR_NAME", "owner")
            .env("GIT_AUTHOR_EMAIL", "owner@example.invalid")
            .env("GIT_COMMITTER_NAME", committer.0)
            .env("GIT_COMMITTER_EMAIL", committer.1)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .expect("git");
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    const OWNER: (&str, &str) = ("owner", "owner@example.invalid");
    const WEB_FLOW: (&str, &str) = ("GitHub", "noreply@github.com");

    /// A merge commit of `head` into `origin/main` with `committer`, signed
    /// (a gpgsig header, as GitHub's web-flow writes) when `signed`.
    fn merge_into_main(
        repo: &Path,
        head: &str,
        subject: &str,
        committer: (&str, &str),
        signed: bool,
    ) {
        let tree = git(repo, OWNER, &["rev-parse", &format!("{head}^{{tree}}")]);
        let base = git(repo, OWNER, &["rev-parse", "refs/remotes/origin/main"]);
        let tip = git(repo, OWNER, &["rev-parse", head]);
        let c = git(
            repo,
            committer,
            &["commit-tree", &tree, "-p", &base, "-p", &tip, "-m", subject],
        );
        let sha = if signed {
            let raw = git(repo, OWNER, &["cat-file", "commit", &c]);
            let (hdr, body) = raw.split_once("\n\n").unwrap();
            let signed = format!(
                "{hdr}\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n wsBcBAABCAAQBQJfixture\n -----END PGP SIGNATURE-----\n\n{body}\n"
            );
            let p = repo.join(".git").join("signed-commit");
            fs::write(&p, signed).unwrap();
            git(
                repo,
                OWNER,
                &["hash-object", "-t", "commit", "-w", p.to_str().unwrap()],
            )
        } else {
            c
        };
        git(
            repo,
            OWNER,
            &["update-ref", "refs/remotes/origin/main", &sha],
        );
    }

    /// ORDER 2094-h3rq: the merge gate admits a record only once a GitHub
    /// pull-request merge put it on the default branch. Every record here is
    /// UNSIGNED, so nothing but the merge can be what admits it.
    #[test]
    fn the_merge_gate_admits_only_a_record_merged_into_the_default_branch() {
        let dir = disk_scratch("merge");
        let repo = dir.join("project");
        fs::create_dir_all(&repo).unwrap();
        git(&repo, OWNER, &["init", "-q"]);
        fs::write(repo.join("README"), "demo\n").unwrap();
        git(&repo, OWNER, &["add", "README"]);
        git(&repo, OWNER, &["commit", "-qm", "base"]);
        git(
            &repo,
            OWNER,
            &["update-ref", "refs/remotes/origin/main", "HEAD"],
        );
        git(
            &repo,
            OWNER,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );
        let base = git(&repo, OWNER, &["rev-parse", "refs/remotes/origin/main"]);
        let reset = || {
            git(
                &repo,
                OWNER,
                &["update-ref", "refs/remotes/origin/main", &base],
            )
        };
        let gate = MergeGate::for_repo(&repo).unwrap();
        assert_eq!(gate.default_ref, "origin/main");
        let verifier = Verifier::merged(gate);
        let row = nc_row();
        let ack = nc_ack("project:demo");
        assert!(ack.signature.is_empty());
        let admit = || {
            register_admits_with_consent_in(
                crate::imagegen_models::register_tsv(),
                RESTRICTED,
                &row,
                // The project dir holds the record too: it must not count.
                &repo.join(ACK_REPO_DIR),
                "project:demo",
                &verifier,
            )
        };

        // The PR branch carries the record; the working tree has it checked out.
        git(
            &repo,
            OWNER,
            &["checkout", "-qb", "licences/cc-by-nc-sa-4.0"],
        );
        fs::create_dir_all(repo.join(ACK_REPO_DIR)).unwrap();
        let rel = format!("{ACK_REPO_DIR}/{}.yaml", ack.slug());
        fs::write(repo.join(&rel), ack.to_yaml()).unwrap();
        git(&repo, OWNER, &["add", &rel]);
        git(&repo, OWNER, &["commit", "-qm", "licence: cc-by-nc-sa-4.0"]);

        // An open, unmerged PR admits nothing, though the file is right there.
        let err = admit().unwrap_err();
        assert!(err.contains("licence_acknowledgement_required"), "{err}");

        // A merge an agent made and pushed (land-queue shape) is not a GitHub merge.
        merge_into_main(
            &repo,
            "licences/cc-by-nc-sa-4.0",
            "Merge pull request #7 from o/licences/cc-by-nc-sa-4.0",
            ("land-queue", "land-queue@localhost"),
            false,
        );
        let err = admit().unwrap_err();
        assert!(err.contains("not by a GitHub pull-request merge"), "{err}");

        // GitHub's committer without GitHub's signature is a forgery.
        reset();
        merge_into_main(
            &repo,
            "licences/cc-by-nc-sa-4.0",
            "Merge pull request #7 from o/licences/cc-by-nc-sa-4.0",
            WEB_FLOW,
            false,
        );
        let err = admit().unwrap_err();
        assert!(err.contains("no GitHub signature"), "{err}");

        // The web-UI merge admits it, with the evidence.
        reset();
        merge_into_main(
            &repo,
            "licences/cc-by-nc-sa-4.0",
            "Merge pull request #7 from o/licences/cc-by-nc-sa-4.0",
            WEB_FLOW,
            true,
        );
        let ok = admit().unwrap();
        let m = ok.merge.clone().expect("merge evidence");
        assert_eq!(m.pr, 7);
        assert_eq!(
            m.merge_sha,
            git(&repo, OWNER, &["rev-parse", "refs/remotes/origin/main"])
        );
        assert!(!m.merged_at.is_empty());
        // Offline, who pressed Merge is unknown, never guessed.
        assert_eq!(m.merged_by, None);
        assert_eq!(m.check, "offline");

        // The mirror's gate REQUIRES GitHub's confirmation: without it the
        // same structurally perfect merge admits nothing (a forge can push
        // bytes that look like a GitHub merge).
        let strict = Verifier::merged(MergeGate {
            online: Online::Required,
            github_repo: None,
            ..MergeGate::for_repo(&repo).unwrap()
        });
        let err = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &row,
            &repo.join(ACK_REPO_DIR),
            "project:demo",
            &strict,
        )
        .unwrap_err();
        assert!(err.contains("GitHub must confirm"), "{err}");

        // Edited on the default branch after the merge: the merge no longer
        // vouches for these bytes.
        git(
            &repo,
            OWNER,
            &["checkout", "-q", "--detach", "refs/remotes/origin/main"],
        );
        let mut edited = nc_ack("project:demo");
        edited.r#use = "commercial".into();
        fs::write(repo.join(&rel), edited.to_yaml()).unwrap();
        git(&repo, OWNER, &["commit", "-qam", "widen use"]);
        git(
            &repo,
            OWNER,
            &["update-ref", "refs/remotes/origin/main", "HEAD"],
        );
        let err = admit().unwrap_err();
        assert!(err.contains("not by a GitHub pull-request merge"), "{err}");
    }

    #[test]
    fn the_licence_pr_quotes_the_pinned_text_and_refuses_other_bytes() {
        use sha2::Digest as _;
        let text = b"LICENCE TEXT\nline two\n";
        let mut ack = nc_ack("project:demo");
        ack.licence_sha256 = format!("{:x}", sha2::Sha256::digest(text));
        let obl = obligations_for(&ack.licence);
        let promises = vec!["I will not sell anything made with it.".to_string()];
        let pr = licence_pr(
            &ack,
            "fixture/nc-weights",
            text,
            "https://example.invalid/l",
            &obl,
            &promises,
            &[],
        )
        .unwrap();
        assert_eq!(pr.head, "licences/cc-by-nc-sa-4-0--fixture-nc-weights");
        assert!(
            pr.body
                .contains("Pressing Merge on this pull request is your acceptance")
        );
        assert!(pr.body.contains("LICENCE TEXT\nline two\n"));
        assert!(pr.body.contains(&ack.licence_sha256));
        let (rec_path, rec) = &pr.files[0];
        assert_eq!(rec_path, &format!("{ACK_REPO_DIR}/{}.yaml", ack.slug()));
        assert_eq!(Acknowledgement::from_yaml(rec).unwrap(), ack);
        assert_eq!(pr.files[2].1.as_bytes(), text);
        let err = licence_pr(
            &ack,
            "x",
            b"LICENCE TEXT\nline 2\n",
            "u",
            &obl,
            &promises,
            &[],
        )
        .unwrap_err();
        assert!(err.contains("not the pinned"), "{err}");
        // An incorporated text is pinned too: other bytes render nothing.
        let inc_text = b"INCORPORATED\n";
        let inc_sha = format!("{:x}", sha2::Sha256::digest(inc_text));
        let inc = IncorporatedText {
            id: "meta-llama-3-community",
            url: "https://example.invalid/llama",
            sha256: &inc_sha,
            text: inc_text,
        };
        let pr = licence_pr(&ack, "x", text, "u", &obl, &promises, &[inc]).unwrap();
        assert!(pr.body.contains("### Incorporated by reference"));
        assert!(pr.body.contains("INCORPORATED\n"));
        assert_eq!(pr.files[3].0, "licences/texts/meta-llama-3-community.md");
        let bad = IncorporatedText {
            text: b"OTHER\n",
            ..inc
        };
        let err = licence_pr(&ack, "x", text, "u", &obl, &promises, &[bad]).unwrap_err();
        assert!(err.contains("incorporated text"), "{err}");
    }

    /// The skill's DRY RUN: render a licence PR to a local dir, opening
    /// nothing. Inputs from the environment (TILLANDSIAS_LICENCE_PR_DRY_RUN=
    /// <out dir>, plus _TEXT, _URL, _LICENCE, _REPO, _SCOPE, _HOST, _PROMISES
    /// as lines). Run: cargo test -p tillandsias-headless --features
    /// host-services licence_pr_dry_run -- --ignored
    #[test]
    #[ignore = "a renderer driven by env, not a check"]
    fn licence_pr_dry_run() {
        use sha2::Digest as _;
        let env = |k: &str| std::env::var(format!("TILLANDSIAS_LICENCE_PR_DRY_RUN{k}")).unwrap();
        let out = PathBuf::from(env(""));
        let text = fs::read(env("_TEXT")).unwrap();
        let ack = Acknowledgement {
            licence: env("_LICENCE"),
            licence_sha256: format!("{:x}", sha2::Sha256::digest(&text)),
            covers: vec![env("_REPO")],
            grantor: "project-owner".into(),
            scope: env("_SCOPE"),
            r#use: "non-sale".into(),
            expiry: "standing".into(),
            signed_at: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            strength: "github-merge".into(),
            host: env("_HOST"),
            signature: String::new(),
        };
        let promises: Vec<String> = env("_PROMISES").lines().map(str::to_string).collect();
        let obl = obligations_for(&ack.licence);
        // _INCORPORATED (optional): lines `<id>|<url>|<path>`.
        let inc_raw: Vec<(String, String, Vec<u8>, String)> =
            std::env::var("TILLANDSIAS_LICENCE_PR_DRY_RUN_INCORPORATED")
                .unwrap_or_default()
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(|l| {
                    let mut it = l.splitn(3, '|');
                    let id = it.next().unwrap().to_string();
                    let url = it.next().unwrap().to_string();
                    let bytes = fs::read(it.next().unwrap()).unwrap();
                    let sha = format!("{:x}", sha2::Sha256::digest(&bytes));
                    (id, url, bytes, sha)
                })
                .collect();
        let inc: Vec<IncorporatedText> = inc_raw
            .iter()
            .map(|(id, url, bytes, sha)| IncorporatedText {
                id,
                url,
                sha256: sha,
                text: bytes,
            })
            .collect();
        let pr = licence_pr(
            &ack,
            &env("_REPO"),
            &text,
            &env("_URL"),
            &obl,
            &promises,
            &inc,
        )
        .unwrap();
        for (p, c) in &pr.files {
            let dst = out.join("files").join(p);
            fs::create_dir_all(dst.parent().unwrap()).unwrap();
            fs::write(dst, c).unwrap();
        }
        fs::write(out.join("pr-body.md"), &pr.body).unwrap();
        fs::write(
            out.join("pr-meta.txt"),
            format!(
                "head: {}\nbase: <default branch>\ntitle: {}\n",
                pr.head, pr.title
            ),
        )
        .unwrap();
    }

    /// The merge gate replaces the signature only for unsigned records: a
    /// SIGNED record in the project dir (the demucs shape) still admits by
    /// its SSHSIG when the project has a mirror.
    #[test]
    fn a_signed_record_still_admits_under_the_merge_gate() {
        let dir = disk_scratch("merge-signed");
        let (key, signers) = enrol(&dir, "operator");
        let repo = dir.join("project");
        fs::create_dir_all(&repo).unwrap();
        git(&repo, OWNER, &["init", "-q"]);
        git(
            &repo,
            OWNER,
            &["commit", "-q", "--allow-empty", "-m", "base"],
        );
        git(
            &repo,
            OWNER,
            &["update-ref", "refs/remotes/origin/main", "HEAD"],
        );
        git(
            &repo,
            OWNER,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );
        let verifier = Verifier {
            allowed_signers: signers,
            merge_gate: Some(MergeGate::for_repo(&repo).unwrap()),
        };
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let unsigned = nc_ack("project:demo");
        fs::write(acks.join("unsigned.yaml"), unsigned.to_yaml()).unwrap();
        let admit = || {
            register_admits_with_consent_in(
                crate::imagegen_models::register_tsv(),
                RESTRICTED,
                &nc_row(),
                &acks,
                "project:demo",
                &verifier,
            )
        };
        assert!(admit().is_err(), "an unsigned, unmerged record admitted");
        let signed = sign(&dir, &key, nc_ack("project:demo"));
        fs::write(acks.join("signed.yaml"), signed.to_yaml()).unwrap();
        let ok = admit().unwrap();
        assert_eq!(ok.acknowledgement_slug.as_deref(), Some("signed"));
        assert_eq!(ok.merge, None);
    }

    /// The gate's source is host state only: no environment variable a forge
    /// could carry picks the repo, and the mirror is reached by podman exec.
    #[test]
    fn the_merge_gate_source_is_host_side_only() {
        let src = include_str!("licence_consent.rs");
        let var = concat!("TILLANDSIAS_LICENCE_", "ACK_REPO");
        assert!(!src.contains(var), "{var} is read again");
        assert_eq!(
            mirror_git_argv("demon_attack", &["symbolic-ref", "--short", "HEAD"]),
            [
                "exec",
                "tillandsias-git-demon_attack",
                "git",
                "-C",
                "/srv/git/demon_attack",
                "symbolic-ref",
                "--short",
                "HEAD"
            ]
        );
    }

    /// 2094-h3rq: demon_attack's licences are registered, pinned, classified
    /// from their text, and admissible with an acknowledgement (neither is
    /// research-only: Fish grants non-commercial use, Higgs is a community
    /// licence with a user threshold).
    #[test]
    fn fish_s2_pro_and_higgs_v2_are_registered_and_classified() {
        let rows = parse_restricted(restricted_register_tsv()).unwrap();
        let higgs = &["higgs-audio-v2", "higgs-audio-v2-tokenizer"][..];
        for (id, hash, names) in [
            (
                "fish-audio-research-license-2026-03-07",
                "aa7d9206e9d710590987a3636934f643529c00cd490323594e6206aaa0c32d80",
                &["fish-s2-pro", "fish-s2-pro-codec"][..],
            ),
            (
                "boson-higgs-audio-2-community",
                "8b2e018eeb3967a4636ccc57528440b33c14dd6e02ad67571fc7759489dde9a0",
                higgs,
            ),
            (
                "meta-llama-3-community",
                "4fa551d4f938f68b8c1e6afa9d28befb70e3f33f75d0753248d530364aeea40f",
                higgs,
            ),
            (
                "meta-llama-3-acceptable-use-policy",
                "716a6b46e9bc75220c7b78f27382f7d0b8ca4c95818661a0936c081708f87f7c",
                higgs,
            ),
        ] {
            assert!(forbidden_outright(id).is_none(), "{id}");
            let table: Vec<Obligation> = obligations_for(id);
            assert!(
                table.iter().all(|o| !o.clause.is_empty()),
                "{id}: every clause is quoted"
            );
            assert!(
                !table.iter().any(|o| matches!(&o.class, ObligationClass::Review { clause } if clause.contains("not in the obligation table"))),
                "{id} is not in the obligation table"
            );
            let classes: Vec<ObligationClass> = table.into_iter().map(|o| o.class).collect();
            for n in names {
                let mine: Vec<&RestrictedRow> = rows
                    .iter()
                    .filter(|r| r.name == *n && r.spdx == id)
                    .collect();
                assert!(!mine.is_empty(), "{n} not registered under {id}");
                for r in mine {
                    assert_eq!(r.licence_sha256, hash, "{n} {id}");
                    assert_eq!(r.gated, "false");
                    assert_eq!(
                        ObligationClass::render_list(&r.obligations),
                        ObligationClass::render_list(&classes),
                        "{n} {id}: register cell and obligation table disagree"
                    );
                }
            }
        }
        // Each Higgs file carries exactly the three licences.
        for n in higgs {
            let mut ids: Vec<&str> = rows
                .iter()
                .filter(|r| r.name == *n)
                .map(|r| r.spdx.as_str())
                .collect();
            ids.sort();
            assert_eq!(
                ids,
                [
                    "boson-higgs-audio-2-community",
                    "meta-llama-3-acceptable-use-policy",
                    "meta-llama-3-community"
                ],
                "{n}"
            );
        }
    }

    /// A file under three licences is admitted only when all three records
    /// are there: Boson alone, or Boson + Llama, admits nothing.
    #[test]
    fn a_higgs_file_needs_all_three_acknowledgements() {
        let dir = disk_scratch("higgs3");
        let (key, signers) = enrol(&dir, "operator");
        let verifier = Verifier::new(&signers);
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let rows = parse_restricted(restricted_register_tsv()).unwrap();
        let r = rows.iter().find(|r| r.name == "higgs-audio-v2").unwrap();
        let art = RestrictedArtefact {
            licence: "boson-higgs-audio-2-community".into(),
            repo: r.repo.clone(),
            revision: r.revision.clone(),
            file: r.file.clone(),
            sha256: r.sha256.clone(),
        };
        let mut want = Vec::new();
        for (id, hash) in [
            (
                "boson-higgs-audio-2-community",
                "8b2e018eeb3967a4636ccc57528440b33c14dd6e02ad67571fc7759489dde9a0",
            ),
            (
                "meta-llama-3-community",
                "4fa551d4f938f68b8c1e6afa9d28befb70e3f33f75d0753248d530364aeea40f",
            ),
            (
                "meta-llama-3-acceptable-use-policy",
                "716a6b46e9bc75220c7b78f27382f7d0b8ca4c95818661a0936c081708f87f7c",
            ),
        ] {
            let err = admits_restricted_in(
                restricted_register_tsv(),
                "demon_attack",
                std::slice::from_ref(&art),
                &acks,
                &verifier,
            )
            .unwrap_err();
            assert!(err.contains(id), "{id} should be the one missing: {err}");
            let mut a = nc_ack("project:demon_attack");
            a.licence = id.into();
            a.licence_sha256 = hash.into();
            a.covers = vec![r.repo.clone()];
            let a = sign(&dir, &key, a);
            want.push(a.slug());
            fs::write(acks.join(a.slug() + ".yaml"), a.to_yaml()).unwrap();
        }
        let ids = admits_restricted_in(
            restricted_register_tsv(),
            "demon_attack",
            &[art],
            &acks,
            &verifier,
        )
        .unwrap();
        assert_eq!(ids, vec![want.join("+")]);
    }

    /// The six records the operator merged in demon_attack (PRs #6, #7, #9,
    /// #10, #11), their `licence` and `covers` exactly as merged: the Rust
    /// slug names each file exactly as it is on demon_attack's main.
    #[test]
    fn slug_names_demon_attacks_merged_records_exactly() {
        for (licence, covers, file) in [
            (
                "creativeml-openrail-plus-plus-m-sdxl",
                "stabilityai/stable-diffusion-xl-base-1.0",
                "creativeml-openrail-plus-plus-m-sdxl--stabilityai-stable-diffusion-xl-base-1-0.yaml",
            ),
            (
                "creativeml-openrail-plus-plus-m-sdxl-lightning",
                "ByteDance/SDXL-Lightning",
                "creativeml-openrail-plus-plus-m-sdxl-lightning--bytedance-sdxl-lightning.yaml",
            ),
            (
                "creativeml-openrail-m",
                "LayerDiffusion/layerdiffusion-v1",
                "creativeml-openrail-m--layerdiffusion-layerdiffusion-v1.yaml",
            ),
            (
                "creativeml-openrail-m",
                "nerijs/pixel-art-xl",
                "creativeml-openrail-m--nerijs-pixel-art-xl.yaml",
            ),
            (
                "meta-llama-3-community",
                "bosonai/higgs-tts-2-3b-base",
                "meta-llama-3-community--bosonai-higgs-tts-2-3b-base.yaml",
            ),
            (
                "meta-llama-3-acceptable-use-policy",
                "bosonai/higgs-tts-2-3b-base",
                "meta-llama-3-acceptable-use-policy--bosonai-higgs-tts-2-3b-base.yaml",
            ),
        ] {
            let mut a = nc_ack("project:demon_attack");
            a.licence = licence.into();
            a.covers = vec![covers.into()];
            assert_eq!(format!("{}.yaml", a.slug()), file, "{licence} {covers}");
        }
    }

    /// demon_attack #4/#6/#7 (coordinator, 2026-11-17): Higgs v2 needs three
    /// licence texts on ONE repo, and records named after the artefact alone
    /// wrote the same file, so the PRs conflicted and a web-UI resolution
    /// would overwrite a record. The file name carries the licence id.
    #[test]
    fn two_licences_on_one_repo_get_two_record_files() {
        let repo = "bosonai/higgs-tts-2-3b-base";
        let mut a = nc_ack("project:demo");
        a.covers = vec![repo.into()];
        a.licence = "boson-higgs-audio-2-community".into();
        let mut b = a.clone();
        b.licence = "meta-llama-3-community".into();
        assert_ne!(a.slug(), b.slug(), "two licences, one file");
        assert_eq!(
            a.slug(),
            "boson-higgs-audio-2-community--bosonai-higgs-tts-2-3b-base"
        );
        // The multi-cover form carries the licence id too.
        let mut m = a.clone();
        m.covers.push("bosonai/higgs-audio-v2-tokenizer".into());
        let mut n = m.clone();
        n.licence = "meta-llama-3-community".into();
        assert_ne!(m.slug(), n.slug());
        assert!(m.slug().starts_with("boson-higgs-audio-2-community--"));
        // And the PRs' record paths differ.
        use sha2::Digest as _;
        let path_of = |ack: &Acknowledgement| {
            let mut ack = ack.clone();
            ack.licence_sha256 = format!("{:x}", sha2::Sha256::digest(b"T"));
            licence_pr(&ack, repo, b"T", "u", &[], &[], &[])
                .unwrap()
                .files[0]
                .0
                .clone()
        };
        assert_ne!(path_of(&a), path_of(&b));
    }

    /// The merge evidence keys on the FILE the default branch holds, not on
    /// [`Acknowledgement::slug`]: records merged under the old artefact-only
    /// name (demon_attack #4, #5) still admit after the rename.
    #[test]
    fn an_old_name_record_merged_before_the_rename_still_admits() {
        let dir = disk_scratch("merge-oldname");
        let repo = dir.join("project");
        fs::create_dir_all(&repo).unwrap();
        git(&repo, OWNER, &["init", "-q"]);
        git(
            &repo,
            OWNER,
            &["commit", "-q", "--allow-empty", "-m", "base"],
        );
        git(
            &repo,
            OWNER,
            &["update-ref", "refs/remotes/origin/main", "HEAD"],
        );
        git(
            &repo,
            OWNER,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );
        let ack = nc_ack("project:demo");
        let old = "fixture-nc-weights";
        assert_ne!(ack.slug(), old, "the premise: the name scheme changed");
        git(
            &repo,
            OWNER,
            &["checkout", "-qb", "licences/cc-by-nc-sa-4.0"],
        );
        fs::create_dir_all(repo.join(ACK_REPO_DIR)).unwrap();
        let rel = format!("{ACK_REPO_DIR}/{old}.yaml");
        fs::write(repo.join(&rel), ack.to_yaml()).unwrap();
        git(&repo, OWNER, &["add", &rel]);
        git(&repo, OWNER, &["commit", "-qm", "licence"]);
        merge_into_main(
            &repo,
            "licences/cc-by-nc-sa-4.0",
            "Merge pull request #4 from o/licences/cc-by-nc-sa-4.0",
            WEB_FLOW,
            true,
        );
        let ok = register_admits_with_consent_in(
            crate::imagegen_models::register_tsv(),
            RESTRICTED,
            &nc_row(),
            &dir.join("none"),
            "project:demo",
            &Verifier::merged(MergeGate::for_repo(&repo).unwrap()),
        )
        .unwrap();
        assert_eq!(ok.acknowledgement_slug.as_deref(), Some(old));
        assert_eq!(ok.merge.unwrap().pr, 4);
    }

    /// demon_attack #13-#15 (2026-11-17): the Higgs model and tokenizer share
    /// three licences, and a head named after the licence alone collided with
    /// the model PRs' branches. The head is `licences/<record file stem>`.
    #[test]
    fn two_artefacts_under_one_licence_get_two_head_branches() {
        use sha2::Digest as _;
        let text = b"T";
        let pr_for = |repo: &str| {
            let mut a = nc_ack("project:demon_attack");
            a.licence = "meta-llama-3-community".into();
            a.licence_sha256 = format!("{:x}", sha2::Sha256::digest(text));
            a.covers = vec![repo.into()];
            licence_pr(&a, repo, text, "u", &[], &[], &[]).unwrap()
        };
        let model = pr_for("bosonai/higgs-tts-2-3b-base");
        let tok = pr_for("bosonai/higgs-audio-v2-tokenizer");
        assert_ne!(
            model.head, tok.head,
            "one licence, two artefacts, one branch"
        );
        assert_eq!(
            tok.head,
            "licences/meta-llama-3-community--bosonai-higgs-audio-v2-tokenizer"
        );
        // The head names the record file, and keeps the licences/ prefix the
        // merge gate requires of a merge commit's head.
        let stem = tok.files[0]
            .0
            .trim_start_matches(&format!("{ACK_REPO_DIR}/"))
            .trim_end_matches(".yaml")
            .to_string();
        assert_eq!(tok.head, format!("{LICENCE_HEAD_PREFIX}{stem}"));
        assert_eq!(
            pr_from_subject(
                &format!("Merge pull request #13 from 8007342/{}", tok.head),
                2
            ),
            Some(13)
        );
    }

    #[test]
    fn a_merge_commit_from_a_non_licences_head_is_not_a_licence_approval() {
        assert_eq!(
            pr_from_subject("Merge pull request #7 from o/licences/llama3", 2),
            Some(7)
        );
        assert_eq!(
            pr_from_subject("Merge pull request #7 from o/work/x", 2),
            None
        );
        assert_eq!(pr_from_subject("licence: fish (#12)", 1), Some(12));
        assert_eq!(pr_from_subject("licence: fish", 1), None);
    }

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
        let obligations = obligations_for("corridor-key-licence-2.0");
        assert_eq!(obligations, obligations_for("corridor-key-licence-v2"));
        assert!(obligations.iter().any(|o| matches!(
            &o.class,
            ObligationClass::Attribution { text } if text == "CorridorKey"
        )));
        let spec = obligations_spec(
            "nikopueringer/CorridorKey2.0@cf44a8db3f024bb49fd59daa408848ccf05f7477/weights/corridorkey_v2.safetensors",
            "corridor-key-licence-2.0",
            &obligations,
        );
        assert!(
            spec.contains("This project depends on nikopueringer/CorridorKey2.0"),
            "{spec}"
        );
        assert!(spec.contains("and must now adhere to"), "{spec}");
        assert!(spec.contains("### Requirement: Attribution"), "{spec}");
        assert!(spec.contains("\"CorridorKey\""), "{spec}");
        // Valid OpenSpec: every requirement has a scenario, and the clause is quoted verbatim.
        let reqs = spec.matches("### Requirement:").count();
        let scenarios = spec.matches("#### Scenario:").count();
        assert!(
            reqs >= 4 && scenarios >= reqs,
            "reqs={reqs} scenarios={scenarios}\n{spec}"
        );
        assert!(
            spec.contains("include the name \"CorridorKey\" in any attribution notice"),
            "{spec}"
        );
        assert!(spec.contains("### Requirement: Share-alike"), "{spec}");
        assert!(
            spec.contains("### Requirement: Seat or revenue threshold"),
            "{spec}"
        );
        assert!(spec.contains("US $20,000,000"), "{spec}");
        assert!(
            spec.contains("### Requirement: No redistribution"),
            "{spec}"
        );
    }

    /// Every OpenRAIL id passes its Attachment A use restrictions downstream.
    #[test]
    fn openrail_yields_use_restriction_passdown() {
        for id in [
            "openrail",
            "openrail-m",
            "creativeml-openrail-m",
            "openrail++",
        ] {
            let obligations = obligations_for(id);
            assert!(
                obligations
                    .iter()
                    .any(|o| matches!(o.class, ObligationClass::UseRestrictionPassdown)),
                "{id}: {obligations:?}"
            );
            let spec = obligations_spec("fixture/openrail-model", id, &obligations);
            assert!(
                spec.contains("### Requirement: Use-restriction passdown"),
                "{spec}"
            );
            assert!(spec.contains("Attachment A"), "{spec}");
        }
    }

    /// GPL-3.0 plugin code carries a source-availability obligation.
    #[test]
    fn gpl_3_0_yields_source_availability() {
        let obligations = obligations_for("gpl-3.0");
        assert!(
            obligations
                .iter()
                .any(|o| matches!(o.class, ObligationClass::SourceAvailability))
        );
        let spec = obligations_spec("fixture/some-node", "gpl-3.0", &obligations);
        assert!(
            spec.contains("### Requirement: Source availability"),
            "{spec}"
        );
        assert!(spec.contains("Corresponding Source"), "{spec}");
    }

    /// An unknown clause (licence) becomes review, never silence.
    #[test]
    fn an_unknown_licence_becomes_review() {
        let obligations = obligations_for("some-licence-nobody-read");
        assert_eq!(obligations.len(), 1);
        assert!(matches!(
            obligations[0].class,
            ObligationClass::Review { .. }
        ));
        assert_eq!(
            ObligationClass::parse("attribution{CorridorKey}").unwrap(),
            ObligationClass::Attribution {
                text: "CorridorKey".into()
            }
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
        assert!(
            seed.covers
                .iter()
                .any(|c| c == "nikopueringer/CorridorKey2.0")
        );
        let signed = sign(&dir, &key, seed);
        fs::write(acks.join(signed.slug() + ".yaml"), signed.to_yaml()).unwrap();

        let restricted = restricted_register_tsv();
        let rows = parse_restricted(restricted).unwrap();
        let ck = rows
            .iter()
            .find(|r| {
                r.repo == "nikopueringer/CorridorKey2.0"
                    && r.file.ends_with("corridorkey_v2.safetensors")
            })
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
        let ok =
            register_admits_with_consent(&permissive, &dir, "project:demo", &verifier).unwrap();
        assert!(ok.acknowledged_by.is_none());
        let ck = parse_restricted(restricted_register_tsv())
            .unwrap()
            .into_iter()
            .find(|r| r.file.ends_with("corridorkey_v2.safetensors"))
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
        let err =
            register_admits_with_consent(&row, &dir, "operator-projects", &verifier).unwrap_err();
        assert!(
            err.starts_with("licence_acknowledgement_required:"),
            "{err}"
        );
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
            assert!(
                !r.obligations.is_empty(),
                "{}: no obligation classes",
                r.name
            );
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
        // The yaml record round-trips, and the committed seeds are the four
        // records of acknowledgement #1, unsigned.
        let seeds = [
            include_str!(
                "../../../licences/acknowledgements/corridor-key-licence-2-0--nikopueringer-corridorkey2-0.yaml"
            ),
            include_str!(
                "../../../licences/acknowledgements/nvidia-open-model-license--nvidia-c-radiov4-so400m.yaml"
            ),
            include_str!(
                "../../../licences/acknowledgements/mit--ruicheng-moge-2-vitb-normal.yaml"
            ),
            include_str!(
                "../../../licences/acknowledgements/cc-by-4-0--google-deepmind-representations4d.yaml"
            ),
        ];
        let acks = operator_standing_acknowledgements();
        assert_eq!(acks.len(), seeds.len());
        for (ack, seed) in acks.iter().zip(seeds) {
            let back = Acknowledgement::from_yaml(&ack.to_yaml()).unwrap();
            assert_eq!(&back, ack);
            let seed = Acknowledgement::from_yaml(seed).unwrap();
            assert_eq!(&seed, ack, "committed seed differs from the code's record");
            assert!(
                seed.signature.is_empty(),
                "the seed is signed by the operator, not by a build"
            );
            assert_eq!(
                seed.slug(),
                format!("{}--{}", slugify(&ack.licence), slugify(&ack.covers[0]))
            );
        }
        // Every repo in the register is covered by one seed record, except
        // Demucs: operator ruling 2026-11-09, acknowledged per project with
        // NO standing grant (2068-eeti), so no seed may cover it.
        for r in &rows {
            if PER_PROJECT_ONLY.contains(&r.spdx.as_str()) {
                assert!(
                    !acks.iter().any(|a| a.covers.contains(&r.repo)),
                    "{}: a standing seed covers {}; Demucs has no standing grant",
                    r.name,
                    r.repo
                );
                continue;
            }
            assert!(
                acks.iter()
                    .any(|a| a.covers.contains(&r.repo) && a.licence == r.spdx),
                "{}: no seed record covers {} under {}",
                r.name,
                r.repo,
                r.spdx
            );
        }
    }

    /// 2068-eeti, operator ruling 2026-11-11: Demucs is acknowledged per
    /// project with a dated expiry. The committed record is project-scoped and
    /// dated; a standing or operator-projects Demucs record is refused.
    #[test]
    fn demucs_records_are_per_project_and_dated_never_standing() {
        let committed = Acknowledgement::from_yaml(include_str!(
            "../../../licences/acknowledgements/adefossez-htdemucs.yaml"
        ))
        .unwrap();
        assert_eq!(committed.licence, "demucs-weights-unstated");
        assert_eq!(demucs_grant_refusal(&committed), None);
        assert!(!committed.signature.is_empty(), "the record is signed");

        let standing = Acknowledgement {
            expiry: "standing".into(),
            ..committed.clone()
        };
        assert!(demucs_grant_refusal(&standing).is_some());
        let operator_wide = Acknowledgement {
            scope: "operator-projects".into(),
            ..committed.clone()
        };
        assert!(demucs_grant_refusal(&operator_wide).is_some());
        // Not Demucs: the rule does not apply.
        let other = Acknowledgement {
            licence: "mit".into(),
            ..standing
        };
        assert_eq!(demucs_grant_refusal(&other), None);
    }

    /// The one-call gate studio_key.rs uses (1956-ucix): with the four signed
    /// standing records in the project's record dir, every artefact of the
    /// CorridorKey weight set is admitted for an operator project, in order,
    /// one acknowledgement id each; a project with no record is refused with
    /// consent_required naming the first artefact. The fixture register is
    /// the shipped one with the NVIDIA licence hash pinned, since the shipped
    /// row is pending; against the shipped register the C-RADIO rows are
    /// refused as licence_text_unpinned, which is the honest state.
    #[test]
    fn admits_restricted_admits_the_corridorkey_set_for_operator_projects() {
        let dir = disk_scratch("admits");
        let (key, signers) = enrol(&dir, "operator");
        let verifier = Verifier::new(&signers);
        let acks = dir.join("acks");
        fs::create_dir_all(&acks).unwrap();
        let nvidia_hash = "9".repeat(64);
        let shipped = restricted_register_tsv();
        let pinned: String = shipped
            .lines()
            .map(|l| {
                let l = match l.split_once("\tpending:") {
                    Some((head, _)) => format!("{head}\t{nvidia_hash}"),
                    None => l.to_string(),
                };
                l + "\n"
            })
            .collect();
        for mut ack in operator_standing_acknowledgements() {
            if ack.licence_sha256.starts_with("pending:") {
                ack.licence_sha256 = nvidia_hash.clone();
            }
            let signed = sign(&dir, &key, ack);
            fs::write(acks.join(signed.slug() + ".yaml"), signed.to_yaml()).unwrap();
        }
        let rows = parse_restricted(shipped).unwrap();
        let to_artefact = |r: &RestrictedRow| RestrictedArtefact {
            licence: r.spdx.clone(),
            repo: r.repo.clone(),
            revision: r.revision.clone(),
            file: r.file.clone(),
            sha256: r.sha256.clone(),
        };
        // The CorridorKey set the standing records cover; Demucs (2068-eeti)
        // has no standing grant, so those records must NOT admit it.
        let (demucs, ck): (Vec<&RestrictedRow>, Vec<&RestrictedRow>) = rows
            .iter()
            .partition(|r| PER_PROJECT_ONLY.contains(&r.spdx.as_str()));
        let artefacts: Vec<RestrictedArtefact> = ck.into_iter().map(to_artefact).collect();
        assert!(artefacts.len() >= 30, "{}", artefacts.len());
        assert_eq!(
            demucs.len(),
            11,
            "htdemucs, htdemucs_6s, 3 Fish S2-Pro rows, 2 Higgs v2 files x 3 licences"
        );
        let demucs: Vec<RestrictedArtefact> = demucs.into_iter().map(to_artefact).collect();
        let err =
            admits_restricted_in(&pinned, "demon_attack", &demucs, &acks, &verifier).unwrap_err();
        assert!(err.contains("licence_acknowledgement_required"), "{err}");

        let ids =
            admits_restricted_in(&pinned, "demon_attack", &artefacts, &acks, &verifier).unwrap();
        assert_eq!(ids.len(), artefacts.len());
        assert_eq!(
            ids[0],
            "corridor-key-licence-2-0--nikopueringer-corridorkey2-0"
        );
        assert!(
            ids.iter()
                .any(|i| i == "nvidia-open-model-license--nvidia-c-radiov4-so400m")
        );
        assert!(ids.iter().any(|i| i == "mit--ruicheng-moge-2-vitb-normal"));
        assert!(
            ids.iter()
                .any(|i| i == "cc-by-4-0--google-deepmind-representations4d")
        );

        // No record: refused, naming the first artefact.
        let err = admits_restricted_in(
            &pinned,
            "someone-elses-game",
            &artefacts,
            &dir.join("empty"),
            &verifier,
        )
        .unwrap_err();
        assert!(
            err.starts_with("consent_required: someone-elses-game:"),
            "{err}"
        );
        assert!(err.contains("nikopueringer/CorridorKey2.0"), "{err}");

        // A project-scoped record admits only its own project.
        let mut mine = operator_standing_acknowledgement();
        mine.scope = "project:my-game".into();
        mine.grantor = "operator".into();
        let mine = sign(&dir, &key, mine);
        let mine_dir = dir.join("mine");
        fs::create_dir_all(&mine_dir).unwrap();
        fs::write(mine_dir.join(mine.slug() + ".yaml"), mine.to_yaml()).unwrap();
        let ck: Vec<RestrictedArtefact> = artefacts
            .iter()
            .filter(|a| a.repo.contains("CorridorKey"))
            .cloned()
            .collect();
        assert_eq!(
            admits_restricted_in(&pinned, "my-game", &ck, &mine_dir, &verifier)
                .unwrap()
                .len(),
            2
        );
        let err =
            admits_restricted_in(&pinned, "other-game", &ck, &mine_dir, &verifier).unwrap_err();
        assert!(err.contains("scope project:my-game"), "{err}");

        // The shipped register: C-RADIO stays unpinned, so the set is refused there.
        let err = admits_restricted_in(shipped, "demon_attack", &artefacts, &acks, &verifier)
            .unwrap_err();
        assert!(err.contains("licence_text_unpinned"), "{err}");
        assert!(err.contains("nvidia/C-RADIOv4-SO400M"), "{err}");

        // Empty input is a refusal, not an admission.
        assert!(admits_restricted_in(&pinned, "demon_attack", &[], &acks, &verifier).is_err());
        // The production entry point reads the record dir from the environment.
        // SAFETY: tests in this module run in one process; the variable only
        // names a scratch directory and is read back immediately.
        unsafe { std::env::set_var("TILLANDSIAS_LICENCE_ACK_DIR", &acks) };
        assert_eq!(project_acknowledgement_dir("demon_attack"), acks);
        let _ = admits_restricted("demon_attack", &ck);
    }
}
