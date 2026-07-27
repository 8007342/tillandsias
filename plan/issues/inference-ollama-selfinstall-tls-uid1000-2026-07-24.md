# inference ollama self-install fails TLS on fresh substrate (uid-1000 can't update-ca-trust) — FUTURE-scoped

- **Date:** 2026-07-24
- **Class:** bug (CA trust / fresh-substrate) — **future-scoped** (local models not used yet)
- **Area:** inference container (ollama) / enclave proxy CA trust
- **Severity:** low-now / P2-later. Operator clarified (2026-07-24) the harnesses use **free cloud models** (OpenCode: BigPickle/Hy3/free cloud); **local ollama inference is for a future expert system**. So this does NOT block current harnesses. It DOES fail on any fresh/destructive substrate, and will matter when local models come online.
- **Discovered-by:** operator macOS reprovision → Claude forge crash on inference; logs pulled via `--exec-guest`.

## Symptom (from `podman logs tillandsias-inference`)

```
[inference] Installing ollama binary (first run)...
curl: (60) ... self-signed certificate in certificate chain (19)
[inference] ollama download FAILED — will retry next launch (non-fatal)
[inference] FATAL: no ollama binary available (self-install failed above) — exiting
```

Models volume ownership is CORRECT (`/root/.cache/tillandsias/models` = `1000:1000`, order-313 `5a5b9a37` chown fix intact at `main.rs:3265-3281`). So this is NOT the order-313 volume issue.

## Root cause (traced)

1. The inference container runs as **`USER 1000:1000`** (`images/inference/Containerfile:58`).
2. Its CA injection is `update-ca-trust` (`entrypoint.sh:22`), which must write `/etc/pki/ca-trust/extracted/` — **root-only**. Under uid 1000 it fails and is swallowed by `|| true` (`:20-22`). The anchors *dir* is chowned to 1000 (`Containerfile:36`) so the cert copies in, but the extract never happens → the system trust store stays without the enclave CA.
3. The ollama self-install `curl` (`entrypoint.sh:79-85`) sets **no** `--cacert`/`CURL_CA_BUNDLE`, so it relies on that empty trust store → TLS verification fails against the enclave proxy's MITM cert.
4. The `CURL_CA_BUNDLE` fallback (`entrypoint.sh:111-115`) reads `/run/secrets/tillandsias-ca-cert` — which is **not** the mount used (the launcher mounts `/etc/tillandsias/ca.crt`, `main.rs:3364-3366`) — and runs AFTER the download anyway.
5. Only bites on a **fresh substrate**: once ollama is cached in the persistent model volume, the download is skipped. A destructive reprovision clears it → exposes the bug.

## Confirmed fix

The enclave proxy signs its per-host MITM certs with the **intermediate** (`images/proxy/squid.conf:13-15` `tls-cert=/etc/squid/certs/intermediate.crt`, `generate-host-certificates=on`), and `/etc/tillandsias/ca.crt` is exactly that intermediate — so it is the correct trust anchor. Fix in `images/inference/entrypoint.sh`, BEFORE the self-install download:

```sh
if [ -f /etc/tillandsias/ca.crt ]; then export CURL_CA_BUNDLE=/etc/tillandsias/ca.crt; fi
```

curl honors `CURL_CA_BUNDLE` regardless of the (unwritable) system trust store. Optionally stop swallowing the `update-ca-trust` failure so it's loud.

## Separate, higher-priority issue surfaced by the same crash

The forge **hard-gates** on inference readiness (`main.rs:3017` 60s budget → abort with "inference did not become ready within 60s"). Since local inference is a FUTURE feature the harnesses don't use, a failed/absent inference should be **non-fatal** (warn, continue) so a forge launch isn't blocked by an unused local-model service. (Operator note: OpenCode launched fine; the Claude lane aborted on this gate.) Tracked for a fix decision.

## Cross-references

- `5a5b9a37` order-313 (the volume-ownership fix, intact — this is a different failure).
- `plan/issues/forge-trust-ca-source-readiness-gap-2026-07-23.md` — CA-trust readiness class.
