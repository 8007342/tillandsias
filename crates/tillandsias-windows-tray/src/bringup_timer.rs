//! ORDER 1915-brst — the tray's bring-up step timer, for the WSL boot.
//!
//! The same line and row as tillandsias-headless's bringup_timer, which times
//! the steps inside the guest: `bringup: step=<name> ms=<n>` on stderr and in
//! the tray log, and one timing-ledger row only where `TILLANDSIAS_TIMING_LOG`
//! already switches the ledger on. The row carries the step name, the duration
//! and the exit, never a path, a project name or a user name.

pub(crate) fn line(step: &str, ms: u128) -> String {
    format!("bringup: step={step} ms={ms}")
}

pub(crate) fn report(step: &'static str, ms: u128, exit: i32) {
    let l = line(step, ms);
    eprintln!("{l}");
    tracing::info!("{l}");
    if let Some(path) = std::env::var_os("TILLANDSIAS_TIMING_LOG") {
        append_row(std::path::Path::new(&path), step, ms, exit);
    }
}

fn host() -> String {
    std::env::var("TILLANDSIAS_HOST_ID")
        .ok()
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .map(|h| h.trim().to_lowercase())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn append_row(path: &std::path::Path, step: &str, ms: u128, exit: i32) {
    let row = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "host": host(),
        "step": step,
        "phase": "bringup",
        "duration_ms": ms as u64,
        "exit": exit,
    });
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{row}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wsl_boot_line_and_row_shape() {
        assert_eq!(line("wsl-boot", 1234), "bringup: step=wsl-boot ms=1234");
        let dir = std::env::temp_dir().join(format!("tray-bringup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("t.jsonl");
        append_row(&p, "wsl-boot", 9, 0);
        let row: serde_json::Value =
            serde_json::from_str(std::fs::read_to_string(&p).unwrap().trim()).unwrap();
        let mut keys: Vec<&str> = row
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(keys, ["duration_ms", "exit", "host", "phase", "step", "ts"]);
        assert_eq!(row["step"], "wsl-boot");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The provision entry point reports wsl-boot around the whole span.
    #[test]
    fn provision_reports_wsl_boot_once() {
        let src: String = include_str!("wsl_lifecycle.rs")
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let needle = "let r = self.provision_via_recipe_steps(progress).await; crate::bringup_timer::report( \"wsl-boot\",";
        assert_eq!(src.matches(needle).count(), 1);
    }
}
