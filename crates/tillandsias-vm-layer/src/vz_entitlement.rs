//! Does the RUNNING binary hold `com.apple.security.virtualization`? (order 811-j9fc)
//!
//! Virtualization.framework refuses an unentitled process, but only at
//! `validateWithError`, after `VzRuntime::start` has already grown the guest
//! disk, regenerated cidata.iso and created a swap image (measured on darwin
//! 2026-10-08: a 1 MiB scratch rootfs came back as a 10 GiB image beside a
//! 24 GiB swap image), and with a message that names an Apple API rather than
//! the project's signed build. A plain `cargo build` tray, and every test
//! binary, is linker-signed with NO entitlements, so this is the first thing a
//! developer hits. The check runs first, and the refusal is named.

/// What the entitlement probe saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entitlement {
    Present,
    Absent,
    /// The probe itself could not answer. start() proceeds, and VZ decides;
    /// `name_vz_entitlement_error` still names its refusal.
    Unknown(String),
}

pub const VIRTUALIZATION_ENTITLEMENT: &str = "com.apple.security.virtualization";

/// The named refusal: why, and the remedy.
pub fn refusal(exe: &str) -> String {
    format!(
        "refused:vm-start:missing-virtualization-entitlement — {exe} is not signed with \
         {VIRTUALIZATION_ENTITLEMENT}, so macOS will not let it start a VM\n  \
         why: Virtualization.framework requires that entitlement in the running binary's code \
         signature; a plain `cargo build` binary (target/*/tillandsias-tray, or any test binary) \
         is never entitled (811-j9fc)\n  \
         remedy: build the signed bundle with scripts/build-macos-tray.sh and run \
         dist/Tillandsias.app/Contents/MacOS/tillandsias-tray (an installed /Applications copy \
         may embed an older guest)"
    )
}

/// The preflight, with the probe injected. `Absent` refuses by name before
/// anything touches the image root; `Present` and `Unknown` proceed.
pub fn preflight_with(probe: impl FnOnce() -> Entitlement, exe: &str) -> Result<(), String> {
    match probe() {
        Entitlement::Absent => Err(refusal(exe)),
        Entitlement::Present | Entitlement::Unknown(_) => Ok(()),
    }
}

/// If a VZ error is the missing-entitlement one, the named refusal for it.
/// The backstop when the probe answered Unknown.
pub fn name_vz_entitlement_error(vz_error: &str, exe: &str) -> Option<String> {
    vz_error
        .contains(VIRTUALIZATION_ENTITLEMENT)
        .then(|| refusal(exe))
}

/// The running executable, for the message.
pub fn current_exe_display() -> String {
    std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "this binary".to_string())
}

/// Ask Security.framework about THIS process (SecTaskCreateFromSelf), rather
/// than reading a file's signature: what macOS enforces is the running task.
#[cfg(target_os = "macos")]
pub fn probe_running_process() -> Entitlement {
    use std::ffi::c_void;

    type CFTypeRef = *const c_void;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        fn SecTaskCreateFromSelf(allocator: CFTypeRef) -> CFTypeRef;
        fn SecTaskCopyValueForEntitlement(
            task: CFTypeRef,
            entitlement: CFTypeRef,
            error: *mut CFTypeRef,
        ) -> CFTypeRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            alloc: CFTypeRef,
            bytes: *const u8,
            num_bytes: isize,
            encoding: u32,
            is_external_representation: u8,
        ) -> CFTypeRef;
        fn CFRelease(cf: CFTypeRef);
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFBooleanGetValue(boolean: CFTypeRef) -> u8;
    }

    // SAFETY: every pointer below is either null-checked before use or comes
    // from a CF Create/Copy call and is released exactly once.
    unsafe {
        let task = SecTaskCreateFromSelf(std::ptr::null());
        if task.is_null() {
            return Entitlement::Unknown("SecTaskCreateFromSelf returned null".into());
        }
        let name = VIRTUALIZATION_ENTITLEMENT.as_bytes();
        let key = CFStringCreateWithBytes(
            std::ptr::null(),
            name.as_ptr(),
            name.len() as isize,
            K_CF_STRING_ENCODING_UTF8,
            0,
        );
        if key.is_null() {
            CFRelease(task);
            return Entitlement::Unknown("CFStringCreateWithBytes returned null".into());
        }
        let mut error: CFTypeRef = std::ptr::null();
        let value = SecTaskCopyValueForEntitlement(task, key, &mut error);
        CFRelease(key);
        CFRelease(task);
        if value.is_null() {
            if !error.is_null() {
                CFRelease(error);
                return Entitlement::Unknown(
                    "SecTaskCopyValueForEntitlement reported an error".into(),
                );
            }
            // Null with no error: the signature carries no such entitlement.
            return Entitlement::Absent;
        }
        let seen = if CFGetTypeID(value) == CFBooleanGetTypeID() {
            if CFBooleanGetValue(value) != 0 {
                Entitlement::Present
            } else {
                Entitlement::Absent
            }
        } else {
            Entitlement::Unknown("the entitlement's value is not a boolean".into())
        };
        CFRelease(value);
        seen
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_absent_entitlement_is_refused_by_name_with_why_and_remedy() {
        let err = preflight_with(|| Entitlement::Absent, "/x/target/release/tillandsias-tray")
            .expect_err("absent must refuse");
        assert!(
            err.starts_with("refused:vm-start:missing-virtualization-entitlement"),
            "{err}"
        );
        assert!(
            err.contains("/x/target/release/tillandsias-tray"),
            "names the binary: {err}"
        );
        assert!(
            err.contains("\n  why: ") && err.contains("\n  remedy: "),
            "{err}"
        );
        assert!(
            err.contains("scripts/build-macos-tray.sh") && err.contains("dist/Tillandsias.app"),
            "{err}"
        );
    }

    /// CONTROLS: a present entitlement proceeds, and an unanswerable probe does
    /// not block (VZ still decides, and its error is still named below).
    #[test]
    fn a_present_or_unknown_entitlement_proceeds() {
        assert_eq!(preflight_with(|| Entitlement::Present, "x"), Ok(()));
        assert_eq!(
            preflight_with(|| Entitlement::Unknown("probe failed".into()), "x"),
            Ok(())
        );
    }

    #[test]
    fn vzs_own_entitlement_error_is_named_and_others_are_not() {
        let vz = "validate: Invalid virtual machine configuration. The process doesn’t have the \
                  “com.apple.security.virtualization” entitlement.";
        let named = name_vz_entitlement_error(vz, "x").expect("named");
        assert!(named.starts_with("refused:vm-start:missing-virtualization-entitlement"));
        assert_eq!(
            name_vz_entitlement_error("validate: memory size too small", "x"),
            None
        );
    }

    /// The real probe agrees with codesign about THIS test binary, which cargo
    /// links with no entitlements.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_running_probe_reads_this_unentitled_test_binary_as_absent() {
        assert_eq!(probe_running_process(), Entitlement::Absent);
    }
}
