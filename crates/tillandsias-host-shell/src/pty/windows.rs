//! Windows ConPTY backend for the host-side PTY (control-wire-pty-attach §3.3).
//!
//! [`ConPtyMaster`] owns a pseudoconsole (`CreatePseudoConsole`) plus its two
//! pipes: we WRITE host→guest stdin to `input_write` (the ConPTY's stdin) and
//! READ guest→host output from `output_read` (the ConPTY's stdout). The
//! `pump_io` bridge (next increment) wires these handles to a
//! [`crate::pty::PtySession`] over vsock; the tray (w4) then renders the
//! pseudoconsole via Windows Terminal.
//!
//! Covers the ConPTY *lifecycle* (create / resize / close), a child
//! `CreateProcessW`-into-the-pseudoconsole attach, and blocking pipe I/O. The
//! async `PtyMaster` impl (bridging the blocking I/O to tokio for `pump_io`)
//! is the next layer.
//!
//! @trace openspec/changes/control-wire-pty-attach/proposal.md (§3.3), spec:windows-native-tray

#![cfg(windows)]

use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::runtime::Handle;

// `use windows::…` resolves to the `windows` *crate* (extern), not this module.
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows::Win32::System::Console::{
    COORD, ClosePseudoConsole, CreatePseudoConsole, HPCON, ResizePseudoConsole,
};
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::Threading::{
    CreateProcessW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT,
    GetExitCodeProcess, INFINITE, InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST,
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, PROCESS_INFORMATION, STARTUPINFOEXW,
    UpdateProcThreadAttribute, WaitForSingleObject,
};
use windows::core::{PCWSTR, PWSTR};

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

    /// Spawn a console process attached to this pseudoconsole. In production
    /// the attached process is the local terminal renderer; for local tests it
    /// is any console app (its stdout flows to `output_read`).
    pub fn spawn(&self, argv: &[&str]) -> Result<ConPtyChild, PtyError> {
        if argv.is_empty() {
            return Err("spawn requires a non-empty argv".to_string());
        }
        // Basic command-line composition: quote args containing spaces.
        let cmdline = argv
            .iter()
            .map(|a| {
                if a.contains(' ') {
                    format!("\"{a}\"")
                } else {
                    (*a).to_string()
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        let mut cmd_w: Vec<u16> = cmdline.encode_utf16().chain(std::iter::once(0)).collect();

        unsafe {
            // Size, then build, the proc-thread attribute list with the
            // pseudoconsole attribute (the first call fails but fills `size`).
            let mut size: usize = 0;
            let _ = InitializeProcThreadAttributeList(
                LPPROC_THREAD_ATTRIBUTE_LIST(std::ptr::null_mut()),
                1,
                0,
                &mut size,
            );
            let mut attr_buf = vec![0u8; size];
            let attr_list = LPPROC_THREAD_ATTRIBUTE_LIST(attr_buf.as_mut_ptr() as *mut _);
            InitializeProcThreadAttributeList(attr_list, 1, 0, &mut size)
                .map_err(|e| format!("InitializeProcThreadAttributeList: {e}"))?;
            UpdateProcThreadAttribute(
                attr_list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                Some(self.hpc.0 as *const core::ffi::c_void),
                std::mem::size_of::<HPCON>(),
                None,
                None,
            )
            .map_err(|e| format!("UpdateProcThreadAttribute: {e}"))?;

            let mut si = STARTUPINFOEXW::default();
            si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
            si.lpAttributeList = attr_list;
            let mut pi = PROCESS_INFORMATION::default();

            let res = CreateProcessW(
                PCWSTR::null(),
                PWSTR(cmd_w.as_mut_ptr()),
                None,
                None,
                false,
                EXTENDED_STARTUPINFO_PRESENT,
                None,
                PCWSTR::null(),
                &si.StartupInfo,
                &mut pi,
            );
            DeleteProcThreadAttributeList(attr_list);
            res.map_err(|e| format!("CreateProcessW: {e}"))?;

            Ok(ConPtyChild {
                process: pi.hProcess,
                thread: pi.hThread,
            })
        }
    }

    /// Blocking write of host→guest stdin to the pseudoconsole input pipe.
    /// Returns the byte count written.
    pub fn write_input(&self, bytes: &[u8]) -> Result<usize, PtyError> {
        let mut written = 0u32;
        unsafe {
            WriteFile(self.input_write, Some(bytes), Some(&mut written), None)
                .map_err(|e| format!("WriteFile: {e}"))?;
        }
        Ok(written as usize)
    }

    /// Blocking read of guest→host output from the pseudoconsole output pipe.
    /// Returns 0 on EOF (all write ends closed).
    pub fn read_output(&self, buf: &mut [u8]) -> Result<usize, PtyError> {
        let mut read = 0u32;
        unsafe {
            ReadFile(self.output_read, Some(buf), Some(&mut read), None)
                .map_err(|e| format!("ReadFile: {e}"))?;
        }
        Ok(read as usize)
    }
}

/// A process attached to a [`ConPtyMaster`]. Closes its handles on `Drop`.
pub struct ConPtyChild {
    process: HANDLE,
    thread: HANDLE,
}

// Owned exclusively; safe to move across threads (e.g. a wait task).
unsafe impl Send for ConPtyChild {}

impl ConPtyChild {
    /// Block until the child exits; return its exit code.
    pub fn wait(&self) -> Result<u32, PtyError> {
        unsafe {
            WaitForSingleObject(self.process, INFINITE);
            let mut code = 0u32;
            GetExitCodeProcess(self.process, &mut code)
                .map_err(|e| format!("GetExitCodeProcess: {e}"))?;
            Ok(code)
        }
    }
}

impl Drop for ConPtyChild {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.process);
            let _ = CloseHandle(self.thread);
        }
    }
}

/// Send wrapper so a raw Win32 handle can move onto a bridge thread.
struct SendPtr<T>(T);
unsafe impl<T> Send for SendPtr<T> {}

/// Bridge the blocking ConPTY pipes to tokio async halves (for `pump_io`).
///
/// `split` hands ownership of the pipe handles to two dedicated blocking
/// threads (Win32 anonymous-pipe I/O has no native async on Windows):
/// - read thread: `ReadFile(output_read)` → a duplex → the returned `Reader`;
/// - write thread: the returned `Writer` → a duplex → `WriteFile(input_write)`.
///
/// `ManuallyDrop` suppresses `ConPtyMaster::drop` so the handles are closed
/// exactly once, by the threads, when their loops end.
///
/// Runtime behaviour is validated at VM end-to-end: a unit test can't exercise
/// the read bridge because `ReadFile` blocks until a process produces output.
impl super::PtyMaster for ConPtyMaster {
    type Reader = DuplexStream;
    type Writer = DuplexStream;

    fn split(self) -> (DuplexStream, DuplexStream) {
        let handle = Handle::current();
        // Take the handles; suppress Drop so they're not double-closed.
        let me = std::mem::ManuallyDrop::new(self);
        let hpc = SendPtr(me.hpc);
        let input_write = SendPtr(me.input_write);
        let output_read = SendPtr(me.output_read);

        // Read bridge: ConPTY output → Reader.
        let (reader_host, mut reader_side) = tokio::io::duplex(64 * 1024);
        let h_read = handle.clone();
        std::thread::spawn(move || {
            // Rebind the whole wrappers so the closure captures `SendPtr`
            // (Send), not the bare inner `HANDLE` (edition-2021 disjoint
            // captures would otherwise capture the field and break `Send`).
            let output_read = output_read;
            let hpc = hpc;
            let out = output_read.0;
            let pc = hpc.0;
            let mut buf = [0u8; 16 * 1024];
            loop {
                let mut read = 0u32;
                let ok = unsafe { ReadFile(out, Some(&mut buf), Some(&mut read), None) };
                if ok.is_err() || read == 0 {
                    break;
                }
                if h_read
                    .block_on(reader_side.write_all(&buf[..read as usize]))
                    .is_err()
                {
                    break;
                }
            }
            unsafe {
                ClosePseudoConsole(pc);
                let _ = CloseHandle(out);
            }
        });

        // Write bridge: Writer → ConPTY input.
        let (writer_host, mut writer_side) = tokio::io::duplex(64 * 1024);
        std::thread::spawn(move || {
            let input_write = input_write; // whole-SendPtr capture (see read thread)
            let inp = input_write.0;
            let mut buf = [0u8; 16 * 1024];
            loop {
                let n = match handle.block_on(writer_side.read(&mut buf)) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                let mut written = 0u32;
                if unsafe { WriteFile(inp, Some(&buf[..n]), Some(&mut written), None) }.is_err() {
                    break;
                }
            }
            unsafe {
                let _ = CloseHandle(inp);
            }
        });

        (reader_host, writer_host)
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

    /// Local mechanics test (no VM): spawn a real console process into the
    /// pseudoconsole and confirm its exit code propagates. This validates
    /// CreateProcessW-into-ConPTY + the proc-thread attribute list + wait().
    ///
    /// NB: it deliberately does NOT call `read_output` — `ReadFile` on the
    /// pseudoconsole pipe BLOCKS until data or all write-ends close, so reading
    /// it in a bounded unit test risks hanging. The blocking pipe I/O is
    /// exercised through the async `PtyMaster` bridge + VM end-to-end, not here.
    #[test]
    fn conpty_spawn_propagates_exit_code() {
        let pty = ConPtyMaster::new(24, 80).expect("create");
        let child = pty
            .spawn(&["cmd.exe", "/c", "exit", "7"])
            .expect("spawn into conpty");
        let code = child.wait().expect("wait");
        assert_eq!(code, 7, "ConPTY child exit code should propagate");
    }

    /// Compile-time check that ConPtyMaster satisfies the cross-platform
    /// PtyMaster trait (so pump_io can drive it). Does NOT call `split` —
    /// the read bridge blocks on ReadFile without a producing process, so its
    /// runtime behaviour is validated at VM end-to-end, not here.
    #[test]
    fn conpty_master_satisfies_pty_master_trait() {
        fn assert_impl<M: crate::pty::PtyMaster>() {}
        assert_impl::<ConPtyMaster>();
    }
}
