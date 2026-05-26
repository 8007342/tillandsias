//! Content-addressed layer keys (§3.2 of vm-recipe-provisioning).
//!
//! `LayerKey = sha256_hex(parent_layer_key || directive_text || arch)`.
//! The parent key is the rolling fold; the first layer in the chain folds
//! the empty key. Two recipes with the same instructions in the same
//! order on the same arch produce byte-identical keys, so the cache hit
//! rate is deterministic — exactly the property design D3 requires.
//!
//! `COPY` and `RUN` source content hashing (the "copied_content_sha"
//! mentioned in the design) is not yet wired here; for now the directive
//! text is the proxy. Once the materializer can run with a bind-mounted
//! build context, this module is the natural place to add per-COPY
//! source SHA accumulation.
//!
//! @trace spec:vm-provisioning-lifecycle (§3.2)

use sha2::{Digest, Sha256};

use super::HostArch;
use crate::recipe::{Instruction, RecipeDirective};

/// Stable hex-encoded SHA-256 of the layer's inputs. Derive via [`layer_key`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LayerKey(String);

impl LayerKey {
    /// Hex string the cache uses as a path component.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// First 12 hex chars — useful for human-readable trace logs.
    pub fn short(&self) -> &str {
        &self.0[..12.min(self.0.len())]
    }
}

impl std::fmt::Display for LayerKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Compute the layer key for `instruction` given the parent's key and
/// the target arch. Pure function; never reads files.
pub fn layer_key(parent: Option<&LayerKey>, instruction: &Instruction, arch: HostArch) -> LayerKey {
    let mut hasher = Sha256::new();
    if let Some(p) = parent {
        hasher.update(p.0.as_bytes());
    } else {
        hasher.update(b""); // explicit empty seed for chain start
    }
    hasher.update(b"|");
    hasher.update(arch.as_str().as_bytes());
    hasher.update(b"|");
    hasher.update(directive_text(instruction).as_bytes());
    let digest = hasher.finalize();
    LayerKey(hex_encode(&digest))
}

fn directive_text(instr: &Instruction) -> String {
    match instr {
        Instruction::From { image } => format!("FROM {image}"),
        Instruction::Arg { name, default } => match default {
            Some(d) => format!("ARG {name}={d}"),
            None => format!("ARG {name}"),
        },
        Instruction::Run { script } => format!("RUN {script}"),
        Instruction::Copy { src, dest } => format!("COPY {src} {dest}"),
        Instruction::Env { key, value } => format!("ENV {key}={value}"),
        Instruction::Workdir { path } => format!("WORKDIR {path}"),
        Instruction::Recipe(RecipeDirective::VsockListen(port)) => {
            format!("RECIPE vsock-listen {port}")
        }
        Instruction::Recipe(RecipeDirective::Entry(cmd)) => format!("RECIPE entry {cmd}"),
        Instruction::Recipe(RecipeDirective::Arch(list)) => {
            format!("RECIPE arch {}", list.join(","))
        }
        Instruction::Other { keyword, args } => format!("{keyword} {args}"),
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(script: &str) -> Instruction {
        Instruction::Run {
            script: script.into(),
        }
    }

    #[test]
    fn layer_key_is_64_hex_chars() {
        let k = layer_key(None, &run("echo hi"), HostArch::X86_64);
        assert_eq!(k.as_str().len(), 64);
        assert!(k.as_str().chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn layer_key_is_deterministic() {
        let k1 = layer_key(None, &run("dnf install -y systemd"), HostArch::X86_64);
        let k2 = layer_key(None, &run("dnf install -y systemd"), HostArch::X86_64);
        assert_eq!(k1, k2);
    }

    #[test]
    fn layer_key_changes_with_arch() {
        let k_x = layer_key(None, &run("dnf install -y systemd"), HostArch::X86_64);
        let k_a = layer_key(None, &run("dnf install -y systemd"), HostArch::Aarch64);
        assert_ne!(k_x, k_a);
    }

    #[test]
    fn layer_key_changes_with_parent() {
        let parent_a = layer_key(None, &run("layer a"), HostArch::X86_64);
        let parent_b = layer_key(None, &run("layer b"), HostArch::X86_64);
        let child_after_a = layer_key(Some(&parent_a), &run("RUN echo"), HostArch::X86_64);
        let child_after_b = layer_key(Some(&parent_b), &run("RUN echo"), HostArch::X86_64);
        assert_ne!(child_after_a, child_after_b);
    }

    #[test]
    fn layer_key_changes_with_directive_text() {
        let k1 = layer_key(None, &run("echo a"), HostArch::X86_64);
        let k2 = layer_key(None, &run("echo b"), HostArch::X86_64);
        assert_ne!(k1, k2);
    }

    #[test]
    fn short_returns_first_12_hex_chars() {
        let k = layer_key(None, &run("x"), HostArch::X86_64);
        assert_eq!(k.short().len(), 12);
        assert!(k.as_str().starts_with(k.short()));
    }
}
