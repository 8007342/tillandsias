// @trace order:2031-dwwy, order:2029-39bt, spec:command-runtime
//
// child_env.rs — THE ONE child-environment builder (design 2029-39bt §4,
// openspec change lua-door-environment-inheritance, spec req ae550c5d).
//
// Every door onto the runtime — proc.run, proc.spawn, proc.chain, the
// positional sh.run / expert.shell (lua_predicate) and `tillandsias-plan run`
// (run_verb) — gets its child's environment from `ChildEnv` here, so "which
// variables reach a child" has ONE answer. The steps, in the order applied
// (design §4.1; a later step wins for a name it sets):
//
//   0 the hard block — class A `ENV_BLOCK_NEVER` + `credential_shape`, class B
//     `ENV_BLOCK_INHERIT` — a filter on every inherited step and a refusal
//     for a per-call class-A literal;
//   1 the base passthrough `ENV_BASE_PASSTHROUGH` (orders 1593-1ny6, 1838-nwyn);
//   2 the project namespace, every runner `TILLANDSIAS_*` name;
//   3 the declared inherit set (`-- @env-profile` / `-- @env-inherit` in a
//     script header, `--env-profile` / `--env-inherit` on the run verb);
//   4 the fixed overrides `ENV_FIXED`;
//   5 the call's own literals (`proc.run{env=...}`, `run --env K=V`).
//
// STEP 2 DURING THE CENSUS (tasks 1.8, first half). The full class-A filter on
// the project namespace is WARN-ONLY in this landing: 2031-h5ru's narrow filter
// (`project_variable_passes`: a last segment SECRET, PASS or PASSWORD) stays
// enforced, and every OTHER name the full block would drop still passes. With
// TILLANDSIAS_ENV_BLOCK_WARN=1 those names are recorded — names and class
// only — in the script-run timing record (`env_block_would_drop`), or once on
// stderr from a process without one. The flip, which deletes the warn branch
// and enforces the block on step 2, is a later landing after the census. Class
// A on the declared step and on per-call literals is enforced from day one.
//
// Names, never values: nothing here formats a value into a message.

use std::ffi::{OsStr, OsString};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// Step 1. The environment a child starts from: NOTHING is inherited except
/// this set (and steps 2 and 3). One constant, so "which variables leak into
/// a check" has one answer. (Moved from lua_predicate's
/// PROC_RUN_BASE_ENV_PASSTHROUGH, name for name.)
pub const ENV_BASE_PASSTHROUGH: &[&str] = &[
    "PATH",
    "HOME",
    "TMPDIR",
    // A Windows child without these cannot start many programs at all.
    "SystemRoot",
    "SYSTEMROOT",
    "SystemDrive",
    "WINDIR",
    "COMSPEC",
    "PATHEXT",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    // ORDER 1593-1ny6. Where this build's artifacts live, so a nested runner a
    // Lua fixture starts (run-litmus-test.sh, plan-binary-probe.sh, cargo)
    // finds the same plan binary the caller runs. Dropped, a linked worktree
    // on a shared target has no ./target of its own and the nested runner
    // reports blocked:litmus-no-plan-binary: test-litmus-verdict-reads-stdout-
    // only.lua refused 5-of-5 there (the Mac, then yolanda-windows, 2026-10-11).
    // A path, not a secret; deciders that pass --target-dir explicitly
    // (check-cross-target-build.lua, 958-w4kq) now agree with the inherited one.
    "CARGO_TARGET_DIR",
    // ORDER 1838-nwyn. The caller's user-session handles, passed only when the
    // caller has them (an unset key is never invented). `toolbox run` and
    // rootless podman locate the user runtime dir and session bus through
    // these; scrubbed, `toolbox run --container tillandsias-builder true` fails
    // "failed to initialize container" under the run door and the land queue
    // evicted three candidates (2026-10-23). Paths/sockets, not secrets.
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
];

/// Step 4. Fixed values every child gets, so a verdict cannot depend on the
/// caller's locale, timezone or a git credential prompt. (Moved from
/// lua_predicate's PROC_RUN_BASE_ENV_FIXED.)
pub const ENV_FIXED: &[(&str, &str)] = &[
    ("LC_ALL", "C"),
    ("LANG", "C"),
    ("TZ", "UTC"),
    ("GIT_TERMINAL_PROMPT", "0"),
];

/// The sub-class a class-A refusal names (spec c3d80b67, 7120e541).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NeverClass {
    /// Loads code into a dynamically linked child or an interpreter.
    Loader,
    /// Runs or reshapes code before a shell script's first line.
    ShellInit,
    /// Names a program a tool will run (git, ssh, sudo, nix).
    ProgramNaming,
    /// Spelled like a credential (design §4.2 A2).
    CredentialShape,
}

impl NeverClass {
    pub fn token(self) -> &'static str {
        match self {
            NeverClass::Loader => "loader",
            NeverClass::ShellInit => "shell-init",
            NeverClass::ProgramNaming => "program-naming",
            NeverClass::CredentialShape => "credential-shape",
        }
    }
}

/// Class A1 (design §4.2): sudo's default removal table plus git's
/// program-naming variables. A trailing `*` is a prefix (the table's own
/// grammar; never a script's — scripts may not declare globs).
pub const ENV_BLOCK_NEVER: &[(&str, NeverClass)] = &[
    ("LD_*", NeverClass::Loader),
    ("DYLD_*", NeverClass::Loader),
    ("_RLD*", NeverClass::Loader),
    ("LDR_*", NeverClass::Loader),
    ("LIBPATH", NeverClass::Loader),
    ("SHLIB_PATH", NeverClass::Loader),
    ("GCONV_PATH", NeverClass::Loader),
    ("NLSPATH", NeverClass::Loader),
    ("LOCALDOMAIN", NeverClass::Loader),
    ("RES_OPTIONS", NeverClass::Loader),
    ("HOSTALIASES", NeverClass::Loader),
    ("PERL5OPT", NeverClass::Loader),
    ("PERLLIB", NeverClass::Loader),
    ("PERL5LIB", NeverClass::Loader),
    ("PERL5DB", NeverClass::Loader),
    ("PERLIO_DEBUG", NeverClass::Loader),
    // Also banned by project rule (no Python in this tree).
    ("PYTHON*", NeverClass::Loader),
    ("RUBYLIB", NeverClass::Loader),
    ("RUBYOPT", NeverClass::Loader),
    ("NODE_OPTIONS", NeverClass::Loader),
    ("NODE_PATH", NeverClass::Loader),
    ("JAVA_TOOL_OPTIONS", NeverClass::Loader),
    ("_JAVA_OPTIONS", NeverClass::Loader),
    ("CLASSPATH", NeverClass::Loader),
    ("TERMINFO", NeverClass::Loader),
    ("TERMINFO_DIRS", NeverClass::Loader),
    ("TERMPATH", NeverClass::Loader),
    ("TERMCAP", NeverClass::Loader),
    ("BASH_ENV", NeverClass::ShellInit),
    ("ENV", NeverClass::ShellInit),
    ("SHELLOPTS", NeverClass::ShellInit),
    ("BASHOPTS", NeverClass::ShellInit),
    ("GLOBIGNORE", NeverClass::ShellInit),
    ("PS4", NeverClass::ShellInit),
    ("IFS", NeverClass::ShellInit),
    ("CDPATH", NeverClass::ShellInit),
    ("FPATH", NeverClass::ShellInit),
    ("ZDOTDIR", NeverClass::ShellInit),
    ("NULLCMD", NeverClass::ShellInit),
    ("READNULLCMD", NeverClass::ShellInit),
    ("TMPPREFIX", NeverClass::ShellInit),
    ("GIT_SSH_COMMAND", NeverClass::ProgramNaming),
    ("GIT_SSH", NeverClass::ProgramNaming),
    ("GIT_ASKPASS", NeverClass::ProgramNaming),
    ("GIT_PROXY_COMMAND", NeverClass::ProgramNaming),
    ("GIT_EXEC_PATH", NeverClass::ProgramNaming),
    ("GIT_EXTERNAL_DIFF", NeverClass::ProgramNaming),
    ("GIT_PAGER", NeverClass::ProgramNaming),
    ("SSH_ASKPASS", NeverClass::ProgramNaming),
    ("SUDO_ASKPASS", NeverClass::ProgramNaming),
    ("NIX_CONFIG", NeverClass::ProgramNaming),
    ("NIX_USER_CONF_FILES", NeverClass::ProgramNaming),
];

/// Class B (design §4.3): never inherited, refused when declared, but a
/// script MAY set one per call with a literal (fixtures build fake worlds
/// with them). `(pattern, reason)`; a trailing `*` is a prefix.
pub const ENV_BLOCK_INHERIT: &[(&str, &str)] = &[
    // Which repository is judged (1442-22d2; the fixture rules read GIT_DIR /
    // GIT_COMMON_DIR from the per-call env, 1760-nn6u).
    ("GIT_DIR", "redirection"),
    ("GIT_WORK_TREE", "redirection"),
    ("GIT_COMMON_DIR", "redirection"),
    ("GIT_INDEX_FILE", "redirection"),
    ("GIT_OBJECT_DIRECTORY", "redirection"),
    ("GIT_ALTERNATE_OBJECT_DIRECTORIES", "redirection"),
    ("GIT_CEILING_DIRECTORIES", "redirection"),
    ("GIT_NAMESPACE", "redirection"),
    ("GIT_CONFIG_GLOBAL", "redirection"),
    ("GIT_CONFIG_SYSTEM", "redirection"),
    ("GIT_CONFIG_NOSYSTEM", "redirection"),
    ("GIT_CONFIG_COUNT", "redirection"),
    ("GIT_CONFIG_KEY_*", "redirection"),
    ("GIT_CONFIG_VALUE_*", "redirection"),
    ("GIT_CONFIG_PARAMETERS", "redirection"),
    ("GIT_OPTIONAL_LOCKS", "redirection"),
    ("GIT_AUTHOR_*", "redirection"),
    ("GIT_COMMITTER_*", "redirection"),
    // What a build produces.
    ("RUSTFLAGS", "build-output"),
    ("CARGO_BUILD_RUSTFLAGS", "build-output"),
    ("CARGO_ENCODED_RUSTFLAGS", "build-output"),
    ("RUSTC", "build-output"),
    ("RUSTDOC", "build-output"),
    ("RUSTC_WRAPPER", "build-output"),
    ("RUSTC_WORKSPACE_WRAPPER", "build-output"),
    ("RUSTUP_TOOLCHAIN", "build-output"),
    ("CC", "build-output"),
    ("CXX", "build-output"),
    ("AR", "build-output"),
    ("LD", "build-output"),
    ("CFLAGS", "build-output"),
    ("CXXFLAGS", "build-output"),
    ("LDFLAGS", "build-output"),
    ("MAKEFLAGS", "build-output"),
    ("SOURCE_DATE_EPOCH", "build-output"),
    // What nix evaluates and where it builds.
    ("NIX_PATH", "nix-evaluation"),
    ("NIX_CONF_DIR", "nix-evaluation"),
    ("NIX_REMOTE_SYSTEMS", "nix-evaluation"),
    ("NIX_BUILD_HOOK", "nix-evaluation"),
    // How Windows variables cross into WSL (795-jjw3).
    ("WSLENV", "wsl-crossing"),
    // A decider's child must not colour or page by the caller's taste.
    ("TERM", "output-shape"),
    ("COLORTERM", "output-shape"),
    ("NO_COLOR", "output-shape"),
    ("CLICOLOR_FORCE", "output-shape"),
    ("PAGER", "output-shape"),
    ("EDITOR", "output-shape"),
    ("VISUAL", "output-shape"),
    ("LESS", "output-shape"),
    ("MANPAGER", "output-shape"),
];

/// Class A2, terminal segment (design §4.2): the last `_`-separated segment.
pub const CREDENTIAL_TERMINAL: &[&str] = &[
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "PASSPHRASE",
    "PASS",
    "KEY",
    "AUTH",
    "CREDENTIALS",
    "CREDENTIAL",
    "COOKIE",
    "SESSION",
];

/// Class A2, contained anywhere in the upper-cased name.
pub const CREDENTIAL_CONTAINS: &[&str] = &[
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "PASSPHRASE",
    "API_KEY",
    "ACCESS_KEY",
    "PRIVATE_KEY",
    "SECRET_KEY",
    "SIGNING_KEY",
    "CLIENT_SECRET",
    "CREDENTIAL",
];

/// Class A2, a name beginning with one of these.
pub const CREDENTIAL_PREFIX: &[&str] = &[
    "AWS_",
    "AZURE_",
    "GOOGLE_APPLICATION_",
    "CLOUDFLARE_API_",
    "CF_API_",
];

/// Class A2, exact names.
pub const CREDENTIAL_EXACT: &[&str] = &[
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "NPM_TOKEN",
    "CARGO_REGISTRY_TOKEN",
    "VAULT_TOKEN",
    "HF_TOKEN",
    "HUGGING_FACE_HUB_TOKEN",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "SSH_AUTH_SOCK",
    "GPG_AGENT_INFO",
    "KRB5CCNAME",
    "DOCKER_AUTH_CONFIG",
];

/// The CLOSED list of locator and label suffixes (design §4.2, §9 Q5 default
/// "as written"): a name ending in one names WHERE a secret is, or labels it,
/// and is never credential-shaped. `_ENV_FILE` and `_SINK_FILE` end in
/// `_FILE`; they are listed because the design lists them.
pub const LOCATOR_SUFFIXES: &[&str] = &[
    "_FILE",
    "_PATH",
    "_DIR",
    "_ID",
    "_NAME",
    "_FP",
    "_LOG",
    "_URL",
    "_ADDR",
    "_SRC",
    "_COUNT",
    "_ENV_FILE",
    "_SINK_FILE",
];

/// The project names that ARE credentials (spec bba4ae64). They are dropped
/// from children by the shape rule on purpose; the namespace-hygiene guard
/// (scripts/lua/check-env-namespace-hygiene.lua, CREDENTIAL_NAMES) keeps the
/// same list, and tests/lua_source_agreements.rs holds the two equal. The spec
/// names this list with the TILLANDSIAS_ prefix (`…_CREDENTIAL_NAMES`); that spelling is itself
/// credential-shaped under design §4.2 A2 (it contains CREDENTIAL and NAMES is
/// not a locator suffix), so the hygiene guard refuses it as a tree name.
pub const PROJECT_CREDENTIAL_NAMES: &[&str] = &[
    "TILLANDSIAS_COORD_CLIENT_SECRET",
    "TILLANDSIAS_KEY_PASS",
    "TILLANDSIAS_CONSENT_TOKEN",
    "TILLANDSIAS_BROWSER_E2E_FOREIGN_KEY",
    "TILLANDSIAS_BROWSER_E2E_ENCLAVE_KEY",
];

/// Which rule made a name credential-shaped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    Terminal(&'static str),
    Contains(&'static str),
    Prefix(&'static str),
    Exact(&'static str),
}

/// Design §4.2 A2, one pure function. Upper-cased on EVERY platform (the
/// design's "after upper-casing", and the hygiene guard's `:upper()`): a
/// lower-case spelling of a credential is still a credential.
pub fn credential_shape(name: &str) -> Option<Shape> {
    let up = name.to_ascii_uppercase();
    if LOCATOR_SUFFIXES.iter().any(|s| up.ends_with(s)) {
        return None;
    }
    let last = up.rsplit('_').next().unwrap_or(up.as_str());
    if let Some(t) = CREDENTIAL_TERMINAL.iter().find(|t| **t == last) {
        return Some(Shape::Terminal(t));
    }
    if let Some(c) = CREDENTIAL_CONTAINS.iter().find(|c| up.contains(**c)) {
        return Some(Shape::Contains(c));
    }
    if let Some(p) = CREDENTIAL_PREFIX.iter().find(|p| up.starts_with(**p)) {
        return Some(Shape::Prefix(p));
    }
    CREDENTIAL_EXACT
        .iter()
        .find(|e| **e == up)
        .map(|e| Shape::Exact(e))
}

/// ORDER 2031-h5ru (p1), kept ENFORCED through the census. Does this
/// `TILLANDSIAS_*` runner variable pass to a child? Not when its last
/// `_`-separated segment is SECRET, PASS or PASSWORD:
/// TILLANDSIAS_COORD_CLIENT_SECRET (the coordinator's Access client secret)
/// and TILLANDSIAS_KEY_PASS (the at-rest CA key passphrase) are read by the
/// process that needs them from ITS OWN environment, and no child ever needed
/// them. Compared case-insensitively, as Windows treats environment names.
pub fn project_variable_passes(name: &str) -> bool {
    let last = name.rsplit('_').next().unwrap_or("").to_ascii_uppercase();
    !matches!(last.as_str(), "SECRET" | "PASS" | "PASSWORD")
}

/// Environment names fold case on Windows (`Path` and `PATH` are one
/// variable) and are exact elsewhere (design §4.9).
fn fold() -> bool {
    cfg!(windows)
}

fn eq_with(a: &str, b: &str, fold: bool) -> bool {
    if fold {
        a.eq_ignore_ascii_case(b)
    } else {
        a == b
    }
}

/// `pattern` is an exact name, or a prefix when it ends in `*` (tables only).
fn matches_with(pattern: &str, name: &str, fold: bool) -> bool {
    match pattern.strip_suffix('*') {
        Some(prefix) => {
            name.len() >= prefix.len()
                && name.is_char_boundary(prefix.len())
                && eq_with(&name[..prefix.len()], prefix, fold)
        }
        None => eq_with(pattern, name, fold),
    }
}

/// One environment name, as this platform compares them.
pub fn name_eq(a: &str, b: &str) -> bool {
    eq_with(a, b, fold())
}

/// What the hard block says about a name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Block {
    /// Class A: never reaches a child, never readable, refused per call.
    Never(NeverClass),
    /// Class B: never inherited, refused when declared, allowed per call.
    Inherit(&'static str),
}

impl Block {
    /// The class word a record or note carries.
    pub fn token(self) -> &'static str {
        match self {
            Block::Never(c) => c.token(),
            Block::Inherit(_) => "inherit-blocked",
        }
    }
}

/// Step 0, the hard block, as this platform compares names.
pub fn hard_block(name: &str) -> Option<Block> {
    hard_block_with(name, fold())
}

/// `hard_block` with the case rule explicit, so the Windows (folding) side is
/// testable on every host.
pub fn hard_block_with(name: &str, fold: bool) -> Option<Block> {
    if let Some((_, c)) = ENV_BLOCK_NEVER
        .iter()
        .find(|(p, _)| matches_with(p, name, fold))
    {
        return Some(Block::Never(*c));
    }
    if credential_shape(name).is_some() {
        return Some(Block::Never(NeverClass::CredentialShape));
    }
    ENV_BLOCK_INHERIT
        .iter()
        .find(|(p, _)| matches_with(p, name, fold))
        .map(|(_, r)| Block::Inherit(r))
}

fn is_base_with(name: &str, fold: bool) -> bool {
    ENV_BASE_PASSTHROUGH.iter().any(|b| eq_with(b, name, fold))
}

fn is_fixed_with(name: &str, fold: bool) -> bool {
    ENV_FIXED.iter().any(|(f, _)| eq_with(f, name, fold))
}

/// A profile entry: `(variable, why it is safe to inherit, order)`.
pub type ProfileVar = (&'static str, &'static str, &'static str);

const PODMAN_WHY: &str = "podman(1) ENVIRONMENT: a locator or socket URL that selects the podman service, store or config the caller uses";
const PROXY_WHY: &str =
    "the host's egress proxy convention; refused when the URL carries userinfo (design §4.2 A3)";
const CA_WHY: &str = "a CA bundle locator, so TLS trusts what the host trusts";

/// The declared-inherit profiles (design §5.3, spec 1dd43038). The ONE
/// answer to "what does the podman profile pass". No prefixes: every entry is
/// an exact name with its reason and the order that introduced it.
pub const ENV_INHERIT_PROFILES: &[(&str, &[ProfileVar])] = &[
    (
        "podman",
        &[
            (
                "CONTAINER_HOST",
                "podman(1): selects a remote service and enables --remote; the macOS/Windows hosts reach podman through it",
                "2029-39bt",
            ),
            ("CONTAINER_CONNECTION", PODMAN_WHY, "2029-39bt"),
            (
                "CONTAINER_SSHKEY",
                "podman(1): the PATH of the ssh identity for a remote connection, not the key",
                "2029-39bt",
            ),
            ("CONTAINERS_CONF", PODMAN_WHY, "2029-39bt"),
            ("CONTAINERS_CONF_OVERRIDE", PODMAN_WHY, "2029-39bt"),
            ("CONTAINERS_REGISTRIES_CONF", PODMAN_WHY, "2029-39bt"),
            ("CONTAINERS_STORAGE_CONF", PODMAN_WHY, "2029-39bt"),
            ("PODMAN_CONNECTIONS_CONF", PODMAN_WHY, "2029-39bt"),
            ("STORAGE_DRIVER", PODMAN_WHY, "2029-39bt"),
            ("STORAGE_OPTS", PODMAN_WHY, "2029-39bt"),
            (
                "REGISTRY_AUTH_FILE",
                "the PATH of the registry auth file (a locator), not its contents",
                "2029-39bt",
            ),
            ("DOCKER_HOST", PODMAN_WHY, "2029-39bt"),
            ("XDG_CONFIG_HOME", PODMAN_WHY, "2029-39bt"),
            ("XDG_DATA_HOME", PODMAN_WHY, "2029-39bt"),
        ],
    ),
    (
        "net-egress",
        &[
            ("HTTP_PROXY", PROXY_WHY, "2029-39bt"),
            ("HTTPS_PROXY", PROXY_WHY, "2029-39bt"),
            ("NO_PROXY", PROXY_WHY, "2029-39bt"),
            ("ALL_PROXY", PROXY_WHY, "2029-39bt"),
            ("http_proxy", PROXY_WHY, "2029-39bt"),
            ("https_proxy", PROXY_WHY, "2029-39bt"),
            ("no_proxy", PROXY_WHY, "2029-39bt"),
            ("all_proxy", PROXY_WHY, "2029-39bt"),
            ("SSL_CERT_FILE", CA_WHY, "2029-39bt"),
            ("SSL_CERT_DIR", CA_WHY, "2029-39bt"),
            ("CURL_CA_BUNDLE", CA_WHY, "2029-39bt"),
            ("GIT_SSL_CAINFO", CA_WHY, "2029-39bt"),
            ("NIX_SSL_CERT_FILE", CA_WHY, "2029-39bt"),
            ("CARGO_HTTP_CAINFO", CA_WHY, "2029-39bt"),
            ("NODE_EXTRA_CA_CERTS", CA_WHY, "2029-39bt"),
        ],
    ),
    (
        "cargo",
        &[
            (
                "CARGO_HOME",
                "where the caller's cargo registry cache and config live (CARGO_TARGET_DIR is base)",
                "2029-39bt",
            ),
            (
                "RUSTUP_HOME",
                "where the caller's toolchains live",
                "2029-39bt",
            ),
            (
                "CARGO_BUILD_JOBS",
                "a parallelism limit; changes speed, not output",
                "2029-39bt",
            ),
            (
                "CARGO_NET_OFFLINE",
                "an offline host stays offline in its children",
                "2029-39bt",
            ),
            (
                "CARGO_INCREMENTAL",
                "an incremental-cache switch; changes speed, not output",
                "2029-39bt",
            ),
        ],
    ),
    (
        "toolbox",
        &[(
            "TOOLBOX_PATH",
            "where the toolbox binary is; `toolbox run` reads it (XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are base, 1838-nwyn)",
            "2029-39bt",
        )],
    ),
    (
        "session",
        &[
            (
                "USER",
                "the caller's login name; toolbox and podman read it",
                "2029-39bt",
            ),
            ("LOGNAME", "the caller's login name", "2029-39bt"),
            ("XDG_CACHE_HOME", "the caller's cache location", "2029-39bt"),
            ("XDG_STATE_HOME", "the caller's state location", "2029-39bt"),
        ],
    ),
    (
        "vault",
        &[
            (
                "VAULT_ADDR",
                "the Vault server URL (a locator)",
                "2029-39bt",
            ),
            ("VAULT_CACERT", CA_WHY, "2029-39bt"),
            ("VAULT_CAPATH", CA_WHY, "2029-39bt"),
            ("VAULT_NAMESPACE", "a Vault namespace label", "2029-39bt"),
            (
                "VAULT_TOKEN_FILE",
                "the PATH of the token file (the sanctioned secret channel), never the token",
                "2029-39bt",
            ),
            (
                "VAULT_ROLE_ID_FILE",
                "the PATH of the AppRole role-id file",
                "2029-39bt",
            ),
            (
                "VAULT_SECRET_ID_FILE",
                "the PATH of the AppRole secret-id file, never the secret",
                "2029-39bt",
            ),
            (
                "VAULT_TOKEN_SINK_FILE",
                "the PATH the agent writes its token to",
                "2029-39bt",
            ),
        ],
    ),
    (
        "nix",
        &[
            (
                "NIX_REMOTE",
                "which nix daemon/store the caller uses",
                "2029-39bt",
            ),
            ("NIX_STORE_DIR", "the caller's store location", "2029-39bt"),
            ("NIX_STATE_DIR", "the caller's state location", "2029-39bt"),
            ("NIX_LOG_DIR", "the caller's log location", "2029-39bt"),
        ],
    ),
    (
        "gh",
        &[
            ("GH_HOST", "which GitHub host gh talks to", "2029-39bt"),
            ("GH_REPO", "the default repository gh acts on", "2029-39bt"),
            (
                "GH_CONFIG_DIR",
                "where gh keeps its own authenticated store; gh authenticates itself, no token is inherited (design §4.6 a)",
                "2029-39bt",
            ),
        ],
    ),
    (
        "macos-toolchain",
        &[
            (
                "DEVELOPER_DIR",
                "which Xcode the macOS build scripts use",
                "2029-39bt",
            ),
            (
                "SDKROOT",
                "which SDK the macOS build scripts use",
                "2029-39bt",
            ),
        ],
    ),
];

/// The names a profile passes, or None for an unknown profile.
pub fn profile(name: &str) -> Option<&'static [ProfileVar]> {
    ENV_INHERIT_PROFILES
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, v)| *v)
}

/// The known profile names, for a refusal's stderr.
pub fn profile_names() -> Vec<&'static str> {
    ENV_INHERIT_PROFILES.iter().map(|(n, _)| *n).collect()
}

/// A refusal: a machine token naming the variable and its class — never a
/// value — with a why and a remedy for a human.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvRefusal {
    pub token: String,
    pub why: String,
    pub remedy: String,
}

impl EnvRefusal {
    fn new(token: String, why: impl Into<String>, remedy: impl Into<String>) -> Self {
        EnvRefusal {
            token,
            why: why.into(),
            remedy: remedy.into(),
        }
    }

    /// `token`, then labelled why/remedy lines (the runner's refusal shape).
    pub fn lines(&self) -> String {
        format!(
            "{}\n  why: {}\n  remedy: {}",
            self.token, self.why, self.remedy
        )
    }
}

const SANCTIONED_CREDENTIAL_ROUTE: &str = "a credential reaches a child only per call, from a file (a *_FILE locator read with fs.read under -- @read-env) or from a program the script ran (design 2029-39bt §4.6)";

fn never_refusal(name: &str, class: NeverClass) -> EnvRefusal {
    let remedy = match class {
        NeverClass::CredentialShape => SANCTIONED_CREDENTIAL_ROUTE.to_string(),
        _ => "run the subject through a wrapper FILE that sets what it needs; a loader, shell-init or program-naming variable never crosses a door (design 2029-39bt §4.2 A1)".to_string(),
    };
    EnvRefusal::new(
        format!("refused:env-inherit:never:{name}:{}", class.token()),
        format!(
            "'{name}' is class A ({}): it never reaches a child",
            class.token()
        ),
        remedy,
    )
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Refuse a declared profile name that is not in the table.
pub fn check_profile(name: &str) -> Result<(), EnvRefusal> {
    if profile(name).is_some() {
        return Ok(());
    }
    Err(EnvRefusal::new(
        format!("refused:env-inherit:unknown-profile:{name}"),
        format!(
            "'{name}' is not a profile; known profiles: {}",
            profile_names().join(" ")
        ),
        "name one of the known profiles, or add the profile to child_env::ENV_INHERIT_PROFILES with a why and an order",
    ))
}

/// Judge one declared inherit name (header `-- @env-inherit`, run verb
/// `--env-inherit`). `Ok(Some(note))` for a base name (a no-op).
pub fn check_declared_name(name: &str) -> Result<Option<String>, EnvRefusal> {
    check_declared_name_with(name, fold())
}

fn check_declared_name_with(name: &str, fold: bool) -> Result<Option<String>, EnvRefusal> {
    if name.contains('*') {
        return Err(EnvRefusal::new(
            format!("refused:env-inherit:glob-not-supported:{name}"),
            "a declared inherit name is exact; prefixes and globs are reserved, not implemented (design 2029-39bt §4.5)",
            "list the exact names, or ask for a profile entry in child_env::ENV_INHERIT_PROFILES",
        ));
    }
    if !valid_name(name) {
        return Err(EnvRefusal::new(
            format!("refused:env-inherit:invalid-name:{name}"),
            "a variable name is ASCII letters, digits and underscores, not starting with a digit",
            "spell the variable's exact name",
        ));
    }
    match hard_block_with(name, fold) {
        Some(Block::Never(c)) => return Err(never_refusal(name, c)),
        Some(Block::Inherit(reason)) => {
            return Err(EnvRefusal::new(
                format!("refused:env-inherit:inherit-blocked:{name}:{reason}"),
                format!("'{name}' ({reason}) is never inherited from the caller"),
                format!(
                    "set it per call with a literal in the script (proc.run{{env={{{name}=...}}}}), where it is visible and reviewed"
                ),
            ));
        }
        None => {}
    }
    if is_fixed_with(name, fold) {
        return Err(EnvRefusal::new(
            format!("refused:env-inherit:fixed:{name}"),
            format!("'{name}' is a fixed override; the caller's value never wins"),
            "drop the declaration; a per-call literal may still set it",
        ));
    }
    if is_base_with(name, fold) {
        return Ok(Some(format!("note:env-inherit:base:{name}")));
    }
    Ok(None)
}

/// Judge one per-call literal (step 5). Class A refuses the call; class B and
/// everything else is allowed. A bash function export (`() ...`) is refused
/// under any name (sudo's `*=()*`).
pub fn check_call_literal(name: &str, value: &str) -> Result<(), EnvRefusal> {
    check_call_literal_with(name, value, fold())
}

fn check_call_literal_with(name: &str, value: &str, fold: bool) -> Result<(), EnvRefusal> {
    if let Some(Block::Never(c)) = hard_block_with(name, fold) {
        return Err(never_refusal(name, c));
    }
    if value.starts_with("() ") {
        return Err(never_refusal(name, NeverClass::ShellInit));
    }
    Ok(())
}

/// A script's (or the run verb's) declared inherit set, already judged.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Declared {
    pub profiles: Vec<String>,
    pub inherit: Vec<String>,
}

impl Declared {
    /// Judge the directives; the first refusal wins. The notes are one line
    /// per declared base name.
    pub fn validate(
        profiles: &[String],
        inherit: &[String],
    ) -> Result<(Declared, Vec<String>), EnvRefusal> {
        let mut notes = Vec::new();
        for p in profiles {
            check_profile(p)?;
        }
        for n in inherit {
            if let Some(note) = check_declared_name(n)? {
                notes.push(note);
            }
        }
        Ok((
            Declared {
                profiles: profiles.to_vec(),
                inherit: inherit.to_vec(),
            },
            notes,
        ))
    }

    /// Every declared variable, profiles first, each once.
    pub fn names(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let from_profiles = self
            .profiles
            .iter()
            .filter_map(|p| profile(p))
            .flat_map(|vars| vars.iter().map(|(v, _, _)| v.to_string()));
        for n in from_profiles.chain(self.inherit.iter().cloned()) {
            if !out.iter().any(|o| name_eq(o, &n)) {
                out.push(n);
            }
        }
        out
    }
}

const PROXY_NAMES: &[&str] = &["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"];

/// Design §4.2 A3, the one value check this landing applies: a proxy URL
/// whose authority carries userinfo (`user:pass@host`) is a credential.
fn proxy_has_userinfo(name: &str, value: &OsStr) -> bool {
    if !PROXY_NAMES.iter().any(|p| p.eq_ignore_ascii_case(name)) {
        return false;
    }
    let v = value.to_string_lossy();
    let rest = v.split_once("://").map(|(_, r)| r).unwrap_or(&v);
    rest.split('/').next().unwrap_or("").contains('@')
}

fn function_export(value: &OsStr) -> bool {
    value.to_string_lossy().starts_with("() ")
}

/// The child environment one call gets, plus what it did, by NAME only.
#[derive(Debug, Clone, Default)]
pub struct ChildEnv {
    /// The variables the child starts with.
    pub vars: Vec<(OsString, OsString)>,
    /// Declared (step 3) and present on the runner.
    pub inherited: Vec<String>,
    /// Declared and unset on the runner (systemd: silently ignored; here
    /// silently absent from the child, loudly present in the record).
    pub absent: Vec<String>,
    /// Declared and present, but the value was refused (`value-shape`).
    pub withheld: Vec<String>,
    /// THE CENSUS (tasks 1.8): step-2 names the full block would drop, with
    /// the class word. They still pass in this landing.
    pub would_drop: Vec<(String, &'static str)>,
}

fn lookup<'a>(runner: &'a [(OsString, OsString)], name: &str, fold: bool) -> Option<&'a OsString> {
    runner
        .iter()
        .find(|(k, _)| k.to_str().is_some_and(|k| eq_with(k, name, fold)))
        .map(|(_, v)| v)
}

fn upsert(vars: &mut Vec<(OsString, OsString)>, name: OsString, value: OsString, fold: bool) {
    let key = name.to_string_lossy().into_owned();
    match vars
        .iter_mut()
        .find(|(k, _)| eq_with(&k.to_string_lossy(), &key, fold))
    {
        Some(slot) => *slot = (name, value),
        None => vars.push((name, value)),
    }
}

impl ChildEnv {
    /// The six steps over an explicit runner environment (pure: tests feed
    /// it). Fails only on a per-call literal.
    pub fn build(
        runner: &[(OsString, OsString)],
        declared: &Declared,
        call: &[(String, String)],
    ) -> Result<ChildEnv, EnvRefusal> {
        Self::build_with(runner, declared, call, fold())
    }

    /// `build` with the case rule explicit (the Windows side on any host).
    pub fn build_with(
        runner: &[(OsString, OsString)],
        declared: &Declared,
        call: &[(String, String)],
        fold: bool,
    ) -> Result<ChildEnv, EnvRefusal> {
        // Step 5 is judged FIRST, so a refused call builds nothing.
        for (k, v) in call {
            check_call_literal_with(k, v, fold)?;
        }
        let mut env = ChildEnv::default();
        // Step 1, filtered by step 0 (a no-op on today's names; the unit test
        // holds every base name outside the block).
        for key in ENV_BASE_PASSTHROUGH {
            if let Some(v) = lookup(runner, key, fold)
                && hard_block_with(key, fold).is_none()
                && !function_export(v)
            {
                upsert(&mut env.vars, OsString::from(key), v.clone(), fold);
            }
        }
        // Step 2. 2031-h5ru's narrow filter is enforced; the rest of the
        // block is the census (warn-only until the flip).
        for (k, v) in runner {
            let name = k.to_string_lossy();
            if !name.starts_with("TILLANDSIAS_") || !project_variable_passes(&name) {
                continue;
            }
            let would = hard_block_with(&name, fold)
                .map(Block::token)
                .or_else(|| function_export(v).then_some("shell-init"));
            if let Some(class) = would {
                env.would_drop.push((name.into_owned(), class));
            }
            upsert(&mut env.vars, k.clone(), v.clone(), fold);
        }
        // Step 3. Header-time validation refused every blocked name; the
        // filter here is the second line, for a caller that skipped it.
        for name in declared.names() {
            match lookup(runner, &name, fold) {
                None => env.absent.push(name),
                Some(_) if hard_block_with(&name, fold).is_some() => {}
                Some(v) if proxy_has_userinfo(&name, v) || function_export(v) => {
                    env.withheld.push(name)
                }
                Some(v) => {
                    upsert(&mut env.vars, OsString::from(&name), v.clone(), fold);
                    env.inherited.push(name);
                }
            }
        }
        // Step 4.
        for (k, v) in ENV_FIXED {
            upsert(&mut env.vars, OsString::from(k), OsString::from(v), fold);
        }
        // Step 5.
        for (k, v) in call {
            upsert(&mut env.vars, OsString::from(k), OsString::from(v), fold);
        }
        Ok(env)
    }

    /// THE door entry: the runner's own environment, the running script's
    /// declared set (none outside a script run), the call's literals.
    pub fn for_call(call: &[(String, String)]) -> Result<ChildEnv, EnvRefusal> {
        Self::for_declared(&script_declared(), call)
    }

    /// The door entry with an explicit declared set (the run verb's flags).
    pub fn for_declared(
        declared: &Declared,
        call: &[(String, String)],
    ) -> Result<ChildEnv, EnvRefusal> {
        let runner: Vec<(OsString, OsString)> = std::env::vars_os().collect();
        let env = Self::build(&runner, declared, call)?;
        env.report_once();
        Ok(env)
    }

    /// A child command starting from exactly `vars`.
    pub fn command(&self, argv: Vec<String>) -> tillandsias_exec::Command {
        let mut cmd = tillandsias_exec::Command::new(argv).env_clear();
        for (k, v) in &self.vars {
            cmd = cmd.env(k, v);
        }
        cmd
    }

    /// Names only, once per process: a withheld value, and (under warn mode,
    /// in a process with no script-run record to carry them) the census.
    fn report_once(&self) {
        static SAID: Mutex<Vec<String>> = Mutex::new(Vec::new());
        let mut lines: Vec<String> = self
            .withheld
            .iter()
            .map(|n| format!("note:env-inherit:withheld:{n}:value-shape"))
            .collect();
        if warn_mode() && !RECORD_OWNER.load(Ordering::SeqCst) {
            lines.extend(
                self.would_drop
                    .iter()
                    .map(|(n, c)| format!("note:env-block:would-drop:{n}:{c}")),
            );
        }
        let Ok(mut said) = SAID.lock() else { return };
        for l in lines {
            if !said.contains(&l) {
                eprintln!("{l}");
                said.push(l);
            }
        }
    }
}

/// TILLANDSIAS_ENV_BLOCK_WARN=1: record the census (tasks 1.8, first half).
pub const ENV_BLOCK_WARN: &str = "TILLANDSIAS_ENV_BLOCK_WARN";

pub fn warn_mode() -> bool {
    std::env::var_os(ENV_BLOCK_WARN).is_some_and(|v| v == "1")
}

static SCRIPT_DECLARED: Mutex<Option<Declared>> = Mutex::new(None);
static RECORD_OWNER: AtomicBool = AtomicBool::new(false);

/// `script run` installs the running script's declared set, once, before any
/// script code runs; every door in the process reads it. It also takes over
/// reporting the census (the script-run record carries it).
pub fn install_script_declared(declared: Declared) {
    if let Ok(mut d) = SCRIPT_DECLARED.lock() {
        *d = Some(declared);
    }
    RECORD_OWNER.store(true, Ordering::SeqCst);
}

fn script_declared() -> Declared {
    SCRIPT_DECLARED
        .lock()
        .ok()
        .and_then(|d| d.clone())
        .unwrap_or_default()
}

/// `env.get` refuses a class-A name (operator ruling Q2, spec c3d80b67):
/// `Some(message)` naming the variable and its class.
pub fn env_get_refusal(name: &str) -> Option<String> {
    match hard_block(name) {
        Some(Block::Never(c)) => Some(format!(
            "env.get: refused:env-inherit:never:{name}:{} — '{name}' cannot be read; see design 2029-39bt §4.6",
            c.token()
        )),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A planted credential-shaped PROJECT name. Spelled in two halves so the
    /// namespace-hygiene guard, which reads source text, does not take this
    /// fixture's probe for a real variable of the tree.
    const PROBE_TOKEN: &str = concat!("TILLANDSIAS_", "PROBE_TOKEN");

    fn os(pairs: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
        pairs
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect()
    }

    fn get<'a>(env: &'a ChildEnv, name: &str) -> Option<&'a OsString> {
        env.vars.iter().find(|(k, _)| k == name).map(|(_, v)| v)
    }

    /// Design §5.3 and the §4.10 census, one row per name: (name, expected).
    /// `None` = passes the block.
    #[test]
    fn every_audited_name_has_its_expected_class() {
        use Block::*;
        use NeverClass::*;
        let rows: &[(&str, Option<Block>)] = &[
            // §4.10 census of TILLANDSIAS_ names matching (TOKEN|KEY|SECRET|PASS).
            (
                "TILLANDSIAS_COORD_CLIENT_SECRET",
                Some(Never(CredentialShape)),
            ),
            ("TILLANDSIAS_KEY_PASS", Some(Never(CredentialShape))),
            ("TILLANDSIAS_CONSENT_TOKEN", Some(Never(CredentialShape))),
            ("TILLANDSIAS_WRAPPER_TOKEN", Some(Never(CredentialShape))),
            ("TILLANDSIAS_WRAPPER_MARK", None),
            ("TILLANDSIAS_NOTARY_KEY", Some(Never(CredentialShape))),
            ("TILLANDSIAS_NOTARY_KEY_FILE", None),
            ("TILLANDSIAS_NOTARY_KEY_ID", None),
            ("TILLANDSIAS_PUSH_KEY_ID", None),
            ("TILLANDSIAS_PUSH_KEY_FP", None),
            ("TILLANDSIAS_NIX_CACHE_KEY_NAME", None),
            ("TILLANDSIAS_VAULT_TOKEN_FILE", None),
            ("TILLANDSIAS_AGY_TOKEN_ENV_FILE", None),
            ("TILLANDSIAS_TOKENS_LOG", None),
            ("TILLANDSIAS_RUNTIME_SECRET_SRC", None),
            ("TILLANDSIAS_FALSE_PASS_OUT", None),
            (
                "TILLANDSIAS_BROWSER_E2E_FOREIGN_KEY",
                Some(Never(CredentialShape)),
            ),
            (PROBE_TOKEN, Some(Never(CredentialShape))),
            ("TILLANDSIAS_PROBE_TOKEN_FILE", None),
            // §5.3 credentials.
            ("GH_TOKEN", Some(Never(CredentialShape))),
            ("GITHUB_TOKEN", Some(Never(CredentialShape))),
            ("SSH_AUTH_SOCK", Some(Never(CredentialShape))),
            ("AWS_REGION", Some(Never(CredentialShape))),
            ("VAULT_TOKEN", Some(Never(CredentialShape))),
            ("CARGO_REGISTRY_TOKEN", Some(Never(CredentialShape))),
            ("MY_SERVICE_TOKEN", Some(Never(CredentialShape))),
            ("FAKE_TOKEN", Some(Never(CredentialShape))),
            ("DB_PASSWORD_HINT", Some(Never(CredentialShape))),
            ("SIGNING_KEY_MODE", Some(Never(CredentialShape))),
            ("gh_token", Some(Never(CredentialShape))),
            // §5.3 class A1.
            ("LD_PRELOAD", Some(Never(Loader))),
            ("LD_LIBRARY_PATH", Some(Never(Loader))),
            ("DYLD_INSERT_LIBRARIES", Some(Never(Loader))),
            ("PYTHONPATH", Some(Never(Loader))),
            ("BASH_ENV", Some(Never(ShellInit))),
            ("ENV", Some(Never(ShellInit))),
            ("PS4", Some(Never(ShellInit))),
            ("IFS", Some(Never(ShellInit))),
            ("GIT_SSH_COMMAND", Some(Never(ProgramNaming))),
            ("GIT_ASKPASS", Some(Never(ProgramNaming))),
            ("NIX_CONFIG", Some(Never(ProgramNaming))),
            // §5.3 class B.
            ("GIT_DIR", Some(Inherit("redirection"))),
            ("GIT_WORK_TREE", Some(Inherit("redirection"))),
            ("GIT_CONFIG_GLOBAL", Some(Inherit("redirection"))),
            ("GIT_CONFIG_KEY_0", Some(Inherit("redirection"))),
            ("GIT_AUTHOR_NAME", Some(Inherit("redirection"))),
            ("RUSTFLAGS", Some(Inherit("build-output"))),
            ("RUSTC_WRAPPER", Some(Inherit("build-output"))),
            ("CC", Some(Inherit("build-output"))),
            ("NIX_PATH", Some(Inherit("nix-evaluation"))),
            ("NIX_CONF_DIR", Some(Inherit("nix-evaluation"))),
            ("WSLENV", Some(Inherit("wsl-crossing"))),
            ("TERM", Some(Inherit("output-shape"))),
            ("PAGER", Some(Inherit("output-shape"))),
            // Locators and ordinary names.
            ("VAULT_TOKEN_FILE", None),
            ("REGISTRY_AUTH_FILE", None),
            ("CONTAINER_SSHKEY", None),
            ("CARGO_HOME", None),
            ("FAKE_PODMAN_STORE", None),
            ("CODEX_HOME", None),
            ("LD", Some(Inherit("build-output"))),
        ];
        for (name, want) in rows {
            assert_eq!(hard_block_with(name, false), *want, "{name}");
        }
    }

    #[test]
    fn the_credential_shape_follows_each_rule_and_the_locator_suffixes() {
        for t in CREDENTIAL_TERMINAL {
            let n = format!("X_{t}");
            assert!(credential_shape(&n).is_some(), "{n}");
            for l in LOCATOR_SUFFIXES {
                let m = format!("X_{t}{l}");
                assert_eq!(credential_shape(&m), None, "{m}");
            }
        }
        for c in CREDENTIAL_CONTAINS {
            let n = format!("X_{c}_MODE");
            assert!(credential_shape(&n).is_some(), "{n}");
        }
        for p in CREDENTIAL_PREFIX {
            assert!(credential_shape(&format!("{p}MODE")).is_some(), "{p}");
        }
        for e in CREDENTIAL_EXACT {
            assert!(credential_shape(e).is_some(), "{e}");
        }
        for not in [
            "X_SESSION_MODE",
            "X_AUTH_MODE",
            "X_KEYS_MODE",
            "DBUS_SESSION_BUS_ADDRESS",
        ] {
            assert_eq!(credential_shape(not), None, "{not}");
        }
    }

    #[test]
    fn base_fixed_and_profile_names_are_outside_the_block() {
        for b in ENV_BASE_PASSTHROUGH {
            assert_eq!(hard_block_with(b, false), None, "base {b}");
            assert_eq!(hard_block_with(b, true), None, "base {b} folded");
        }
        for (f, _) in ENV_FIXED {
            assert_eq!(hard_block_with(f, true), None, "fixed {f}");
        }
        assert_eq!(ENV_INHERIT_PROFILES.len(), 9, "the nine profiles of §5.3");
        for (p, vars) in ENV_INHERIT_PROFILES {
            assert!(!vars.is_empty(), "profile {p} is empty");
            for (v, why, order) in *vars {
                assert!(!v.contains('*'), "{p}: {v} is a glob");
                assert!(valid_name(v), "{p}: {v}");
                assert_eq!(credential_shape(v), None, "{p}: {v} is credential-shaped");
                assert_eq!(hard_block_with(v, true), None, "{p}: {v} is blocked");
                assert!(!is_base_with(v, true), "{p}: {v} is base");
                assert!(!is_fixed_with(v, true), "{p}: {v} is fixed");
                assert!(!why.is_empty() && !order.is_empty(), "{p}: {v}");
            }
        }
        for name in PROJECT_CREDENTIAL_NAMES {
            assert!(credential_shape(name).is_some(), "{name}");
        }
    }

    #[test]
    fn the_six_steps_apply_in_order() {
        let runner = os(&[
            ("PATH", "/bin"),
            ("LC_ALL", "fr_FR.UTF-8"),
            ("TZ", "Europe/Berlin"),
            ("CONTAINER_HOST", "unix:///a.sock"),
            ("FAKE_PODMAN_STORE", "/tmp/s"),
            ("GH_TOKEN", "x"),
            ("LD_PRELOAD", "/x.so"),
            ("TILLANDSIAS_HOST_KIND", "bare-metal"),
            ("TILLANDSIAS_KEY_PASS", "x"),
            (PROBE_TOKEN, "x"),
        ]);
        let declared = Declared {
            profiles: vec!["podman".into()],
            inherit: vec!["PATH".into()],
        };
        let call = vec![
            ("CONTAINER_HOST".to_string(), "unix:///b.sock".to_string()),
            ("GIT_CONFIG_GLOBAL".to_string(), "/dev/null".to_string()),
        ];
        let env = ChildEnv::build_with(&runner, &declared, &call, false).unwrap();
        assert_eq!(get(&env, "PATH").unwrap(), "/bin");
        assert_eq!(
            env.vars.iter().filter(|(k, _)| k == "PATH").count(),
            1,
            "base and declared: one entry"
        );
        assert_eq!(get(&env, "LC_ALL").unwrap(), "C");
        assert_eq!(get(&env, "TZ").unwrap(), "UTC");
        assert_eq!(get(&env, "CONTAINER_HOST").unwrap(), "unix:///b.sock");
        assert_eq!(get(&env, "GIT_CONFIG_GLOBAL").unwrap(), "/dev/null");
        assert_eq!(get(&env, "TILLANDSIAS_HOST_KIND").unwrap(), "bare-metal");
        for gone in [
            "FAKE_PODMAN_STORE",
            "GH_TOKEN",
            "LD_PRELOAD",
            "TILLANDSIAS_KEY_PASS",
        ] {
            assert!(get(&env, gone).is_none(), "{gone} reached the child");
        }
        // The census: passes, and is named.
        assert!(get(&env, PROBE_TOKEN).is_some());
        assert_eq!(
            env.would_drop,
            vec![(PROBE_TOKEN.to_string(), "credential-shape")]
        );
        assert!(env.inherited.contains(&"CONTAINER_HOST".to_string()));
        assert!(env.absent.contains(&"CONTAINERS_CONF".to_string()));
        // Deterministic.
        let again = ChildEnv::build_with(&runner, &declared, &call, false).unwrap();
        assert_eq!(env.vars, again.vars);
    }

    #[test]
    fn a_per_call_class_a_literal_refuses_and_class_b_does_not() {
        let d = Declared::default();
        for (k, class) in [
            ("LD_PRELOAD", "loader"),
            ("GH_TOKEN", "credential-shape"),
            ("BASH_ENV", "shell-init"),
            ("GIT_ASKPASS", "program-naming"),
        ] {
            let e = ChildEnv::build_with(&[], &d, &[(k.into(), "v".into())], false).unwrap_err();
            assert_eq!(e.token, format!("refused:env-inherit:never:{k}:{class}"));
            assert!(!e.lines().contains("=v"), "a value in a refusal");
        }
        let e =
            ChildEnv::build_with(&[], &d, &[("X".into(), "() { :; }".into())], false).unwrap_err();
        assert_eq!(e.token, "refused:env-inherit:never:X:shell-init");
        assert!(ChildEnv::build_with(&[], &d, &[("GIT_DIR".into(), "/g".into())], false).is_ok());
    }

    #[test]
    fn a_declared_proxy_with_userinfo_is_withheld() {
        let runner = os(&[
            ("HTTPS_PROXY", "http://user:pw@proxy:3128"),
            ("HTTP_PROXY", "http://proxy:3128"),
        ]);
        let d = Declared {
            profiles: vec!["net-egress".into()],
            inherit: vec![],
        };
        let env = ChildEnv::build_with(&runner, &d, &[], false).unwrap();
        assert!(get(&env, "HTTPS_PROXY").is_none());
        assert_eq!(env.withheld, vec!["HTTPS_PROXY".to_string()]);
        assert!(get(&env, "HTTP_PROXY").is_some());
    }

    #[test]
    fn header_judgements_name_the_variable_and_class() {
        let refuse = |n: &str| check_declared_name_with(n, false).unwrap_err().token;
        assert_eq!(
            refuse("LD_PRELOAD"),
            "refused:env-inherit:never:LD_PRELOAD:loader"
        );
        assert_eq!(
            refuse("MY_SERVICE_TOKEN"),
            "refused:env-inherit:never:MY_SERVICE_TOKEN:credential-shape"
        );
        assert_eq!(
            refuse("GIT_CONFIG_GLOBAL"),
            "refused:env-inherit:inherit-blocked:GIT_CONFIG_GLOBAL:redirection"
        );
        assert_eq!(refuse("TZ"), "refused:env-inherit:fixed:TZ");
        assert_eq!(
            refuse("CONTAINERS_*"),
            "refused:env-inherit:glob-not-supported:CONTAINERS_*"
        );
        assert_eq!(refuse("9X"), "refused:env-inherit:invalid-name:9X");
        assert_eq!(
            check_declared_name_with("PATH", false).unwrap(),
            Some("note:env-inherit:base:PATH".to_string())
        );
        assert_eq!(
            check_declared_name_with("TOOLBOX_PATH", false).unwrap(),
            None
        );
        assert_eq!(
            check_profile("podmann").unwrap_err().token,
            "refused:env-inherit:unknown-profile:podmann"
        );
    }

    // tasks 1.7, both sides on every host: the Windows rule folds case for
    // the A1/B tables, base, fixed and the runner lookup; the Linux rule does
    // not. The credential shape folds on both (design §4.2 A2).
    #[test]
    fn the_windows_rule_folds_case_and_the_linux_rule_does_not() {
        assert_eq!(hard_block_with("ld_preload", false), None);
        assert_eq!(
            hard_block_with("ld_preload", true),
            Some(Block::Never(NeverClass::Loader))
        );
        assert_eq!(
            hard_block_with("gh_token", false),
            Some(Block::Never(NeverClass::CredentialShape))
        );
        assert_eq!(
            check_declared_name_with("tz", true).unwrap_err().token,
            "refused:env-inherit:fixed:tz"
        );
        assert_eq!(check_declared_name_with("tz", false).unwrap(), None);
        // A runner's `Path` is the base `PATH` on Windows only.
        let runner = os(&[("Path", "C:\\bin"), ("container_host", "npipe:x")]);
        let d = Declared {
            profiles: vec!["podman".into()],
            inherit: vec![],
        };
        let win = ChildEnv::build_with(&runner, &d, &[], true).unwrap();
        assert!(get(&win, "PATH").is_some());
        assert!(win.inherited.contains(&"CONTAINER_HOST".to_string()));
        let lin = ChildEnv::build_with(&runner, &d, &[], false).unwrap();
        assert!(get(&lin, "PATH").is_none());
        assert!(lin.absent.contains(&"CONTAINER_HOST".to_string()));
    }
}
