//! vz-spike — minimal Virtualization.framework smoke test.
//!
//! Runs only on macOS. Two modes:
//!
//! - **Validate-only** (default): builds a `VZVirtualMachineConfiguration`
//!   via `tillandsias_vm_layer::vz::boot::build_vm_configuration` and calls
//!   `validateWithError`. Verifies the bindings + the entitlement story
//!   without booting anything.
//! - **`--boot`**: drives the production code path through `VzRuntime`
//!   (`start` → `wait_ready` → observe → `stop`). The same path the macOS
//!   tray will use. Iter 8 (m2) refactor — the spike no longer hand-rolls
//!   VZ method calls.
//!
//! Usage:
//!
//!     cargo run -p tillandsias-vm-layer --example vz-spike --
//!         [--disk /path/to/rootfs.img]
//!         [--nvram /path/to/nvram.bin]
//!         [--boot]
//!         [--cid N]
//!         [--observe-secs N]   (default 5)
//!
//! @trace spec:vm-idiomatic-layer, spec:macos-native-tray, spec:vsock-transport

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("vz-spike is macOS-only — this binary is a stub on other targets.");
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
fn main() {
    macos_main::run();
}

#[cfg(target_os = "macos")]
mod macos_main {
    use std::path::PathBuf;
    use std::time::Duration;

    use tillandsias_vm_layer::VmRuntime;
    use tillandsias_vm_layer::vz::VzRuntime;
    use tillandsias_vm_layer::vz::boot::{VzBootConfig, build_vm_configuration};

    struct Args {
        disk: Option<PathBuf>,
        nvram: Option<PathBuf>,
        boot: bool,
        vsock_cid: u32,
        observe_secs: u64,
    }

    fn parse_args() -> Args {
        let mut args = Args {
            disk: None,
            nvram: None,
            boot: false,
            vsock_cid: 42,
            observe_secs: 5,
        };
        let mut it = std::env::args().skip(1);
        while let Some(a) = it.next() {
            match a.as_str() {
                "--disk" => args.disk = it.next().map(PathBuf::from),
                "--nvram" => args.nvram = it.next().map(PathBuf::from),
                "--boot" => args.boot = true,
                "--cid" => {
                    if let Some(v) = it.next() {
                        args.vsock_cid = v.parse().expect("--cid must be u32");
                    }
                }
                "--observe-secs" => {
                    if let Some(v) = it.next() {
                        args.observe_secs = v.parse().expect("--observe-secs must be u64");
                    }
                }
                "-h" | "--help" => {
                    println!(
                        "usage: vz-spike [--disk <rootfs.img>] [--nvram <nvram.bin>] \
                         [--boot] [--cid N] [--observe-secs N]"
                    );
                    std::process::exit(0);
                }
                other => {
                    eprintln!("unknown arg: {other}");
                    std::process::exit(2);
                }
            }
        }
        args
    }

    pub fn run() {
        let mut args = parse_args();
        if args.nvram.is_none() {
            args.nvram = Some(PathBuf::from("target/vz-spike-nvram.bin"));
        }
        println!(
            "[vz-spike] start: disk={:?} nvram={:?} boot={} cid={} observe_secs={}",
            args.disk, args.nvram, args.boot, args.vsock_cid, args.observe_secs
        );

        if !args.boot {
            run_validate_only(&args);
            return;
        }
        run_via_vmruntime(&args);
    }

    /// Validate-only path: bypass `VzRuntime` and call the public boot
    /// builder directly so we can inspect intermediate config state on
    /// `validate()` failures (e.g. "variableStore is nil" before NVRAM
    /// auto-create was wired). No tokio runtime, no VM handle.
    fn run_validate_only(args: &Args) {
        let spec = VzBootConfig {
            cpu_count: 2,
            memory_bytes: 2 * 1024 * 1024 * 1024,
            root_disk: args.disk.clone(),
            cidata_iso: None,
            shared_host_dir: None,
            share_tag: "home-src".to_string(),
            nvram: args.nvram.clone(),
            serial_writer_fd: None,
        };
        let cfg = match build_vm_configuration(&spec) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[vz-spike] config build error: {e}");
                std::process::exit(1);
            }
        };
        match unsafe { cfg.validateWithError() } {
            Ok(()) => println!("[vz-spike] validate(): OK"),
            Err(e) => {
                println!("[vz-spike] validate(): FAIL — {}", e.localizedDescription());
                std::process::exit(1);
            }
        }
        println!("[vz-spike] validate-only mode — pass --boot to drive VzRuntime");
    }

    /// Production path: build a `VzRuntime`, drive
    /// `start → wait_ready → (observe) → stop`. Same code the macOS tray
    /// uses. Sets up `image_root` as a tempdir with a symlink to the
    /// caller-provided rootfs so `VzRuntime` can locate it at the
    /// `<image_root>/rootfs.img` path it expects.
    fn run_via_vmruntime(args: &Args) {
        let disk = args.disk.clone().unwrap_or_else(|| {
            eprintln!("[vz-spike] --boot requires --disk <rootfs.img>");
            std::process::exit(2);
        });
        let abs_disk = disk.canonicalize().unwrap_or_else(|e| {
            eprintln!("[vz-spike] cannot canonicalize disk path {disk:?}: {e}");
            std::process::exit(1);
        });

        let image_root = match make_image_root(&abs_disk, args.nvram.as_deref()) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[vz-spike] image_root setup failed: {e}");
                std::process::exit(1);
            }
        };
        println!("[vz-spike] image_root: {}", image_root.display());

        let rt = VzRuntime::new(args.vsock_cid, image_root);
        let observe = Duration::from_secs(args.observe_secs);

        let tokio_rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio current_thread runtime");
        let exit_code = tokio_rt.block_on(async {
            use std::time::Instant;
            let t0 = Instant::now();
            if let Err(e) = rt.start().await {
                eprintln!("[vz-spike] VzRuntime::start: {e}");
                return 1;
            }
            println!(
                "[vz-spike] VzRuntime::start: ok in {} ms",
                t0.elapsed().as_millis()
            );

            let t1 = Instant::now();
            if let Err(e) = rt.wait_ready(Duration::from_secs(15)).await {
                eprintln!("[vz-spike] VzRuntime::wait_ready: {e}");
                // continue to stop so we don't leak a running VM
            } else {
                println!(
                    "[vz-spike] VzRuntime::wait_ready: ok in {} ms",
                    t1.elapsed().as_millis()
                );
            }

            println!("[vz-spike] observing serial for {} s", observe.as_secs());
            // Observe by pumping the runloop (the serial writer fd is host
            // stderr; bytes flow as the guest produces them).
            tillandsias_vm_layer::vz::boot::pump_cf_loop_for(observe);

            // Fedora 44 cloud's systemd shutdown takes ~20–30s to drain
            // through journald flush + cgroups teardown; 30s is a comfortable
            // ceiling. The production tray will pass a similar value.
            let t2 = Instant::now();
            match rt.stop(Duration::from_secs(30)).await {
                Ok(()) => println!(
                    "[vz-spike] VzRuntime::stop: ok in {} ms",
                    t2.elapsed().as_millis()
                ),
                Err(e) => eprintln!("[vz-spike] VzRuntime::stop: {e}"),
            }
            0
        });
        std::process::exit(exit_code);
    }

    /// Build a temp `image_root` containing a symlink `rootfs.img → <disk>`
    /// and (if `nvram` is provided) a symlink `nvram.bin → <nvram>`. The
    /// tempdir is leaked on purpose — `VzRuntime` reads from it for the
    /// lifetime of the process, and a real tray persists `image_root` at
    /// `~/Library/Application Support/tillandsias/vm/`.
    fn make_image_root(
        disk: &std::path::Path,
        nvram: Option<&std::path::Path>,
    ) -> std::io::Result<PathBuf> {
        let base = std::env::temp_dir().join(format!("vz-spike-{}", std::process::id()));
        std::fs::create_dir_all(&base)?;

        let rootfs_link = base.join("rootfs.img");
        let _ = std::fs::remove_file(&rootfs_link);
        std::os::unix::fs::symlink(disk, &rootfs_link)?;

        if let Some(nv) = nvram {
            let nvram_link = base.join("nvram.bin");
            let _ = std::fs::remove_file(&nvram_link);
            // Symlink may dangle if the source doesn't exist yet — that's
            // fine; VZEFIVariableStore creates the target on first boot.
            let nv_abs = nv.canonicalize().unwrap_or_else(|_| nv.to_path_buf());
            std::os::unix::fs::symlink(&nv_abs, &nvram_link)?;
        }
        Ok(base)
    }
}
