//! ORDER 1335-jz8c — the tray glyph follows `VmPhase`.
//!
//! Before this order the Windows tray icon was set exactly once, in
//! `notify_icon::add_tray_icon`, from resource id 1, and the two `NIM_MODIFY`
//! sites carried `NIF_TIP` and `NIF_INFO` but never `NIF_ICON`. The icon was
//! therefore static by construction: the phase was already arriving (via
//! `VmStatusPush` and the fallback poll, both of which land in
//! `apply_vm_status`), and nothing consumed it visually.
//!
//! The mapping below and its test are deliberately NOT `cfg(windows)`-gated —
//! same reasoning as `tray_registry`: the decision is what needs pinning, and a
//! mapping that is only exercised where a Win32 tray exists is a mapping no CI
//! run ever checks. The HICON construction is gated; the policy is not.

use tillandsias_control_wire::VmPhase;
use tillandsias_core::genus::TrayIconState;

/// Which glyph a given VM phase shows.
///
/// The chosen mapping, and why each arm is the arm it is:
///
/// - `Provisioning` / `Starting` → `Pup`. The plant is not grown yet. Both are
///   transient "coming up" states and the operator should not be able to tell
///   them from at-rest at a glance, which is the whole point of the change.
/// - `Ready` → `Mature`. At rest, healthy. This is also the glyph the static
///   exe icon renders (`bud.svg`), so the steady state looks identical to the
///   taskbar/Alt-Tab identity of the app — no spurious "something changed".
/// - `Draining` / `Stopping` → `Stopping`. Shutting down.
/// - `Failed` → `Dried`. `Dried` is documented in `genus.rs` as
///   "unrecoverable error", which is what `Failed` is on the wire.
///
/// `Building`/`Blooming` are intentionally unreachable from `VmPhase`: they
/// describe per-project image/container build progress, which is not a VM phase
/// and does not arrive on this path. No control-wire variant was added.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn tray_state_for_phase(phase: VmPhase) -> TrayIconState {
    match phase {
        VmPhase::Provisioning | VmPhase::Starting => TrayIconState::Pup,
        VmPhase::Ready => TrayIconState::Mature,
        VmPhase::Draining | VmPhase::Stopping => TrayIconState::Stopping,
        VmPhase::Failed => TrayIconState::Dried,
    }
}

#[cfg(target_os = "windows")]
pub use windows_impl::apply_phase_icon;

#[cfg(target_os = "windows")]
mod windows_impl {
    use super::tray_state_for_phase;
    use std::collections::HashMap;
    use std::sync::Mutex;
    use tillandsias_control_wire::VmPhase;
    use tillandsias_core::genus::TrayIconState;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::Shell::{NIF_ICON, NIM_MODIFY, NOTIFYICONDATAW, Shell_NotifyIconW};
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateIconFromResourceEx, DestroyIcon, HICON, LR_DEFAULTCOLOR,
    };

    /// Must match `notify_icon::TRAY_ICON_ID`; the tray owns exactly one icon.
    const TRAY_ICON_ID: u32 = 1;

    /// The icon currently installed, plus the per-state HICON cache.
    ///
    /// Cached rather than rebuilt per transition for the reason the order
    /// names: a transition that allocates an HICON and does not free it leaks a
    /// GDI handle, and a cache makes the lifetime trivially correct — each
    /// state owns one HICON for the process lifetime, and the only handle ever
    /// destroyed is one this module created and is replacing. The alternative
    /// (build-then-DestroyIcon-the-previous) is one missed early-return away
    /// from a leak per phase flap, and phase flaps are exactly what a
    /// crash-looping VM produces.
    static ICON_CACHE: Mutex<Option<IconCache>> = Mutex::new(None);

    #[derive(Default)]
    struct IconCache {
        current: Option<TrayIconState>,
        /// `isize` rather than `HICON`: HICON is not `Send`, and this static is
        /// only ever touched from the tray's own thread, but the Mutex needs
        /// the bound anyway. Round-tripped through `HICON(..)` at use.
        handles: HashMap<TrayIconState, isize>,
    }

    // SAFETY-adjacent note: HICONs live until process exit by design (see
    // ICON_CACHE). Nothing else in the tray owns them.

    /// Decode `tillandsias_core::icons::tray_icon_png` into an HICON.
    ///
    /// `CreateIconFromResourceEx` wants an icon RESOURCE — a BITMAPINFOHEADER
    /// followed by the XOR bitmap and the AND mask — not a PNG, so the PNG is
    /// decoded to RGBA and re-encoded into that layout. Same shape build.rs
    /// writes into the .ico, for the same reason: it is the one icon-image
    /// encoding every Windows loader accepts at every size.
    fn hicon_for_state(state: TrayIconState) -> Option<HICON> {
        let png = tillandsias_core::icons::tray_icon_png(state);
        if png.is_empty() {
            return None;
        }
        let decoder = png::Decoder::new(png);
        let mut reader = decoder.read_info().ok()?;
        let mut buf = vec![0u8; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).ok()?;
        let (w, h) = (info.width, info.height);
        if w == 0 || h == 0 {
            return None;
        }
        // The embedded tray PNGs are RGBA8; anything else is unexpected and is
        // better skipped (leaving the static icon up) than rendered wrong.
        if info.color_type != png::ColorType::Rgba || info.bit_depth != png::BitDepth::Eight {
            return None;
        }
        let rgba = &buf[..(w as usize * h as usize * 4)];

        let mask_stride = (w as usize).div_ceil(32) * 4;
        let mask_len = mask_stride * h as usize;
        let xor_len = (w as usize) * (h as usize) * 4;
        let mut res = Vec::with_capacity(40 + xor_len + mask_len);
        res.extend_from_slice(&40u32.to_le_bytes());
        res.extend_from_slice(&(w as i32).to_le_bytes());
        res.extend_from_slice(&((h as i32) * 2).to_le_bytes());
        res.extend_from_slice(&1u16.to_le_bytes());
        res.extend_from_slice(&32u16.to_le_bytes());
        res.extend_from_slice(&0u32.to_le_bytes());
        res.extend_from_slice(&((xor_len + mask_len) as u32).to_le_bytes());
        res.extend_from_slice(&0i32.to_le_bytes());
        res.extend_from_slice(&0i32.to_le_bytes());
        res.extend_from_slice(&0u32.to_le_bytes());
        res.extend_from_slice(&0u32.to_le_bytes());
        // Bottom-up BGRA. The PNG carries straight alpha already (unlike
        // tiny-skia's premultiplied pixmap in build.rs), so no un-premultiply.
        for y in (0..h as usize).rev() {
            let row = &rgba[y * w as usize * 4..(y + 1) * w as usize * 4];
            for px in row.chunks_exact(4) {
                res.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
            }
        }
        res.resize(res.len() + mask_len, 0);

        // fIcon = TRUE, version 0x00030000 = the only value documented for
        // CreateIconFromResourceEx.
        let hicon =
            unsafe { CreateIconFromResourceEx(&res, true, 0x0003_0000, 0, 0, LR_DEFAULTCOLOR) };
        hicon.ok().filter(|h| !h.is_invalid())
    }

    /// Install the glyph for `phase` if it differs from the one showing.
    ///
    /// No-ops when the mapped state is unchanged, so the steady-state push
    /// stream (which delivers `Ready` repeatedly) does not issue a
    /// `Shell_NotifyIconW` per frame.
    pub fn apply_phase_icon(phase: VmPhase, hwnd: HWND) {
        let state = tray_state_for_phase(phase);
        let Ok(mut guard) = ICON_CACHE.lock() else {
            return;
        };
        let cache = guard.get_or_insert_with(IconCache::default);
        if cache.current == Some(state) {
            return;
        }
        let raw = match cache.handles.get(&state) {
            Some(h) => *h,
            None => {
                let Some(h) = hicon_for_state(state) else {
                    return;
                };
                cache.handles.insert(state, h.0 as isize);
                h.0 as isize
            }
        };
        let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
        nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        nid.hWnd = hwnd;
        nid.uID = TRAY_ICON_ID;
        nid.uFlags = NIF_ICON;
        nid.hIcon = HICON(raw as *mut std::ffi::c_void);
        let ok = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) };
        if ok.as_bool() {
            cache.current = Some(state);
        }
    }

    /// Free every cached HICON. Called on tray teardown so a long-lived
    /// process that stops and restarts the tray does not accumulate handles.
    #[allow(dead_code)]
    pub fn release_cached_icons() {
        let Ok(mut guard) = ICON_CACHE.lock() else {
            return;
        };
        if let Some(cache) = guard.as_mut() {
            for (_, raw) in cache.handles.drain() {
                let _ = unsafe { DestroyIcon(HICON(raw as *mut std::ffi::c_void)) };
            }
            cache.current = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phase_mapping_is_the_documented_one() {
        assert_eq!(
            tray_state_for_phase(VmPhase::Provisioning),
            TrayIconState::Pup
        );
        assert_eq!(tray_state_for_phase(VmPhase::Starting), TrayIconState::Pup);
        assert_eq!(tray_state_for_phase(VmPhase::Ready), TrayIconState::Mature);
        assert_eq!(
            tray_state_for_phase(VmPhase::Draining),
            TrayIconState::Stopping
        );
        assert_eq!(
            tray_state_for_phase(VmPhase::Stopping),
            TrayIconState::Stopping
        );
        assert_eq!(tray_state_for_phase(VmPhase::Failed), TrayIconState::Dried);
    }

    /// The running/stopped distinction must be VISIBLE — a mapping where every
    /// phase collapsed onto one glyph would pass the arm-by-arm test above and
    /// still leave the icon static, which is the defect this order exists for.
    #[test]
    fn ready_is_distinguishable_from_every_other_phase() {
        let ready = tray_state_for_phase(VmPhase::Ready);
        for other in [
            VmPhase::Provisioning,
            VmPhase::Starting,
            VmPhase::Draining,
            VmPhase::Stopping,
            VmPhase::Failed,
        ] {
            assert_ne!(tray_state_for_phase(other), ready, "{other:?} vs Ready");
        }
    }
}
