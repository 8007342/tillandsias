//! `dispatch_to_main_thread` — fire-and-forget bridge from any thread
//! back to the AppKit main thread, via libdispatch's `dispatch_async`.
//!
//! AppKit objects (NSStatusItem, NSMenu, NSMenuItem) MUST only be
//! mutated on the main thread. Our action-host stubs spawn Tokio tasks
//! on worker threads to do VM work without blocking the menu, so after
//! the async work completes we need a way to land back on the main
//! thread for any UI updates (menu label refresh, status item tooltip).
//!
//! `tokio::task::spawn_blocking` does NOT help — its worker threads are
//! still off the AppKit main thread. The libdispatch main queue is the
//! canonical Cocoa-thread re-entry point.
//!
//! ## Implementation
//!
//! Uses GCD's C API directly via two FFI symbols:
//!   - `_dispatch_main_q` (the static main queue struct; in C it's
//!     reached via the `dispatch_get_main_queue()` macro).
//!   - `dispatch_async_f` (function-pointer variant of dispatch_async;
//!     simpler than the block variant — no block2 dependency).
//!
//! Closure marshaling: we box the closure, hand the raw pointer to
//! libdispatch as the trampoline context, and the trampoline rebuilds
//! the Box and invokes it on the main thread. Memory is owned by the
//! Box for the full round-trip; the trampoline drops it.
//!
//! macOS-only; the non-macOS branch of the crate never compiles this.
//!
//! @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 2)

#![cfg(target_os = "macos")]

use std::ffi::c_void;

// libdispatch (part of macOS libSystem; always linked).
unsafe extern "C" {
    /// Process-wide static main queue. `dispatch_get_main_queue()` in C
    /// is a macro that yields `&_dispatch_main_q`; we link the static
    /// directly because Rust extern "C" can't take macros.
    static _dispatch_main_q: c_void;

    /// `void dispatch_async_f(dispatch_queue_t, void *context,
    ///                        dispatch_function_t work);`
    /// Fire-and-forget; returns immediately. The work function runs on
    /// the queue with the context pointer.
    fn dispatch_async_f(
        queue: *const c_void,
        context: *mut c_void,
        work: extern "C" fn(*mut c_void),
    );
}

/// Schedule `f` to run on the AppKit main thread soon. Returns
/// immediately; the closure runs once, at the next main-runloop tick.
///
/// `F: Send` because the closure has to cross thread boundaries.
/// `F: 'static` because libdispatch may invoke it after `f`'s scope
/// has ended on the spawner.
///
/// # Example
///
/// ```ignore
/// // From a Tokio worker:
/// dispatch_to_main_thread(|| {
///     // safe to touch AppKit here
///     eprintln!("back on main thread");
/// });
/// ```
pub fn dispatch_to_main_thread<F>(f: F)
where
    F: FnOnce() + Send + 'static,
{
    // Box the closure on the heap, pass the raw pointer as the
    // trampoline's context. The trampoline reclaims the box and
    // executes the closure on the main queue, then drops it.
    let boxed: Box<F> = Box::new(f);
    let ctx: *mut c_void = Box::into_raw(boxed) as *mut c_void;

    // SAFETY:
    // - `_dispatch_main_q` is a known-good libdispatch global on macOS.
    // - `ctx` is a valid Box pointer; the trampoline takes ownership.
    // - The trampoline signature matches `dispatch_function_t`.
    // - `F: Send` ensures crossing threads is sound; `F: 'static`
    //   ensures the captured references outlive the dispatch.
    unsafe {
        dispatch_async_f(
            &_dispatch_main_q as *const c_void,
            ctx,
            trampoline::<F>,
        );
    }
}

extern "C" fn trampoline<F: FnOnce()>(ctx: *mut c_void) {
    // SAFETY: `ctx` is the Box pointer we handed to dispatch_async_f
    // in `dispatch_to_main_thread`. We reconstruct the Box and call
    // the closure exactly once, then let the Box drop normally.
    unsafe {
        let boxed: Box<F> = Box::from_raw(ctx as *mut F);
        (*boxed)();
    }
}
