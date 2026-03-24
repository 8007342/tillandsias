//! CLI argument parser for Tillandsias.
//!
//! Determines whether the binary should start in tray mode (no args)
//! or CLI attach mode (`tillandsias <path>`).

use std::path::PathBuf;

/// How the application should run based on CLI arguments.
pub enum CliMode {
    /// No arguments — start the system tray application.
    Tray,

    /// `tillandsias init` — pre-build container images.
    Init,

    /// A project path was given — launch an interactive container.
    Attach {
        /// Absolute path to the project directory.
        path: PathBuf,
        /// Image short name (e.g., "forge" -> "tillandsias-forge:latest").
        image: String,
        /// Show verbose debug output.
        debug: bool,
        /// Drop into bash shell instead of default entrypoint (troubleshooting).
        bash: bool,
    },
}

const USAGE: &str = "\
Tillandsias — development environment manager

USAGE:
    tillandsias                     Start the system tray app
    tillandsias <path>              Attach a container to a project
    tillandsias <path> --bash       Drop into fish shell for troubleshooting
    tillandsias init                Pre-build container images
    tillandsias --help              Show this help

OPTIONS:
    --image <name>    Container image to use (default: forge)
                      Maps to tillandsias-<name>:latest
    --debug           Show verbose output including podman commands
    --bash            Drop into bash shell instead of default entrypoint
";

/// Parse CLI arguments and return the appropriate mode.
///
/// Returns `None` if `--help` was requested (usage is printed to stdout
/// and the caller should exit).
pub fn parse() -> Option<CliMode> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // No arguments — tray mode.
    if args.is_empty() {
        return Some(CliMode::Tray);
    }

    // `tillandsias init` — pre-build images.
    if args.first().map(|s| s.as_str()) == Some("init") {
        return Some(CliMode::Init);
    }

    let mut path: Option<PathBuf> = None;
    let mut image = "forge".to_string();
    let mut debug = false;
    let mut bash = false;
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                print!("{USAGE}");
                return None;
            }
            "--image" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("Error: --image requires a value");
                    print!("{USAGE}");
                    return None;
                }
                image = args[i].clone();
            }
            "--debug" => {
                debug = true;
            }
            "--bash" => {
                bash = true;
            }
            arg => {
                // Skip Tauri-injected flags (they start with --)
                if arg.starts_with('-') {
                    // Unknown flag — ignore (could be Tauri internals)
                    i += 1;
                    continue;
                }
                // Positional argument = project path
                path = Some(PathBuf::from(arg));
            }
        }
        i += 1;
    }

    match path {
        Some(p) => Some(CliMode::Attach {
            path: p,
            image,
            debug,
            bash,
        }),
        None => {
            // Had flags but no path — tray mode (could be Tauri flags)
            Some(CliMode::Tray)
        }
    }
}
