# TypeScript

@trace spec:agent-cheatsheets

## Provenance

- TypeScript official documentation (Microsoft): <https://www.typescriptlang.org/docs/> — handbook covering generics, conditional types, mapped types, template literal types, keyof, utility types (Pick/Omit/Partial/Required/Readonly/Record/ReturnType/Awaited/NonNullable), TSConfig reference (strict, noUncheckedIndexedAccess, exactOptionalPropertyTypes, NodeNext module resolution)
- TypeScript 4.9 release notes (satisfies operator): <https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-9.html> — satisfies operator validation behavior
- **Last updated:** 2026-04-25

**Version baseline**: TypeScript 5.x (install per-project: `npm i -D typescript`)
**Use when**: writing TS in the forge — type system, generics, build setup.

## Quick reference

| Task | Command / syntax |
|------|------------------|
| Init project | `npm init -y && npm i -D typescript @types/node` |
| Init tsconfig | `npx tsc --init --strict` |
| Compile | `npx tsc` (or `npx tsc -w` to watch) |
| Type-check only | `npx tsc --noEmit` |
| Run TS directly | `npx tsx script.ts` (or `node --experimental-strip-types script.ts` on Node 22.6+) |
| Primitives | `string`, `number`, `boolean`, `bigint`, `symbol`, `null`, `undefined` |
| Top types | `unknown` (safe), `any` (escape hatch) |
| Bottom type | `never` (unreachable, exhaustiveness) |
| Literal union | `type Mode = "r" \| "w" \| "rw"` |
| Tuple | `type Pair = [string, number]` |
| Readonly | `readonly T[]` or `ReadonlyArray<T>` |
| Const assertion | `const x = { a: 1 } as const` (deep readonly + literal) |
| `satisfies` (4.9+) | `const x = {...} satisfies Config` (validate without widening) |
| Generic constraint | `<T extends { id: string }>` |
| Conditional type | `T extends U ? X : Y` |
| Mapped type | `{ [K in keyof T]: ... }` |
| Template literal type | `` `prefix-${string}` `` |
| Strict flags (recommended) | `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes` |
| Module style | `"module": "NodeNext"` + `"moduleResolution": "NodeNext"` for modern Node |

## Common patterns

### Pattern 1 — discriminated unions
```ts
type Result<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

function unwrap<T>(r: Result<T>): T {
  if (r.ok) return r.value;   // narrowed to success arm
  throw new Error(r.error);    // narrowed to error arm
}
```
Tag every variant with the same literal field (`ok`, `kind`, `type`). The compiler narrows the union inside `if`/`switch`.

### Pattern 2 — generics with constraints
```ts
function pluck<T, K extends keyof T>(items: T[], key: K): T[K][] {
  return items.map((i) => i[key]);
}
const ids = pluck([{ id: 1, name: "a" }], "id"); // number[]
```
`K extends keyof T` ties the key parameter to the object's actual keys — typos become compile errors.

### Pattern 3 — utility types (Pick / Omit / Partial / Required)
```ts
interface User { id: string; name: string; email: string; createdAt: Date }

type UserSummary = Pick<User, "id" | "name">;
type UserUpdate  = Partial<Omit<User, "id" | "createdAt">>;
type RequiredUser = Required<User>; // strip `?` from optional fields
```
Compose built-ins instead of redefining shapes. Also useful: `Readonly<T>`, `Record<K, V>`, `ReturnType<F>`, `Awaited<P>`, `NonNullable<T>`.

### Pattern 4 — async + Promise<T>
```ts
async function fetchUser(id: string): Promise<User> {
  const res = await fetch(`/api/users/${id}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return (await res.json()) as User; // validate at runtime if input is untrusted
}

const users = await Promise.all(ids.map(fetchUser));
```
`async` functions always return `Promise<T>`. Prefer `Promise.all` over sequential `await` in loops when requests are independent.

### Pattern 5 — type guards & exhaustiveness
```ts
function isString(x: unknown): x is string {
  return typeof x === "string";
}

type Shape = { kind: "circle"; r: number } | { kind: "square"; side: number };
function area(s: Shape): number {
  switch (s.kind) {
    case "circle": return Math.PI * s.r ** 2;
    case "square": return s.side ** 2;
    default: { const _exhaustive: never = s; return _exhaustive; }
  }
}
```
User-defined type guards (`x is T`) narrow `unknown`. The `never` assignment forces a compile error if a new variant is added.

## Common pitfalls

- **`any` vs `unknown`** — `any` opts out of type checking everywhere it propagates. `unknown` forces you to narrow before use. Default to `unknown` for external input (JSON, `catch (e)`, `fetch().json()`); reach for `any` only as a deliberate, scoped escape hatch.
- **Narrowing failures via aliasing** — assigning a narrowed value to a `let` widens it; control-flow narrowing only tracks the original symbol. Use `const` for narrowed locals, or re-narrow after the assignment.
- **Structural typing surprises** — TS compares shapes, not nominal names. `interface Dog { name: string }` and `interface Cat { name: string }` are interchangeable. Use a brand (`type UserId = string & { __brand: "UserId" }`) when nominal identity matters.
- **`strict` half-on** — turning on `strict` is necessary but not sufficient. Also enable `noUncheckedIndexedAccess` (so `arr[0]` is `T | undefined`) and `exactOptionalPropertyTypes` (so `{ x?: number }` rejects `{ x: undefined }`). Without these, real bugs slip through.
- **ESM vs CJS in Node** — `"type": "module"` in `package.json` switches the package to ESM; relative imports must include the `.js` extension (yes, `.js` even from `.ts`) under `NodeNext`. Mixing `require` and `import` in the same file fails. Pick one per package.
- **`as` casts hide bugs** — `obj as Foo` is an unchecked assertion, not a conversion. The compiler trusts you. Prefer `satisfies` (validates without widening) or a runtime validator (zod, valibot) when the value crosses a trust boundary.
- **`Function` and `{}` types** — both are nearly-top types that match almost anything. Use `(...args: never[]) => unknown` for callables and `object` (or `Record<string, unknown>`) for objects.
- **Enums (especially numeric)** — numeric enums are bidirectional, leak runtime objects, and don't tree-shake well. Prefer `const enum` (inlined), or just a literal union (`type Status = "open" | "closed"`) with `as const` objects.
- **`tsc` does not bundle** — `tsc` only emits `.js` per `.ts` file. For browser bundles use vite/esbuild/rollup; for Node use `tsx` (dev) or compile + `node` (prod). Don't expect `tsc` to resolve aliases at runtime — `paths` in tsconfig is type-only.
- **`@types/*` version drift** — `@types/node` major must roughly match the Node runtime; mismatched DOM lib targets (`"lib": ["ES2022"]` without `"DOM"`) make `fetch`/`URL` vanish. Pin both.

## See also

- `languages/javascript.md` — runtime semantics underneath TS
- `build/npm.md`, `build/pnpm.md`, `build/yarn.md` — package management
- `test/playwright.md` — E2E testing in TS
