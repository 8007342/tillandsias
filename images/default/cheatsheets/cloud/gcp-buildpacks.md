---
tags: [google-cloud, gcp, buildpacks, cloud-run, project-toml, procfile, deploy]
languages: [javascript, python, go, java, dart]
since: 2026-10-27
last_verified: 2026-10-27
sources:
  - https://cloud.google.com/docs/buildpacks/builders
  - https://cloud.google.com/docs/buildpacks/service-specific-configs
  - https://cloud.google.com/docs/buildpacks/set-environment-variables
  - https://cloud.google.com/docs/buildpacks/nodejs
  - https://cloud.google.com/docs/buildpacks/python
  - https://cloud.google.com/docs/buildpacks/go
  - https://github.com/GoogleCloudPlatform/buildpacks
  - https://github.com/GoogleCloudPlatform/buildpack-samples
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Google Cloud's buildpacks (Cloud Run without a Dockerfile)

@trace order:1906-md6q

**Use when**: deploying to Cloud Run with the "Google Cloud's buildpacks" build
type, or `gcloud run deploy --source` in a repo with no Dockerfile.

## Provenance

- Builders: <https://cloud.google.com/docs/buildpacks/builders>
- `GOOGLE_*` configuration: <https://cloud.google.com/docs/buildpacks/service-specific-configs>
- `project.toml` build env: <https://cloud.google.com/docs/buildpacks/set-environment-variables>
- Per-language pages: <https://cloud.google.com/docs/buildpacks/nodejs>, <https://cloud.google.com/docs/buildpacks/python>, <https://cloud.google.com/docs/buildpacks/go>
- Detection source: <https://github.com/GoogleCloudPlatform/buildpacks> (`cmd/<lang>/*/lib/lib.go`, `builders/gcp/base/google.24.builder.toml`)
- Samples: <https://github.com/GoogleCloudPlatform/buildpack-samples>
- **Last updated:** 2026-10-27 (fetched and read that day by lenovinha for order 1906-md6q)

Billing: buildpack builds run on Cloud Build and deploy to Cloud Run, both of
which need a billing account. See `cloud/gcp-cloud-run-deploy-paths.md` → Cost.

## Builder

`gcr.io/buildpacks/builder:latest` = `:google-24` (Ubuntu 24), the builder
`gcloud run deploy` uses. Older: `:google-22`, `:v1`. Languages on google-24:
Python, Node.js, Go, Java, Ruby, PHP, .NET, OS-only (the builder file also
lists Dart).

## How the language is detected

| Language | Detected by | Dependencies / build |
|---|---|---|
| Node.js | `package.json`, else any `*.js` | npm, yarn or pnpm from the lockfile |
| Python | any `*.py` | `requirements.txt` (wins) or `pyproject.toml` |
| Go | any `*.go` | `go.mod` recommended |
| Java | `pom.xml`, `.mvn/extensions.xml`, `build.gradle(.kts)`, `settings.gradle(.kts)` | Maven / Gradle |
| Dart | `pubspec.yaml` or `*.dart` | Flutter is detected; its SDK is used at compile time only |

**Static sites and Flutter web are not supported on a generally available
path**: the static (nginx) buildpack opts out unless the build is on the ALPHA
release track, and it reads `index.html` only at the app root, not `build/web`
or `dist/`. Use the Dockerfile path for them.

## Entrypoint (what the container runs)

In order: `GOOGLE_ENTRYPOINT`, else a `Procfile` `web:` line, else the language
default:

- Node.js: `scripts.start` from `package.json` (`npm start`).
- Python ≤ 3.12: `gunicorn -b :8080 main:app`. On 3.13+, source deploys pick
  the server from the framework in `requirements.txt` (FastAPI, Gradio, Streamlit, ...).
- Go: the built binary.

The app must still listen on `0.0.0.0:$PORT`.

## Configuration

| Variable | Meaning |
|---|---|
| `GOOGLE_ENTRYPOINT` | the command to run (like a Dockerfile entrypoint) |
| `GOOGLE_RUNTIME` | force a runtime, e.g. `nodejs` |
| `GOOGLE_RUNTIME_VERSION` | e.g. `24.1.0` (Node), `1.25.1` (Go) |
| `GOOGLE_BUILDABLE` | Go/Java/Dart/.NET path to build, e.g. `./cmd/server` |
| `GOOGLE_CLEAR_SOURCE`, `GOOGLE_GOLDFLAGS` | Go only |

Set them for remote (Cloud Build) builds in `project.toml` at the repo root:

```toml
[[build.env]]
name = "GOOGLE_RUNTIME_VERSION"
value = "24.1.0"

[[build.env]]
name = "GOOGLE_ENTRYPOINT"
value = "node server.js"
```

Not verified: the docs say Cloud Build reads `project.toml` for remote builds;
that `gcloud run deploy --source` honours it follows from that but is not
stated word for word.

## Where to fetch canonical templates

- `GoogleCloudPlatform/buildpack-samples`: `sample-node`, `sample-node-tsc`,
  `sample-python`, `sample-go`, `sample-java-mvn`, `sample-php-entrypoint-procfile`, ...
- `GoogleCloudPlatform/buildpacks/builders/testdata/<lang>/`: the builder's own fixtures.

The forge's starting `project.toml` and `Procfile` live in the
`start-a-new-project` skill under `templates/gcp/`.
