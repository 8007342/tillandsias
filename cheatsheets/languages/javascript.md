# JavaScript

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: Node.js 22.x LTS (Fedora 43 `nodejs` package), ES2023 syntax
**Use when**: writing modern JS in the forge — Node scripts, browser code, glue.

## Quick reference

| Task | Command / syntax |
|------|------------------|
| Run script | `node script.js` |
| REPL | `node` (or `node -i -e "code"` to drop in after) |
| One-liner | `node -e "console.log(process.version)"` |
| ESM by default | `"type": "module"` in `package.json` (or use `.mjs`) |
| CJS file in ESM project | rename to `.cjs` |
| `const` / `let` | block-scoped; never use `var` |
| Destructuring | `const { a, b: alias = 1, ...rest } = obj` |
| Spread / rest | `[...arr, x]`, `{ ...obj, k: v }`, `(...args) => ...` |
| Optional chaining | `obj?.a?.b?.()` — short-circuits on `null`/`undefined` |
| Nullish coalescing | `value ?? fallback` (only `null`/`undefined`, NOT `0`/`""`) |
| Logical assign | `a ??= b`, `a ||= b`, `a &&= b` |
| Top-level `await` | allowed in ESM modules |
| Dynamic import | `const m = await import("./x.js")` |
| Native fetch (18+) | `await fetch(url).then(r => r.json())` |
| Native test runner | `node --test test/*.test.js` |
| Watch mode | `node --watch script.js` |
| Env file (20.6+) | `node --env-file=.env script.js` |
| Format / lint | `prettier --write .` / `eslint --fix .` |
| Type-check JS | `tsc --allowJs --checkJs --noEmit` (with JSDoc) |

## Common patterns

### async/await with error handling
```javascript
async function loadUser(id) {
  try {
    const res = await fetch(`/api/users/${id}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (err) {
    console.error("loadUser failed:", err);
    throw err; // re-throw so callers see it
  }
}
```
Always `await` inside `try` so the `catch` actually runs. A bare `return promise` skips it.

### Promise.all vs Promise.allSettled
```javascript
// All-or-nothing: rejects on first failure
const [user, posts] = await Promise.all([
  fetchUser(id),
  fetchPosts(id),
]);

// Best-effort: collect results AND failures
const results = await Promise.allSettled(urls.map(fetch));
const ok = results.filter(r => r.status === "fulfilled").map(r => r.value);
```
Use `all` when you need every result; `allSettled` when partial success is acceptable.

### Async iteration
```javascript
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";

const rl = createInterface({ input: createReadStream("big.log") });
for await (const line of rl) {
  if (line.includes("ERROR")) console.log(line);
}
```
`for await...of` consumes async iterables (streams, generators) one item at a time without loading all into memory.

### Dynamic import (code splitting / conditional)
```javascript
async function loadParser(format) {
  const mod = await import(`./parsers/${format}.js`);
  return mod.default;
}
```
`import()` returns a Promise — works in both ESM and CJS. Use for plugins, lazy loading, or to avoid heavy startup cost.

### structuredClone (deep copy, built-in since 17)
```javascript
const original = { a: 1, nested: { b: [2, 3] }, date: new Date() };
const copy = structuredClone(original);
copy.nested.b.push(4); // does NOT mutate original
```
Handles cycles, Maps/Sets/Dates, typed arrays. Beats `JSON.parse(JSON.stringify(x))` (which loses Dates, undefined, functions).

## Common pitfalls

- **`==` vs `===`** — `==` does type coercion (`0 == ""`, `null == undefined`, `[] == false`). Always use `===`/`!==` unless you specifically need coercion (and you don't).
- **`this` binding in callbacks** — `arr.map(obj.method)` loses `this`. Use arrow functions (`arr.map(x => obj.method(x))`) or `obj.method.bind(obj)`. Arrow functions inherit `this` from the enclosing scope; regular functions do not.
- **ESM vs CJS interop** — ESM (`import`) and CJS (`require`) don't mix freely. CJS can't `require()` an ESM module synchronously; use dynamic `import()`. ESM can import CJS but only the default export is reliable. Set `"type": "module"` in `package.json` and stick with one.
- **Unhandled promise rejections** — a `Promise` that rejects without a `.catch()` (or `await` in a `try`) crashes Node 15+ by default. Always `await` in `try/catch` or attach `.catch()`. For top-level scripts, wrap in `(async () => { ... })().catch(console.error)`.
- **Spread is shallow** — `{ ...obj }` and `[...arr]` only copy one level deep. Nested objects/arrays are shared references. Use `structuredClone(obj)` for true deep copy.
- **`forEach` ignores async** — `arr.forEach(async x => await save(x))` returns immediately; the awaits run unsupervised. Use `for...of` with `await` (sequential) or `await Promise.all(arr.map(async x => save(x)))` (parallel).
- **`JSON.stringify` drops `undefined` and functions** — `JSON.stringify({ a: undefined, b: () => 1 })` -> `"{}"`. Also throws on circular references and BigInts. Use `structuredClone` for cloning, custom `replacer` for serialization.
- **Floating-point math** — `0.1 + 0.2 === 0.3` is `false` (it's `0.30000000000000004`). Use `Math.abs(a - b) < Number.EPSILON` for equality, or work in integer cents. For arbitrary precision, use `BigInt` (integers only) or a decimal library.
- **`for...in` vs `for...of`** — `for...in` iterates enumerable string keys (including inherited!); `for...of` iterates iterable values. On arrays, `for...in` gives indices as strings (`"0"`, `"1"`) and may include extra properties. Use `for...of` for arrays, `Object.entries()` for objects.
- **`npm install -g` in the forge** — writes to a path on the ephemeral overlay and lost on container stop. Install per-project (`npm install`, then run via `npx` or `package.json` scripts), or bake the tool into the forge image.
- **Mutating array methods return undefined** — `arr.sort()`, `arr.reverse()`, `arr.push()` mutate in place. The non-mutating versions (`toSorted`, `toReversed`, `with`) are ES2023. Don't chain off mutators expecting a new array.

## See also

- `languages/typescript.md` — type-checked superset
- `languages/json.md` — data interchange format
- `build/npm.md` — default Node package manager
- `build/pnpm.md` — fast, disk-efficient alternative
- `build/yarn.md` — alternative package manager
- `test/node-test.md` — built-in test runner
- `runtime/forge-container.md` — why per-project installs (not `npm install -g`) in the forge
