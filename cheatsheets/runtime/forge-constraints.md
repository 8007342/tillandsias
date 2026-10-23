---
tags: [forge, runtime, constraints, docker, container, podman, nested, daemon, rootless, cap-drop, tmpfs, proxy, inference, git-mirror]
languages: [bash]
since: 2026-10-23
last_verified: 2026-10-23
sources:
  - https://docs.podman.io/en/stable/markdown/podman-run.1.html
  - https://docs.podman.io/en/stable/markdown/podman.1.html
  - https://man7.org/linux/man-pages/man7/capabilities.7.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Forge hard constraints (can I run docker / a container here?)

@trace spec:forge-container, spec:knowledge-source-of-truth

**Use when**: you are an agent inside a Tillandsias forge and wonder whether you can run docker, podman, a nested container or daemon, install packages, reach the internet, call a local model, or push code.

## Summary (quote this block)

There is NO docker and NO nested container daemon in the forge. Do not recommend `docker run`, `docker compose`, `podman run`, podman-in-podman or mounting a container socket here. The forge is itself a rootless podman container (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`). Container work is done on the host by tillandsias or by enclave services, never from inside the forge. The workspace is a git clone on tmpfs (lost on stop; push to keep it). Egress goes only through the enclave proxy. Local inference is at `inference:11434`, the expert endpoint at `127.0.0.1:11436`. `git push` goes through the git mirror.

## Provenance

- <https://docs.podman.io/en/stable/markdown/podman-run.1.html> — `--cap-drop`, `--security-opt no-new-privileges`, `--userns=keep-id`, `--tmpfs` semantics
- <https://docs.podman.io/en/stable/markdown/podman.1.html> — rootless podman model (no daemon; user namespaces)
- <https://man7.org/linux/man-pages/man7/capabilities.7.html> — what dropping ALL capabilities removes
- Repo (verified 2026-10-23): `crates/tillandsias-podman/src/container_spec.rs` (emits `--userns=keep-id`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`; a test refuses removing `--cap-drop=ALL` in every profile), `crates/tillandsias-podman/src/policy.rs` (mandatory flag list), `crates/tillandsias-podman/src/launch.rs` (`--tmpfs /tmp`, `/run/user/1000`, `/opt/cheatsheets`), `crates/tillandsias-podman/src/client.rs` (containers.conf bakes `http(s)_proxy=proxy:3128` into containers), `images/default/Containerfile` (no podman or docker installed), `images/default/lib-common.sh` (`inference:11434` default, `TILLANDSIAS_EXPERT_SERVE_PORT` default 11436, `clone_project_from_mirror`, `rewrite_origin_for_enclave_push`), `crates/tillandsias-plan/src/expert_serve.rs` (`DEFAULT_PORT` 11436, bound to 127.0.0.1)
- Sibling sheets: `runtime/forge-container.md`, `runtime/everything-in-forge.md` (never mount `/var/run/docker.sock` or `/run/podman/podman.sock`), `runtime/forge-paths-ephemeral-vs-persistent.md`, `runtime/enclave-proxy-patterns.md`
- **Last updated:** 2026-10-23

## Constraints

| Question | Answer | Basis |
|----------|--------|-------|
| Run docker? | No. No docker binary, no daemon, no socket. | Containerfile installs none; everything-in-forge forbids mounting container sockets |
| Run podman / nested containers? | No. Rootless, all capabilities dropped, no-new-privileges; no nested daemon is provided. | container_spec.rs flags |
| Need a container for your task? | Ask the host: tillandsias launches containers; enclave services (proxy, git mirror, inference) already run beside the forge. Write a `RUNTIME_LIMITATIONS_NNN.md` request rather than working around it. | forge-container.md pitfalls |
| Gain privileges / setuid / sudo? | No. `no-new-privileges` + `cap-drop ALL`. | container_spec.rs |
| Is the workspace a bind mount? | No by default: `/home/forge/src/<project>` is a clone from the git mirror on tmpfs (RAM); it dies with the container. Commit and push to keep work. Exception: a host-mounted launch sets `TILLANDSIAS_PROJECT_HOST_MOUNT=1` and the directory is the real checkout. | forge-paths-ephemeral-vs-persistent.md, everything-in-forge.md |
| Install system packages? | No (`dnf install` fails; image is read-only). | forge-container.md |
| Reach the internet? | Only via the enclave proxy (`proxy:3128`, allowlisted). Direct egress is not available. | client.rs comment, enclave-proxy-patterns.md |
| Local model? | Ollama-compatible service at `http://inference:11434`; grounded experts at `http://127.0.0.1:11436/v1`. | lib-common.sh, expert_serve.rs |
| Push code? | `git push origin <branch>` goes to the enclave git mirror, which relays to the remote; the forge holds no credentials. | lib-common.sh `rewrite_origin_for_enclave_push` |

## Common pitfalls

- Suggesting `docker compose up` or a Dockerfile-based test loop: impossible here; use host-side tooling or enclave services.
- Mounting or hunting for `/var/run/docker.sock` or the podman socket: it must not exist.
- Leaving work uncommitted in the tmpfs workspace.

## See also

- `runtime/forge-container.md`, `runtime/everything-in-forge.md`, `runtime/forge-paths-ephemeral-vs-persistent.md`, `runtime/enclave-proxy-patterns.md`
