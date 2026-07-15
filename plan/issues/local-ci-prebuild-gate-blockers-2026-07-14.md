# Local CI pre-build gate blockers — 2026-07-14

- host: linux_mutable (macuahuitl)
- branch: linux-next
- commit: 4e18ae36 (post-litmus-fix)
- gate: `scripts/local-ci.sh --phase pre-build`
- result: 13/17 checks PASS, 4 FAIL

## Failure 1: container-base-policy

Three test scripts use mutable `:latest` image tags:

```
scripts/test-forge-gitconfig-bidirectional-quarantine.sh:5
scripts/test-forge-standard-gitconfig-path.sh:5
scripts/test-forge-runtime-ca-trust.sh:5
```

All use `IMAGE="${TILLANDSIAS_FORGE_IMAGE:-localhost/tillandsias-forge:latest}"`.
The policy rejects mutable `:latest` tags in runtime/build docs or scripts.

**Root cause**: These test scripts predate the container-base-policy check and
were never updated to use version-pinned image references.

**Smallest next action**: Pin the default image tag to the current version
(`0.3.260714.1`) or use the same pattern as the litmus tests (read VERSION
file). Three files, one-line fix each.

## Failure 2: no-python-scripts

`scripts/test-forge-runtime-ca-trust.sh` uses python3 at lines 49, 50, and 100:

- Line 49: `python3 -c 'import socket; ...'` for random port allocation
- Line 50: `python3 - "$tmp/web" "$tmp/server.crt" "$tmp/server.key" "$port" <<'PY'` for test HTTPS server
- Line 100: `python3 -c "import urllib.request; ..."` for URL fetch

Repository policy rejects Python scripts.

**Root cause**: The CA trust test was written before the no-python-scripts
policy was enforced. The python3 usage is for test infrastructure (port
allocation, HTTPS server, URL fetching), not production code.

**Smallest next action**: Rewrite the python3 test helpers using bash/openssl
equivalents. Port allocation: use `ss -tln` or `nc -l` with a random port.
HTTPS server: use `openssl s_server` or a socat-based TLS proxy. URL fetch:
use `curl` or `wget`.

## Failure 3: no-base64-script-injection

Two scripts use base64 decode-to-executable idiom:

```
scripts/test-codex-device-auth.sh
scripts/test-codex-oauth-harvest.sh
```

**Root cause**: These scripts materialize and execute a script from a base64
literal, which is the exact anti-pattern the check guards against.

**Smallest next action**: Rewrite the base64-decoded scripts as proper
committed script files, or use an approved-language path.

## Failure 4: litmus-pre-build (2 FAIL out of 167)

Both failures are in forge CA trust litmus tests that run containers with
the forge image:

- `litmus:forge-config-trust-cross-platform-parity` (step 1/1)
- `litmus:forge-runtime-ca-trust` (step 1/3)

Both fail because the litmus test script (`test-forge-runtime-ca-trust.sh`)
uses python3 inside the forge container, and the forge image does not have
python3 installed (no-python-scripts policy).

**Root cause**: The litmus tests inherit the python3 dependency from the test
script they invoke. This is the same root cause as Failure 2 — fixing the
test script's python3 usage will fix both.

## Filed work packets

| Order | Packet ID | Summary |
|---|---|---|
| 343 | test-scripts-mutable-image-tag | Pin :latest tags in 3 test scripts |
| 344 | test-scripts-python3-elimination | Rewrite python3 helpers in CA trust test |
| 345 | test-scripts-base64-injection-elimination | Rewrite base64 decode-to-exec in auth tests |

## Release disposition

The local-build e2e gate is red. No release, published-release smoke, or
destructive e2e can proceed until these 4 checks pass. All are pre-existing
issues that predate the current cycle. Orders 343-345 are ready for pickup.
