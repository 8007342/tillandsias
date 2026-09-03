# Forensics: first-ever launch of a sub-10-GiB macOS host (macneo), captured before reset

- Date: 2026-09-03 (UTC); operator-local 2026-09-02 PDT (UTC-7)
- Host: macneo-macos — NEW HARDWARE TIER, first host in the fleet below 10 GiB RAM
- Class: forensic capture (perishable state), filed ahead of order 978-juw4
- Captured by: macneo-macos, at the instruction of macuahuitl-fedora
- Related: order 978-juw4 (guest sizing below the reserve/floor crossover)

## Why this file exists

This is the first-ever launch of Tillandsias on a factory-fresh Mac with 8 GiB
of RAM. That state cannot be re-entered once the VM directory is reset, so it is
copied here VERBATIM rather than described. Everything below is command output
captured on the host, not prose about it.

The sharpest single fact in this record: **`rootfs.img` was last written at
23:12 local, eleven minutes AFTER the last `console.log` write at 23:01**, and
at capture time no VM process exists and the tray holds no `rootfs.img` file
descriptor — while the tray UI still displayed "building forge".

## Install provenance

- Install method: `curl` install of a PUBLISHED release (no local build).
- Release under test: **56.9.2.1** (`CFBundleVersion`, confirmed by `--diagnose`).
- Bundle: `/Applications/Tillandsias.app`, ad-hoc signed, `LSUIElement=true`,
  `LSMinimumSystemVersion=14.0`.
- Entitlements: `com.apple.security.get-task-allow`, `com.apple.security.virtualization`.
- Bundle payload: `MacOS/tillandsias-tray` plus ONLY two guest binaries,
  `Resources/guest/tillandsias-headless-{aarch64,x86_64}-unknown-linux-musl`.
  Both are musl-linked. This matters for the GLIBC observation below.
- NO `tillandsias` / `tillandsias-tray` binary on `PATH`; NO Rust toolchain on
  the host (`cargo` and `rustc` both absent).
- Operator installed `qemu` (11.1.1), then later `gh` (2.99.0) + `git` (2.55.0)
  via Homebrew DURING debugging. Those were not present at first launch.

## Operator-reported sequence (verbatim intent)

1. curl install downloaded and launched fine; failed immediately claiming qemu was missing.
2. `brew install qemu` -> relaunch -> **failed at the same spot**.
3. `tillandsias-tray --provision` from the command line -> **succeeded**.
4. Relaunch -> claimed success, but GitHub Login failed with a GLIBC error.
5. Terminated tray, relaunched -> GitHub Login succeeded. (`brew install gh git` happened in between.)
6. Forge launch ran long, printed a source checkout, then went silent. Tray still
   says "building forge" with no disk, network, or CPU activity.

## Host identity

```
$ sysctl -n hw.model machdep.cpu.brand_string hw.ncpu hw.physicalcpu hw.memsize
Mac17,5
Apple A18 Pro
6
6
8589934592
$ sw_vers
ProductName:		macOS
ProductVersion:		26.6
BuildVersion:		25G72
$ uname -m
arm64
```

## VM directory, with timestamps (THE TIMELINE)

Apparent vs real size matters: `rootfs.img` is a 250 GiB SPARSE file occupying 11 GiB.

```
$ ls -la '/Users/tlatoani/Library/Application Support/Tillandsias'
total 23866720
drwxr-xr-x   8 tlatoani  staff           256 Sep  2 23:01 .
drwx------+ 32 tlatoani  staff          1024 Sep  2 22:57 ..
-rw-r--r--   1 tlatoani  staff        921600 Sep  2 23:01 cidata.iso
-rw-r--r--   1 tlatoani  staff          1236 Sep  2 23:01 console.log
-rw-r--r--   1 tlatoani  staff            89 Sep  2 23:10 crashloop.state
-rw-------   1 tlatoani  staff        131072 Sep  2 22:55 nvram.bin
-rw-r--r--   1 tlatoani  staff  268435456000 Sep  2 23:12 rootfs.img
-rw-r--r--   1 tlatoani  staff     528154624 Sep  2 22:40 rootfs.qcow2

$ du -sh '/Users/tlatoani/Library/Application Support/Tillandsias'/*
900K	/Users/tlatoani/Library/Application Support/Tillandsias/cidata.iso
4.0K	/Users/tlatoani/Library/Application Support/Tillandsias/console.log
4.0K	/Users/tlatoani/Library/Application Support/Tillandsias/crashloop.state
128K	/Users/tlatoani/Library/Application Support/Tillandsias/nvram.bin
 11G	/Users/tlatoani/Library/Application Support/Tillandsias/rootfs.img
504M	/Users/tlatoani/Library/Application Support/Tillandsias/rootfs.qcow2
```

## crashloop.state (verbatim, complete file)

```
tillandsias-crashloop-state v1
window_secs 180
threshold 3
ever_ready 1
last_phase ready
```

Reading: `ever_ready 1` and `last_phase ready` — the guest DID reach ready.
This is not a guest that never came up; it is one that came up and then went away.

## console.log (verbatim, complete file, control characters rendered via `cat -v`)

File size 1236 bytes; mtime 2026-09-02 23:01 local. Two distinct `bootid`s are
present, i.e. the guest booted TWICE. Both boots end at a login prompt and nothing
further was ever written.

```
^[[!p^[]104^[\^[[0m^[[?7h^[[1G^[[0J^[[6n^[[32766;32766H^[[6n^[[!p^[]104^[\^[[0m^[[?7h^[[1G^[[0J^[[6n^[[32766;32766H^[[6n^[]3008;start=20986ab079054cc6aee7f9bb179b6dd4;user=root;hostname=tillandsias-vm;machineid=7bbfb06f6fa54f08a060a8a99222e000;bootid=7aca355acdb54bbe8e1ffb744b09e364;pid=1121;pidfdid=1122;comm=(agetty);servicename=serial-getty@hvc0.service;invocationid=c06a9163b0e0463a830b4be60604417b;type=service^[\^[P+q6E616D65^[\^M^M
Fedora Linux 44 (Cloud Edition)^M
Kernel 6.19.10-300.fc44.aarch64 on aarch64 (hvc0)^M
^M
enp0s1: 192.168.64.2 fd30:8063:8854:ae7d:7416:8bff:fe8f:c406^M
Try contacting this VM's SSH server via 'ssh vsock%3' from host.^M
^M
tillandsias-vm login: ^[[!p^[]104^[\^[[0m^[[?7h^[[1G^[[0J^[[6n^[[32766;32766H^[[6n^[[!p^[]104^[\^[[0m^[[?7h^[[1G^[[0J^[[6n^[[32766;32766H^[[6n^[]3008;start=40d0a9b940204cd2906fbb482558f686;user=root;hostname=tillandsias-vm;machineid=7bbfb06f6fa54f08a060a8a99222e000;bootid=d4c19f7c9b57486ca6f62bd7ce4628f1;pid=1051;pidfdid=1052;comm=(agetty);servicename=serial-getty@hvc0.service;invocationid=8dc63e329e8b4629878e4502e8a2d742;type=service^[\^[P+q6E616D65^[\^M^M
Fedora Linux 44 (Cloud Edition)^M
Kernel 6.19.10-300.fc44.aarch64 on aarch64 (hvc0)^M
^M
enp0s1: 192.168.64.3 fd30:8063:8854:ae7d:3cdf:a8ff:fe09:f1e8^M
tillandsias-vm login: ```

## Proof the VM is DEAD, not idle

macOS Virtualization.framework runs the VM IN-PROCESS: there is no separate
helper process, and the VM's disk is held as an open file descriptor by the
owning process. So two facts together are conclusive:
  (a) no VM/hypervisor process exists, and
  (b) the tray process holds NO `rootfs.img` descriptor.

```
$ ps aux | grep -iE "tilland|qemu|vfkit|krun|podman|vz" | grep -v grep
tlatoani          6994   0.0  0.1 435311648   5376 s002  S+   11:06PM   0:00.02 /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --attach-pty /dev/ttys001 --session-sock /var/folders/nn/sggcw18s4kd_zxsb10d1w44m0000gn/T/tillandsias-pty-6708-1.sock
tlatoani          6708   0.0  0.2 435797984  18608   ??  S    11:01PM   1:00.84 /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray
tlatoani          1374   0.0  0.1 435334576  10992   ??  Ss   10:35PM   0:00.06 /System/Applications/Messages.app/Contents/Extensions/MessagesActionExtension.appex/Contents/MacOS/MessagesActionExtension -LaunchArguments eyJzZXJ2aWNlTmFtZSI6ImNvbS5hcHBsZS5Nb2JpbGVTTVMuTWVzc2FnZXNBY3Rpb25FeHRlbnNpb24iLCJlbmhhbmNlZFNlY3VyaXR5IjpmYWxzZSwidHlwZSI6MX0=
tlatoani          1245   0.0  0.2 435360672  13408   ??  Ss   10:34PM   0:00.09 /System/Library/CoreServices/Batteries.app/Contents/PlugIns/BatteriesAvocadoWidgetExtension.appex/Contents/MacOS/BatteriesAvocadoWidgetExtension -LaunchArguments eyJ0eXBlIjoxLCJlbmhhbmNlZFNlY3VyaXR5IjpmYWxzZSwic2VydmljZU5hbWUiOiJjb20uYXBwbGUuQmF0dGVyaWVzLkJhdHRlcmllc0F2b2NhZG9XaWRnZXRFeHRlbnNpb24ifQ==
```

Tray open descriptors (filtered to non-library entries). Note `console.log` at
fd 10w and the pty session socket at fd 17u are still held, and note the ABSENCE
of any `rootfs.img` entry:

```
$ lsof -p 6708
COMMAND    PID     USER   FD     TYPE             DEVICE  SIZE/OFF                NODE NAME
tillandsi 6708 tlatoani  cwd      DIR               1,14       704                   2 /
tillandsi 6708 tlatoani  txt      REG               1,14   4016064              394565 /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray
tillandsi 6708 tlatoani  txt      REG               1,14     72984              292573 /Library/Preferences/Logging/.plist-cache.x2Rdqn6R
tillandsi 6708 tlatoani  txt      REG               1,14   2562000 1152921500312573253 /usr/lib/dyld
tillandsi 6708 tlatoani  txt      REG               1,14    139252               19912 /System/Library/Caches/com.apple.IntlDataCache.le.kbdx
tillandsi 6708 tlatoani  txt      REG               1,14  25130384 1152921500312129962 /System/Library/Extensions/AGXMetalG17P.bundle/Contents/MacOS/AGXMetalG17P
tillandsi 6708 tlatoani  txt      REG               1,14  32307000 1152921500312129967 /System/Library/Extensions/AGXMetalG17P.bundle/Contents/Resources/ds.g17p
tillandsi 6708 tlatoani    0r     CHR                3,2       0t0                 342 /dev/null
tillandsi 6708 tlatoani    1u     CHR                3,2       0t0                 342 /dev/null
tillandsi 6708 tlatoani    2u     CHR                3,2    0t2480                 342 /dev/null
tillandsi 6708 tlatoani    3u     REG               1,14         4              394613 /Users/tlatoani/Library/Caches/tillandsias/tillandsias-macos-tray.lock
tillandsi 6708 tlatoani    4u  KQUEUE                                                  count=0, state=0xa
tillandsi 6708 tlatoani    5u  KQUEUE                                                  count=0, state=0xa
tillandsi 6708 tlatoani    6u  KQUEUE                                                  count=0, state=0xa
tillandsi 6708 tlatoani    7u    unix 0xcb4801ed5d2681d9       0t0                     ->0xa96268b8fb46eb86
tillandsi 6708 tlatoani    8u    unix 0xa96268b8fb46eb86       0t0                     ->0xcb4801ed5d2681d9
tillandsi 6708 tlatoani    9u    unix 0xcb4801ed5d2681d9       0t0                     ->0xa96268b8fb46eb86
tillandsi 6708 tlatoani   10w     REG               1,14      1236              609190 /Users/tlatoani/Library/Application Support/tillandsias/console.log
tillandsi 6708 tlatoani   11r     CHR                3,2       0t0                 342 /dev/null
tillandsi 6708 tlatoani   12u    unix 0x4683c39191b76350       0t0                     ->0x6b1885b121eeb3ea
tillandsi 6708 tlatoani   13u    unix 0x367c37d7d32f870e       0t0                     ->0x254272f15100db59
tillandsi 6708 tlatoani   14u     CHR               15,1   0t23479                 611 /dev/ptmx
tillandsi 6708 tlatoani   15u    unix 0x26f64c56f81d6fe4       0t0                     ->0xa384b67959cfdba6
tillandsi 6708 tlatoani   16u    unix 0x8baf7c20f62ad930       0t0                     ->0xf20e93da58d926fd
tillandsi 6708 tlatoani   17u    unix 0xb4404dedb9bd714e       0t0                     /var/folders/nn/sggcw18s4kd_zxsb10d1w44m0000gn/T/tillandsias-pty-6708-1.sock
```

```
$ lsof -p 6708 | grep -c rootfs.img
0
(zero: the guest disk is not open by anything)
```

Tray thread state — five threads, all sleeping, no CPU:

```
$ ps -M -p 6708
USER       PID   TT   %CPU STAT PRI     STIME     UTIME COMMAND
tlatoani  6708   ??    0.0 S    46T   0:00.32   0:00.77 /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray
          6708         0.0 S    46T   0:00.09   0:00.06 
          6708         0.0 S    31T   0:00.02   0:00.01 
          6708         0.0 S    31T   0:00.03   0:00.29 
          6708         0.0 S    31T   0:00.00   0:00.00 
```

## Memory and swap AT CAPTURE TIME (with the VM already dead)

```
$ vm_stat
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                    15344.
Pages active:                                  87485.
Pages inactive:                                79009.
Pages speculative:                              8626.
Pages throttled:                                   0.
Pages wired down:                              84856.
Pages purgeable:                                 993.
"Translation faults":                       36814754.
Pages copy-on-write:                          991367.
Pages zero filled:                          20829647.
Pages reactivated:                           6362223.
Pages purged:                                1239707.
File-backed pages:                             72715.
Anonymous pages:                              102405.
Pages stored in compressor:                   455534.
Pages occupied by compressor:                 219415.
Decompressions:                              4532451.
Compressions:                                6217492.
Pageins:                                     4171707.
Pageouts:                                     129049.
Swapins:                                       22907.
Swapouts:                                      85936.
$ sysctl vm.swapusage
vm.swapusage: total = 2048.00M  used = 982.69M  free = 1065.31M  (encrypted)
$ memory_pressure -Q
The system has 8589934592 (524288 pages with a page size of 16384).
System-wide memory free percentage: 38%
```

## Model cache — preload COMPLETED before the death

Both manifests are fully materialised and the blob sizes match the manifests
byte-for-byte, so the model preload SUCCEEDED at 23:11. Whatever failed came
after this point, during the forge build.

```
$ ls -la ~/Library/Caches/tillandsias/models/blobs
total 1312792
drwxr-xr-x  11 tlatoani  staff        352 Sep  2 23:11 .
drwxr-xr-x   6 tlatoani  staff        192 Sep  2 23:11 ..
-rw-r--r--   1 tlatoani  staff        490 Sep  2 23:11 sha256-005f95c7475154a17e84b85cd497949d6dd2a4f9d77c096e3c66e4d9c32acaf5
-rw-r--r--   1 tlatoani  staff        420 Sep  2 23:11 sha256-31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f
-rw-r--r--   1 tlatoani  staff         68 Sep  2 23:11 sha256-66b9ea09bd5b7099cbb4fc820f31b575c0366fa439b08245566692c6784e281e
-rw-r--r--   1 tlatoani  staff      11343 Sep  2 23:11 sha256-832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e
-rw-r--r--   1 tlatoani  staff  274290656 Sep  2 23:11 sha256-970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6
-rw-r--r--   1 tlatoani  staff  397807936 Sep  2 23:11 sha256-c5396e06af294bd101b30dce59131a76d2b773e76950acc870eda801d3ab0515
-rw-r--r--   1 tlatoani  staff      11357 Sep  2 23:11 sha256-c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
-rw-r--r--   1 tlatoani  staff         17 Sep  2 23:11 sha256-ce4a164fc04605703b485251fe9f1a181688ba0eb6badb80cc6335c0de17ca0d
-rw-r--r--   1 tlatoani  staff       1482 Sep  2 23:11 sha256-eb4402837c7829a690fa845de4d7f3fd842c2adee476d5341da8a46ea9255175
$ cat ~/Library/Caches/tillandsias/models/.preloaded
qwen2.5:0.5b
```

## --diagnose reports HEALTHY during the outage

Captured while the forge was wedged and the VM was dead. Exit code 0.
macOS `--diagnose` structurally cannot observe live VM phase (Apple vsock is
per-VM-handle; there is no `AF_VSOCK`), so it reports static state only:

```
Tillandsias.app diagnostic report
================================

Version:    56.9.2.1
Bundle:     inside Tillandsias.app (codesigned ad-hoc at build)
Exe:        /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray
Image-root: /Users/tlatoani/Library/Application Support/tillandsias
  rootfs.img      present, 268435456000 bytes
  vmlinuz         MISSING
  initramfs.img   MISSING
Release:    fedora-44
Manifest:   bundled at build (compile-time include_str!)
  aarch64.qcow2 SHA-256 pin: 55c60a3b80d3…

Control wire status:
  (live VM phase + podman_ready are only reachable from
   the running tray process itself — macOS vsock is per-
   VM-handle, no AF_VSOCK. Click the menubar icon for
   the live chip; the 30 s poller refreshes it in place.)

Guest health: healthy

Guest binary:
  in sync — staged copy matches this bundle (38c609c9b45f…)

Status: PROVISIONED — first-launch materialization complete.
exit: 0
```

## Host binary availability under a LaunchServices-minimal PATH

A `.app` started from Finder/LaunchServices does not inherit the shell PATH.
Simulated with `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin`:

```
xz         NOT-FOUND
hdiutil    /usr/bin/hdiutil
qemu-img   NOT-FOUND
sysctl     /usr/sbin/sysctl
curl       /usr/bin/curl
git        /usr/bin/git

# and where they really are on this host:
xz         /opt/homebrew/bin/xz
hdiutil    /usr/bin/hdiutil
qemu-img   /opt/homebrew/bin/qemu-img
jq         /usr/bin/jq
```

`/usr/bin/xz` DOES NOT EXIST on macOS 26.6. The `xz` present here arrived as a
Homebrew dependency of qemu — so the operator's `brew install qemu` incidentally
masked a SECOND bare-PATH defect at `vz.rs:1194` before it could be observed.

## Homebrew packages present at capture (installed by the operator mid-debug)

```
ca-certificates 2026-08-13
capstone 5.0.9
dtc 1.8.1
gettext 1.0
gh 2.99.0
git 2.55.0
glib 2.88.3
gmp 6.3.0
gnutls 3.8.13_2
jpeg-turbo 3.2.0
json-c 0.19
libidn2 2.3.8
libpng 1.6.58
libslirp 4.9.4
libssh 0.12.2
libtasn1 4.21.0
libunistring 1.4.2
libusb 1.0.30
libyaml 0.2.5
lz4 1.10.0
lzo 2.10
ncurses 6.6
nettle 4.0
openssl@3 3.6.4
p11-kit 0.26.5
pcre2 10.48
pixman 0.46.4
qemu 11.1.1
snappy 1.2.2
vde 2.3.3
xz 5.8.3
zstd 1.5.7_1
```
