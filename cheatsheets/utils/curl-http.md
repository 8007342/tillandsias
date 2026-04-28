# curl and wget

@trace spec:agent-source-of-truth

**Version baseline**: curl 8.5.0, wget 1.21.4 (Fedora 43)  
**Use when**: Downloading files, making HTTP requests, testing APIs, or working through proxies

## Provenance

- https://curl.se/docs/ — curl documentation (canonical reference)
- https://www.gnu.org/software/wget/manual/ — wget manual
- **Last updated:** 2026-04-27

## Quick reference

| Task | curl | wget |
|------|------|------|
| Download file | `curl -o file.txt <url>` | `wget -O file.txt <url>` |
| Follow redirect | `curl -L <url>` | Auto |
| Set header | `curl -H "Auth: token"` | `wget --header="Auth: token"` |
| POST data | `curl -d "key=val"` | N/A |
| Auth | `curl -u user:pass <url>` | `wget --user=user --password=pass` |
| Proxy | `curl -x http://proxy:8080 <url>` | `wget -e https_proxy=http://proxy:8080` |
| Timeout | `curl -m 10 <url>` | `wget -T 10` |
| Verbose | `curl -v <url>` | `wget -d <url>` |
| HTTP method | `curl -X PUT <url>` | N/A |
| View headers | `curl -I <url>` | `wget --spider <url>` |

## Common patterns

**Download multiple files in parallel:**
```bash
curl -o image1.jpg https://example.com/1.jpg &
curl -o image2.jpg https://example.com/2.jpg &
wait
```

**POST JSON API request:**
```bash
curl -X POST https://api.example.com/data \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "role": "admin"}'
```

**Download with Bearer token:**
```bash
curl -H "Authorization: Bearer $TOKEN" https://api.example.com/resource
```

**Resume partial download:**
```bash
curl -C - -O https://example.com/large-file.iso
```

**Through proxy with CA (dev):**
```bash
curl --proxy http://proxy:8080 --cacert /path/to/ca.pem https://example.com
```

## Common pitfalls

- **HTTP vs HTTPS proxy**: Use `http://` for HTTP traffic; `https://` only if proxy itself is HTTPS.
- **Bearer token format**: Use `Authorization: Bearer <token>`, not `Authorization: token <token>` (GitHub quirk).
- **SSL verification**: Don't use `-k` (insecure). Use `--cacert file.pem` for custom CAs in proxy scenarios.
- **Redirect loops**: `-L` follows redirects; infinite loops eventually timeout. Add `-m 10` to fail fast.
- **Large file resume**: Broken resume leaves partial file. Best: download to temp, then rename.
- **wget recursive**: `wget -r https://example.com` descends infinitely. Use `-l 1` to limit depth; avoid in scripts.

## See also

- `runtime/networking.md` — Proxy configuration in enclave
- `utils/jq-yq-json.md` — Parse JSON responses with jq
