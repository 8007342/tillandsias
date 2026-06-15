//! Recipe + manifest parser for the VM provisioning recipe
//! (`vm-recipe-provisioning` §2). Shared / co-owned module.
//!
//! Pure parsing — no VM, no buildah, no network. Turns `images/vm/Recipefile`
//! (a Containerfile augmented with the three `RECIPE` directives, design D1)
//! into an AST, and `images/vm/manifest.toml` (design D2 + the D6 format
//! matrix) into a per-arch base-digest lookup. The materializer (§3, NOT in
//! this module — co-owned, per-OS backends) consumes this AST.
//!
//! Behind the `recipe` feature so trait-only / minimal builds stay lean.
//!
//! @trace spec:vm-provisioning-lifecycle

use std::collections::HashMap;
use std::path::Path;

use serde::Deserialize;

/// Already-rendered error context — matches the crate's `VmError` /
/// `FetchError` String-error idiom.
pub type RecipeError = String;

/// One parsed Recipefile instruction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Instruction {
    From {
        image: String,
    },
    Arg {
        name: String,
        default: Option<String>,
    },
    Run {
        script: String,
    },
    Copy {
        src: String,
        dest: String,
    },
    Env {
        key: String,
        value: String,
    },
    Workdir {
        path: String,
    },
    Recipe(RecipeDirective),
    /// A recognised-but-not-modelled Containerfile keyword (LABEL, USER,
    /// EXPOSE, …). Preserved verbatim so the parser is forward-compatible and
    /// does not reject otherwise-valid Containerfiles.
    Other {
        keyword: String,
        args: String,
    },
}

/// The three `RECIPE` directives layered on top of Containerfile syntax (D1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecipeDirective {
    /// `RECIPE vsock-listen <port>` — install a systemd unit running
    /// `tillandsias-headless --listen-vsock <port>` on boot.
    VsockListen(u32),
    /// `RECIPE entry <command>` — informational primary entrypoint.
    Entry(String),
    /// `RECIPE arch <a,b,…>` — supported architectures.
    Arch(Vec<String>),
}

/// Parsed `images/vm/Recipefile`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recipe {
    pub instructions: Vec<Instruction>,
}

impl Recipe {
    /// Parse a Recipefile from disk.
    pub fn parse(path: &Path) -> Result<Recipe, RecipeError> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("read recipe {}: {e}", path.display()))?;
        Self::parse_str(&text)
    }

    /// Parse a Recipefile from a string.
    pub fn parse_str(text: &str) -> Result<Recipe, RecipeError> {
        let mut instructions = Vec::new();
        for logical in logical_lines(text) {
            let line = logical.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            instructions.push(parse_instruction(line)?);
        }
        Ok(Recipe { instructions })
    }

    /// The `FROM` image reference, if any.
    pub fn from_image(&self) -> Option<&str> {
        self.instructions.iter().find_map(|i| match i {
            Instruction::From { image } => Some(image.as_str()),
            _ => None,
        })
    }

    /// Architectures declared by `RECIPE arch`, if present.
    pub fn supported_arches(&self) -> Option<&[String]> {
        self.instructions.iter().find_map(|i| match i {
            Instruction::Recipe(RecipeDirective::Arch(a)) => Some(a.as_slice()),
            _ => None,
        })
    }

    /// vsock port declared by `RECIPE vsock-listen`, if present.
    pub fn vsock_port(&self) -> Option<u32> {
        self.instructions.iter().find_map(|i| match i {
            Instruction::Recipe(RecipeDirective::VsockListen(p)) => Some(*p),
            _ => None,
        })
    }

    /// Entry command declared by `RECIPE entry`, if present.
    pub fn entry(&self) -> Option<&str> {
        self.instructions.iter().find_map(|i| match i {
            Instruction::Recipe(RecipeDirective::Entry(c)) => Some(c.as_str()),
            _ => None,
        })
    }

    /// True iff `arch` is in the recipe's `RECIPE arch` set. A recipe with no
    /// `RECIPE arch` directive is treated as supporting any arch.
    pub fn supports_arch(&self, arch: &str) -> bool {
        match self.supported_arches() {
            Some(set) => set.iter().any(|a| a == arch),
            None => true,
        }
    }
}

/// Join Containerfile line continuations (trailing `\`) into logical lines.
fn logical_lines(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut acc = String::new();
    for raw in text.lines() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some(prefix) = line.strip_suffix('\\') {
            acc.push_str(prefix);
            acc.push(' ');
        } else {
            acc.push_str(line);
            out.push(std::mem::take(&mut acc));
        }
    }
    if !acc.is_empty() {
        out.push(acc);
    }
    out
}

fn parse_instruction(line: &str) -> Result<Instruction, RecipeError> {
    let (keyword, rest) = match line.split_once(char::is_whitespace) {
        Some((k, r)) => (k, r.trim()),
        None => (line, ""),
    };
    match keyword.to_ascii_uppercase().as_str() {
        "FROM" => {
            if rest.is_empty() {
                return Err("FROM requires an image reference".into());
            }
            Ok(Instruction::From {
                image: rest.to_string(),
            })
        }
        "ARG" => {
            let (name, default) = match rest.split_once('=') {
                Some((n, d)) => (n.trim().to_string(), Some(d.trim().to_string())),
                None => (rest.to_string(), None),
            };
            if name.is_empty() {
                return Err("ARG requires a name".into());
            }
            Ok(Instruction::Arg { name, default })
        }
        "RUN" => Ok(Instruction::Run {
            script: rest.to_string(),
        }),
        "COPY" => {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() < 2 {
                return Err(format!("COPY requires <src> <dest>, got: {rest:?}"));
            }
            // Last token is the destination; the rest join as the source
            // (single logical source in v1).
            let dest = parts[parts.len() - 1].to_string();
            let src = parts[..parts.len() - 1].join(" ");
            Ok(Instruction::Copy { src, dest })
        }
        "ENV" => {
            let (key, value) = match rest.split_once('=') {
                Some((k, v)) => (k.trim().to_string(), v.trim().to_string()),
                None => match rest.split_once(char::is_whitespace) {
                    Some((k, v)) => (k.trim().to_string(), v.trim().to_string()),
                    None => {
                        return Err(format!(
                            "ENV requires KEY=VALUE or KEY VALUE, got: {rest:?}"
                        ));
                    }
                },
            };
            if key.is_empty() {
                return Err("ENV requires a key".into());
            }
            Ok(Instruction::Env { key, value })
        }
        "WORKDIR" => {
            if rest.is_empty() {
                return Err("WORKDIR requires a path".into());
            }
            Ok(Instruction::Workdir {
                path: rest.to_string(),
            })
        }
        "RECIPE" => parse_recipe_directive(rest).map(Instruction::Recipe),
        other => Ok(Instruction::Other {
            keyword: other.to_string(),
            args: rest.to_string(),
        }),
    }
}

fn parse_recipe_directive(rest: &str) -> Result<RecipeDirective, RecipeError> {
    let (verb, args) = match rest.split_once(char::is_whitespace) {
        Some((v, a)) => (v, a.trim()),
        None => (rest, ""),
    };
    match verb {
        "vsock-listen" => {
            let port: u32 = args
                .trim()
                .parse()
                .map_err(|_| format!("RECIPE vsock-listen requires a u32 port, got: {args:?}"))?;
            Ok(RecipeDirective::VsockListen(port))
        }
        "entry" => {
            if args.is_empty() {
                return Err("RECIPE entry requires a command".into());
            }
            Ok(RecipeDirective::Entry(args.to_string()))
        }
        "arch" => {
            let arches: Vec<String> = args
                .split(',')
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty())
                .collect();
            if arches.is_empty() {
                return Err("RECIPE arch requires a comma-separated arch list".into());
            }
            Ok(RecipeDirective::Arch(arches))
        }
        other => Err(format!(
            "unknown RECIPE verb: {other}; valid: vsock-listen, entry, arch"
        )),
    }
}

// ---------------------------------------------------------------------------
// manifest.toml (design D2 + D6 format matrix)
// ---------------------------------------------------------------------------

/// Parsed `images/vm/manifest.toml`.
#[derive(Debug, Clone, Deserialize)]
pub struct Manifest {
    pub recipe_version: u32,
    #[serde(default)]
    pub recipe_sha: Option<String>,
    /// `[[base]]` array-of-tables: one pinned base image per arch.
    #[serde(default, rename = "base")]
    pub bases: Vec<BaseImage>,
    #[serde(default)]
    pub output: Option<OutputSpec>,
}

/// One pinned base image (`[[base]]` entry).
#[derive(Debug, Clone, Deserialize)]
pub struct BaseImage {
    pub arch: String,
    /// `ref` in TOML; `ref` is a Rust keyword so it is renamed here.
    #[serde(rename = "ref")]
    pub image_ref: String,
    pub digest: String,
    #[serde(default)]
    pub manifest_size_bytes: Option<u64>,
}

/// `[output]` block. Per D6 the SHA map is keyed by `<arch>` or
/// `<arch>.<format>` (e.g. `"aarch64.qcow2"`, `"x86_64.tar"`).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct OutputSpec {
    #[serde(default)]
    pub expected_rootfs_sha: HashMap<String, String>,
    /// Exact artifact locators keyed by `<arch>.<format>`. These take
    /// precedence over `artifact_url_template`, allowing hosts to consume
    /// different official Fedora image families without guessing paths.
    #[serde(default)]
    pub artifact_urls: HashMap<String, String>,
    /// l9: artifact-URL contract. A template with `{tag}`, `{arch}`,
    /// and `{format}` placeholders that non-Linux hosts resolve at
    /// fetch time. The default points at the GitHub release asset
    /// uploaded by `.github/workflows/recipe-publish.yml`. Hosts MAY
    /// override at install time (e.g. internal mirror) — the recipe
    /// stays the trust root, manifest SHAs are the verification gate.
    #[serde(default)]
    pub artifact_url_template: Option<String>,
}

impl Manifest {
    /// Load + parse `manifest.toml` from disk.
    pub fn load(path: &Path) -> Result<Manifest, RecipeError> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("read manifest {}: {e}", path.display()))?;
        Self::from_toml(&text)
    }

    /// Parse `manifest.toml` from a string.
    pub fn from_toml(text: &str) -> Result<Manifest, RecipeError> {
        toml::from_str(text).map_err(|e| format!("parse manifest.toml: {e}"))
    }

    /// The pinned base image for `arch`, if present.
    pub fn base_for_arch(&self, arch: &str) -> Option<&BaseImage> {
        self.bases.iter().find(|b| b.arch == arch)
    }

    /// The expected rootfs SHA for an `<arch>` or `<arch>.<format>` key.
    pub fn expected_sha(&self, key: &str) -> Option<&str> {
        self.output
            .as_ref()
            .and_then(|o| o.expected_rootfs_sha.get(key))
            .map(|s| s.as_str())
    }

    /// l9: resolve the artifact URL for `(arch, format, tag)`. An exact
    /// `<arch>.<format>` entry wins; otherwise the optional template is used.
    ///
    /// Substitution is positional `replace`; we don't pull in a full
    /// template engine because the variable surface is fixed.
    ///
    /// @trace plan/issues/cross-host-blocker-roundup-2026-05-25.md l9
    pub fn artifact_url(&self, arch: &str, format: &str, tag: &str) -> Option<String> {
        let output = self.output.as_ref()?;
        let key = format!("{arch}.{format}");
        if let Some(url) = output.artifact_urls.get(&key) {
            return Some(url.clone());
        }
        let tmpl = output.artifact_url_template.as_ref()?;
        Some(
            tmpl.replace("{arch}", arch)
                .replace("{format}", format)
                .replace("{tag}", tag),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_RECIPE: &str = include_str!("../../tests/fixtures/recipe-basic/Recipefile");
    const FIXTURE_MANIFEST: &str = include_str!("../../tests/fixtures/recipe-basic/manifest.toml");
    const PRODUCTION_MANIFEST: &str = include_str!("../../../../images/vm/manifest.toml");

    #[test]
    fn parses_full_recipe_and_accessors() {
        let recipe = Recipe::parse_str(FIXTURE_RECIPE).expect("parse fixture");
        assert_eq!(
            recipe.from_image(),
            Some("registry.fedoraproject.org/fedora:44@sha256:deadbeef")
        );
        assert_eq!(recipe.vsock_port(), Some(42420));
        assert_eq!(recipe.entry(), Some("/usr/local/bin/tillandsias-headless"));
        assert_eq!(
            recipe.supported_arches(),
            Some(["x86_64".to_string(), "aarch64".to_string()].as_slice())
        );
        assert!(recipe.supports_arch("x86_64"));
        assert!(recipe.supports_arch("aarch64"));
        assert!(!recipe.supports_arch("riscv64"));
        // Three RUN steps from the bootstrap scripts + the dnf install.
        let runs = recipe
            .instructions
            .iter()
            .filter(|i| matches!(i, Instruction::Run { .. }))
            .count();
        assert_eq!(runs, 4);
    }

    #[test]
    fn exact_artifact_url_precedes_template() {
        let manifest = Manifest::from_toml(
            r#"
recipe_version = 1
[output]
artifact_url_template = "https://example.invalid/{arch}/{format}/{tag}"
[output.artifact_urls]
"x86_64.oci.tar.xz" = "https://download.example/fedora.oci.tar.xz"
"#,
        )
        .expect("parse manifest");

        assert_eq!(
            manifest.artifact_url("x86_64", "oci.tar.xz", "ignored"),
            Some("https://download.example/fedora.oci.tar.xz".to_string())
        );
        assert_eq!(
            manifest.artifact_url("aarch64", "qcow2", "v1"),
            Some("https://example.invalid/aarch64/qcow2/v1".to_string())
        );
    }

    #[test]
    fn production_manifest_resolves_published_fedora_artifacts() {
        let manifest = Manifest::from_toml(PRODUCTION_MANIFEST).expect("parse production manifest");

        assert_eq!(
            manifest.artifact_url("x86_64", "oci.tar.xz", "ignored"),
            Some("https://download.fedoraproject.org/pub/fedora/linux/releases/44/Container/x86_64/images/Fedora-Container-Base-Generic-44-1.7.x86_64.oci.tar.xz".to_string())
        );
        assert_eq!(
            manifest.expected_sha("x86_64.oci.tar.xz"),
            Some("75200f5752a74a21a616ca9a75e25beb594e2e117a0195c54f87c0b3e3974d1b")
        );
        assert_eq!(
            manifest.artifact_url("aarch64", "qcow2", "ignored"),
            Some("https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2".to_string())
        );
    }

    #[test]
    fn parses_individual_instructions() {
        // NB: do NOT `use Instruction::*` here — the `Recipe` variant would
        // shadow the `Recipe` struct. Qualify each variant explicitly.
        let r = Recipe::parse_str(
            "FROM fedora:44\nARG TARGETARCH\nARG FOO=bar\nCOPY bootstrap/ /opt/bootstrap/\nENV KEY=val\nENV OTHER value2\nWORKDIR /src\nLABEL maintainer=me\n",
        )
        .unwrap();
        assert_eq!(
            r.instructions[0],
            Instruction::From {
                image: "fedora:44".into()
            }
        );
        assert_eq!(
            r.instructions[1],
            Instruction::Arg {
                name: "TARGETARCH".into(),
                default: None
            }
        );
        assert_eq!(
            r.instructions[2],
            Instruction::Arg {
                name: "FOO".into(),
                default: Some("bar".into())
            }
        );
        assert_eq!(
            r.instructions[3],
            Instruction::Copy {
                src: "bootstrap/".into(),
                dest: "/opt/bootstrap/".into()
            }
        );
        assert_eq!(
            r.instructions[4],
            Instruction::Env {
                key: "KEY".into(),
                value: "val".into()
            }
        );
        assert_eq!(
            r.instructions[5],
            Instruction::Env {
                key: "OTHER".into(),
                value: "value2".into()
            }
        );
        assert_eq!(
            r.instructions[6],
            Instruction::Workdir {
                path: "/src".into()
            }
        );
        // Unknown-but-valid Containerfile keyword is preserved, not rejected.
        assert_eq!(
            r.instructions[7],
            Instruction::Other {
                keyword: "LABEL".into(),
                args: "maintainer=me".into()
            }
        );
    }

    #[test]
    fn comments_and_blank_lines_are_skipped() {
        let r = Recipe::parse_str("# a comment\n\nFROM x\n  # indented comment\n").unwrap();
        assert_eq!(r.instructions.len(), 1);
    }

    #[test]
    fn line_continuation_joins() {
        let r = Recipe::parse_str("RUN dnf install -y \\\n  systemd \\\n  podman\n").unwrap();
        match &r.instructions[0] {
            Instruction::Run { script } => {
                assert!(script.contains("systemd"));
                assert!(script.contains("podman"));
                assert!(script.contains("dnf install"));
            }
            other => panic!("expected Run, got {other:?}"),
        }
    }

    #[test]
    fn unknown_recipe_verb_errors() {
        let err = Recipe::parse_str("RECIPE teleport now\n").unwrap_err();
        assert!(err.contains("unknown RECIPE verb: teleport"), "got: {err}");
        assert!(
            err.contains("vsock-listen"),
            "error lists valid verbs: {err}"
        );
    }

    #[test]
    fn recipe_directive_validation() {
        assert!(Recipe::parse_str("RECIPE vsock-listen notaport\n").is_err());
        assert!(Recipe::parse_str("RECIPE entry\n").is_err());
        assert!(Recipe::parse_str("RECIPE arch\n").is_err());
        // FROM with no image fails.
        assert!(Recipe::parse_str("FROM\n").is_err());
        // COPY with one arg fails.
        assert!(Recipe::parse_str("COPY only-one\n").is_err());
    }

    #[test]
    fn keyword_is_case_insensitive() {
        let r = Recipe::parse_str("from fedora:44\nrun echo hi\n").unwrap();
        assert_eq!(r.from_image(), Some("fedora:44"));
    }

    #[test]
    fn manifest_parses_and_looks_up_arch() {
        let m = Manifest::from_toml(FIXTURE_MANIFEST).expect("parse manifest fixture");
        assert_eq!(m.recipe_version, 1);
        let x86 = m.base_for_arch("x86_64").expect("x86_64 base");
        assert_eq!(x86.image_ref, "registry.fedoraproject.org/fedora:44");
        assert!(x86.digest.starts_with("sha256:"));
        assert_eq!(x86.manifest_size_bytes, Some(524288));
        assert!(m.base_for_arch("aarch64").is_some());
        assert!(m.base_for_arch("riscv64").is_none());
        // D6 format-matrix keys.
        assert_eq!(m.expected_sha("x86_64.tar"), Some("aaaa"));
        assert_eq!(m.expected_sha("aarch64.qcow2"), Some("cccc"));
        assert_eq!(m.expected_sha("nope"), None);
    }

    #[test]
    fn manifest_rejects_malformed_toml() {
        assert!(Manifest::from_toml("this is not = = toml").is_err());
    }

    /// @trace plan/issues/cross-host-blocker-roundup-2026-05-25.md l9
    #[test]
    fn artifact_url_resolves_with_substitution() {
        let m = Manifest::from_toml(FIXTURE_MANIFEST).expect("parse fixture");
        let url = m
            .artifact_url("x86_64", "tar", "v0.2.260526.1")
            .expect("template resolves");
        assert_eq!(
            url,
            "https://example.test/releases/v0.2.260526.1/rootfs-x86_64.tar"
        );
    }

    /// @trace plan/issues/cross-host-blocker-roundup-2026-05-25.md l9
    #[test]
    fn artifact_url_substitutes_macos_qcow2_format() {
        let m = Manifest::from_toml(FIXTURE_MANIFEST).expect("parse fixture");
        let url = m
            .artifact_url("aarch64", "qcow2", "v0.2.260526.1")
            .expect("template resolves");
        assert!(url.contains("aarch64.qcow2"), "got {url}");
        assert!(url.contains("v0.2.260526.1"), "got {url}");
    }

    /// @trace plan/issues/cross-host-blocker-roundup-2026-05-25.md l9
    #[test]
    fn artifact_url_returns_none_when_template_absent() {
        let m = Manifest::from_toml(
            r#"
recipe_version = 1
[output]
expected_rootfs_sha = { "x86_64.tar" = "x" }
"#,
        )
        .unwrap();
        assert!(m.artifact_url("x86_64", "tar", "v1").is_none());
    }
}
