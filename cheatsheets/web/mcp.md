# Model Context Protocol (MCP) Quick Reference

**Use when**: Implementing MCP servers, debugging MCP client/server communication, or extending tool surfaces.

## Provenance

- https://modelcontextprotocol.io/specification/2025-06-18 — canonical protocol specification
- https://modelcontextprotocol.io/specification/2025-06-18/server/tools — tool definition schema
- **Last updated:** 2026-04-27

## Overview

MCP is a JSON-RPC 2.0 protocol for bidirectional communication between clients (AI models) and servers (tools). Transport is transport-agnostic; Tillandsias uses **newline-delimited JSON over stdio**.

@trace spec:host-browser-mcp

## JSON-RPC 2.0 Framing

Every message is a **single-line JSON object** followed by `\n`:

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}\n
```

No multi-line JSON. No empty lines. No preamble. The receiving side reads line-by-line.

### Request Structure
```json
{
  "jsonrpc": "2.0",
  "id": <uint64>,
  "method": "<method_name>",
  "params": { /* method-specific */ }
}
```

- `id` is required; client expects a response with matching `id`.
- `method` is required; must be one of the defined RPC methods.
- `params` is a JSON object; may be empty `{}`.

### Response Structure (Success)
```json
{
  "jsonrpc": "2.0",
  "id": <uint64>,
  "result": { /* method-specific */ }
}
```

### Response Structure (Error)
```json
{
  "jsonrpc": "2.0",
  "id": <uint64>,
  "error": {
    "code": <int>,
    "message": "<string>"
  }
}
```

## Error Codes

| Code | Meaning | Example |
|---|---|---|
| `-32700` | Parse error | Invalid JSON in request |
| `-32600` | Invalid request | Missing required field |
| `-32601` | Method not found | `method: "foo"` not implemented |
| `-32602` | Invalid params | `params` do not match schema |
| `-32603` | Internal error | Server crash / unexpected condition |
| `-32000` to `-32099` | Server-defined | Use for domain-specific errors |

**Critical**: Return `-32601 Method not found` for any `method` not in your server's capability list. Do NOT return generic "internal error".

## Core MCP Methods (Server Perspective)

### `initialize`
**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": { "name": "...", "version": "..." }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": {}
    },
    "serverInfo": {
      "name": "tillandsias-browser-mcp",
      "version": "0.1.0"
    }
  }
}
```

The client may not call any other method until `initialize` succeeds.

### `tools/list`
**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "browser.open",
        "description": "Open a browser window...",
        "inputSchema": {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "..." }
          },
          "required": ["url"]
        }
      }
    ]
  }
}
```

**CRITICAL**: Always return an array, even if empty. A missing `tools/list` response causes Claude to hang for 60 seconds (per the git-tools.sh lesson).

### `tools/call`
**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "browser.open",
    "arguments": {
      "url": "https://example.com"
    }
  }
}
```

**Response (Success):**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Window opened with id: 42"
      }
    ]
  }
}
```

**Response (Tool Error):**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Error: URL_NOT_ALLOWED"
      }
    ],
    "isError": true
  }
}
```

Tool errors return HTTP 200 with `isError: true` (not JSON-RPC error). This signals "the tool ran, but the user's input was rejected" (e.g., allowlist deny).

### `prompts/list`
**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "prompts/list",
  "params": {}
}
```

**Response (No Prompts):**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "prompts": []
  }
}
```

Return an empty array if your server provides no custom prompts.

### `resources/list` & `resources/templates/list`
Same pattern as `prompts/list` — return empty array if not implemented.

### `notifications/initialized`
**Sent by client after `initialize` succeeds:**
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized",
  "params": {}
}
```

No `id` field (it's a notification, not a request). The server reads this but does not respond.

## Concurrency Notes

- MCP is **single-threaded on the wire** (requests are processed in order).
- The server may spawn internal background tasks, but `tools/call` responses must serialize over the single stdout stream.
- **No pipelining**: the client waits for response with matching `id` before sending the next request with a new `id`.

## Timeouts

- **Per-tool call**: 30 seconds (MCP client side, typically Claude). Tillandsias tools target <2 seconds (per design.md).
- **Per-RPC call overhead**: 100 ms for framing + serialization.

## Example Session

```
Client sends (id=1):
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Claude","version":"v0"}}}\n

Server responds (id=1):
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"tillandsias-browser-mcp","version":"0.1.0"}}}\n

Client sends (no id, notification):
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}\n

Client sends (id=2):
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n

Server responds (id=2):
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"browser.open",...}]}}\n

Client sends (id=3):
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser.open","arguments":{"url":"http://web.project.localhost:8080"}}}\n

Server responds (id=3):
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Window 123 opened"}]}}\n
```
