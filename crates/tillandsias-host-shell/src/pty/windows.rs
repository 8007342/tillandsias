//! Windows ConPTY backend for the host-side PTY (control-wire-pty-attach §3.3).
//!
//! [`ConPtyMaster`] owns a pseudoconsole (`CreatePseudoConsole`) plus its two
//! pipes: we WRITE host→guest stdin to `input_write` (the ConPTY's stdin) and
//! READ guest→host output from `output_read` (the ConPTY's stdout). The
//! `pump_io` bridge (next increment) wires these handles to a
//! [`crate::pty::PtySession`] over vsock; the tray (w4) then renders the
//! pseudoconsole via Windows Terminal.
//!
//! This module is the ConPTY *lifecycle* (create / resize / close). The
//! `CreateProcessW`-into-the-ConPTY attach + async pipe I/O land with pump_io.
//!
//! @trace openspec/changes/control-wire-pty-attach/proposal.md (§3.3), spec:windows-native-tray

#![cfg(windows)]

// `use windows::…` resolves to the `windows` *crate* (extern), not this module.
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::Console::{
    ClosePseudoConsole, CreatePseudoConsole, ResizePseudoConsole, HPCON,
};
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::Console::COORD;

use super::PtyError;

/// A host-side pseudoconsole and its bridge pipes. `Send` so it can move onto
/// the pump_io task; the underlying handles are owned exclusively by this
/// struct and closed on `Drop`.
pub struct ConPtyMaster {
    hpc: HPCON,
    /// Write end of the ConPTY input pipe — host→guest stdin goes here.
    input_write: HANDLE,
    /// Read end of the ConPTY output pipe — guest→host output comes from here.
    output_read: HANDLE,
}

// The handles are owned solely by this struct; no aliasing. Sending it across
// threads (onto the pump task) is sound.
unsafe impl Send for ConPtyMaster {}

impl ConPtyMaster {
    /// Create a pseudoconsole sized `rows`×`cols` with fresh I/O pipes.
    pub fn new(rows: u16, cols: u16) -> Result<Self, PtyError> {
        unsafe {
            let mut input_read = HANDLE::default();
            let mut input_write = HANDLE::default();
            CreatePipe(&mut input_read, &mut input_write, None, 0)
                .map_err(|e| format!("CreatePipe(input): {e}"))?;

            let mut output_read = HANDLE::default();
            let mut output_write = HANDLE::default();
            CreatePipe(&mut output_read, &mut output_write, None, 0)
                .map_err(|e| format!("CreatePipe(output): {e}"))?;

            let size = COORD {
                X: cols as i16,
                Y: rows as i16,
            };
            let hpc = CreatePseudoConsole(size, input_read, output_write, 0)
                .map_err(|e| format!("CreatePseudoConsole: {e}"))?;

            // The pseudoconsole duplicated the ends it needs; close ours.
            let _ = CloseHandle(input_read);
            let _ = CloseHandle(output_write);

            Ok(ConPtyMaster {
                hpc,
                input_write,
                output_read,
            })
        }
    }

    /// Relay a terminal resize to the pseudoconsole (§3.5, local side).
    pub fn resize(&self, rows: u16, cols: u16) -> Result<(), PtyError> {
        let size = COORD {
            X: cols as i16,
            Y: rows as i16,
        };
        unsafe {
            ResizePseudoConsole(self.hpc, size).map_err(|e| format!("ResizePseudoConsole: {e}"))
        }
    }

    /// Raw write handle (host→guest stdin). Used by pump_io.
    pub fn input_write_handle(&self) -> HANDLE {
        self.input_write
    }

    /// Raw read handle (guest→host output). Used by pump_io.
    pub fn output_read_handle(&self) -> HANDLE {
        self.output_read
    }
}

impl Drop for ConPtyMaster {
    fn drop(&mut self) {
        unsafe {
            // Closing the pseudoconsole signals any attached process to exit.
            ClosePseudoConsole(self.hpc);
            let _ = CloseHandle(self.input_write);
            let _ = CloseHandle(self.output_read);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Local mechanics test (no VM): the ConPTY lifecycle works on this host.
    #[test]
    fn conpty_create_resize_drop() {
        let pty = ConPtyMaster::new(24, 80).expect("CreatePseudoConsole");
        assert!(!pty.input_write_handle().is_invalid());
        assert!(!pty.output_read_handle().is_invalid());
        pty.resize(40, 120).expect("ResizePseudoConsole");
        // Drop closes the pseudoconsole + handles without panicking.
    }
}
