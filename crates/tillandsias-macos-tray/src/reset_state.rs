//! ORDER 1286-4437 — the macOS arm of `--reset-state`.
//!
//! CONTRACT, identical on all three platforms (design event 6cbbe622d, routing
//! event 02c73f8c, coordinator ruling 2026-09-20):
//!   * one flag name and one meaning everywhere;
//!   * the installer calls it by default AFTER the new app is in place;
//!   * it destroys the local STATE and PRESERVES the installation identity;
//!   * it announces both lists BEFORE touching anything;
//!   * `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` is the ONE affordance that skips the
//!     reset — and it skips only the destruction, still reprovisioning;
//!   * it reprovisions SYNCHRONOUSLY and the dispatch exits 1 on any Err.
//!
//! WHY THIS RETURNS `Result<(), String>` AND NOT `-> i32` LIKE ITS THREE
//! SIBLINGS (`--provision`, `--reset-guest`, `--diagnose` at main.rs:243/250/332).
//! It is deliberate and it is NOT a mistake to tidy. `--reset-state`'s whole
//! contract is that it means the same thing on every platform, so it follows the
//! cross-platform convention rather than the local one. Linux cannot offer exact
//! numeric propagation — its reprovision goes through `run_init`, which returns
//! `Result<(), String>` across ten call sites and never holds a child status —
//! so a richer macOS exit code would be an asymmetry born of an implementation
//! limit and then read by the next person as an intended design. See
//! tillandsias-core's reset-state documentation.
//!
//! THE PRE-FLIGHT GUARD IS NOT VACUOUS EVEN THOUGH THIS CODE *IS* THE BINARY IT
//! CHECKS FOR. An install can be interrupted between the app swap and this call,
//! and on macneo 2026-09-20 the installed app was observed GONE while 1.2 GiB of
//! VM state survived — cause never identified. A repair tool that assumes the
//! thing it repairs with is present is not a repair tool: destroying the state
//! there would leave nothing to reprovision from, on exactly the broken host this
//! flag exists to fix.

// WIRING REQUIRES ONE VISIBILITY CHANGE, recorded here so it is not discovered
// at compile time: `diagnose::image_root()` (diagnose.rs:107) is currently
// private and must become `pub(crate)`. Nothing else in this module references
// a symbol that does not already exist — provision_main, delete_credential_string,
// tillandsias_core::cache_root::cache_root and VzRuntime::wipe_provisioned_artifacts
// were each checked against the tree before being called.

// PENDING pirria's core half landing on trunk: this module imports
// tillandsias_core::reset_state::{RESET_SKIPPED_LINE, RESET_NO_REPROVISION_PATH}
// and the shared guard. It is deliberately NOT declared in main.rs yet, so the
// crate keeps building until those symbols exist. Wiring is: add `mod
// reset_state;`, make diagnose::image_root() pub(crate), and add the parse site
// beside --provision/--reset-guest/--diagnose.

use std::path::{Path, PathBuf};

/// The keychain entries the host-credential clearer clears.
const CLEARED_CREDENTIALS: [&str; 2] = ["vault-shamir-share-v1", "vault-root-token-v1"];
/// PRESERVED. Anchors the INSTALLATION, not the guest; the in-VM Vault derives
/// its master key from it, so clearing it makes the next vault underivable
/// rather than re-initialised (803-49re). The Windows counterpart is
/// `tillandsias-vm-uuid`; this is why the flag is reset-STATE, not reset-install.
const PRESERVED_ANCHOR: &str = "installation-uuid-v1";

fn caches_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Caches/tillandsias"))
}

/// `TILLANDSIAS_RESET_KEEP_MODELS=1` — a PRE-EXISTING per-run opt-in that
/// NARROWS what is destroyed; it does not skip the reset, so it does not collide
/// with the single-opt-out ruling. The smoke runbook's §2 already honours it and
/// breaking it here would be a regression, not a simplification.
fn keep_models() -> bool {
    std::env::var("TILLANDSIAS_RESET_KEEP_MODELS").is_ok_and(|v| v == "1")
}

/// The reprovision path this body will need AFTER it has destroyed the state.
/// Checked FIRST, and named in the refusal, so a broken host fails loudly with
/// its state intact instead of quietly losing it.
fn reprovision_path() -> PathBuf {
    PathBuf::from("/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray")
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// NO `debug` PARAMETER, unlike the Linux body. The macOS tray has no `--debug`
/// flag and `provision_main()` takes no arguments, so a parameter here would be
/// threaded through this module and dropped on the floor — a signature claiming
/// a verbosity control that does not exist. The shared contract is the flag's
/// NAME, MEANING and OUTPUT, not the arity of each platform's private body.
pub fn run_reset_state() -> Result<(), String> {
    let app = reprovision_path();
    if !is_executable(&app) {
        // Same rule as the skipped line: the SHARED constant carries the wording,
        // this body supplies only the platform path it could not find.
        return Err(format!(
            "{}: {}",
            tillandsias_core::reset_state::RESET_NO_REPROVISION_PATH,
            app.display()
        ));
    }

    // ORDER 1315-d4qd — BEFORE the announcement, not merely before the deletion.
    // With HOME unset the root resolves to /tmp/Library/..., and the announcement
    // below is built from the SAME root as the removals: it would name /tmp
    // paths, do exactly what it named, exit 0, and leave the operator told that
    // the local state was cleared while it sat untouched at the real root. The
    // two halves agreeing is what makes that unreadable as a failure, so the
    // refusal has to precede the first thing the operator is shown.
    let image_root = crate::diagnose::image_root_for_destruction()?;
    let caches = caches_dir();
    let cache_root = tillandsias_core::cache_root::cache_root();

    let mut destroyed: Vec<String> = vec![
        format!(
            "{} (VM state: rootfs, kernel, initrd, cidata, console log)",
            image_root.display()
        ),
        format!(
            "{} (provision markers, heartbeat/crashloop state, rotated console log)",
            image_root.display()
        ),
    ];
    if let Some(c) = &caches {
        destroyed.push(if keep_models() {
            format!(
                "{} (except models/, kept by TILLANDSIAS_RESET_KEEP_MODELS=1)",
                c.display()
            )
        } else {
            format!("{}", c.display())
        });
    }
    for t in CLEARED_CREDENTIALS {
        destroyed.push(format!("keychain: {t}"));
        destroyed.push(format!(
            "{}",
            cache_root.join(format!("fallback_{t}")).display()
        ));
    }
    destroyed.push(format!("{}", cache_root.join("vault-data").display()));

    let mut preserved: Vec<String> = vec![
        format!(
            "keychain: {PRESERVED_ANCHOR} (anchors this INSTALLATION; the in-VM Vault derives from it — 803-49re)"
        ),
        format!("{} (the installed application)", app.display()),
        format!(
            "{} (EFI variable store — preserved as installation identity; see this module's gap-4 note)",
            image_root.join("nvram.bin").display()
        ),
    ];
    if keep_models() {
        preserved.push("the model cache (TILLANDSIAS_RESET_KEEP_MODELS=1)".to_string());
    }

    let d: Vec<&str> = destroyed.iter().map(String::as_str).collect();
    let p: Vec<&str> = preserved.iter().map(String::as_str).collect();
    tillandsias_core::reset_state::announce_reset_plan(&d, &p);

    if !tillandsias_core::reset_state::destructive_reset_allowed() {
        // IMPORTED, NOT PASTED. I had pasted a paraphrase of yolanda's wording
        // here and it was already wrong in its bytes — which is the whole
        // argument: a string that must be identical on three platforms cannot be
        // kept identical by three people copying it. The constant is the single
        // source; if it changes, all three bodies change with it and none can
        // drift silently.
        eprintln!("{}", tillandsias_core::reset_state::RESET_SKIPPED_LINE);
        return provision_now();
    }

    // A DELTA OVER reset_guest_main, NOT A PARALLEL IMPLEMENTATION. The guest
    // artifacts are wiped by the SAME call the existing reset uses, so the two
    // cannot drift; everything after this line is the part macOS was missing.
    // NOTE THE ASYMMETRY WITH WINDOWS, measured rather than assumed: there
    // reset_guest_once already cleared the Vault credentials, so --reset-state
    // was a rename. Here it does NOT — there is no production caller of
    // delete_credential_string (both call sites are test-only) while the
    // existing message tells the operator it discards "cached credentials".
    // This module does not assert "more than --reset-guest" as a contract; that
    // claim is platform-specific and the litmus asserts the CONTRACT only.
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root.clone());
    vz.wipe_provisioned_artifacts()
        .map_err(|e| format!("reset-state: wiping guest artifacts: {e}"))?;

    // GAP 4, RESOLVED ASYMMETRICALLY ON MEASURED EVIDENCE (macbookair, 2026-09-20,
    // who owns the macOS guest boot path and kept measured and inferred apart).
    //
    // DESTROYED — `provision/`, `heartbeat.state`, `crashloop.state`, and
    // `console.log.prev`. provision/ is OUTPUT, not input: vz.rs ~2341 calls
    // create_dir_all on it before every start and boots WITHOUT the share if that
    // fails, so the host recreates it unconditionally; its own doc says it "lives
    // under the image root beside heartbeat.state and crashloop.state, so a
    // destroy that resets the guest also resets the record — a marker surviving
    // the guest it describes would be the stale-state defect". Its survival today
    // is unswept, not deliberate. The other three are the same class of marker or
    // byproduct; `console.log.prev` was 51 MB on macbookair's host while the wipe
    // removes console.log and not its sibling. (Source-read, not a live
    // destructive test — macbookair deliberately did not delete provision.state on
    // a provisioned host, because a false "provisioning never completed" is the
    // exact failure this row exists to prevent.)
    //
    // PRESERVED — `nvram.bin`, DESPITE a measurement that destroying it is safe.
    // macbookair deleted it and booted: the guest came up and the file was
    // regenerated at 131072 bytes (vz.rs:1852 branches on path.exists() and
    // creates the variable store when absent). That proves it is NOT boot-blocking.
    // It does NOT prove nothing DERIVES from it, and macbookair said so rather
    // than stretching the result. This flag preserves installation identity BY
    // CONTRACT, and an EFI variable store is not proven to be outside that; the
    // cost is asymmetric — a surviving stale variable store is harmless, while
    // destroying a live anchor is 803-49re, a vault that cannot be re-derived.
    // THE MEASUREMENT THAT WOULD SETTLE IT, named so it is a task and not a doubt:
    // derive a vault against a destroyed-and-regenerated nvram and see if it
    // reproduces. Until someone runs it, this file is spared and the row says why.
    for marker in [
        "provision",
        "heartbeat.state",
        "crashloop.state",
        "console.log.prev",
    ] {
        remove_path(&image_root.join(marker))?;
    }

    if let Some(c) = &caches {
        if keep_models() {
            remove_children_except(c, "models")?;
        } else {
            remove_path(c)?;
        }
    }
    for t in CLEARED_CREDENTIALS {
        crate::installation_uuid::delete_credential_string(t)
            .map_err(|e| format!("reset-state: clearing keychain {t}: {e}"))?;
        remove_path(&cache_root.join(format!("fallback_{t}")))?;
    }
    remove_path(&cache_root.join("vault-data"))?;

    eprintln!("[reset-state] local state cleared — reprovisioning from scratch…");
    provision_now()
}

fn provision_now() -> Result<(), String> {
    match crate::diagnose::provision_main() {
        0 => Ok(()),
        rc => Err(format!(
            "reset-state: reprovision failed (provision exited {rc}) — the local state has been \
             cleared and the guest is NOT provisioned; re-run the installer or \
             `tillandsias-tray --provision`"
        )),
    }
}

/// Absent is success: this is a reset, and a path that is already gone is the
/// state we want. Only an existing path we cannot remove is an error.
fn remove_path(p: &Path) -> Result<(), String> {
    if !p.exists() {
        return Ok(());
    }
    let r = if p.is_dir() {
        std::fs::remove_dir_all(p)
    } else {
        std::fs::remove_file(p)
    };
    r.map_err(|e| format!("reset-state: removing {}: {e}", p.display()))
}

fn remove_children_except(dir: &Path, keep: &str) -> Result<(), String> {
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(_) => return Ok(()),
    };
    for entry in rd.flatten() {
        if entry.file_name() == keep {
            continue;
        }
        remove_path(&entry.path())?;
    }
    Ok(())
}
