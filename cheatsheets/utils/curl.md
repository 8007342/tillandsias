# curl

@trace spec:agent-cheatsheets

**Version baseline**: curl 8.x (Fedora 43).
**Use when**: HTTP from the shell. In the forge, curl auto-uses `HTTPS_PROXY` env var.

## Provenance

- curl man page (official): <https://curl.se/docs/manpage.html> — complete flag reference including `-f`, `-s`, `-S`, `-L`, `-o`, `-w`, `-H`, `--data`, `--json`, `--form`, `--resolve`
- curl project documentation index: <https://curl.se/docs/> — feature documentation and release notes
- **Last updated:** 2026-04-25

Verified against curl 8.20.0 man page: `-f`/`--fail` exits 22 on HTTP ≥400 (confirmed); `--json` sets `Content-Type: application/json` + `Accept: application/json` and implies POST (added in 7.82.0); `-fsSL` idiom flags work as documented individually.

## Quick reference

| Flag | Effect |
|---|---|
| `-X <METHOD>` | HTTP method (GET, POST, PUT, DELETE, PATCH). Without `--data`, `-X POST` still sends an empty GET-shaped body. |
| `-H 'Header: value'` | Add request header. Repeatable. `-H 'Header;'` sends an empty header; `-H 'Header:'` removes a default. |
| `--data 'k=v&k2=v2'` | POST body, `Content-Type: application/x-www-form-urlencoded` by default. Implies `-X POST`. |
| `--data-raw '...'` | Like `--data` but no `@file` interpretation. |
| `--data-binary @file` | Send file as-is (no newline stripping). Use for JSON, binary uploads. |
| `--json '{"k":1}'` | Shortcut: sets `Content-Type` + `Accept: application/json`, POSTs body. (curl 7.82+) |
| `--form 'field=value'` / `--form 'file=@path'` | `multipart/form-data`. Use `@` to attach a file. |
| `-L` | Follow redirects (3xx). Off by default. |
| `-f` | Fail (exit 22) on HTTP ≥400 — body suppressed. **Critical for scripts.** |
| `-s` | Silent: hide progress bar + errors. Pair with `-S` to keep errors visible. |
| `-fsSL` | The standard "fetch a script" idiom: fail-on-error, silent, show-errors, follow-redirects. |
| `-o <file>` / `-O` | Write body to file. `-O` uses URL's basename. |
| `-i` / `-I` | Include headers in output (`-i`) or HEAD-only (`-I`). |
| `-w '%{http_code}\n'` | Print formatted summary after transfer (status, time, size). |
| `--resolve host:port:ip` | Override DNS for one host. Useful for testing before DNS cuts over. |
| `-k` / `--insecure` | Skip TLS verification. Last resort — fix `SSL_CERT_FILE` instead. |
| `--proxy http://host:port` | Override `HTTPS_PROXY` env var for one call. |

## Common patterns

### Pattern 1 — fetch and execute a remote script

```bash
curl -fsSL https://example.com/install.sh | bash
```

`-fsSL` is the canonical idiom: fails fast on HTTP error, silent except for errors, follows redirects. Without `-f`, a 404 page would be piped to bash.

### Pattern 2 — POST JSON

```bash
curl -fsS -X POST https://api.example.com/items \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer '"$TOKEN" \
  --data '{"name":"foo","count":3}'

# curl 7.82+: equivalent shorthand
curl -fsS --json '{"name":"foo","count":3}' https://api.example.com/items
```

### Pattern 3 — multipart upload

```bash
curl -fsS -X POST https://api.example.com/upload \
  --form 'meta={"kind":"image"};type=application/json' \
  --form 'file=@./photo.jpg;type=image/jpeg'
```

`@path` reads the file; `;type=` overrides MIME. Use `<path` to inline file *contents* as a normal field.

### Pattern 4 — get only the HTTP status

```bash
status=$(curl -s -o /dev/null -w '%{http_code}' https://example.com/health)
[[ "$status" == "200" ]] || exit 1
```

`-w` formats are documented in `man curl` (`time_total`, `size_download`, `redirect_url`, etc.).

### Pattern 5 — pretend a host resolves elsewhere

```bash
curl -fsSL --resolve example.com:443:10.0.0.5 https://example.com/
```

Tests a new server before flipping DNS, or routes around a misbehaving record. No `/etc/hosts` edit required.

## Common pitfalls

- **`-X POST` without `--data` sends an empty body** — and many servers respond as if it were a GET. Always pair with `--data`/`--json`/`--form` or use `--request POST -H 'Content-Length: 0'` if you really mean "empty POST".
- **`--data` URL-encodes** — sending JSON via plain `--data '{"k":1}'` works for most servers but the default `Content-Type` is `application/x-www-form-urlencoded`. Always set `-H 'Content-Type: application/json'` or use `--json`.
- **Missing `-L` on redirected URLs** — many CDNs and shorteners respond `301`/`302`. Without `-L`, curl prints the redirect body (often empty) and exits 0. Scripts then fail downstream with confusing errors.
- **`-i` mixes headers and body in stdout** — fine for humans, breaks `jq`/`grep` pipelines. Use `-D - -o body.txt` or `-w` instead when scripting.
- **Exit 0 on HTTP 500 without `-f`** — by default curl considers any *transport-level success* a win. A 500 response body is happily written to your output file. **Always use `-f` (or `--fail-with-body` in 7.76+) in scripts.**
- **`--data @file` strips newlines** — use `--data-binary @file` for JSON files or anything where newlines matter.
- **`-s` hides real errors too** — pair with `-S` (`-sS`) so transport failures still surface. The `-fsSL` idiom does this correctly.
- **`-k` masks a real cert problem** — in the forge, the right fix is to point at the proxy CA via `SSL_CERT_FILE`, not to disable verification.

## Forge-specific

- `HTTPS_PROXY=http://proxy:3128` is exported by entrypoint — direct internet egress goes through Squid. curl picks it up automatically; no `--proxy` needed.
- `SSL_CERT_FILE` points at the proxy's CA bundle (`/etc/ssl/certs/ca-bundle.crt`). curl honours it without extra flags.
- For per-call bypass of the proxy (e.g., calling `inference:11434`), the address is in `NO_PROXY` already — nothing to do.
- Long downloads (`ollama pull`-class) through Squid 6 may EOF mid-stream. Pre-pull on the host where possible. See `runtime/networking.md`.

## See also

- `runtime/networking.md` — proxy + cert details, enclave addressing
- `utils/gh.md` — for GitHub specifically (auth + rate limits handled for you)
