---
tags: [google-cloud, gcp, cloud-run, dockerfile, container, non-root, port]
languages: [javascript, python, go, dart]
since: 2026-10-27
last_verified: 2026-10-27
sources:
  - https://cloud.google.com/run/docs/container-contract
  - https://cloud.google.com/run/docs/continuous-deployment
  - https://github.com/GoogleCloudPlatform/python-docs-samples/tree/main/run/helloworld
  - https://github.com/GoogleCloudPlatform/golang-samples/tree/main/run/helloworld
  - https://github.com/GoogleCloudPlatform/nodejs-docs-samples/tree/main/run/helloworld
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# A Dockerfile for Cloud Run

@trace order:1906-md6q

**Use when**: deploying to Cloud Run with the "Dockerfile" build type, or any
static site / Flutter web app (buildpacks cannot serve those on a GA path).

## Provenance

- Container runtime contract: <https://cloud.google.com/run/docs/container-contract>
- Console build type and "Source location": <https://cloud.google.com/run/docs/continuous-deployment>
- Google's per-language samples: `run/helloworld/Dockerfile` in
  <https://github.com/GoogleCloudPlatform/python-docs-samples>,
  <https://github.com/GoogleCloudPlatform/golang-samples>,
  <https://github.com/GoogleCloudPlatform/nodejs-docs-samples>
- **Last updated:** 2026-10-27 (fetched and read that day by lenovinha for order 1906-md6q)

Billing: see `cloud/gcp-cloud-run-deploy-paths.md` → Cost. A billing account is required.

## Rules the contract imposes

1. **Listen on `0.0.0.0:$PORT`**; default 8080. Read `PORT` at run time, never hard-code a different one.
2. **linux/amd64** image. From an arm64 Mac: `--platform linux/amd64`.
3. **Handle SIGTERM**: 10 s before SIGKILL. Use the exec form (`CMD ["..."]` or `exec` in a shell form) so the server is PID 1 and receives it.
4. **No disk state**: the filesystem is in memory and per instance.
5. **Start within 4 minutes**; keep the image small and do the build in a build stage.
6. **Run as a non-root user that exists** in the image (`USER` naming a missing user means root). No setuid tools.

## Google's sample (Python, verbatim shape)

```dockerfile
FROM python:3.14-slim
...
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 main:app
```

## Static site / Flutter web

Build in one stage, serve `build/web` (Flutter) or `dist/` from a small web
server that reads `$PORT`. The forge template uses nginx with
`listen ${PORT}` substituted at start by the official image's envsubst
templates (`/etc/nginx/templates/*.template`), runs as the unprivileged `nginx`
user, and falls back to `index.html` for client-side routes.

## Where to fetch canonical templates

- `GoogleCloudPlatform/{python,golang,nodejs}-docs-samples/run/helloworld/Dockerfile`
- `GoogleCloudPlatform/java-docs-samples/run/helloworld/`
- `GoogleCloudPlatform/cloud-run-samples`

The forge's starting Dockerfiles (node, python, go, static) live in the
`start-a-new-project` skill under `templates/gcp/`.
