//! Output-only audio for host browser windows (order 1722-2haw).
//!
//! A browser container gets exactly one audio path: the socket file of a
//! dedicated PulseAudio-protocol server that refuses every record stream and
//! module load (see `host_audio_pulse.conf`). The host's own
//! `$XDG_RUNTIME_DIR/pulse/native` is never mounted: it would give a page the
//! microphone, and the monitor of every sink.
//!
//! The server is a child of the tray, started on the first visible window and
//! reused after that. It dies with the tray (PR_SET_PDEATHSIG).
//!
//! @trace spec:browser-isolation-tray-integration

use std::io;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The pinned server configuration. `@SOCKET@` is the only substitution.
pub(crate) const PULSE_CONF: &str = include_str!("host_audio_pulse.conf");

/// `sun_path` holds 108 bytes including the terminating NUL. A longer path
/// fails inside pipewire as "address family not supported", which names
/// nothing (measured 2026-10-15 with a 116-byte path).
const SUN_PATH_MAX: usize = 107;

/// How long a fresh server gets to bind its socket.
const START_BUDGET: Duration = Duration::from_secs(3);

/// The socket a browser container mounts, under the tray's runtime dir.
pub(crate) fn socket_path(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join("tillandsias/audio/native")
}

/// The configuration for a server listening on `socket`.
pub(crate) fn render_conf(socket: &Path) -> Result<String, String> {
    let socket = socket
        .to_str()
        .ok_or("the audio socket path is not UTF-8")?;
    if socket.len() > SUN_PATH_MAX {
        return Err(format!(
            "the audio socket path is {} bytes; a unix socket path holds at most {SUN_PATH_MAX}",
            socket.len()
        ));
    }
    if socket.contains('"') {
        return Err("the audio socket path contains a quote".into());
    }
    Ok(PULSE_CONF.replace("@SOCKET@", socket))
}

fn listening(socket: &Path) -> bool {
    UnixStream::connect(socket).is_ok()
}

/// The child server, held for the tray's lifetime.
static SERVER: Mutex<Option<std::process::Child>> = Mutex::new(None);

/// The output-only audio socket, starting its server if none is listening.
/// `Err` says why a window has no sound; the window still opens.
pub(crate) fn ensure_output_only_socket(runtime_dir: &Path) -> Result<PathBuf, String> {
    let socket = socket_path(runtime_dir);
    let mut server = SERVER
        .lock()
        .map_err(|_| "the audio server lock is poisoned")?;
    if let Some(child) = server.as_mut() {
        if child.try_wait().ok().flatten().is_none() && listening(&socket) {
            return Ok(socket);
        }
        let _ = child.kill();
        let _ = child.wait();
        *server = None;
    }
    let dir = socket.parent().ok_or("the audio socket has no directory")?;
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    // A socket left by a server that died with an earlier tray.
    if socket.exists() {
        std::fs::remove_file(&socket)
            .map_err(|e| format!("cannot remove the stale {}: {e}", socket.display()))?;
    }
    let conf = dir.join("pulse.conf");
    std::fs::write(&conf, render_conf(&socket)?)
        .map_err(|e| format!("cannot write {}: {e}", conf.display()))?;
    let mut child = spawn_server(&conf)
        .map_err(|e| format!("no audio server: pipewire could not start ({e})"))?;
    let deadline = Instant::now() + START_BUDGET;
    while Instant::now() < deadline {
        if listening(&socket) {
            *server = Some(child);
            return Ok(socket);
        }
        if let Ok(Some(status)) = child.try_wait() {
            return Err(format!("no audio server: pipewire exited ({status})"));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
    Err(format!(
        "no audio server: pipewire did not listen within {} s",
        START_BUDGET.as_secs()
    ))
}

type SpawnRequest = (
    PathBuf,
    std::sync::mpsc::Sender<io::Result<std::process::Child>>,
);

/// PR_SET_PDEATHSIG fires when the THREAD that forked exits, not the process.
/// A server forked from a pooled worker thread would die when the pool reaps
/// that thread, taking open windows' sound with it. So every fork happens on
/// one thread that lives as long as the tray.
fn spawn_server(conf: &Path) -> io::Result<std::process::Child> {
    static SPAWNER: std::sync::OnceLock<Mutex<std::sync::mpsc::Sender<SpawnRequest>>> =
        std::sync::OnceLock::new();
    let spawner = SPAWNER.get_or_init(|| {
        let (requests, inbox) = std::sync::mpsc::channel::<SpawnRequest>();
        std::thread::Builder::new()
            .name("tillandsias-audio-spawner".into())
            .spawn(move || {
                for (conf, reply) in inbox {
                    let _ = reply.send(spawn_on_this_thread(&conf));
                }
            })
            .expect("spawn the audio spawner thread");
        Mutex::new(requests)
    });
    let (reply, answer) = std::sync::mpsc::channel();
    spawner
        .lock()
        .map_err(|_| io::Error::other("the audio spawner lock is poisoned"))?
        .send((conf.to_path_buf(), reply))
        .map_err(|_| io::Error::other("the audio spawner thread is gone"))?;
    answer
        .recv()
        .map_err(|_| io::Error::other("the audio spawner thread is gone"))?
}

fn spawn_on_this_thread(conf: &Path) -> io::Result<std::process::Child> {
    let mut command = Command::new("pipewire");
    command
        .arg("-c")
        .arg(conf)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: prctl is async-signal-safe and touches no Rust state.
        unsafe {
            command.pre_exec(|| {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    command.spawn()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shipped configuration is the whole security boundary, so its
    /// three controls and the absence of network modules are asserted on
    /// the text the binary carries.
    #[test]
    fn shipped_conf_is_output_only_and_local() {
        let conf = render_conf(Path::new("/run/user/1000/tillandsias/audio/native")).unwrap();
        assert!(conf.contains("pulse.allow-module-loading = false"));
        assert!(conf.contains("quirks = [ block-record-stream block-source-volume ]"));
        // Every client. A bare `[ { } ]` matched nobody (a capture stalled
        // at 0 bytes instead of being refused); this is the measured form.
        assert!(
            conf.contains("{ application.process.binary = \"~.*\" }")
                && conf.contains("{ application.process.binary = null }"),
            "every client"
        );
        assert!(!conf.contains("matches = [ { } ]"));
        assert!(conf.contains(
            "{ address = \"unix:/run/user/1000/tillandsias/audio/native\" client.access = \"restricted\" }"
        ));
        assert!(!conf.contains("@SOCKET@"));
        let modules: Vec<&str> = conf
            .lines()
            .filter_map(|l| l.split("name = ").nth(1))
            .map(|rest| rest.split_whitespace().next().unwrap_or(""))
            .collect();
        assert_eq!(
            modules,
            [
                "libpipewire-module-rt",
                "libpipewire-module-protocol-native",
                "libpipewire-module-client-node",
                "libpipewire-module-adapter",
                "libpipewire-module-metadata",
                "libpipewire-module-protocol-pulse",
            ],
            "no network module (tcp, rtp, zeroconf, raop) and nothing else"
        );
    }

    /// 1769-9gna: the private server inside the browser image, the only audio
    /// server the browser talks to.
    const BROWSER_AUDIO_PA: &str = include_str!("../../../images/chromium/browser-audio.pa");
    const BROWSER_LAUNCHER: &str =
        include_str!("../../../images/chromium/chromium-framework-launch.sh");

    /// The modules a PulseAudio script loads, with their arguments.
    fn loaded_modules(pa: &str) -> Vec<(&str, &str)> {
        pa.lines()
            .filter_map(|l| l.trim().strip_prefix("load-module "))
            .map(|rest| rest.split_once(' ').unwrap_or((rest, "")))
            .collect()
    }

    /// The browser's whole audio world is one socket and one "Speakers" sink
    /// that tunnels to the output-only server: no device, network or source
    /// module, so no host name can be listed through it. The text IS the
    /// boundary here, as with `shipped_conf_is_output_only_and_local`; the
    /// live fixture test-browser-audio-generic-names.lua measures the view.
    #[test]
    fn host_audio_browser_view_is_one_generic_speakers_sink() {
        let modules = loaded_modules(BROWSER_AUDIO_PA);
        let names: Vec<&str> = modules.iter().map(|(n, _)| *n).collect();
        assert_eq!(
            names,
            ["module-native-protocol-unix", "module-tunnel-sink-new"],
            "one socket and one tunnel sink, nothing else"
        );
        assert_eq!(
            modules[1].1,
            "server=unix:@UPSTREAM@ sink_name=speakers sink_properties=device.description=Speakers"
        );
        assert!(BROWSER_AUDIO_PA.contains("set-default-sink speakers"));
        // NEGATIVE CONTROL: the check above rejects a config that also loads a
        // device module, the shape that would list a host's sound card.
        let mutant = format!("{BROWSER_AUDIO_PA}load-module module-udev-detect\n");
        assert_ne!(loaded_modules(&mutant).len(), names.len());

        // The launcher keeps clients from loading modules, and a window whose
        // private server does not start gets no server rather than the host's.
        // source-pin-ok: the launcher's flags and fallback are the contract.
        assert!(BROWSER_LAUNCHER.contains("--disallow-module-loading=yes"));
        assert!(BROWSER_LAUNCHER.contains("unset PULSE_SERVER"));
    }

    #[test]
    fn a_socket_path_too_long_for_sun_path_is_refused_by_name() {
        let long = PathBuf::from(format!("/{}/native", "r".repeat(110)));
        let err = render_conf(&long).unwrap_err();
        assert!(err.contains("at most 107"), "{err}");
        assert!(render_conf(&socket_path(Path::new("/run/user/1000"))).is_ok());
    }
}
