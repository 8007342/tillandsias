//! vz-spike — minimal Virtualization.framework smoke test.
//!
//! Runs only on macOS. Drives the public `tillandsias_vm_layer::vz::boot`
//! API end-to-end: build a `VZVirtualMachineConfiguration`, validate it,
//! optionally create a `VZVirtualMachine` and start it (`--boot`). Used to
//! confirm the bindings work + the entitlement story is wired before the
//! same building blocks flow into `VzRuntime::start`.
//!
//! Usage:
//!
//!     cargo run -p tillandsias-vm-layer --example vz-spike --
//!         [--disk /path/to/rootfs.img]
//!         [--nvram /path/to/nvram.bin]
//!         [--boot]
//!         [--cid N]
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
    use std::time::{Duration, Instant};

    use objc2::ClassType;
    use objc2_foundation::NSError;
    use objc2_virtualization::VZVirtualMachine;

    use tillandsias_vm_layer::vz::boot::{
        build_vm_configuration, pump_cf_loop_for, VzBootConfig,
    };

    struct Args {
        disk: Option<PathBuf>,
        nvram: Option<PathBuf>,
        boot: bool,
        vsock_cid: u32,
    }

    fn parse_args() -> Args {
        let mut args = Args {
            disk: None,
            nvram: None,
            boot: false,
            vsock_cid: 42,
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
                "-h" | "--help" => {
                    println!(
                        "usage: vz-spike [--disk <rootfs.img>] [--nvram <nvram.bin>] [--boot] [--cid N]"
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
        // EFI bootloader requires a persistent variable store. Default to
        // target/vz-spike-nvram.bin so `cargo run --example vz-spike` reaches
        // validate() without operator setup.
        if args.nvram.is_none() {
            args.nvram = Some(PathBuf::from("target/vz-spike-nvram.bin"));
        }
        println!(
            "[vz-spike] start: disk={:?} nvram={:?} boot={} cid={}",
            args.disk, args.nvram, args.boot, args.vsock_cid
        );

        // Translate spike args → library spec.
        let spec = VzBootConfig {
            cpu_count: 2,
            memory_bytes: 2 * 1024 * 1024 * 1024,
            root_disk: args.disk.clone(),
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
                if !args.boot {
                    std::process::exit(1);
                }
            }
        }

        if !args.boot {
            println!("[vz-spike] validate-only mode — pass --boot to start the VM");
            return;
        }

        let alloc = VZVirtualMachine::alloc();
        let vm = unsafe { VZVirtualMachine::initWithConfiguration(alloc, &cfg) };
        boot_and_observe(&vm);
    }

    fn boot_and_observe(vm: &VZVirtualMachine) {
        use block2::RcBlock;

        let started_at = Instant::now();
        let handler = RcBlock::new(move |err: *mut NSError| {
            if err.is_null() {
                println!(
                    "[vz-spike] start completion: ok ({} ms)",
                    started_at.elapsed().as_millis()
                );
            } else {
                let desc = unsafe { (*err).localizedDescription() }.to_string();
                println!("[vz-spike] start completion: ERR {desc}");
            }
        });
        unsafe {
            vm.startWithCompletionHandler(&handler);
        }
        println!("[vz-spike] startWithCompletionHandler dispatched; pumping CFRunLoop 10s");
        pump_cf_loop_for(Duration::from_secs(10));

        println!("[vz-spike] requesting stop");
        match unsafe { vm.requestStopWithError() } {
            Ok(()) => println!("[vz-spike] requestStop dispatched"),
            Err(e) => println!(
                "[vz-spike] requestStop failed: {}",
                e.localizedDescription()
            ),
        }
        pump_cf_loop_for(Duration::from_secs(2));
        println!("[vz-spike] done");
    }
}
