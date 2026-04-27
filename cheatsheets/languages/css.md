---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://developer.mozilla.org/en-US/docs/Web/CSS
  - https://www.w3.org/TR/css-2023/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# CSS

@trace spec:agent-cheatsheets

## Provenance

- MDN CSS Reference (Mozilla): <https://developer.mozilla.org/en-US/docs/Web/CSS> — canonical reference for all CSS properties, selectors, units, flexbox, grid, custom properties, container queries, :has(), dvh/svh, oklch()
  local: `cheatsheet-sources/developer.mozilla.org/en-US/docs/Web/CSS`
- W3C CSS Snapshot 2023: <https://www.w3.org/TR/css-2023/> — normative spec list covering Flexbox Level 1, Grid Level 2, Custom Properties, Selectors Level 4, Containment Level 3
  local: `cheatsheet-sources/www.w3.org/TR/css-2023`
- **Last updated:** 2026-04-25

**Version baseline**: Modern CSS (Baseline 2024 — flexbox, grid, custom properties, container queries, `:has()`)
**Use when**: writing styles — layout, theming, responsive design.

## Quick reference

| Selector | Matches |
|----------|---------|
| `.cls` / `#id` / `tag` | class / id / element |
| `a > b` / `a b` | direct child / any descendant |
| `a + b` / `a ~ b` | next sibling / any later sibling |
| `[attr="v"]` / `[attr^="p"]` / `[attr*="s"]` | exact / prefix / contains |
| `:hover` `:focus-visible` `:disabled` | interaction state |
| `:nth-child(2n+1)` / `:first-child` | structural position |
| `:not(.x)` / `:is(h1, h2)` / `:where(...)` | negation / match-any (`:where` has 0 specificity) |
| `:has(> img)` | parent selector — matches if descendant matches |
| `::before` / `::after` / `::placeholder` | pseudo-elements (need `content:` for `::before`/`::after`) |

| Unit | Use for |
|------|---------|
| `rem` | font sizes, spacing — relative to root font size |
| `em` | sizes that should scale with parent text |
| `px` | borders, hairlines, fixed visuals |
| `%` | widths/heights relative to parent's same dimension |
| `vh` / `vw` / `dvh` / `svh` | viewport — `dvh`/`svh` handle mobile URL bar |
| `ch` / `ex` | character-width / x-height (text-aware) |
| `fr` (grid only) | fractional remaining space |

| Property | Common values |
|----------|---------------|
| `display` | `block` `inline` `inline-block` `flex` `grid` `contents` `none` |
| `position` | `static` `relative` `absolute` `fixed` `sticky` |
| `box-sizing` | `border-box` (set globally — see pitfalls) |

## Common patterns

### Flexbox row/column
```css
.toolbar {
  display: flex;
  gap: 0.5rem;             /* replaces margin hacks */
  align-items: center;     /* cross-axis */
  justify-content: space-between; /* main-axis */
  flex-wrap: wrap;
}
.toolbar > .spacer { flex: 1; } /* grow to fill */
```
`gap` works in flex (Baseline 2021+). One-dimensional layouts.

### Grid two-column with sidebar
```css
.layout {
  display: grid;
  grid-template-columns: 240px 1fr;
  grid-template-areas: "nav main";
  gap: 1rem;
  min-height: 100dvh;
}
.layout > nav  { grid-area: nav; }
.layout > main { grid-area: main; }
```
Two-dimensional layouts. `1fr` = "rest of available space".

### Custom properties + theming
```css
:root {
  --bg: white;
  --fg: #222;
  --accent: oklch(60% 0.2 250);
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #111; --fg: #eee; }
}
body { background: var(--bg); color: var(--fg); }
.button { background: var(--accent, blue); } /* fallback */
```
Custom properties cascade and inherit (unlike Sass variables). Toggle themes by swapping values, not selectors.

### Container queries
```css
.card-list { container-type: inline-size; container-name: cards; }

@container cards (min-width: 600px) {
  .card { display: grid; grid-template-columns: 120px 1fr; }
}
```
Style based on the *container's* size, not the viewport. Components become truly reusable.

### `:has()` parent selector
```css
/* Style the form when it contains an invalid input */
form:has(input:invalid) .submit { opacity: 0.5; }

/* Style a label that wraps a checked checkbox */
label:has(> input[type="checkbox"]:checked) { font-weight: bold; }

/* Hide a section with no children */
section:has(> *) { display: block; }
section:not(:has(> *)) { display: none; }
```
Replaces most JS-driven class toggling. Baseline 2023+.

## Common pitfalls

- **Specificity wars** — count selectors as `(inline, ids, classes/attrs/pseudo-classes, elements/pseudo-elements)`. `#a .b span` = `(0,1,1,1)` beats `.x.y.z` = `(0,0,3,0)`. Use `:where(...)` (0 specificity) for utility/reset rules. Reach for `!important` only after counting — it's an escape hatch, not a tool.
- **Stacking context confusion** — `z-index` only works on positioned elements (`position` not `static`) OR flex/grid items with `z-index` set. Many properties create a new stacking context (`transform`, `opacity < 1`, `filter`, `will-change`, `position: fixed`). A child can never escape its parent's stacking context — so a `z-index: 9999` modal won't appear above a sibling's `transform: translateZ(0)` ancestor.
- **Margin collapse** — adjacent vertical margins between block siblings collapse to the larger value. Margins also collapse through empty parents (no padding/border). Prevent with `display: flex`/`grid` on the parent, or add `padding: 0.01px` (ugly but works). Horizontal margins never collapse.
- **Default `min-width: auto` on flex/grid items** — flex/grid items refuse to shrink below their content's intrinsic size. A long word or `<pre>` block blows out the layout. Fix with `min-width: 0` (or `min-height: 0` on column layouts) on the flex/grid child. Required for `text-overflow: ellipsis` inside flex.
- **`transform`/`filter`/`opacity` create stacking contexts AND containing blocks** — `position: fixed` children get positioned relative to a transformed ancestor instead of the viewport. Surprises CSS animations and modals.
- **`box-sizing` defaults to `content-box`** — `width: 100%; padding: 1rem;` overflows the parent because padding adds to width. Set globally: `*, *::before, *::after { box-sizing: border-box; }`.
- **`100vh` on mobile** — includes the URL bar's hidden area, so content gets cut off when the bar collapses. Use `100dvh` (dynamic) or `100svh` (smallest) — Baseline 2023+.
- **Inheritance gaps** — most properties inherit (`color`, `font`), many don't (`background`, `border`, `padding`, `display`). `background: inherit` works but is rarely what you want. Use custom properties to share values across non-inheriting properties.
- **`display: none` vs `visibility: hidden` vs `opacity: 0`** — `none` removes from layout AND accessibility tree (screen readers skip it); `hidden` reserves space, removed from a11y tree; `opacity: 0` reserves space, still focusable and read aloud. Add `aria-hidden="true"` and `pointer-events: none` if you mean "invisible but present".
- **Specificity of `:not()`, `:is()`, `:has()`** — `:is(a, .b, #c)` takes the *highest* specificity of its arguments (`#c`). `:not(.x)` adds the specificity of `.x`. `:where(...)` always contributes 0 — use it when you don't want to inflate specificity.

## See also

- `languages/html.md` — what you're styling
