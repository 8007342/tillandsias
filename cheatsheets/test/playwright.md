# Playwright

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: Playwright 1.45+ (install per-project; not in forge image — but `playwright install` fetches browser binaries automatically).
**Use when**: modern E2E browser testing — TypeScript/JavaScript primary, Python and Java also supported. Often preferred over Selenium for new projects.

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

## See also

- `test/selenium.md` — older alternative (WebDriver-based)
- `languages/typescript.md`, `languages/javascript.md` — host languages
- `runtime/networking.md` — proxy egress required for browser download
