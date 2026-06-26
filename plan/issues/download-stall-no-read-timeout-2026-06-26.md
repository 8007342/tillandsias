# download_verified: no in-flight retry or read timeout — stalls on WiFi drop

**discovered_by:** `/smoke-curl-install-and-test-e2e` on macOS, release `v0.3.260626.4`
**Host:** Darwin arm64
**Agent:** `macos-smoke-20260626T2000Z`

## Symptom

During `--provision`, the 528 MB Fedora Cloud image download stalled after
reaching 343 MB (65%) when the host WiFi dropped momentarily. The process
kept the CPU alive (PID visible in pgrep) but produced no output and wrote
no bytes to `rootfs.part` for **34 minutes** until manually killed.

```
rootfs.part  346816180 bytes  last-written 13:13:02 PDT
current time                              13:47:29 PDT  (34 min gap)
```

## Root cause

`crates/tillandsias-vm-layer/src/fetch.rs:download_verified` builds a
`reqwest::Client` with only a `connect_timeout` (10 s). No `read_timeout`
and no `timeout` on the whole response body are set:

```rust
// fetch.rs:176-181
let client = reqwest::Client::builder()
    .connect_timeout(std::time::Duration::from_secs(10))
    // Do not set a total request timeout here: large VM images can take
    // minutes on slow links, and retry/resume handles interrupted bodies.
    .build()...
```

The comment says "retry/resume handles interrupted bodies", but there is no
retry loop in the function. `resp.chunk().await` (line 217) can hang
indefinitely once the underlying TCP connection goes silent after a WiFi
drop — the OS does not always send RST when a physical link disappears, so
`reqwest`/`hyper` has no signal to report an error.

**Resume on restart works** (`.part` file + `Range: bytes=<have>-` at
line 184), but that requires the caller to kill the hung process first —
there is no automatic self-healing.

## Evidence

- `target/smoke-e2e/03-provision-macos.log` — last line: `{"phase":"Downloading Fedora Cloud image 343/528 MB (65%)"}`
- `~/Library/Application Support/tillandsias/rootfs.part` — 346,816,180 bytes, mtime 13:13:02, not updated for 34 min
- `fetch.rs:176-181` — only `connect_timeout` set, no read/idle timeout
- `fetch.rs:217-220` — `resp.chunk().await` in a plain while-let with no timeout wrapper

## Required fix

Two complementary layers:

1. **Per-chunk idle timeout inside `download_verified`** — wrap
   `resp.chunk().await` with `tokio::time::timeout(Duration::from_secs(30))`
   (or similar). On timeout, return an error from the chunk loop.

2. **Retry loop at the caller or within `download_verified`** — on any
   chunk error (timeout, connection reset, etc.) the function should:
   - flush and close the partial file
   - increment a retry counter (e.g. max 5)
   - wait with exponential backoff (1 s, 2 s, 4 s …)
   - re-enter the download loop: the existing `.part` file ensures the next
     `Range: bytes=<have>-` request resumes from where it left off

The fix lives in `crates/tillandsias-vm-layer/src/fetch.rs` and benefits
both macOS (VzRuntime) and Windows (WslRuntime) since they share this module.

## Work Packet

### Work Packet: smoke-finding/download-no-read-timeout

- id: `smoke-finding/download-no-read-timeout`
- owner_host: any
- capability_tags: [rust, networking, provisioning, macos, windows, reliability]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.4`
- evidence:
  - `crates/tillandsias-vm-layer/src/fetch.rs:176-220` — `connect_timeout` only; `resp.chunk().await` has no timeout wrapper and no retry loop
  - `target/smoke-e2e/03-provision-macos.log` — download stalled at 65% for 34 min after WiFi drop
- repro:
  - Start `"/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray" --provision` on macOS with a fresh substrate, then temporarily disconnect WiFi mid-download (≥50% progress). Process will hang indefinitely.
- next_action: >
    In `crates/tillandsias-vm-layer/src/fetch.rs`, wrap `resp.chunk().await`
    with `tokio::time::timeout(Duration::from_secs(30), ...)`. On timeout or
    chunk error, close the partial file and retry with backoff (max 5 attempts),
    relying on the existing Range-request resume path. Add a `#[tokio::test]`
    that injects a stalling mock body and asserts the function retries and
    eventually succeeds (or fails with a clear error after max retries).
- events:
  - type: discovered
    ts: "2026-06-26T20:47:29Z"
    agent_id: "macos-smoke-20260626T2000Z"
    host: macos
