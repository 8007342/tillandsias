# --init Proxy Env Poisons Image Builds (P0: app won't launch)

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-27
**Severity:** CRITICAL — released app fails to launch on fresh install
**Trace:** `spec:proxy-container`, `spec:init-command`

## Symptom

On a fresh install (v0.3.260627.2), `tillandsias --init` fails to build the
`git` image (required, non-optional), so the app cannot launch:

```
build-git: WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.20/main: DNS lookup error
build-git: ERROR: unable to select packages: bash (no such package) ...
FAILED git: Build exited with status exit status: 8
...
build-forge-base: >>> Curl error (5): Could not resolve proxy name for
  https://mirrors.fedoraproject.org/metalink?... [Could not resolve proxy: proxy]
FAILED forge-base ...
Error: Failed to build 1 required image(s): git
```

## Root Cause

`run_init` calls `ensure_containers_conf_proxy_env`, which writes the squid proxy
into the **global** `[engine] env` of `~/.config/containers/containers.conf`:

```toml
[engine]
env = ["http_proxy=http://proxy:3128", "https_proxy=http://proxy:3128", ...]
```

Podman injects `[engine] env` into **every** container it launches — including
the RUN steps of `podman build`. Confirmed empirically:

```
$ podman build --no-cache -f Containerfile.test .   # RUN echo $http_proxy
http_proxy=[http://proxy:3128] HTTP_PROXY=[http://proxy:3128]
```

But `proxy` is a hostname that only resolves at **runtime**, inside the pod
network, via aardvark-dns once the squid proxy container is up. During an image
build there is no pod and no proxy container, so `proxy` is unresolvable. Every
build that needs the network (`apk`, `microdnf`, npm, cargo) then fails:

- Alpine `apk` → "DNS lookup error" (tries to resolve `proxy`)
- Fedora `microdnf` → "Could not resolve proxy: proxy"

The proxy env is correct for **runtime** containers (egress caching/policy) but
wrong for **builds**, which need direct outbound network.

## Fix

Neutralize the proxy env for the build subprocess only, in
`build_image_with_logging`. An empty value present in the spawning process's
environment overrides the containers.conf `[engine] env` for that variable
(confirmed empirically — all of: emptying in calling env, `--build-arg`,
`--env`, and `--http-proxy=false` produce an empty proxy inside RUN):

```rust
for proxy_var in BUILD_PROXY_NEUTRALIZE_VARS {   // http_proxy, https_proxy, HTTP_PROXY, ...
    command.env(proxy_var, "");
}
```

Runtime container launches are untouched and still route through `proxy:3128`.

### Verification

End-to-end, the exact operation the git build performs:

```
$ http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
    podman build --no-cache -f Containerfile.apktest .   # RUN apk add jq
(2/2) Installing jq (1.7.1-r0)
OK: 9 MiB in 16 packages
jq-1.7.1
Successfully tagged localhost/till-apkfix:latest
```

Pinned by unit test `build_proxy_neutralize_vars_cover_lower_and_upper_case`.

## Why CI didn't catch it

CI builds the *release binary* via Nix; it does not exercise `--init`'s
podman-build path on a clean host with the proxy env written. The failure only
manifests on a fresh end-user machine where every image must be built locally.
Filed as a bar-raise candidate: add a clean-host curl-install e2e that runs
`--init` and asserts the required `git` image builds.

## Related

- `plan/issues/init-dns-systemd-resolved-2026-06-27.md` — order 115; the DNS
  `dns_servers` workaround masked this on the dev host but does not fix the
  proxy poisoning for the `proxy` hostname specifically.
- Orphaned `zeroclaw` image plumbing still present in the init image list
  (`images/zeroclaw/`, `is_optional_image`, identity chain) after the zeroclaw
  binary/crate removal — filed separately for cleanup.
