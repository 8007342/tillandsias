---
tags: [browser, networking, optimization]
languages: []
since: 2026-05-03
last_verified: 2026-05-03
sources:
  - internal
authority: internal
status: draft
tier: bundled
---

# Request Rate Limiting

@trace spec:browser-debounce

**Use when**: Understanding request debouncing and rate limiting in browser isolation.

## Provenance

- Internal documentation
- **Last updated:** 2026-05-03

## Rate Limiting Strategy

Browser requests are debounced to prevent:
- Excessive proxy load
- Network saturation
- Container resource exhaustion

Rate limiting is applied at:
- Proxy level (Squid cache peer)
- Browser container level (request coalescing)
- API level (backoff on rate-limit headers)

## See Also

- `cheatsheets/runtime/browser-isolation.md`
- `cheatsheets/runtime/networking.md`
