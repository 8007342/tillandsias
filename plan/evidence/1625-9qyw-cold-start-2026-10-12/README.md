# 1625-9qyw evidence: a cold-start forge serves a web project, no operator action (lenovinha, 2026-10-12)

The operator's scenario: a freshly installed Tillandsias, a forge on a Wrangler
web project, and the request "serve this web project locally". On v56.10.9.1 it
failed (plan/issues/research/forge-web-preview-cold-start-2026-10-12.md). This
directory holds the same run against v56.10.9.1 (pre-fix) and v56.10.12.1
(post-fix). The repeatable form is `scripts/lua/cold-start-acceptance.lua`
(litmus:cold-start-acceptance-e2e, opt-in).

## Substrate: sealed, because Vault's unseal share lives in the host keychain

Vault keeps its unseal share in the host OS keychain under the fixed service
`tillandsias` (vault_bootstrap.rs). The file fallback is used only when the
keychain is unreachable. On lenovinha the podman isolation must keep the real
XDG_RUNTIME_DIR, because netavark starts aardvark-dns through `systemd-run
--user`. That keeps the session bus, and so the keychain, reachable. A scratch
install on the host would read the operator's share, and a scratch Vault init
would overwrite it. The host keychain holds three such items:
`keychain-baseline-20261012T153141Z.txt` (vault-root-token-v1,
vault-shamir-share-v1, installation-uuid-v1).

So every run happens inside a container that has its own podman and NO D-Bus
session. The coordinator ruled out an env var relocating the share: it could
strand a real user's share.

- **Outer container:** `podman run -d --name … --privileged --user podman -v <vol>:/home/podman/.local/share/containers quay.io/podman/stable:v5.8.7 sleep infinity`.
  - It runs from a scratch podman store: graph under `target/work`; runroot and tmp_dir in a private `$XDG_RUNTIME_DIR` dir, since pasta's SELinux domain refuses a home-labelled pid file. A guard checks the store before every podman call.
  - `--privileged` is needed: without it netavark cannot set `net/ipv4/ip_forward`, and the nested bridge networks need `/dev/net/tun`.
  - No host path, socket, env or runtime dir is passed in.
- **Structural proof** (`*/structural-proof*.txt`), run before any install, and again after each deviation:
  - no `DBUS_SESSION_BUS_ADDRESS`;
  - no `/run/user/*/bus` and no `/run/dbus` socket;
  - no `~/.local/share/keyrings`;
  - no dbus, keyring or secret daemon;
  - active `gdbus --session` and `busctl --user` probes fail.
- **The product's own words, in the vault log of both runs:** "keyring Shamir share get failed/timed out (Platform secure storage failure: no secret service provider or dbus session found); checking file fallback". Inside the container, `fallback_vault-shamir-share-v1` and `fallback_vault-root-token-v1` exist (mode 600; metadata only).
- **Host keychain:** the metadata of the `service=tillandsias` items (Label, Created, Modified, Locked, Attributes, read via `org.freedesktop.DBus.Properties.Get` on `org.freedesktop.Secret.Item`, never GetSecret) is byte-identical before and after every run, and to the baseline. See `keychain-before.txt` and `keychain-after.txt`.

**Deviations inside the outer container.** Each stands in for something a real host provides. They were accepted by the coordinator.
1. openssl.
2. An empty `/run/user/1000`, mode 0700. The installer's `--reset-state` needs it; logind provides it.
3. Stock-host namespaces in the nested podman's containers.conf. The image forces `utsns=host`, which refused the product's `--hostname proxy`, and binds `/proc` into every container. `cgroups="disabled"` is kept, because there is no cgroup delegation in a nested container.
4. A random `/etc/machine-id`, which the vault ensure needs.
5. A healthcheck ticker that runs `podman healthcheck run` every 5 s, in place of systemd's timers. Without it vault never left `starting`. It must start AFTER the install: post-fix launch 1 timed out at the 60 s vault health wait because the ticker had been started before the installer's `podman system reset` (`postfix-v56.10.12.1/launch-1-vault-health-timeout.log`).

**Project:** `8007342/macron.dev`, public. The operator made it public for this purpose; it was seeded with one commit, 2ac6ce92b.
- `wrangler.jsonc` serves `./public`, with no build step.
- The default branch is main.
- The forge got its source from the git mirror (a clone of the public remote). **No GitHub login was needed:** a token-less fresh install launches a forge on a public remote.

The steps from install to fetch were scripted with no operator action. Inside the forge, NDJSON was piped to `/home/forge/.config-overlay/mcp/host-browser.sh`, exactly what a forge agent's MCP client sends. The fetch ran host-side, on the outer container, as the host browser would. The URL is a host-browser URL: `*.localhost` goes to the router's host port 18443. TLS was checked with `--cacert ~/.local/state/tillandsias/ca/intermediate.crt`.

## Pre-fix: v56.10.9.1 (`prefix-v56.10.9.1/`)

- **Install:** 10 images provisioned (proxy, git, vault, inference, router, chromium-core, chromium-framework, forge-base, forge, web). There is **no web-wrangler image** (`inner-images.txt`); 1625-un54.
- **`publish_local {"category":"WEB","runtime":"auto"}`:** `-32000 "runtime_unavailable: initialize the managed runtime image before publication"`.
- **`service_status`:** `state=stopped`, `runtime=unknown`, `diagnostic=""`. The failure leaves no trace (1625-6iwd). No URL.
- **`runtime=static` on the same install:** served. `https://www.macron.dev.localhost:18443` returned http=200, 1276 bytes, ssl_verify=0, and the title "macron.dev — under construction".
  - This reconciles with the operator's static failure: visual-chess has no root index.html, var/html or public/, and its wrangler assets dir (./dist) was unbuilt, so static's source selection fell through `verify_subset("index.html")`. macron.dev has `public/index.html`.

## Post-fix: v56.10.12.1 (`postfix-v56.10.12.1/`)

- **Install:**
  - The installer sha256 matches the release SHA256SUMS. The release is prerelease, so the run pinned `TILLANDSIAS_RELEASE_BASE` to the tag, 95874de57.
  - 11 images provisioned, including **`tillandsias-web-wrangler:v56.10.12.1`** (identity sha256-589586ef, the same as the 1625-un54 evidence).
- **Criterion 1** (`publish-auto.txt`):
  - `publish_local` runtime auto returned `state=running`, `runtime=wrangler`, `watch=true`, `route_ready=true`, url `https://www.macron.dev.localhost:18443`.
  - The host-side fetch through the router returned **http=200**, 1276 bytes, **ssl_verify=0**, and the title "macron.dev — under construction".
  - `service_status` agrees.
- **Router self-heal** (`publish-router-stopped.txt`): after `service_stop` and `podman stop tillandsias-router`, the same publish re-ensured the router and served http=200 again. A stopped router is not a failure.
- **Forced router-step failure** (`publish-port-squatted.txt`): an unrelated container held `127.0.0.1:18443`, as another app on the host would, and the router container was removed.
  - `publish_local` returned `-32000 "runtime_unavailable: podman failed at step router (exit)"`.
  - `service_status`: `state=stopped`, `last_failure {"step":"router","class":"exit","reason":"runtime_unavailable: podman failed at step router (exit)","at":"2026-10-12T19:46:41Z","remedy":"operator"}`.
  - `remedy=operator` is right for a port conflict: the agent cannot free a host port.
- **Recovery** (`publish-recovered.txt`): with the port holder removed, the same call returned running, wrangler, http=200, and `last_failure` was cleared.

## Repeatable: `scripts/lua/cold-start-acceptance.lua`

Everything above, as one opt-in Lua driver:
- host-side podman orchestration through `proc.run`, with an explicit scratch env and no D-Bus address;
- in-container steps as bash text on stdin;
- MCP replies parsed with the runtime's `json.parse`, no jq;
- the keychain metadata probe and the structural proof both fail closed;
- the ticker starts after the install.

It refuses to act without `--privileged-podman-in-podman`. Its pins are
litmus:cold-start-acceptance-shape (instant, five seeded negative controls).
The live run is litmus:cold-start-acceptance-e2e (size e2e, never in the
default gate).

### Driver run: v56.10.12.1 (`lua-driver-v56.10.12.1/`, run 20261012195203)

The in-repo driver reproduced the whole post-fix result in one unattended run.
Verdict:
`ok:cold-start-acceptance:v56.10.12.1:served:https://www.macron.dev.localhost:18443:http=200:router-failure=step-qualified:recovered`.

- **Structural proof:** all markers present; both probes fail.
- **Install:** the installer sha matches SHA256SUMS. 11 images, including web-wrangler, v56.10.12.1.
- **Forge:** up on attempt 1 after 55 s. The ticker started after the install, so there was no vault health timeout.
- **`publish_local` auto:** runtime=wrangler. The host-side fetch returned http=200, ssl_verify=0, and the macron.dev title.
- **Forced port conflict:** `runtime_unavailable: podman failed at step router (exit)`, with last_failure step=router, class=exit, remedy=operator.
- **Recovery:** http=200 and last_failure cleared.
- **Host keychain:** the item metadata is identical before and after (`keychain-before.txt`, `keychain-after.txt`).

One fix came out of this run. Every podman invocation recreates an empty storage
skeleton, including the cleanup's own `podman unshare`. The driver now ends with
a podman-free `find <graph> <runtime-dir> -delete`. `rm` outside the repository
needs consent under `proc.run`'s policy; `find` does not.

