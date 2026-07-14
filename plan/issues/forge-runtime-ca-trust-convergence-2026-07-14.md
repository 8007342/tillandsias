# Forge Runtime CA Trust Convergence

Date: 2026-07-14
Packet: `forge-runtime-ca-trust-convergence` (`linux-260714-3`)

## Decision

The per-install proxy CA cannot be baked into an immutable forge image. It is generated during initialization, rotates independently of the image, and is unique to one Tillandsias installation. Baking its bytes would either ship the wrong authority or require rebuilding the image whenever the installation rotates its CA.

The image instead bakes the trust mechanism and boundary:

- Fedora's vendor bundle is preserved read-only at `/usr/local/share/tillandsias/vendor-ca-bundle.crt`.
- Fedora's standard extracted PEM path points to `/run/tillandsias/ca-bundle.crt`.
- `/run/tillandsias` is owned by the unprivileged `forge` user inside the credential-free container.
- The launcher mounts only the public runtime CA at `/run/tillandsias/ca-chain.crt:ro`.
- `lib-common.sh` atomically composes vendor roots plus the runtime CA before any entrypoint network work.

Git, curl, Fedora-patched Python/Requests, and Node's system-CA mode therefore use one distribution-default lookup. No launcher or production default-image entrypoint sets `GIT_SSL_CAINFO`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, or `NODE_EXTRA_CA_CERTS`.

## Trust Boundary

The forge user may rewrite only its own ephemeral `/run/tillandsias/ca-bundle.crt`. It cannot modify the immutable vendor copy, host trust, mounted CA, or image-owned symlink. This adds no authority beyond the former per-process environment overrides and cannot affect another container or the host. Missing image trust material or an unwritable runtime boundary fails startup loudly; a missing runtime CA is diagnosed and falls back to vendor roots for standalone inspection.

Existing containers pin the mounted CA inode until restart. CA rotation therefore takes effect on the next forge launch, matching the existing short-lived `--rm` container lifecycle.
