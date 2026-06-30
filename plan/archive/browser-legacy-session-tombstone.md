# browser/legacy-session-tombstone

**Task**: Retire the old webview-based session spec, superseded by OTP authentication flow.

**Status**: Completed 2026-05-14

## Summary

The original `opencode-web-session` specification (webview-based approach) has been formally retired and replaced by the new `opencode-web-session-otp` specification, which provides cryptographically-sound session authentication via one-time passwords.

## Timeline

- **2026-05-02**: `browser-isolation-tray-integration` spec introduced native Chromium-based browser isolation
- **2026-04-27**: `opencode-web-session-otp` spec created with OTP authentication layer (archived change 2026-04-27-opencode-web-session-otp)
- **2026-05-14**: Legacy spec formally retired with tombstone annotations

## Migration Path

### Old Approach (Deprecated)

The old spec described a webview-based session model:
- Embedded Tauri webview rendering OpenCode Web
- Per-project persistent web containers on localhost-only ports
- Simple host-port bindings, no authentication layer
- Vulnerable to compromised browser extensions and sibling processes

**Location**: `openspec/specs/opencode-web-session/spec.md`

### New Approach (Active)

The new spec (`opencode-web-session-otp`) provides:
- Native Chromium browser isolation (security boundary between browser and OS)
- Per-attach one-time-password (OTP) generation via OS CSPRNG
- OTP never touches disk; embedded in data: URI and auto-submitted
- Router-side validation and independent session cookie issuance
- Defence-in-depth: loopback-only bind + OTP layer + HttpOnly cookies
- Multi-window reattachment with independent cookies per window

**Location**: `openspec/specs/opencode-web-session-otp/spec.md`

**Architectural Benefits**:
1. **Cryptographic strength** — OTP uses OS CSPRNG (getrandom), not derivable from environment
2. **Single-use token** — OTP is evicted immediately after first validation, non-replayable
3. **Separation of concerns** — OTP and session cookie are independent random values
4. **Defence in depth** — Even if OTP is compromised after consumption, it cannot be replayed or yield the session token

## Code References

One reference to the old spec found in active code:

- `crates/tillandsias-browser-mcp/src/allowlist.rs:3` — `@trace spec:opencode-web-session`
  - **Status**: Left as-is (still valid context for allowlist behavior, which applies to both old and new flows)
  - **Rationale**: The URL allowlist enforcement is independent of the session authentication mechanism

## Binding Updates

**Old spec binding** (`openspec/litmus-bindings.yaml`):
- Changed `last_verified` from 2026-05-13 to 2026-05-14
- Added `tombstone: superseded:opencode-web-session-otp` field

**New spec binding** (unchanged):
- `spec_id: opencode-web-session-otp`
- `status: active`
- `litmus_tests: [litmus:credential-isolation]`
- `coverage_ratio: 30`

## Retention Policy

Per the `@tombstone` methodology (CLAUDE.md):

- **Last live in**: v0.1.260513 (current version as of 2026-05-14)
- **Safe to delete after**: v0.1.260513+2 (keep through 2 releases for traceability)
- **Reason**: Superseded by cryptographically-sound OTP authentication layer

The spec file will remain committed to git as a tombstone for three releases, enabling:
- Traceability: git log shows the transition from webview to OTP model
- Backwards compatibility: existing deployments can reference the old spec if needed
- Knowledge archival: architectural rationale for the transition is preserved

## Observability

To find remaining references to the old spec:

```bash
grep -rn "spec:opencode-web-session[^-]" crates/ scripts/ images/ docs/ --include="*.rs" --include="*.sh" --include="*.md"
```

Current reference:
- `crates/tillandsias-browser-mcp/src/allowlist.rs:3` (intentionally left; applies to both flows)

## Files Modified

1. `openspec/specs/opencode-web-session/spec.md` — Added tombstone annotation
2. `openspec/litmus-bindings.yaml` — Updated verification timestamp and added tombstone marker
3. This file — Migration guide and retention policy

## Related Changes

- `openspec/changes/archive/2026-04-27-opencode-web-session-otp/` — Original OTP spec proposal and implementation
- `openspec/specs/browser-isolation-tray-integration/spec.md` — Native browser isolation layer
- `openspec/specs/subdomain-routing-via-reverse-proxy/spec.md` — Caddy-based routing and authentication framework
