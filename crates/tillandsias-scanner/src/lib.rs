//! @trace spec:filesystem-scanner

mod detect;
mod watcher;

pub use detect::{detect_artifacts, detect_project_type, scan_project};
pub use watcher::{Scanner, ScannerConfig};
