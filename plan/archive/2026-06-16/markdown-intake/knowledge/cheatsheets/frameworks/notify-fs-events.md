---
id: notify-fs-events
title: Filesystem Event Watching (notify crate)
category: frameworks/notify
tags: [notify, inotify, kqueue, fsevents, filesystem, watcher, events]
upstream: https://docs.rs/notify/latest/notify/
version_pinned: "8.x"
last_verified: "2026-03-30"
authority: official
---

# Filesystem Event Watching (notify crate)

## Core API

### Watcher Creation

`RecommendedWatcher` auto-selects the best backend for the current platform.

```rust
use notify::{RecommendedWatcher, Watcher, Config, RecursiveMode};
use std::sync::mpsc;

let (tx, rx) = mpsc::channel();
let mut watcher = RecommendedWatcher::new(tx, Config::default())?;
watcher.watch(Path::new("/some/path"), RecursiveMode::Recursive)?;

for event in rx {
    match event {
        Ok(event) => handle(event),
        Err(e) => eprintln!("watch error: {e}"),
    }
}
```

### Config

- `Config::default()` — platform defaults, no poll interval.
- `.with_poll_interval(Duration)` — only affects `PollWatcher`.
- `.with_compare_contents(bool)` — `PollWatcher` compares file contents instead of metadata.

### EventKind Hierarchy

Top-level variants of `notify::event::EventKind`:

| Variant    | Subtypes                                     | Notes                             |
|------------|----------------------------------------------|-----------------------------------|
| `Access`   | `Open`, `Close(Write/Rewrite)`, `Read`       | Not emitted on all platforms      |
| `Create`   | `File`, `Folder`, `Any`                      |                                   |
| `Modify`   | `Data(Content/Size)`, `Name(From/To/Both/Any)`, `Metadata(*)`, `Any` | Rename lives here as `Name` |
| `Remove`   | `File`, `Folder`, `Any`                      |                                   |
| `Other`    |                                               | Backend-specific                  |
| `Any`      |                                               | Catch-all when kind is unknown    |

### RecursiveMode

- `RecursiveMode::Recursive` — watch directory and all descendants.
- `RecursiveMode::NonRecursive` — watch only the immediate directory.

On Linux (inotify), recursive mode adds a watch per subdirectory. On macOS (FSEvents/kqueue), the OS handles recursion natively.

## Platform Backends

| Platform       | Backend                  | Recursive Native | Notes                              |
|----------------|--------------------------|------------------|------------------------------------|
| Linux          | inotify                  | No (emulated)    | Per-directory watches; subject to limits |
| macOS          | FSEvents (default)       | Yes              | Stream-based; slight delivery delay |
| macOS          | kqueue (feature flag)    | No (emulated)    | Per-fd; more precise but heavier   |
| Windows        | ReadDirectoryChangesW    | Yes              | Native recursive support           |
| Fallback/Any   | PollWatcher              | Yes              | Stat-based; works on NFS/FUSE      |

Select kqueue on macOS: enable the `macos_kqueue` feature flag.

## Debouncing

Two companion crates handle event deduplication:

- **`notify-debouncer-mini`** — lightweight, emits `AnySee` or `AnyOther` after a configurable timeout. Good for "something changed" triggers.
- **`notify-debouncer-full`** — tracks file IDs, emits full `Event` objects, handles renames across directories. Uses `RecommendedCache` (file ID cache on Windows/macOS, disabled on Linux).

```rust
use notify_debouncer_full::{new_debouncer, DebouncedEvent};
use std::time::Duration;

let (tx, rx) = mpsc::channel();
let mut debouncer = new_debouncer(Duration::from_millis(500), None, tx)?;
debouncer.watch(path, RecursiveMode::Recursive)?;
```

## Gotchas

### Rename events differ per platform

- Linux (inotify): emits `Modify::Name(From)` then `Modify::Name(To)` as two separate events with a shared cookie. You must correlate them.
- macOS (FSEvents): may emit a single event or coalesce with other changes.
- v8 change: files/directories moved *into* a watched folder on Linux now produce rename events instead of create events.

### inotify watch limits

Linux enforces per-user limits via sysctl:
- `fs.inotify.max_user_watches` (default often 8192 or 65536)
- `fs.inotify.max_user_instances` (default often 128)

Recursive watching of large trees (e.g., `node_modules`) can exhaust these. Raise with:
```bash
sysctl fs.inotify.max_user_watches=524288
```

### Network and virtual filesystems

NFS, FUSE, SSHFS, and container-mounted volumes generally do **not** emit inotify/kqueue events. The kernel is not notified of remote changes. Use `PollWatcher` as a fallback for these cases.

### Editor save behavior

Editors vary: some truncate-and-write (single modify), some write-to-temp-then-rename (remove + create or rename pair), some create a new inode entirely. Never assume a single "file saved" event pattern.

### Event coalescing

FSEvents on macOS batches events and may deliver them with a delay (typically ~100-500ms). Multiple rapid changes to the same file can merge into a single event. kqueue is more granular but heavier on resources.

### crossbeam-channel and async runtimes

By default, notify uses crossbeam-channel internally, making the watcher `Sync`. This can cause issues inside tokio. Disable the `crossbeam-channel` feature to fall back to `std::sync::mpsc`, or use `tokio::sync::mpsc` with a custom event handler.

## Performance Considerations

- **inotify** is O(watched directories), not O(files). One watch per directory covers all files in it, but recursive mode means one watch per subdirectory in the tree.
- **PollWatcher** stats every file on each interval. CPU cost scales linearly with file count. Use only when native events are unavailable.
- **FSEvents** has negligible per-watch overhead (stream-based), but coalesced delivery adds latency.
- For large trees, prefer non-recursive watches on specific directories of interest over blanket recursive watches.
- On Linux, prefer filtering events in your handler over reducing the watch set -- adding/removing watches has syscall overhead.

## Channel Pattern (async)

```rust
use tokio::sync::mpsc;
use notify::{RecommendedWatcher, Watcher, Config, RecursiveMode};

let (tx, mut rx) = mpsc::channel(256);
let mut watcher = RecommendedWatcher::new(
    move |res| { let _ = tx.blocking_send(res); },
    Config::default(),
)?;
watcher.watch(path, RecursiveMode::Recursive)?;

while let Some(event) = rx.recv().await {
    // handle event
}
```

## Version Notes (8.x)

- Serialization format changed for JS interop; use `serialization-compat-6` feature to restore v6 format.
- `RecommendedCache` in debouncer-full auto-selects file ID tracking per platform.
- v9.0.0 release candidates available (9.0.0-rc.2 as of Feb 2026) -- API may shift.
