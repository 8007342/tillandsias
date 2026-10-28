# Deploying to Google Cloud Run

Read this after the user chose a Google Cloud option in step 4b.

## Cost, said plainly

Google Cloud needs a billing account with a payment method, even to use its
free allowance. Small apps usually stay inside the free monthly allowance
(Cloud Run: 2 million requests; Cloud Build: 2,500 build-minutes; Artifact
Registry: 0.5 GiB, as published on 2026-10-27), and use beyond it is charged.
You never create projects, link billing, enable APIs or run cloud builds; the
user does those in their own console.

## What the setup script added

| File | Option | What it is |
|---|---|---|
| `Dockerfile` | Dockerfile | builds and runs the app; listens on `$PORT` (8080) on 0.0.0.0, as a non-root user |
| `nginx.conf.template` | Dockerfile, static | serves `build/web` (run `flutter build web` first) and falls back to `index.html` |
| `.dockerignore` | Dockerfile | keeps local folders out of the build |
| `cloudbuild.yaml` | Dockerfile | optional build, push and deploy pipeline; the console trigger works without it |
| `project.toml` | Buildpacks | pins the runtime the builder would otherwise guess |
| `service.yaml` | both | the Cloud Run service, declared (replace IMAGE before applying) |

## What the user does in the Google Cloud console

1. Create or pick a project with billing enabled.
2. Cloud Run → Create service → "Continuously deploy from a repository".
3. Connect GitHub through Cloud Build or Developer Connect and pick the repo
   and branch.
4. Build type: **Dockerfile** (source location `/Dockerfile`) or **Google
   Cloud's buildpacks**, matching the option chosen here.
5. Save. Each push to the branch then builds and deploys.

## Reference and canonical sources

The forge's reference notes cover each path in depth, with sources:
`$TILLANDSIAS_CHEATSHEETS/cloud/gcp-cloud-run-deploy-paths.md`,
`gcp-dockerfile-for-cloud-run.md`, `gcp-buildpacks.md` and
`gcp-cloudbuild-yaml.md`. Google's own templates to fetch from:

- `GoogleCloudPlatform/{python,golang,nodejs}-docs-samples/run/helloworld/Dockerfile`
- `GoogleCloudPlatform/buildpack-samples` (`sample-node`, `sample-python`, `sample-go`, ...)
- `GoogleCloudPlatform/cloud-run-samples`
- `GoogleCloudPlatform/cloud-builders` (`docker/`, `gcloud/`)
