//! Shared test-only helpers for the whole `tillandsias-headless` crate.
//!
//! `env_lock()` is the ONE process-wide mutex every env-mutating test in this
//! crate must serialize on. `std::env::set_var`/`remove_var` are process-global
//! and unsound to race with `getenv`, so two independent mutexes do not
//! serialize anything against each other — they only serialize the tests that
//! happen to share one of them. Order 1437-5czv found five: `local_projects`,
//! `remote_projects`, `tray::mod` (two, `ENV_LOCK`/`ENV_LOCK2`) and
//! `vault_bootstrap` each kept their own, alongside the pre-existing
//! `runtime_assets::env_lock()` (order 434) that `remote_projects`' tests also
//! took — belt and suspenders that still left every OTHER lock's tests
//! unsynchronized against each other. `resource_lock`'s tests read
//! `XDG_RUNTIME_DIR` (via `lock_dir()`) under NO lock at all, which is why
//! `resource_lock::tests::is_held_reflects_lock_lifecycle` failed only in a
//! full parallel run (1242-4x53): any of the five locks' tests could mutate
//! that same var mid-probe. `runtime_assets::env_lock()` now re-exports this
//! function, so every existing call site keeps working against the same lock.
#![cfg(test)]

/// Acquire the crate-wide env-mutation lock. Poison-tolerant: one test's
/// panic must not cascade-fail every test that acquires the lock afterward.
pub(crate) fn env_lock() -> std::sync::MutexGuard<'static, ()> {
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}
