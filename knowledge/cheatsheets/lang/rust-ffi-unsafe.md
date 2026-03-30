---
id: rust-ffi-unsafe
title: Rust FFI & Unsafe Code
category: lang/rust
tags: [rust, ffi, unsafe, libc, pre_exec, cstring, ub]
upstream: https://doc.rust-lang.org/nomicon/
version_pinned: "1.85"
last_verified: "2026-03-30"
authority: official
---

# Rust FFI & Unsafe Code

## The Five Unsafe Superpowers

An `unsafe` block unlocks exactly five capabilities the borrow checker cannot verify:

1. **Dereference raw pointers** (`*const T`, `*mut T`)
2. **Call unsafe functions** (including `extern` FFI functions)
3. **Access or modify mutable statics**
4. **Implement unsafe traits** (e.g., `Send`, `Sync` manually)
5. **Access fields of `union`s**

Everything else (casts, integer arithmetic, indexing via `.get_unchecked()`) is
governed by these five. `unsafe` does NOT disable the borrow checker for
references — it only opens these doors.

```rust
let ptr: *const i32 = &42;
let val = unsafe { *ptr }; // (1) deref raw pointer
```

## FFI Basics

### Declaring Foreign Functions

```rust
extern "C" {
    fn close(fd: libc::c_int) -> libc::c_int;
    fn write(fd: libc::c_int, buf: *const libc::c_void, count: libc::size_t) -> libc::ssize_t;
}
```

All functions inside `extern "C"` are implicitly `unsafe` to call.

### Exporting Rust to C

```rust
#[no_mangle]
pub extern "C" fn my_init() -> libc::c_int {
    0
}
```

- `extern "C"` — use the C calling convention.
- `#[no_mangle]` — emit the symbol name as-is (no Rust name mangling).
- `#[repr(C)]` on structs to guarantee C-compatible memory layout.

## CString and CStr

| Type | Owned? | Null-terminated? | Use case |
|------|--------|-------------------|----------|
| `CString` | Yes | Yes | Rust-owned string passed to C |
| `CStr` | No (borrowed) | Yes | Borrowed view of a C string |
| `&str` / `String` | — | No | Never pass directly to C |

### Rust to C

```rust
use std::ffi::CString;
let s = CString::new("/tmp/file")?;  // Err if input contains \0
unsafe { libc::open(s.as_ptr(), libc::O_RDONLY) };
// s must outlive the pointer — do NOT drop it early
```

### C to Rust

```rust
use std::ffi::CStr;
unsafe {
    let c_buf: *const libc::c_char = get_name();
    let name: &str = CStr::from_ptr(c_buf).to_str()?;
}
```

**Lifetime rule**: the `&CStr` borrows from the pointer's memory. If C frees
that memory, the reference dangles. Copy into a `String` if you need ownership.

## The `libc` Crate

Provides raw bindings to platform C types and POSIX functions.

```rust
// Common types
libc::c_int, libc::c_char, libc::c_void, libc::size_t, libc::pid_t, libc::mode_t

// Common functions
libc::open, libc::close, libc::read, libc::write,
libc::stat, libc::fstat, libc::kill, libc::waitpid,
libc::fork, libc::execvp, libc::dup2, libc::pipe
```

Always check return values. Convention: `-1` means error, check `errno` via
`std::io::Error::last_os_error()`.

## pre_exec Hooks (CommandExt)

```rust
use std::os::unix::process::CommandExt;

let mut cmd = std::process::Command::new("child");
unsafe {
    cmd.pre_exec(|| {
        // Runs after fork(), before exec(), in the CHILD process.
        libc::setsid();
        Ok(())
    });
}
cmd.spawn()?;
```

**Critical constraints** — the closure runs between `fork()` and `exec()`:

- **Async-signal-safe only.** No heap allocation (`malloc`), no `println!`,
  no mutex locks, no logging. The parent's heap is copy-on-write and mutexes
  may be in locked state.
- **Safe functions**: `close`, `dup2`, `setsid`, `setpgid`, `sigprocmask`,
  `open`, `write` (to known fds).
- `pre_exec` is `unsafe` because violating async-signal-safety is UB.
- Returning `Err` causes `spawn()` to return an error; the child calls `_exit`.

## Undefined Behavior Catalog

Any of these make your program's behavior completely unpredictable:

| UB | Example |
|----|---------|
| **Dangling reference** | Use-after-free, reference outlives data |
| **Data race** | Two threads access same data, at least one writes, no synchronization |
| **Invalid values** | `bool` that is not 0 or 1, `char` outside Unicode scalar range, null `&T` |
| **Aliasing violation** | `&T` and `&mut T` to same data simultaneously |
| **Misaligned access** | `*const u32` pointing to odd address |
| **Unwinding into C** | Rust panic crossing an `extern "C"` boundary (use `catch_unwind` or `extern "C-unwind"`) |
| **Breaking `unsafe` invariants** | Constructing invalid `Vec` from raw parts, wrong length/capacity |
| **Out-of-bounds access** | `ptr::read`/`ptr::write` beyond allocation |

## Soundness

An `unsafe` API is **sound** if no combination of safe code calling it can
trigger UB. The unsafe block's author bears the proof burden.

```rust
// SOUND: caller can't break invariants
pub fn get(slice: &[i32], idx: usize) -> Option<&i32> {
    if idx < slice.len() {
        Some(unsafe { slice.get_unchecked(idx) })
    } else {
        None
    }
}

// UNSOUND: safe caller can pass any idx
pub fn get_fast(slice: &[i32], idx: usize) -> &i32 {
    unsafe { slice.get_unchecked(idx) }
}
```

**Rule of thumb**: if your public API is safe, the `unsafe` inside must be
unconditionally correct for all inputs. If you cannot guarantee that, mark
the function `unsafe fn` and document the safety contract with `# Safety`.

## Common Patterns

### Wrapping a C Library

```rust
pub struct Handle(*mut ffi::opaque_t);  // raw pointer, not Send/Sync

impl Handle {
    pub fn open(path: &str) -> Result<Self> {
        let c_path = CString::new(path)?;
        let ptr = unsafe { ffi::lib_open(c_path.as_ptr()) };
        if ptr.is_null() { return Err(last_error()); }
        Ok(Handle(ptr))
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { ffi::lib_close(self.0); }
    }
}
```

### Callback FFI

```rust
extern "C" fn on_event(ctx: *mut libc::c_void, code: libc::c_int) {
    let closure: &mut Box<dyn FnMut(i32)> = unsafe { &mut *(ctx as *mut _) };
    closure(code as i32);
}

pub fn register(mut callback: Box<dyn FnMut(i32)>) {
    let ctx = &mut callback as *mut _ as *mut libc::c_void;
    unsafe { ffi::set_callback(Some(on_event), ctx); }
    std::mem::forget(callback); // prevent drop — C owns the lifetime now
}
```

Prevent the callback from being dropped while C holds the pointer. Arrange
cleanup when the C library signals it is done.

## Miri for UB Detection

[Miri](https://github.com/rust-lang/miri) is an interpreter that detects UB at
runtime in test code.

```bash
rustup +nightly component add miri
cargo +nightly miri test            # run test suite under Miri
cargo +nightly miri run             # run binary under Miri
```

Miri catches: out-of-bounds access, use-after-free, invalid values, alignment
violations, data races (with `-Zmiri-preemption-rate=0.1`), Stacked Borrows /
Tree Borrows violations.

**Limitations**: Miri cannot execute actual FFI calls (syscalls, C libraries).
Provide mocks or use `#[cfg(miri)]` to skip those code paths.
