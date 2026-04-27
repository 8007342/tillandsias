# Rust

@trace spec:agent-cheatsheets

## Provenance

- The Rust Programming Language book (official): <https://doc.rust-lang.org/book/> — ownership, borrowing, lifetimes, Result/?, match, closures, iterators, async/await, traits, generics
  local: `cheatsheet-sources/doc.rust-lang.org/book`
- Rust Reference: <https://doc.rust-lang.org/reference/> — normative language spec; let-else, const/static, visibility (pub/pub(crate)/pub(super)), integer overflow behavior
  local: `cheatsheet-sources/doc.rust-lang.org/reference/index.html`
- Rust std library documentation: <https://doc.rust-lang.org/std/> — Box, Arc, Rc, String, str, Iterator, Result, Option
  local: `cheatsheet-sources/doc.rust-lang.org/std`
- **Last updated:** 2026-04-25

**Version baseline**: Rust 1.83+ (Fedora 43 `rust` package), edition 2024
**Use when**: writing Rust in the forge — syntax, ownership idioms, common stdlib.

## Quick reference

| Concept | Syntax |
|---|---|
| Immutable / mutable binding | `let x = 1;` / `let mut x = 1;` |
| Const / static | `const N: u32 = 4;` / `static G: &str = "g";` |
| Function | `fn name(a: T) -> R { ... }` |
| Struct / tuple struct | `struct S { f: T }` / `struct W(T);` |
| Enum with data | `enum E { A, B(u32), C { x: u8 } }` |
| Trait def / impl | `trait T { fn m(&self); }` / `impl T for S { ... }` |
| Generics + bounds | `fn f<T: Clone + Send>(x: T)` or `where T: Clone` |
| Module / use | `mod foo;` / `use crate::foo::Bar;` |
| Visibility | `pub`, `pub(crate)`, `pub(super)` |
| Match | `match v { Some(x) => x, None => 0 }` |
| Closure | `\|x\| x + 1` / `move \|x\| x + 1` |
| Range / slice | `0..n`, `0..=n`, `&v[..]`, `&s[1..3]` |
| Error propagation | `let n = parse(s)?;` |
| String types | `&str` (borrowed) vs `String` (owned) |
| Box / Arc / Rc | heap / atomic-shared / single-thread shared |
| Async fn | `async fn f() -> T { ... .await }` |

## Common patterns

### Pattern 1 — Result and the `?` operator

```rust
fn parse_port(s: &str) -> Result<u16, std::num::ParseIntError> {
    s.parse()
}

fn load() -> std::io::Result<String> {
    let s = std::fs::read_to_string("config")?;
    Ok(s.trim().to_owned())
}
```

### Pattern 2 — Ownership and borrowing

```rust
fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.len() >= b.len() { a } else { b }
}

let s = String::from("hi");
let r: &str = &s;       // borrow
println!("{r} {s}");    // s still owned
```

### Pattern 3 — Iterator chains (lazy, allocation-free until collect)

```rust
let evens_squared: Vec<u32> = (1..=10)
    .filter(|n| n % 2 == 0)
    .map(|n| n * n)
    .collect();
```

### Pattern 4 — Common derives

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
struct Tag { name: String, score: u32 }

#[derive(Debug, thiserror::Error)]
enum MyErr {
    #[error("io: {0}")] Io(#[from] std::io::Error),
}
```

### Pattern 5 — `let-else` and async with tokio

```rust
fn first_word(s: &str) -> &str {
    let Some((head, _)) = s.split_once(' ') else { return s };
    head
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (a, b) = tokio::join!(fetch("/a"), fetch("/b"));
    println!("{} / {}", a?, b?);
    Ok(())
}

async fn fetch(_path: &str) -> anyhow::Result<String> { Ok(String::new()) }
```

## Common pitfalls

- **Returning a reference to a local** — `fn f() -> &str { let s = String::new(); &s }` won't compile; return `String` or take a borrow as input and return one tied to it via lifetimes.
- **`&str` vs `String` confusion** — APIs should accept `&str` (or `impl AsRef<str>`); only return `String` when ownership transfer is intentional. Calling `.to_string()` on every argument is a code smell.
- **Mutable + immutable borrow overlap** — `let r = &v[0]; v.push(x); println!("{r}");` fails because `push` may reallocate. Finish reading before mutating, or clone the value out.
- **Async lifetime traps** — async fns capture all referenced borrows for the entire future lifetime. Holding `&MutexGuard` across `.await` deadlocks; drop guards before awaiting (`drop(guard);`).
- **Missing `Send`/`Sync` bounds for `tokio::spawn`** — futures spawned on the multi-threaded runtime must be `Send + 'static`. `Rc`, `RefCell`, and raw `*mut` break this; use `Arc` and `Mutex`/`RwLock`.
- **`unwrap()` / `expect()` in production code** — only acceptable in tests, examples, or proven-unreachable branches with a comment. Prefer `?` propagation and typed errors.
- **Iterator double-consumption** — `for x in &iter { ... } for x in &iter { ... }` works on a collection but not on an iterator value (consumed). Re-create or `.clone()` the iterator.
- **Integer overflow in release** — debug panics, release wraps silently. Use `checked_*` / `saturating_*` / `wrapping_*` when input is untrusted.

## See also

- `build/cargo.md` — cargo build/test/check/clippy
- `test/cargo-test.md` — test discovery + workspace + integration
- `runtime/forge-container.md` — `target/` lives in per-project workspace; ephemeral
