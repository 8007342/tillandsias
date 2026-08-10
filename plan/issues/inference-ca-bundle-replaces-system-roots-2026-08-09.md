# Inference CA bundle REPLACES the system roots, so spliced upstreams fail and the container exits 1

Filed 2026-08-09 by `windows-claude-fable-metaorch-20260809t0630z` on `windows-next`
during a meta-orchestration cycle. Deliverable for packet **486**
(`inference-coldstart-races-proxy-egress-and-hard-gates-launch`, status `ready`)
and order token `627-k4mz`.

Triggered by an operator instruction to confirm that the low-end
`TILLANDSIAS_NO_LOCAL_INFERENCE` kill switch (order 620-cine) had not broken the
normal launch path **with** the inference container.

trace: order 313 (first-run install resilience), order 486 (cold-start races),
order 525 (SSL_CERT_FILE for Go), order 620-cine (low-end kill switch),
images/inference/entrypoint.sh

---

## Answer to the question that was asked: the kill switch is fine

The low-end gate is **opt-in and correct**. Verified by reading every site and
by live state on this host:

- `local_inference_disabled()` reads `TILLANDSIAS_NO_LOCAL_INFERENCE` and returns
  false when unset, empty, or `"0"`.
- All five gate sites are `if disabled { skip } else { <original code verbatim> }`.
  The default path is structurally unchanged.
- The only writer is the Windows tray unit, and it forwards the variable **only**
  when the tray's own environment already carries it
  (`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:1319`). There is no
  auto-detection that could mis-fire on a normal host.
- On this host the variable is unset, and `tillandsias-inference` **was** created
  — so the gate did not skip it.

## But the normal path is broken anyway, for an unrelated reason

`tillandsias-inference` on this host: `Exited (1)`, image
`localhost/tillandsias-inference:v0.4.260809.2`. Its log:

```
[inference] WARN: system trust store not updated (rc=1, expected as uid 1000 on this image)
[inference] ca-trust: store_rc=1 ssl_cert_file=/etc/tillandsias/ca.crt curl_ca_bundle=/etc/tillandsias/ca.crt
[inference] Installing ollama binary (first run)...
curl: (60) SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
[inference] proxy egress not ready (attempt 1/5) — retrying in 2s
   ... identical failure on attempts 2, 3, 4, 5 ...
[inference] FATAL: proxy egress never became ready within bounded backoff (5 probes)
[inference] ollama download FAILED — will retry next launch (non-fatal)
[inference] FATAL: no ollama binary available (self-install failed above) — exiting
```

**The proxy was not the problem.** The message is wrong.

### Root cause

`CURL_CA_BUNDLE` and `SSL_CERT_FILE` **replace** the default trust set; they do
not augment it. `entrypoint.sh` pointed both at `/etc/tillandsias/ca.crt`, which
holds exactly one certificate:

```
subject=C=US, ST=Privacy, L=Local, O=Tillandsias, CN=Tillandsias CA
issuer =C=US, ST=Privacy, L=Local, O=Tillandsias, CN=Tillandsias CA
```

That override discards the **146 public roots** the image ships at
`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`. squid **splices** github
(order 313 recorded this explicitly: *"github is SPLICED by squid — real Sectigo
chain against the system store; HTTP 200, 1.4 GB"*), so curl is presented with
GitHub's genuine public chain and has no root to anchor it. Hence
`unable to get local issuer certificate` — on a perfectly healthy proxy.

The system trust store, which *would* have merged both, cannot be written:
`store_rc=1`, because the container runs as uid 1000 and the Containerfile chowns
only `source/anchors`. So the correct mechanism is unavailable and the fallback
breaks the working path.

This is a regression introduced by the order-486 fix itself. Its 2026-07-28
progress event states the intent — *"entrypoint now exports
`CURL_CA_BUNDLE=/etc/tillandsias/ca.crt` … so squid's bumped error page can never
read as a CA problem"* — and it does prevent that misreading. It also makes every
spliced upstream genuinely unverifiable, which is strictly worse: the previous
symptom was a misleading message, the new one is a container that cannot start.

### Controlled experiment (guest, same host, same network, one variable changed)

```
A. system store, no override        -> OK: system store verifies github
B. CURL_CA_BUNDLE=<enclave CA only> -> curl (60) unable to get local issuer certificate
```

B is byte-identical to the container's log line. Only the variable differed.

### Verification of the fix, inside the real image at the real uid

```
$ podman run --rm -v /tmp/tillandsias-ca/intermediate.crt:/etc/tillandsias/ca.crt:ro \
    --entrypoint /bin/bash localhost/tillandsias-inference:v0.4.260809.2 -c '<new CA block>'

uid=1000 mode=system+enclave bundle=/tmp/tillandsias-ca-bundle.crt certs=147
--- NEW: combined bundle -> github (spliced, real public chain) ---
PASS: github verifies
--- OLD (regression control): enclave-CA-only -> github ---
FAIL rc=60 (this is the shipped behaviour)
```

147 = 146 public roots + 1 enclave CA. The enclave-CA side needs no separate
proof: the combined file is a **concatenation**, so it is a strict superset of
the old bundle and cannot verify less than it did. (`openssl` is absent from the
image, so the in-image `openssl verify` leg could not run; the enclave CA was
confirmed to verify `vault.crt` in the guest instead.)

## Fix landed

`images/inference/entrypoint.sh` — build the bundle the trust store would have
produced: public roots **then** the enclave CA, written to `${TMPDIR:-/tmp}`
(writable at uid 1000; `$HOME` is not guaranteed writable once the models volume
mounts beneath it), and point both variables at it. Falls back to the previous
enclave-only behaviour with a loud WARN when no system bundle is readable. The
`ca-trust:` diagnostic now reports `mode=`, `bundle=` and the cert count, so this
class of failure is visible in one line instead of inferred from a curl error.

`bash -n` clean. Not yet exercised through a real image build — see residual.

## Residual

- **Image rebuild + cold e2e is the remaining verification** and is Linux-owned
  (`pickup_role: linux` on 486). The change is inert until the inference image is
  rebuilt; until then inference stays down on every host, non-fatally (lanes
  soft-degrade per the 5ddc80db warn-and-continue contract, which is why the
  operator's opencode session worked while inference was dead).
- **The egress-probe summary line is still mislabelled.** It reports
  "proxy egress not ready" for any probe failure, including a pure CA fault. The
  raw curl error *is* printed alongside it, so the information is present — but
  the summary sends the reader to the wrong subsystem. Worth distinguishing
  curl 60 (trust) from curl 7/28 (reachability) in that message.
- Packet 486's exit criterion 1 was recorded closed on 2026-07-28. It should be
  re-read against this finding: the closure is what introduced the regression.

## Handoff

- Branch: `windows-next` (merged `origin/linux-next` first per the pre-push gate).
- Evidence commands are reproducible on any host with a provisioned guest; the
  container need not be running (`podman logs` on the exited container carries
  the whole story).
