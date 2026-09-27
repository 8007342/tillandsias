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

// ---------------------------------------------------------------------------
// ORDER 1443-bgbs (Windows half of 1420-v3zt): first-provision progress on the
// tray icon and in the menu, from typed ProgressEvents. Portable, like the
// mapping above: the strip's palette, the row's text and the repaint gate are
// what need pinning, and they are pinned on every host.
// ---------------------------------------------------------------------------

/// Cells in the menu row's bar. Ten, so the row fits the 45-character chip
/// beside the longest label it carries ("Downloading Fedora rootfs").
pub const PROGRESS_CELLS: usize = 10;

fn clamp_fraction(fraction: f64) -> f64 {
    if fraction.is_nan() {
        0.0
    } else {
        fraction.clamp(0.0, 1.0)
    }
}

/// Paint a progress strip across the bottom rows of an RGBA8 icon image, in
/// place: the filled width on the tillandsia leaf ramp (deepest at the left),
/// its leading column in the blush tip while unfinished, the rest in the track
/// colour. Opaque, so it reads over any glyph. The strip is an eighth of the
/// height and never less than two rows, so it survives a 16x16 icon.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn paint_progress_strip(rgba: &mut [u8], w: usize, h: usize, fraction: f64) {
    use tillandsias_progress_tty::palette;
    if w == 0 || h == 0 || rgba.len() < w * h * 4 {
        return;
    }
    let fraction = clamp_fraction(fraction);
    let rows = (h / 8).max(2).min(h);
    let filled = ((fraction * w as f64).floor() as usize).min(w);
    let ramp = &palette::LEAF_RAMP;
    for y in (h - rows)..h {
        for x in 0..w {
            let rgb = if x < filled {
                if x + 1 == filled && filled < w {
                    palette::TIP_BLUSH.rgb
                } else {
                    ramp[(x * ramp.len() / w).min(ramp.len() - 1)].rgb
                }
            } else {
                palette::TRACK.rgb
            };
            let i = (y * w + x) * 4;
            rgba[i..i + 4].copy_from_slice(&[rgb.0, rgb.1, rgb.2, 0xFF]);
        }
    }
}

/// The menu progress row: the step's own label, a bar of `PROGRESS_CELLS`
/// U+25B0/U+25B1 glyphs (macOS's, for one look across trays), the percent.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn menu_row_text(label: &str, fraction: f64) -> String {
    let fraction = clamp_fraction(fraction);
    let filled = ((fraction * PROGRESS_CELLS as f64).floor() as usize).min(PROGRESS_CELLS);
    format!(
        "{label} {}{} {}%",
        "\u{25B0}".repeat(filled),
        "\u{25B1}".repeat(PROGRESS_CELLS - filled),
        tillandsias_progress_tty::percent(fraction)
    )
}

/// The task id of the first-provision rootfs download, the one measurable
/// step of a Windows provision.
pub const ROOTFS_DOWNLOAD_TASK: &str = "provision/rootfs-download";

/// The typed event for the rootfs download, `done` of `total` bytes. Its label
/// is the phase's existing, approved wording (ProvisionPhase::DownloadingRootfs
/// without the ellipsis), so no new user-visible words enter the tray.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn rootfs_download_event(done: u64, total: u64) -> tillandsias_control_wire::ProgressEvent {
    use tillandsias_control_wire::{ProgressEvent, ProgressKind, ProgressUnit};
    ProgressEvent {
        task: ROOTFS_DOWNLOAD_TASK.to_string(),
        parent: None,
        label: tillandsias_host_shell::provisioning::ProvisionPhase::DownloadingRootfs
            .status_text_ascii()
            .trim_end_matches("...")
            .to_string(),
        kind: ProgressKind::Determinate {
            done,
            total: Some(total),
            unit: ProgressUnit::Bytes,
        },
        ts_unix_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
    }
}

/// vm-layer reports per chunk; the tray repaints only when the shown percent
/// changes (a new icon is a GDI handle and a Shell_NotifyIconW call). `true` =
/// repaint. Same rule as macOS's PercentGate.
#[derive(Debug, Default)]
pub struct PercentGate {
    last: Option<(String, u32)>,
}

impl PercentGate {
    #[cfg_attr(not(target_os = "windows"), allow(dead_code))]
    pub fn changed(&mut self, task: &str, fraction: f64) -> bool {
        let key = (
            task.to_string(),
            tillandsias_progress_tty::percent(clamp_fraction(fraction)),
        );
        if self.last.as_ref() == Some(&key) {
            return false;
        }
        self.last = Some(key);
        true
    }

    /// Forget the last task, so the next event repaints (after a clear).
    #[cfg_attr(not(target_os = "windows"), allow(dead_code))]
    pub fn reset(&mut self) {
        self.last = None;
    }
}

#[cfg(target_os = "windows")]
pub use windows_impl::apply_phase_icon;
#[cfg(target_os = "windows")]
pub use windows_impl::apply_progress_icon;

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
        /// ORDER 1443-bgbs: the one progress icon currently installed, if
        /// any. Unlike the per-state glyphs it is rebuilt per percent, so it
        /// is the one handle this module destroys: when the next percent
        /// replaces it, and when progress clears.
        progress: Option<isize>,
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
        let (w, h, rgba) = rgba_for_state(state)?;
        hicon_from_rgba(w, h, &rgba)
    }

    /// The state's embedded PNG as straight-alpha RGBA8, or None when it is
    /// missing or not RGBA8 (the static icon then stays up).
    fn rgba_for_state(state: TrayIconState) -> Option<(u32, u32, Vec<u8>)> {
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
        buf.truncate(w as usize * h as usize * 4);
        Some((w, h, buf))
    }

    /// Encode RGBA8 as an icon resource and load it.
    fn hicon_from_rgba(w: u32, h: u32, rgba: &[u8]) -> Option<HICON> {
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
            for px in row.as_chunks::<4>().0 {
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
            // 1443-bgbs: a phase glyph replaced any progress icon.
            if let Some(old) = cache.progress.take() {
                let _ = unsafe { DestroyIcon(HICON(old as *mut std::ffi::c_void)) };
            }
        }
    }

    /// ORDER 1443-bgbs: show `fraction` as a palette strip across the bottom
    /// of the current state's glyph, or with `None` restore the plain glyph.
    /// The progress icon is rebuilt per call (the caller gates it to once per
    /// percent) and the previous one is destroyed only after its replacement
    /// is installed, so the tray never shows a freed handle.
    pub fn apply_progress_icon(fraction: Option<f64>, hwnd: HWND) {
        let Ok(mut guard) = ICON_CACHE.lock() else {
            return;
        };
        let cache = guard.get_or_insert_with(IconCache::default);
        let state = cache.current.unwrap_or(TrayIconState::Pup);
        let raw = match fraction {
            Some(f) => {
                let Some((w, h, mut rgba)) = rgba_for_state(state) else {
                    return;
                };
                super::paint_progress_strip(&mut rgba, w as usize, h as usize, f);
                let Some(icon) = hicon_from_rgba(w, h, &rgba) else {
                    return;
                };
                icon.0 as isize
            }
            None => {
                if cache.progress.is_none() {
                    return;
                }
                match cache.handles.get(&state) {
                    Some(h) => *h,
                    None => {
                        let Some(h) = hicon_for_state(state) else {
                            return;
                        };
                        cache.handles.insert(state, h.0 as isize);
                        h.0 as isize
                    }
                }
            }
        };
        let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
        nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        nid.hWnd = hwnd;
        nid.uID = TRAY_ICON_ID;
        nid.uFlags = NIF_ICON;
        nid.hIcon = HICON(raw as *mut std::ffi::c_void);
        let ok = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) };
        if !ok.as_bool() {
            // Not installed: a fresh progress icon is ours alone to free.
            if fraction.is_some() {
                let _ = unsafe { DestroyIcon(HICON(raw as *mut std::ffi::c_void)) };
            }
            return;
        }
        let old = cache.progress.take();
        if fraction.is_some() {
            cache.progress = Some(raw);
        }
        if let Some(old) = old {
            let _ = unsafe { DestroyIcon(HICON(old as *mut std::ffi::c_void)) };
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
            if let Some(raw) = cache.progress.take() {
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

    /// 1443-bgbs: the strip is the tillandsia palette across the bottom rows
    /// only: leaf ramp from the left, blush tip at the front, track after it,
    /// opaque; the glyph above it is untouched.
    #[test]
    fn progress_strip_paints_the_palette_on_the_bottom_rows_only() {
        use tillandsias_progress_tty::palette;
        let (w, h) = (32usize, 32usize);
        let mut img = vec![7u8; w * h * 4];
        paint_progress_strip(&mut img, w, h, 0.5);
        let px = |x: usize, y: usize| {
            let i = (y * w + x) * 4;
            (img[i], img[i + 1], img[i + 2], img[i + 3])
        };
        let rgb = |c: tillandsias_progress_tty::palette::Colour| (c.rgb.0, c.rgb.1, c.rgb.2, 0xFF);
        // 32 / 8 = 4 rows of strip, rows 28..32.
        assert_eq!(px(0, 27), (7, 7, 7, 7), "the glyph above the strip changed");
        assert_eq!(px(0, 28), rgb(palette::LEAF_DEEPEST));
        assert_eq!(
            px(15, 31),
            rgb(palette::TIP_BLUSH),
            "the leading filled column"
        );
        assert_eq!(px(16, 31), rgb(palette::TRACK));
        assert_eq!(px(31, 28), rgb(palette::TRACK));
        // Complete: no blush tip, no track; a 16px icon still gets 2 rows.
        let mut full = vec![0u8; 16 * 16 * 4];
        paint_progress_strip(&mut full, 16, 16, 1.0);
        for x in 0..16 {
            let i = (15 * 16 + x) * 4;
            let c = (full[i], full[i + 1], full[i + 2]);
            assert_ne!(c, palette::TIP_BLUSH.rgb, "blush at x={x} when complete");
            assert_ne!(c, palette::TRACK.rgb, "track at x={x} when complete");
        }
        assert_eq!(full[(14 * 16) * 4 + 3], 0xFF, "a 16px strip must be 2 rows");
        assert_eq!(full[(13 * 16) * 4 + 3], 0, "and only 2");
    }

    /// 1443-bgbs: the menu row is label, ten-cell bar, percent, and fits the
    /// 45-character status chip at 100% with the longest label it carries.
    #[test]
    fn menu_row_is_label_bar_percent_and_fits_the_chip() {
        assert_eq!(
            menu_row_text("Downloading Fedora rootfs", 0.42),
            "Downloading Fedora rootfs \u{25B0}\u{25B0}\u{25B0}\u{25B0}\u{25B1}\u{25B1}\u{25B1}\u{25B1}\u{25B1}\u{25B1} 42%"
        );
        let full = menu_row_text("Downloading Fedora rootfs", 1.0);
        assert!(
            full.ends_with(" 100%") && !full.contains('\u{25B1}'),
            "{full}"
        );
        assert!(
            full.chars().count() <= 45,
            "{} chars: {full}",
            full.chars().count()
        );
        assert!(menu_row_text("x", f64::NAN).ends_with(" 0%"));
    }

    /// 1443-bgbs: the rootfs download is a typed Bytes event under the
    /// approved phase wording, not prose.
    #[test]
    fn rootfs_download_is_a_typed_bytes_event_with_the_approved_label() {
        use tillandsias_control_wire::{ProgressKind, ProgressUnit};
        let ev = rootfs_download_event(132, 528);
        assert_eq!(ev.task, ROOTFS_DOWNLOAD_TASK);
        assert_eq!(ev.label, "Downloading Fedora rootfs");
        assert_eq!(
            ev.kind,
            ProgressKind::Determinate {
                done: 132,
                total: Some(528),
                unit: ProgressUnit::Bytes
            }
        );
        assert_eq!(ev.kind.fraction(), Some(0.25));
    }

    /// 1443-bgbs closure shape: a byte-granular download repaints once per
    /// percent, at least 10 and at most 101 times, never once per chunk.
    #[test]
    fn percent_gate_repaints_once_per_percent() {
        let mut gate = PercentGate::default();
        let total = 528_000_000u64;
        let repaints = (0..=total)
            .step_by(1_000_000)
            .filter(|done| gate.changed("rootfs", *done as f64 / total as f64))
            .count();
        assert!((10..=101).contains(&repaints), "{repaints}");
        assert!(!gate.changed("rootfs", 1.0), "same percent, no repaint");
        gate.reset();
        assert!(gate.changed("rootfs", 1.0), "a reset repaints");
    }
}
