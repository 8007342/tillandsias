// @trace order:1506-q7ab, openspec/changes/fleet-messaging-poc/design.md (Decision 3)
//
// lanefs — every file operation the infrastructure performs INSIDE a lane
// directory, done relative to a directory file descriptor with O_NOFOLLOW at
// each path component.
//
// WHY. A forge holds its lane directory read-write (bind-mounted at
// /run/host/tillandsias-msg), and the mover runs on the HOST as the user. With
// plain path operations a forge could replace `outbox/new` with a symlink to
// `../b-default/inbox/new` and the mover would "refuse" another lane's mail
// into the forge's own dead/ — reading and deleting another lane's inbox — or
// replace `receipts/` with a symlink into ~/.config and have the host write
// files there. The threat table (design note §3) says a compromised forge
// cannot read another lane's inbox or reach beyond its directory; this module
// is what makes that true.
//
// THE CONTRACT. The lane directory ITSELF is trusted as a directory: it is the
// bind-mount point, which a forge cannot rename or replace, under a parent
// (`<root>/lanes/`) no forge can see. It is opened with O_NOFOLLOW. Everything
// beneath it is untrusted: each component is opened with
// O_DIRECTORY|O_NOFOLLOW relative to its parent's fd, files with O_NOFOLLOW
// and O_NONBLOCK (a FIFO cannot hang the mover) and read only when they are
// regular files of bounded size. Renames and unlinks use the *at() calls on
// the same fds, so swapping a directory for a symlink after it was opened
// changes nothing: the fd names the original inode.
//
// Non-unix builds (the CLI on a Windows host) fall back to path operations
// with symlink_metadata checks; no forge mounts a lane there.

use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How a durable write makes its bytes stable. Production passes [`fsync`];
/// the mover's tests inject a failing one to prove no ack follows a failed
/// fsync, and the `TILLANDSIAS_MSG_SKIP_FSYNC` fixture seam passes [`no_sync`].
pub type SyncFn = fn(&File) -> io::Result<()>;

/// The real one: fsync(2).
pub fn fsync(f: &File) -> io::Result<()> {
    f.sync_all()
}

/// A sync that does nothing. Only the mover's fixture seam passes it, and the
/// mover then refuses to ack (it holds no proof of durability).
pub fn no_sync(_f: &File) -> io::Result<()> {
    Ok(())
}

/// Largest file the infrastructure reads out of a lane (an envelope is capped
/// at 4096 bytes; receipts and the seen set are larger but bounded by TTL).
pub const READ_CAP: u64 = 1024 * 1024;

fn bad_name(name: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("not a single path component: {name:?}"),
    )
}

fn check_name(name: &str) -> io::Result<()> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        return Err(bad_name(name));
    }
    Ok(())
}

fn components(rel: &str) -> io::Result<Vec<&str>> {
    let v: Vec<&str> = rel.split('/').filter(|c| !c.is_empty()).collect();
    for c in &v {
        check_name(c)?;
    }
    Ok(v)
}

fn tmp_suffix() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!(
        "{}.{}.{nanos:08x}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    )
}

/// True when an error means "a symlink or a non-directory stood where a lane
/// directory component was expected" — the shape a hostile lane produces.
pub fn is_not_plain(e: &io::Error) -> bool {
    #[cfg(unix)]
    {
        matches!(e.raw_os_error(), Some(libc::ELOOP) | Some(libc::ENOTDIR))
            || e.kind() == io::ErrorKind::InvalidData
    }
    #[cfg(not(unix))]
    {
        e.kind() == io::ErrorKind::InvalidData
    }
}

#[cfg(unix)]
mod imp {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
    use std::os::unix::ffi::OsStrExt;

    const DIR_FLAGS: libc::c_int =
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;

    fn cstr(s: &[u8]) -> io::Result<CString> {
        CString::new(s).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"))
    }

    fn cvt(rc: libc::c_int) -> io::Result<libc::c_int> {
        if rc < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(rc)
        }
    }

    fn own(fd: libc::c_int) -> OwnedFd {
        // SAFETY: `fd` was just returned by a successful open/openat and is
        // owned by nobody else.
        unsafe { OwnedFd::from_raw_fd(fd) }
    }

    fn openat_dir(dirfd: RawFd, name: &str) -> io::Result<OwnedFd> {
        let c = cstr(name.as_bytes())?;
        // SAFETY: `c` is a valid NUL-terminated string for the call's duration.
        let fd = cvt(unsafe { libc::openat(dirfd, c.as_ptr(), DIR_FLAGS) })?;
        Ok(own(fd))
    }

    fn fstatat_nofollow(dirfd: RawFd, name: &str) -> io::Result<libc::stat> {
        let c = cstr(name.as_bytes())?;
        // SAFETY: zeroed is a valid bit pattern for `stat`; the pointer is valid.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        cvt(unsafe { libc::fstatat(dirfd, c.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) })?;
        Ok(st)
    }

    fn is_reg(st: &libc::stat) -> bool {
        // All three are mode_t (u32 on Linux, u16 on macOS): no casts.
        (st.st_mode & libc::S_IFMT) == libc::S_IFREG
    }

    fn sync_fd(fd: &OwnedFd, sync: SyncFn) -> io::Result<()> {
        let f = File::from(fd.try_clone()?);
        match sync(&f) {
            // Some filesystems cannot fsync a directory; the file itself was.
            Err(e) if e.raw_os_error() == Some(libc::EINVAL) => Ok(()),
            r => r,
        }
    }

    /// An open lane directory. See the module comment for the contract.
    pub struct Lane {
        root: OwnedFd,
        path: PathBuf,
    }

    impl Lane {
        /// Open an existing lane directory (the final component must not be a
        /// symlink).
        pub fn open(dir: &Path) -> io::Result<Lane> {
            let c = cstr(dir.as_os_str().as_bytes())?;
            // SAFETY: valid NUL-terminated path.
            let fd = cvt(unsafe { libc::open(c.as_ptr(), DIR_FLAGS) })?;
            Ok(Lane {
                root: own(fd),
                path: dir.to_path_buf(),
            })
        }

        /// Create the lane directory (and its host-owned parents) if needed,
        /// then open it.
        pub fn create(dir: &Path) -> io::Result<Lane> {
            if std::fs::symlink_metadata(dir).is_err() {
                std::fs::create_dir_all(dir)?;
            }
            Self::open(dir)
        }

        pub fn path(&self) -> &Path {
            &self.path
        }

        fn dir(&self, rel: &str) -> io::Result<OwnedFd> {
            let mut cur = self.root.try_clone()?;
            for c in components(rel)? {
                cur = openat_dir(cur.as_raw_fd(), c)?;
            }
            Ok(cur)
        }

        /// mkdir each missing component of each `rel`, refusing (ELOOP /
        /// ENOTDIR) any component that exists as something other than a
        /// directory.
        pub fn ensure_dirs(&self, rels: &[&str]) -> io::Result<()> {
            for rel in rels {
                let mut cur = self.root.try_clone()?;
                for c in components(rel)? {
                    let cn = cstr(c.as_bytes())?;
                    // SAFETY: valid fd and NUL-terminated name.
                    let rc = unsafe { libc::mkdirat(cur.as_raw_fd(), cn.as_ptr(), 0o700) };
                    if rc < 0 {
                        let e = io::Error::last_os_error();
                        if e.kind() != io::ErrorKind::AlreadyExists {
                            return Err(e);
                        }
                    }
                    cur = openat_dir(cur.as_raw_fd(), c)?;
                }
            }
            Ok(())
        }

        /// Regular files in `rel`, dot-names (in-flight tmp files, locks)
        /// excluded, sorted. Symlinks, FIFOs and directories are not listed.
        pub fn list(&self, rel: &str) -> io::Result<Vec<String>> {
            let d = self.dir(rel)?;
            let dup = d.try_clone()?;
            let raw = std::os::fd::IntoRawFd::into_raw_fd(dup);
            // SAFETY: `raw` is an owned directory fd; fdopendir takes it over
            // and closedir below releases it.
            let dirp = unsafe { libc::fdopendir(raw) };
            if dirp.is_null() {
                let e = io::Error::last_os_error();
                drop(own(raw));
                return Err(e);
            }
            let mut names = Vec::new();
            loop {
                // SAFETY: `dirp` is a valid DIR* until closedir.
                let ent = unsafe { libc::readdir(dirp) };
                if ent.is_null() {
                    break;
                }
                // SAFETY: d_name is NUL-terminated within the dirent.
                let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) };
                if let Ok(s) = name.to_str()
                    && !s.starts_with('.')
                {
                    names.push(s.to_string());
                }
            }
            // SAFETY: closes the DIR* and the fd it owns.
            unsafe { libc::closedir(dirp) };
            let mut files: Vec<String> = names
                .into_iter()
                .filter(|n| fstatat_nofollow(d.as_raw_fd(), n).is_ok_and(|st| is_reg(&st)))
                .collect();
            files.sort();
            Ok(files)
        }

        /// The bytes of `rel/name`: `Ok(None)` when absent; an error when it is
        /// a symlink (ELOOP), not a regular file, or larger than [`READ_CAP`].
        pub fn read(&self, rel: &str, name: &str) -> io::Result<Option<Vec<u8>>> {
            check_name(name)?;
            let d = self.dir(rel)?;
            let c = cstr(name.as_bytes())?;
            // SAFETY: valid fd and NUL-terminated name.
            let fd = unsafe {
                libc::openat(
                    d.as_raw_fd(),
                    c.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                let e = io::Error::last_os_error();
                return if e.kind() == io::ErrorKind::NotFound {
                    Ok(None)
                } else {
                    Err(e)
                };
            }
            let f = File::from(own(fd));
            if !f.metadata()?.is_file() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{name} is not a regular file"),
                ));
            }
            let mut buf = Vec::new();
            (&f).take(READ_CAP + 1).read_to_end(&mut buf)?;
            if buf.len() as u64 > READ_CAP {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{name} is larger than {READ_CAP} bytes"),
                ));
            }
            Ok(Some(buf))
        }

        /// tmp → sync → renameat → sync(dir), all fd-relative. On any failure
        /// before the rename the tmp file is removed, so a failed sync leaves
        /// nothing under `dir_rel`.
        pub fn write_durable(
            &self,
            tmp_rel: &str,
            dir_rel: &str,
            name: &str,
            bytes: &[u8],
            sync: SyncFn,
        ) -> io::Result<()> {
            check_name(name)?;
            let tmpd = self.dir(tmp_rel)?;
            let dstd = self.dir(dir_rel)?;
            let tmp_name = format!(".{name}.{}", tmp_suffix());
            let tn = cstr(tmp_name.as_bytes())?;
            // SAFETY: valid fd and NUL-terminated name; mode passed as the
            // variadic third argument.
            let fd = cvt(unsafe {
                libc::openat(
                    tmpd.as_raw_fd(),
                    tn.as_ptr(),
                    libc::O_WRONLY
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600 as libc::c_uint,
                )
            })?;
            let mut f = File::from(own(fd));
            let written = f.write_all(bytes).and_then(|_| sync(&f));
            drop(f);
            let unlink_tmp = || {
                // SAFETY: valid fd and name.
                unsafe { libc::unlinkat(tmpd.as_raw_fd(), tn.as_ptr(), 0) };
            };
            if let Err(e) = written {
                unlink_tmp();
                return Err(e);
            }
            let dn = cstr(name.as_bytes())?;
            // SAFETY: valid fds and names.
            let rc = unsafe {
                libc::renameat(tmpd.as_raw_fd(), tn.as_ptr(), dstd.as_raw_fd(), dn.as_ptr())
            };
            if rc < 0 {
                let e = io::Error::last_os_error();
                unlink_tmp();
                return Err(e);
            }
            sync_fd(&dstd, sync)
        }

        /// renameat(from_rel/from, to_rel/to); never follows a symlink (a
        /// symlink entry is moved as itself).
        pub fn rename(&self, from_rel: &str, from: &str, to_rel: &str, to: &str) -> io::Result<()> {
            check_name(from)?;
            check_name(to)?;
            let fd_from = self.dir(from_rel)?;
            let fd_to = self.dir(to_rel)?;
            let (a, b) = (cstr(from.as_bytes())?, cstr(to.as_bytes())?);
            // SAFETY: valid fds and names.
            cvt(unsafe {
                libc::renameat(
                    fd_from.as_raw_fd(),
                    a.as_ptr(),
                    fd_to.as_raw_fd(),
                    b.as_ptr(),
                )
            })?;
            let _ = sync_fd(&fd_to, fsync);
            let _ = sync_fd(&fd_from, fsync);
            Ok(())
        }

        /// unlinkat(rel/name): `Ok(false)` when it was already gone.
        pub fn remove(&self, rel: &str, name: &str) -> io::Result<bool> {
            check_name(name)?;
            let d = self.dir(rel)?;
            let c = cstr(name.as_bytes())?;
            // SAFETY: valid fd and name.
            if unsafe { libc::unlinkat(d.as_raw_fd(), c.as_ptr(), 0) } < 0 {
                let e = io::Error::last_os_error();
                return if e.kind() == io::ErrorKind::NotFound {
                    Ok(false)
                } else {
                    Err(e)
                };
            }
            Ok(true)
        }

        /// Append `bytes` to the lane-root file `name` (created 0600 if absent,
        /// never through a symlink), then sync it with `sync`.
        pub fn append(&self, name: &str, bytes: &[u8], sync: SyncFn) -> io::Result<()> {
            check_name(name)?;
            let c = cstr(name.as_bytes())?;
            // SAFETY: valid fd and name; mode as the variadic argument.
            let fd = cvt(unsafe {
                libc::openat(
                    self.root.as_raw_fd(),
                    c.as_ptr(),
                    libc::O_WRONLY
                        | libc::O_APPEND
                        | libc::O_CREAT
                        | libc::O_NOFOLLOW
                        | libc::O_NONBLOCK
                        | libc::O_CLOEXEC,
                    0o600 as libc::c_uint,
                )
            })?;
            let mut f = File::from(own(fd));
            if !f.metadata()?.is_file() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{name} is not a regular file"),
                ));
            }
            f.write_all(bytes)?;
            sync(&f)
        }

        /// Create the lane-root file `name` exclusively: `Ok(true)` created,
        /// `Ok(false)` it already existed.
        pub fn create_excl(&self, name: &str) -> io::Result<bool> {
            check_name(name)?;
            let c = cstr(name.as_bytes())?;
            // SAFETY: valid fd and name; mode as the variadic argument.
            let fd = unsafe {
                libc::openat(
                    self.root.as_raw_fd(),
                    c.as_ptr(),
                    libc::O_WRONLY
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600 as libc::c_uint,
                )
            };
            if fd < 0 {
                let e = io::Error::last_os_error();
                return if e.kind() == io::ErrorKind::AlreadyExists {
                    Ok(false)
                } else {
                    Err(e)
                };
            }
            drop(own(fd));
            Ok(true)
        }

        /// How long ago `rel/name` was last modified (not following a symlink).
        pub fn age(&self, rel: &str, name: &str) -> Option<Duration> {
            let d = self.dir(rel).ok()?;
            let st = fstatat_nofollow(d.as_raw_fd(), name).ok()?;
            let mtime = std::time::UNIX_EPOCH + Duration::from_secs(st.st_mtime.max(0) as u64);
            mtime.elapsed().ok().or(Some(Duration::ZERO))
        }

        /// fsync the lane directory itself.
        pub fn sync_root(&self, sync: SyncFn) -> io::Result<()> {
            sync_fd(&self.root, sync)
        }
    }
}

#[cfg(not(unix))]
mod imp {
    use super::*;
    use std::fs::{self, OpenOptions};
    use std::io::{Read, Write};

    fn not_plain(p: &Path) -> io::Error {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{} is not a plain directory", p.display()),
        )
    }

    /// Path-based fallback: checks every component with symlink_metadata.
    pub struct Lane {
        path: PathBuf,
    }

    impl Lane {
        pub fn open(dir: &Path) -> io::Result<Lane> {
            let m = fs::symlink_metadata(dir)?;
            if !m.is_dir() || m.file_type().is_symlink() {
                return Err(not_plain(dir));
            }
            Ok(Lane {
                path: dir.to_path_buf(),
            })
        }
        pub fn create(dir: &Path) -> io::Result<Lane> {
            if fs::symlink_metadata(dir).is_err() {
                fs::create_dir_all(dir)?;
            }
            Self::open(dir)
        }
        pub fn path(&self) -> &Path {
            &self.path
        }
        fn dir(&self, rel: &str) -> io::Result<PathBuf> {
            let mut cur = self.path.clone();
            for c in components(rel)? {
                cur.push(c);
                let m = fs::symlink_metadata(&cur)?;
                if !m.is_dir() || m.file_type().is_symlink() {
                    return Err(not_plain(&cur));
                }
            }
            Ok(cur)
        }
        pub fn ensure_dirs(&self, rels: &[&str]) -> io::Result<()> {
            for rel in rels {
                let mut cur = self.path.clone();
                for c in components(rel)? {
                    cur.push(c);
                    if fs::symlink_metadata(&cur).is_err() {
                        fs::create_dir(&cur).or_else(|e| {
                            if e.kind() == io::ErrorKind::AlreadyExists {
                                Ok(())
                            } else {
                                Err(e)
                            }
                        })?;
                    }
                    let m = fs::symlink_metadata(&cur)?;
                    if !m.is_dir() || m.file_type().is_symlink() {
                        return Err(not_plain(&cur));
                    }
                }
            }
            Ok(())
        }
        pub fn list(&self, rel: &str) -> io::Result<Vec<String>> {
            let d = self.dir(rel)?;
            let mut v: Vec<String> = fs::read_dir(&d)?
                .filter_map(Result::ok)
                .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
                .filter_map(|e| e.file_name().to_str().map(str::to_string))
                .filter(|n| !n.starts_with('.'))
                .collect();
            v.sort();
            Ok(v)
        }
        pub fn read(&self, rel: &str, name: &str) -> io::Result<Option<Vec<u8>>> {
            check_name(name)?;
            let p = self.dir(rel)?.join(name);
            let m = match fs::symlink_metadata(&p) {
                Ok(m) => m,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(e),
            };
            if !m.is_file() {
                return Err(not_plain(&p));
            }
            let mut buf = Vec::new();
            File::open(&p)?.take(READ_CAP + 1).read_to_end(&mut buf)?;
            if buf.len() as u64 > READ_CAP {
                return Err(not_plain(&p));
            }
            Ok(Some(buf))
        }
        pub fn write_durable(
            &self,
            tmp_rel: &str,
            dir_rel: &str,
            name: &str,
            bytes: &[u8],
            sync: SyncFn,
        ) -> io::Result<()> {
            check_name(name)?;
            let tmp = self.dir(tmp_rel)?.join(format!(".{name}.{}", tmp_suffix()));
            let dst = self.dir(dir_rel)?.join(name);
            let res = (|| {
                let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
                f.write_all(bytes)?;
                sync(&f)
            })();
            if let Err(e) = res {
                let _ = fs::remove_file(&tmp);
                return Err(e);
            }
            fs::rename(&tmp, &dst).inspect_err(|_| {
                let _ = fs::remove_file(&tmp);
            })
        }
        pub fn rename(&self, from_rel: &str, from: &str, to_rel: &str, to: &str) -> io::Result<()> {
            check_name(from)?;
            check_name(to)?;
            fs::rename(self.dir(from_rel)?.join(from), self.dir(to_rel)?.join(to))
        }
        pub fn remove(&self, rel: &str, name: &str) -> io::Result<bool> {
            check_name(name)?;
            match fs::remove_file(self.dir(rel)?.join(name)) {
                Ok(()) => Ok(true),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
                Err(e) => Err(e),
            }
        }
        pub fn append(&self, name: &str, bytes: &[u8], sync: SyncFn) -> io::Result<()> {
            check_name(name)?;
            let p = self.path.join(name);
            if fs::symlink_metadata(&p).is_ok_and(|m| !m.is_file()) {
                return Err(not_plain(&p));
            }
            let mut f = OpenOptions::new().create(true).append(true).open(&p)?;
            f.write_all(bytes)?;
            sync(&f)
        }
        pub fn create_excl(&self, name: &str) -> io::Result<bool> {
            check_name(name)?;
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.path.join(name))
            {
                Ok(_) => Ok(true),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(false),
                Err(e) => Err(e),
            }
        }
        pub fn age(&self, rel: &str, name: &str) -> Option<Duration> {
            let m = fs::symlink_metadata(self.dir(rel).ok()?.join(name)).ok()?;
            m.modified().ok()?.elapsed().ok().or(Some(Duration::ZERO))
        }
        pub fn sync_root(&self, _sync: SyncFn) -> io::Result<()> {
            Ok(())
        }
    }
}

pub use imp::Lane;

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn lane(t: &Path, name: &str) -> Lane {
        let l = Lane::create(&t.join(name)).unwrap();
        l.ensure_dirs(&["inbox/tmp", "inbox/new", "outbox/new", "dead"])
            .unwrap();
        l
    }

    #[test]
    fn a_symlinked_subdirectory_is_refused_not_followed() {
        let t = tempfile::tempdir().unwrap();
        let _b = lane(t.path(), "b");
        std::fs::write(t.path().join("b/inbox/new/m-1"), "secret mail").unwrap();
        let a = Lane::create(&t.path().join("a")).unwrap();
        // The attack: a's outbox/new IS b's inbox/new, by a relative symlink.
        std::fs::create_dir_all(t.path().join("a/outbox")).unwrap();
        symlink("../../b/inbox/new", t.path().join("a/outbox/new")).unwrap();
        let e = a.list("outbox/new").unwrap_err();
        assert!(is_not_plain(&e), "{e}");
        let e = a.read("outbox/new", "m-1").unwrap_err();
        assert!(is_not_plain(&e), "{e}");
        assert!(
            a.ensure_dirs(&["outbox/new"])
                .is_err_and(|e| is_not_plain(&e))
        );
        // NEGATIVE CONTROL: the same path through std follows the link.
        assert!(t.path().join("a/outbox/new/m-1").exists());
    }

    #[test]
    fn a_symlinked_file_is_not_read_and_not_listed() {
        let t = tempfile::tempdir().unwrap();
        let a = lane(t.path(), "a");
        std::fs::write(t.path().join("host-file"), "host secret").unwrap();
        symlink(
            t.path().join("host-file"),
            t.path().join("a/outbox/new/m-x"),
        )
        .unwrap();
        assert!(a.list("outbox/new").unwrap().is_empty());
        assert!(a.read("outbox/new", "m-x").is_err());
        // Renaming moves the LINK, never the target.
        a.rename("outbox/new", "m-x", "dead", "m-x").unwrap();
        assert!(t.path().join("host-file").exists());
        assert!(
            std::fs::symlink_metadata(t.path().join("a/dead/m-x"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn a_fifo_does_not_hang_the_reader() {
        let t = tempfile::tempdir().unwrap();
        let a = lane(t.path(), "a");
        let p = std::ffi::CString::new(
            t.path()
                .join("a/outbox/new/m-fifo")
                .to_str()
                .unwrap()
                .as_bytes(),
        )
        .unwrap();
        // SAFETY: valid path.
        assert_eq!(unsafe { libc::mkfifo(p.as_ptr(), 0o600) }, 0);
        assert!(a.list("outbox/new").unwrap().is_empty());
        assert!(a.read("outbox/new", "m-fifo").is_err());
    }

    #[test]
    fn a_failed_sync_leaves_nothing_behind() {
        fn fail(_: &File) -> io::Result<()> {
            Err(io::Error::other("injected fsync failure"))
        }
        let t = tempfile::tempdir().unwrap();
        let a = lane(t.path(), "a");
        assert!(
            a.write_durable("inbox/tmp", "inbox/new", "m-1", b"x", fail)
                .is_err()
        );
        assert!(a.list("inbox/new").unwrap().is_empty());
        assert_eq!(
            std::fs::read_dir(t.path().join("a/inbox/tmp"))
                .unwrap()
                .count(),
            0
        );
        a.write_durable("inbox/tmp", "inbox/new", "m-1", b"x", fsync)
            .unwrap();
        assert_eq!(a.list("inbox/new").unwrap(), vec!["m-1".to_string()]);
    }

    #[test]
    fn names_are_single_components() {
        let t = tempfile::tempdir().unwrap();
        let a = lane(t.path(), "a");
        for bad in ["", ".", "..", "../x", "a/b"] {
            assert!(a.read("inbox/new", bad).is_err(), "{bad:?}");
            assert!(a.remove("inbox/new", bad).is_err(), "{bad:?}");
        }
        assert!(a.list("../a").is_err());
    }
}
