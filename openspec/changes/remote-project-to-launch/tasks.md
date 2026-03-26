## 1. Update event_loop.rs

- [ ] 1.1 Add `allocator` and `build_tx` parameters to `handle_clone_project` function signature
- [ ] 1.2 Pass `&mut allocator` and `build_tx.clone()` at the call site in `MenuCommand::CloneProject` handler
- [ ] 1.3 After a successful clone, pre-insert the cloned project into `state.projects` using a minimal `Project` entry so `handle_attach_here` can locate it
- [ ] 1.4 Call `handlers::handle_attach_here(target_dir, &mut state, &mut allocator, build_tx)` after pre-insertion
- [ ] 1.5 Log and swallow `handle_attach_here` errors — clone success is independent of launch success
- [ ] 1.6 Call `on_state_change` after the auto-launch attempt so the tray reflects the new state

## 2. Verification

- [ ] 2.1 Run `./build.sh --check` — must pass with zero errors
- [ ] 2.2 Clone a remote project via the tray menu and verify the forge launches automatically
- [ ] 2.3 Verify that if the forge image is not built, the clone still succeeds and the error is logged gracefully
- [ ] 2.4 Verify the scanner does not create a duplicate project entry when it detects the new directory
