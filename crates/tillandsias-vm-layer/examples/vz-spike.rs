//! vz-spike — minimal Virtualization.framework smoke test.
//!
//! Runs only on macOS. Builds a `VZVirtualMachineConfiguration` with the
//! same device set the real `VzRuntime::start` will use, calls `validate()`,
//! optionally creates a `VZVirtualMachine` and starts it (`--boot`). Used to
//! confirm the `objc2-virtualization` API surface compiles + works
//! end-to-end before refactoring `VzRuntime`.
//!
//! Usage:
//!
//!     cargo run -p tillandsias-vm-layer --example vz-spike
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
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    use objc2::ClassType;
    use objc2::rc::Retained;
    use objc2_foundation::{NSArray, NSError, NSString, NSURL};
    use objc2_virtualization::{
        VZBootLoader, VZDiskImageStorageDeviceAttachment, VZEFIBootLoader, VZEFIVariableStore,
        VZEFIVariableStoreInitializationOptions, VZEntropyDeviceConfiguration,
        VZGenericPlatformConfiguration, VZMemoryBalloonDeviceConfiguration,
        VZNATNetworkDeviceAttachment, VZNetworkDeviceConfiguration, VZPlatformConfiguration,
        VZSerialPortConfiguration, VZSocketDeviceConfiguration, VZStorageDeviceConfiguration,
        VZVirtioBlockDeviceConfiguration, VZVirtioConsoleDeviceSerialPortConfiguration,
        VZVirtioEntropyDeviceConfiguration, VZVirtioNetworkDeviceConfiguration,
        VZVirtioSocketDeviceConfiguration, VZVirtioTraditionalMemoryBalloonDeviceConfiguration,
        VZVirtualMachine, VZVirtualMachineConfiguration,
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
        // EFI bootloader requires a persistent variable store. If the user
        // didn't pass --nvram, drop one at target/vz-spike-nvram.bin so the
        // default smoke test (`cargo run --example vz-spike`) reaches and
        // passes validate() up to the next missing-device blocker.
        if args.nvram.is_none() {
            let default = PathBuf::from("target/vz-spike-nvram.bin");
            args.nvram = Some(default);
        }
        println!(
            "[vz-spike] start: disk={:?} nvram={:?} boot={} cid={}",
            args.disk, args.nvram, args.boot, args.vsock_cid
        );

        let cfg = match build_config(&args) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[vz-spike] config build error: {e}");
                std::process::exit(1);
            }
        };

        match unsafe { cfg.validateWithError() } {
            Ok(()) => println!("[vz-spike] validate(): OK"),
            Err(e) => {
                println!(
                    "[vz-spike] validate(): FAIL — {}",
                    e.localizedDescription()
                );
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

    fn build_config(args: &Args) -> Result<Retained<VZVirtualMachineConfiguration>, String> {
        unsafe {
            let cfg = VZVirtualMachineConfiguration::new();

            cfg.setCPUCount(2);
            cfg.setMemorySize(2 * 1024 * 1024 * 1024); // 2 GiB

            // ── Platform: generic (no Mac-host requirements)
            let platform = VZGenericPlatformConfiguration::new();
            let plat_super: &VZPlatformConfiguration = &*platform;
            cfg.setPlatform(plat_super);

            // ── EFI bootloader; optional persistent NVRAM
            let efi = VZEFIBootLoader::new();
            if let Some(path) = &args.nvram {
                let url = ns_url_for(path);
                let alloc = VZEFIVariableStore::alloc();
                let store = if path.exists() {
                    VZEFIVariableStore::initWithURL(alloc, &url)
                } else {
                    VZEFIVariableStore::initCreatingVariableStoreAtURL_options_error(
                        alloc,
                        &url,
                        VZEFIVariableStoreInitializationOptions::VZEFIVariableStoreInitializationOptionAllowOverwrite,
                    )
                    .map_err(|e| format!("create nvram: {}", e.localizedDescription()))?
                };
                efi.setVariableStore(Some(&store));
            }
            let efi_super: &VZBootLoader = &*efi;
            cfg.setBootLoader(Some(efi_super));

            // ── Storage: virtio-blk root disk (optional for validate-only)
            if let Some(path) = &args.disk {
                let url = ns_url_for(path);
                let att = VZDiskImageStorageDeviceAttachment::initWithURL_readOnly_error(
                    VZDiskImageStorageDeviceAttachment::alloc(),
                    &url,
                    false,
                )
                .map_err(|e| format!("disk attach: {}", e.localizedDescription()))?;
                let blk_alloc = VZVirtioBlockDeviceConfiguration::alloc();
                // The bindings expose `initWithAttachment(&VZStorageDeviceAttachment)`;
                // VZDiskImageStorageDeviceAttachment is a subclass so we upcast via deref.
                let blk = VZVirtioBlockDeviceConfiguration::initWithAttachment(blk_alloc, &att);
                let arr: Retained<NSArray<VZStorageDeviceConfiguration>> =
                    NSArray::from_id_slice(&[Retained::cast(blk)]);
                cfg.setStorageDevices(&arr);
            }

            // ── Network: virtio-net + NAT
            let nat = VZNATNetworkDeviceAttachment::new();
            let nat_super: &objc2_virtualization::VZNetworkDeviceAttachment = &nat;
            let nic = VZVirtioNetworkDeviceConfiguration::new();
            nic.setAttachment(Some(nat_super));
            let nic_super: Retained<VZNetworkDeviceConfiguration> = Retained::into_super(nic);
            let arr_n: Retained<NSArray<VZNetworkDeviceConfiguration>> =
                NSArray::from_id_slice(&[nic_super]);
            cfg.setNetworkDevices(&arr_n);

            // ── Serial console: guest writes → stderr; reads from /dev/null
            let null_fh = open_read_only(b"/dev/null\0")
                .ok_or_else(|| "open(/dev/null) failed".to_string())?;
            let stderr_dup = dup_fd(2).ok_or_else(|| "dup(stderr) failed".to_string())?;
            let read_fh = objc2_foundation::NSFileHandle::initWithFileDescriptor_closeOnDealloc(
                objc2_foundation::NSFileHandle::alloc(),
                null_fh,
                true,
            );
            let write_fh = objc2_foundation::NSFileHandle::initWithFileDescriptor_closeOnDealloc(
                objc2_foundation::NSFileHandle::alloc(),
                stderr_dup,
                true,
            );
            use objc2_virtualization::VZFileHandleSerialPortAttachment;
            let serial_att =
                VZFileHandleSerialPortAttachment::initWithFileHandleForReading_fileHandleForWriting(
                    VZFileHandleSerialPortAttachment::alloc(),
                    Some(&read_fh),
                    Some(&write_fh),
                );
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration::new();
            // setAttachment(&VZSerialPortAttachment) — upcast via deref
            use objc2_virtualization::VZSerialPortAttachment;
            let att_super: &VZSerialPortAttachment = &*serial_att;
            serial.setAttachment(Some(att_super));
            let arr_s: Retained<NSArray<VZSerialPortConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(serial)]);
            cfg.setSerialPorts(&arr_s);

            // ── Entropy + balloon
            let entropy = VZVirtioEntropyDeviceConfiguration::new();
            let arr_e: Retained<NSArray<VZEntropyDeviceConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(entropy)]);
            cfg.setEntropyDevices(&arr_e);

            let balloon = VZVirtioTraditionalMemoryBalloonDeviceConfiguration::new();
            let arr_b: Retained<NSArray<VZMemoryBalloonDeviceConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(balloon)]);
            cfg.setMemoryBalloonDevices(&arr_b);

            // ── Vsock: virtio-vsock device (guest binds, host connects)
            let sock = VZVirtioSocketDeviceConfiguration::new();
            let arr_sd: Retained<NSArray<VZSocketDeviceConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(sock)]);
            cfg.setSocketDevices(&arr_sd);

            Ok(cfg)
        }
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

        // VZ delivers its completion handler on the dispatch queue we
        // submitted the start from. With nothing pumping the main thread's
        // CFRunLoop the callback never fires and the VM stays in "starting".
        // Pump for 10 s, then attempt a graceful stop.
        run_cf_loop_for(Duration::from_secs(10));

        println!("[vz-spike] requesting stop");
        match unsafe { vm.requestStopWithError() } {
            Ok(()) => println!("[vz-spike] requestStop dispatched"),
            Err(e) => println!(
                "[vz-spike] requestStop failed: {}",
                e.localizedDescription()
            ),
        }
        run_cf_loop_for(Duration::from_secs(2));
        println!("[vz-spike] done");
    }

    /// Pump CoreFoundation's main runloop for `dur`, letting VZ completion
    /// handlers dispatched to the main queue fire. Returns when the time
    /// elapses (whether or not any sources fired).
    fn run_cf_loop_for(dur: Duration) {
        #[link(name = "CoreFoundation", kind = "framework")]
        unsafe extern "C" {
            fn CFRunLoopRunInMode(
                mode: *const std::ffi::c_void,
                seconds: f64,
                return_after_source_handled: u8,
            ) -> i32;
            static kCFRunLoopDefaultMode: *const std::ffi::c_void;
        }
        let deadline = Instant::now() + dur;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now()).as_secs_f64();
            if remaining <= 0.0 {
                break;
            }
            let rc = unsafe {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining.min(1.0), 0)
            };
            // rc: 1=Finished (no sources), 2=Stopped, 3=TimedOut, 4=HandledSource
            // We treat all as "loop again until our wall-clock deadline".
            let _ = rc;
        }
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    fn ns_url_for(p: &Path) -> Retained<NSURL> {
        let s = NSString::from_str(p.to_string_lossy().as_ref());
        unsafe { NSURL::fileURLWithPath(&s) }
    }

    fn open_read_only(cpath: &[u8]) -> Option<std::os::raw::c_int> {
        unsafe extern "C" {
            fn open(path: *const std::os::raw::c_char, oflag: std::os::raw::c_int) -> std::os::raw::c_int;
        }
        let fd = unsafe { open(cpath.as_ptr() as _, 0 /* O_RDONLY */) };
        if fd < 0 { None } else { Some(fd) }
    }

    fn dup_fd(fd: std::os::raw::c_int) -> Option<std::os::raw::c_int> {
        unsafe extern "C" {
            fn dup(fd: std::os::raw::c_int) -> std::os::raw::c_int;
        }
        let new_fd = unsafe { dup(fd) };
        if new_fd < 0 { None } else { Some(new_fd) }
    }
}
