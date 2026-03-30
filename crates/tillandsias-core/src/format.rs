//! Formatting utilities for user-facing output.

/// Human-readable byte count: "1.2 GB", "345 MB", "12 KB", "512 B".
pub fn human_bytes(bytes: u64) -> String {
    const GB: u64 = 1_073_741_824;
    const MB: u64 = 1_048_576;
    const KB: u64 = 1_024;
    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_human_bytes_gb() {
        assert_eq!(human_bytes(1_073_741_824), "1.0 GB");
        assert_eq!(human_bytes(2_147_483_648), "2.0 GB");
    }

    #[test]
    fn test_human_bytes_mb() {
        assert_eq!(human_bytes(1_048_576), "1.0 MB");
        assert_eq!(human_bytes(5_242_880), "5.0 MB");
    }

    #[test]
    fn test_human_bytes_kb() {
        assert_eq!(human_bytes(1_024), "1.0 KB");
        assert_eq!(human_bytes(2_048), "2.0 KB");
    }

    #[test]
    fn test_human_bytes_b() {
        assert_eq!(human_bytes(512), "512 B");
        assert_eq!(human_bytes(0), "0 B");
    }
}
