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
//! # The default IS NOW SECURE, and that is what this order changed
//!
//! Absent means On. Until this commit the shipped default was a plaintext,
//! credential-carrying listener bound to any CID, opt-in through a variable
//! that nothing in the product sets — six files read it, none set it, and the
//! only `export` in the tree sat inside the message string of an `#[ignore]`d
//! test. A security posture that requires an undocumented environment variable
//! to reach is not a posture, it is a hope. The flip landed in the commit that
//! converted the LAST of the six readers, because "the default is secure" is
//! one fact about a HANDSHAKE: flipping one side of it is not a smaller
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
    /// Version-bound Noise handshake. The DEFAULT since 972-umik converted
    /// the last of the six readers: an absent variable means On.
    On,
    /// Plaintext. Reachable only by writing `off` explicitly.
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
             'off' explicitly. Note that an ABSENT variable means ON \n             (972-umik converted the last reader and flipped the \n             default); blank is not a shorter way of writing either one."
        )),
        Ok(v) => Err(format!(
            "{SECURE_CONTROL_WIRE_ENV} must be 'on' or 'off' (got {v:?}). Note \
             that '1', 'true' and 'yes' are NOT accepted: they used to mean \
             'secure' on some surfaces and 'plaintext' on others, which is the \
             divergence order 972-umik removed."
        )),
        // ABSENT NOW MEANS SECURE. This is the line 972-umik existed to
        // change, and it changes here because THIS is the commit that lands
        // after the last of the six readers was converted — macbookair took the
        // two macOS readers (311aa27d5), yolanda took windows-tray/hvsocket.rs
        // (commit A, 7623213e2), and the ratchet
        // scripts/check-secure-wire-single-reader.sh reads 0 of 3.
        //
        // WHY NOT EARLIER. The flip was tried once with only the LISTENER
        // converted (e6a80609f, reverted at 08a7d3cc7): all four clients still
        // carried their own parsers defaulting to plaintext, so every client
        // opened a plaintext connection to a server that had just started
        // refusing plaintext. A silent insecurity became a total outage, which
        // is strictly worse. "The default is secure" is ONE fact about a
        // HANDSHAKE; flipping one side of it is not a smaller version of
        // flipping both. With one reader, both sides move in this commit.
        //
        // THE GUEST MOVES WITH THE HOST, and that is not incidental.
        // vm-layer/vz.rs derives the string it writes into the guest's systemd
        // unit (Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=...) from THIS
        // function, so an absent variable on the host now provisions a secure
        // guest rather than stamping "off" into the unit and into the VM's
        // instance-id.
        //
        // WHAT AN OPERATOR MUST DO TO GET THE OLD BEHAVIOUR: set it to `off`
        // explicitly. That is the intended cost — plaintext remains reachable,
        // but only on purpose, and it is now the spelling that has to be
        // written down rather than the one you get by saying nothing.
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

    /// THE DEFAULT IS SECURE AND THIS TEST PINS THAT. It is the inverse of
    /// `absent_is_still_plaintext_until_every_reader_is_converted`, which stood
    /// here until the last of the six readers was converted (972-umik). The
    /// earlier attempt to flip with only the listener converted (e6a80609f)
    /// left every client opening plaintext to a server that had started
    /// refusing it; both sides move together now.
    ///
    /// Pinned through the PURE parser with an explicit `VarError::NotPresent`
    /// rather than through `set_var`: process-global environment mutation races
    /// between concurrently running tests, which is how three ca_path tests
    /// failed under concurrent cargo (1002-9xmb). A default this important must
    /// not be pinned by a test that can read another test's value.
    ///
    /// @trace order:972-umik
    #[test]
    fn absent_means_secure_now_that_every_reader_is_converted() {
        assert_eq!(
            parse_secure_wire_mode(Err(VarError::NotPresent)).unwrap(),
            SecureWireMode::On,
            "an absent variable must mean an ENCRYPTED wire; plaintext is now              reachable only by writing 'off' explicitly"
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
