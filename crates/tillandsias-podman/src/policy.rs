//! Pure policy helpers for auditing Podman launch argv.
//!
//! This module deliberately does not execute Podman. It gives callers and
//! source audits one small place to ask whether a launch still carries the
//! immutable safety envelope and whether a raw passthrough option is part of
//! the intentionally tiny escape hatch.
//!
//! @trace spec:podman-orchestration, spec:podman-container-spec, spec:security-privacy-isolation

use std::fmt;

/// The safety envelope that remains mandatory for every Tillandsias launch.
///
/// `--rm` is intentionally not included here: persistent web-mode containers
/// are allowed to outlive their originating click, but they may not weaken any
/// of these four hardening controls.
pub const MANDATORY_HARDENING_FLAGS: [&str; 4] = [
    "--userns=keep-id",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--security-opt=label=disable",
];

/// A launch-argv policy violation found before any Podman process is spawned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchArgvError {
    /// Launch argv must be direct Podman argv beginning with the `run`
    /// subcommand, not a shell-joined command string.
    MissingRunSubcommand,
    /// A `podman run` argv without an image is malformed and cannot be audited
    /// safely because trailing command arguments have no stable boundary.
    MissingImage,
    /// The argv omitted one or more immutable hardening flags.
    MissingMandatoryHardening(Vec<&'static str>),
    /// The argv carried a second option that can weaken a mandatory flag even
    /// when the canonical flag is also present.
    WeakensMandatoryHardening(String),
}

impl fmt::Display for LaunchArgvError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LaunchArgvError::MissingRunSubcommand => {
                write!(f, "launch argv must begin with the direct `run` subcommand")
            }
            LaunchArgvError::MissingImage => {
                write!(
                    f,
                    "launch argv must include an image before command arguments"
                )
            }
            LaunchArgvError::MissingMandatoryHardening(flags) => {
                write!(
                    f,
                    "launch argv is missing mandatory hardening flags: {}",
                    flags.join(", ")
                )
            }
            LaunchArgvError::WeakensMandatoryHardening(flag) => {
                write!(f, "launch argv weakens mandatory hardening with `{flag}`")
            }
        }
    }
}

impl std::error::Error for LaunchArgvError {}

/// Return true when `argv` contains the immutable hardening envelope.
///
/// Both Podman spellings are accepted: `--key=value` and `--key value`.
pub fn has_mandatory_hardening_flags(argv: &[String]) -> bool {
    missing_mandatory_hardening_flags(argv).is_empty()
}

/// Return the canonical mandatory flags missing from `argv`.
///
/// This intentionally returns canonical spellings so audit output stays
/// deterministic even if an input uses Podman's split `--key value` form.
pub fn missing_mandatory_hardening_flags(argv: &[String]) -> Vec<&'static str> {
    MANDATORY_HARDENING_FLAGS
        .iter()
        .copied()
        .filter(|flag| !contains_flag(argv, flag))
        .collect()
}

/// Return true when an opaque passthrough option is allowed to escape the typed
/// builder boundary.
///
/// Raw options are an anti-bypass aperture, not a general extension surface.
/// Today the only needed shape is the GPU discovery helper's `--device=<path>`
/// output; everything else should use a typed `ContainerSpec` method.
pub fn is_allowlisted_passthrough_option(option: &str) -> bool {
    option.starts_with("--device=") && option.len() > "--device=".len()
}

/// Return passthrough options that are not on the narrow anti-bypass allowlist.
pub fn disallowed_passthrough_options(options: &[String]) -> Vec<&str> {
    options
        .iter()
        .map(String::as_str)
        .filter(|option| !is_allowlisted_passthrough_option(option))
        .collect()
}

/// Validate a direct `podman run` argv vector before launch.
///
/// Validation only considers Podman launch options before the image boundary;
/// command arguments after the image cannot spoof required policy flags.
pub fn validate_launch_argv(argv: &[String]) -> Result<(), LaunchArgvError> {
    if argv.first().map(String::as_str) != Some("run") {
        return Err(LaunchArgvError::MissingRunSubcommand);
    }

    let image_index = image_index(argv).ok_or(LaunchArgvError::MissingImage)?;
    let launch_options = &argv[1..image_index];

    let missing = missing_mandatory_hardening_flags(launch_options);
    if !missing.is_empty() {
        return Err(LaunchArgvError::MissingMandatoryHardening(missing));
    }

    if let Some(flag) = weakening_hardening_flag(launch_options) {
        return Err(LaunchArgvError::WeakensMandatoryHardening(flag));
    }

    Ok(())
}

fn contains_flag(argv: &[String], canonical: &str) -> bool {
    if argv.iter().any(|arg| arg == canonical) {
        return true;
    }

    let Some((flag, value)) = canonical.split_once('=') else {
        return false;
    };
    argv.windows(2)
        .any(|pair| pair[0] == flag && pair[1] == value)
}

fn image_index(argv: &[String]) -> Option<usize> {
    let mut index = 1;
    while index < argv.len() {
        let arg = argv[index].as_str();
        if arg == "--" {
            return (index + 1 < argv.len()).then_some(index + 1);
        }
        if !arg.starts_with('-') {
            return Some(index);
        }

        index += if option_takes_value(arg) { 2 } else { 1 };
    }
    None
}

fn option_takes_value(arg: &str) -> bool {
    if arg.contains('=') {
        return false;
    }

    matches!(
        arg,
        "--name"
            | "--hostname"
            | "--cap-add"
            | "--cap-drop"
            | "--security-opt"
            | "--userns"
            | "--pids-limit"
            | "--env"
            | "--network"
            | "--mount"
            | "--tmpfs"
            | "--device"
            | "--entrypoint"
            | "-p"
            | "-v"
    )
}

fn weakening_hardening_flag(argv: &[String]) -> Option<String> {
    let mut index = 0;
    while index < argv.len() {
        let arg = argv[index].as_str();
        let next = argv.get(index + 1).map(String::as_str);

        if arg == "--privileged"
            || arg.starts_with("--privileged=")
            || flag_value(arg, next, "--userns").is_some_and(|value| value != "keep-id")
            || flag_value(arg, next, "--cap-add").is_some_and(|value| value == "ALL")
            || flag_value(arg, next, "--security-opt").is_some_and(is_weakening_security_opt)
        {
            return Some(match next {
                Some(value) if option_takes_value(arg) && !arg.contains('=') => {
                    format!("{arg} {value}")
                }
                _ => arg.to_string(),
            });
        }

        index += if option_takes_value(arg) { 2 } else { 1 };
    }
    None
}

fn flag_value<'a>(arg: &'a str, next: Option<&'a str>, flag: &str) -> Option<&'a str> {
    if arg == flag {
        return next;
    }
    arg.strip_prefix(flag)?.strip_prefix('=')
}

fn is_weakening_security_opt(value: &str) -> bool {
    value == "no-new-privileges=false"
        || value
            .strip_prefix("label=")
            .is_some_and(|label| label != "disable")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hardened_run() -> Vec<String> {
        vec![
            "run".into(),
            "--userns=keep-id".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges".into(),
            "--security-opt=label=disable".into(),
            "example:v1".into(),
        ]
    }

    #[test]
    fn mandatory_hardening_accepts_inline_and_split_flag_spellings() {
        let argv = vec![
            "--userns".into(),
            "keep-id".into(),
            "--cap-drop".into(),
            "ALL".into(),
            "--security-opt".into(),
            "no-new-privileges".into(),
            "--security-opt".into(),
            "label=disable".into(),
        ];

        assert!(has_mandatory_hardening_flags(&argv));
    }

    #[test]
    fn mandatory_hardening_reports_canonical_missing_flags() {
        let argv = vec!["--cap-drop=ALL".into()];

        assert_eq!(
            missing_mandatory_hardening_flags(&argv),
            vec![
                "--userns=keep-id",
                "--security-opt=no-new-privileges",
                "--security-opt=label=disable",
            ]
        );
    }

    #[test]
    fn passthrough_allowlist_keeps_only_gpu_device_flags() {
        let options = vec![
            "--device=/dev/dri/renderD128".into(),
            "--network=host".into(),
            "--privileged".into(),
        ];

        assert!(is_allowlisted_passthrough_option(
            "--device=/dev/dri/renderD128"
        ));
        assert_eq!(
            disallowed_passthrough_options(&options),
            vec!["--network=host", "--privileged"]
        );
    }

    #[test]
    fn launch_validation_accepts_persistent_direct_argv() {
        let mut argv = hardened_run();
        argv.insert(1, "-d".into());

        assert_eq!(validate_launch_argv(&argv), Ok(()));
        assert!(!argv.contains(&"--rm".to_string()));
    }

    #[test]
    fn launch_validation_rejects_shell_joined_or_incomplete_argv() {
        assert_eq!(
            validate_launch_argv(&["podman run --rm example:v1".into()]),
            Err(LaunchArgvError::MissingRunSubcommand)
        );
        assert_eq!(
            validate_launch_argv(&hardened_run()[..5]),
            Err(LaunchArgvError::MissingImage)
        );
    }

    #[test]
    fn command_args_after_image_cannot_spoof_hardening() {
        let argv = vec![
            "run".into(),
            "example:v1".into(),
            "--userns=keep-id".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges".into(),
            "--security-opt=label=disable".into(),
        ];

        assert_eq!(
            validate_launch_argv(&argv),
            Err(LaunchArgvError::MissingMandatoryHardening(
                MANDATORY_HARDENING_FLAGS.to_vec()
            ))
        );
    }

    #[test]
    fn launch_validation_rejects_conflicting_weakeners() {
        let mut argv = hardened_run();
        argv.insert(5, "--userns=host".into());

        assert_eq!(
            validate_launch_argv(&argv),
            Err(LaunchArgvError::WeakensMandatoryHardening(
                "--userns=host".into()
            ))
        );
    }
}
