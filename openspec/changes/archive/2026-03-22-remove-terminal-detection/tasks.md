## 1. Remove Terminal Detection

- [x] 1.1 Remove `detect_terminal()` function from handlers.rs
- [x] 1.2 Remove `spawn_terminal()` function from handlers.rs
- [x] 1.3 Remove `which_sync()` helper from handlers.rs
- [x] 1.4 Update `handle_attach_here` to spawn `podman run -it --rm` directly via `std::process::Command`
- [x] 1.5 Build and verify compilation
