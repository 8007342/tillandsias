//! Order 1957-msjs: a provider usage limit one host's forge recorded holds
//! the forges of every fleet host, since the free tier's quota is shared.
//!
//! The tray is the relay; the logic lives in `scripts/provider-limit-relay.sh`
//! (one implementation, fixture-tested by
//! `scripts/lua/test-provider-limit-relay.lua`):
//!
//! - at LAUNCH, offline: `seed-env` folds the local plan copy's limit events,
//!   and the live ones reach the forge as [`SHARED_ENV`], which
//!   `lib-provider-limit.sh` refuses on, naming the recording host;
//! - on EXIT: `on-exit` publishes the forge's own record as a plan fragment on
//!   the plan-only lane. Spawned detached and never waited for, so it cannot
//!   delay the exit; a failed push leaves a deferred line the slot retries.
//!
//! Both need a developer checkout (the script and the plan). A host without
//! one (an installed tray outside the fleet) does neither: nothing changes.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The forge env var a seeded deadline travels in.
pub const SHARED_ENV: &str = "TILLANDSIAS_PROVIDER_LIMIT_SHARED";

/// How long launch waits for the offline fold before going without it.
const SEED_DEADLINE: Duration = Duration::from_secs(5);

fn relay_script() -> Option<PathBuf> {
    let root = crate::find_developer_checkout_root().ok()?;
    let script = root.join("scripts/provider-limit-relay.sh");
    script.is_file().then_some(script)
}

/// The `(name, value)` to set on a forge launch, or None when no other host's
/// limit is live (or there is no checkout to fold). Never touches the network.
pub fn launch_env() -> Option<(&'static str, String)> {
    // Argv builders are unit-tested; a live fold would make them depend on
    // whatever the checkout's plan holds today.
    if cfg!(test) {
        return None;
    }
    let script = relay_script()?;
    let mut child = Command::new("bash")
        .arg(&script)
        .arg("seed-env")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < SEED_DEADLINE => {
                std::thread::sleep(Duration::from_millis(20))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let out = child.wait_with_output().ok()?;
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!value.is_empty()).then_some((SHARED_ENV, value))
}

/// After a forge exits: publish whatever limit it recorded in `cache_volume`.
/// Detached in its own process group and never waited for.
pub fn relay_on_exit(cache_volume: &str) {
    if cfg!(test) {
        return;
    }
    let Some(script) = relay_script() else {
        return;
    };
    let mut cmd = Command::new("bash");
    cmd.arg(&script)
        .args(["on-exit", "--volume", cache_volume])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let _ = cmd.spawn();
}
