---
tags: [google-cloud, gcp, cloud-run, cloud-build, developer-connect, dockerfile, buildpacks, deploy, billing]
languages: []
since: 2026-10-27
last_verified: 2026-10-27
sources:
  - https://cloud.google.com/run/docs/container-contract
  - https://cloud.google.com/run/docs/continuous-deployment
  - https://cloud.google.com/run/docs/deploying-source-code
  - https://cloud.google.com/run/docs/deploying
  - https://cloud.google.com/run/docs/configuring/request-timeout
  - https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github
  - https://cloud.google.com/free/docs/free-cloud-features
  - https://cloud.google.com/run/pricing
  - https://cloud.google.com/build/pricing
  - https://cloud.google.com/artifact-registry/pricing
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Google Cloud Run: the two deploy paths from a GitHub repo

@trace order:1906-md6q

**Use when**: a web app should deploy to Google Cloud Run from its GitHub repo,
and you must choose Dockerfile or Buildpacks and write the repo files each needs.

## Provenance

- Cloud Run container runtime contract: <https://cloud.google.com/run/docs/container-contract>
- Continuous deployment from a repository (Cloud Build or Developer Connect): <https://cloud.google.com/run/docs/continuous-deployment>
- Deploying from source (`gcloud run deploy --source`): <https://cloud.google.com/run/docs/deploying-source-code>
- Deploying a service, including the `service.yaml` form: <https://cloud.google.com/run/docs/deploying>
- Request timeout: <https://cloud.google.com/run/docs/configuring/request-timeout>
- Connecting GitHub to Cloud Build: <https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github>
- Free Tier and billing: <https://cloud.google.com/free/docs/free-cloud-features>, <https://cloud.google.com/run/pricing>, <https://cloud.google.com/build/pricing>, <https://cloud.google.com/artifact-registry/pricing>
- **Last updated:** 2026-10-27 (fetched and read that day by lenovinha for order 1906-md6q)

## Cost: a billing account is required

Google Cloud is **not** free-only the way the default Cloudflare and GitHub
paths are. Google states: "A Google Cloud billing account is required to access
the Google Cloud Free Tier", and the free limits are counted per billing
account. A card on file can be charged once a free allowance is exceeded.

Free monthly allowances as published on 2026-10-27 (check the pricing pages
before relying on them):

| Product | Free per month |
|---|---|
| Cloud Run (request-based billing) | 180,000 vCPU-seconds, 360,000 GiB-seconds, 2 million requests, 1 GiB egress within North America |
| Cloud Build | 2,500 build-minutes (e2-standard-2) |
| Artifact Registry | 0.5 GiB storage |

Say this to the user in plain words before any Google Cloud step: it needs a
billing account with a payment method, small apps usually stay inside the free
allowance, and usage beyond it is billed. Forge agents never create projects,
link billing, enable APIs or run cloud builds; the user does those in their own
console.

## The two paths (treat them as equals)

Connecting a repo in the Cloud Run console ("Continuously deploy from a
repository") offers **Cloud Build** (GitHub only) or **Developer Connect**
(GitHub, GitLab, Bitbucket). Either creates a **Cloud Build trigger** on a
branch regex; if exactly one branch matches, the trigger runs once at creation.
Then the build type:

| | Dockerfile | Google Cloud's buildpacks |
|---|---|---|
| Repo needs | a `Dockerfile` (console asks for its "Source location"; its folder is the build context) | language files the builder detects (`package.json`, `requirements.txt`/`pyproject.toml`, `go.mod`, `pom.xml`, `pubspec.yaml`), optional `project.toml` and `Procfile` |
| You control | base image, user, every layer | runtime version and entrypoint through `GOOGLE_*` env |
| Static site / Flutter web | yes (serve the build output, see the Dockerfile sheet) | no: the static buildpack is ALPHA-track only; use a Dockerfile |
| Reference | `cloud/gcp-dockerfile-for-cloud-run.md` | `cloud/gcp-buildpacks.md` |

`gcloud run deploy --source .` picks the Dockerfile when one exists and
buildpacks otherwise, and pushes to an Artifact Registry repo named
`cloud-run-source-deploy`. A `cloudbuild.yaml` is only needed for a custom
pipeline: see `cloud/gcp-cloudbuild-yaml.md`.

## The container contract both paths must meet

- Listen on **`0.0.0.0`** (not 127.0.0.1) on **`$PORT`**, default **8080**.
  `PORT` is set only in the ingress container. `K_SERVICE`, `K_REVISION` and
  `K_CONFIGURATION` are also set.
- Start listening within **4 minutes**.
- Requests time out at 300 s by default (max 3600 s, startup included); over it is a 504.
- The filesystem is writable but **in memory**: writes cost instance memory and
  vanish with the instance. Keep state in a database or bucket.
- Shutdown sends **SIGTERM**, then SIGKILL **10 s** later: handle SIGTERM.
- **linux/amd64 only**: a multi-arch image's list must include it (build with
  `--platform linux/amd64` from an arm64 Mac).
- No privileged containers; setuid binaries fail for non-root users. If the
  image's `USER` names a user that does not exist, the container runs as root.
  Our templates create a non-root user and run as it.

## service.yaml (optional, declarative)

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: my-app            # <= 49 characters, unique per region and project
spec:
  template:
    spec:
      containers:
      - image: REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/my-app
        ports:
        - containerPort: 8080
```

`gcloud run services replace service.yaml` applies it. Field reference:
<https://cloud.google.com/run/docs/reference/yaml/v1>.

## Where to fetch canonical Google templates

All paths verified to exist on 2026-10-27 through the GitHub API:

- `GoogleCloudPlatform/python-docs-samples/run/helloworld/Dockerfile`,
  `GoogleCloudPlatform/golang-samples/run/helloworld/Dockerfile`,
  `GoogleCloudPlatform/nodejs-docs-samples/run/helloworld/Dockerfile`,
  `GoogleCloudPlatform/java-docs-samples/run/helloworld/`: per-language Cloud Run Dockerfiles.
- `GoogleCloudPlatform/cloud-run-samples`: more Cloud Run samples.
- `GoogleCloudPlatform/cloud-run-microservice-template-python`: a full service template.
- `GoogleCloudPlatform/buildpack-samples`: `sample-node`, `sample-python`, `sample-go`, `sample-java-mvn`, `sample-php-entrypoint-procfile`, ...
- `GoogleCloudPlatform/buildpacks`: the builder itself (detection in `cmd/<lang>/*/lib/lib.go`).
- `GoogleCloudPlatform/cloud-builders`: the `docker` and `gcloud` build-step images.

The forge's starting templates live in the `start-a-new-project` skill under
`templates/gcp/`.

## Not verified

- The console's default Dockerfile location (`/Dockerfile`) is what the
  operator saw; the doc page does not state it in text.
- No published maximum image size was found.
