//! ORDER 626-w3fn (b) — tell the user something is happening during the
//! multi-minute workspace bring-up.
//!
//! THE DEFECT. Every stage of bring-up was silent or `--debug`-gated, so a user
//! starting a workspace saw a blank terminal for minutes. The field report this
//! packet was filed from records an operator concluding the flow had hung and
//! closing the window — it had not hung, it was working. A blank window is
//! indistinguishable from a hang, which makes silence a correctness problem and
//! not a polish one.
//!
//! WHY A NEW SURFACE RATHER THAN PROMOTING THE EXISTING EVENTS. The packet's own
//! cheaper suggestion was to un-gate `emit_launch_event`. Its line is
//!
//!     event:container_launch stage=vault state=starting container=tillandsias-vault
//!
//! which names `container` and `vault` — both on spec:tray-ux's explicit ban
//! list — is a machine wire format rather than prose, and is a PINNED API whose
//! `key=value` field order litmus assertions depend on. So that stream stays
//! exactly as it is (spec:tray-ux classes diagnostics as agent-facing, under
//! normal engineering discipline) and this is additive.
//!
//! WHY ONE SENTENCE AND A COUNTER, RATHER THAN A LABEL PER STAGE. This is the
//! approved surface, and the shape is also the safest one available: the stage
//! NAMES are all internals (`vault`, `proxy`, `router`, `enclave-network`), so
//! any design that renders them has to launder each one into user vocabulary and
//! stays one new stage away from leaking. A fixed sentence plus `(N of M)` shows
//! motion and remaining work — which is what distinguishes it from a blank
//! window — and cannot leak a banned word by construction.
//!
//! APPROVAL. spec:tray-ux makes Tlatoāni approval MANDATORY for any user-visible
//! surface and forbids implementing before it is recorded. Granted by the
//! operator 2026-08-29 for this exact template, recorded as an operator_note on
//! 626-w3fn. Three hosts had previously verified the approval's ABSENCE and
//! declined to proceed; the gate held each time.

use std::io::IsTerminal;

/// The approved sentence. Kept as one constant so the test below and the
/// emitter cannot drift apart, and so a reviewer can diff the approved string
/// against the ledger's operator_note in one place.
const APPROVED_SENTENCE: &str = "Getting your workspace ready…";

/// The approved prefix, matching every other user-facing line the headless lane
/// emits (`[tillandsias] …`).
const PREFIX: &str = "[tillandsias]";

/// Emits the approved bring-up progress line, once per stage.
///
/// `total` is the number of stages the caller intends to report. It is passed
/// in rather than counted, because the honest denominator is what the caller
/// KNOWS it will do, and a count discovered as it goes would render `(1 of 1)`
/// on the first line of a five-stage run.
pub struct BringUpProgress {
    current: usize,
    total: usize,
    enabled: bool,
}

impl BringUpProgress {
    /// `enabled` is resolved once, at construction, from whether stdout is a
    /// terminal.
    ///
    /// NOT A DEBUG GATE — the whole packet is that this must appear WITHOUT
    /// `--debug`. It is the same refinement surface (a) already carries
    /// (`LoginInputMode::Terminal`): when output is being piped or captured,
    /// the consumer is a machine and progress prose is noise in its stream. A
    /// user watching a terminal is exactly the case the packet is about, and
    /// that user always sees it.
    pub fn new(total: usize) -> Self {
        Self {
            current: 0,
            total,
            enabled: std::io::stdout().is_terminal(),
        }
    }

    /// Construct with the terminal decision forced. Test seam ONLY — production
    /// callers use [`BringUpProgress::new`] so the decision has one source.
    ///
    /// `#[cfg(test)]` rather than `#[allow(dead_code)]`: it really is unused
    /// outside tests, and saying so in the type system is better than silencing
    /// the lint that noticed.
    #[cfg(test)]
    pub fn with_enabled(total: usize, enabled: bool) -> Self {
        Self {
            current: 0,
            total,
            enabled,
        }
    }

    /// The line for the next stage, without printing it. Pure, so the
    /// vocabulary test can assert over every line this type can ever produce.
    ///
    /// Saturates at `total` rather than counting past it: `(6 of 5)` reads as a
    /// bug to a user and would undermine the one thing the counter is for.
    pub fn next_line(&mut self) -> String {
        self.current = (self.current + 1).min(self.total.max(1));
        format!(
            "{PREFIX} {APPROVED_SENTENCE} ({} of {})",
            self.current,
            self.total.max(1)
        )
    }

    /// Advance one stage and report it to the user.
    pub fn step(&mut self) {
        let line = self.next_line();
        if self.enabled {
            println!("{line}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// spec:tray-ux's ban list, verbatim from the requirement text:
    /// "Internals vocabulary (VM, WSL, enclave, mirror, vault, container,
    /// podman, provisioning) MUST NOT appear in end-user-facing UX text."
    /// Extended with the neighbouring internals this codebase actually says, so
    /// the guard is about the RULE rather than about the eight example words.
    const BANNED: &[&str] = &[
        "vm",
        "wsl",
        "enclave",
        "mirror",
        "vault",
        "container",
        "podman",
        "provisioning",
        "proxy",
        "router",
        "sidecar",
        "image",
        "daemon",
        "socket",
        "systemd",
        "toolbox",
        "nix",
        "registry",
    ];

    /// EXIT CRITERION 3, as a test over the emitted strings rather than a
    /// promise in a comment.
    ///
    /// Asserted over EVERY line the type can produce for a realistic range of
    /// totals, not over one sample: a vocabulary guard that checks a single
    /// rendering proves nothing about the next one.
    #[test]
    fn no_internals_vocabulary_in_any_emitted_line() {
        for total in 1..=12 {
            let mut p = BringUpProgress::with_enabled(total, true);
            for _ in 0..total {
                let line = p.next_line().to_ascii_lowercase();
                for banned in BANNED {
                    assert!(
                        !line.contains(banned),
                        "emitted line leaked internals vocabulary '{banned}': {line}"
                    );
                }
            }
        }
    }

    /// The line is EXACTLY the approved template. If someone rewords it, this
    /// fails and sends them back to the operator — which is the point of the
    /// approval being for an exact surface rather than an intent.
    #[test]
    fn line_matches_the_approved_template() {
        let mut p = BringUpProgress::with_enabled(5, true);
        assert_eq!(
            p.next_line(),
            "[tillandsias] Getting your workspace ready… (1 of 5)"
        );
        assert_eq!(
            p.next_line(),
            "[tillandsias] Getting your workspace ready… (2 of 5)"
        );
    }

    #[test]
    fn counter_advances_and_saturates_rather_than_overrunning() {
        let mut p = BringUpProgress::with_enabled(2, true);
        assert!(p.next_line().contains("(1 of 2)"));
        assert!(p.next_line().contains("(2 of 2)"));
        // A caller that steps more often than it declared must not print
        // "(3 of 2)" — that reads as a bug and discredits the counter.
        assert!(p.next_line().contains("(2 of 2)"));
    }

    /// THE DENOMINATOR MUST MATCH THE CALL SITES, checked against the real
    /// source rather than against a copy of the number.
    ///
    /// This is the invariant a reader cannot verify by eye: `BringUpProgress::new(5)`
    /// and five `progress.step()` calls sit ~15 lines apart in a 25k-line file,
    /// and either one can be edited without the other. Too few steps and the
    /// user never sees "(5 of 5)" — the run appears to stall at 4 forever, which
    /// is precisely the "is it hung?" reading this packet exists to remove. Too
    /// many and the counter saturates, silently under-reporting the work.
    #[test]
    fn declared_total_matches_the_number_of_steps_in_run_opencode_mode() {
        let src = include_str!("main.rs");
        let start = src
            .find("fn run_opencode_mode(")
            .expect("run_opencode_mode must exist — if it was renamed, repoint this test");
        // Bound the window at the next top-level `fn ` so a later function's
        // steps cannot be counted into this one.
        let rest = &src[start + 1..];
        let end = rest
            .find("\nfn ")
            .map(|i| start + 1 + i)
            .unwrap_or(src.len());
        let body = &src[start..end];

        let declared = body
            .find("BringUpProgress::new(")
            .map(|i| {
                let after = &body[i + "BringUpProgress::new(".len()..];
                after
                    .split(')')
                    .next()
                    .unwrap_or("")
                    .trim()
                    .parse::<usize>()
                    .expect("the total must be a literal so this test can read it")
            })
            .expect("run_opencode_mode must construct a BringUpProgress");

        let steps = body.matches("progress.step()").count();
        assert_eq!(
            declared, steps,
            "BringUpProgress::new({declared}) but {steps} progress.step() calls in \
             run_opencode_mode — the user would see a counter that never reaches its \
             total, or one that saturates early"
        );
    }

    /// A zero total is a caller bug, but it must not render "(1 of 0)".
    #[test]
    fn zero_total_degrades_to_one_not_to_nonsense() {
        let mut p = BringUpProgress::with_enabled(0, true);
        assert!(p.next_line().contains("(1 of 1)"), "{}", p.next_line());
    }

    /// The counter still advances when output is suppressed, so a piped run and
    /// a terminal run agree about which stage they are on. Divergent state
    /// between the two modes is how a "works in the terminal only" bug starts.
    #[test]
    fn disabled_still_advances_the_counter() {
        let mut p = BringUpProgress::with_enabled(3, false);
        p.step();
        p.step();
        assert!(p.next_line().contains("(3 of 3)"));
    }
}
