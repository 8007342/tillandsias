---
tags: [google-cloud, gcp, cloud-build, cloudbuild-yaml, artifact-registry, cloud-run, ci]
languages: [yaml]
since: 2026-10-27
last_verified: 2026-10-27
sources:
  - https://cloud.google.com/build/docs/build-config-file-schema
  - https://cloud.google.com/build/docs/configuring-builds/substitute-variable-values
  - https://cloud.google.com/build/docs/deploying-builds/deploy-cloud-run
  - https://cloud.google.com/artifact-registry/docs/docker/names
  - https://github.com/GoogleCloudPlatform/cloud-builders
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# cloudbuild.yaml for Cloud Run

@trace order:1906-md6q

**Use when**: a repo needs its own Cloud Build pipeline (tests before deploy,
a non-root Dockerfile path, extra steps) instead of the console's built-in
Dockerfile or buildpacks trigger.

## Provenance

- Build config schema: <https://cloud.google.com/build/docs/build-config-file-schema>
- Substitutions: <https://cloud.google.com/build/docs/configuring-builds/substitute-variable-values>
- Deploying to Cloud Run with Cloud Build: <https://cloud.google.com/build/docs/deploying-builds/deploy-cloud-run>
- Artifact Registry image names: <https://cloud.google.com/artifact-registry/docs/docker/names>
- Build step images: <https://github.com/GoogleCloudPlatform/cloud-builders> (`docker/`, `gcloud/`)
- **Last updated:** 2026-10-27 (fetched and read that day by lenovinha for order 1906-md6q)

Billing: Cloud Build gives 2,500 free build-minutes a month per billing
account, and a billing account is required. See
`cloud/gcp-cloud-run-deploy-paths.md` → Cost.

## Google's canonical build → push → deploy

```yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '$_REGION-docker.pkg.dev/$PROJECT_ID/$_REPOSITORY/$_SERVICE_NAME:$SHORT_SHA', '.']
- name: 'gcr.io/cloud-builders/docker'
  args: ['push', '$_REGION-docker.pkg.dev/$PROJECT_ID/$_REPOSITORY/$_SERVICE_NAME:$SHORT_SHA']
- name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
  entrypoint: gcloud
  args: ['run', 'deploy', '$_SERVICE_NAME',
         '--image', '$_REGION-docker.pkg.dev/$PROJECT_ID/$_REPOSITORY/$_SERVICE_NAME:$SHORT_SHA',
         '--region', '$_REGION']
images: ['$_REGION-docker.pkg.dev/$PROJECT_ID/$_REPOSITORY/$_SERVICE_NAME:$SHORT_SHA']
substitutions:
  _REGION: us-central1
  _REPOSITORY: cloud-run-source-deploy
  _SERVICE_NAME: my-app
```

The doc's example uses literal placeholders; the substitutions above are the
same steps parameterised. `$SHORT_SHA` is set only on triggered builds, so a
manual `gcloud builds submit --region=REGION` of this file needs a tag of its
own: swap `$SHORT_SHA` for a user substitution such as `$_TAG` and pass
`--substitutions=_TAG=...`.

## Schema essentials

- Step fields: `name` (builder image), `args`, `env`, `id`, `waitFor`,
  `entrypoint`, `dir`, `secretEnv`, `script`, `timeout`.
- Top level: `steps`, `images`, `options`, `substitutions`, `timeout`,
  `artifacts`, `logsBucket`, `queueTtl`.
- Built-in substitutions: `$PROJECT_ID`, `$BUILD_ID`; on
  triggered builds also `$COMMIT_SHA`, `$SHORT_SHA` (7 chars), `$BRANCH_NAME`,
  `$TAG_NAME`, `$REPO_NAME`, `$REPO_FULL_NAME`, `$TRIGGER_NAME`, `$REVISION_ID`.
- User substitutions must match `_[A-Z0-9_]+`. Write a literal `$` as `$$`.
- Image path: `LOCATION-docker.pkg.dev/PROJECT-ID/REPOSITORY/IMAGE[:tag|@digest]`.

The forge's starting `cloudbuild.yaml` lives in the `start-a-new-project`
skill under `templates/gcp/`.
