## 1. Singleton Module

- [x] 1.1 Create `src-tauri/src/singleton.rs` with `lock_file_path()` returning the platform-appropriate lock file location
- [x] 1.2 Implement `try_acquire()` — read existing lock, check PID liveness + process name, write new PID if stale or absent
- [x] 1.3 Implement `release()` — remove the lock file (called on graceful shutdown)
- [x] 1.4 Implement stale detection: Linux (`/proc/<pid>/comm`), macOS (`kill(pid, 0)`), Windows (`OpenProcess`)

## 2. Integration

- [x] 2.1 Wire singleton check into `main.rs` — call `try_acquire()` after CLI parse, before Tauri builder, only for tray mode
- [x] 2.2 Wire `release()` into the existing shutdown path (SIGTERM/SIGINT handler or Tauri exit event)
- [x] 2.3 Add `mod singleton;` to the crate

## 3. Testing

- [x] 3.1 Test: launch app, verify lock file created at expected path with correct PID
- [x] 3.2 Test: launch second instance, verify it exits immediately with code 0
- [x] 3.3 Test: kill first instance with SIGKILL, launch again, verify stale lock is replaced
