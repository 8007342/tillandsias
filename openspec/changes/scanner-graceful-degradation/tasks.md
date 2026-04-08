# Tasks — scanner-graceful-degradation

## Context
The scanner's `watch()` method can crash on inotify watch-limit exhaustion, permission-denied, or missing paths because it uses `?` to propagate `notify::Error`. It should degrade gracefully: log warnings, continue with partial watches, and never bring down the application.

## Tasks

- [x] T1: `watch()` — handle missing watch paths with warning log instead of silently skipping
- [x] T2: `watch()` — catch top-level `watcher.watch()` errors (permission denied, inotify limits) and log warnings instead of returning `Err`
- [x] T3: `watch()` — log meaningful context on depth-2 watch failures instead of silently dropping with `let _ =`
- [x] T4: Add trace annotation `@trace spec:filesystem-scanner` to graceful-degradation paths
- [x] T5: Add tests for scanner behavior with nonexistent watch paths and unreadable directories
