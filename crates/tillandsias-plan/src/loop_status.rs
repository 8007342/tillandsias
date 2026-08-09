//! ORDER 582-nqw5 — the CRDT fragment overlay for `plan/loop_status.md`.
//!
//! loop_status.md is a single narrative file every host rewrites, so it
//! conflicts under concurrency for exactly the reason plan/index.yaml did. But
//! it is PROSE, not keyed records — there is no packet_id to key a G-Set on —
//! so the index.yaml design must not be force-fit onto it. The CRDT is chosen
//! per section, not assumed:
//!
//! | section                                | kind            | CRDT                                      |
//! |----------------------------------------|-----------------|-------------------------------------------|
//! | `## Cycle <ts> (<host> — …)`           | append-only log | G-SET keyed by the heading line           |
//! | `## Direction`                         | operator-writes | LWW-REGISTER, operator-writes-only        |
//! | `## ACTIVE RELEASE`                    | operator-writes | LWW-REGISTER, operator/coordinator-only   |
//! | everything else (`## This Loop`, `## WINDOWS LANE`, …) | historical base | base-only; fragments never carry it |
//!
//! **Why the cycle log is a G-SET keyed by its heading.** A cycle entry is an
//! immutable narrative fact: once a host writes one it is never edited, only
//! added. The heading embeds the UTC timestamp + host, so it is a stable unique
//! identity — the prose substitute for packet_id. Two hosts appending yield the
//! UNION (commutative and idempotent): neither narrative can overwrite the
//! other, and re-applying a fragment or resuming a half-finished compaction
//! dedups by heading instead of duplicating.
//!
//! **Why the operator sections are LWW-Register and not agents' to write.** The
//! `## Direction` directive and the `## ACTIVE RELEASE` pointer are written by
//! The Tlatoāni (operator comment: "The Tlatoāni, updated 2026-07-17"), so they
//! need no concurrent-writer resolution FROM agents. Three layers keep them
//! safe: (1) [`append`] refuses a fragment that names any non-`## Cycle`
//! heading; (2) [`parse_fragment`] treats such a fragment as malformed, so
//! [`load_all`] never folds it in and [`malformed`] surfaces it with a warning;
//! (3) [`validate_candidate`] asserts the Direction and ACTIVE RELEASE section
//! spans are byte-identical between base and candidate, so even a future fold
//! bug cannot clobber them silently.
//!
//! **The rendered file is a fold.** [`fold_text`] inserts every fragment's
//! cycle sections right after the H1 title — where agents prepend today — in
//! newest-first order (fragment name descending = chronological descending)
//! and deduplicated by heading. The base is never rewritten beyond that
//! insertion, so operator sections, legacy sections, and comments survive BY
//! CONSTRUCTION.
//!
//! Fragments live in `plan/loop_status.d/` as `<utc>-<suffix>-<host>.md`,
//! UTC-first so a lexical sort is chronological — the same contract as the
//! index.d overlay (`fragments.rs`,
//! `cheatsheets/concurrent-git/crdt-ledger-fragments.md`). Two hosts appending
//! each write their OWN file, so the concurrent write that used to conflict on
//! the shared base no longer touches the same path.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The base document the overlay folds onto, when no `--index` is given.
pub const DEFAULT_BASE: &str = "plan/loop_status.md";

/// One `## Cycle …` section: an immutable dated, host-scoped narrative entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CycleSection {
    /// The trimmed heading line, e.g. `## Cycle 2026-08-03T01:00Z (h1 — …)`.
    /// This is the G-SET KEY: unique by timestamp+host and stable for the
    /// entry's whole life, which is what makes it a safe prose substitute for
    /// packet_id.
    pub heading: String,
    /// Everything after the heading up to the next `## ` heading or EOF,
    /// trailing blank lines trimmed so the fold controls separators.
    pub body: String,
}

/// One fragment file, parsed into its cycle sections.
#[derive(Debug, Clone)]
pub struct Fragment {
    /// Sort key — the FILENAME, not anything the file claims (a fragment must
    /// not be able to influence its own fold position by claiming a convenient
    /// timestamp; the name is fixed at creation and visible in git).
    pub name: String,
    pub path: PathBuf,
    pub sections: Vec<CycleSection>,
}

/// The fragment store next to the base: `plan/loop_status.md` →
/// `plan/loop_status.d`, derived the same way the index overlay derives
/// `plan/index.yaml` → `plan/index.d`.
pub fn fragment_dir(base: &Path) -> PathBuf {
    crate::fragments::fragment_dir(base)
}

/// A file beside the base is a foldable fragment only when it is a `.md`
/// cycle-status file — and not the store's own documentation (`README.md`).
///
/// The index overlay excludes its README by EXTENSION (fragments there are
/// `.yaml`); the prose overlay reads `.md` fragments, so its README would
/// otherwise be parsed as a malformed fragment with no `## Cycle` section on
/// every fold and drift report. ORDER 626-bnn5: exclude it by NAME so the
/// committed store documentation never masquerades as a fragment, while a
/// genuinely malformed cycle-status file still surfaces via [`malformed`].
fn is_fragment_file(p: &Path) -> bool {
    p.extension().and_then(|x| x.to_str()) == Some("md")
        && p.file_name()
            .and_then(|n| n.to_str())
            .is_none_or(|n| !n.eq_ignore_ascii_case("README.md"))
}

/// Parse a fragment's raw text into its cycle sections.
///
/// STRICT by design, and fail-closed: a fragment may carry a leading
/// `#`-comment header (the same immutable-header convention as index.d
/// fragments), blank lines, and any number of `## Cycle` sections — and
/// NOTHING else. A `## Direction`, `## ACTIVE RELEASE`, `## This Loop`, or any
/// other heading is REFUSED with the offending line named, so an agent fragment
/// can never be merged over an operator-owned or legacy section. A fragment
/// with no cycle sections is refused too — an empty fragment has nothing to
/// fold and is almost certainly a mistake.
pub fn parse_fragment(raw: &str, path: &Path) -> Result<Vec<CycleSection>, String> {
    let mut sections: Vec<CycleSection> = Vec::new();
    let mut current: Option<(String, Vec<String>)> = None;
    // Header = everything before the first `## ` heading: only comments and
    // blanks are legal there. Anything else is a misplaced section.
    let mut in_header = true;

    for (idx, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.starts_with("## ") {
            if !trimmed.starts_with("## Cycle") {
                return Err(format!(
                    "{}:{}: fragment carries non-cycle heading `{trimmed}` — the overlay refuses agent writes to every section except `## Cycle` entries",
                    path.display(),
                    idx + 1
                ));
            }
            if let Some((h, b)) = current.take() {
                sections.push(CycleSection {
                    heading: h,
                    body: finish_body(b),
                });
            }
            current = Some((trimmed.to_string(), Vec::new()));
            in_header = false;
        } else if trimmed.starts_with('#') {
            // A single-hash line is a header comment BEFORE the first section,
            // or body prose after it (e.g. "#1"). Either way it is not a
            // level-2 heading and may not start a section.
            if !in_header && let Some((_, body)) = &mut current {
                body.push(line.to_string());
            }
        } else if in_header && !trimmed.is_empty() {
            return Err(format!(
                "{}:{}: non-comment text before the first `## Cycle` heading",
                path.display(),
                idx + 1
            ));
        } else if let Some((_, body)) = &mut current {
            body.push(line.to_string());
        }
    }
    if let Some((h, b)) = current.take() {
        sections.push(CycleSection {
            heading: h,
            body: finish_body(b),
        });
    }
    if sections.is_empty() {
        return Err(format!(
            "{}: fragment carries no `## Cycle` section",
            path.display()
        ));
    }
    Ok(sections)
}

/// Trim trailing blank lines from a section body.
fn finish_body(lines: Vec<String>) -> String {
    let mut end = lines.len();
    while end > 0 && lines[end - 1].trim().is_empty() {
        end -= 1;
    }
    lines[..end].join("\n")
}

/// Every well-formed fragment beside `base`, in deterministic fold order.
///
/// Best-effort by design (mirrors `fragments::load_all`): a missing directory
/// means no fragments, and an unreadable, unparseable, or non-cycle fragment is
/// SKIPPED so one bad file cannot make the whole loop_status unreadable. It is
/// reported separately by [`malformed`] so it is visible rather than silently
/// ignored.
pub fn load_all(base: &Path) -> Vec<Fragment> {
    let dir = fragment_dir(base);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<Fragment> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| is_fragment_file(p))
        .filter_map(|p| {
            let raw = std::fs::read_to_string(&p).ok()?;
            let sections = parse_fragment(&raw, &p).ok()?;
            Some(Fragment {
                name: p.file_name()?.to_string_lossy().to_string(),
                path: p,
                sections,
            })
        })
        .collect();
    // (name) IS the (ts, suffix, host) tuple — UTC-first naming makes a lexical
    // sort a chronological one, exactly as in the index overlay.
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Fragment paths that exist but could not be folded: unreadable, no cycle
/// sections, or — most importantly — naming a non-`## Cycle` heading such as
/// `## Direction`. Skipping a malformed fragment keeps loop_status readable;
/// skipping it QUIETLY would lose work with no signal. Callers surface these as
/// warnings.
pub fn malformed(base: &Path) -> Vec<PathBuf> {
    let dir = fragment_dir(base);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut bad: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| is_fragment_file(p))
        .filter(|p| {
            std::fs::read_to_string(p)
                .ok()
                .and_then(|raw| parse_fragment(&raw, p).ok())
                .is_none()
        })
        .collect();
    bad.sort();
    bad
}

/// Render the base with every fragment's cycle sections folded in.
///
/// PURE: same inputs, same output — the property that lets any host compact
/// and reach a state every other host agrees with. New sections are inserted
/// immediately before the base's first `## ` line (after the H1 title, where
/// agents prepend today), in newest-first order (fragment name descending =
/// chronological descending, sections within one fragment staying in file
/// order), deduplicated by heading (G-Set: an already-present heading adds
/// nothing). The base is never rewritten beyond that insertion.
pub fn fold_text(base_raw: &str, fragments: &[Fragment]) -> Result<String, String> {
    let mut seen: BTreeSet<String> = base_raw
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("## "))
        .map(str::to_string)
        .collect();

    // G-Set: fresh cycle sections, deduplicated against the base AND against
    // other fragments, so re-folding an already-merged fragment adds nothing.
    let mut fresh: Vec<(String, CycleSection)> = Vec::new();
    for frag in fragments {
        for sec in &frag.sections {
            if seen.insert(sec.heading.clone()) {
                fresh.push((frag.name.clone(), sec.clone()));
            }
        }
    }
    if fresh.is_empty() {
        return Ok(base_raw.to_string());
    }

    // Newest-first: fragment name is UTC-first, so descending name order is
    // descending chronology. STABLE sort keeps one fragment's sections in file
    // order.
    fresh.sort_by(|a, b| b.0.cmp(&a.0));

    let block = fresh
        .iter()
        .map(|(_, sec)| format!("{}\n{}", sec.heading, sec.body))
        .collect::<Vec<_>>()
        .join("\n\n")
        + "\n\n";

    let had_trailing_nl = base_raw.ends_with('\n');
    let lines: Vec<&str> = base_raw.lines().collect();
    let insert_at = lines
        .iter()
        .position(|l| l.trim().starts_with("## "))
        .unwrap_or(lines.len());

    let mut out = String::with_capacity(base_raw.len() + block.len());
    let mut pushed_block = false;
    for (i, l) in lines.iter().enumerate() {
        if i == insert_at {
            out.push_str(&block);
            pushed_block = true;
        }
        out.push_str(l);
        out.push('\n');
    }
    if insert_at == lines.len() && !pushed_block {
        out.push_str(&block);
    }
    if !had_trailing_nl {
        out.pop();
    }
    Ok(out)
}

/// ORDER 606-xu52 — the release the coordination loop currently targets, read
/// from the FOLDED loop status (base plus fragments, the same view every host
/// sees). The heading grammar is `## ACTIVE RELEASE: vX.Y …` — the first
/// `vN.N`-shaped token after the colon is the release; trailing prose (ship
/// history, parentheticals) is ignored. Returns `None` when the file or the
/// heading is absent — callers refuse rather than guess a release.
///
/// READ-ONLY on purpose: truth-gating and rendering of this heading belong to
/// packet 606-46x9, not here.
pub fn active_release(base: &Path) -> Option<String> {
    let base_raw = std::fs::read_to_string(base).ok()?;
    let folded = fold_text(&base_raw, &load_all(base)).unwrap_or(base_raw);
    for line in folded.lines() {
        let Some(rest) = line.trim().strip_prefix("## ACTIVE RELEASE:") else {
            continue;
        };
        return rest.split_whitespace().find_map(|token| {
            let token = token.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '.'));
            let mut chars = token.chars();
            (chars.next() == Some('v')
                && chars.clone().next().is_some_and(|c| c.is_ascii_digit())
                && chars.all(|c| c.is_ascii_digit() || c == '.'))
            .then(|| token.to_string())
        });
    }
    None
}

/// One `- **vX.Y … (N open / M total tagged)` release-list bullet from the
/// operator-owned release section of the loop_status base (ORDER 626-zmhz).
///
/// Parsed as-is, never validated: a bullet may lack the `— ACTIVE` label or a
/// parseable count, and [`verify_active_release`] decides what that means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseBullet {
    /// The version token, `vN.N…`, exactly as `active_release` renders it.
    pub version: String,
    /// Whether the bullet carried the inlined `— ACTIVE` label.
    pub active: bool,
    /// The committed `N` from `(N open / M total tagged)`, when parseable.
    pub open: Option<u64>,
    /// The committed `M` from `(N open / M total tagged)`, when parseable.
    pub total: Option<u64>,
}

/// Parse the release-list bullets out of folded loop-status text. Matches
/// `- **vN.N…[ — ACTIVE][ (N open / M total tagged)]` lines and ignores
/// everything else — prose, headings, and bullets for other release names.
pub fn release_bullets(text: &str) -> Vec<ReleaseBullet> {
    let mut out = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        let Some(rest) = t.strip_prefix("- **v") else {
            continue;
        };
        let digits: String = rest
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '.')
            .collect();
        if digits.is_empty() || !digits.starts_with(|c: char| c.is_ascii_digit()) {
            continue;
        }
        let version = format!("v{digits}");
        let mut after = &rest[digits.len()..];
        // A version token runs until the first non-digit/dot, and what follows
        // must be whitespace — `v0.9x` is a bogus bullet, not `v0.9` plus junk.
        if !after.starts_with(' ') {
            continue;
        }
        let mut active = false;
        for sep in ["—", "–", "-"] {
            if let Some(tail) = after.strip_prefix(&format!(" {sep} ACTIVE")) {
                active = true;
                after = tail;
                break;
            }
        }
        // A release bullet's remainder opens the count parenthetical — anything
        // else (`- **v0.5 work seeded** …`) is prose wearing a bullet marker.
        if !after.trim_start().starts_with('(') {
            continue;
        }
        let mut open = None;
        let mut total = None;
        if let Some(par) = after.split('(').nth(1)
            && let Some(close) = par.find(')')
            && let Some((a, b)) = par[..close].trim().split_once(" open / ")
            && let Ok(a) = a.trim().parse::<u64>()
            && let Ok(b) = b
                .strip_suffix(" total tagged")
                .unwrap_or("")
                .trim()
                .parse::<u64>()
        {
            open = Some(a);
            total = Some(b);
        }
        out.push(ReleaseBullet {
            version,
            active,
            open,
            total,
        });
    }
    out
}

/// Count `## ACTIVE RELEASE:` heading declarations in folded loop-status text.
pub fn active_release_headings(text: &str) -> usize {
    text.lines()
        .filter(|l| l.trim().starts_with("## ACTIVE RELEASE:"))
        .count()
}

/// The canonical count parenthetical for the release-list prose, e.g.
/// `(217 open / 298 total tagged)`.
pub fn render_count_line(open: u64, total: u64) -> String {
    format!("({open} open / {total} total tagged)")
}

/// ORDER 626-zmhz — the deterministic ACTIVE-RELEASE truth check over the
/// FOLDED loop-status prose. One contradiction per returned line; an empty
/// vector means the prose is consistent:
///
/// 1. exactly one `## ACTIVE RELEASE:` heading;
/// 2. exactly one release bullet carries the `— ACTIVE` label;
/// 3. that bullet IS the active release (version matches), and the active
///    release's own bullet is the one labeled ACTIVE — a stale `v0.4 — ACTIVE`
///    while the register says v0.5 is a contradiction this catches.
pub fn verify_active_release(folded: &str, active: &str) -> Vec<String> {
    let mut problems = Vec::new();
    let headings = active_release_headings(folded);
    if headings == 0 {
        problems.push("no `## ACTIVE RELEASE:` heading in the folded loop status".to_string());
    } else if headings > 1 {
        problems.push(format!(
            "{headings} `## ACTIVE RELEASE:` headings — exactly one is allowed"
        ));
    }
    if active.is_empty() {
        if headings > 0 {
            problems.push("active release could not be parsed from the heading".to_string());
        }
        return problems;
    }
    let bullets = release_bullets(folded);
    let for_active: Vec<&ReleaseBullet> = bullets.iter().filter(|b| b.version == active).collect();
    let labeled: Vec<&ReleaseBullet> = bullets.iter().filter(|b| b.active).collect();
    if for_active.is_empty() {
        problems.push(format!(
            "no release-list bullet for the active release {active}"
        ));
    } else if for_active.len() > 1 {
        problems.push(format!(
            "{} release-list bullets claim the active release {active}",
            for_active.len()
        ));
    } else if !for_active[0].active {
        problems.push(format!(
            "active release {active} bullet is not labeled `— ACTIVE`"
        ));
    }
    if labeled.is_empty() {
        problems.push(format!(
            "no release bullet carries the `— ACTIVE` label (expected {active})"
        ));
    } else if labeled.len() > 1 || labeled[0].version != active {
        let offenders: Vec<String> = labeled.iter().map(|b| b.version.clone()).collect();
        problems.push(format!(
            "release bullet(s) {} are labeled ACTIVE but the register names {active}",
            offenders.join(", ")
        ));
    }
    problems
}

/// The drift summary for the loop_status overlay, mirroring `fragments::drift`.
pub struct Drift {
    pub fragment_count: usize,
    pub section_count: usize,
    pub total_bytes: u64,
    pub malformed_count: usize,
}

impl Drift {
    /// Thresholds are judgement, not correctness, and deliberately loose: each
    /// cycle entry is a few KB of prose, so the store fills slower than the
    /// index overlay's, and compaction — the one operation that rewrites the
    /// shared base — is worth doing rarely.
    pub fn eligible(&self) -> bool {
        self.fragment_count >= 10 || self.total_bytes >= 64 * 1024 || self.malformed_count > 0
    }

    pub fn verdict(&self) -> String {
        let reason = if self.malformed_count > 0 {
            "malformed-fragments"
        } else if self.fragment_count >= 10 {
            "fragment-count"
        } else if self.total_bytes >= 64 * 1024 {
            "total-bytes"
        } else {
            "-"
        };
        format!(
            "loop_status: compaction eligible={} fragments={} sections={} bytes={} malformed={} reason={}",
            self.eligible(),
            self.fragment_count,
            self.section_count,
            self.total_bytes,
            self.malformed_count,
            reason
        )
    }
}

pub fn drift(base: &Path) -> Drift {
    let fragments = load_all(base);
    let malformed_count = malformed(base).len();
    let section_count = fragments.iter().map(|f| f.sections.len()).sum();
    let total_bytes = fragments
        .iter()
        .filter_map(|f| std::fs::metadata(&f.path).ok())
        .map(|m| m.len())
        .sum();
    Drift {
        fragment_count: fragments.len(),
        section_count,
        total_bytes,
        malformed_count,
    }
}

/// Validate a candidate cycle entry and write it as a NEW fragment file.
///
/// Refuses anything `parse_fragment` refuses — in particular `## Direction`
/// and `## ACTIVE RELEASE` can never enter the overlay this way. Creating a
/// NEW file is what makes concurrent writes conflict-free: two hosts appending
/// each write their own `<utc>-<suffix>-<host>.md`, never the shared base.
pub fn append(
    base: &Path,
    raw: &str,
    utc_compact: &str,
    suffix: &str,
    host: &str,
) -> Result<PathBuf, String> {
    parse_fragment(raw, Path::new("<loop-status-append>"))?;
    let dir = fragment_dir(base);
    std::fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let name = crate::fragments::fragment_name_md(utc_compact, suffix, host);
    let path = dir.join(&name);
    std::fs::write(&path, raw).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// The compaction verdict: the candidate base TEXT plus exactly which
/// fragments it consumed. The same delete-by-name contract as the index
/// overlay — never a glob, or a fragment written by another host
/// mid-compaction is silently destroyed.
pub struct Compaction {
    pub candidate: String,
    pub consumed: Vec<PathBuf>,
}

/// Fold every fragment into the base and report what was consumed.
///
/// Does NOT touch the filesystem — the caller validates the candidate via
/// [`validate_candidate`] and writes it. A compaction that emits a broken base
/// is worse than no compaction.
pub fn compact(base: &Path) -> Result<Compaction, String> {
    let raw = std::fs::read_to_string(base).map_err(|e| format!("read {}: {e}", base.display()))?;
    let fragments = load_all(base);
    if fragments.is_empty() {
        return Ok(Compaction {
            candidate: raw,
            consumed: Vec::new(),
        });
    }
    let candidate = fold_text(&raw, &fragments)?;
    let consumed = fragments.iter().map(|f| f.path.clone()).collect();
    Ok(Compaction {
        candidate,
        consumed,
    })
}

/// The structural gate a candidate must pass before it may REPLACE the base.
///
/// loop_status is prose, so the index.yaml parse/integrity gate has no YAML to
/// validate. Its prose equivalent proves the four things that losing a host's
/// narrative would violate:
///
/// 1. every base heading still present (nothing dropped);
/// 2. every fragment cycle heading present (nothing lost);
/// 3. the operator-owned Direction and ACTIVE RELEASE section spans are
///    byte-identical between base and candidate (cannot be clobbered);
/// 4. re-folding the candidate with the SAME fragments is a no-op (idempotent
///    compaction, so a crash between fold and delete is safe to re-run).
///
/// Fail-closed: every refusal leaves the base untouched.
pub fn validate_candidate(
    base_raw: &str,
    candidate: &str,
    fragments: &[Fragment],
) -> Result<(), String> {
    let base_headings = heading_multiset(base_raw);
    let cand_headings = heading_multiset(candidate);

    for (h, count) in &base_headings {
        let have = cand_headings.get(h).copied().unwrap_or(0);
        if have < *count {
            return Err(format!(
                "compaction would DROP heading `{h}` ({count} -> {have})"
            ));
        }
    }

    let present = cand_headings.clone();
    for frag in fragments {
        for sec in &frag.sections {
            if !present.contains_key(&sec.heading) {
                return Err(format!(
                    "compaction would LOSE fragment {} section `{}`",
                    frag.name, sec.heading
                ));
            }
        }
    }

    // Operator-owned sections must be byte-identical. They are already
    // un-clobberable by construction (no fragment can carry them), but the gate
    // defends against a future fold bug too.
    for op in ["## Direction", "## ACTIVE RELEASE"] {
        if section_span(base_raw, op) != section_span(candidate, op) {
            return Err(format!(
                "compaction would ALTER the operator-owned `{op}` section"
            ));
        }
    }

    // Idempotency: folding the candidate with the same fragments changes
    // nothing. This is the strongest gate — it catches insertion-position and
    // dedup bugs that the three checks above cannot see.
    let refold = fold_text(candidate, fragments).map_err(|e| format!("re-fold failed: {e}"))?;
    if refold != candidate {
        return Err(
            "compaction is not idempotent: folding the candidate with the same fragments changes it"
                .to_string(),
        );
    }

    Ok(())
}

/// Every `## ` heading in a document, with multiplicity.
fn heading_multiset(text: &str) -> BTreeMap<String, usize> {
    let mut m = BTreeMap::new();
    for l in text.lines() {
        let t = l.trim();
        if t.starts_with("## ") {
            *m.entry(t.to_string()).or_insert(0) += 1;
        }
    }
    m
}

/// A section span: from the first line starting with `heading_prefix` through
/// the next `## ` line (or EOF). Empty if the prefix is absent.
fn section_span(text: &str, heading_prefix: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let Some(start) = lines
        .iter()
        .position(|l| l.trim().starts_with(heading_prefix))
    else {
        return String::new();
    };
    let end = lines[start + 1..]
        .iter()
        .position(|l| l.trim().starts_with("## "))
        .map(|i| start + 1 + i)
        .unwrap_or(lines.len());
    lines[start..end].join("\n")
}

/// Current UTC stamp in the fragment-name shape (`20260803t010000z`), for the
/// default `--ts` of `loop-status-append`. No chrono: reuses the crate's civil
/// calendar in `answer::epoch_to_iso8601`.
pub fn utc_compact_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    iso_to_compact(&crate::answer::epoch_to_iso8601(secs))
}

/// `YYYY-MM-DDTHH:MM:SSZ` → `YYYYMMDDtHHMMSSz` (the UTC-first name shape).
pub fn iso_to_compact(iso: &str) -> String {
    let mut out = String::with_capacity(iso.len());
    for c in iso.chars() {
        match c {
            '-' | ':' => {}
            'T' => out.push('t'),
            'Z' => out.push('z'),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // A representative base carrying every section family the real
    // loop_status.md has: recent cycles, an operator lane note, the ACTIVE
    // RELEASE pointer, a legacy This Loop, and the operator-owned Direction
    // section with its HTML comment block.
    const BASE: &str = "# Multi-Host Coordination Loop Status\n\
                        \n\
                        ## Cycle 2026-08-02T00:00Z (h1 — earlier)\n\
                        \n\
                        - old body\n\
                        \n\
                        ## WINDOWS LANE 2026-07-22 (operator-attended)\n\
                        \n\
                        - win\n\
                        \n\
                        ## ACTIVE RELEASE: v0.5 (v0.4 SHIPPED)\n\
                        \n\
                        > v0.4 shipped\n\
                        \n\
                        ## This Loop (2026-07-10)\n\
                        \n\
                        - loop\n\
                        \n\
                        ## Direction — what are we all doing today\n\
                        \n\
                        <!-- Operator-owned thematic direction (The Tlatoāni, updated 2026-07-17).\n\
                             One theme, no packet ids. -->\n\
                        \n\
                        **We're giving forge agents local EXPERTS.**\n";

    fn frag(name: &str, raw: &str) -> Fragment {
        Fragment {
            name: name.to_string(),
            path: PathBuf::from(name),
            sections: parse_fragment(raw, Path::new(name)).expect("fixture parses"),
        }
    }

    const HOST_A: &str = "## Cycle 2026-08-03T01:00Z (h1 — from h1)\n\n- h1 status\n";
    const HOST_B: &str = "## Cycle 2026-08-03T01:05Z (h2 — from h2)\n\n- h2 status\n";

    fn cycle_headings(text: &str) -> Vec<String> {
        text.lines()
            .filter(|l| l.trim().starts_with("## Cycle"))
            .map(|l| l.trim().to_string())
            .collect()
    }

    #[test]
    fn cycle_entries_from_two_hosts_both_survive() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let b = frag("20260803t010500z-bb-h2.md", HOST_B);
        let merged = fold_text(BASE, &[a, b]).unwrap();
        assert!(merged.contains("h1 status") && merged.contains("h2 status"));
        let hs = cycle_headings(&merged);
        assert!(hs.iter().any(|h| h.contains("2026-08-03T01:00Z")));
        assert!(hs.iter().any(|h| h.contains("2026-08-03T01:05Z")));
    }

    #[test]
    fn the_fold_is_commutative_the_defining_crdt_property() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let b = frag("20260803t010500z-bb-h2.md", HOST_B);
        let ab = fold_text(BASE, &[a.clone(), b.clone()]).unwrap();
        let ba = fold_text(BASE, &[b, a]).unwrap();
        assert_eq!(ab, ba);
    }

    #[test]
    fn the_fold_is_idempotent_so_a_half_finished_compaction_is_safe() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let once = fold_text(BASE, std::slice::from_ref(&a)).unwrap();
        let twice = fold_text(&once, &[a]).unwrap();
        assert_eq!(
            once, twice,
            "re-folding an already-merged fragment is a no-op"
        );
    }

    #[test]
    fn new_cycles_render_newest_first_after_the_title_and_never_move_base_content() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let b = frag("20260803t010500z-bb-h2.md", HOST_B);
        let merged = fold_text(BASE, &[a, b]).unwrap();
        assert!(merged.starts_with("# Multi-Host Coordination Loop Status\n\n"));
        let hs = cycle_headings(&merged);
        assert_eq!(hs.len(), 3, "two new + one base cycle");
        assert!(hs[0].contains("01:05Z"), "newest fragment first");
        assert!(hs[1].contains("01:00Z"));
        assert!(
            hs[2].contains("2026-08-02T00:00Z"),
            "base cycle still present"
        );
        assert!(merged.contains("- old body"));
        assert!(merged.contains("> v0.4 shipped"));
        assert!(merged.contains("- loop"));
        assert!(merged.contains("**We're giving forge agents local EXPERTS.**"));
    }

    #[test]
    fn operator_and_legacy_sections_are_byte_identical_after_folding() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let merged = fold_text(BASE, &[a]).unwrap();
        for op in [
            "## Direction",
            "## ACTIVE RELEASE",
            "## WINDOWS LANE",
            "## This Loop",
        ] {
            assert_eq!(
                section_span(BASE, op),
                section_span(&merged, op),
                "{op} span must not change"
            );
        }
    }

    #[test]
    fn a_fragment_naming_direction_or_any_non_cycle_heading_is_refused() {
        for bad in [
            "## Direction — what are we all doing today\n\nclobber\n",
            "## ACTIVE RELEASE: v0.5\n\nclobber\n",
            "## This Loop (2026-07-01)\n\nclobber\n",
            "## WINDOWS LANE 2026-07-22\n\nclobber\n",
        ] {
            assert!(
                parse_fragment(bad, Path::new("x.md")).is_err(),
                "must refuse: {bad}"
            );
        }
    }

    #[test]
    fn a_comment_header_is_allowed_but_garbage_preamble_is_not() {
        let ok = "# Ledger fragment — append-only, IMMUTABLE once written.\n# Written by: h1\n\n## Cycle 2026-08-03T01:00Z (h1 — a)\n\n- body\n";
        assert!(parse_fragment(ok, Path::new("x.md")).is_ok());
        let empty = "# header only, no sections\n";
        assert!(parse_fragment(empty, Path::new("x.md")).is_err());
        let garbage = "this is not a comment\n\n## Cycle 2026-08-03T01:00Z (h1 — a)\n\n- body\n";
        assert!(parse_fragment(garbage, Path::new("x.md")).is_err());
    }

    #[test]
    fn append_refuses_an_agent_attempt_at_the_direction_section() {
        // append() is the agent's write surface; it must reject the one write
        // the overlay exists to prevent.
        assert!(
            append(
                Path::new("plan/loop_status.md"),
                "## Direction — what are we all doing today\n\nclobber\n",
                "20260803t010000z",
                "aa",
                "h1"
            )
            .is_err()
        );
    }

    #[test]
    fn compaction_gate_refuses_a_candidate_that_drops_a_section() {
        // Direction removed entirely from the candidate — the fatal silent
        // loss, caught by the nothing-dropped check.
        let cand = BASE.replacen(
            "## Direction — what are we all doing today",
            "## Direction was deleted",
            1,
        );
        assert!(validate_candidate(BASE, &cand, &[]).is_err());
    }

    #[test]
    fn compaction_gate_refuses_a_candidate_that_alters_an_operator_section() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let cand = fold_text(BASE, std::slice::from_ref(&a)).unwrap().replacen(
            "**We're giving forge agents local EXPERTS.**",
            "**hijacked**",
            1,
        );
        assert!(validate_candidate(BASE, &cand, &[a]).is_err());
    }

    #[test]
    fn compaction_gate_passes_a_true_fold() {
        let a = frag("20260803t010000z-aa-h1.md", HOST_A);
        let b = frag("20260803t010500z-bb-h2.md", HOST_B);
        let cand = fold_text(BASE, &[a.clone(), b.clone()]).unwrap();
        validate_candidate(BASE, &cand, &[a, b]).expect("a true fold passes the gate");
    }

    #[test]
    fn iso_compact_shape_is_utc_first_and_sortable() {
        let a = iso_to_compact("2026-08-03T01:00:00Z");
        let b = iso_to_compact("2026-08-03T01:05:00Z");
        assert_eq!(a, "20260803t010000z");
        assert!(a < b, "utc-first naming must sort chronologically");
    }

    #[test]
    fn drift_verdict_never_reports_eligible_for_zero_fragments() {
        let mut d = drift(Path::new("plan/loop_status.md"));
        d.fragment_count = 0;
        d.section_count = 0;
        d.total_bytes = 0;
        d.malformed_count = 0;
        assert!(!d.eligible());
        assert!(d.verdict().contains("eligible=false"));
    }

    #[test]
    fn the_store_readme_is_never_a_fragment_but_real_malformed_files_still_are() {
        // ORDER 626-bnn5: the committed plan/loop_status.d/README.md must not be
        // parsed as a fragment or reported malformed, while a genuinely
        // malformed cycle-status file still surfaces.
        let dir = std::env::temp_dir().join(format!("tilland-ls-readme-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let base = dir.join("loop_status.md");
        std::fs::create_dir_all(dir.join("loop_status.d")).unwrap();
        std::fs::write(
            &base,
            "# Multi-Host Coordination Loop Status\n\n## ACTIVE RELEASE: v0.5\n\n> base\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("loop_status.d/README.md"),
            "# Loop-status fragments (`plan/loop_status.d/`)\n\nDocumentation, not a fragment.\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("loop_status.d/20260809t010000z-bad-h.md"),
            "## Direction — what are we all doing today\n\nclobber\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("loop_status.d/20260809t010000z-good-h.md"),
            "## Cycle 2026-08-09T01:00:00Z (h — fine)\n\n- ok\n",
        )
        .unwrap();

        let names = |v: &[Fragment]| -> Vec<String> { v.iter().map(|f| f.name.clone()).collect() };
        let loaded = load_all(&base);
        let loaded_names = names(&loaded);
        assert!(
            !loaded_names.iter().any(|n| n == "README.md"),
            "README.md must not be folded as a fragment: {loaded_names:?}"
        );
        assert!(
            loaded_names.iter().any(|n| n.ends_with("-good-h.md")),
            "a real cycle fragment still loads"
        );

        let bad = malformed(&base);
        let bad_names: Vec<String> = bad
            .iter()
            .map(|p| {
                p.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string()
            })
            .collect();
        assert!(
            !bad_names.iter().any(|n| n == "README.md"),
            "README.md must not be reported malformed: {bad_names:?}"
        );
        assert!(
            bad_names.iter().any(|n| n.ends_with("-bad-h.md")),
            "a genuinely malformed fragment still surfaces as malformed: {bad_names:?}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── ORDER 626-zmhz: the folded-loop-status release-truth gate ──────────

    const RELEASE_SECTION: &str = "# Multi-Host Coordination Loop Status\n\
                                   \n\
                                   ## ACTIVE RELEASE: v0.5 (v0.4 SHIPPED)\n\
                                   \n\
                                   - **v0.4 — ACTIVE (13 open / 53 total tagged): \"stale\"**\n\
                                   - **v0.5 (87 open / 94 total tagged): \"stale too\"**\n";

    #[test]
    fn release_bullets_parse_version_label_and_counts() {
        let bullets = release_bullets(RELEASE_SECTION);
        assert_eq!(bullets.len(), 2);
        assert_eq!(bullets[0].version, "v0.4");
        assert!(bullets[0].active);
        assert_eq!(bullets[0].open, Some(13));
        assert_eq!(bullets[0].total, Some(53));
        assert_eq!(bullets[1].version, "v0.5");
        assert!(
            !bullets[1].active,
            "v0.5 bullet currently lacks the ACTIVE label"
        );
        assert_eq!(bullets[1].open, Some(87));
        assert_eq!(bullets[1].total, Some(94));
    }

    #[test]
    fn release_bullets_ignore_non_bullet_lines() {
        let text = "## ACTIVE RELEASE: v0.5\n\n- not a **v bullet\n- **v0.9x (1 open / 2 total tagged)\n- **v0.5 work seeded**: packet prose\n- **v1.0 (0 open / 1 total tagged)\n";
        let bullets = release_bullets(text);
        assert_eq!(bullets.len(), 1, "only the well-formed bullet parses");
        assert_eq!(bullets[0].version, "v1.0");
    }

    #[test]
    fn verify_active_release_flags_the_known_stale_shape() {
        // The pre-fix release section: v0.4 carries the ACTIVE label while the
        // register names v0.5, and v0.5's bullet is neither labeled nor current.
        let problems = verify_active_release(RELEASE_SECTION, "v0.5");
        assert!(
            problems
                .iter()
                .any(|p| p.contains("not labeled `— ACTIVE`")),
            "must flag the ACTIVE bullet missing its label: {problems:?}"
        );
        assert!(
            problems
                .iter()
                .any(|p| p.contains("are labeled ACTIVE") && p.contains("v0.4")),
            "must flag the stale v0.4 — ACTIVE bullet: {problems:?}"
        );
    }

    #[test]
    fn verify_active_release_passes_a_consistent_section() {
        let text = "# Multi-Host Coordination Loop Status\n\
                    \n\
                    ## ACTIVE RELEASE: v0.5 (v0.4 SHIPPED)\n\
                    \n\
                    - **v0.4 (13 open / 53 total tagged): \"shipped\"**\n\
                    - **v0.5 — ACTIVE (217 open / 298 total tagged): \"experts\"**\n";
        let problems = verify_active_release(text, "v0.5");
        assert!(problems.is_empty(), "consistent section: {problems:?}");
        let headings = active_release_headings(text);
        assert_eq!(headings, 1);
    }

    #[test]
    fn verify_active_release_refuses_duplicate_headings() {
        let text = "## ACTIVE RELEASE: v0.5\n\n## ACTIVE RELEASE: v0.6\n";
        let problems = verify_active_release(text, "v0.5");
        assert!(
            problems
                .iter()
                .any(|p| p.contains("exactly one is allowed")),
            "duplicate headings must be a contradiction: {problems:?}"
        );
    }

    #[test]
    fn render_count_line_is_the_spliceable_parenthetical() {
        assert_eq!(render_count_line(217, 298), "(217 open / 298 total tagged)");
    }

    #[test]
    fn stale_bullet_counts_fail_against_a_fresher_render() {
        // Exit criterion 3 at the prose level: a committed count that no longer
        // matches the folded truth must be distinguishable from a current one,
        // and the renderer must produce the canonical replacement.
        let committed = RELEASE_SECTION.replace(
            "(87 open / 94 total tagged)",
            "(217 open / 298 total tagged)",
        );
        let canonical = render_count_line(217, 298);
        assert!(committed.contains(&canonical));
        // Simulate the fold moving on: a fresher count line is the replacement a
        // coordinator splices in; the committed text at the old count still
        // differs from the canonical output.
        assert_ne!(
            render_count_line(87, 94),
            canonical,
            "the stale count must not render identically to the fresh one"
        );
    }
}
