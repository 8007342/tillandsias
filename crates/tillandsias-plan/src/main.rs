//! tillandsias-plan — agent-facing CLI over the plan ledger engine.
//!
//! Slice 1 (read-only): query + integrity check. The edit surface
//! (claim/event-append/status-flip with validated flushes) is slice 2.
//!
//! @trace spec:spec-traceability

use std::path::{Path, PathBuf};
use tillandsias_plan::{
    Ledger, Schema, answer, count_release, edit, fragments, groundtruth, loop_status, methodology,
    spec, str_field, str_list,
};

/// ORDER 569. The capability manifest, embedded from the crate's own
/// `capabilities.txt` at COMPILE TIME.
///
/// `include_str!` is the load-bearing part: the list travels INSIDE the
/// artifact, so `tillandsias-plan capabilities` describes the sources this
/// binary was built from — not the sources sitting in whatever checkout happens
/// to be mounted next to it. A stale binary therefore reports a stale (or, if it
/// predates this order, an absent) capability set, which is exactly the signal
/// order 531 lacked when a pre-expert build stamped `experts: ready` and every
/// `plan_answer` came back `confidence=unsupported`.
///
/// The forge reads the SAME filename out of the mounted checkout to learn what a
/// relaunch would provide. One file, two readers — see capabilities.txt for why
/// this is data rather than a Rust array. If it becomes a Rust array again, the
/// shell side has to hardcode a second copy and the two will drift.
const CAPABILITY_MANIFEST: &str = include_str!("../capabilities.txt");

/// The manifest's tokens, comments and blank lines stripped.
fn capability_tokens() -> Vec<&'static str> {
    CAPABILITY_MANIFEST
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

/// ORDER 583-dv9n. Every subcommand name `main` can dispatch — the DISPATCH
/// side of the capability surface, where [`capability_tokens`] is the DECLARED
/// side. The relationship is deliberately one-directional:
///
///   manifest → dispatch IS enforced behaviourally:
///   litmus:expert-capability-skew-honesty invokes every declared token, with a
///   negative control proving the check can fail.
///
///   dispatch → manifest is a WARNING, never a gate. An undeclared arm makes
///   the expert UNDER-report itself, which is fail-safe by design — the MCP
///   wrapper refuses to route to it, so nothing breaks, it merely looks
///   missing. The cost was silence: a subcommand added to the CLI but not to
///   capabilities.txt worked from the host and was invisible inside every
///   forge. `capabilities` now reports the omission on stderr (the forge runs
///   that self-report at every launch probe), so the drift is visible before it
///   reaches a forge instead of after.
///
/// Keep this in sync with the dispatch in `main`. Adding a subcommand there
/// without naming it here (or in capabilities.txt) is exactly the omission this
/// order exists to surface.
const DISPATCH_ARMS: &[&str] = &[
    "set-field",
    "append-event",
    "answer",
    "blocked-by",
    "blocked-closure",
    "blocking-counts",
    "burndown",
    "capabilities",
    "capability-matrix",
    "carry-forward-check",
    "check",
    "closure-evidence-check",
    "compact",
    "dependencies-of",
    "expire-claims",
    "fragment-event-packets",
    "fragment-misplaced-definitions",
    "fragment-terminal-events",
    "fragments",
    "grade",
    "loop-status",
    "loop-status-append",
    "loop-status-compact",
    "loop-status-fragments",
    "loop-status-verify",
    "methodology",
    "methodology-ask",
    "methodology-index",
    "next",
    "next-order",
    "parked-blocks",
    "query",
    "ready",
    "select-rows",
    "spec-envelope",
    "spec-index",
    "spec-retrieve",
    "status",
    "verify-answer",
];

/// ORDER 583-dv9n. The dispatch arms an arbitrary declared set omits. Split out
/// so the detection logic is unit-testable against a synthetic manifest without
/// rebuilding: the real call sites pass the compiled-in manifest.
fn manifest_drift_against(declared: &[&str]) -> Vec<&'static str> {
    let mut drift: Vec<&'static str> = DISPATCH_ARMS
        .iter()
        .copied()
        .filter(|arm| !declared.contains(arm))
        .collect();
    drift.sort_unstable();
    drift
}

/// ORDER 583-dv9n. Dispatch arms absent from the compiled-in manifest. Empty on
/// a tree where every arm is declared; a non-empty result is a warning, never a
/// gate (see [`DISPATCH_ARMS`]).
fn manifest_drift() -> Vec<&'static str> {
    manifest_drift_against(&capability_tokens())
}

const USAGE: &str = concat!(
    "usage: tillandsias-plan [--index <path>] <command>\n",
    "         commands:\n",
    "           capabilities              ORDER 569. Print this binary's subcommand capability set,\n",
    "                                     one token per line on stdout and nothing else. The set is\n",
    "                                     embedded at COMPILE time, so it describes the sources this\n",
    "                                     artifact was built from. A binary WITHOUT this subcommand\n",
    "                                     predates order 569 and its capabilities are unknowable —\n",
    "                                     that absence is itself the stale-binary signal the forge\n",
    "                                     wrapper branches on.\n",
    "           capability-matrix         ORDER 808-7yrd. The FLEET HARDWARE matrix, folded from the\n",
    "                                     `capabilities:` fragment channel: one row per host_id, its\n",
    "                                     schedulable (device_class, lane, engine) triples, and its\n",
    "                                     present-but-unusable devices. Distinct from `capabilities`\n",
    "                                     above, which reports THIS BINARY's subcommands.\n",
    "           check [--strict-fragments]\n",
    "                                     integrity + schema validation (exit 1 on violations).\n",
    "                                     ORDER 796-4ydb. A fragment the fold could not parse is\n",
    "                                     always named on stdout as `malformed: <path>` and the\n",
    "                                     verdict says `incomplete:` instead of `ok:` — the checks\n",
    "                                     that passed were run over less than the plan. It exits 0\n",
    "                                     anyway, because build.sh runs this on every host and a\n",
    "                                     fleet-wide refusal makes one host's typo every host's red\n",
    "                                     build (699-dycj). --strict-fragments arms that refusal for\n",
    "                                     a caller that cannot tolerate a partial corpus: exit 3,\n",
    "                                     distinct from 1 so 'incomplete' and 'unsound' never blur.\n",
    "           closure-evidence-check <fragment.yaml>\n",
    "                                     exit 1 if the fragment sets a closure rung\n",
    "                                     (completed/verified/done) with no evidence event (686-7qcm)\n",
    "           fragment-misplaced-definitions <fragment.yaml>\n",
    "                                     ORDER 812-d45t. Print the packet_ids of `events:`\n",
    "                                     entries that carry DEFINITION fields but no `event:` —\n",
    "                                     a packet written under the wrong key, which every gate\n",
    "                                     accepts and the fold then drops entirely.\n",
    "           fragment-event-packets <fragment.yaml>\n",
    "                                     ORDER 797-qm4t. Print EVERY packet_id an events block\n",
    "                                     addresses, whatever the event type, one per line, exit 0.\n",
    "                                     The terminal-only sibling below cannot see a `note` or\n",
    "                                     `progress` event aimed at a packet_id that does not exist,\n",
    "                                     so such work is discarded in silence. Same YAML parse and\n",
    "                                     the same exit 3 on an unparseable fragment.\n",
    "           fragment-terminal-events <fragment.yaml>\n",
    "                                     ORDER 752-pst5. Print the packet_ids whose events block\n",
    "                                     DECLARES a terminal `completed` event (inline packet\n",
    "                                     `events:` or the top-level `events:` form), one per\n",
    "                                     line, exit 0. A YAML parse bounds attribution to the\n",
    "                                     events block, so PROSE that quotes the marker inside a\n",
    "                                     block scalar is never read as a declaration. Backs the\n",
    "                                     closure-event pass of check-fragment-status-loss.sh.\n",
    "           carry-forward-check <fragment.yaml>\n",
    "                                     ORDER 831-ezea. Print the packet_ids this fragment\n",
    "                                     TOUCHED (has an event for) and LEFT OPEN (no terminal\n",
    "                                     event, status: value, or declared status) while naming\n",
    "                                     no `next_action` — one per line, exit 0. Closures are\n",
    "                                     EXEMPT: a carry-forward note on a terminal row is a dead\n",
    "                                     letter no selector reads again. Same YAML parse and the\n",
    "                                     same exit 3 on an unparseable fragment as its three\n",
    "                                     fragment-* siblings. ADVISORY today (adoption 4.6%),\n",
    "                                     see scripts/check-carry-forward.sh for the promotion bar.\n",
    "           next-order [prefix]       mint a COLLISION-FREE order token for a new packet\n",
    "                                     (<seq>-<suffix>, e.g. 581-k3f9). Never compute the\n",
    "                                     'next free order' yourself: that reads a ledger snapshot\n",
    "                                     which is stale the moment another host commits, so\n",
    "                                     concurrent filers pick the SAME number. The minted token\n",
    "                                     is PERMANENT — never renumber it. A prefix shared by two\n",
    "                                     packets is normal. See methodology/distributed-work.yaml\n",
    "                                     -> order_id_allocation.\n",
    "           expire-claims [--ttl-hours N] [--dry-run] [--now-epoch S] [--host H]\n",
    "                                     ORDER 672-bz7u. Return stranded in_progress claims to\n",
    "                                     ready: any packet whose LAST recorded event activity is\n",
    "                                     older than the TTL (default 24h) gets a status fragment\n",
    "                                     flipping it back to ready with a progress event naming\n",
    "                                     the expiry. --dry-run lists without writing. A packet\n",
    "                                     with NO parseable activity timestamp is reported as\n",
    "                                     unknown-age and NEVER expired (fail conservative).\n",
    "           status <id|order>         one packet's status line\n",
    "           blocked-by <id|order>     packets directly blocked by X\n",
    "           dependencies-of <id|order> X's direct unsatisfied depends_on prerequisites\n",
    "           blocked-closure <id|order> everything transitively downstream of X\n",
    "           parked-blocks [id|order]  dependents invisibly blocked behind a PARKED\n",
    "                                     packet (implemented/needs_clarification/blocked/\n",
    "                                     failed); no arg = whole ledger (order 686-7qcm)\n",
    "           ready [role]              ready packets (optionally for a pickup role)\n",
    "           next [role] [--release V] [--limit N]\n",
    "                                     ORDER 606-xu52. The cold-start selector: at most FIVE\n",
    "                                     cited, release-aware, role-compatible, dependency-clear,\n",
    "                                     unleased claimable packets, ranked deterministically\n",
    "                                     (priority, release-targeted first, order). Release\n",
    "                                     defaults from the folded '## ACTIVE RELEASE' heading;\n",
    "                                     no release anywhere is a typed refusal. Milestones and\n",
    "                                     criteria holders are never offered as claims. Natural\n",
    "                                     aliases via `answer`: \"what's next?\" and\n",
    "                                     \"what v0.5 work can I do on linux?\".\n",
    "           blocking-counts [--release V] [--limit N]\n",
    "                                     ORDER 632-retq. `<packet_id>\\t<count>` — how many READY\n",
    "                                     packets each id blocks, counted over EVERY ready packet\n",
    "                                     rather than one role's, because a packet in another column\n",
    "                                     is frequently the thing this one waits on.\n",
    "           select-rows [--claimable-by R] [--release V] [--limit N]\n",
    "                                     ORDER 632-retq. The batch selector's projection, as TSV:\n",
    "                                     rank, release_target, order, packet_id, urgency, release.\n",
    "                                     Already filtered to ready + claimable + release +\n",
    "                                     dependency-clear + unleased, so the caller needs no jq.\n",
    "                                     scripts/select-work-batch.sh needed NINETEEN jq calls to\n",
    "                                     build this, which is why it could not run on a host without\n",
    "                                     jq; satisfying that dependency per host repeats the yq/ruby\n",
    "                                     exposure, so the projection moves to the binary that already\n",
    "                                     owns the ledger.\n",
    "           query [--status S] [--role R] [--release V] [--tag T]... [--limit N] [--json]\n",
    "                                     ORDER 582-26mm. THE generic filtered reader over the\n",
    "                                     FOLDED ledger (base ⊕ plan/index.d/ fragments): the only\n",
    "                                     correct way to enumerate packets by status / pickup_role /\n",
    "                                     desired_release / capability_tags. Release matching is exact;\n",
    "                                     an unknown release is an error, never an ignored constraint.\n",
    "                                     project-info plan_query and drain-queue\n",
    "                                     both route here; a reader that forgets fragments reports a\n",
    "                                     stale ledger with total confidence. TSV by default\n",
    "                                     (order<TAB>packet_id<TAB>desired_release<TAB>tags); --json\n",
    "                                     emits the plan_query projection array.\n",
    "           burndown <milestone>      release-target children with statuses\n",
    "           answer <question...>      the CITED answer envelope as JSON (order 394b)\n",
    "           verify-answer [--root D]  read an envelope on stdin; exit 1 if any citation\n",
    "                                     does not resolve or its span does not contain the claim.\n",
    "                                     ORDER 801-g9nn: also derives caller-relation\n",
    "                                     (same|behind|ahead|diverged|unfetched|unknown) between D's\n",
    "                                     HEAD and the answer's commit, and exits 3 — not 1 — when a\n",
    "                                     citation is SOUND at its own commit but stale here.\n",
    "           methodology [--root D] [--file S] <yaml.path>\n",
    "                                     ORDER 394c. YAML path query over methodology.yaml and\n",
    "                                     methodology/**/*.yaml. Prints the 394b envelope: the\n",
    "                                     matched block plus a resolvable file:line. An unknown\n",
    "                                     path is confidence=unsupported, never a guess.\n",
    "           methodology-ask [--root D] [--file S] <question...>\n",
    "                                     route a canonical discipline question to its YAML path,\n",
    "                                     then answer it. Unrouted questions are unsupported.\n",
    "           methodology-index [--root D]\n",
    "                                     every indexed path with its file:line (the query surface)\n",
    "           append-event <id|order> <type> <summary> --ts <ISO> [--agent A] [--host H]\n",
    "                                     append an event, VALIDATED before flush (refuses a broken ledger).\n",
    "                                     --agent defaults from TILLANDSIAS_AGENT_ID and REFUSES when both\n",
    "                                     are absent; --host defaults to the compiled platform (772-4se9)\n",
    "           grade [--root D] [--case ID] [--envelope F|-] [--list-engines] [SET.yaml ...]\n",
    "                                     ORDER 394d. Grade the experts against the COMMITTED ground\n",
    "                                     truth. Defaults to openspec/litmus-tests/groundtruth/\n",
    "                                     expert-groundtruth-rung1.yaml; pass more query sets (or a\n",
    "                                     glob) to grade further corpora with the same harness.\n",
    "                                     --envelope grades ONE case against an envelope captured\n",
    "                                     elsewhere (e.g. off the MCP server). Exit 1 = graded RED,\n",
    "                                     exit 2 = the harness could not run at all.\n",
    "           spec-index --out <dir> [--root D]\n",
    "                                     ORDER 547. Chunk the whole-spec corpus into <dir>/chunks.jsonl\n",
    "           spec-retrieve --index-dir <dir> --query-vec <f> [--k N]\n",
    "                                     network-free cosine top-k over caller-supplied embeddings\n",
    "           spec-envelope --chunks-json <f> [--answer-file F] [--root D]\n",
    "                         [--corpus-commit SHA]\n",
    "                                     build a VERIFIED envelope keeping only the citations the\n",
    "                                     answer actually used. --corpus-commit stamps the frame the\n",
    "                                     INDEX was built at onto every citation (order 801-g9nn)\n",
    "           fragments                 report the append-only plan/index.d/ overlay: which\n",
    "                                     fragments are live, which are malformed, and whether\n",
    "                                     compaction is eligible\n",
    "           compact                   fold every fragment into the base ledger and delete\n",
    "                                     exactly the ones folded (refuses a lossy rewrite)\n",
    "           loop-status [--index plan/loop_status.md]\n",
    "                                     ORDER 582-nqw5. THE loop_status reader: the folded view\n",
    "                                     (base ⊕ loop_status.d/ fragments). The only correct way to\n",
    "                                     read loop_status — a reader that forgets fragments reports\n",
    "                                     a stale status with total confidence.\n",
    "           loop-status-fragments      ORDER 582-nqw5. Report the loop_status.d/ overlay: live\n",
    "                                     fragments, malformed ones, and whether compaction is eligible\n",
    "           loop-status-verify [--ledger P] [--render]\n",
    "                                     ORDER 626-zmhz. The deterministic ACTIVE-RELEASE + count gate:\n",
    "                                     cross-checks the FOLDED loop_status prose (exactly one ACTIVE\n",
    "                                     RELEASE heading, exactly one `— ACTIVE` bullet, and that bullet\n",
    "                                     IS the active release) against the FOLDED ledger's release\n",
    "                                     counts, and fails loud on stale prose. --ledger overrides\n",
    "                                     plan/index.yaml; --render prints the canonical count line.\n",
    "           set-field <id|order> <field> <value> [--ts ISO] [--host H] [--reason TEXT]\n",
    "                                     ORDER 636-9m79. Correct a packet field by writing the LWW\n",
    "                                     channel as a NEW fragment. USE THIS instead of hand-authoring:\n",
    "                                     re-declaring a packet under `packets:` is a G-Set no-op that\n",
    "                                     parses, validates and silently does nothing — three hosts hit\n",
    "                                     that on 2026-08-09 and 11 of 21 completions were discarded.\n",
    "                                     Field-generic despite the channel's `status:` name (642-fedr).\n",
    "                                     Resolves against the FOLDED ledger, so unlike append-event it\n",
    "                                     reaches fragment-only packets (600-c266). Refuses an unknown\n",
    "                                     reference; reports a no-op instead of writing one.\n",
    "           loop-status-append [--ts ISO] [--host H] [--suffix S] [--file F]\n",
    "                                     ORDER 582-nqw5. Append ONE `## Cycle …` section (stdin or\n",
    "                                     --file) as a NEW fragment file — concurrent hosts each write\n",
    "                                     their own path, so appending status no longer conflicts.\n",
    "                                     Refuses `## Direction` and every other non-cycle heading.\n",
    "           loop-status-compact        ORDER 582-nqw5. Fold fragments into loop_status and delete\n",
    "                                     exactly the ones folded, gated on: nothing dropped, nothing\n",
    "                                     lost, operator-owned sections byte-identical, fold idempotent\n",
    "           loop-status-fragments      ORDER 582-nqw5. Report the loop_status.d/ overlay: live\n",
    "                                     fragments, malformed ones, and whether compaction is eligible\n"
);

fn usage() -> ! {
    eprintln!("{USAGE}");
    std::process::exit(2);
}

/// ORDER 569. An unrecognised subcommand is its OWN named failure, distinct from
/// the missing-operand `usage()` above.
///
/// Both used to funnel into `usage()`, which made "this binary cannot do that"
/// indistinguishable from "you forgot an argument" — and the pre-394b binary
/// order 531 shipped was worse still: it printed usage on STDOUT and exited 0,
/// so the MCP wrapper could not tell incapability from success without sniffing
/// the shape of the output. Naming the condition, listing what this artifact CAN
/// do, and exiting non-zero is what lets the wrapper (and a human reading a
/// terminal) say "wrong binary" instead of "wrong question".
///
/// If this is deleted, an agent whose forge carries a stale expert gets a usage
/// dump where it asked for an answer, and the capability probe in
/// images/default/lib-expert-capability.sh loses its negative control.
fn unknown_subcommand(name: &str) -> ! {
    eprintln!(
        "error: unknown subcommand '{name}' — this tillandsias-plan was built from sources \
         that do not provide it."
    );
    eprintln!("  this binary can do: {}", capability_tokens().join(", "));
    eprintln!(
        "  if you expected '{name}' to exist, the ARTIFACT is stale relative to the checkout: \
         rebuild it (cargo build --release -p tillandsias-plan) or relaunch the forge."
    );
    eprintln!("{USAGE}");
    std::process::exit(2);
}

/// ORDER 523 (R2). Emit an envelope only after it verifies against the root its
/// own citations are relative to — and downgrade to `unsupported` naming the
/// violations when it does not.
///
/// `answer::verify` existed and was exercised only by `verify-answer` and the
/// litmus, i.e. by whoever chose to run it. Nothing on the RUNTIME path called
/// it, so an envelope could be emitted with `confidence: exact` carrying a
/// citation that `verify-answer` would refuse against the same checkout —
/// reachable in practice because the MCP wrapper probes several candidate index
/// locations and caches the first non-empty one, so the root the paths were built
/// against need not be the root a reader resolves them from.
///
/// Running the verifier at the exit point makes it unavoidable: the emitter and
/// the checker can no longer disagree about the same envelope, because the
/// emitter IS a checker.
///
/// Exits 0 in every case, including a downgrade: `unsupported` is a well-formed
/// answer, and the forge-plan MCP wrapper runs under `set -e` where a non-zero
/// status kills the server mid-request. The envelope is the signal.
///
/// ORDER 796-4ydb — the envelope is also STAMPED with whatever the fold could
/// not read. `skipped` is those corpus files: empty for the
/// methodology and spec corpora, which are loaded before and independently of
/// the ledger, and `ledger.skipped_fragments()` for the plan corpus. Every call
/// site states it explicitly so a new one has to decide rather than inherit
/// silence, which is the exact failure this order exists to fix.
fn emit_verified_envelope(envelope: answer::Envelope, root: &Path, skipped: &[PathBuf]) {
    // Stamped AFTER self-verification: `self_verified` may replace the envelope
    // with a fresh refusal, and the corpus was still partial either way.
    let verified = stamp_frame(self_verified(envelope, root), root)
        .with_skipped_sources(skipped.iter().map(|p| citation_path(p, root)).collect());
    match serde_json::to_string_pretty(&verified) {
        Ok(json) => println!("{json}"),
        Err(e) => {
            eprintln!("error: serialize envelope: {e}");
            std::process::exit(1);
        }
    }
}

/// The environment variable a caller uses to tell the expert where it stands.
///
/// AN EXPERT CANNOT SEE ITS CALLER. The MCP server answers out of the checkout
/// it was launched in; the asking agent may be in a linked worktree several
/// commits away, or in a forge whose repo was seeded at a different sha. There
/// is no ambient way to learn the reader's HEAD, so the reader supplies it — and
/// when it does not, the field is OMITTED rather than defaulted, because a
/// `caller_relation: same` invented from the emitter's own self-consistency is
/// the precise false assurance order 801-g9nn exists to remove.
const CALLER_HEAD_ENV: &str = "TILLANDSIAS_CALLER_HEAD";

/// ORDER 801-g9nn — stamp the answer's FRAME onto the envelope on its way out.
///
/// Two stamps, and they answer different questions:
///
/// * every citation gets the commit its span was read at, defaulting to the
///   checkout HEAD already in `freshness.source_commit` — correct for the
///   deterministic layer, which reads the corpus out of the working tree at
///   query time. A retrieved answer served from an index built elsewhere sets
///   its own per-citation commit first and this leaves it alone.
/// * `caller_relation` is stamped ONLY when the reader identified itself. See
///   [`CALLER_HEAD_ENV`].
///
/// A refusal is stamped too. `unsupported` carries no citations, but it does
/// carry a freshness block, and "which frame refused you" is worth as much as
/// "which frame answered you" when two harnesses disagree about whether a packet
/// exists.
fn stamp_frame(envelope: answer::Envelope, root: &Path) -> answer::Envelope {
    let commit = envelope.freshness().source_commit().to_string();
    let envelope = envelope.with_default_citation_commit(&commit);
    let Ok(caller_head) = std::env::var(CALLER_HEAD_ENV) else {
        return envelope;
    };
    let caller_head = caller_head.trim();
    if !tillandsias_plan::gitref::looks_like_sha(caller_head) {
        // A malformed hint is dropped in silence rather than stamped: an
        // envelope that reported `caller_head: HEAD` would look answered and be
        // unusable, which is worse than an absent field.
        return envelope;
    }
    let view = tillandsias_plan::gitref::GitView::new(root);
    envelope.with_caller_relation(answer::CallerRelation::ancestry_only(
        &view,
        caller_head,
        &commit,
    ))
}

/// The pure half of [`emit_verified_envelope`], split out so the downgrade is
/// unit-testable without capturing stdout. Returns the envelope unchanged when it
/// verifies, and a self-refusal naming every violation when it does not.
fn self_verified(envelope: answer::Envelope, root: &Path) -> answer::Envelope {
    let envelope = if envelope.confidence() != answer::Confidence::Unsupported {
        envelope.with_citation_root(root)
    } else {
        envelope
    };
    let violations = answer::verify(&envelope, root);
    if violations.is_empty() {
        return envelope;
    }
    answer::Envelope::unsupported(
        format!(
            "this answer FAILED its own citation check against {} and was withheld \
             ({} violation(s)): {}",
            root.display(),
            violations.len(),
            violations.join("; ")
        ),
        envelope.freshness().clone(),
    )
}

/// The repo-relative path the citations carry. A citation must name a path a
/// READER can open from the checkout root, so an absolute or `../`-laden
/// `--index` is reduced to its `plan/index.yaml`-shaped tail.
///
/// The tail is only ever used as a LABEL: `verify-answer` re-resolves it
/// against the root and re-reads the span, so a wrong label is caught there
/// rather than being trusted — and since order 523 the emitter runs that same
/// check itself before printing, so a wrong label is caught at emission too.
fn citation_path(index: &Path, root: &Path) -> String {
    if let Ok(rel) = index.strip_prefix(root) {
        return rel.to_string_lossy().replace('\\', "/");
    }
    let comps: Vec<String> = index
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect();
    match comps.iter().rposition(|c| c == "plan") {
        Some(i) => comps[i..].join("/"),
        None => index.to_string_lossy().replace('\\', "/"),
    }
}

/// The checkout the citation paths are resolved against: the parent of the
/// index's `plan/` directory, falling back to the process cwd.
fn root_for(index: &Path) -> PathBuf {
    let candidate = index
        .parent()
        .and_then(Path::parent)
        .filter(|p| !p.as_os_str().is_empty())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    candidate.canonicalize().unwrap_or(candidate)
}

/// Print one line, exiting cleanly if the reader has gone away.
///
/// WHY THIS IS NOT `println!`. Rust's `println!` PANICS on a write error, so
/// piping any list-producing command into `head` — which every agent and every
/// shell wrapper does constantly — closes the pipe and makes this binary abort
/// with exit 101 and a backtrace note on stderr:
///
///     thread 'main' panicked at library/std/src/io/stdio.rs
///     failed printing to stdout: Broken pipe (os error 32)
///
/// That is a correctness problem, not an aesthetic one. `forge-plan.sh` runs
/// under `set -euo pipefail`, and order 456 already recorded a case where a
/// non-zero exit from this binary killed the MCP server mid-session. A tool
/// whose output is routinely piped must treat a closed reader the way every
/// other unix tool does: stop writing and exit successfully.
///
/// Resetting SIGPIPE to SIG_DFL is the conventional fix, but it needs `libc`,
/// and this crate carries exactly three dependencies on purpose. Handling the
/// error costs nothing and keeps that promise.
fn emit(text: &str) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    if let Err(e) = writeln!(out, "{text}") {
        if e.kind() == std::io::ErrorKind::BrokenPipe {
            // The reader closed early (`| head`). Nothing is wrong.
            std::process::exit(0);
        }
        eprintln!("error: write to stdout: {e}");
        std::process::exit(1);
    }
}

/// How far a hand-supplied `--ts` may sit from the host clock, in seconds.
/// Fifteen minutes: generous enough for a slow cycle that read the clock at its
/// start and writes at its end, tight enough to catch a fabricated hour.
const TS_SKEW_LIMIT_SECS: i64 = 900;

/// ORDER 796-4ydb — `check --strict-fragments` refused because the fold could
/// not read part of the corpus.
///
/// DISTINCT FROM 1 ON PURPOSE. Exit 1 means the ledger is UNSOUND — something
/// it says is wrong. This means the ledger is INCOMPLETE — something it should
/// say is missing, and what is there may be fine. A caller that cannot tell
/// them apart either escalates a typo to a corruption or, far worse, reads a
/// partial-corpus refusal as a clean tree. The pre-push plan-only lane told
/// them apart by grepping stderr prose until this existed.
const EXIT_FOLD_INCOMPLETE: i32 = 3;

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The host string stamped on a ledger write when `--host` was not passed.
///
/// It used to fall back to the literal `"host"`, then to `"unknown"` — and
/// append-event, worse, hardcoded `"linux"`, a wrong FACT on two of the four
/// host kinds, written by the windows .exe into durable events (order
/// 772-4se9, plan/issues/plan-append-event-defaults-fabricate-host-linux-
/// 2026-08-16.md). But the platform is not an absence: the binary knows it at
/// compile time. `std::env::consts::OS` says exactly `linux`/`macos`/`windows`
/// on the three host platforms, which is the ledger's own vocabulary
/// (`--host <linux|macos|windows|...>`), so the default is now that compiled
/// fact. Callers wanting the richer identity (`linux_immutable`, a forge
/// label) still pass `--host`.
///
/// TILLANDSIAS_HOST_KIND is consulted first for compatibility — it answers a
/// DIFFERENT question (forge-vs-host, not which machine wrote this), but when
/// it is set to `forge` it is the more specific truth.
fn resolve_writer_host() -> String {
    writer_host_from(std::env::var("TILLANDSIAS_HOST_KIND").ok())
}

/// Pure core of [`resolve_writer_host`], unit-testable without env races.
fn writer_host_from(kind: Option<String>) -> String {
    if let Some(kind) = kind
        && !kind.is_empty()
    {
        return kind;
    }
    std::env::consts::OS.to_string()
}

/// The agent_id for a ledger event when `--agent` was not passed.
///
/// Precedence mirrors scripts/agent-identity.sh (order 756-hn3a): an explicit
/// `--agent` wins, then launch-provided TILLANDSIAS_AGENT_ID, and when both
/// are absent the write is REFUSED. The literal string `unknown` is not an
/// identity — it is the hand-composed improvisation 756-hn3a removed from
/// claim recipes — so it counts as absent from either source (order 772-4se9).
fn resolve_writer_agent(flag: Option<String>) -> String {
    match writer_agent_from(flag, std::env::var("TILLANDSIAS_AGENT_ID").ok()) {
        Ok(agent) => agent,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(2);
        }
    }
}

/// Pure core of [`resolve_writer_agent`], unit-testable without env races.
fn writer_agent_from(flag: Option<String>, env_id: Option<String>) -> Result<String, String> {
    let usable = |s: &String| {
        let t = s.trim();
        !t.is_empty() && t != "unknown"
    };
    if let Some(agent) = flag.filter(usable) {
        return Ok(agent);
    }
    if let Some(agent) = env_id.filter(usable) {
        return Ok(agent);
    }
    Err(
        "error: ledger event has no --agent and TILLANDSIAS_AGENT_ID is unset — refusing to \
         record agent_id 'unknown'. Derive the id from scripts/agent-identity.sh (order \
         756-hn3a) and pass --agent, or export TILLANDSIAS_AGENT_ID."
            .to_string(),
    )
}

/// Resolve the `--ts` for a ledger write (order 719-kgr5).
///
/// THE DEFECT THIS CLOSES. Every writer took `--ts` on trust, which made
/// ordering a property of agent discipline rather than of the tool. Across the
/// 2026-08-13 windows overnight run the values were hand-authored — incremented
/// by roughly an hour per cycle from an early guess — and drifted to +8.6h
/// against the real commit times, while the sibling linux host, reading its
/// clock, stayed within 17 seconds. The ledger is an append-only CRDT whose
/// fragments fold in NAME order, whose claim expiry is decided from event
/// timestamps, and whose rolling metrics window over them, so a host writing
/// hours ahead sorts its work after later work and can make a stale claim
/// outlive its TTL. It also cost a sibling a night diagnosing a clock fault
/// that did not exist: the machine clock was correct to the second.
///
/// Three properties, in the order they matter:
///
///   * ABSENT `--ts` now means the host clock, so the correct thing is the easy
///     thing. The old interface made inventing a value exactly as convenient as
///     reading one, and `append-event` went further and REQUIRED the flag —
///     "the tool does not invent timestamps" — which read as rigour but simply
///     moved the invention to the caller.
///   * A supplied value must agree with the clock within the skew limit, and a
///     refusal names BOTH values, because the symptom ("your clock is 7 hours
///     ahead") was misdiagnosed once already.
///   * `--backfill` is the escape hatch for recording something that genuinely
///     happened earlier. Explicit, typed by a person, never implicit silence.
fn resolve_ts(supplied: Option<String>, backfill: bool, subcommand: &str) -> String {
    let now = now_epoch();
    let Some(ts) = supplied else {
        return answer::epoch_to_iso8601(now);
    };
    let Some(given) = answer::iso8601_to_epoch(&ts) else {
        eprintln!(
            "error: --ts '{ts}' is not a ledger timestamp (want YYYY-MM-DDTHH:MM:SSZ, UTC) — {subcommand} refused the write"
        );
        std::process::exit(2);
    };
    let skew = given - now;
    if backfill {
        // A backfill may only reach BACKWARD. "Recording something that
        // happened earlier" is the whole justification, and a flag that also
        // waived future timestamps would hand the original defect a one-word
        // bypass.
        if skew > TS_SKEW_LIMIT_SECS {
            eprintln!(
                "error: --backfill records something that already happened, but --ts {ts} is {skew}s AHEAD of this host's clock ({}) — {subcommand} refused the write",
                answer::epoch_to_iso8601(now)
            );
            std::process::exit(2);
        }
        return ts;
    }
    if skew.abs() > TS_SKEW_LIMIT_SECS {
        eprintln!(
            "error: --ts {ts} disagrees with this host's clock {} by {}s (limit {TS_SKEW_LIMIT_SECS}s) — \
             omit --ts to use the clock, or pass --backfill if the event genuinely happened earlier; \
             {subcommand} refused the write",
            answer::epoch_to_iso8601(now),
            skew.abs()
        );
        std::process::exit(2);
    }
    ts
}

fn line(ledger: &Ledger, p: &serde_yaml::Value) -> String {
    let id = ledger.id_of(p);
    let order = p
        .get("order")
        .map(|v| match v {
            serde_yaml::Value::Number(n) => n.to_string(),
            serde_yaml::Value::String(s) => s.clone(),
            _ => "?".into(),
        })
        .unwrap_or_else(|| "?".into());
    let status = p
        .get("status")
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("?");
    format!("{order}\t{status}\t{id}")
}

#[derive(Debug, PartialEq, Eq)]
struct QueryOptions {
    status: Option<String>,
    role: Option<String>,
    claimable_by: Option<String>,
    release: Option<String>,
    tags: Vec<String>,
    limit: usize,
    json: bool,
}

impl Default for QueryOptions {
    fn default() -> Self {
        Self {
            status: None,
            role: None,
            claimable_by: None,
            release: None,
            tags: Vec::new(),
            limit: 20,
            json: false,
        }
    }
}

/// Parse the closed `query` constraint vocabulary. Missing values and invalid
/// limits are errors rather than silently disappearing — a dropped constraint
/// makes a broad result look authoritative, which is worse than a refusal.
fn parse_query_options(args: &[String]) -> Result<QueryOptions, String> {
    let mut options = QueryOptions::default();
    let mut limit_seen = false;
    let mut i = 0usize;
    while i < args.len() {
        let flag = args[i].as_str();
        let value_after = |at: usize| -> Result<String, String> {
            let Some(value) = args.get(at + 1) else {
                return Err(format!("{flag} requires a value"));
            };
            if value.starts_with("--") {
                return Err(format!("{flag} requires a value"));
            }
            if value.is_empty() {
                return Err(format!("{flag} requires a non-empty value"));
            }
            Ok(value.clone())
        };
        match flag {
            "--status" => {
                if options.status.is_some() {
                    return Err("--status may be specified only once".to_string());
                }
                options.status = Some(value_after(i)?);
                i += 2;
            }
            "--role" => {
                if options.role.is_some() {
                    return Err("--role may be specified only once".to_string());
                }
                options.role = Some(value_after(i)?);
                i += 2;
            }
            "--claimable-by" => {
                if options.claimable_by.is_some() {
                    return Err("--claimable-by may be specified only once".to_string());
                }
                if options.role.is_some() {
                    return Err(
                        "--role and --claimable-by ask different questions; specify only one"
                            .to_string(),
                    );
                }
                options.claimable_by = Some(value_after(i)?);
                i += 2;
            }
            "--release" => {
                if options.release.is_some() {
                    return Err("--release may be specified only once".to_string());
                }
                options.release = Some(value_after(i)?);
                i += 2;
            }
            "--tag" => {
                options.tags.push(value_after(i)?);
                i += 2;
            }
            "--limit" => {
                if limit_seen {
                    return Err("--limit may be specified only once".to_string());
                }
                let raw = value_after(i)?;
                options.limit = raw
                    .parse::<usize>()
                    .map_err(|_| format!("--limit requires a non-negative integer, got '{raw}'"))?;
                limit_seen = true;
                i += 2;
            }
            "--json" => {
                if options.json {
                    return Err("--json may be specified only once".to_string());
                }
                options.json = true;
                i += 1;
            }
            other => return Err(format!("unknown query constraint: {other}")),
        }
    }
    Ok(options)
}

fn known_releases(ledger: &Ledger) -> Vec<String> {
    let mut releases: Vec<String> = ledger
        .packets
        .iter()
        .filter_map(|p| str_field(p, "desired_release"))
        .map(str::to_string)
        .collect();
    releases.sort();
    releases.dedup();
    releases
}

/// ORDER 706-ddw6. Active claim lease state, parsed from the claim-ledger-node
/// filesystem contract (${TILLANDSIAS_LEDGER_LEASE_ROOT} or
/// ${XDG_RUNTIME_DIR}/tillandsias-locks/ledger-nodes or /tmp/tillandsias-locks/ledger-nodes).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct PacketLease {
    holder: String,
    host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    acquired_at: Option<String>,
    expires_epoch: u64,
    is_active: bool,
}

fn inspect_lease(packet_id: &str) -> Option<PacketLease> {
    let lease_root = std::env::var("TILLANDSIAS_LEDGER_LEASE_ROOT")
        .map(PathBuf::from)
        .or_else(|_| {
            std::env::var("XDG_RUNTIME_DIR")
                .map(|r| PathBuf::from(r).join("tillandsias-locks/ledger-nodes"))
        })
        .unwrap_or_else(|_| PathBuf::from("/tmp/tillandsias-locks/ledger-nodes"));
    let safe = packet_id.replace('/', "__");
    let holder_file = lease_root.join(format!("{safe}.lease")).join("holder");
    if !holder_file.is_file() {
        return None;
    }
    let content = std::fs::read_to_string(&holder_file).ok()?;
    let mut holder = String::new();
    let mut host = String::new();
    let mut acquired_at = None;
    let mut expires_epoch: u64 = 0;
    for line in content.lines() {
        if let Some(val) = line.strip_prefix("lease_id=") {
            holder = val.trim().to_string();
        } else if let Some(val) = line.strip_prefix("host=") {
            host = val.trim().to_string();
        } else if let Some(val) = line.strip_prefix("acquired_at=") {
            acquired_at = Some(val.trim().to_string());
        } else if let Some(val) = line.strip_prefix("expires_epoch=") {
            expires_epoch = val.trim().parse().unwrap_or(0);
        }
    }
    let now_epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let is_active = expires_epoch > now_epoch;
    Some(PacketLease {
        holder,
        host,
        acquired_at,
        expires_epoch,
        is_active,
    })
}

/// Order 632-retq. The urgency rank + display a batch selector needs, derived
/// once, HERE, instead of in an awk block that only a host with jq ever reaches.
///
/// Three tiers, and the last is the point (order 630-6hyc): an EXPLICIT
/// priority dominates because the operator said so; otherwise urgency is
/// DERIVED from `kind`, since 202 ready packets carry a kind and only 38 carry
/// a priority; otherwise the packet is UNSCORED — rank 99, excluded from the
/// urgency term rather than coerced to a plausible p3, which is the shape that
/// made the term a constant 0 for ~82% of the pool without anyone noticing.
pub fn urgency_rank_and_display(priority: Option<&str>, kind: Option<&str>) -> (u32, String) {
    match priority.unwrap_or("") {
        "p0" => return (0, "p0".to_string()),
        "p1" => return (1, "p1".to_string()),
        "p2" => return (2, "p2".to_string()),
        "p3" => return (3, "p3".to_string()),
        _ => {}
    }
    let kind = kind.unwrap_or("");
    let rank = match kind {
        "security" | "bug" | "fix" => 4,
        "feat" | "enhancement" | "infra" | "ux" | "optimization" | "perf" | "dx" => 5,
        "research" | "exploration" | "docs" | "discussion" | "decision" | "chore" => 6,
        _ => 99,
    };
    if rank == 99 {
        (99, "unscored".to_string())
    } else {
        (rank, format!("kind:{kind}"))
    }
}

/// Order 632-retq. Is every dependency of `packet` terminal?
///
/// An id that resolves to nothing counts as BLOCKING, matching the resolver's
/// conservatism: an unresolvable dependency is an unanswered question, not an
/// absent constraint.
pub fn dependencies_are_clear(
    deps: &[String],
    terminal: &std::collections::BTreeSet<String>,
) -> bool {
    deps.iter().all(|d| terminal.contains(d))
}

fn query_json_projection(packet: &serde_yaml::Value) -> serde_json::Value {
    let mut obj = serde_json::Map::new();
    for key in [
        "packet_id",
        "order",
        "title",
        "status",
        "kind",
        "pickup_role",
        "desired_release",
        "release_target",
        // Order 627-cx24, found by the macOS lane. `priority` was absent from
        // this projection, so scripts/select-work-batch.sh — whose minimax score
        // is 2*urgency + 1.5*blocking + neglect — read `.priority // "p3"` and
        // got "p3" for EVERY packet on EVERY platform. Urgency was a constant 0
        // and the term contributed nothing to any selection ever made.
        //
        // The failure was silent by construction: the selector's `// "p3"`
        // default is indistinguishable from a genuine p3, so the scoring looked
        // like it worked and every batch was ranked on blocking+neglect alone.
        // A projection that silently drops a field a consumer scores on is the
        // same class of defect as an expression-pinned guard (622-rmit): it
        // fails in a direction nothing observes.
        "priority",
        "capability_tags",
        "deliverable",
        "depends_on",
    ] {
        if let Some(value) = packet.get(key) {
            obj.insert(
                key.to_string(),
                serde_json::to_value(value).unwrap_or(serde_json::Value::Null),
            );
        }
    }
    // ORDER 706-ddw6. Project active lease information directly.
    if let Some(packet_id) = packet.get("packet_id").and_then(serde_yaml::Value::as_str) {
        if let Some(lease) = inspect_lease(packet_id) {
            obj.insert(
                "lease".to_string(),
                serde_json::to_value(&lease).unwrap_or(serde_json::Value::Null),
            );
        } else {
            obj.insert("lease".to_string(), serde_json::Value::Null);
        }
    } else {
        obj.insert("lease".to_string(), serde_json::Value::Null);
    }
    // These are the release-query contract, not opportunistic metadata.
    // A missing field is explicit JSON null so consumers can distinguish
    // "projected but absent" from "this binary predates the projection".
    for key in ["desired_release", "release_target", "priority"] {
        obj.entry(key.to_string())
            .or_insert(serde_json::Value::Null);
    }
    serde_json::Value::Object(obj)
}

/// ORDER 582-26mm + 606-e2hg. Filter the FOLDED ledger by status and
/// desired_release (exact), pickup_role (case-insensitive substring),
/// capability_tags (every given tag must be present), then cap at `limit`.
/// Reproduces project-info.sh plan_query's original contract while making the
/// previously ignored release constraint first-class. `limit == 0` is treated
/// as "no cap" so a caller can ask for every match.
fn query_packets<'a>(
    ledger: &'a Ledger,
    status: Option<&str>,
    role: Option<&str>,
    claimable_by: Option<&str>,
    release: Option<&str>,
    tags: &[String],
    limit: usize,
) -> Vec<&'a serde_yaml::Value> {
    ledger
        .packets
        .iter()
        .filter(|p| match status {
            Some(s) => str_field(p, "status") == Some(s),
            None => true,
        })
        // ORDER 632-39p3. `--role` is a SUBSTRING FILTER ON THE FIELD, and both
        // MCP servers document it that way. `next <role>` answers a different
        // question — "what may a host of this role CLAIM" — which additionally
        // includes `pickup_role: any`.
        //
        // Both were being used as if they answered the same question, and the
        // gap was silent and expensive: `query --role macos` returned 13 packets
        // while `next macos` saw 32, so scripts/select-work-batch.sh handed a
        // Windows cycle ONE packet while 56 `any` packets sat unreachable by it.
        // The Linux lane never noticed, because its own role tag covers 131.
        //
        // Resolved by ADDING the missing question rather than redefining the
        // existing one: `--claimable-by` is claimability (role OR `any`),
        // `--role` keeps the documented substring semantics its consumers rely
        // on. Silently widening `--role` would have changed what plan_query
        // reports to every other surface — the same class of unobserved change
        // this packet exists to close.
        .filter(|p| {
            let matches_field = |r: &str| {
                let want = r.to_ascii_lowercase();
                str_field(p, "pickup_role")
                    .map(|pr| pr.to_ascii_lowercase().contains(&want))
                    .unwrap_or(false)
            };
            match (role, claimable_by) {
                (Some(r), _) => matches_field(r),
                (None, Some(c)) => {
                    matches_field(c) || {
                        // `any` must be the WHOLE field, not a substring: a
                        // pickup_role of "company-lane" contains "any" and is
                        // emphatically not claimable by everyone.
                        str_field(p, "pickup_role")
                            .map(|pr| pr.trim().eq_ignore_ascii_case("any"))
                            .unwrap_or(false)
                    }
                }
                (None, None) => true,
            }
        })
        .filter(|p| match release {
            Some(r) => str_field(p, "desired_release") == Some(r),
            None => true,
        })
        .filter(|p| {
            let have = str_list(p, "capability_tags");
            tags.iter().all(|t| have.contains(t))
        })
        // `limit == 0` means UNLIMITED and is load-bearing: drain-queue.sh passes
        // it explicitly so a default cap cannot silently truncate the ready queue.
        // `take` alone expresses that; the filter that used to sit here was
        // `|_| limit == 0 || true`, which is unconditionally true and did nothing.
        .take(if limit == 0 { usize::MAX } else { limit })
        .collect()
}

/// Distinguish "resolves, blocks nothing" from "does not resolve" for the
/// list-shaped queries, which otherwise report both as an empty stdout.
/// Diagnostic only — stdout and the exit code are untouched.
fn warn_if_unresolved(ledger: &Ledger, reference: &str) {
    if ledger.resolve(reference).is_none() {
        eprintln!("warning: {}", unresolved_reason(ledger, reference));
        eprintln!("warning: the empty result below means UNRESOLVED, not 'nothing depends on it'");
    }
}

/// Why a reference did not resolve, distinguishing the two cases a bare
/// "no packet matches" conflates.
///
/// An AMBIGUOUS order (several packets claim it) is not an unknown reference —
/// the order exists, it just does not identify one packet. Reporting that as
/// "no packet matches" tells an agent there is no such work, which is false and
/// is exactly the false-negative class order 516 removed from this surface.
/// Naming the claimants also gives the caller the packet_ids to use instead,
/// which are unique by construction.
fn unresolved_reason(ledger: &Ledger, reference: &str) -> String {
    let claimants = ledger.ambiguous_claimants(reference);
    if claimants.is_empty() {
        return format!("no packet matches '{reference}'");
    }
    format!(
        "'{}' is claimed by {} packets and identifies none of them: {}. \
         Reference one by packet_id — packet_ids are unique, order numbers are not.",
        reference,
        claimants.len(),
        claimants.join(", ")
    )
}

/// ORDER 394d — `grade`. Returns the PROCESS EXIT CODE, kept distinct on
/// purpose:
///   0 — every graded case matched its committed expected answer;
///   1 — at least one case is RED (the harness worked and disagreed);
///   2 — the harness could not run (missing/foreign/empty query set, unknown
///       engine, unreadable corpus).
///
/// Collapsing 1 and 2 is how a grading gate rots into a no-op: "the query set
/// file moved" would then read exactly like "the experts are correct".
fn run_grade(args: &[String], index: &Path) -> i32 {
    let mut index = index.to_path_buf();
    let mut root = root_for(&index);
    let mut root_explicit = false;
    let mut only_case: Option<String> = None;
    let mut envelope_src: Option<String> = None;
    let mut sets: Vec<PathBuf> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--root" => {
                i += 1;
                if let Some(r) = args.get(i) {
                    root = PathBuf::from(r);
                    root_explicit = true;
                }
            }
            // Accepted HERE as well as in the leading position. `--index` is
            // otherwise only legal before the subcommand, and a misplaced one
            // used to be swallowed as a query-set path — a flag that silently
            // becomes a filename is how a grading run ends up reading the
            // wrong ledger.
            "--index" => {
                i += 1;
                if let Some(p) = args.get(i) {
                    index = PathBuf::from(p);
                    if !root_explicit {
                        root = root_for(&index);
                    }
                }
            }
            "--case" => {
                i += 1;
                only_case = args.get(i).cloned();
            }
            "--envelope" => {
                i += 1;
                envelope_src = args.get(i).cloned();
            }
            "--list-engines" => {
                for (name, what) in groundtruth::ENGINES {
                    println!("{name}\t{what}");
                }
                return 0;
            }
            other if other.starts_with('-') => {
                // An UNKNOWN flag is a hard stop, never a positional path: a
                // typo'd `--cases` swallowed as a query-set filename would
                // grade the wrong thing and report it as an ordinary miss.
                eprintln!(
                    "HARNESS ERROR: unknown option {other:?} for `grade` (known: --root, --index, --case, --envelope, --list-engines)"
                );
                return 2;
            }
            other => sets.push(PathBuf::from(other)),
        }
        i += 1;
    }
    if sets.is_empty() {
        sets.push(root.join("openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml"));
    }

    let query_sets = match groundtruth::load_all(&sets) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("HARNESS ERROR: {e}");
            return 2;
        }
    };
    // Each case carries its owning set's declared corpus (order 786-kjke), so
    // a fixture-backed set is graded against the ledger it was written for
    // instead of whatever `--index` the run happened to supply. The pairing is
    // what makes the declaration honourable per-set in a single run.
    let selected: Vec<(&groundtruth::QuerySet, &groundtruth::Case)> = query_sets
        .iter()
        .flat_map(|q| q.cases.iter().map(move |c| (q, c)))
        .filter(|(_, c)| only_case.as_deref().is_none_or(|id| c.id == id))
        .collect();
    if selected.is_empty() {
        eprintln!(
            "HARNESS ERROR: --case {:?} matches no case in {}",
            only_case.unwrap_or_default(),
            sets.iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
        return 2;
    }

    let started = std::time::Instant::now();
    let mut outcomes: Vec<groundtruth::Outcome> = Vec::new();

    if let Some(src) = envelope_src {
        // ENVELOPE MODE: grade a captured envelope — the one an agent actually
        // received, e.g. off the MCP server — against the SAME committed
        // expectation the in-process run uses. Same bar, different transport.
        if selected.len() != 1 {
            eprintln!(
                "HARNESS ERROR: --envelope grades exactly one case; {} are selected (pass --case ID)",
                selected.len()
            );
            return 2;
        }
        let raw = if src == "-" {
            let mut buf = String::new();
            match std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf) {
                Ok(_) => buf,
                Err(e) => {
                    eprintln!("HARNESS ERROR: read envelope from stdin: {e}");
                    return 2;
                }
            }
        } else {
            match std::fs::read_to_string(&src) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("HARNESS ERROR: read envelope {src}: {e}");
                    return 2;
                }
            }
        };
        let envelope: answer::Envelope = match serde_json::from_str(&raw) {
            Ok(e) => e,
            Err(e) => {
                // A malformed envelope is a graded FAILURE, not a harness
                // error: "the tool returned something that is not an envelope"
                // is exactly the order-456 dead-on-arrival regression this
                // harness exists to catch.
                outcomes.push(groundtruth::Outcome {
                    id: selected[0].1.id.clone(),
                    engine: format!("{} (captured envelope)", selected[0].1.engine),
                    failures: vec![format!("input is not an answer envelope: {e}")],
                });
                report(&outcomes, &sets, started);
                return 1;
            }
        };
        outcomes.push(groundtruth::Outcome {
            id: selected[0].1.id.clone(),
            engine: format!("{} (captured envelope)", selected[0].1.engine),
            failures: groundtruth::grade_envelope(&envelope, &selected[0].1.expect, &root),
        });
    } else {
        // One harness PER RESOLVED CORPUS, cached: a set that declares its own
        // ledger is graded against that ledger, everything else against the
        // run's `--index`. Caching matters because Harness memoizes a loaded
        // ledger, and rebuilding it per case would re-read a 22k-line file.
        //
        // A declared corpus fixes BOTH the index and the ROOT for that set.
        // `--index` already implies a root (root_for), because citations are
        // resolved and re-read relative to it — so honouring the index while
        // leaving the root pointing at the checkout would make every fixture
        // citation unresolvable, which is a different false red in place of
        // the one this fixes. The declaration is resolved against the CHECKOUT
        // root, computed independently of `--index` for exactly the same
        // reason: with `--index <fixture>` the run's own root is already the
        // fixture's.
        let checkout_root = root_for(Path::new("plan/index.yaml"));
        let mut harnesses: Vec<(PathBuf, PathBuf, groundtruth::Harness)> = Vec::new();
        let mut announced: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for (set, case) in &selected {
            let set_index = match &set.corpus {
                Some(rel) => checkout_root.join(rel),
                None => index.clone(),
            };
            let set_root = match &set.corpus {
                Some(_) => root_for(&set_index),
                None => root.clone(),
            };
            // Say so when a set's declared corpus is not the run's index. The
            // previous behaviour was to grade against the wrong ledger in
            // silence and report the mismatch as six ordinary FAILs.
            if set_index != index && announced.insert(set.name.clone()) {
                eprintln!(
                    "note: query set {:?} declares corpus {} — grading it against that, not {}",
                    set.name,
                    citation_path(&set_index, &root),
                    citation_path(&index, &root),
                );
            }
            if !set_index.exists() {
                eprintln!(
                    "HARNESS ERROR: query set {:?} declares corpus {} which does not exist",
                    set.name,
                    citation_path(&set_index, &root),
                );
                return 2;
            }
            let slot = harnesses.iter().position(|(p, _, _)| *p == set_index);
            let slot = match slot {
                Some(s) => s,
                None => {
                    let rel = citation_path(&set_index, &set_root);
                    harnesses.push((
                        set_index.clone(),
                        set_root.clone(),
                        groundtruth::Harness::new(set_root.clone(), set_index.clone(), rel),
                    ));
                    harnesses.len() - 1
                }
            };
            let envelope = match harnesses[slot].2.run(case) {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("HARNESS ERROR: {e}");
                    return 2;
                }
            };
            let grade_root = harnesses[slot].1.clone();
            outcomes.push(groundtruth::Outcome {
                id: case.id.clone(),
                engine: case.engine.clone(),
                failures: groundtruth::grade_envelope(&envelope, &case.expect, &grade_root),
            });
        }
    }

    let failed = report(&outcomes, &sets, started);
    i32::from(failed > 0)
}

/// Print the per-case verdicts plus ONE machine-readable summary line, and
/// return the failure count.
fn report(
    outcomes: &[tillandsias_plan::groundtruth::Outcome],
    sets: &[PathBuf],
    started: std::time::Instant,
) -> usize {
    let mut failed = 0;
    for o in outcomes {
        if o.passed() {
            println!("PASS  {}  [{}]", o.id, o.engine);
            continue;
        }
        failed += 1;
        println!("FAIL  {}  [{}]", o.id, o.engine);
        for f in &o.failures {
            println!("        - {f}");
        }
    }
    println!(
        "groundtruth-result: sets={} total={} pass={} fail={} elapsed_ms={}",
        sets.len(),
        outcomes.len(),
        outcomes.len() - failed,
        failed,
        started.elapsed().as_millis()
    );
    failed
}

/// ORDER 582-nqw5. The loop_status overlay commands. `base` is the target
/// document (`plan/loop_status.md` unless `--index` named something else); the
/// fragment store is its `*.d/` sibling, exactly like the index overlay.
fn run_loop_status(args: &[String], base: &Path) {
    match args[0].as_str() {
        "loop-status" => {
            // The READER — the only correct way to read loop_status, for the
            // same reason every ledger read goes through load_with_fragments: a
            // reader that forgets fragments reports a stale status with total
            // confidence.
            for bad in loop_status::malformed(base) {
                eprintln!(
                    "warning: loop_status fragment {} is malformed and was SKIPPED — its contents are not in the view below",
                    bad.display()
                );
            }
            let raw = match std::fs::read_to_string(base) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", base.display());
                    std::process::exit(1);
                }
            };
            match loop_status::fold_text(&raw, &loop_status::load_all(base)) {
                Ok(view) => {
                    // Graceful on a closed pipe: a viewer piped through
                    // `head`/`rg` must not panic mid-stream. Other write
                    // errors are real and reported.
                    use std::io::Write;
                    let mut out = std::io::stdout().lock();
                    match out.write_all(view.as_bytes()) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => {}
                        Err(e) => {
                            eprintln!("error: write stdout: {e}");
                            std::process::exit(1);
                        }
                    }
                }
                Err(e) => {
                    eprintln!("error: fold {}: {e}", base.display());
                    std::process::exit(1);
                }
            }
        }
        "loop-status-fragments" => {
            // Report the overlay's state and whether compaction is eligible.
            // Read-only: compaction itself is a separate, deliberate act.
            let d = loop_status::drift(base);
            println!("{}", d.verdict());
            for f in loop_status::load_all(base) {
                emit(&format!("fragment: {}", f.name));
            }
            for bad in loop_status::malformed(base) {
                emit(&format!("malformed: {}", bad.display()));
            }
        }
        "loop-status-verify" => {
            // ORDER 626-zmhz. The deterministic ACTIVE-RELEASE + count gate:
            // READ-ONLY, so a coordinator runs it every cycle and it fails loud
            // the moment the operator-owned release prose contradicts the FOLDED
            // truth. Two truths are cross-checked:
            //   - the FOLDED loop_status prose: exactly one `## ACTIVE RELEASE:`
            //     heading, exactly one `— ACTIVE`-labeled release bullet, and
            //     that bullet IS the active release;
            //   - the FOLDED plan ledger: the active release's `(N open / M
            //     total tagged)` counts must equal `count_release` over base
            //     plus index.d fragments.
            // `--ledger <path>` overrides the default plan/index.yaml so an
            // isolated fixture can stage both corpora; `--render` prints the
            // canonical count line (the splice a coordinator pastes into the
            // release bullet) even when the check fails.
            let mut ledger_path = PathBuf::from("plan/index.yaml");
            if let Some(i) = args.iter().position(|a| a == "--ledger")
                && let Some(p) = args.get(i + 1)
            {
                ledger_path = PathBuf::from(p);
            }
            let render_only = args.iter().any(|a| a == "--render");

            let raw = match std::fs::read_to_string(base) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", base.display());
                    std::process::exit(1);
                }
            };
            let folded = match loop_status::fold_text(&raw, &loop_status::load_all(base)) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("error: fold {}: {e}", base.display());
                    std::process::exit(1);
                }
            };
            let active = loop_status::active_release(base).unwrap_or_default();
            let problems = loop_status::verify_active_release(&folded, &active);

            let (open, total) = match Ledger::load_with_fragments(&ledger_path) {
                Ok(l) => count_release(&l, &active),
                Err(e) => {
                    eprintln!(
                        "error: load ledger {} for the folded counts: {e}",
                        ledger_path.display()
                    );
                    std::process::exit(1);
                }
            };
            let canonical = loop_status::render_count_line(open, total);

            let headings = loop_status::active_release_headings(&folded);
            let actives = loop_status::release_bullets(&folded)
                .iter()
                .filter(|b| b.active)
                .count();
            let mut count_ok = true;
            // ORDER 668-9z9h. The committed `(N open / M total)` count is a
            // point-in-time snapshot: EVERY subsequently filed release-tagged
            // packet changes the live count, so an exact-match gate went red
            // within half an hour of every green — a treadmill, not a control.
            // The count is now DERIVED live (`canonical` below) and reported as
            // an ADVISORY (`count_ok` in the verdict line + the canonical
            // splice), NOT a gate: count drift alone never fails verify. The
            // STRUCTURAL truths that CAN be wrong — the active-release name, a
            // single `## ACTIVE RELEASE:` heading, a single `— ACTIVE` bullet
            // on the right release — stay hard failures via `verify_active_release`.
            let mut count_advisories: Vec<String> = Vec::new();
            if render_only {
                // `--render` is not a gate: emit the canonical line so a
                // coordinator can splice it, and leave consistency checking to a
                // bare run.
                println!("{canonical}");
                return;
            }
            if let Some(b) = loop_status::release_bullets(&folded)
                .iter()
                .find(|b| b.version == active)
            {
                match (b.open, b.total) {
                    (Some(o), Some(t)) if o == open && t == total => {}
                    (Some(o), Some(t)) => {
                        count_ok = false;
                        count_advisories.push(format!(
                            "active release {active} count drifted — committed ({o} open / {t} total tagged), live is {canonical} (advisory, not a gate — 668-9z9h)"
                        ));
                    }
                    _ => {
                        count_ok = false;
                        count_advisories.push(format!(
                            "active release {active} bullet has no parseable count — live is {canonical} (advisory)"
                        ));
                    }
                }
            }

            let verdict = if problems.is_empty() { "ok" } else { "fail" };
            println!(
                "loop_status: verify active_release={} headings={} actives={} count_ok={} counts=\"{}\" verdict={}",
                if active.is_empty() { "-" } else { &active },
                headings,
                actives,
                if count_ok { "yes" } else { "no" },
                canonical,
                verdict
            );
            for p in &problems {
                eprintln!("problem: {p}");
            }
            // Count drift is surfaced but never gates (668-9z9h): a coordinator
            // splices `canonical` when convenient, and filing a packet in the
            // meantime does not turn a green control red.
            for a in &count_advisories {
                eprintln!("advisory: {a}");
            }
            if !problems.is_empty() {
                std::process::exit(1);
            }
        }
        "loop-status-compact" => {
            // Fold every fragment into the base and delete EXACTLY the ones
            // folded — the same delete-by-name contract as `compact`: never a
            // glob, or a fragment written by another host mid-compaction is
            // silently destroyed.
            let c = match loop_status::compact(base) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!(
                        "error: compaction REFUSED — {e}\n\x20 the base is UNCHANGED and every \
                         fragment is intact — the loop-status view is already transparent, so \
                         nothing is blocked by staying uncompacted"
                    );
                    std::process::exit(1);
                }
            };
            if c.consumed.is_empty() {
                println!("ok: nothing to compact (0 fragments)");
                return;
            }
            // The gate: prose has no YAML to parse, so the structural gate must
            // prove nothing dropped, nothing lost, the operator-owned sections
            // byte-identical, and the fold idempotent — see
            // loop_status::validate_candidate.
            let base_raw = match std::fs::read_to_string(base) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", base.display());
                    std::process::exit(1);
                }
            };
            let fragments = loop_status::load_all(base);
            if let Err(e) = loop_status::validate_candidate(&base_raw, &c.candidate, &fragments) {
                eprintln!(
                    "error: compaction REFUSED — {e}; the base is unchanged and every fragment is intact"
                );
                std::process::exit(1);
            }
            if let Err(e) = std::fs::write(base, &c.candidate) {
                eprintln!("error: write {}: {e}", base.display());
                std::process::exit(1);
            }
            let mut removed = 0usize;
            for p in &c.consumed {
                match std::fs::remove_file(p) {
                    Ok(()) => removed += 1,
                    Err(e) => eprintln!(
                        "warning: could not remove folded fragment {}: {e}",
                        p.display()
                    ),
                }
            }
            println!(
                "ok: compacted {} fragment(s) into {} ({} removed)",
                c.consumed.len(),
                base.display(),
                removed
            );
        }
        "loop-status-append" => {
            // The WRITER surface. Takes one cycle entry on stdin (or --file),
            // validates it (refusing `## Direction` and every other non-cycle
            // heading), and writes it as a NEW fragment file — the concurrent
            // write that used to conflict on the shared base now lands on a
            // per-host path.
            let mut raw = String::new();
            if let Some(i) = args.iter().position(|a| a == "--file")
                && let Some(f) = args.get(i + 1)
            {
                raw = match std::fs::read_to_string(f) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("error: read {}: {e}", f);
                        std::process::exit(1);
                    }
                };
            } else if let Err(e) = std::io::Read::read_to_string(&mut std::io::stdin(), &mut raw) {
                eprintln!("error: read stdin: {e}");
                std::process::exit(1);
            }
            // 719-kgr5: the fragment NAME carries this stamp and fragments fold
            // in name order, so an invented value here reorders the folded
            // status view itself. Validate before compacting.
            let supplied_ts = args
                .iter()
                .position(|a| a == "--ts")
                .and_then(|i| args.get(i + 1))
                .cloned();
            let backfill = args.iter().any(|a| a == "--backfill");
            let ts = loop_status::iso_to_compact(&resolve_ts(
                supplied_ts,
                backfill,
                "loop-status-append",
            ));
            let host = args
                .iter()
                .position(|a| a == "--host")
                .and_then(|i| args.get(i + 1))
                .cloned()
                .unwrap_or_else(resolve_writer_host);
            let suffix = args
                .iter()
                .position(|a| a == "--suffix")
                .and_then(|i| args.get(i + 1))
                .cloned()
                .unwrap_or_else(|| {
                    format!(
                        "{:08x}",
                        std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.subsec_nanos())
                            .unwrap_or(0)
                    )
                });
            match loop_status::append(base, &raw, &ts, &suffix, &host) {
                Ok(path) => println!("ok: wrote {}", path.display()),
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
        other => unknown_subcommand(other),
    }
}

// ── order 547 index I/O helpers (JSONL / JSON, dependency-only serde_json) ───

fn read_chunks(path: &Path) -> Vec<spec::Chunk> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<spec::Chunk>(line) {
            Ok(c) => out.push(c),
            Err(e) => {
                eprintln!(
                    "error: {}:{}: not a chunk record: {e}",
                    path.display(),
                    n + 1
                );
                std::process::exit(1);
            }
        }
    }
    out
}

fn read_chunks_array(path: &Path) -> Vec<spec::Chunk> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    serde_json::from_str::<Vec<spec::Chunk>>(&text).unwrap_or_else(|e| {
        eprintln!(
            "error: {} is not a JSON array of chunks: {e}",
            path.display()
        );
        std::process::exit(1);
    })
}

fn read_vectors(path: &Path) -> Vec<Vec<f32>> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Vec<f32>>(line) {
            Ok(v) => out.push(v),
            Err(e) => {
                eprintln!(
                    "error: {}:{}: not a float vector: {e}",
                    path.display(),
                    n + 1
                );
                std::process::exit(1);
            }
        }
    }
    out
}

fn read_query_vec(path: &Path) -> Vec<f32> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    serde_json::from_str::<Vec<f32>>(text.trim()).unwrap_or_else(|e| {
        eprintln!("error: {} is not a JSON float array: {e}", path.display());
        std::process::exit(1);
    })
}

/// Event type and summary prefix for a `set-field --evidence` write (696-6byc).
///
/// The type must follow the STATUS being written. It was hardcoded to
/// `completed`, harmless while every status worth attaching evidence to was
/// terminal — until the 650-dq6u ladder added the non-terminal `implemented`
/// rung. From then on an honest non-terminal write emitted a fragment claiming
/// completion in the event stream while the status channel said otherwise, and
/// `check-fragment-status-loss.sh` refused it AFTER the write and AFTER a
/// commit. It cost two cycles on this host inside one hour.
fn evidence_event_shape(status: &str) -> (&'static str, String) {
    if tillandsias_plan::is_terminal_status(status) {
        ("completed", format!("status '{status}' with evidence_refs"))
    } else {
        (
            "progress",
            format!("status '{status}' (not terminal) with evidence_refs"),
        )
    }
}

/// ORDER 706-jmi7. Lightweight UTC ISO-8601 timestamp generator without external crate deps.
fn utc_now_iso() -> String {
    let now = std::time::SystemTime::now();
    match now.duration_since(std::time::UNIX_EPOCH) {
        Ok(dur) => {
            let secs = dur.as_secs();
            let s = secs % 60;
            let m = (secs / 60) % 60;
            let h = (secs / 3600) % 24;
            let mut days = (secs / 86400) as i64;

            let mut year = 1970;
            loop {
                let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
                let ydays = if leap { 366 } else { 365 };
                if days < ydays {
                    break;
                }
                days -= ydays;
                year += 1;
            }
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
            let mdays = [
                31,
                if leap { 29 } else { 28 },
                31,
                30,
                31,
                30,
                31,
                31,
                30,
                31,
                30,
                31,
            ];
            let mut month = 1;
            for &dim in &mdays {
                if days < dim {
                    break;
                }
                days -= dim;
                month += 1;
            }
            let day = days + 1;
            format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}Z")
        }
        Err(_) => "unknown".to_string(),
    }
}

/// ORDER 706-jmi7. Record direct CLI invocations to the shared telemetry channel
/// (${TILLANDSIAS_EXPERT_USAGE_LOG:-/tmp/forge-expert-usage.jsonl}).
pub fn log_cli_usage(tool: &str, outcome: &str, latency_ms: u128) {
    if std::env::var_os("TILLANDSIAS_NO_TELEMETRY").is_some() {
        return;
    }
    let log_path = std::env::var("TILLANDSIAS_EXPERT_USAGE_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp/forge-expert-usage.jsonl"));

    let ts = utc_now_iso();
    let line = format!(
        "{{\"ts\":\"{}\",\"server\":\"cli\",\"tool\":\"{}\",\"outcome\":\"{}\",\"latency_ms\":{}}}\n",
        ts, tool, outcome, latency_ms
    );
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        use std::io::Write;
        let _ = file.write_all(line.as_bytes());
    }
}

/// ORDER 816-kq2z. The three `fragment-*` subcommands parse ONE fragment file
/// and never consult the ledger — yet they sat in the main dispatch AFTER
/// `Ledger::load_with_fragments`, which reads a 60,192-line index plus every
/// fragment in plan/index.d.
///
/// MEASURED on macuahuitl 2026-08-18: 133ms per invocation, of which 132ms is
/// that load. `capabilities`, which returns before it, costs 1ms.
///
/// check-fragment-status-loss.sh calls all three once per fragment, so the
/// waste was 3 x 102 x 132ms ~= 40s on EVERY `./build.sh --check`, on every
/// host. It crossed litmus:fragment-status-loss-attribution-shape's 30s step
/// budget when the second and third channels landed (797-qm4t, 812-d45t) —
/// which is why the symptom was a TIMEOUT rather than a wrong answer, and why
/// `--check` (no per-phase budget) stayed green while `--ci-full` went red.
///
/// Returns true when it handled the subcommand; main must return immediately.
/// These arms fall off their own end rather than exiting, so a bool is the
/// safe contract: `std::process::exit` here would skip the stdout flush and
/// can truncate piped output.
/// ORDER 831-ezea. The CARRY-FORWARD GAPS in one fragment: every packet the
/// fragment TOUCHED and LEFT OPEN while naming no next action.
///
/// WHY THIS IS A DISTINCT CHECK. The only blocking exit condition the work loop
/// enforces today is FILING A NEW ROW. Nothing anywhere requires that a cycle
/// which picked a packet up and put it down again leaves that packet resumable,
/// so arrival scales with service: every cycle adds rows and carries none
/// forward. `next_action` is the field the cold-start selector already reads
/// (answer.rs `next_action_snippet` -> the `next:` line of every `plan next`
/// row, since 606-xu52) and it is declared in plan/schema.yaml. Where a packet
/// omits it that reader falls through to handoff_note -> outcome -> title, so
/// the row advertises the packet's own NAME as its next step.
///
/// TOUCHED means the fragment carries an EVENT for the packet — the same
/// definition `fragment-event-packets` uses, deliberately, so "addresses a
/// packet" means one thing across this family. A bare `packets:` definition
/// with no events is a filing, not a touch.
///
/// LEFT OPEN means this fragment does not close the packet. Closure is read
/// from all three channels a fragment can close on: a terminal EVENT type, a
/// terminal `status:` LWW value, and a terminal status on an inline `packets:`
/// declaration. Terminal-set membership is the resolver's
/// ([`tillandsias_plan::is_terminal_status`], 650-dq6u) rather than a literal
/// list — a guard laxer OR wider than the resolver is decorative (649-b2e4),
/// and litmus:terminal-status-vocabulary-shape exists because an earlier guard
/// drifted to `done|completed|retired|obsolete`.
///
/// CLOSURES ARE EXEMPT BY DESIGN, which is the whole reason this is not simply
/// "every packet named in a fragment needs a next_action". A "what would have
/// made this cheaper" note on a terminal row is a dead letter: no selector ever
/// reads that row again, so requiring one would buy nothing and would train
/// filers to write filler.
///
/// CARRIED accepts the two channels a fragment can actually write the field on:
/// a `packets:` entry with `next_action`, and a `status:` LWW entry with
/// `field: next_action`. It does NOT accept a next_action nested inside an
/// EVENT. That shape exists in the corpus — measured 2026-08-19 on
/// plan/index.yaml, 6 event-nested (indent 10) against 65 packet-level (indent
/// 6) — but `next_action_snippet` reads the PACKET field, so an event-nested
/// value is never printed by `plan next`. Accepting it would let a fragment
/// satisfy this check with a value no selector can reach.
///
/// KNOWN LIMIT, stated rather than hidden: a `packets:` entry that RE-declares
/// an existing packet is a G-Set no-op, so a next_action written there on an
/// existing packet is discarded by the fold. This subcommand cannot tell a
/// fresh definition from a re-declaration without loading the ledger, and it
/// must not load the ledger (it lives with the 816-kq2z fragment-only arms for
/// the same 132ms reason). The discarded-declaration class is
/// check-fragment-status-loss.sh's, not this one; the remedy text points at
/// `set-field`, which writes the LWW channel.
///
/// Returns the gap packet_ids, sorted and deduplicated.
fn carry_forward_gaps(doc: &serde_yaml::Value) -> Vec<String> {
    use serde_yaml::Value;
    // Plain `fn`s rather than closures: a closure here infers a single lifetime
    // for the borrow and the returned &str, which does not compile once the
    // result outlives the call. Not a style choice.
    fn text<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
        v.get(k).and_then(Value::as_str)
    }
    fn named(v: &Value, k: &str) -> bool {
        text(v, k).is_some_and(|t| !t.trim().is_empty())
    }

    // A terminal EVENT: `type: completed` at the entry, or nested under
    // `event:` as a scalar or a mapping. Same three shapes
    // `fragment-terminal-events` accepts (752-pst5), widened from `completed`
    // alone to the whole closure ladder because a fragment that closes a packet
    // straight to `verified` or `done` has closed it just as finally. All four
    // ladder words are live event types in the corpus (measured 2026-08-19:
    // completed 550, verified 60, done 3, obsoleted 1).
    let terminal_event = |event: &Value| -> bool {
        let terminal = |t: Option<&str>| t.is_some_and(tillandsias_plan::is_terminal_status);
        if terminal(text(event, "type")) {
            return true;
        }
        if let Some(inner) = event.get("event")
            && (terminal(inner.as_str()) || terminal(text(inner, "type")))
        {
            return true;
        }
        false
    };

    let mut touched: Vec<String> = Vec::new();
    let mut closed: Vec<String> = Vec::new();
    let mut carried: Vec<String> = Vec::new();

    // Inline: packets: [{packet_id, status, next_action, events: [...]}]
    if let Some(pkts) = doc.get("packets").and_then(Value::as_sequence) {
        for p in pkts {
            let Some(pid) = text(p, "packet_id") else {
                continue;
            };
            let events = p.get("events").and_then(Value::as_sequence);
            if events.is_some_and(|evs| !evs.is_empty()) {
                touched.push(pid.to_string());
            }
            if events.is_some_and(|evs| evs.iter().any(&terminal_event)) {
                closed.push(pid.to_string());
            }
            if text(p, "status").is_some_and(tillandsias_plan::is_terminal_status) {
                closed.push(pid.to_string());
            }
            if named(p, "next_action") {
                carried.push(pid.to_string());
            }
        }
    }

    // Top-level: events: [{packet_id, event: {...}}] — declares without
    // creating, so this is the shape a cycle uses to put a packet down.
    if let Some(evs) = doc.get("events").and_then(Value::as_sequence) {
        for e in evs {
            let Some(pid) = text(e, "packet_id") else {
                continue;
            };
            if e.get("event").is_none() {
                // A misplaced DEFINITION under `events:` (812-d45t), not an
                // event. Its own subcommand reports it; counting it as a touch
                // here would put one authoring mistake in two advisories.
                continue;
            }
            touched.push(pid.to_string());
            if terminal_event(e) {
                closed.push(pid.to_string());
            }
        }
    }

    // The LWW channel. `field:` is ANY field, not just status — the key is
    // misnamed and plan/index.d/README.md says so.
    if let Some(sts) = doc.get("status").and_then(Value::as_sequence) {
        for s in sts {
            let Some(pid) = text(s, "packet_id") else {
                continue;
            };
            match text(s, "field") {
                Some("status")
                    if text(s, "value").is_some_and(tillandsias_plan::is_terminal_status) =>
                {
                    closed.push(pid.to_string());
                }
                Some("next_action") if named(s, "value") => {
                    carried.push(pid.to_string());
                }
                _ => {}
            }
        }
    }

    let mut gaps: Vec<String> = touched
        .into_iter()
        .filter(|pid| !closed.contains(pid) && !carried.contains(pid))
        .collect();
    gaps.sort_unstable();
    gaps.dedup();
    gaps
}

fn dispatch_fragment_only(subcommand: &str, args: &[String]) -> bool {
    match subcommand {
        "carry-forward-check" => {
            // ORDER 831-ezea. See [`carry_forward_gaps`] for the contract. This
            // arm is IO only: read, parse, print one packet_id per line, exit 0.
            //
            // ADVISORY BY DESIGN — exit 0 even with gaps. Measured 2026-08-19,
            // next_action adoption across the fold is 4.6% of ready rows (65
            // packet-level values in plan/index.yaml). A hard refusal at that
            // adoption would reject essentially every fragment the fleet writes
            // tonight, and a gate that blocks everyone on its first night is
            // switched off within a day. The caller
            // (scripts/check-carry-forward.sh) prints the advisory and exits 0;
            // the promotion threshold is recorded there.
            //
            // Exit 3 on an unparseable fragment, identically to its three
            // siblings: silence from a parser is not evidence of absence
            // (787-f7dh), and "this fragment carries every packet forward" must
            // never be the same answer as "this fragment could not be read".
            const EXIT_FRAGMENT_UNPARSEABLE: i32 = 3;
            let Some(path) = args.get(1) else {
                eprintln!("usage: tillandsias-plan carry-forward-check <fragment.yaml>");
                std::process::exit(2);
            };
            let raw = match std::fs::read_to_string(path) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {path}: {e}");
                    std::process::exit(2);
                }
            };
            let doc: serde_yaml::Value = match serde_yaml::from_str(&raw) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!(
                        "unparseable:{path}: {e} — the carry-forward pass cannot read this fragment, so any packet it leaves open is UNEXAMINED (831-ezea)"
                    );
                    std::process::exit(EXIT_FRAGMENT_UNPARSEABLE);
                }
            };
            for id in carry_forward_gaps(&doc) {
                emit(&id);
            }
            true
        }
        "fragment-misplaced-definitions" => {
            // ORDER 812-d45t. A PACKET DEFINITION written under the top-level
            // `events:` key instead of `packets:` is accepted by every gate and
            // then dropped entirely. Measured 2026-08-18: a closure fragment
            // filed three follow-up packets that way; `./build.sh --check` was
            // rc=0, the fragment's own status transition folded correctly, and
            // all three packets simply did not exist. The author found it only
            // by asking for the packets back afterwards.
            //
            // It is a different hole from 797-qm4t. There the packet_id named
            // nothing; here the entry is a well-formed definition sitting under
            // the wrong key, so no packet_id is even claimed — the
            // unknown-packet check cannot see it, and neither can the
            // terminal-event or status-block checks, because it declares
            // neither.
            //
            // THE SIGNATURE IS UNAMBIGUOUS: an entry under `events:` that has
            // NO `event:` key but DOES carry definition fields (order, title,
            // kind, deliverable). A real event entry always nests `event:`; a
            // real definition never appears here. Requiring a definition field
            // rather than merely "no event key" keeps a malformed-but-intended
            // event from being reported as a lost packet.
            const EXIT_FRAGMENT_UNPARSEABLE: i32 = 3;
            let Some(path) = args.get(1) else {
                eprintln!("usage: tillandsias-plan fragment-misplaced-definitions <fragment.yaml>");
                std::process::exit(2);
            };
            let raw = match std::fs::read_to_string(path) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {path}: {e}");
                    std::process::exit(2);
                }
            };
            let doc: serde_yaml::Value = match serde_yaml::from_str(&raw) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!(
                        "unparseable:{path}: {e} — the misplaced-definition pass cannot read this fragment, so any packet it drops is UNEXAMINED (812-d45t)"
                    );
                    std::process::exit(EXIT_FRAGMENT_UNPARSEABLE);
                }
            };
            let mut ids: Vec<String> = Vec::new();
            if let Some(evs) = doc.get("events").and_then(serde_yaml::Value::as_sequence) {
                for e in evs {
                    if e.get("event").is_some() {
                        continue;
                    }
                    let looks_like_definition = ["order", "title", "kind", "deliverable"]
                        .iter()
                        .any(|k| e.get(*k).is_some());
                    if !looks_like_definition {
                        continue;
                    }
                    let pid = e
                        .get("packet_id")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("<no packet_id>");
                    ids.push(pid.to_string());
                }
            }
            ids.sort_unstable();
            ids.dedup();
            for id in ids {
                emit(&id);
            }
            true
        }
        "fragment-event-packets" => {
            // ORDER 797-qm4t. Sibling of fragment-terminal-events, and the reason
            // it exists is a loss I caused and then measured.
            //
            // The unknown-packet_id checks added on the status and terminal-event
            // channels close the cases where a fragment CLAIMS a closure. They
            // cannot see a NON-TERMINAL event — `note`, `progress`, `filed` —
            // addressed to a packet_id the fold has never heard of. That event is
            // dropped in total silence: the fold ignores it, the loss guard skips
            // it, and every validator still answers ok.
            //
            // Measured 2026-08-17: fragment 20260817t184639z carried a `note`
            // event with the full GPU-passthrough measurements for order 406,
            // addressed to `inference-gpu-passthrough-fat-host-thinnest-rung` —
            // a plausible id I invented rather than asked for. The real one is
            // `inference-cuda-bringup-fat-host`. The note is on disk, is not in
            // the fold, and is not on 406. Nothing reported it; the guard said
            // ok:no-fragment-status-loss over a corpus containing it.
            //
            // Prints EVERY packet_id an events block addresses, whatever the type
            // (sorted, deduplicated), so the caller can ask the one question this
            // subcommand exists for: does the fold know this packet at all. Same
            // parse and the same exit 3 on an unparseable fragment, because
            // silence from a parser is not evidence of absence (787-f7dh).
            const EXIT_FRAGMENT_UNPARSEABLE: i32 = 3;
            let Some(path) = args.get(1) else {
                eprintln!("usage: tillandsias-plan fragment-event-packets <fragment.yaml>");
                std::process::exit(2);
            };
            let raw = match std::fs::read_to_string(path) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {path}: {e}");
                    std::process::exit(2);
                }
            };
            let doc: serde_yaml::Value = match serde_yaml::from_str(&raw) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!(
                        "unparseable:{path}: {e} — the unknown-packet pass cannot read this fragment, so any event it addresses is UNEXAMINED (797-qm4t)"
                    );
                    std::process::exit(EXIT_FRAGMENT_UNPARSEABLE);
                }
            };
            let mut ids: Vec<String> = Vec::new();
            // Inline: packets: [{packet_id, events: [...]}]. A pid here also
            // CREATES the packet, so it can never be unknown — collected anyway
            // so the caller sees one consistent set and decides for itself.
            if let Some(pkts) = doc.get("packets").and_then(serde_yaml::Value::as_sequence) {
                for p in pkts {
                    let Some(pid) = p.get("packet_id").and_then(serde_yaml::Value::as_str) else {
                        continue;
                    };
                    if p.get("events")
                        .and_then(serde_yaml::Value::as_sequence)
                        .is_some_and(|evs| !evs.is_empty())
                    {
                        ids.push(pid.to_string());
                    }
                }
            }
            // Top-level: events: [{packet_id, event: {...}}] — the shape that
            // declares WITHOUT creating, and therefore the one that can address
            // a packet nobody has ever filed.
            if let Some(evs) = doc.get("events").and_then(serde_yaml::Value::as_sequence) {
                for e in evs {
                    let Some(pid) = e.get("packet_id").and_then(serde_yaml::Value::as_str) else {
                        continue;
                    };
                    if e.get("event").is_some() {
                        ids.push(pid.to_string());
                    }
                }
            }
            ids.sort_unstable();
            ids.dedup();
            for id in ids {
                emit(&id);
            }
            true
        }
        "fragment-terminal-events" => {
            // ORDER 752-pst5. The closure-event pass of check-fragment-status-loss.sh
            // reads every fragment in plan/index.d and asks, per packet: does its
            // events block DECLARE a terminal `completed` event? The shell's old
            // answer was a line-grep with ad-hoc resets, and it could not tell an
            // event declaration from PROSE that quotes the marker inside a block
            // scalar — it invented a completion for packet 751-i9mb whose real
            // event was `type: filed` (752-pst5). A YAML parse bounds attribution
            // to the actual events block, so no indent heuristic can silently
            // disable or widen the check.
            //
            // Prints one packet_id per line (sorted, deduplicated), nothing else
            // on stdout, exit 0.
            //
            // ORDER 787-f7dh. An unparseable fragment used to `return` here —
            // a stderr note and exit 0, on the reasoning that parse failures
            // are the sibling added-fragments-parse gate's job. That made
            // "this fragment declares no terminal events" and "this fragment
            // could not be read" the SAME answer to the caller: empty stdout,
            // exit 0. The caller (check-fragment-status-loss.sh) additionally
            // sent stderr to /dev/null, so the note reached nobody and a
            // fragment carrying an undelivered closure passed the gate green.
            // Found when the 785-sqe6 fixture wrote `": "` into a summary,
            // silently invalidating its own YAML.
            //
            // The delegation was also an ASSUMPTION rather than a guarantee:
            // added-fragments-parse is DIFF-SCOPED (698-7n6q), so a malformed
            // fragment arriving by merge, hand edit, sibling branch, or one
            // already present before that gate landed is never seen by it.
            // Exit 3 makes the two cases distinguishable at the point of use;
            // silence from a parser is not evidence of absence.
            const EXIT_FRAGMENT_UNPARSEABLE: i32 = 3;
            let Some(path) = args.get(1) else {
                eprintln!("usage: tillandsias-plan fragment-terminal-events <fragment.yaml>");
                std::process::exit(2);
            };
            let raw = match std::fs::read_to_string(path) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {path}: {e}");
                    std::process::exit(2);
                }
            };
            let doc: serde_yaml::Value = match serde_yaml::from_str(&raw) {
                Ok(d) => d,
                Err(e) => {
                    // Distinguishable, and stdout stays EMPTY so no caller can
                    // mistake a parse failure for a set of declarations.
                    eprintln!(
                        "unparseable:{path}: {e} — the closure-event pass cannot read this fragment, so any terminal event it declares is UNEXAMINED (787-f7dh)"
                    );
                    std::process::exit(EXIT_FRAGMENT_UNPARSEABLE);
                }
            };
            // A `declares` entry: the event carries `type: completed`, or nests
            // `event: completed` / `event: {type: completed}` (the shapes the old
            // awk reached via `/type: completed/ || /event: completed/`).
            let declares_terminal = |event: &serde_yaml::Value| -> bool {
                if event.get("type").and_then(serde_yaml::Value::as_str) == Some("completed") {
                    return true;
                }
                if let Some(inner) = event.get("event")
                    && (inner.as_str() == Some("completed")
                        || inner.get("type").and_then(serde_yaml::Value::as_str)
                            == Some("completed"))
                {
                    return true;
                }
                false
            };
            let mut ids: Vec<String> = Vec::new();
            // Inline: packets: [{packet_id, events: [{type: completed, ...}]}]
            if let Some(pkts) = doc.get("packets").and_then(serde_yaml::Value::as_sequence) {
                for p in pkts {
                    let Some(pid) = p.get("packet_id").and_then(serde_yaml::Value::as_str) else {
                        continue;
                    };
                    let declares = p
                        .get("events")
                        .and_then(serde_yaml::Value::as_sequence)
                        .is_some_and(|evs| evs.iter().any(declares_terminal));
                    if declares {
                        ids.push(pid.to_string());
                    }
                }
            }
            // Top-level: events: [{packet_id, event: {type: completed, ...}}]
            if let Some(evs) = doc.get("events").and_then(serde_yaml::Value::as_sequence) {
                for e in evs {
                    let Some(pid) = e.get("packet_id").and_then(serde_yaml::Value::as_str) else {
                        continue;
                    };
                    if e.get("event").is_some_and(declares_terminal) {
                        ids.push(pid.to_string());
                    }
                }
            }
            ids.sort_unstable();
            ids.dedup();
            for id in ids {
                emit(&id);
            }
            true
        }
        _ => false,
    }
}

fn main() {
    let start_time = std::time::Instant::now();
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut index = PathBuf::from("plan/index.yaml");
    let mut index_explicit = false;
    if args.first().map(String::as_str) == Some("--index") {
        args.remove(0);
        if args.is_empty() {
            usage();
        }
        index = PathBuf::from(args.remove(0));
        index_explicit = true;
    }
    if args.is_empty() {
        usage();
    }
    let subcommand = args.first().cloned().unwrap_or_else(|| "none".to_string());

    // ORDER 569. `capabilities` runs FIRST and touches nothing — no ledger, no
    // methodology corpus, no filesystem at all beyond the embedded manifest.
    //
    // That is the whole point: the forge wrapper asks a binary what it can do
    // BEFORE it knows whether an index exists, and on a checkout whose plan
    // ledger may be broken or absent. A capability probe that could fail for an
    // unrelated reason would be indistinguishable from a stale binary, which is
    // exactly the ambiguity this order exists to remove.
    //
    // STDOUT CARRIES ONLY THE TOKENS, one per line, exit 0. The shell side
    // validates that shape (`^[a-z][a-z0-9-]*$`) and treats anything else —
    // a usage dump, a warning, an empty stream — as "this binary predates the
    // manifest", which is its own named state rather than a guess.
    if args[0] == "capabilities" {
        for token in capability_tokens() {
            emit(token);
        }
        // ORDER 583-dv9n. Report dispatch arms the manifest omits — WARNING,
        // never a gate, on stderr only. stdout still carries exactly the
        // tokens, so the shell-side shape check (and the fail-safe under-report
        // the wrapper relies on) are untouched; the omission just stops being
        // silent. An empty drift here is the audited-clean state.
        for arm in manifest_drift() {
            eprintln!(
                "warning: dispatch arm '{arm}' is not listed in capabilities.txt — the MCP \
                 wrapper cannot route to it. Declare it in capabilities.txt or justify its \
                 absence (order 583-dv9n)."
            );
        }
        return;
    }

    // ORDER 394b. `verify-answer` deliberately runs BEFORE the ledger is
    // loaded: it audits an envelope's citations against the CHECKOUT, and a
    // verifier that needed the corpus it is auditing could not be pointed at
    // an envelope captured elsewhere.
    if args[0] == "verify-answer" {
        let mut root = root_for(&index);
        let mut root_explicit = false;
        if let Some(i) = args.iter().position(|a| a == "--root")
            && let Some(r) = args.get(i + 1)
        {
            root = PathBuf::from(r);
            root_explicit = true;
        }
        let mut raw = String::new();
        if let Err(e) = std::io::Read::read_to_string(&mut std::io::stdin(), &mut raw) {
            eprintln!("error: read stdin: {e}");
            std::process::exit(1);
        }
        let envelope: answer::Envelope = match serde_json::from_str(&raw) {
            Ok(e) => e,
            Err(e) => {
                // A malformed envelope is a FAILED verification, never a pass.
                eprintln!("REFUSED: input is not an answer envelope: {e}");
                std::process::exit(1);
            }
        };
        if !root_explicit && let Some(r) = envelope.citation_root() {
            root = PathBuf::from(r);
        }
        // ORDER 801-g9nn. The reader-side audit, not the frame-blind `verify`:
        // this is the ONE place that knows both the envelope's frame and the
        // reader's, so it is the only place that can tell a fabricated citation
        // from a citation the reader has simply not fetched yet.
        let audit = answer::audit(&envelope, &root);
        if audit.violations.is_empty() && audit.stale.is_empty() {
            // FIRST LINE IS PINNED. Litmus steps and MCP wrappers grep
            // '^ok: envelope verified'; the relation is additive below it.
            println!(
                "ok: envelope verified — {} citation(s) resolve, confidence={:?}",
                envelope.citations().len(),
                envelope.confidence()
            );
            println!("{}", audit.relation.render());
            // RESOLVING HERE IS NOT THE SAME AS HAVING BEEN READ HERE. Every
            // span matched, but if the answer's frame is one this checkout
            // cannot reach, that match is unconfirmed: the line numbers may
            // land on a DIFFERENT passage that happens to contain the same key.
            // The `ok:` prefix stays pinned for the consumers that grep it; the
            // caution is what stops it being read as "safe to open".
            if audit.relation.relation().may_differ() {
                println!(
                    "caution: the spans matched here, but this checkout is NOT the frame they were read in"
                );
            }
            return;
        }
        if audit.violations.is_empty() {
            // SOUND THERE, WRONG HERE. Exit 3, deliberately neither 0 nor 1: a
            // reader that treats this as a pass opens stale line numbers, and a
            // reader that treats it as a refusal throws away a correct answer
            // plus the fetch instruction that would fix it. It needs its own
            // code because it needs its own response.
            println!(
                "stale: envelope is sound at its own frame but NOT in this checkout — {} citation(s) moved",
                audit.stale.len()
            );
            println!("{}", audit.relation.render());
            for s in &audit.stale {
                println!("  stale: {s}");
            }
            std::process::exit(3);
        }
        eprintln!("REFUSED: {} citation violation(s):", audit.violations.len());
        for v in &audit.violations {
            eprintln!("  violation: {v}");
        }
        for s in &audit.stale {
            eprintln!("  stale: {s}");
        }
        eprintln!("{}", audit.relation.render());
        std::process::exit(1);
    }

    // ORDER 394d. `grade` runs BEFORE the ledger load for the same reason
    // `verify-answer` does: it owns its corpora (it loads each at most once and
    // reuses it across cases), and a query set that grades only the methodology
    // corpus must still run in a checkout whose plan ledger is broken.
    if args[0] == "grade" {
        std::process::exit(run_grade(&args[1..], &index));
    }

    // ORDER 394c. The methodology corpus is a DIFFERENT corpus from the plan
    // ledger, so these subcommands run before (and independently of) the
    // ledger load — a checkout with a broken or absent plan/index.yaml must
    // still be able to answer a runtime-language-policy question.
    //
    // (Deliberately NOT spelling that question out here: order 394b's
    // no-python litmus step word-greps this file, and the canonical question
    // this engine answers names the very interpreter the policy bans. The
    // question itself lives in methodology.rs::CANONICAL_QUESTIONS, whose
    // no-interpreter guarantee is asserted structurally instead — the module
    // spawns no subprocess at all.)
    if args[0].starts_with("methodology") {
        let mut root = root_for(&index);
        let mut file_filter: Option<String> = None;
        let mut rest: Vec<String> = Vec::new();
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--root" => {
                    i += 1;
                    if let Some(r) = args.get(i) {
                        root = PathBuf::from(r);
                    }
                }
                "--file" => {
                    i += 1;
                    file_filter = args.get(i).cloned();
                }
                other => rest.push(other.to_string()),
            }
            i += 1;
        }
        let corpus = match methodology::Corpus::load(&root) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        };
        for (file, err) in corpus.parse_errors() {
            eprintln!("warning: {file} does not parse as YAML ({err}) — its spans are suspect");
        }
        if args[0] == "methodology-index" {
            for f in &corpus.files {
                for e in &f.entries {
                    println!("{}:{}-{}\t{}", f.rel, e.line_start, e.line_end, e.path);
                }
            }
            return;
        }
        let query = rest.join(" ");
        // EXIT 0 EVEN WHEN UNSUPPORTED, for the same reason `answer` does: the
        // MCP wrapper runs under `set -e` and the envelope IS the signal.
        let envelope = match args[0].as_str() {
            "methodology" => {
                methodology::answer_path_query(&corpus, &query, file_filter.as_deref())
            }
            "methodology-ask" => {
                methodology::answer_question(&corpus, &query, file_filter.as_deref())
            }
            // Order 569: `methodology-<something-we-do-not-have>` is an
            // INCAPABILITY, not a malformed invocation. Saying so is what lets a
            // caller tell a stale artifact from a bad question.
            other => unknown_subcommand(other),
        };
        // ORDER 523 (R2): self-verify before emitting. The methodology corpus
        // root IS the checkout, so citations resolve against `root`.
        // No ledger is loaded on this path, so there is nothing skipped to report.
        emit_verified_envelope(envelope, &root, &[]);
        return;
    }

    // ORDER 547. The whole-spec RAG corpus (openspec/specs + cheatsheets +
    // methodology) is a DIFFERENT corpus from the plan ledger, so — like
    // `methodology` — these run before (and independently of) the ledger load.
    // The crate stays network-free: `spec-index` chunks, `spec-retrieve` does
    // cosine top-k over caller-supplied embeddings, `spec-envelope` builds a
    // verifiable answer envelope. Embedding + synthesis are the caller's shell
    // job over `/v1`.
    if args[0].starts_with("spec-") {
        let mut root = root_for(&index);
        let mut out: Option<PathBuf> = None;
        let mut index_dir: Option<PathBuf> = None;
        let mut query_vec: Option<PathBuf> = None;
        let mut chunks_json: Option<PathBuf> = None;
        let mut answer_file: Option<PathBuf> = None;
        // ORDER 801-g9nn — the commit the INDEX was built at, which for a
        // retrieved answer is the frame the spans were read in and is NOT this
        // process's HEAD. A shared, mirror-backed index (801-a2by) is routinely
        // built by another harness at another commit; without this flag the
        // envelope would stamp the reader's own HEAD onto spans it never read
        // there, which is a worse lie than no stamp at all.
        let mut corpus_commit: Option<String> = None;
        let mut k = 8usize;
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--root" => {
                    i += 1;
                    if let Some(r) = args.get(i) {
                        root = PathBuf::from(r);
                    }
                }
                "--out" => {
                    i += 1;
                    out = args.get(i).map(PathBuf::from);
                }
                "--index-dir" => {
                    i += 1;
                    index_dir = args.get(i).map(PathBuf::from);
                }
                "--query-vec" => {
                    i += 1;
                    query_vec = args.get(i).map(PathBuf::from);
                }
                "--chunks-json" => {
                    i += 1;
                    chunks_json = args.get(i).map(PathBuf::from);
                }
                "--answer-file" => {
                    i += 1;
                    answer_file = args.get(i).map(PathBuf::from);
                }
                "--corpus-commit" => {
                    i += 1;
                    corpus_commit = args.get(i).cloned();
                }
                "--k" => {
                    i += 1;
                    if let Some(v) = args.get(i) {
                        k = v.parse().unwrap_or(8);
                    }
                }
                other => {
                    eprintln!("error: unknown flag for {}: {other}", args[0]);
                    std::process::exit(2);
                }
            }
            i += 1;
        }

        match args[0].as_str() {
            "spec-index" => {
                let Some(out_dir) = out else {
                    eprintln!("error: spec-index requires --out <dir>");
                    std::process::exit(2);
                };
                if let Err(e) = std::fs::create_dir_all(&out_dir) {
                    eprintln!("error: cannot create {}: {e}", out_dir.display());
                    std::process::exit(1);
                }
                let chunks = spec::chunk_corpus(&root);
                let chunks_path = out_dir.join("chunks.jsonl");
                let mut body = String::new();
                for c in &chunks {
                    match serde_json::to_string(c) {
                        Ok(line) => {
                            body.push_str(&line);
                            body.push('\n');
                        }
                        Err(e) => {
                            eprintln!("error: serialize chunk {}: {e}", c.id);
                            std::process::exit(1);
                        }
                    }
                }
                if let Err(e) = std::fs::write(&chunks_path, body) {
                    eprintln!("error: write {}: {e}", chunks_path.display());
                    std::process::exit(1);
                }
                println!(
                    "spec-index: {} chunks -> {}",
                    chunks.len(),
                    chunks_path.display()
                );
                return;
            }
            "spec-retrieve" => {
                let Some(dir) = index_dir else {
                    eprintln!("error: spec-retrieve requires --index-dir <dir>");
                    std::process::exit(2);
                };
                let Some(qv) = query_vec else {
                    eprintln!("error: spec-retrieve requires --query-vec <file>");
                    std::process::exit(2);
                };
                let chunks = read_chunks(&dir.join("chunks.jsonl"));
                let vectors = read_vectors(&dir.join("vectors.jsonl"));
                if chunks.len() != vectors.len() {
                    eprintln!(
                        "error: index is inconsistent — {} chunks but {} vectors (re-run spec-index + embed)",
                        chunks.len(),
                        vectors.len()
                    );
                    std::process::exit(1);
                }
                let query = read_query_vec(&qv);
                let top = spec::top_k(&query, &vectors, k);
                // ORDER 821-73es. The score used to be dropped here, which is
                // why nothing downstream could tell "the corpus covers this"
                // from "the corpus was searched": cosine top-k always returns
                // k, so an out-of-corpus question yields k confident-looking
                // citations. Carrying the similarity is the prerequisite for
                // any refusal — a threshold cannot be applied to a number that
                // was thrown away.
                let selected: Vec<spec::ScoredChunk> = top
                    .iter()
                    .map(|(idx, score)| spec::ScoredChunk {
                        chunk: chunks[*idx].clone(),
                        score: *score,
                    })
                    .collect();
                match serde_json::to_string_pretty(&selected) {
                    Ok(s) => println!("{s}"),
                    Err(e) => {
                        eprintln!("error: serialize retrieval result: {e}");
                        std::process::exit(1);
                    }
                }
                return;
            }
            "spec-envelope" => {
                let Some(cj) = chunks_json else {
                    eprintln!("error: spec-envelope requires --chunks-json <file>");
                    std::process::exit(2);
                };
                let chunks = read_chunks_array(&cj);
                let answer = match &answer_file {
                    Some(f) => std::fs::read_to_string(f).unwrap_or_default(),
                    None => {
                        let mut buf = String::new();
                        let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf);
                        buf
                    }
                };
                let mut envelope = spec::build_envelope(answer.trim(), &chunks, &root);
                // ORDER 801-g9nn. Applied BEFORE `emit_verified_envelope`, whose
                // own default stamp only fills citations that still have no
                // frame — so the index's commit wins over this process's HEAD
                // wherever the two differ, which is the whole point.
                if let Some(sha) = corpus_commit.as_deref() {
                    envelope = envelope.with_default_citation_commit(sha.trim());
                }
                // Spec corpus, not the ledger: nothing skipped to report here.
                emit_verified_envelope(envelope, &root, &[]);
                return;
            }
            other => {
                eprintln!("error: unknown spec subcommand '{other}'");
                std::process::exit(2);
            }
        }
    }

    // ORDER 582-nqw5. The loop_status overlay is a DIFFERENT corpus from the
    // plan ledger — prose, not keyed records — so its commands run before (and
    // independently of) the ledger load: a checkout with a broken
    // plan/index.yaml must still be able to read, append, and compact its
    // loop_status. The target defaults to plan/loop_status.md unless `--index`
    // named something else explicitly.
    if matches!(
        args[0].as_str(),
        "loop-status"
            | "loop-status-append"
            | "loop-status-compact"
            | "loop-status-fragments"
            | "loop-status-verify"
    ) {
        let base = if index_explicit {
            index.clone()
        } else {
            PathBuf::from(loop_status::DEFAULT_BASE)
        };
        run_loop_status(&args, &base);
        return;
    }

    // FRAGMENT-AWARE by default. Every read path must go through the same
    // overlay: a reader that forgets fragments reports a stale ledger with total
    // confidence, and if the CLI, the MCP server and the expert disagree about
    // what the plan says, the retrieval surface is worse than useless.
    // ORDER 816-kq2z: handled BEFORE the ledger load below, which these
    // three never use and which costs 132ms of their 133ms.
    if dispatch_fragment_only(&subcommand, &args) {
        return;
    }

    let ledger = match Ledger::load_with_fragments(&index) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };
    // A fragment that cannot be parsed is SKIPPED so one bad file never makes
    // the whole plan unreadable — but skipping it quietly would lose filed work
    // with no signal, which this project refuses on principle.
    //
    // ORDER 796-4ydb — THE WARNING IS NOT THE FIX, AND USED TO BE THE WHOLE OF
    // IT. This loop printed exactly this sentence and the process exited 0, so
    // `plan_answer`, `plan_next`, the batch selector, burndown and every
    // closure check answered from a ledger they had been TOLD was partial, at
    // full confidence. The sentence stays — it is how the defect was found —
    // but it is now the human rendering of a typed condition the fold carries
    // (`Ledger::skipped_fragments`), and the two surfaces that can act on it do:
    //
    //   * `check` NAMES the file on stdout and downgrades its verdict from
    //     `ok:` to `incomplete:`, and refuses — exit 3 — only under
    //     `--strict-fragments`. The release preflight and the plan-only push
    //     lane opt in; `build.sh` does not, because it runs on every host.
    //   * `answer` / `next` DEGRADE BUT REPORT: the envelope carries
    //     `skipped_sources`, so an MCP client can see the answer is drawn from
    //     a partial corpus without parsing stderr prose.
    //
    // WHY NOT REFUSE EVERYWHERE. Two reasons, and 699-dycj states the second as
    // a design constraint on anyone who touches this. First, the tooling needed
    // to FIX a bad fragment is this same binary, and the agents doing the
    // fixing bootstrap by asking the plan what to do — a reader that hard-fails
    // would wedge every host on the one file nobody can then look up. Second,
    // an unconditional refusal turns one host's typo into every other host's
    // red build, converting a local error into a fleet outage.
    //
    // Read from the LEDGER, not by re-scanning: the fold already listed what it
    // skipped, and a second scan of a directory other hosts append to can
    // disagree with the first.
    for bad in ledger.skipped_fragments() {
        eprintln!(
            "warning: ledger fragment {} does not parse and was SKIPPED — its contents are not in the answers below",
            bad.display()
        );
    }

    let schema_path = index
        .parent()
        .map(|d| d.join("schema.yaml"))
        .unwrap_or_else(|| PathBuf::from("plan/schema.yaml"));
    let schema = Schema::load(&schema_path).unwrap_or_else(|_| Schema::minimal());

    match args[0].as_str() {
        "capability-matrix" => {
            // ORDER 808-7yrd. The fleet capability matrix, folded from the
            // `capabilities:` channel of the SAME fragments every other channel
            // uses.
            //
            // NOT named `capabilities` — that arm is taken by order 569 and
            // reports this BINARY's subcommand set. Two meanings of the word,
            // and a reader who conflates them gets a confident wrong answer.
            //
            // One line per host, then its schedulable triples. `legacy_tier` is
            // printed as DERIVED context, never as the routing input: a single
            // string cannot express "GPU present, no lane", which is the state
            // every WSL2 host is in.
            let frags = tillandsias_plan::fragments::load_all(&index);
            let (matrix, skipped) = tillandsias_plan::fragments::fold_capabilities(&frags);
            if matrix.is_empty() {
                println!("capability-matrix: 0 rows (no `capabilities:` rows in any fragment)");
            }
            for ((host_id, locus), entry) in &matrix {
                let kind = entry.document["host"]["host_kind"]
                    .as_str()
                    .unwrap_or("unknown");
                let source = entry.document["host"]["host_id_source"]
                    .as_str()
                    .unwrap_or("unknown");
                let tier = entry.document["legacy_tier"].as_str().unwrap_or("unknown");
                println!(
                    "host:{host_id}\tlocus:{locus}\tkind:{kind}\tid_source:{source}\tderived_tier:{tier}\tts:{}\twriter:{}\tfrom:{}",
                    entry.ts, entry.host, entry.source
                );
                // Machine RAM, when the contributing context knows it. This is
                // deliberately NOT a field on the Rust `HostInfo` (adding one
                // would give a second home to a value DeviceRecord already
                // owns), so without printing it here the number is carried in
                // the ledger and visible to nobody — the write-only field this
                // milestone keeps collecting. Printing it is the cheap half of
                // that fix; typing it waits for a consumer that needs
                // machine-capacity RAM as distinct from context-available RAM.
                //
                // Two loci legitimately disagree: this machine's guest reports
                // its 7.3 GB VM slice and Windows reports 15.2 GB installed.
                // Neither is wrong, which is why the figure is printed per-row
                // rather than once per host.
                if let Some(ram) = entry.document["host"]["system_ram_gb"].as_f64() {
                    println!("  machine_ram_gb: {ram:.2}");
                }
                let triples = tillandsias_plan::fragments::schedulable_triples(&entry.document);
                if triples.is_empty() {
                    println!("  schedulable: none");
                }
                for (class, lane, engine) in triples {
                    println!("  schedulable: {class}/{lane}/{engine}");
                }
                // Measurements the matrix will not place (order 810-jeg7). An
                // unlocated number is refused rather than shown as a plain
                // figure, because the locus difference has been measured at
                // 5-10% on the embed arm — enough to have inverted a cross-host
                // conclusion once. Reported rather than dropped: a measurement
                // discarded in silence is indistinguishable from one never
                // taken.
                let (placed, unplaced) =
                    tillandsias_plan::fragments::partition_measurements(&entry.document);
                for meas in &placed {
                    println!(
                        "  measured: {}/{} suite:{} decode_tps:{}",
                        meas["device"].as_str().unwrap_or("?"),
                        meas["engine"].as_str().unwrap_or("?"),
                        meas["workload_suite"].as_str().unwrap_or("unstated"),
                        meas["decode_tps"].as_f64().unwrap_or(f64::NAN)
                    );
                }
                for (meas, why) in &unplaced {
                    println!(
                        "  measurement-refused: {}/{} ({why})",
                        meas["device"].as_str().unwrap_or("?"),
                        meas["engine"].as_str().unwrap_or("?")
                    );
                }
                // Present-unusable devices are reported BESIDE the schedulable
                // set, because "present but unreachable" and "absent" are
                // different engineering problems (806-2r4s) and a matrix that
                // shows only what is schedulable cannot tell them apart.
                if let Some(devices) = entry.document["devices"].as_sequence() {
                    for d in devices {
                        if d["usable"].as_bool() == Some(false) {
                            // `os_status` is printed BESIDE the reason, not
                            // folded into it, because they are two independent
                            // facts and 806-2r4s is precisely about not
                            // collapsing them. Windows calls this NPU healthy
                            // AND we cannot reach it; a reader who sees only
                            // the reason cannot tell "the OS says it is
                            // broken" from "the OS says it is fine and our
                            // lanes cannot get to it" — which are different
                            // engineering problems. Omitted when the
                            // contributing context did not report one, rather
                            // than guessed.
                            let os_status = d["os_status"]
                                .as_str()
                                .map(|s| format!(" os_status:{s}"))
                                .unwrap_or_default();
                            println!(
                                "  present-unusable: {}/{} ({}){os_status}",
                                d["device_class"].as_str().unwrap_or("?"),
                                d["name"].as_str().unwrap_or("?"),
                                d["unusable_reason"].as_str().unwrap_or("unstated")
                            );
                        }
                    }
                }
            }
            // Reported, never silent: a row that could not be keyed is
            // indistinguishable from a host that never contributed unless the
            // reader is told, and "the matrix looks empty" is exactly the
            // symptom a misfiled row produces.
            for s in &skipped {
                println!("skipped: {} ({})", s.source, s.reason);
            }
        }
        "fragments" => {
            // Report the overlay's state and whether compaction is eligible.
            // Read-only: compaction itself is a separate, deliberate act.
            let d = tillandsias_plan::fragments::drift(&index);
            println!("{}", d.verdict());
            for f in tillandsias_plan::fragments::load_all(&index) {
                emit(&format!("fragment: {}", f.name));
            }
            for bad in tillandsias_plan::fragments::malformed(&index) {
                emit(&format!("malformed: {}", bad.display()));
            }
        }
        "compact" => {
            // Fold every fragment into the base and delete EXACTLY the ones
            // folded.
            //
            // Two rules make this safe, and both are easy to break:
            //   1. Delete by NAME, never by glob. A fragment written by another
            //      host while this ran has not been folded, and globbing it away
            //      would silently destroy filed work — the classic
            //      GC-versus-writer race.
            //   2. VALIDATE the candidate before replacing the base. A
            //      compaction that emits a malformed base is worse than no
            //      compaction at all.
            //
            // The fold itself is TEXT-LEVEL and format-preserving
            // (fragments::compact_text): the base is never re-serialized, so
            // every comment and the exact item indentation survive BY
            // CONSTRUCTION, and the appended packets/events are emitted in the
            // shape `edit::append_event`/`push_event` recognize. A YAML
            // round-trip would drop ~120 operator comment lines and re-indent
            // list items to column 0, silently breaking every future event
            // append — the refusal-to-round-trip rationale that preceded this
            // implementation is recorded in packet
            // format-preserving-ledger-compaction.
            let c = match tillandsias_plan::fragments::compact_text(&index) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!(
                        "error: compaction REFUSED — {e}\n\x20 the base is UNCHANGED and every \
                         fragment is intact — reading is already transparent, so nothing is \
                         blocked by staying uncompacted"
                    );
                    std::process::exit(1);
                }
            };
            if c.consumed.is_empty() {
                println!("ok: nothing to compact (0 fragments)");
                return;
            }
            // The gate: the merged ledger must load AND pass integrity before it
            // is allowed to replace a working base.
            //
            // The candidate is validated with the SAME archived-id set the live
            // loader uses. An empty set here would flag every `depends_on` that
            // points at an archived (done) packet as an unresolved reference,
            // refusing a compaction `plan check` would have accepted — verified
            // live 2026-08-03 on agent-login-flows-research / encrypted-
            // control-channel-research, both archived in plan/archive/.
            match Ledger::parse(&c.candidate, ledger.archived_ids().clone()) {
                Ok(l) => {
                    let report = l.check_integrity(&schema.reference_fields);
                    if !report.violations.is_empty() {
                        eprintln!(
                            "error: compaction REFUSED — the merged ledger violates integrity ({} violation(s)); the base is unchanged and every fragment is intact:",
                            report.violations.len()
                        );
                        for v in &report.violations {
                            eprintln!("  {v}");
                        }
                        std::process::exit(1);
                    }
                }
                Err(e) => {
                    eprintln!(
                        "error: compaction REFUSED — the merged ledger does not parse ({e}); the base is unchanged and every fragment is intact"
                    );
                    std::process::exit(1);
                }
            }
            if let Err(e) = std::fs::write(&index, &c.candidate) {
                eprintln!("error: write {}: {e}", index.display());
                std::process::exit(1);
            }
            let mut removed = 0usize;
            for p in &c.consumed {
                match std::fs::remove_file(p) {
                    Ok(()) => removed += 1,
                    Err(e) => eprintln!(
                        "warning: could not remove folded fragment {}: {e}",
                        p.display()
                    ),
                }
            }
            println!(
                "ok: compacted {} fragment(s) into {} ({} removed)",
                c.consumed.len(),
                index.display(),
                removed
            );
        }
        "next-order" => {
            // Mint a collision-free order token for a NEW packet.
            //
            // Replaces "read the ledger, add one" — which is computed from a
            // snapshot that goes stale the moment another host commits, and so
            // makes two hosts filing in the same window pick the SAME number
            // deterministically. That happened twice in one session.
            //
            // Prints ONE token on stdout and nothing else, so it composes:
            //   order: $(tillandsias-plan next-order)
            // args[0] is the subcommand. The optional prefix is the first
            // POSITIONAL operand after it — flags and their values must be
            // skipped, or `next-order --count 5` reads "--count" as the prefix
            // and refuses a perfectly valid invocation.
            let positional: Vec<&String> = {
                let mut out = Vec::new();
                let mut i = 1usize;
                while i < args.len() {
                    if args[i] == "--count" {
                        i += 2; // the flag and its value
                        continue;
                    }
                    out.push(&args[i]);
                    i += 1;
                }
                out
            };
            let prefix = match positional.first() {
                None => None,
                Some(a) => match a.parse::<u64>() {
                    Ok(n) => Some(n),
                    // A non-numeric operand is a MISTAKE, not "use the default".
                    // Silently ignoring it would mint a token under a different
                    // prefix than the caller asked for and print it as if it had
                    // complied — the caller would only find out when the token
                    // did not sort where they expected.
                    Err(_) => {
                        eprintln!(
                            "error: prefix must be a number, got '{a}' \
                             (omit it to continue from the highest existing prefix)"
                        );
                        std::process::exit(2);
                    }
                },
            };
            // `--count N` mints N tokens in ONE invocation, guaranteed distinct
            // from each other.
            //
            // This is the surface that actually needs it. `mint` only knows what
            // is in the LEDGER, so tokens not yet written back are invisible to
            // it — and calling `next-order` N times means N separate PROCESSES,
            // none of which can see the others' draws. Filing a batch of packets
            // (the common case) is therefore exactly the unprotected shape, and
            // one invocation is the only place the guarantee can be made.
            let count = match args.iter().position(|a| a == "--count") {
                None => 1usize,
                Some(i) => match args.get(i + 1).and_then(|n| n.parse::<usize>().ok()) {
                    Some(n) if n >= 1 => n,
                    _ => {
                        eprintln!("error: --count requires a positive integer");
                        std::process::exit(2);
                    }
                },
            };
            match tillandsias_plan::allocate::mint_batch(&ledger, prefix, count) {
                Ok(tokens) => {
                    for t in tokens {
                        emit(t.as_str());
                    }
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
        "check" => {
            // 796-4ydb. Opt-in, because the refusal it arms is fleet-wide; see
            // the block below the integrity report for why that is not the
            // default.
            let mut strict_fragments = false;
            for a in &args[1..] {
                match a.as_str() {
                    "--strict-fragments" => strict_fragments = true,
                    other => {
                        eprintln!(
                            "error: unknown option {other:?} for `check` (known: --strict-fragments)"
                        );
                        std::process::exit(2);
                    }
                }
            }
            // INVARIANT CORE (ids + references) hard-gates: a live dangling
            // reference means the graph is a lie. SCHEMA drift (status enum,
            // required fields) is ADVISORY — the schema is evolving data
            // (operator 2026-07-17), so drift is surfaced, not blocked;
            // deliberate flushes through slice 2 will normalize it.
            let report = ledger.check_integrity(&schema.reference_fields);
            for w in &report.warnings {
                eprintln!("warning (organic reference debt): {w}");
            }
            for s in ledger.validate_against_schema(&schema) {
                eprintln!("advisory (schema drift): {s}");
            }
            // 686-7qcm — the invisible-block report. A dependent waiting on a
            // PARKED packet (implemented / needs_clarification / blocked /
            // failed) is otherwise silently stuck: `ready` skips it and
            // burndown does not count the block. Surface every such edge as an
            // advisory so parked work with waiting dependents is visible.
            let parked = ledger.parked_blocks();
            for pb in &parked {
                eprintln!(
                    "parked-block: {} waits on {} [{}]{}",
                    pb.dependent,
                    pb.dependency,
                    pb.status,
                    if pb.outstanding.is_empty() {
                        String::new()
                    } else {
                        format!(" — {}", pb.outstanding)
                    }
                );
            }
            // ORDER 796-4ydb — AN UNREADABLE FRAGMENT IS REPORTED HERE, AND
            // REFUSED ONLY WHEN THE CALLER ASKS.
            //
            // The first draft of this made a skipped fragment an unconditional
            // violation, and 699-dycj forbids exactly that, by name: "do not
            // simply make `check` exit non-zero and call it done — re-read why
            // 698 scoped itself first." The reason holds. `build.sh` runs this
            // command on EVERY host, so a fleet-wide refusal turns one host's
            // typo into every other host's red build, on a file they did not
            // write and may not be able to fix. That converts a local error
            // into a fleet outage — the same argument 634-39ik used to scope
            // its enforcement to the diff.
            //
            // So the split is: this command always SAYS SO, in a form a caller
            // can branch on, and refuses only under `--strict-fragments`, which
            // the surfaces that genuinely cannot tolerate a partial corpus turn
            // on for themselves. The author-side diff-scoped gate
            // (698-7n6q / check-added-fragments-parse.sh) keeps its job of
            // stopping the fragment at whoever wrote it.
            let skipped = ledger.skipped_fragments();
            for bad in skipped {
                // Same token the `fragments` subcommand uses for the same
                // condition — one word for one thing across the CLI.
                emit(&format!("malformed: {}", bad.display()));
            }
            if !report.violations.is_empty() && !skipped.is_empty() {
                // WHY THIS CAVEAT IS NOT DECORATION: a `depends_on` whose
                // target is DEFINED in the unreadable fragment reports here as
                // a dangling reference. When the fold is partial the violation
                // list is partial evidence too, and a reader who fixes the
                // "dangling" reference instead of the fragment makes it worse.
                eprintln!(
                    "note: {} fragment(s) could not be read, so the violations below may be \
                     ARTIFACTS of the missing content — repair the fragment first, then re-check",
                    skipped.len()
                );
            }
            if !report.violations.is_empty() {
                for v in &report.violations {
                    eprintln!("violation: {v}");
                }
                std::process::exit(1);
            }
            if skipped.is_empty() {
                // `emit`, not `println!`: this line is routinely piped
                // (litmus:parked-blocks-visibility-shape does `check | grep -q`),
                // and `println!` PANICS with exit 101 when the reader closes
                // early. It survived on output small enough to fit the pipe
                // buffer; adding lines above it is not the moment to keep
                // relying on that.
                emit(&format!(
                    "ok: {} packets, ids unique, live references sound ({} parked-block edge{})",
                    ledger.packets.len(),
                    parked.len(),
                    if parked.len() == 1 { "" } else { "s" }
                ));
            } else {
                // NOT `ok:`. Announcing a sound ledger when part of the corpus
                // was never read is the precise lie this order was filed
                // against — the checks that follow the colon are all true, and
                // they were run over less than the plan.
                emit(&format!(
                    "incomplete: {} packets from a PARTIAL corpus — {} fragment(s) could not be \
                     read; ids unique and live references sound across what WAS read \
                     ({} parked-block edge{})",
                    ledger.packets.len(),
                    skipped.len(),
                    parked.len(),
                    if parked.len() == 1 { "" } else { "s" }
                ));
                if strict_fragments {
                    eprintln!(
                        "refusing (--strict-fragments): the fold skipped {} unreadable \
                         fragment(s); this ledger is incomplete",
                        skipped.len()
                    );
                    // DISTINCT EXIT CODE, so a caller can tell "incomplete
                    // corpus" from "unsound ledger" WITHOUT parsing prose. The
                    // pre-push plan-only lane used to grep this binary's stderr
                    // for the sentence "does not parse and was SKIPPED" and
                    // said so in a comment; that is what a condition with no
                    // machine-readable form costs its callers.
                    std::process::exit(EXIT_FOLD_INCOMPLETE);
                }
            }
        }
        "parked-blocks" => {
            // 686-7qcm. List every dependent invisibly blocked behind a parked
            // packet. With a reference argument, only that packet's parked
            // dependencies; with none, the whole ledger. One TSV row per edge:
            // dependent<TAB>dependency<TAB>status<TAB>outstanding.
            let edges = match args.get(1) {
                Some(reference) => {
                    warn_if_unresolved(&ledger, reference);
                    ledger.parked_dependencies_of(reference)
                }
                None => ledger.parked_blocks(),
            };
            for pb in &edges {
                emit(&format!(
                    "{}\t{}\t{}\t{}",
                    pb.dependent, pb.dependency, pb.status, pb.outstanding
                ));
            }
        }
        "closure-evidence-check" => {
            // 686-7qcm criterion 3. A single-FILE gate: a fragment that sets a
            // closure-ladder terminal (completed/verified/done) — via the
            // `status:` LWW channel OR an inline `packets:` status — must carry
            // an evidence-bearing event for that packet, so a closure can never
            // be recorded without a trace of what justified it. This is the
            // gate-time backstop to the set-field write-time --evidence
            // requirement; a shell wrapper diff-scopes it to newly ADDED
            // fragments so the base ledger's history is exempt. Exit 1 on a
            // closure with no evidence event, naming the packet.
            let Some(path) = args.get(1) else {
                eprintln!("usage: tillandsias-plan closure-evidence-check <fragment.yaml>");
                std::process::exit(2);
            };
            let raw = match std::fs::read_to_string(path) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {path}: {e}");
                    std::process::exit(2);
                }
            };
            let doc: serde_yaml::Value = match serde_yaml::from_str(&raw) {
                Ok(d) => d,
                // A parse failure is the sibling gate's job (added-fragments-parse);
                // here it is a pass-through, not this check's violation.
                Err(_) => {
                    println!(
                        "ok:closure-evidence:0 checked (unparseable — see added-fragments-parse)"
                    );
                    return;
                }
            };
            let is_closure = |s: &str| matches!(s, "completed" | "verified" | "done");
            // packet_id -> does the fragment carry an evidence-bearing event?
            let evidence_event_for = |pid: &str| -> bool {
                let has_marker = |ev: &serde_yaml::Value| -> bool {
                    let ty = ev
                        .get("type")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    if matches!(ty, "completed" | "verified" | "falsified") {
                        return true;
                    }
                    // evidence_refs field, or the word in the summary text.
                    ev.get("evidence_refs").is_some()
                        || ev
                            .get("summary")
                            .and_then(serde_yaml::Value::as_str)
                            .is_some_and(|s| s.to_lowercase().contains("evidence"))
                };
                // top-level events: [{packet_id, event: {...}}]
                if let Some(evs) = doc.get("events").and_then(serde_yaml::Value::as_sequence) {
                    for e in evs {
                        if e.get("packet_id").and_then(serde_yaml::Value::as_str) == Some(pid)
                            && e.get("event").is_some_and(has_marker)
                        {
                            return true;
                        }
                    }
                }
                // inline packet events: packets:[{packet_id, events:[{type,...}]}]
                if let Some(pkts) = doc.get("packets").and_then(serde_yaml::Value::as_sequence) {
                    for p in pkts {
                        if p.get("packet_id").and_then(serde_yaml::Value::as_str) == Some(pid)
                            && p.get("events")
                                .and_then(serde_yaml::Value::as_sequence)
                                .is_some_and(|evs| evs.iter().any(has_marker))
                        {
                            return true;
                        }
                    }
                }
                false
            };
            let mut offenders: Vec<String> = Vec::new();
            let mut checked = 0u32;
            // status: LWW closures
            if let Some(us) = doc.get("status").and_then(serde_yaml::Value::as_sequence) {
                for u in us {
                    let field = u
                        .get("field")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    let value = u
                        .get("value")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    let pid = u
                        .get("packet_id")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    if field == "status" && is_closure(value) && !pid.is_empty() {
                        checked += 1;
                        if !evidence_event_for(pid) {
                            offenders.push(format!("{pid} (status:{value})"));
                        }
                    }
                }
            }
            // inline packets: closures
            if let Some(pkts) = doc.get("packets").and_then(serde_yaml::Value::as_sequence) {
                for p in pkts {
                    let value = p
                        .get("status")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    let pid = p
                        .get("packet_id")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    if is_closure(value) && !pid.is_empty() {
                        checked += 1;
                        if !evidence_event_for(pid) {
                            offenders.push(format!("{pid} (packets:{value})"));
                        }
                    }
                }
            }
            if offenders.is_empty() {
                println!("ok:closure-evidence:{checked} checked");
            } else {
                for o in &offenders {
                    eprintln!(
                        "violation:closure-without-evidence: {o} sets a closure rung with no evidence-bearing event in the same fragment"
                    );
                }
                eprintln!(
                    "  A closure (completed/verified/done) must carry an event with evidence_refs (or type completed/verified/falsified). Use set-field --evidence, or add the event (686-7qcm)."
                );
                std::process::exit(1);
            }
        }
        "status" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            match ledger.resolve(reference) {
                Some(p) => {
                    println!("{}", line(&ledger, p));
                    // 686-7qcm: name any parked dependency so a single-packet
                    // status read shows WHY the packet cannot progress and what
                    // would free it, instead of an unexplained blocked/pending.
                    for pb in ledger.parked_dependencies_of(reference) {
                        eprintln!(
                            "  blocked-on-parked: {} [{}]{}",
                            pb.dependency,
                            pb.status,
                            if pb.outstanding.is_empty() {
                                String::new()
                            } else {
                                format!(" — {}", pb.outstanding)
                            }
                        );
                    }
                }
                None => {
                    eprintln!("error: {}", unresolved_reason(&ledger, reference));
                    std::process::exit(1);
                }
            }
        }
        "blocked-by" | "blocked-closure" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            // Order 516: these queries answer with an empty stdout both when
            // the reference resolves and blocks nothing AND when it does not
            // resolve at all — the second case reads as "no such work", which
            // is exactly the false negative that got 394a/392a filed. Say so
            // on stderr. The exit code is deliberately left alone so existing
            // callers (litmus pipelines, the forge-plan MCP wrapper) keep
            // their contract.
            warn_if_unresolved(&ledger, reference);
            let packets = if args[0] == "blocked-by" {
                ledger.blocked_by(reference)
            } else {
                ledger.blocked_by_closure(reference)
            };
            for p in packets {
                emit(&line(&ledger, p));
            }
        }
        "dependencies-of" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            if args.len() != 2 {
                eprintln!("error: dependencies-of accepts exactly one packet id or order");
                std::process::exit(2);
            }
            let Some(packets) = ledger.dependencies_of(reference) else {
                eprintln!("error: {}", unresolved_reason(&ledger, reference));
                std::process::exit(1);
            };
            for p in packets {
                emit(&line(&ledger, p));
            }
        }
        "blocking-counts" => {
            // ORDER 632-retq (rung 2). How many READY packets each id blocks.
            //
            // Deliberately NOT folded into `select-rows`: that one answers "what
            // may I pick", filtered to dependency-clear and unleased, while this
            // one must count edges from EVERY ready packet — including the ones
            // select-rows excludes. A linux packet is frequently the thing a
            // windows packet is waiting on, and that downstream weight is
            // exactly the residual minimax asks us to maximise. Folding them
            // would silently score the graph against a filtered subset.
            let options = match parse_query_options(&args[1..]) {
                Ok(options) => options,
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(2);
                }
            };
            let mut counts: std::collections::BTreeMap<String, usize> =
                std::collections::BTreeMap::new();
            for p in query_packets(
                &ledger,
                Some("ready"),
                None,
                None,
                options.release.as_deref(),
                &[],
                options.limit,
            ) {
                if let Some(deps) = p.get("depends_on").and_then(serde_yaml::Value::as_sequence) {
                    for d in deps {
                        let key = match d {
                            serde_yaml::Value::String(s) => s.clone(),
                            serde_yaml::Value::Number(n) => n.to_string(),
                            _ => continue,
                        };
                        *counts.entry(key).or_insert(0) += 1;
                    }
                }
            }
            for (id, n) in counts {
                emit(&format!("{id}	{n}"));
            }
        }
        "select-rows" => {
            // ORDER 632-retq. Emit the batch selector's projection directly.
            //
            // scripts/select-work-batch.sh built this with nineteen jq calls, so
            // the selector — the thing that decides what a cycle WORKS ON —
            // could not run on a host without jq. Order 632-retq made that fail
            // loud rather than counterfeit a drained ledger, which was right and
            // still left the host unable to select work. Satisfying the
            // dependency per host repeats the yq/ruby exposure recorded on
            // 2026-08-03; emitting the projection from the binary that already
            // owns the ledger deletes the class.
            //
            // Output: rank \t release_target \t order \t packet_id \t urgency \t release
            // Already filtered to ready + role + release + dependency-clear +
            // unleased, so the caller needs no further projection.
            let options = match parse_query_options(&args[1..]) {
                Ok(options) => options,
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(2);
                }
            };
            if let Some(release) = options.release.as_deref() {
                let releases = known_releases(&ledger);
                if !releases.iter().any(|known| known == release) {
                    eprintln!(
                        "error: unknown release constraint '{release}' (known desired_release values: {})",
                        releases.join(",")
                    );
                    std::process::exit(2);
                }
            }

            // The terminal set is computed over the WHOLE ledger, not the
            // role-filtered pool: a linux packet is frequently the thing a
            // windows packet waits on.
            let mut terminal: std::collections::BTreeSet<String> =
                std::collections::BTreeSet::new();
            for p in query_packets(&ledger, None, None, None, None, &[], usize::MAX) {
                let status = p
                    .get("status")
                    .and_then(serde_yaml::Value::as_str)
                    .unwrap_or("");
                if matches!(status, "done" | "completed" | "obsoleted") {
                    terminal.insert(ledger.id_of(p).to_string());
                }
            }

            // ORDER 726-cjb8. A packet that has been SPLIT is a criteria holder,
            // not work — its slices are the claimable things. It stays `ready`
            // so it can hold the criteria until the children close, and until
            // this filter existed the selector kept offering the parent as the
            // urgent pick forever. 606-bvnp was split into four ready children
            // and was immediately re-offered as `urgent=` on the very next
            // cycle, outranking its own slices because it is older and p0. Two
            // other split parents sit `ready` in the ledger with the same
            // latent behaviour.
            //
            // The parent is skipped only while a child is still OPEN. Once
            // every named slice is terminal the parent becomes visible again,
            // which is exactly when someone should look at it — to close it.
            //
            // split_into entries are prose ("722-hthz — name (slice a: ...)"),
            // so child identity is tested by substring against the ids and
            // order tokens of packets that are NOT terminal. A prose entry that
            // names nothing open cannot hold the parent back.
            let open_tokens: Vec<String> =
                query_packets(&ledger, None, None, None, None, &[], usize::MAX)
                    .into_iter()
                    .filter(|p| !terminal.contains(&ledger.id_of(p).to_string()))
                    .flat_map(|p| {
                        let mut toks = vec![ledger.id_of(p).to_string()];
                        if let Some(o) = p.get("order") {
                            match o {
                                serde_yaml::Value::Number(n) => toks.push(n.to_string()),
                                serde_yaml::Value::String(s) => toks.push(s.clone()),
                                _ => {}
                            }
                        }
                        toks
                    })
                    .filter(|t| !t.is_empty())
                    .collect();

            let matched = query_packets(
                &ledger,
                Some("ready"),
                options.role.as_deref(),
                options.claimable_by.as_deref(),
                options.release.as_deref(),
                &options.tags,
                options.limit,
            );

            for p in matched {
                let id = ledger.id_of(p).to_string();
                let deps: Vec<String> = p
                    .get("depends_on")
                    .and_then(serde_yaml::Value::as_sequence)
                    .map(|s| {
                        s.iter()
                            .filter_map(|v| match v {
                                serde_yaml::Value::String(s) => Some(s.clone()),
                                serde_yaml::Value::Number(n) => Some(n.to_string()),
                                _ => None,
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                if !dependencies_are_clear(&deps, &terminal) {
                    continue;
                }
                if inspect_lease(&id).map(|l| l.is_active).unwrap_or(false) {
                    continue;
                }
                // Split parent with at least one open slice — see above.
                if let Some(entries) = p.get("split_into").and_then(serde_yaml::Value::as_sequence)
                {
                    let has_open_child = entries.iter().any(|e| {
                        e.as_str().is_some_and(|s| {
                            open_tokens
                                .iter()
                                .any(|t| t != &id && s.contains(t.as_str()))
                        })
                    });
                    if has_open_child {
                        continue;
                    }
                }
                let (rank, display) = urgency_rank_and_display(
                    p.get("priority").and_then(serde_yaml::Value::as_str),
                    p.get("kind").and_then(serde_yaml::Value::as_str),
                );
                let epic = p
                    .get("release_target")
                    .and_then(serde_yaml::Value::as_str)
                    .unwrap_or("UNGROUPED");
                let order = p
                    .get("order")
                    .map(|v| match v {
                        serde_yaml::Value::Number(n) => n.to_string(),
                        serde_yaml::Value::String(s) => s.clone(),
                        _ => "?".into(),
                    })
                    .unwrap_or_else(|| "?".into());
                let release = p
                    .get("desired_release")
                    .and_then(serde_yaml::Value::as_str)
                    .unwrap_or("?");
                emit(&format!(
                    "{rank}\t{epic}\t{order}\t{id}\t{display}\t{release}"
                ));
            }
        }
        "query" => {
            // ORDER 582-26mm. The generic filtered reader over the FOLDED
            // ledger — the single correct way to enumerate packets by
            // status/role/tag without opening plan/index.yaml directly.
            // project-info.sh's plan_query (yq) and drain-queue.sh (awk) both
            // read the BASE only and reported a stale ledger with total
            // confidence; both now route here. The filter semantics below
            // reproduce plan_query's contract exactly: exact status/release,
            // pickup_role as a case-insensitive substring, capability_tags
            // all-must-match, then a limit.
            let options = match parse_query_options(&args[1..]) {
                Ok(options) => options,
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(2);
                }
            };
            if let Some(release) = options.release.as_deref() {
                let releases = known_releases(&ledger);
                if !releases.iter().any(|known| known == release) {
                    eprintln!(
                        "error: unknown release constraint '{release}' (known desired_release values: {})",
                        releases.join(",")
                    );
                    std::process::exit(2);
                }
            }
            let matched = query_packets(
                &ledger,
                options.status.as_deref(),
                options.role.as_deref(),
                options.claimable_by.as_deref(),
                options.release.as_deref(),
                &options.tags,
                options.limit,
            );
            if options.json {
                let arr: Vec<serde_json::Value> =
                    matched.iter().map(|p| query_json_projection(p)).collect();
                println!(
                    "{}",
                    serde_json::to_string(&serde_json::Value::Array(arr))
                        .unwrap_or_else(|_| "[]".to_string())
                );
            } else {
                for p in matched {
                    let id = ledger.id_of(p);
                    let order = p
                        .get("order")
                        .map(|v| match v {
                            serde_yaml::Value::Number(n) => n.to_string(),
                            serde_yaml::Value::String(s) => s.clone(),
                            _ => "?".into(),
                        })
                        .unwrap_or_else(|| "?".into());
                    let release = p
                        .get("desired_release")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    let tags = p
                        .get("capability_tags")
                        .and_then(serde_yaml::Value::as_sequence)
                        .map(|s| {
                            s.iter()
                                .filter_map(serde_yaml::Value::as_str)
                                .collect::<Vec<_>>()
                                .join(",")
                        })
                        .unwrap_or_default();
                    emit(&format!("{order}\t{id}\t{release}\t{tags}"));
                }
            }
        }
        "ready" => {
            for p in ledger.ready(args.get(1).map(String::as_str)) {
                emit(&line(&ledger, p));
            }
        }
        "burndown" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            warn_if_unresolved(&ledger, reference);
            for p in ledger.milestone_children(reference) {
                emit(&line(&ledger, p));
            }
        }
        "answer" => {
            // ORDER 394b. The envelope is the ONLY output shape: a question
            // this engine cannot answer deterministically comes back as
            // `confidence: "unsupported"` with an empty citation list, never
            // as prose an agent might mistake for a finding.
            //
            // EXIT 0 EVEN WHEN UNSUPPORTED, deliberately: `unsupported` is a
            // well-formed answer, and the forge-plan MCP wrapper runs under
            // `set -e` where a non-zero status kills the server mid-request
            // (see forge-plan.sh::plan_query). The envelope IS the signal.
            let question = args[1..].join(" ");
            if question.trim().is_empty() {
                usage();
            }
            let root = root_for(&index);
            let envelope =
                answer::answer_question(&ledger, &question, &citation_path(&index, &root));
            // ORDER 523 (R2): self-verify against the SAME root the citation
            // paths were built relative to. This is the exact disagreement that
            // was observed — an index reached through a probe path yielded
            // confidence=exact with a citation `verify-answer` refused.
            emit_verified_envelope(envelope, &root, ledger.skipped_fragments());
        }
        "next" => {
            // ORDER 606-xu52. The cold-start selector: at most five cited,
            // release-aware, role-compatible, dependency-clear, unleased
            // claimable packets, ranked deterministically. Same envelope
            // discipline as `answer`: exit 0 even when the typed no-work
            // refusal comes back — the envelope IS the signal.
            let mut role: Option<String> = None;
            let mut release: Option<String> = None;
            let mut limit: Option<usize> = None;
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--release" => {
                        i += 1;
                        release = args.get(i).cloned();
                    }
                    "--limit" => {
                        i += 1;
                        let raw = args.get(i).cloned().unwrap_or_default();
                        match raw.parse::<usize>() {
                            Ok(n) if (1..=answer::NEXT_LIMIT_MAX).contains(&n) => limit = Some(n),
                            _ => {
                                eprintln!(
                                    "error: --limit must be an integer in 1..={} (got {raw:?}) — plan_next is capped at five on purpose",
                                    answer::NEXT_LIMIT_MAX
                                );
                                std::process::exit(2);
                            }
                        }
                    }
                    other if other.starts_with('-') => {
                        eprintln!(
                            "error: unknown option {other:?} for `next` (known: [role], --release <vX.Y>, --limit <1..=5>)"
                        );
                        std::process::exit(2);
                    }
                    other => {
                        if role.is_some() {
                            eprintln!("error: `next` takes at most one positional pickup_role");
                            std::process::exit(2);
                        }
                        role = Some(other.to_string());
                    }
                }
                i += 1;
            }
            let root = root_for(&index);
            let envelope = answer::answer_next(
                &ledger,
                role.as_deref(),
                release.as_deref(),
                limit,
                &citation_path(&index, &root),
            );
            emit_verified_envelope(envelope, &root, ledger.skipped_fragments());
        }
        "append-event" => {
            // append-event <ref> <type> <summary> --ts <ISO> [--agent A] [--host H]
            let mut positional: Vec<String> = Vec::new();
            let mut ts: Option<String> = None;
            // 772-4se9: no more hardcoded agent="unknown" / host="linux" —
            // those defaults fabricated a wrong host FACT on two of the four
            // host kinds and an improvised identity on all of them. Absent
            // flags now resolve after the ref resolves: host from the
            // compiled platform, agent from TILLANDSIAS_AGENT_ID or refusal.
            let mut agent: Option<String> = None;
            let mut host: Option<String> = None;
            let mut flag_type: Option<String> = None;
            let mut flag_summary: Option<String> = None;
            let mut backfill = false;
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--ts" => {
                        i += 1;
                        ts = args.get(i).cloned();
                    }
                    "--agent" => {
                        i += 1;
                        agent = args.get(i).cloned();
                    }
                    "--host" => {
                        i += 1;
                        host = args.get(i).cloned();
                    }
                    // Accept --type/--summary as explicit flags. Before this
                    // (690-2kwd fallout, 2026-08-12), passing them was silently
                    // swallowed as POSITIONAL garbage: `--type progress` stored
                    // type="--type", summary="progress", and the malformed event
                    // passed every gate (698-7n6q). Now the flag form works.
                    "--type" => {
                        i += 1;
                        flag_type = args.get(i).cloned();
                    }
                    "--summary" => {
                        i += 1;
                        flag_summary = args.get(i).cloned();
                    }
                    // 719-kgr5 escape hatch: recording an event that genuinely
                    // happened earlier. Takes no value.
                    "--backfill" => backfill = true,
                    // Any OTHER --flag is rejected loudly rather than corrupting
                    // the event by masquerading as a positional value.
                    other if other.starts_with("--") => {
                        eprintln!(
                            "error: unknown flag '{other}' for append-event \
                             (usage: <ref> <type> <summary> --ts <ISO> \
                             [--agent A] [--host H]; --type/--summary also accepted)"
                        );
                        std::process::exit(2);
                    }
                    other => positional.push(other.to_string()),
                }
                i += 1;
            }
            // type/summary may come from flags or positionals; ref is always
            // positional[0]. Missing any of the three -> usage (diverges).
            if positional.is_empty() {
                usage();
            }
            let reference = positional[0].clone();
            let etype = flag_type
                .or_else(|| positional.get(1).cloned())
                .unwrap_or_else(|| usage());
            let summary = flag_summary
                .or_else(|| positional.get(2).cloned())
                .unwrap_or_else(|| usage());
            let (reference, etype, summary) = (&reference, &etype, &summary);
            // 719-kgr5. This used to REQUIRE --ts, on the reasoning that "the
            // tool does not invent timestamps" — but the caller then invented
            // them instead, for eleven consecutive cycles, drifting to +8.6h.
            // Reading the clock is not inventing a timestamp; it is the only
            // way to measure one. The flag stays available and is now CHECKED.
            let ts = resolve_ts(ts, backfill, "append-event");
            let Some(target) = ledger.resolve(reference).map(|p| ledger.id_of(p)) else {
                eprintln!("error: {}", unresolved_reason(&ledger, reference));
                std::process::exit(1);
            };
            // 772-4se9: identity resolves AFTER the ref so an unresolvable
            // reference still reports as such (pinned by
            // litmus:append-event-rejects-unknown-flags-shape), but BEFORE
            // any byte is written — a refusal here writes nothing.
            let agent = resolve_writer_agent(agent);
            let host = host
                .filter(|h| !h.trim().is_empty())
                .unwrap_or_else(resolve_writer_host);
            let block = edit::event_block(etype, &ts, &agent, &host, summary);
            let raw = match std::fs::read_to_string(&index) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", index.display());
                    std::process::exit(1);
                }
            };

            // 699-usxc. A packet declared only in an uncompacted fragment has no
            // block in the BASE to append into — this arm locates packets by
            // their item prefix in plan/index.yaml. Until now that produced
            // "packet_id not found" for a packet `status` resolves perfectly
            // well, so the natural workflow "file a packet, then record progress
            // on it" failed for exactly the packets filed this cycle.
            //
            // Worse in practice than it sounds: the documented workaround
            // (`set-field <same-value> --reason`) NO-OPS when the value is
            // unchanged and writes nothing at all, so there was NO path to
            // annotate such a packet without also changing a field. That bites
            // hardest when someone is correcting a mistake in the record —
            // exactly when the ledger most needs to accept a write.
            //
            // So: if the base cannot host the event, write it as a NEW FRAGMENT,
            // which is what the overlay is for and what set-field already does.
            // The fold reads events from fragments, so the result is identical
            // to a base append from every reader's point of view.
            if !edit::base_hosts_packet(&raw, &target) {
                let compact = loop_status::iso_to_compact(&ts);
                let suffix = format!(
                    "{:08x}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.subsec_nanos())
                        .unwrap_or(0)
                );
                let dir = fragments::fragment_dir(&index);
                if let Err(e) = std::fs::create_dir_all(&dir) {
                    eprintln!("error: create {}: {e}", dir.display());
                    std::process::exit(1);
                }
                let path = dir.join(fragments::fragment_name(&compact, &suffix, &host));
                let mut body = String::new();
                body.push_str("# Ledger fragment — append-only, IMMUTABLE once written.\n");
                body.push_str("# Written by: tillandsias-plan append-event (order 699-usxc).\n");
                body.push_str(
                    "#\n# The target packet is declared only in an uncompacted fragment, so the\n\
                     # BASE ledger has no block to append into. Recording the event here keeps\n\
                     # it visible to the fold, which is what every reader consults.\n",
                );
                body.push_str("events:\n");
                body.push_str(&format!("  - packet_id: {target}\n"));
                body.push_str("    event:\n");
                body.push_str(&format!("      type: {etype}\n"));
                body.push_str(&format!("      ts: \"{ts}\"\n"));
                body.push_str(&format!("      agent_id: {agent}\n"));
                body.push_str(&format!("      host: {host}\n"));
                body.push_str("      summary: >\n");
                for line in summary.replace('\n', " ").split('\n') {
                    body.push_str(&format!("        {line}\n"));
                }
                if let Err(e) = std::fs::write(&path, body) {
                    eprintln!("error: write {}: {e}", path.display());
                    std::process::exit(1);
                }
                println!("appended {etype} event to {target} ({})", path.display());
                return;
            }
            let candidate = match edit::append_event(&raw, &target, &block) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            };
            // FLUSH GUARD: never write a broken ledger (order-263 by construction).
            let violations = edit::validate_candidate(
                &candidate,
                ledger.archived_ids(),
                &schema.reference_fields,
            );
            if !violations.is_empty() {
                eprintln!("REFUSED: this edit would break the ledger:");
                for v in &violations {
                    eprintln!("  violation: {v}");
                }
                std::process::exit(1);
            }
            if let Err(e) = std::fs::write(&index, candidate) {
                eprintln!("error: write {}: {e}", index.display());
                std::process::exit(1);
            }
            println!("appended {etype} event to {target}");
        }
        // Order 569. Was `usage()`, which conflated "this binary cannot do that"
        // with "you forgot an operand". The wrapper needs the two apart: the
        // first means RELAUNCH/REBUILD, the second means fix the call.
        // ORDER 636-9m79. The write path for a field correction, so the LWW
        // channel is never hand-authored.
        //
        // THREE HOSTS got this wrong on 2026-08-09, independently, within hours
        // of each other and of it being documented:
        //   linux    re-declared a packet under `packets:` to mark it done — a
        //            G-Set no-op; 11 of 21 completions were discarded (635-i6vm)
        //   macos    wrote `type: completed` EVENTS with no status block, so a
        //            packet that passed 5/5 with evidence stayed claimable
        //   windows  filed 642-fedr on the naming: the channel is called
        //            `status:` but corrects ANY field, so nobody finds it
        //
        // Three independent hosts is a write-path defect, not three mistakes.
        // 636-9m79's exit criteria call a helper "the strongest — it removes the
        // choice". This also closes 600-c266: unlike `append-event`, which
        // locates packets by their item prefix in the BASE ledger and so cannot
        // see fragment-only packets, this resolves against the FOLDED ledger.
        //
        // Named `set-field`, not `set-status`: the channel is field-generic, and
        // naming it for one field is exactly what hid it.
        "set-field" => {
            // args[0] is the subcommand itself (same convention as the `status`
            // arm's args.get(1)); skip it or the subcommand name becomes the
            // packet reference and every invocation refuses.
            let positional: Vec<String> = {
                let mut out = Vec::new();
                let mut i = 1;
                while i < args.len() {
                    if args[i].starts_with("--") {
                        i += 2;
                    } else {
                        out.push(args[i].clone());
                        i += 1;
                    }
                }
                out
            };
            let flagged = |name: &str| -> Option<String> {
                args.iter()
                    .position(|a| a == name)
                    .and_then(|i| args.get(i + 1))
                    .cloned()
            };
            if positional.len() < 3 {
                eprintln!(
                    "usage: tillandsias-plan set-field <id|order> <field> <value> [--ts ISO] [--host H] [--reason TEXT]"
                );
                std::process::exit(2);
            }
            let (target, field, value) = (
                positional[0].clone(),
                positional[1].clone(),
                positional[2].clone(),
            );

            // Resolve against the FOLDED ledger so a fragment-only packet is
            // reachable. A typo must refuse, never write a fragment that
            // silently applies to nothing.
            let Some(packet) = ledger.resolve(&target) else {
                eprintln!(
                    "error: no packet resolves '{target}' in the folded ledger (base + fragments)"
                );
                std::process::exit(1);
            };
            let Some(pid) = str_field(packet, "packet_id").map(|s| s.to_string()) else {
                eprintln!("error: resolved packet has no packet_id");
                std::process::exit(1);
            };
            let current = str_field(packet, &field).unwrap_or("<unset>").to_string();
            // 699-usxc, second half. A no-op on the FIELD must not silently
            // discard a note the caller explicitly asked to record.
            //
            // This branch used to return here unconditionally, so
            // `set-field <id> <field> <same-value> --reason "..."` printed `ok`
            // and wrote NOTHING — not the row, not the reason. Combined with
            // append-event being unable to reach fragment-only packets (the
            // other half of this packet), that left NO way to annotate such a
            // packet without also changing a field, and it bit hardest while
            // trying to correct a corrupted record: the one moment the ledger
            // most needs to accept a write. `ok` for "I discarded your text" is
            // the same unevidenced-success shape as 700-nz4n's other members.
            //
            // A bare no-op stays quiet and cheap. A no-op carrying --reason or
            // --evidence records the note and says so.
            if current == value {
                let note = flagged("--reason")
                    .filter(|s| !s.trim().is_empty())
                    .or_else(|| flagged("--evidence").filter(|s| !s.trim().is_empty()));
                let Some(note) = note else {
                    println!("ok: no-op — {pid}.{field} is already '{value}'");
                    return;
                };
                // Same defaults the field-changing path below uses, so a note
                // written here is indistinguishable from one written there.
                let ts = resolve_ts(
                    flagged("--ts"),
                    args.iter().any(|a| a == "--backfill"),
                    "set-field",
                );
                let host = flagged("--host").unwrap_or_else(resolve_writer_host);
                let compact = loop_status::iso_to_compact(&ts);
                let suffix = format!(
                    "{:08x}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.subsec_nanos())
                        .unwrap_or(0)
                );
                let dir = fragments::fragment_dir(&index);
                if let Err(e) = std::fs::create_dir_all(&dir) {
                    eprintln!("error: create {}: {e}", dir.display());
                    std::process::exit(1);
                }
                let path = dir.join(fragments::fragment_name(&compact, &suffix, &host));
                let mut body = String::new();
                body.push_str("# Ledger fragment — append-only, IMMUTABLE once written.\n");
                body.push_str("# Written by: tillandsias-plan set-field (order 699-usxc).\n");
                body.push_str(&format!(
                    "#\n# {pid}.{field} was ALREADY '{value}', so no field changed — but the caller\n\
                     # supplied a note, and discarding it silently is what this packet is about.\n"
                ));
                body.push_str("events:\n");
                body.push_str(&format!("  - packet_id: {pid}\n"));
                body.push_str("    event:\n");
                body.push_str("      type: note\n");
                body.push_str(&format!("      ts: \"{ts}\"\n"));
                body.push_str(&format!("      host: {host}\n"));
                body.push_str("      summary: >\n");
                body.push_str(&format!("        {}\n", note.replace('\n', " ")));
                if let Err(e) = std::fs::write(&path, body) {
                    eprintln!("error: write {}: {e}", path.display());
                    std::process::exit(1);
                }
                println!(
                    "ok: no-op — {pid}.{field} is already '{value}'; note recorded ({})",
                    path.display()
                );
                return;
            }

            // ORDER 650-dq6u — the status write gate. Write time is the hard
            // gate; `check` stays advisory (operator constraint 2026-07-17:
            // schemas evolve on the fly). Three refusals:
            //   1. a value outside plan/schema.yaml's vocabulary
            //   2. a closure-ladder downgrade without --reopen-evidence
            //      (which records the mandatory `falsified` event)
            //   3. a closure rung asserted without --evidence
            let reopen_evidence = flagged("--reopen-evidence");
            let evidence = flagged("--evidence");
            if field == "status" {
                if !schema.statuses.is_empty() && !schema.statuses.iter().any(|s| s == &value) {
                    eprintln!(
                        "error: '{value}' is not in the status vocabulary (plan/schema.yaml): {}",
                        schema.statuses.join(", ")
                    );
                    eprintln!(
                        "       retired words (claimed, stalled, provisional, failed-retryable, parked, tested) are invalid to write — see methodology/distributed-work.yaml status_transition_protocol"
                    );
                    std::process::exit(1);
                }
                let cur_rank = tillandsias_plan::closure_rank(&current);
                let new_rank = tillandsias_plan::closure_rank(&value);
                let is_downgrade = match (cur_rank, new_rank) {
                    (Some(c), Some(n)) => n < c,
                    // Leaving the ladder for a working state is also downward;
                    // obsoleted (supersession) and failed (attempt ended) are
                    // lateral terminal moves, not evidence retractions.
                    (Some(_), None) => !matches!(value.as_str(), "obsoleted" | "failed"),
                    _ => false,
                };
                if is_downgrade && reopen_evidence.is_none() {
                    eprintln!(
                        "error: '{current}' -> '{value}' moves DOWN the closure ladder (implemented < completed < verified < done)."
                    );
                    eprintln!(
                        "       The only path down is a falsified event: re-run with --reopen-evidence <ref> naming the falsifying observation (650-dq6u)."
                    );
                    std::process::exit(1);
                }
                if matches!(value.as_str(), "completed" | "verified" | "done")
                    && evidence.is_none()
                    && reopen_evidence.is_none()
                {
                    eprintln!(
                        "error: writing status '{value}' requires --evidence <ref> (commit SHA + a named check result; as-wired check for verified; validation/acceptance for done) — 650-dq6u."
                    );
                    std::process::exit(1);
                }
            }

            let ts = resolve_ts(
                flagged("--ts"),
                args.iter().any(|a| a == "--backfill"),
                "set-field",
            );
            let host = flagged("--host").unwrap_or_else(resolve_writer_host);
            let reason = flagged("--reason").unwrap_or_default();

            let compact = loop_status::iso_to_compact(&ts);
            let suffix = format!(
                "{:08x}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.subsec_nanos())
                    .unwrap_or(0)
            );
            let dir = fragments::fragment_dir(&index);
            if let Err(e) = std::fs::create_dir_all(&dir) {
                eprintln!("error: create {}: {e}", dir.display());
                std::process::exit(1);
            }
            let path = dir.join(fragments::fragment_name(&compact, &suffix, &host));

            let mut body = String::new();
            body.push_str("# Ledger fragment — append-only, IMMUTABLE once written.\n");
            body.push_str("# Written by: tillandsias-plan set-field (order 636-9m79).\n");
            body.push_str("#\n");
            body.push_str(
                "# The LWW channel below is named `status:` for historical reasons but\n",
            );
            body.push_str("# corrects ANY field (642-fedr). Re-declaring the packet under\n");
            body.push_str("# `packets:` would be a G-Set no-op and would silently do nothing.\n");
            body.push_str("status:\n");
            body.push_str(&format!("  - packet_id: {pid}\n"));
            body.push_str(&format!("    field: {field}\n"));
            // ORDER 832-698m. The value is EMITTED AS YAML, not interpolated.
            //
            // This line used to be `format!("    value: {value}\n")`. The first
            // production write of a `next_action` — a free-prose field this
            // project had just made load-bearing — began "Wave 2: (1) seed …".
            // The `: ` turned the scalar into a nested mapping, the fragment
            // became unparseable, and `set-field` printed
            // `ok: …next_action <unset> -> Wave 2: (1) seed…` while doing it.
            // The fold then reported `incomplete: 1126 packets from a PARTIAL
            // corpus — 1 fragment(s) could not be read` and the pre-push gate
            // refused, which is the only reason it was caught at all.
            //
            // Free text is the DEFAULT case for next_action, and prose carries
            // colon-space constantly ("Wave 2: …", "REFUTED: …", "note: …").
            // Every other emitted field here is a controlled vocabulary, which
            // is why this survived until the day free text arrived.
            body.push_str(&format!(
                "    value: {}\n",
                serde_yaml::to_string(&value)
                    .unwrap_or_else(|_| format!("{value:?}"))
                    .trim_end()
                    .trim_start_matches("--- ")
                    .trim()
            ));
            body.push_str(&format!("    ts: \"{ts}\"\n"));
            body.push_str(&format!("    host: {host}\n"));
            let mut event_blocks: Vec<(String, String)> = Vec::new();
            if let Some(refs) = &reopen_evidence {
                // The mandatory record for a ladder downgrade (650-dq6u): the
                // falsified event IS the transition; the LWW row above merely
                // mirrors it into the header.
                event_blocks.push((
                    "falsified".to_string(),
                    format!(
                        "falsified '{current}' claim; evidence: {} — status set to '{value}', new attempt epoch",
                        refs.replace('\n', " ")
                    ),
                ));
            } else if let Some(refs) = &evidence {
                // 696-6byc: the event TYPE must follow the status being written.
                // This was hardcoded to `completed`, which was harmless while
                // every status worth attaching evidence to was terminal. The
                // 650-dq6u ladder added the non-terminal `implemented` rung, and
                // from then on an honest `--evidence "..."` on a non-terminal
                // rung emitted a fragment claiming completion in the event
                // stream while the status channel said otherwise —
                // check-fragment-status-loss.sh (correctly) refused it, AFTER
                // the write and AFTER a commit, and its remedy text describes
                // the other violation class. It cost two cycles on this host in
                // one hour before being fixed here.
                let (event_type, prefix) = evidence_event_shape(&value);
                event_blocks.push((
                    event_type.to_string(),
                    format!("{prefix}: {}", refs.replace('\n', " ")),
                ));
            }
            if !reason.is_empty() {
                event_blocks.push(("note".to_string(), reason.replace('\n', " ")));
            }
            if !event_blocks.is_empty() {
                body.push_str("\nevents:\n");
                for (etype, summary) in &event_blocks {
                    body.push_str(&format!("  - packet_id: {pid}\n"));
                    body.push_str("    event:\n");
                    body.push_str(&format!("      type: {etype}\n"));
                    body.push_str(&format!("      ts: \"{ts}\"\n"));
                    body.push_str(&format!("      host: {host}\n"));
                    body.push_str(&format!("      summary: >\n        {summary}\n"));
                }
            }

            if let Err(e) = std::fs::write(&path, body) {
                eprintln!("error: write {}: {e}", path.display());
                std::process::exit(1);
            }
            println!(
                "ok: {pid}.{field} {current} -> {value} ({})",
                path.display()
            );
        }
        "expire-claims" => {
            // ORDER 672-bz7u — 641-e2qa criterion 2: a claim that produces no
            // event within its cycle must return the packet to ready
            // automatically. Lives HERE and not in bash because the claim age
            // is only knowable from the folded ledger, and grepping for it
            // shell-side is the brittle parsing 456 eliminated.
            let mut ttl_hours: i64 = 24;
            let mut dry_run = false;
            let mut now_epoch: Option<i64> = None;
            let mut host = resolve_writer_host();
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--ttl-hours" => {
                        i += 1;
                        ttl_hours = match args.get(i).and_then(|s| s.parse().ok()) {
                            Some(n) => n,
                            None => {
                                eprintln!("error: --ttl-hours needs an integer argument");
                                std::process::exit(2);
                            }
                        };
                    }
                    "--dry-run" => dry_run = true,
                    "--now-epoch" => {
                        i += 1;
                        now_epoch = match args.get(i).and_then(|s| s.parse().ok()) {
                            Some(n) => Some(n),
                            None => {
                                eprintln!("error: --now-epoch needs unix seconds");
                                std::process::exit(2);
                            }
                        };
                    }
                    "--host" => {
                        i += 1;
                        match args.get(i) {
                            Some(h) => host = h.clone(),
                            None => {
                                eprintln!("error: --host needs a value");
                                std::process::exit(2);
                            }
                        }
                    }
                    other => {
                        eprintln!("error: unknown expire-claims flag '{other}'");
                        std::process::exit(2);
                    }
                }
                i += 1;
            }
            if ttl_hours < 1 {
                eprintln!("error: --ttl-hours must be >= 1 (got {ttl_hours})");
                std::process::exit(2);
            }
            let now = now_epoch.unwrap_or_else(|| {
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0)
            });
            let cutoff = answer::epoch_to_iso8601(now - ttl_hours * 3600);
            let now_iso = answer::epoch_to_iso8601(now);
            let (expired, unknown) = expire_claim_candidates(&ledger, &cutoff);
            let label = if dry_run {
                "expire-candidate"
            } else {
                "expired-claim"
            };
            for (order, pid, last) in &expired {
                emit(&format!("{label}\t{order}\t{pid}\t{last}"));
            }
            for (order, pid) in &unknown {
                emit(&format!("unknown-age\t{order}\t{pid}\tnever-expired"));
            }
            if !dry_run && !expired.is_empty() {
                let compact = loop_status::iso_to_compact(&now_iso);
                let suffix = format!(
                    "{:08x}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.subsec_nanos())
                        .unwrap_or(0)
                );
                let dir = fragments::fragment_dir(&index);
                if let Err(e) = std::fs::create_dir_all(&dir) {
                    eprintln!("error: create {}: {e}", dir.display());
                    std::process::exit(1);
                }
                let path = dir.join(fragments::fragment_name(&compact, &suffix, &host));
                let mut body = String::new();
                body.push_str("# Ledger fragment — append-only, IMMUTABLE once written.\n");
                body.push_str("# Written by: tillandsias-plan expire-claims (order 672-bz7u).\n");
                body.push_str("status:\n");
                for (_, pid, _) in &expired {
                    body.push_str(&format!("  - packet_id: {pid}\n"));
                    body.push_str("    field: status\n");
                    body.push_str("    value: ready\n");
                    body.push_str(&format!("    ts: \"{now_iso}\"\n"));
                    body.push_str(&format!("    host: {host}\n"));
                }
                body.push_str("\nevents:\n");
                for (_, pid, last) in &expired {
                    body.push_str(&format!("  - packet_id: {pid}\n"));
                    body.push_str("    event:\n");
                    body.push_str("      type: progress\n");
                    body.push_str(&format!("      ts: \"{now_iso}\"\n"));
                    body.push_str(&format!("      host: {host}\n"));
                    body.push_str(&format!(
                        "      summary: >\n        Claim expired by tillandsias-plan expire-claims: in_progress \
                         with no recorded activity since {last} (TTL {ttl_hours}h). Returned \
                         to ready automatically per 641-e2qa criterion 2.\n"
                    ));
                }
                if let Err(e) = std::fs::write(&path, body) {
                    eprintln!("error: write {}: {e}", path.display());
                    std::process::exit(1);
                }
                emit(&format!("fragment: {}", path.display()));
            }
            let total = query_packets(
                &ledger,
                Some("in_progress"),
                None,
                None,
                None,
                &[],
                usize::MAX,
            )
            .len();
            emit(&format!(
                "summary: in_progress={total} expired={} unknown_age={} ttl_hours={ttl_hours} mode={}",
                expired.len(),
                unknown.len(),
                if dry_run { "dry-run" } else { "write" }
            ));
        }
        other => unknown_subcommand(other),
    }
    log_cli_usage(&subcommand, "answered", start_time.elapsed().as_millis());
}

/// ORDER 672-bz7u. The candidate selection for `expire-claims`, split out so
/// the policy is unit-testable without a filesystem: given the folded ledger
/// and a cutoff timestamp, partition every `in_progress` packet into
/// (expired, unknown_age). A packet expires when its NEWEST recorded event
/// timestamp — any event type; `filed` counts, because a claim filed
/// in_progress with nothing after it is exactly the stranded signature — is
/// lexicographically older than the cutoff. Lexicographic comparison is sound
/// because every ledger timestamp is `YYYY-MM-DDTHH:MM:SSZ` (UTC, fixed
/// width); a timestamp that does not start with four digits is treated as
/// unparseable. A packet with NO parseable timestamp is never expired: age
/// unknown is not age infinite, and guessing marks live work abandoned —
/// the most expensive version of the 641-e2qa bug.
///
/// Expired rows are `(order, packet_id, last_activity_ts)`; unknown-age rows
/// are `(order, packet_id)`.
type ExpiredClaim<'a> = (String, &'a str, String);
type UnknownAgeClaim<'a> = (String, &'a str);

fn expire_claim_candidates<'a>(
    ledger: &'a Ledger,
    cutoff_iso: &str,
) -> (Vec<ExpiredClaim<'a>>, Vec<UnknownAgeClaim<'a>>) {
    let mut expired: Vec<(String, &str, String)> = Vec::new();
    let mut unknown: Vec<(String, &str)> = Vec::new();
    for p in query_packets(
        ledger,
        Some("in_progress"),
        None,
        None,
        None,
        &[],
        usize::MAX,
    ) {
        let Some(pid) = str_field(p, "packet_id") else {
            continue;
        };
        let order = p
            .get("order")
            .map(|v| match v {
                serde_yaml::Value::Number(n) => n.to_string(),
                serde_yaml::Value::String(s) => s.clone(),
                _ => "?".into(),
            })
            .unwrap_or_else(|| "?".into());
        let mut last_ts: Option<String> = None;
        if let Some(seq) = p.get("events").and_then(serde_yaml::Value::as_sequence) {
            for ev in seq {
                let Some(ts) = ev.get("ts").and_then(serde_yaml::Value::as_str) else {
                    continue;
                };
                if ts.len() < 4 || !ts.as_bytes()[..4].iter().all(u8::is_ascii_digit) {
                    continue;
                }
                if last_ts.as_deref().is_none_or(|cur| ts > cur) {
                    last_ts = Some(ts.to_string());
                }
            }
        }
        match last_ts {
            Some(ts) if ts.as_str() < cutoff_iso => expired.push((order, pid, ts)),
            Some(_) => {}
            None => unknown.push((order, pid)),
        }
    }
    (expired, unknown)
}

#[cfg(test)]
mod tests {
    use super::*;
    use answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
    use std::collections::BTreeMap;

    /// 772-4se9. append-event hardcoded host="linux", writing a wrong FACT
    /// into durable events from every non-linux build. The default is now the
    /// compiled platform, so this test — compiled and run on every host that
    /// gates a push — proves no build can fabricate another platform's name.
    #[test]
    fn writer_host_default_is_the_compiled_platform_never_a_fabricated_linux() {
        let host = writer_host_from(None);
        assert_eq!(
            host,
            std::env::consts::OS,
            "absent --host and TILLANDSIAS_HOST_KIND must yield the compiled platform"
        );
        assert_ne!(
            host, "unknown",
            "the platform is a known fact, not an absence"
        );
        #[cfg(not(target_os = "linux"))]
        assert_ne!(
            host, "linux",
            "a non-linux build must never stamp host=linux by default (the 772-4se9 defect)"
        );
        // TILLANDSIAS_HOST_KIND still wins when set (forge), and an EMPTY
        // kind is absence, not an identity.
        assert_eq!(writer_host_from(Some("forge".into())), "forge");
        assert_eq!(writer_host_from(Some(String::new())), std::env::consts::OS);
    }

    /// 772-4se9. agent_id="unknown" is the hand-composed improvisation
    /// 756-hn3a removed: absent identity refuses instead of writing.
    #[test]
    fn writer_agent_refuses_absence_and_the_literal_unknown() {
        assert_eq!(
            writer_agent_from(Some("flag-id".into()), Some("env-id".into())).unwrap(),
            "flag-id",
            "an explicit --agent wins over the environment"
        );
        assert_eq!(
            writer_agent_from(None, Some("windows-yolanda-fable5-20260816t124617z".into()))
                .unwrap(),
            "windows-yolanda-fable5-20260816t124617z",
            "TILLANDSIAS_AGENT_ID is the launch-provided fallback"
        );
        assert!(
            writer_agent_from(None, None).is_err(),
            "no --agent and no TILLANDSIAS_AGENT_ID must refuse, never write 'unknown'"
        );
        assert!(
            writer_agent_from(Some("unknown".into()), None).is_err(),
            "the literal 'unknown' is not an identity from the flag"
        );
        assert!(
            writer_agent_from(None, Some("unknown".into())).is_err(),
            "the literal 'unknown' is not an identity from the environment"
        );
        assert!(
            writer_agent_from(Some("   ".into()), Some(String::new())).is_err(),
            "whitespace and empty values are absence"
        );
    }

    /// 696-6byc. A non-terminal ladder rung written with `--evidence` must NOT
    /// emit a terminal event: doing so makes the fragment claim completion in
    /// the event stream while its status channel says otherwise, which
    /// check-fragment-status-loss.sh refuses — after the write, after a commit.
    #[test]
    fn evidence_event_type_follows_the_status_being_written() {
        let (ty, prefix) = evidence_event_shape("implemented");
        assert_eq!(
            ty, "progress",
            "the non-terminal `implemented` rung must not emit a terminal event"
        );
        assert!(
            prefix.contains("not terminal"),
            "the summary must not read as a completion claim; got: {prefix}"
        );
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik). A fix that simply stopped emitting
    /// `completed` for everything would satisfy the test above while destroying
    /// the signal that real closures depend on. Every genuinely terminal status
    /// must still produce a terminal event.
    #[test]
    fn terminal_statuses_still_emit_a_completion_event() {
        for status in ["completed", "verified", "done", "obsoleted"] {
            let (ty, prefix) = evidence_event_shape(status);
            assert_eq!(
                ty, "completed",
                "terminal status {status:?} must still emit a completion event — \
                 otherwise closures stop being recorded at all"
            );
            assert!(
                !prefix.contains("not terminal"),
                "terminal status {status:?} must not be labelled non-terminal"
            );
        }
    }

    /// ORDER 569. The manifest is read by THREE parties — this binary, the forge
    /// wrapper, and lib-common.sh — and two of them are shell. A token carrying a
    /// space, a comma, or an uppercase letter would parse differently on each
    /// side, so the shape is pinned here rather than discovered in a forge.
    ///
    /// Sorted + unique is not cosmetic either: the shell side compares the two
    /// capability sets as sorted token lists, and a duplicate would make a set
    /// difference report a phantom missing capability.
    /// ORDER 672-bz7u. The expiry policy's three-way partition, pinned:
    /// stale-in_progress expires, fresh-in_progress is untouched, and a
    /// packet with no parseable activity timestamp is reported but NEVER
    /// expired. Completed packets are invisible to the sweep entirely.
    #[test]
    fn expire_claims_partitions_stale_fresh_and_unknown_age() {
        let raw = concat!(
            "packets:\n",
            "  - packet_id: stale\n    order: 1\n    title: \"s\"\n    status: in_progress\n    desired_release: v0.5\n",
            "    events:\n      - type: filed\n        ts: \"2026-08-01T00:00:00Z\"\n",
            "  - packet_id: fresh\n    order: 2\n    title: \"f\"\n    status: in_progress\n    desired_release: v0.5\n",
            "    events:\n      - type: filed\n        ts: \"2026-08-01T00:00:00Z\"\n",
            "      - type: progress\n        ts: \"2026-08-10T00:00:00Z\"\n",
            "  - packet_id: ageless\n    order: 3\n    title: \"a\"\n    status: in_progress\n    desired_release: v0.5\n",
            "  - packet_id: done\n    order: 4\n    title: \"d\"\n    status: completed\n    desired_release: v0.5\n",
            "    events:\n      - type: completed\n        ts: \"2026-08-01T00:00:00Z\"\n",
        );
        let ledger = Ledger::parse(raw, Default::default()).expect("synthetic ledger parses");
        let (expired, unknown) = expire_claim_candidates(&ledger, "2026-08-09T00:00:00Z");
        assert_eq!(
            expired,
            vec![("1".to_string(), "stale", "2026-08-01T00:00:00Z".to_string())],
            "only the stale in_progress claim expires; the fresh one's newest event is inside the TTL"
        );
        assert_eq!(
            unknown,
            vec![("3".to_string(), "ageless")],
            "no-timestamp packets are reported as unknown-age, never expired"
        );
    }

    /// ORDER 831-ezea. The carry-forward contract, both directions in one
    /// fragment so the EXEMPTION is proved rather than asserted: `abandoned` is
    /// touched-and-left-open with no next_action and must be named; `closed` is
    /// touched and CLOSED and must not be, even though it too carries no
    /// next_action. A check that named both would be a check that just counts
    /// packets.
    fn gaps_of(raw: &str) -> Vec<String> {
        let doc: serde_yaml::Value = serde_yaml::from_str(raw).expect("fixture parses");
        carry_forward_gaps(&doc)
    }

    #[test]
    fn carry_forward_names_open_touches_and_exempts_closures() {
        let raw = concat!(
            "packets:\n",
            // Touched, left open, no next_action anywhere -> NAMED.
            "  - packet_id: abandoned\n    order: 1\n    title: \"a\"\n    status: ready\n",
            "    events:\n      - type: progress\n        ts: \"2026-08-19T00:00:00Z\"\n",
            // Touched and CLOSED by a terminal event -> exempt.
            "  - packet_id: closed-by-event\n    order: 2\n    title: \"b\"\n    status: ready\n",
            "    events:\n      - type: completed\n        ts: \"2026-08-19T00:00:00Z\"\n",
            // Touched, left open, but CARRIED at packet level -> exempt.
            "  - packet_id: carried-inline\n    order: 3\n    title: \"c\"\n    status: ready\n",
            "    next_action: \"Run scripts/foo.sh and quote the output.\"\n",
            "    events:\n      - type: progress\n        ts: \"2026-08-19T00:00:00Z\"\n",
            // Declared straight to a terminal status -> exempt.
            "  - packet_id: closed-by-declaration\n    order: 4\n    title: \"d\"\n    status: verified\n",
            "    events:\n      - type: note\n        ts: \"2026-08-19T00:00:00Z\"\n",
            // A DEFINITION with no events is a filing, not a touch -> not named.
            "  - packet_id: merely-filed\n    order: 5\n    title: \"e\"\n    status: ready\n",
        );
        assert_eq!(
            gaps_of(raw),
            vec!["abandoned".to_string()],
            "only the touched-and-left-open packet with no next_action may be named"
        );
    }

    #[test]
    fn carry_forward_reads_the_top_level_event_and_lww_channels() {
        let raw = concat!(
            "events:\n",
            // Put down with a note, nothing carried -> NAMED.
            "  - packet_id: open-note\n    event:\n      type: note\n      ts: \"2026-08-19T00:00:00Z\"\n",
            // Put down with a note, carried on the LWW channel -> exempt.
            "  - packet_id: open-carried\n    event:\n      type: progress\n      ts: \"2026-08-19T00:00:00Z\"\n",
            // Closed on the LWW status channel -> exempt.
            "  - packet_id: closed-lww\n    event:\n      type: note\n      ts: \"2026-08-19T00:00:00Z\"\n",
            // Closed by a terminal event nested under `event:` -> exempt.
            "  - packet_id: closed-nested\n    event:\n      type: done\n      ts: \"2026-08-19T00:00:00Z\"\n",
            "status:\n",
            "  - packet_id: open-carried\n    field: next_action\n    value: \"Rerun the fixture.\"\n    ts: \"2026-08-19T00:00:00Z\"\n    host: h\n",
            "  - packet_id: closed-lww\n    field: status\n    value: completed\n    ts: \"2026-08-19T00:00:00Z\"\n    host: h\n",
        );
        assert_eq!(
            gaps_of(raw),
            vec!["open-note".to_string()],
            "the LWW next_action and status channels must both be read"
        );
    }

    /// ORDER 831-ezea. An EVENT-nested `next_action` must NOT satisfy the
    /// check. The shape is real — 6 occurrences in plan/index.yaml against 65
    /// packet-level, measured 2026-08-19 — but `answer.rs next_action_snippet`
    /// reads the PACKET field, so an event-nested value is never printed on a
    /// `plan next` row. Accepting it would let a fragment pass with a value no
    /// selector can reach, which is this order's own failure class.
    #[test]
    fn an_event_nested_next_action_does_not_satisfy_carry_forward() {
        let raw = concat!(
            "packets:\n",
            "  - packet_id: buried\n    order: 1\n    title: \"a\"\n    status: ready\n",
            "    events:\n      - type: progress\n        ts: \"2026-08-19T00:00:00Z\"\n",
            "        next_action: \"invisible to plan next\"\n",
        );
        assert_eq!(
            gaps_of(raw),
            vec!["buried".to_string()],
            "a next_action the cold-start selector cannot read must not exempt the packet"
        );
    }

    /// An empty or whitespace-only value is not a carry-forward. Filler is the
    /// predictable response to any adoption push, so the check refuses it at
    /// the point where the field is read.
    #[test]
    fn a_blank_next_action_is_not_a_carry_forward() {
        let raw = concat!(
            "packets:\n",
            "  - packet_id: blank\n    order: 1\n    title: \"a\"\n    status: ready\n",
            "    next_action: \"   \"\n",
            "    events:\n      - type: progress\n        ts: \"2026-08-19T00:00:00Z\"\n",
        );
        assert_eq!(gaps_of(raw), vec!["blank".to_string()]);
    }

    /// A fragment that ONLY closes packets is the exemption in isolation — the
    /// shape a closure cycle actually writes. It must produce an EMPTY result,
    /// not a list of every id it mentions.
    #[test]
    fn a_pure_closure_fragment_has_no_carry_forward_gaps() {
        let raw = concat!(
            "events:\n",
            "  - packet_id: one\n    event:\n      type: completed\n      ts: \"2026-08-19T00:00:00Z\"\n",
            "  - packet_id: two\n    event:\n      type: verified\n      ts: \"2026-08-19T00:00:00Z\"\n",
            "status:\n",
            "  - packet_id: one\n    field: status\n    value: completed\n    ts: \"2026-08-19T00:00:00Z\"\n    host: h\n",
            "  - packet_id: two\n    field: status\n    value: verified\n    ts: \"2026-08-19T00:00:00Z\"\n    host: h\n",
        );
        assert!(
            gaps_of(raw).is_empty(),
            "closures are exempt by design: a carry-forward note on a terminal row is a dead letter"
        );
    }

    /// ORDER 812-d45t interaction. A misplaced DEFINITION under `events:`
    /// carries no `event:` key. It is already reported by
    /// `fragment-misplaced-definitions`; counting it as a touch here would put
    /// one authoring mistake into two different advisories.
    #[test]
    fn a_misplaced_definition_is_not_counted_as_a_touch() {
        let raw = concat!(
            "events:\n",
            "  - packet_id: misfiled\n    order: 9\n    title: \"written under the wrong key\"\n    kind: fix\n",
        );
        assert!(gaps_of(raw).is_empty());
    }

    #[test]
    fn the_capability_manifest_is_a_sorted_unique_shell_safe_token_list() {
        let tokens = capability_tokens();
        assert!(!tokens.is_empty(), "the capability manifest is empty");
        for t in &tokens {
            assert!(
                t.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "capability token {t:?} is not [a-z0-9-]; the shell readers split on \
                 whitespace and join with commas"
            );
            assert!(
                t.starts_with(|c: char| c.is_ascii_lowercase()),
                "capability token {t:?} must start with a lowercase letter"
            );
        }
        let mut sorted = tokens.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(
            sorted, tokens,
            "capabilities.txt must be sorted and free of duplicates"
        );
        assert!(
            tokens.contains(&"capabilities"),
            "the manifest must declare `capabilities` itself — the wrapper uses its \
             PRESENCE to tell a post-569 binary from a stale one"
        );
    }

    /// ORDER 569. Every capability this binary CLAIMS must also be documented,
    /// so a human reading `--help` and a machine reading `capabilities` are told
    /// the same story.
    ///
    /// Deliberately one-directional (manifest ⊆ usage, not the reverse): a
    /// subcommand that exists but is not declared makes the expert UNDER-report
    /// itself, which is fail-safe — the wrapper simply refuses to route to it.
    /// The reverse, claiming a capability that does not dispatch, is the
    /// dangerous direction, and it is caught BEHAVIOURALLY by
    /// litmus:expert-capability-skew-honesty, which invokes every declared token.
    #[test]
    fn every_declared_capability_is_documented_in_usage() {
        for t in capability_tokens() {
            assert!(
                USAGE.contains(t),
                "capability {t:?} is declared in capabilities.txt but absent from the \
                 usage text — agents would never learn it exists"
            );
        }
    }

    /// ORDER 583-dv9n. Every DISPATCH arm must be documented in usage too, so
    /// the `main` dispatch, the manifest, and the help text cannot each carry a
    /// different story. This is the arm-side half of the same pin above.
    #[test]
    fn every_dispatch_arm_is_documented_in_usage() {
        for arm in DISPATCH_ARMS {
            assert!(
                USAGE.contains(arm),
                "dispatch arm {arm:?} is absent from the usage text — a subcommand \
                 nobody can discover might as well not exist"
            );
        }
    }

    /// ORDER 583-dv9n. The drift DETECTOR is tested against a synthetic declared
    /// set — the whole point of the split-out helper is that the current tree is
    /// clean, so a mechanism test over the real manifest could never fail. A
    /// manifest that omits a dispatch arm must be reported (sorted, by name).
    #[test]
    fn manifest_drift_reports_arms_a_synthetic_manifest_omits() {
        let drift = manifest_drift_against(&["capabilities", "check", "query"]);
        assert!(
            drift.contains(&"answer"),
            "a manifest that omits `answer` must be reported as drifted"
        );
        assert!(
            drift.contains(&"loop-status"),
            "a manifest that omits `loop-status` must be reported as drifted"
        );
        assert!(
            !drift.contains(&"check"),
            "a declared arm must not be reported as drifted"
        );
        assert!(
            !drift.contains(&"query"),
            "a declared arm must not be reported as drifted"
        );
        assert_eq!(
            drift.len(),
            DISPATCH_ARMS.len() - 3,
            "the drift set must be exactly the omitted arms"
        );
        let mut sorted = drift.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, drift, "the drift set must be reported sorted");
    }

    /// ORDER 523 (R2). `answer::verify` existed but nothing on the RUNTIME path
    /// called it, so the emitter and the checker could disagree about the same
    /// envelope: an answer could ship `confidence: exact` carrying a citation
    /// `verify-answer` would refuse against the same checkout. Self-verifying at
    /// the exit point makes the verifier unavoidable — but only if the downgrade
    /// actually fires, which is what this pins.
    #[test]
    fn a_failing_envelope_is_downgraded_to_unsupported_naming_the_violations() {
        let dir = std::env::temp_dir().join(format!("tilland-523-sv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mk root");
        let fresh = Freshness::new("deadbeef".to_string(), "2026-07-29T00:00:00Z".to_string());

        // A citation into a file that does not exist under `root` — precisely the
        // shape of the observed defect, where the paths were built against one
        // root and resolved against another.
        let mut authority = BTreeMap::new();
        authority.insert("packet_id".to_string(), "demo".to_string());
        let bogus = Citation::new(
            "plan/does-not-exist.yaml".to_string(),
            1,
            5,
            CitationKind::Plan,
            authority,
        );
        let envelope = Envelope::supported(
            "some confident prose",
            vec![bogus],
            Confidence::Exact,
            fresh.clone(),
        );
        // Precondition: it really did construct as a supported answer.
        assert_eq!(envelope.confidence(), Confidence::Exact);

        let out = self_verified(envelope, &dir);
        assert_eq!(
            out.confidence(),
            Confidence::Unsupported,
            "an envelope whose citation cannot resolve MUST be withheld, got: {}",
            out.answer()
        );
        assert!(
            out.citations().is_empty(),
            "a withheld answer must carry zero citations"
        );
        assert!(
            out.answer().starts_with("unsupported:"),
            "the refusal must use the pinned rendering, got: {}",
            out.answer()
        );
        assert!(
            out.answer().contains("FAILED its own citation check"),
            "the refusal must say the answer failed ITS OWN check, got: {}",
            out.answer()
        );

        // And a genuinely verifiable envelope passes through untouched.
        std::fs::create_dir_all(dir.join("plan")).expect("mk plan dir");
        std::fs::write(
            dir.join("plan/real.yaml"),
            "packet_id: demo\nstatus: ready\nline3: x\nline4: y\nline5: z\n",
        )
        .expect("write real file");
        let mut authority2 = BTreeMap::new();
        authority2.insert("packet_id".to_string(), "demo".to_string());
        let good = Citation::new(
            "plan/real.yaml".to_string(),
            1,
            2,
            CitationKind::Plan,
            authority2,
        );
        let ok_env = Envelope::supported("demo is ready", vec![good], Confidence::Exact, fresh);
        let passed = self_verified(ok_env.clone(), &dir);
        assert_eq!(
            passed,
            ok_env.with_citation_root(&dir),
            "a verifiable envelope must pass through byte-identical"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn citation_root_is_carried_and_derivable() {
        let dir = std::env::temp_dir().join(format!("tilland-523-cr-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("plan")).expect("mk plan dir");
        std::fs::write(
            dir.join("plan/real.yaml"),
            "packet_id: demo\nstatus: ready\nline3: x\nline4: y\nline5: z\n",
        )
        .expect("write real file");

        let fresh = Freshness::new("deadbeef".to_string(), "2026-07-29T00:00:00Z".to_string());
        let mut authority = BTreeMap::new();
        authority.insert("packet_id".to_string(), "demo".to_string());
        let good = Citation::new(
            "plan/real.yaml".to_string(),
            1,
            2,
            CitationKind::Plan,
            authority,
        );
        let canonical_dir = dir.canonicalize().expect("canonicalize dir");
        let ok_env = Envelope::supported(
            "demo is ready",
            vec![good.clone()],
            Confidence::Exact,
            fresh,
        );
        let verified = self_verified(ok_env, &dir);
        let root_str = verified.citation_root().expect("citation_root present");
        assert!(!root_str.is_empty(), "citation_root must be non-empty");
        let root_path = Path::new(root_str);
        assert!(
            root_path.is_absolute(),
            "citation_root must be absolute: {root_str}"
        );
        assert!(
            root_path.is_dir(),
            "citation_root must be an existing directory: {root_str}"
        );
        assert_eq!(
            verified.citation_root(),
            Some(canonical_dir.display().to_string().as_str())
        );

        let json = serde_json::to_string(&verified).expect("json");
        let deserialized: Envelope = serde_json::from_str(&json).expect("deserialized");
        assert_eq!(
            deserialized.citation_root(),
            Some(canonical_dir.display().to_string().as_str())
        );

        let violations = answer::verify(
            &deserialized,
            Path::new(deserialized.citation_root().unwrap()),
        );
        assert!(
            violations.is_empty(),
            "derived root verify must pass: {:?}",
            violations
        );

        // Test passing relative path ".": citation_root must canonicalize to non-empty absolute dir
        let rel_env = Envelope::supported(
            "demo is ready",
            vec![],
            Confidence::Retrieved,
            Freshness::new("a".to_string(), "b".to_string()),
        )
        .with_citation_root(Path::new("."));
        let rel_root = rel_env.citation_root().expect("rel citation_root present");
        assert!(
            !rel_root.is_empty(),
            "relative citation_root must be non-empty"
        );
        assert!(
            Path::new(rel_root).is_absolute(),
            "relative citation_root must canonicalize to absolute"
        );
        assert!(
            Path::new(rel_root).is_dir(),
            "relative citation_root must point to an existing directory"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ORDER 582-26mm. The generic filtered reader must reproduce plan_query's
    /// filter contract EXACTLY: exact status/release, pickup_role as a
    /// case-insensitive substring, capability_tags all-must-match, then a
    /// limit. Release is the order-606 additive constraint; the others retain
    /// the semantics project-info's yq/jq pipeline used.
    /// Order 632-retq. The urgency tiers the batch selector scores on, moved
    /// out of an awk block that only a host with jq ever reached.
    #[test]
    fn urgency_ranks_explicit_priority_then_kind_then_unscored() {
        // Tier 1: the operator said so.
        assert_eq!(urgency_rank_and_display(Some("p0"), None), (0, "p0".into()));
        assert_eq!(
            urgency_rank_and_display(Some("p2"), Some("bug")),
            (2, "p2".into()),
            "an explicit priority must dominate a kind that would rank differently"
        );
        // Tier 2: derived from kind, correctness before forward-progress
        // before research.
        assert_eq!(
            urgency_rank_and_display(None, Some("security")),
            (4, "kind:security".into())
        );
        assert_eq!(
            urgency_rank_and_display(None, Some("enhancement")),
            (5, "kind:enhancement".into())
        );
        assert_eq!(
            urgency_rank_and_display(None, Some("docs")),
            (6, "kind:docs".into())
        );
        // Tier 3, and the point of order 630-6hyc: NEITHER signal present is
        // reported as unscored, never coerced to a plausible p3. The coercion
        // made the urgency term a constant 0 for ~82% of the pool, and looked
        // exactly like a genuine p3 while doing it.
        assert_eq!(
            urgency_rank_and_display(None, None),
            (99, "unscored".into())
        );
        assert_eq!(
            urgency_rank_and_display(None, Some("some-new-kind")),
            (99, "unscored".into()),
            "an unrecognised kind is unscored, not silently ranked"
        );
        assert_ne!(
            urgency_rank_and_display(None, None).0,
            urgency_rank_and_display(Some("p3"), None).0,
            "unscored must be distinguishable from p3 — conflating them IS the defect"
        );
    }

    /// An unresolvable dependency counts as BLOCKING, matching the resolver's
    /// conservatism: an id that resolves to nothing is an unanswered question,
    /// not an absent constraint.
    #[test]
    fn dependency_clearance_treats_unknown_ids_as_blocking() {
        let mut terminal = std::collections::BTreeSet::new();
        terminal.insert("done-thing".to_string());
        assert!(dependencies_are_clear(&[], &terminal), "no deps is clear");
        assert!(dependencies_are_clear(
            &["done-thing".to_string()],
            &terminal
        ));
        assert!(
            !dependencies_are_clear(&["open-thing".to_string()], &terminal),
            "an open dependency blocks"
        );
        assert!(
            !dependencies_are_clear(&["typo-or-retired".to_string()], &terminal),
            "an id that resolves to nothing blocks — it is a question, not an absence"
        );
        assert!(
            !dependencies_are_clear(
                &["done-thing".to_string(), "open-thing".to_string()],
                &terminal
            ),
            "one blocking dependency blocks the packet"
        );
    }

    #[test]
    fn query_packets_reproduces_plan_query_filter_semantics() {
        let led = Ledger::parse(
            "plan_index:\n  steps:\n\
             \x20 - packet_id: p1\n    order: 1\n    status: ready\n    pickup_role: linux\n    desired_release: v0.5\n    release_target: milestone-a\n    capability_tags: [plan, crdt]\n\
             \x20 - packet_id: p2\n    order: 2\n    status: blocked\n    pickup_role: windows\n    desired_release: v0.6\n    capability_tags: [plan]\n\
             \x20 - packet_id: p3\n    order: 3\n    status: ready\n    pickup_role: Linux-Mutable\n    desired_release: v0.5\n    capability_tags: [crdt, plan]\n\
             \x20 - packet_id: p4\n    order: 4\n    status: ready\n    capability_tags: []\n",
            Default::default(),
        )
        .expect("parse");

        // Exact status only.
        let ready = query_packets(&led, Some("ready"), None, None, None, &[], 0);
        assert_eq!(ids(ready), vec!["p1", "p3", "p4"]);

        // pickup_role is a case-insensitive SUBSTRING.
        let linux = query_packets(&led, None, Some("linux"), None, None, &[], 0);
        assert_eq!(ids(linux), vec!["p1", "p3"]);

        // desired_release is exact; packets without it never match an explicit
        // release constraint.
        let v05 = query_packets(&led, None, None, None, Some("v0.5"), &[], 0);
        assert_eq!(ids(v05), vec!["p1", "p3"]);
        assert!(query_packets(&led, None, None, None, Some("V0.5"), &[], 0).is_empty());

        // capability_tags all-must-match, independent of order in the list.
        let crdt_plan = query_packets(
            &led,
            None,
            None,
            None,
            None,
            &["plan".into(), "crdt".into()],
            0,
        );
        assert_eq!(ids(crdt_plan), vec!["p1", "p3"]);

        // Combined filters narrow the set.
        let combo = query_packets(
            &led,
            Some("ready"),
            Some("linux"),
            None,
            Some("v0.5"),
            &["crdt".into()],
            0,
        );
        assert_eq!(ids(combo), vec!["p1", "p3"]);

        // Limit caps the result.
        let limited = query_packets(&led, Some("ready"), None, None, None, &[], 2);
        assert_eq!(ids(limited), vec!["p1", "p3"]);

        // A packet with no capability_tags matches a tag filter only if the
        // filter is empty.
        let empty_tag = query_packets(&led, Some("ready"), None, None, None, &["plan".into()], 0);
        assert_eq!(ids(empty_tag), vec!["p1", "p3"]);

        let projected = query_json_projection(led.resolve("p1").expect("p1 resolves"));
        assert_eq!(projected["desired_release"], serde_json::json!("v0.5"));
        assert_eq!(
            projected["release_target"],
            serde_json::json!("milestone-a")
        );
        let absent = query_json_projection(led.resolve("p4").expect("p4 resolves"));
        assert!(absent.get("desired_release").is_some_and(|v| v.is_null()));
        assert!(absent.get("release_target").is_some_and(|v| v.is_null()));
    }

    #[test]
    fn query_constraint_parser_refuses_missing_unknown_and_invalid_values() {
        let args = [
            "--status",
            "ready",
            "--release",
            "v0.5",
            "--tag",
            "experts",
            "--limit",
            "0",
            "--json",
        ]
        .map(str::to_string);
        let parsed = parse_query_options(&args).expect("valid constraints parse");
        assert_eq!(parsed.status.as_deref(), Some("ready"));
        assert_eq!(parsed.release.as_deref(), Some("v0.5"));
        assert_eq!(parsed.tags, vec!["experts"]);
        assert_eq!(parsed.limit, 0);
        assert!(parsed.json);

        for bad in [
            vec!["--release"],
            vec!["--release", "--json"],
            vec!["--role", ""],
            vec!["--tag", ""],
            vec!["--status", "ready", "--status", "blocked"],
            vec!["--role", "linux", "--role", "any"],
            vec!["--release", "v0.5", "--release", "v0.6"],
            vec!["--limit", "1", "--limit", "2"],
            vec!["--json", "--json"],
            vec!["--limit", "many"],
            vec!["--not-a-constraint", "value"],
        ] {
            let bad: Vec<String> = bad.into_iter().map(str::to_string).collect();
            assert!(
                parse_query_options(&bad).is_err(),
                "invalid constraints must be explicit errors: {bad:?}"
            );
        }
    }

    fn ids(packets: Vec<&serde_yaml::Value>) -> Vec<String> {
        packets
            .iter()
            .map(|p| {
                p.get("packet_id")
                    .and_then(serde_yaml::Value::as_str)
                    .unwrap()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn query_json_projection_includes_lease_field() {
        let raw = concat!(
            "packet_id: unleased-sample\n",
            "order: 123\n",
            "title: \"Unleased\"\n",
            "status: ready\n",
            "desired_release: v0.5\n",
        );
        let val: serde_yaml::Value = serde_yaml::from_str(raw).unwrap();
        let proj = query_json_projection(&val);
        assert!(proj.get("lease").is_some());
        assert_eq!(proj["lease"], serde_json::Value::Null);
    }

    #[test]
    fn utc_now_iso_produces_non_empty_utc_format() {
        let ts = utc_now_iso();
        assert!(ts.ends_with('Z'));
        assert!(ts.contains('T'));
        assert_eq!(ts.len(), 20);
    }
}
