---
id: appimage-packaging
title: AppImage Packaging & Runtime
category: packaging/appimage
tags: [appimage, squashfuse, fuse, desktop-integration, apprun, packaging]
upstream: https://docs.appimage.org
version_pinned: "type2"
last_verified: "2026-03-30"
authority: official
---

# AppImage Packaging & Runtime

## AppDir Structure

An AppDir is a regular directory with a defined layout. The minimum required contents:

```
MyApp.AppDir/
  AppRun                  # Entry point (executable, script, or symlink)
  myapp.desktop           # Desktop entry (must be in root)
  myapp.png               # App icon (256x256 recommended)
  .DirIcon                # PNG icon for thumbnailers (optional)
  usr/
    bin/myapp             # Application binary
    lib/                  # Bundled shared libraries
    share/
      applications/       # .desktop file copy
      icons/              # Icon theme hierarchy
```

`AppRun` is executed by the runtime after mounting. It typically sets `LD_LIBRARY_PATH`,
`XDG_DATA_DIRS`, and then execs the real binary. Tools like `linuxdeploy` generate it
automatically, but a hand-written shell script works fine.

## Type 1 vs Type 2

| Aspect | Type 1 (deprecated) | Type 2 (current) |
|---|---|---|
| Filesystem | ISO 9660 (zisofs) | SquashFS |
| Compression | ~45% larger | gzip/zstd, much smaller |
| Self-extract | Requires AppImageExtract (GUI) | `--appimage-extract` built in |
| Signatures | None | Embedded GPG signatures |
| Updates | Manual | AppImageUpdate (binary delta) |
| Tooling | AppImageKit (legacy) | `appimagetool` |

Type 1 is obsolete. All new packaging should target Type 2.

## Runtime Mount Mechanism

A Type 2 AppImage is a single ELF file: a small **runtime** binary prepended to a SquashFS
image. On execution:

1. Runtime reads the ELF header to find the SquashFS offset.
2. Looks for `squashfuse` on `$PATH`; if absent, extracts a bundled static binary to
   `$XDG_RUNTIME_DIR`.
3. Mounts the SquashFS via FUSE at `/tmp/.mount_<AppName><XXXXXX>`.
4. Executes `AppRun` inside the mountpoint.
5. On exit, unmounts the FUSE filesystem and cleans up the temp directory.

The mount directory is visible in `/tmp/.mount_*` while the app runs. File descriptors
inherited from the FUSE mount remain valid for the lifetime of the process.

## APPIMAGE_EXTRACT_AND_RUN

When FUSE is unavailable, skip mounting entirely:

```bash
# Via environment variable
APPIMAGE_EXTRACT_AND_RUN=1 ./MyApp.AppImage

# Via flag
./MyApp.AppImage --appimage-extract-and-run
```

This extracts the SquashFS to a temp directory, runs the app, then cleans up on exit.
Slower startup (full extraction), but requires zero kernel support.

Other useful flags:

```bash
./MyApp.AppImage --appimage-extract      # Extract to ./squashfs-root/
./MyApp.AppImage --appimage-mount        # Mount and print path, wait for Ctrl+C
./MyApp.AppImage --appimage-offset       # Print SquashFS byte offset
```

## Runtime Environment Variables

Set **by the runtime** before `AppRun` executes:

| Variable | Value |
|---|---|
| `$APPIMAGE` | Absolute path to the `.AppImage` file (symlinks resolved) |
| `$APPDIR` | Path to the FUSE mountpoint (`/tmp/.mount_*`) |
| `$OWD` | Original working directory at invocation time |
| `$ARGV0` | Name/path used to invoke the AppImage (preserves symlink name) |

Use `$APPIMAGE` when you need the real file (updates, self-inspection). Use `$ARGV0` for
user-facing paths or multi-call binary dispatch via symlink names.

## appimagetool

Builds a Type 2 AppImage from an AppDir:

```bash
# Basic usage
appimagetool MyApp.AppDir MyApp.AppImage

# With update information for delta updates
appimagetool -u "gh-releases-zsync|user|repo|latest|*.AppImage.zsync" MyApp.AppDir

# Override architecture detection
ARCH=x86_64 appimagetool MyApp.AppDir
```

Key env vars for `appimagetool`:

- `ARCH` -- override binary architecture detection
- `APPIMAGETOOL_APP_NAME` -- explicit app name in output filename
- `VERSION` -- inserted into desktop file and output filename

## Desktop Integration

The `.desktop` file in the AppDir root must follow the freedesktop spec. Minimal example:

```ini
[Desktop Entry]
Type=Application
Name=MyApp
Exec=myapp
Icon=myapp
Categories=Development;
```

Rules:
- `Exec=` must be the binary name only (no path) -- the runtime handles resolution.
- `Icon=` must match the root icon filename (without extension).
- One `.desktop` file in the AppDir root; copies under `usr/share/applications/` are fine.
- Icon files should exist at `usr/share/icons/hicolor/<size>/apps/<name>.png`.

Optional daemon-based desktop integration (`appimaged`, `AppImageLauncher`) watches for
AppImages and registers them with the system menu. Not required for basic operation.

## Troubleshooting FUSE on Immutable OS

Immutable distributions (Fedora Silverblue/Kinoite, VanillaOS, NixOS) often lack FUSE 2
or restrict `/usr` modifications.

**Check FUSE availability:**

```bash
ls -l /dev/fuse              # Kernel support present?
which fusermount              # FUSE 2 userspace tool
which fusermount3             # FUSE 3 userspace tool
```

**Common fixes:**

| Problem | Solution |
|---|---|
| No `/dev/fuse` | Load kernel module: `sudo modprobe fuse` |
| Only `fusermount3`, no `fusermount` | `sudo ln -s /usr/bin/fusermount3 /usr/local/bin/fusermount` |
| Immutable `/usr`, cannot install fuse2 | Use `APPIMAGE_EXTRACT_AND_RUN=1` |
| Silverblue/Atomic: fuse2 unavailable | `rpm-ostree install fuse2-libs fuse` then reboot, or use extract-and-run |
| NixOS: no FHS paths | Use `appimage-run` wrapper from nixpkgs, or extract-and-run |
| Flatpak sandbox blocks FUSE | AppImages cannot run inside Flatpak; run on the host |

**Permanent extract-and-run** (no FUSE needed):

```bash
# In ~/.bashrc or equivalent
export APPIMAGE_EXTRACT_AND_RUN=1
```

This is the simplest universal workaround for any system where FUSE setup is impractical.

## macOS / Gatekeeper

Not applicable. AppImage is a Linux-only format. macOS uses `.app` bundles, `.dmg`
disk images, or Homebrew casks. There is no AppImage runtime for macOS or Windows.
