---
tags: [nodejs, test, javascript, cli]
languages: [javascript]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://nodejs.org/api/test.html
authority: high
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Node.js test runner

@trace spec:agent-cheatsheets

**Use when**: testing JavaScript or TypeScript projects with Node's built-in `node:test` runner instead of adding Jest, Mocha, or Vitest.

## Provenance

- Node.js `test` module docs: <https://nodejs.org/api/test.html>
- **Last updated:** 2026-05-19

## Quick reference

| Command/API | Purpose |
|---|---|
| `node --test` | Run test files discovered by Node |
| `node --test path/to/file.test.js` | Run one test file |
| `import test from "node:test"` | Define a test |
| `import assert from "node:assert/strict"` | Built-in assertions |
| `test.only(...)` | Focus during local debugging; remove before commit |

## Common patterns

### Basic test

```javascript
import test from "node:test";
import assert from "node:assert/strict";

test("adds values", () => {
  assert.equal(1 + 1, 2);
});
```

### Async test

```javascript
test("loads data", async () => {
  const data = await loadData();
  assert.ok(data.length > 0);
});
```

## Common pitfalls

- **Committing focused tests** - `only` hides the rest of the suite.
- **Mixing runner globals** - Jest globals are not available unless that runner is installed.
- **Leaking timers or handles** - async resources can keep the process alive.
- **Assuming TypeScript support** - use the project's configured transpiler or loader.

## See also

- `languages/javascript.md` - JavaScript language baseline
- `build/npm.md` - package scripts and dependency commands

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull the Node API docs for current CLI flags, mocks, snapshots, and coverage options.

- **Upstream URL(s):**
  - `https://nodejs.org/api/test.html`
- **Archive type:** single-page reference
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/test/node-test`
- **License:** upstream-documentation
- **License URL:** `https://github.com/nodejs/node/blob/main/LICENSE`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/test/node-test"
mkdir -p "$TARGET"
cp cheatsheets/test/node-test.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Check the project Node version before using new `node:test` flags or APIs.
2. Keep runner-specific globals out of examples unless the runner is installed.
