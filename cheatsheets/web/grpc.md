# gRPC

@trace spec:agent-cheatsheets

**Version baseline**: gRPC concepts language-agnostic. grpcurl 1.9+ added by `agent-source-of-truth` change.
**Use when**: building service-to-service RPC with strict schemas, streaming, or bidirectional comms.

## Quick reference

| Item | Notes |
|---|---|
| **Unary** | One request, one response. The "REST-like" RPC. |
| **Server-streaming** | One request, stream of responses. Good for feeds, tailing logs. |
| **Client-streaming** | Stream of requests, one response. Good for bulk uploads with a final summary. |
| **Bidirectional** | Independent request + response streams over one HTTP/2 connection. |
| **Metadata** | `key: value` pairs (like HTTP headers). `-bin` suffix marks binary values. Sent in initial + trailing headers. |
| **Deadlines** | Client sends `grpc-timeout` header; server should propagate to downstream calls. Cancellation flows from client → server automatically on channel close. |
| **Status codes** | `OK`, `CANCELLED`, `INVALID_ARGUMENT`, `DEADLINE_EXCEEDED`, `NOT_FOUND`, `PERMISSION_DENIED`, `UNAUTHENTICATED`, `RESOURCE_EXHAUSTED`, `FAILED_PRECONDITION`, `UNAVAILABLE`, `INTERNAL`, `UNIMPLEMENTED`. **Numeric, not HTTP.** |
| `grpcurl -plaintext host:port list` | List services via reflection (no `.proto` needed). |
| `grpcurl -plaintext -d '{...}' host:port pkg.Svc/Method` | Invoke unary RPC with JSON-encoded request. |
| `grpcurl -import-path . -proto svc.proto …` | Use local `.proto` when reflection is off. |

## Common patterns

### Pattern 1 — unary call with grpcurl

```bash
grpcurl -plaintext \
  -d '{"name":"world"}' \
  localhost:50051 helloworld.Greeter/SayHello
```

JSON keys map to proto field names (camelCase). Use `-plaintext` only against trusted local endpoints.

### Pattern 2 — discover services via reflection

```bash
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 list helloworld.Greeter
grpcurl -plaintext localhost:50051 describe helloworld.HelloRequest
```

Reflection is the fastest way to explore an unknown gRPC server. Often disabled in production — fall back to `-proto` with the `.proto` file.

### Pattern 3 — TLS + auth metadata

```bash
grpcurl \
  -cacert ca.pem \
  -H 'authorization: Bearer '"$TOKEN" \
  -H 'x-request-id: '"$(uuidgen)" \
  -d '{"id":"abc"}' \
  api.example.com:443 svc.Service/Get
```

Drop `-plaintext` to enable TLS. Use `-insecure` only for self-signed in dev. `-H` repeats for multiple metadata entries.

### Pattern 4 — server-streaming consumption

```bash
grpcurl -plaintext \
  -d '{"topic":"events"}' \
  localhost:50051 feed.Feed/Subscribe
```

grpcurl prints each response message as JSON, separated by newlines. Use `| jq -c` for line-delimited processing. Ctrl-C cancels the stream cleanly.

### Pattern 5 — deadline + cancellation

```bash
grpcurl -plaintext \
  -max-time 5 \
  -d '{"query":"slow"}' \
  localhost:50051 search.Search/Query
```

`-max-time` sets the client deadline. Servers receive `grpc-timeout` and SHOULD honor it. In code (Go/Rust/Python), use `context.WithTimeout` / `tokio::time::timeout` / `asyncio.wait_for` and pass the context through to downstream calls so the deadline propagates.

## Common pitfalls

- **HTTP/2 required, no HTTP/1.1 fallback** — gRPC depends on HTTP/2 trailers. Load balancers, proxies, and ingresses must speak HTTP/2 end-to-end. AWS ALB, older nginx, and most "transparent" L7 proxies will silently break it.
- **gRPC status codes are NOT HTTP status codes** — a gRPC call returning `NOT_FOUND` (5) still uses HTTP 200 at the transport layer. Don't write monitoring that alerts on HTTP 5xx for gRPC errors; inspect the `grpc-status` trailer instead.
- **Metadata key case is normalized, value case is preserved** — `Authorization` and `authorization` are the same key, but `Bearer xyz` and `bearer xyz` are different values. Some servers reject mixed-case keys; lowercase everything to be safe.
- **Deadlines do not propagate automatically across services** — if service A calls B which calls C, B must explicitly forward the incoming context/deadline to C. Forgetting this is the #1 cause of cascading timeouts and dangling work.
- **gRPC-Web requires a proxy** — browsers cannot speak native gRPC (no HTTP/2 trailer access from `fetch`). You need Envoy with the `grpc_web` filter, `grpcwebproxy`, or a server-side gRPC-Web handler. Plain gRPC clients in the browser do not exist.
- **Reflection is often disabled in production** — `grpcurl list` will return `UNIMPLEMENTED`. Keep the `.proto` files handy and use `-import-path . -proto svc.proto` to invoke without reflection.
- **Keepalives needed across NATs / load balancers** — idle gRPC connections get silently dropped after a few minutes by most middleboxes. Configure client keepalive (`KEEPALIVE_TIME_MS`) or expect `UNAVAILABLE` errors on the first call after an idle period.
- **Large messages need explicit limits** — default max message size is 4 MiB on most clients. Streaming many small messages is almost always better than one large one; if you must, raise `MaxRecvMsgSize` / `max_receive_message_length` on both ends.

## See also

- `web/protobuf.md` — schema definition (the `.proto` files gRPC uses)
- `utils/curl.md` — for HTTP/REST alternatives when gRPC is overkill
