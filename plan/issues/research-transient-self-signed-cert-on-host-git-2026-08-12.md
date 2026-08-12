# research: a TRANSIENT "self signed certificate" error on the host's git fetch to github.com

- **Filed**: 2026-08-12
- **Host**: macos (Tlatoani's MacBook Air), bare-metal builder checkout `~/claudia/tillandsias`
- **Class**: `research/` — observed once, recovered immediately, cause not identified
- **Status**: open, LOW priority — filed for correlation if it recurs, not because it is currently breaking anything

## What happened

At the top of a meta-orchestration cycle, the routine fetch failed:

```
$ git fetch origin --prune
fatal: unable to access 'https://github.com/8007342/tillandsias.git/':
SSL certificate problem: self signed certificate
```

An immediate retry, same command, same shell, seconds later, succeeded and
pulled two branches normally. Nothing was changed between the two attempts.

## What was ruled out, immediately after

- **Proxy environment**: `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy`
  all unset.
- **Git HTTP config**: `git config --get-regexp '^http\.'` empty at both repo and
  global scope — no `http.proxy`, no `http.sslCAInfo`, no `http.sslVerify`
  override.
- **TLS env overrides**: no `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`,
  or `GIT_SSL_*`.

So it was not a persistent misconfiguration on this checkout, and not an
inherited proxy variable.

## Why it is worth a record rather than a shrug

A "self signed certificate" error is not a generic network failure. It means
*something answered the TLS handshake with a certificate this host does not
trust* — a different endpoint, or an interceptor — rather than a connection
merely failing. On a host that had just performed GitHub credential work
minutes earlier, that is worth being able to correlate later.

Plausible benign explanations, none confirmed:

- a macOS network transition (Wi-Fi reassociation, VPN attach/detach, or a
  captive-portal style interceptor answering during the window);
- transient interference from local TLS-terminating machinery — this project
  runs an enclave proxy (Squid) with a generated ephemeral CA, though it lives
  INSIDE the guest VM and should never be on the host's path to github.com.
  Worth checking whether any host-side component can ever route host traffic
  through it.

**NOT to do:** setting `http.sslVerify=false`, `GIT_SSL_NO_VERIFY`, or adding
the ephemeral CA to the host trust store to "fix" this. All three would convert
a visible anomaly into a silent one, on the exact path that carries push
credentials. If this recurs and blocks work, capture the presented certificate
(`openssl s_client -connect github.com:443 -showcerts`) and identify the issuer
before changing any trust configuration.

## If it recurs

Escalate to a packet with: the captured certificate chain, whether a VM was
running at the time, and whether the guest's proxy container was up. One
occurrence with a clean immediate retry does not justify more than this note.
