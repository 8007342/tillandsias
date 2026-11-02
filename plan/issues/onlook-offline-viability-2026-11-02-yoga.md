# Onlook offline viability — 1865-dn5h measurement (yoga, 2026-11-02)

**Verdict: Onlook cannot run offline in a forge. It stays listed as
"needs cloud account" and is never `[Recommended]`; no lane is built.**

## What was read, and how

A shallow clone of `https://github.com/onlook-dev/onlook` (main at `423e2e9`,
committed 2026-07-21; licence Apache-2.0), read inside a throwaway
`node:22.19.0-bookworm-slim` container on yoga. Nothing was installed on the
host, and Onlook's own dependency tree was NOT installed (see "Not done").

- `docs/content/docs/developers/running-locally.mdx`: local development is
  "a Next.js app, a Supabase backend, and the ability to run dev containers
  with Codesandbox". Step 3a, "Get Codesandbox API key", is required, and the
  guide says: "We plan on enabling running the dev containers with Docker
  Desktop in the future after we figure out the best API integration."
- `packages/code-provider/package.json` depends on `@codesandbox/sdk`. The
  editor's file sync
  (`apps/web/client/src/components/store/editor/sandbox/index.ts`,
  `apps/web/client/src/services/sync-engine/sync-engine.ts`) works against
  that sandbox.
- `apps/web/client/.env.example` lists `CSB_API_KEY` beside a Supabase
  backend (`NEXT_PUBLIC_SUPABASE_URL`, `SUPABASE_DATABASE_URL`, run with
  Docker) and hosted model keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, …).

## What that means for the exit criterion

The criterion asks whether, in a forge with egress=none, an edit on a Next.js
+ Tailwind fixture lands in the checkout. With Onlook as published:
- **It cannot start a project.** The project's dev container is a CodeSandbox
  cloud sandbox, which needs a CodeSandbox account (API key) and network
  egress to CodeSandbox.
- **An edit would land in the cloud sandbox, not the forge checkout.** The
  file sync is with the sandbox.

That is the degraded outcome. The registry row matches it
(`needs_cloud_account = true`, `frameworks = {}`, a brief that says why, and
a launch refusal that names the reason), and
`studio::tests::onlook_is_never_recommended_and_says_why_it_cannot_launch` pins it.

## Not done, on purpose

- Onlook was **not run**. Running it means installing its bun monorepo (and a
  Supabase stack) in a throwaway container. That needs a licence census and
  an operator ruling first (the operator's rule: no licence accepted without
  discussing it). It would also only reach the step that asks for the
  CodeSandbox key the guide calls mandatory. The source and the project's
  own guide settle the question without it.
- **Re-measure** when Onlook ships the Docker dev-container path its guide
  plans. Then the question becomes real: a local container in a forge.
