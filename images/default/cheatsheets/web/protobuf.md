---
tags: [protobuf, proto3, serialization, schema, grpc, wire-format, codegen]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://protobuf.dev/programming-guides/proto3/
  - https://protobuf.dev/programming-guides/encoding/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Protocol Buffers (proto3)

@trace spec:agent-cheatsheets

## Provenance

- Google protobuf.dev — proto3 language guide (field types, field numbers, reserved, well-known types, scalar types, enums, oneofs, maps — the canonical proto3 reference): <https://protobuf.dev/programming-guides/proto3/>
- Google protobuf.dev — encoding reference (wire format, field number ranges 1–15 vs 16–2047, zigzag encoding, packed repeated): <https://protobuf.dev/programming-guides/encoding/>
- **Last updated:** 2026-04-25

**Version baseline**: protoc 3.x (added to forge by `agent-source-of-truth` change). proto3 syntax assumed.
**Use when**: defining wire-format schemas; gRPC services; serialization with strong schema evolution.

## Quick reference

| Construct | Syntax |
|-----------|--------|
| File header | `syntax = "proto3";` (must be first non-comment line) |
| Package | `package my.pkg;` (maps to language namespace/module) |
| Import | `import "other.proto";` / `import public "shim.proto";` |
| Message | `message Foo { string name = 1; int32 n = 2; }` |
| Enum | `enum Status { UNSPECIFIED = 0; OK = 1; ERROR = 2; }` |
| Service (gRPC) | `service S { rpc Get(Req) returns (Resp); }` |
| Streaming RPC | `rpc Watch(Req) returns (stream Event);` (also `stream Req` and bidi) |
| Repeated | `repeated string tags = 3;` (zero or more, ordered) |
| Map | `map<string, int32> counts = 4;` (key must be scalar, not float/bytes) |
| Oneof | `oneof body { string text = 5; bytes blob = 6; }` |
| Reserved | `reserved 2, 4, 9 to 11; reserved "old_name";` |
| Field option | `[deprecated = true]`, `[json_name = "x"]`, `[packed = true]` |

**Scalar types**: `double`, `float`, `int32`, `int64`, `uint32`, `uint64`, `sint32`, `sint64` (zigzag, prefer for negatives), `fixed32`, `fixed64`, `sfixed32`, `sfixed64`, `bool`, `string` (UTF-8), `bytes`.

**Field numbers**: `1`–`15` use 1 wire byte (hot fields go here). `16`–`2047` use 2 bytes. `19000`–`19999` reserved. Max `2^29 - 1`.

**Codegen**:
```
protoc -I=. --go_out=./gen --go_opt=paths=source_relative foo.proto
protoc -I=. --python_out=./gen foo.proto
protoc -I=. --java_out=./gen foo.proto
protoc -I=. --cpp_out=./gen foo.proto
protoc -I=. --go_out=./gen --go-grpc_out=./gen foo.proto    # + gRPC stubs
```

## Common patterns

### Message with nested types
```proto
message Order {
  string id = 1;
  message LineItem { string sku = 1; int32 qty = 2; }
  repeated LineItem items = 2;
  google.protobuf.Timestamp created_at = 3;
}
```
Nest types only used by the parent. Promote to top-level once shared.

### Enum with reserved zero
```proto
enum Color {
  COLOR_UNSPECIFIED = 0;   // mandatory zero, prefix for namespace safety
  COLOR_RED = 1;
  COLOR_GREEN = 2;
  reserved 3;              // tombstone removed value
  reserved "BLUE";         // tombstone removed name
}
```
The `0` must exist and conventionally means "unset". Prefix all values to avoid C++/Java collisions.

### Oneof for tagged unions
```proto
message Event {
  string id = 1;
  oneof payload {
    Login login = 2;
    Logout logout = 3;
    Error error = 4;
  }
}
```
At most one field set; setting another clears the first. Cannot be `repeated` and cannot contain `map`/`repeated` fields directly.

### Repeated and map
```proto
message Bag {
  repeated int32 ids = 1 [packed = true];   // packed default in proto3 for scalars
  map<string, Item> items = 2;              // sugar for repeated KV message
}
```
`map` is unordered, no nulls, key must be integral or string. Forbidden inside `oneof`.

### gRPC service
```proto
service Greeter {
  rpc SayHello(HelloRequest) returns (HelloReply);                  // unary
  rpc StreamFacts(Query) returns (stream Fact);                     // server stream
  rpc UploadLogs(stream LogChunk) returns (UploadAck);              // client stream
  rpc Chat(stream Msg) returns (stream Msg);                        // bidi
}
```
Codegen: `protoc --go-grpc_out=. svc.proto` (Go) or `python -m grpc_tools.protoc ...` (Python).

### Well-known types
```proto
import "google/protobuf/timestamp.proto";
import "google/protobuf/duration.proto";
import "google/protobuf/any.proto";
import "google/protobuf/struct.proto";   // dynamic JSON-like

message Job {
  google.protobuf.Timestamp scheduled_at = 1;
  google.protobuf.Duration timeout = 2;
  google.protobuf.Any opaque_payload = 3;
}
```
Prefer well-known types over hand-rolled equivalents — every language plugin maps them to native types.

## Common pitfalls

- **Field numbers are immutable once published** — wire format is `(number, wire_type, value)`. Renumbering silently mis-deserializes old data. Always `reserved` the old number when removing a field.
- **proto3 default values are not on the wire** — a scalar set to its zero value (`0`, `""`, `false`) is indistinguishable from unset. If you need explicit "field was set to zero", wrap in `google.protobuf.Int32Value` etc., or use `optional` (re-added in protoc 3.15+ — emits `has_x()` accessors).
- **Tag renumbering breaks compatibility** — even rearranging fields in source is fine, but changing a field's `= N` is a breaking change. Treat tags like database column IDs.
- **Removing a `required` field** — proto3 has no `required`, but if you ported from proto2, dropping a required field crashes old readers. Always migrate via `optional` first, deploy readers, then remove.
- **Enum value 0 must exist** — proto3 mandates a zero value (conventionally `*_UNSPECIFIED`). Missing zero = code generation error in some plugins, runtime "unknown value 0" in others.
- **Enum values are global in C++ and Java** — `enum Color { RED = 1; }` and `enum Mood { RED = 1; }` collide unless prefixed (`COLOR_RED`, `MOOD_RED`). Always prefix.
- **Language plugins install separately** — `protoc` ships only the core. You need `protoc-gen-go`, `protoc-gen-go-grpc`, `grpcio-tools` (Python), `protobuf-java`, etc. Plugin must be on `$PATH` as `protoc-gen-<name>` for `--<name>_out` to work.
- **Unknown fields are preserved by default in proto3** — since 3.5, parsers round-trip unknown fields. Older 3.0–3.4 silently dropped them. Pin protoc ≥ 3.5 if you do proxy/relay services.
- **`map` field iteration order is undefined** — never assume insertion order. For deterministic serialization (signing, hashing), copy entries into a sorted `repeated` of KV messages.
- **`Any` requires `type_url` resolution** — packing with `Any.Pack(msg)` writes a URL like `type.googleapis.com/my.pkg.Foo`; unpacking needs the descriptor registered. Plain JSON marshalling will fail without a type registry.
- **`bytes` vs `string`** — `string` validates UTF-8 and rejects malformed input at decode time. Use `bytes` for any non-text payload (hashes, encrypted blobs, file contents) — even if it "looks like text".
- **`json_name` option ≠ JSON field name in all langs** — proto3 JSON mapping uses lowerCamelCase by default; `[json_name = "snake_case"]` overrides it, but some older plugins ignore the hint. Test round-trip with `protoc --decode_raw` or `buf convert`.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://protobuf.dev/programming-guides/proto3/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/protobuf.dev/programming-guides/proto3/`
- **License:** see-license-allowlist
- **License URL:** https://protobuf.dev/programming-guides/proto3/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/protobuf.dev/programming-guides/proto3/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://protobuf.dev/programming-guides/proto3/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/web/protobuf.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `web/grpc.md` — most common protobuf use case; service stubs, streaming, status codes
- `languages/json.md` — alternative wire format; protobuf JSON mapping converts between the two
- `runtime/forge-container.md` — why internal Tillandsias IPC uses `postcard` (Rust-only) instead of protobuf
