# Research: a cold-start forge could not serve a web project (2026-10-12)

Provenance: a forge agent's research write-up in another project of the
operator's, `8007342/visual-chess`, branch `research/web-preview-runtime-diagnosis`,
commit `56ba0858a`, file `research/forge-web-preview-diagnosis.md`. The forge ran
on yoga (Fedora host), lane `visual-chess-default`. The coordinator
(macuahuitl) distilled it on 2026-10-12 and checked each claim against
trunk `origin/linux-next`.

## The ask

The operator, with no other context: "start this [web] project and serve it
locally". The prompt in the forge was "Can you serve this project locally on
a sibling container and open it?". The sanctioned path is the `host-browser`
MCP: `publish_local {"category":"WEB","runtime":"auto|static|wrangler"}`, then
`browser_open` on the returned URL. The forge has no podman, by design.

## What failed, and the cause on trunk

| Symptom in the forge | Cause, verified on trunk | Packet |
|---|---|---|
| `publish_local` with `auto` (the project has `wrangler.jsonc`) and with `wrangler`: `runtime_unavailable: initialize the managed runtime image before publication`, on every retry | No code path ever builds `tillandsias-web-wrangler`. `publish_locked` (local_web_preview.rs) checks `podman image exists` for it. But `INIT_IMAGES` in main.rs lists ten images without `web-wrangler`, and main.rs `image_specs` has no `web-wrangler` arm (only runtime_assets.rs `image_context_rel` does). The refusal names a step the agent cannot run, and nothing else ever runs it either. | 1625-un54 |
| `publish_local` with `static`: `runtime_unavailable: Podman operation failed` | Unknown. `podman()` in local_web_preview.rs maps EVERY non-zero podman exit to that one string. That's deliberate, because raw output can carry secrets. The static image passed the existence check, so the failure came later (ps/inspect, `source_mounts`, `ensure_router`, run, or readiness). The code cannot tell which. | 1625-6iwd |
| `service_status {}` empty in every state | Status reports only published services; a failed publish leaves no trace. | 1625-6iwd |
| `gh auth status`: `permission denied` reading `~/.config/gh/config.yml` | The credential-quarantine tmpfs `/home/forge/.config/gh:size=1m,mode=0700` (main.rs, order 224) has no `uid=`, so it is root-owned inside the forge. That contradicts `default-image` ("masked with forge-owned empty overlays"), while `forge-offline` says the path "SHALL NOT exist". Credential-free is correct and stays. The defect is that gh fails with a misleading error instead of "not logged in", and the agent was given no sanctioned route for filing an upstream issue. | 1625-bax2 |
| In-forge `./build.sh --dev` cannot build: no `wasm32-unknown-unknown` target, and no rustup | The forge image ships Fedora's system rustc and no wasm32 std. `wasm-pack` is present but cannot add the target. Fedora packages it as `rust-std-static-wasm32-unknown-unknown`. | 1625-grk8 |
| `tests.stockfishchess.org` denied by the proxy | Project-specific host and not on the allowlist. The project's own GitHub mirror fallback is reachable. NOT a Tillandsias defect; no packet. | — |

## What worked

The project mirror (git fetch and push), project-info MCP, npm registry and
GitHub reachability, and the fail-soft expert status `degraded(no-plan-crate)`.
The agent also followed the right path when blocked. It wrote its findings to
a `research/` branch and pushed it through the mirror, and that is how this
report reached the coordinator.

## The acceptance this release owes

1625-9qyw: on a freshly provisioned host, a cold-start forge given only "serve
this web project locally" for a Wrangler + wasm project reaches a URL the host
browser loads, with no operator action. It depends on the four fixes above
and on the 1552 local-web-preview rows (238z runtime, mqvf image+MCP, e3wf
live acceptance). Those rows are still `ready` although their code is on
trunk; this report is the first live evidence against them.

Spec change: `openspec/changes/forge-web-preview-cold-start/`.
