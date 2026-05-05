---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://playwright.dev/docs/intro
  - https://playwright.dev/docs/locators
  - https://playwright.dev/docs/test-configuration
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Playwright

@trace spec:agent-cheatsheets

**Version baseline**: Playwright 1.45+ (install per-project; not in forge image — but `playwright install` fetches browser binaries automatically).
**Use when**: modern E2E browser testing — TypeScript/JavaScript primary, Python and Java also supported. Often preferred over Selenium for new projects.

## Provenance

- Playwright official documentation (Microsoft): <https://playwright.dev/docs/intro> — getting started, test runner, CLI flags
- Playwright locators reference: <https://playwright.dev/docs/locators> — `getByRole`, `getByLabel`, `getByText`, `getByTestId` priority
- Playwright configuration reference: <https://playwright.dev/docs/test-configuration> — `trace`, `screenshot`, `video`, `workers`, `fullyParallel`
- **Last updated:** 2026-04-25

Verified against official docs: `npx playwright test` runs tests (confirmed); `--headed` shows browser window (confirmed); `getByRole` accessibility-first locator (confirmed in locators docs); auto-waiting `expect(...).toBeVisible()` (confirmed — Playwright auto-waits on all `expect` assertions). `--debug`, `--trace on`, sharding (`--shard`), and storage state confirmed in the respective docs sections.

## Quick reference

| Command / Pattern | Effect |
|---|---|
| `npm i -D @playwright/test` | Install test runner + library |
| `npx playwright install` | Download Chromium / Firefox / WebKit binaries (~600 MB) |
| `npx playwright install --with-deps chromium` | One browser only, plus apt deps (Linux) |
| `npx playwright test` | Run all tests under `tests/` (or `playwright.config` `testDir`) |
| `npx playwright test path/to/spec.ts:42` | Run a single test by file:line |
| `npx playwright test -g "name"` | Filter by test title (regex) |
| `npx playwright test --project=chromium` | One browser only |
| `npx playwright test --headed` | Show the browser window (default headless) |
| `npx playwright test --debug` | Pause on first action, open Inspector |
| `npx playwright test --trace on` | Always record traces (zip per test) |
| `npx playwright show-trace trace.zip` | Open the timeline / DOM / console viewer |
| `npx playwright codegen URL` | Record clicks → generate test code |
| `npx playwright test --ui` | Interactive watch-mode UI |

**Locator priority** (accessibility-first; prefer top-down):
`getByRole` → `getByLabel` → `getByPlaceholder` → `getByText` → `getByTestId` → `locator(css|xpath)`.

## Common patterns

### Pattern 1 — Role-based locator + auto-waiting expect

```ts
import { test, expect } from '@playwright/test';

test('login flow', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('a@b.com');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('heading', { name: 'Welcome' })).toBeVisible();
});
```

`expect(...).toBeVisible()` retries until the timeout — no manual `waitFor` needed.

### Pattern 2 — Fixtures (auth state, custom page)

```ts
// fixtures.ts
import { test as base } from '@playwright/test';

export const test = base.extend<{ authedPage: Page }>({
  authedPage: async ({ browser }, use) => {
    const ctx = await browser.newContext({ storageState: 'auth.json' });
    await use(await ctx.newPage());
    await ctx.close();
  },
});
```

Then `import { test } from './fixtures'` and request `authedPage` like any built-in fixture.

### Pattern 3 — Trace viewer on failure (CI default)

```ts
// playwright.config.ts
export default defineConfig({
  use: { trace: 'retain-on-failure', screenshot: 'only-on-failure', video: 'retain-on-failure' },
});
```

`retain-on-failure` produces a `trace.zip` only for failing tests — keeps artifacts small. Open with `npx playwright show-trace`.

### Pattern 4 — Parallel workers + sharding

```ts
// playwright.config.ts
export default defineConfig({
  workers: process.env.CI ? 4 : '50%',
  fullyParallel: true,
});
```

```bash
npx playwright test --shard=1/4   # CI matrix: split across 4 jobs
```

### Pattern 5 — Reuse storage state across tests

```ts
// global-setup.ts — runs once before all tests
export default async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('/login'); /* ...sign in... */
  await page.context().storageState({ path: 'auth.json' });
  await browser.close();
};
```

Reference in config: `globalSetup: require.resolve('./global-setup')`. Skips per-test login.

## Common pitfalls

- **`playwright install` downloads ~600 MB of browsers** — slow first time (and bandwidth-hungry); subsequent runs hit the local cache. On the forge, the cache is ephemeral (see Forge-specific below).
- **CDP-based; Chromium has best fidelity** — Firefox and WebKit work, but some events (network throttling, advanced devtools features) are Chromium-only. Cross-browser bugs surface in CI more than dev.
- **Accessibility-first locators fail on poorly marked-up sites** — `getByRole('button', { name: ... })` returns nothing if the element is a `<div onclick>`. Fallbacks: `getByText`, then `locator('css=...')`, then a `data-testid`. Don't reach for XPath unless nothing else works.
- **Trace files are huge** — a single failing test can produce a 10–50 MB zip. Use `trace: 'retain-on-failure'` (not `'on'`) and prune CI artifacts on a schedule.
- **Storage state expires** — tokens / cookies in `auth.json` go stale. Re-run global setup periodically or detect 401 and re-auth. CI: regenerate per run.
- **Auto-waiting locators look like races but aren't** — `await page.click(...)` retries until the element is actionable. Adding manual `waitForTimeout(1000)` is almost always wrong; use `expect(locator).toBeVisible()` to assert state.
- **`page.locator(...)` vs `page.$(...)`** — `locator` is lazy + auto-retrying (preferred); `$` is a one-shot ElementHandle (legacy, deprecated for tests). New code should never use `$` / `$$`.
- **Cross-test state leaks via shared `context`** — by default each test gets a fresh BrowserContext (clean cookies, localStorage). Sharing one via fixture or `test.use({ storageState })` makes tests order-dependent. Keep contexts test-scoped unless deliberately sharing.
- **`webServer` in config doesn't restart between runs** — it's spawned once. If your dev server crashes mid-suite, all subsequent tests fail with connection refused. Set `reuseExistingServer: false` in CI.

## Forge-specific

`npx playwright install` reaches out to `playwright.azureedge.net` (Microsoft CDN) for browser binaries. The forge proxy must allowlist that domain or installation fails with a TLS / timeout error. The downloaded binaries land in `~/.cache/ms-playwright/` — ephemeral on container stop, so each fresh forge attach re-downloads (~600 MB, minutes on a slow proxy).

If frequent attach + test cycles, options to consider (out of scope here):
- Mount a persistent volume at `~/.cache/ms-playwright/` so binaries survive restart
- Bake a Playwright-preinstalled image variant
- Set `PLAYWRIGHT_BROWSERS_PATH=0` to install browsers next to `node_modules/` (committed to a project-local cache dir)

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://playwright.dev/docs/intro`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/playwright.dev/docs/intro`
- **License:** see-license-allowlist
- **License URL:** https://playwright.dev/docs/intro

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/playwright.dev/docs/intro"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://playwright.dev/docs/intro" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/test/playwright.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `test/selenium.md` — older alternative (WebDriver-based)
- `languages/typescript.md`, `languages/javascript.md` — host languages
- `runtime/networking.md` — proxy egress required for browser download
