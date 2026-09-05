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
//! # The default is NOT YET SECURE, and that is what this order changes
//!
//! Absent still means Off. The shipped default is a plaintext, credential-carrying
//! listener bound to any CID, opt-in through a variable that nothing in the
//! product sets — six files read it, none set it, and the only `export` in the
//! tree sits inside the message string of an `#[ignore]`d test. A security
//! posture that requires an undocumented environment variable to reach is not a
//! posture, it is a hope. The flip is prepared here and lands in the commit
//! that converts the LAST of the six readers, because "the default is secure"
//! is one fact about a HANDSHAKE: flipping one side of it is not a smaller
//! version of flipping both, it is an outage. See the wildcard arm below.
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
    /// Version-bound Noise handshake. Reached today only by an explicit `on`;
    /// becomes the default when the last reader is converted (972-umik).
    On,
    /// Plaintext. Today also the default when the variable is absent.
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
             'off' explicitly. Note that absent currently means OFF and becomes ON when 972-umik converts the last reader."
        )),
        Ok(v) => Err(format!(
            "{SECURE_CONTROL_WIRE_ENV} must be 'on' or 'off' (got {v:?}). Note \
             that '1', 'true' and 'yes' are NOT accepted: they used to mean \
             'secure' on some surfaces and 'plaintext' on others, which is the \
             divergence order 972-umik removed."
        )),
        // ABSENT IS STILL PLAINTEXT, AND THIS IS THE ONE LINE 972-umik EXISTS
        // TO CHANGE. It is deliberately NOT changed yet.
        //
        // I flipped it to On in e6a80609f with only the LISTENER converted, and
        // that broke the product: all four clients still carry their own
        // parsers defaulting to plaintext, nothing in scripts/ or packaging/
        // sets the variable, so every client opened a plaintext connection to a
        // server that had just started refusing plaintext. A silent insecurity
        // became a total outage, which is strictly worse.
        //
        // THE DECISION IS ATOMIC ACROSS SIX READERS. "The default is secure" is
        // one fact about a handshake, and flipping one side of a handshake is
        // not a smaller version of flipping both — it is a different, worse
        // change. A partial slice is only valid when the partial state is
        // COHERENT, and slicing this packet by crate produced a partial state
        // that was not.
        //
        // So the flip belongs in the commit that converts the LAST reader, not
        // the first. Until then this module's value is that the divergence
        // above is documented and single-sourced, with no behaviour change.
        Err(std::env::VarError::NotPresent) => Ok(SecureWireMode::Off),
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

    /// THE DEFAULT IS STILL PLAINTEXT AND THIS TEST PINS THAT, deliberately.
    /// 972-umik exists to flip it, and the flip must land in the commit that
    /// converts the LAST of the six readers — flipping the listener alone
    /// (e6a80609f) left every client opening plaintext to a server that had
    /// started refusing it. When the last reader lands, this test inverts and
    /// its name changes with it.
    #[test]
    fn absent_is_still_plaintext_until_every_reader_is_converted() {
        assert_eq!(
            parse_secure_wire_mode(Err(VarError::NotPresent)).unwrap(),
            SecureWireMode::Off,
            "the flip is atomic across six readers; see the module comment"
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
