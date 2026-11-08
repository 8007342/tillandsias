//! tillandsias-enclave-fetch: serve the enclave-fetch MCP service.
//!
//! Environment:
//!   TILLANDSIAS_FETCH_LISTEN   listen address (default 0.0.0.0:8790)
//!   TILLANDSIAS_FETCH_CATALOG  catalog path (default /etc/tillandsias/fetch-catalog.yaml)
//!   TILLANDSIAS_FETCH_PROXY    upstream proxy URL (the proxy's research port); unset = direct, pinned
//!   TILLANDSIAS_FETCH_AUDIT    JSONL audit path (default: stderr)
//!
//! @trace spec:proxy-container, order:2041-csm4

use std::sync::{Arc, Mutex};
use tillandsias_enclave_fetch::catalog::Catalog;
use tillandsias_enclave_fetch::fetch::Fetcher;
use tillandsias_enclave_fetch::server::{self, Audit};

#[tokio::main]
async fn main() {
    let env = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
    let listen = env("TILLANDSIAS_FETCH_LISTEN", "0.0.0.0:8790");
    let path = env(
        "TILLANDSIAS_FETCH_CATALOG",
        "/etc/tillandsias/fetch-catalog.yaml",
    );
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("enclave-fetch: cannot read catalog {path}: {e}");
            std::process::exit(2);
        }
    };
    let catalog = match Catalog::parse(&text) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("enclave-fetch: {e}");
            std::process::exit(2);
        }
    };
    let proxy = std::env::var("TILLANDSIAS_FETCH_PROXY")
        .ok()
        .filter(|p| !p.is_empty());
    let sink: Audit = match std::env::var("TILLANDSIAS_FETCH_AUDIT") {
        Ok(p) if !p.is_empty() => match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&p)
        {
            Ok(f) => Arc::new(Mutex::new(Box::new(f))),
            Err(e) => {
                eprintln!("enclave-fetch: cannot open audit log {p}: {e}");
                std::process::exit(2);
            }
        },
        _ => Arc::new(Mutex::new(Box::new(std::io::stderr()))),
    };
    let listener = match tokio::net::TcpListener::bind(&listen).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("enclave-fetch: cannot listen on {listen}: {e}");
            std::process::exit(2);
        }
    };
    eprintln!(
        "enclave-fetch: {} sources, listening on {listen}, upstream {}",
        catalog.sources.len(),
        proxy.as_deref().unwrap_or("direct (pinned)")
    );
    if let Err(e) = server::serve(listener, Arc::new(Fetcher::new(catalog, proxy)), sink).await {
        eprintln!("enclave-fetch: {e}");
        std::process::exit(1);
    }
}
