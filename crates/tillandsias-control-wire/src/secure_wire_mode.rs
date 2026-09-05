//! The ONE reader of `TILLANDSIAS_SECURE_CONTROL_WIRE`.
//!
//! Order 972-umik. Before this module the decision "is the control wire
//! encrypted?" had SIX implementations with THREE different behaviours, and the
//! divergence shipped an insecure client to anyone who capitalised a word.
//!
//! # The divergence this replaces, measured on 2026-09-04
//!
//! | value     | four loud parsers | vm-layer/vz.rs | windows-tray/hvsocket.rs |
//! |-----------|-------------------|----------------|--------------------------|
//! | `on`      | On                | on             | secure                   |
//! | `On`/`ON` | On                | on             | **PLAINTEXT, silently**  |
//! | `1`/`true`| **ERROR, loud**   | **off, silent**| **PLAINTEXT, silently**  |
//! | `" on"`   | **ERROR, loud**   | **off, silent**| **PLAINTEXT, silently**  |
//! | `""`      | Off               | off            | plaintext                |
//! | absent    | Off               | off            | plaintext                |
//!
//! `1` is the sharp one: an operator writing `1`, because every other flag in
//! the world takes it, got a loud refusal on four surfaces and a silently
//! insecure client on a fifth. vz.rs is a THIRD shape that the original report
//! did not separate — `_ => "off"`, case-insensitive on `on` but silent on
//! everything else — and its value PROPAGATES INTO THE GUEST through the
//! systemd unit it writes, so a host-side silent default becomes the guest's
//! default too.
//!
//! # Why here rather than in tillandsias-secure-channel
//!
//! The adopted design said "secure-channel OR control-wire". Measured: four of
//! the five reader crates already depend on secure-channel, but
//! tillandsias-vm-layer does NOT, while ALL FIVE already depend on
//! control-wire. Putting it here is a pure MOVE for every reader; putting it in
//! secure-channel would have added a dependency to vm-layer, which is the
//! coupling the "this is a move, not a new edge" argument was meant to avoid.
//!
//! # The default is SECURE
//!
//! Absent means On. The shipped default was a plaintext, credential-carrying
//! listener bound to any CID, opt-in through a variable that nothing in the
//! product sets — six files read it, none set it, and the only `export` in the
//! tree sits inside the message string of an `#[ignore]`d test. A security
//! posture that requires an undocumented environment variable to reach is not a
//! posture, it is a hope.
//!
//! # An EMPTY value is a hard error, and that was contested
//!
//! macuahuitl proposed empty-as-error, then WITHDREW it with the right
//! reasoning: hardening one parser hardens the copies that already validate and
//! leaves untouched the one that does not, so the gap widens. That objection is
//! answered by unification rather than by dropping the rule — with one reader,
//! empty-as-error lands once and reaches all six call sites. Blank is the shape
//! an operator sets by accident (`export TILLANDSIAS_SECURE_CONTROL_WIRE=` in a
//! profile, a CI variable defined but unfilled), and silently meaning "insecure"
//! is the worst reading available for it.

/// Whether the control wire runs the Noise handshake or passes plaintext.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecureWireMode {
    /// Version-bound Noise handshake. The default.
    On,
    /// Plaintext. Reachable only by an explicit, exact `off`.
    Off,
}

impl SecureWireMode {
    /// True when the wire must be encrypted.
    pub fn is_secure(self) -> bool {
        matches!(self, SecureWireMode::On)
    }
}

/// The environment variable this module owns. Nothing else may read it; the
/// gate refuses a second reader (see scripts/check-secure-wire-single-reader.sh).
pub const SECURE_CONTROL_WIRE_ENV: &str = "TILLANDSIAS_SECURE_CONTROL_WIRE";

/// Parse the mode from an already-read environment value.
///
/// Split from the reader so it is testable without touching process-global
/// state: `HOME`-style `set_var` races are how three ca_path tests failed under
/// concurrent cargo (1002-9xmb), and this decision is too important to pin with
/// a test that can read another test's value.
pub fn parse_secure_wire_mode(
    raw: Result<String, std::env::VarError>,
) -> Result<SecureWireMode, String> {
    match raw {
        Ok(v) if v.eq_ignore_ascii_case("on") => Ok(SecureWireMode::On),
        Ok(v) if v.eq_ignore_ascii_case("off") => Ok(SecureWireMode::Off),
        Ok(v) if v.trim().is_empty() => Err(format!(
            "{SECURE_CONTROL_WIRE_ENV} is set but empty. Blank does NOT mean \
             'off' — it is the shape an unfilled CI variable takes, and reading \
             it as 'insecure' is the worst available guess. Set it to 'on' or \
             'off' explicitly, or unset it entirely (absent means ON)."
        )),
        Ok(v) => Err(format!(
            "{SECURE_CONTROL_WIRE_ENV} must be 'on' or 'off' (got {v:?}). Note \
             that '1', 'true' and 'yes' are NOT accepted: they used to mean \
             'secure' on some surfaces and 'plaintext' on others, which is the \
             divergence order 972-umik removed."
        )),
        // ABSENT IS SECURE. This is the flip.
        Err(std::env::VarError::NotPresent) => Ok(SecureWireMode::On),
        Err(err) => Err(format!("{SECURE_CONTROL_WIRE_ENV}: {err}")),
    }
}

/// Read and parse the mode from the process environment.
pub fn secure_wire_mode() -> Result<SecureWireMode, String> {
    parse_secure_wire_mode(std::env::var(SECURE_CONTROL_WIRE_ENV))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env::VarError;

    #[test]
    fn absent_is_secure() {
        assert_eq!(
            parse_secure_wire_mode(Err(VarError::NotPresent)).unwrap(),
            SecureWireMode::On,
            "the shipped default must be encrypted; opt-in security is not security"
        );
    }

    #[test]
    fn only_an_explicit_off_disables_it() {
        for v in ["off", "OFF", "Off"] {
            assert_eq!(
                parse_secure_wire_mode(Ok(v.to_string())).unwrap(),
                SecureWireMode::Off,
                "{v:?} is an explicit opt-out"
            );
        }
    }

    #[test]
    fn on_is_accepted_case_insensitively() {
        for v in ["on", "ON", "On", "oN"] {
            assert_eq!(
                parse_secure_wire_mode(Ok(v.to_string())).unwrap(),
                SecureWireMode::On,
                "{v:?} must be On — case sensitivity here shipped a plaintext \
                 windows client (972-umik)"
            );
        }
    }

    /// The values that used to diverge. Each must now be a LOUD error on every
    /// surface rather than On here and plaintext there.
    #[test]
    fn the_divergent_values_are_all_loud_errors() {
        for v in [
            "1", "0", "true", "false", "yes", "no", " on", "on ", "enabled",
        ] {
            let got = parse_secure_wire_mode(Ok(v.to_string()));
            assert!(
                got.is_err(),
                "{v:?} must be refused loudly; it silently meant PLAINTEXT on \
                 the windows lane and 'off' in vz.rs while four parsers errored"
            );
        }
    }

    #[test]
    fn empty_is_a_hard_error_not_a_silent_off() {
        for v in ["", "   ", "\t"] {
            let err = parse_secure_wire_mode(Ok(v.to_string()))
                .expect_err("blank must not silently mean insecure");
            assert!(
                err.contains("set but empty"),
                "the error must name the blank case: {err}"
            );
        }
    }

    /// A refusal that does not say what to do is a refusal the operator works
    /// around. Every error names the accepted values.
    #[test]
    fn every_refusal_names_the_accepted_values() {
        for v in ["1", "", "banana"] {
            let err = parse_secure_wire_mode(Ok(v.to_string())).unwrap_err();
            assert!(
                err.contains("'on'") && err.contains("'off'"),
                "refusal for {v:?} must name both accepted values: {err}"
            );
        }
    }
}
