---
id: postcard-serde
title: Postcard Serialization Format
category: formats/serialization
tags: [postcard, serde, serialization, no_std, binary, ipc]
upstream: https://docs.rs/postcard/latest/postcard/
version_pinned: "1.x"
last_verified: "2026-03-30"
authority: official
---

# Postcard Serialization Format

Postcard is a `#![no_std]`-focused binary serializer/deserializer for Serde. It
targets constrained environments (embedded, IPC) while remaining a drop-in
replacement for any Serde format. As of v1.0 the wire format is stable and
[formally specified](https://postcard.jamesmunns.com/wire-format.html).

## Wire Format Essentials

**Primitive encoding:**

| Type | Encoding |
|---|---|
| `bool` | Single byte (`0x00` / `0x01`) |
| `u8` / `i8` | Single byte, as-is |
| `u16`..`u128`, `usize` | Varint |
| `i16`..`i128`, `isize` | Zigzag + Varint |
| `f32` / `f64` | Little-endian IEEE 754 |
| `char` | Varint of Unicode scalar value |

**Varint encoding:** Little-endian variable-length integers that encode 7 data
bits per byte. The high bit is a continuation flag (1 = more bytes follow).

| Value range | Bytes on wire |
|---|---|
| 0 -- 127 | 1 |
| 128 -- 16,383 | 2 |
| 16,384 -- 2,097,151 | 3 |
| up to `u128::MAX` | max 19 |

**Signed integers** are zigzag-encoded first, storing the sign bit in the LSB.
Values near zero (1, -1, 2, -2, ...) stay compact regardless of sign.

**Collections and strings:** A varint length prefix followed by encoded elements.
Structs are encoded as their fields in order, with no field names or delimiters.
Enum variants use a varint discriminant followed by variant data.

## Core API

```rust
use postcard::{to_vec, to_slice, to_allocvec, from_bytes};
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Msg { id: u32, payload: Vec<u8> }

// Serialize to a Vec (requires `alloc` feature)
let bytes: Vec<u8> = to_allocvec(&msg)?;

// Serialize into a borrowed slice (no alloc, fixed buffer)
let mut buf = [0u8; 128];
let used: &[u8] = to_slice(&msg, &mut buf)?;

// Deserialize
let decoded: Msg = from_bytes(&bytes)?;
```

**`to_vec`** -- serializes to `heapless::Vec<N>` (no alloc, stack-sized).
**`to_allocvec`** -- serializes to `alloc::vec::Vec<u8>` (needs `alloc` feature).
**`to_slice`** -- serializes into a caller-provided `&mut [u8]`.
**`from_bytes`** -- deserializes from `&[u8]`.

All functions return `postcard::Result<T>`.

## Feature Flags

| Feature | Purpose |
|---|---|
| `alloc` | Enables `to_allocvec`, `Vec`-based flavors |
| `heapless` | Enables `to_vec` with `heapless::Vec` |
| `use-std` | Pulls in `std` (implies `alloc`) |
| `experimental-derive` | Derive macros for `postcard-schema` |
| `use-crc` | CRC flavor support via the `crc` crate |

Default: `no_std`-compatible, zero features enabled.

## Flavors (Middleware)

Flavors modify serialized output or deserialized input as a composable pipeline.

### Serialization flavors (`ser_flavors`)

| Flavor | Effect |
|---|---|
| `Slice` | Write into a borrowed `&mut [u8]` |
| `AllocVec` | Write into a growable `Vec<u8>` |
| `HVec` | Write into `heapless::Vec<u8, N>` |
| `Cobs` | Wrap output in COBS framing (zero-delimited) |
| `Crc` | Append a CRC checksum (configurable algorithm) |

Flavors compose: `Cobs<Crc<AllocVec>>` applies CRC then COBS framing.

### Deserialization flavors (`de_flavors`)

| Flavor | Effect |
|---|---|
| `Slice` | Read from `&[u8]` (default) |

Custom flavors implement the `Flavor` trait.

## CRC Checksums

```rust
use postcard::ser_flavors::crc::{CrcModifier, Crc32Inta};

let bytes = postcard::serialize_with_flavor::<_, Crc32Inta, _>(
    &msg,
    CrcModifier::new(Crc32Inta),
)?;
```

The CRC flavor appends a checksum after the serialized data. On deserialization,
the checksum is verified before returning the value. Requires `use-crc` feature.

## Accumulator (Streaming / Chunked Input)

The `CobsAccumulator<N>` collects incoming byte chunks (e.g., from UART or a
socket) and yields complete deserialized messages when a COBS frame boundary
(zero byte) is found.

```rust
use postcard::accumulator::{CobsAccumulator, FeedResult};

let mut acc = CobsAccumulator::<256>::new();

// Feed chunks as they arrive
match acc.feed(chunk) {
    FeedResult::Consumed => { /* need more data */ }
    FeedResult::OverFull(_) => { /* buffer overflow */ }
    FeedResult::DeserError(_) => { /* bad frame */ }
    FeedResult::Success { data, remaining } => {
        let msg: Msg = data;
        // `remaining` holds leftover bytes for the next feed
    }
}
```

Ideal for `no_std` streaming over serial, USB, or pipe-based IPC.

## Schema Evolution and Backward Compatibility

Postcard is **not self-describing**. Messages carry no field names, types, or
version tags. Both sides must share the exact same schema (typically a common
Rust types crate). Consequences:

- **Adding a field** to the end of a struct silently misparses old messages.
- **Removing or reordering fields** breaks deserialization.
- **Adding enum variants** at the end is safe only if old code never sees them.
- **Renaming** fields or variants is wire-compatible (names are not encoded).

**Practical strategies:**

1. **Version header** -- prefix messages with a `u8` version tag; dispatch to
   the correct struct definition per version.
2. **Envelope pattern** -- `enum Msg { V1(MsgV1), V2(MsgV2) }`. Old variants
   stay forever; new code handles all.
3. **Shared types crate** -- keep message definitions in a single crate imported
   by all parties; bump the crate version on any wire change.
4. **`postcard-schema`** -- companion crate that derives a runtime schema from
   types for introspection and compatibility checking (experimental).

If you need built-in forward/backward compatibility, consider `postbag` (a
postcard fork adding optional fields and reordering) or a self-describing format.

## When to Use Postcard

| Scenario | Recommended format |
|---|---|
| Embedded / `no_std` IPC | **Postcard** -- smallest footprint, no alloc needed |
| Low-latency local IPC | **Postcard** -- compact, fast, stable wire format |
| Maximum throughput | Bincode -- fixed-size encoding is ~1.5x faster |
| Maximum compression | MessagePack -- self-describing, smallest on complex data |
| Human-readable / debugging | JSON -- text, universal tooling |
| Cross-language interop | MessagePack or Protobuf -- broad ecosystem support |
| Schema evolution required | Protobuf, FlatBuffers, or `postbag` |

**Size comparison** (typical small struct): Postcard ~41 bytes vs Bincode ~58
bytes vs MessagePack ~37 bytes vs JSON ~100+ bytes. Postcard hits roughly 70%
of Bincode's wire size with comparable speed.

## Common Patterns

**Fixed-size buffer, no allocator:**
```rust
let mut buf = [0u8; 64];
let msg = to_slice(&value, &mut buf)?;
send(msg);
```

**Round-trip test:**
```rust
let bytes = to_allocvec(&original)?;
let decoded: MyType = from_bytes(&bytes)?;
assert_eq!(original, decoded);
```

**COBS-framed stream (embedded UART):**
```rust
use postcard::to_allocvec_cobs;
let frame = to_allocvec_cobs(&msg)?;  // zero-delimited frame
uart.write_all(&frame)?;
```

**Max encoded size (compile-time):**
Use `postcard::experimental::max_size::MaxSize` derive to get a const upper
bound on serialized size -- useful for stack-allocated buffers in `no_std`.

---

*Sources: [docs.rs/postcard](https://docs.rs/postcard/latest/postcard/),
[Postcard Wire Specification](https://postcard.jamesmunns.com/wire-format.html),
[jamesmunns/postcard (GitHub)](https://github.com/jamesmunns/postcard),
[postcard 1.0 announcement](https://jamesmunns.com/blog/postcard-1-0-run/)*
