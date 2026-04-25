# HTML

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: HTML5 (WHATWG Living Standard)
**Use when**: writing HTML — pages, components, email-safe markup.

## Quick reference

| Element / attr | Purpose |
|----------------|---------|
| `<!DOCTYPE html>` | Triggers standards mode; first line, no version |
| `<html lang="en">` | Required for accessibility + SEO |
| `<meta charset="utf-8">` | First child of `<head>`; before any text |
| `<meta name="viewport" content="width=device-width, initial-scale=1">` | Mobile responsive baseline |
| `<header>` / `<footer>` | Page or section banner / footer |
| `<nav>` | Primary navigation block (one per landmark) |
| `<main>` | Unique main content; one per page |
| `<article>` | Self-contained, syndicatable content |
| `<section>` | Thematic grouping with a heading |
| `<aside>` | Tangentially related (sidebar, pull quote) |
| `<figure>` / `<figcaption>` | Image + caption, semantically linked |
| `<picture>` + `<source>` | Art direction / format fallback |
| `<dialog>` | Native modal; `.showModal()` / `.close()` |
| `<details>` / `<summary>` | Native disclosure widget |
| `<input type="...">` | `email`, `tel`, `url`, `number`, `date`, `search`, `color` |
| `<label for="id">` | Click-target + screen reader name |
| `aria-label="..."` | Accessible name when no visible label |
| `aria-live="polite"` | Announce dynamic updates to AT |
| `role="..."` | Override semantics (rarely needed; use real tags) |
| `data-*="..."` | Custom attributes; read via `el.dataset.*` |
| `loading="lazy"` | Defer offscreen `<img>` / `<iframe>` |

## Common patterns

### Semantic page structure
```html
<body>
  <header><h1>Site</h1><nav>...</nav></header>
  <main>
    <article>
      <h2>Title</h2>
      <section><h3>Part 1</h3>...</section>
    </article>
    <aside>Related links</aside>
  </main>
  <footer>...</footer>
</body>
```
Landmarks (`header`, `nav`, `main`, `aside`, `footer`) let assistive tech skip between regions. One `<main>` per page.

### Accessible form
```html
<form action="/subscribe" method="post">
  <label for="email">Email</label>
  <input id="email" name="email" type="email" required autocomplete="email">

  <fieldset>
    <legend>Frequency</legend>
    <label><input type="radio" name="freq" value="d"> Daily</label>
    <label><input type="radio" name="freq" value="w" checked> Weekly</label>
  </fieldset>

  <button type="submit">Subscribe</button>
</form>
```
Every input needs a `<label for="id">` (or wrap the input). `autocomplete` enables password managers / browser fill. Group radios in a `<fieldset>`.

### Responsive images
```html
<picture>
  <source type="image/avif" srcset="hero.avif">
  <source type="image/webp" srcset="hero.webp">
  <img src="hero.jpg" alt="Sunset over the bay"
       width="1600" height="900" loading="lazy">
</picture>

<img srcset="small.jpg 480w, large.jpg 1600w"
     sizes="(max-width: 600px) 480px, 1600px"
     src="large.jpg" alt="...">
```
`<picture>` for format fallback (AVIF/WebP/JPEG). `srcset` + `sizes` for resolution switching. Always set `width`/`height` to prevent layout shift.

### data-* attributes
```html
<button data-action="delete" data-id="42">X</button>
<script>
  document.addEventListener("click", e => {
    const btn = e.target.closest("[data-action]");
    if (!btn) return;
    const { action, id } = btn.dataset; // "delete", "42"
  });
</script>
```
`data-foo-bar` -> `el.dataset.fooBar`. Strings only — parse numbers/JSON yourself.

### Native dialog (modal)
```html
<dialog id="confirm">
  <form method="dialog">
    <p>Delete this file?</p>
    <button value="cancel">Cancel</button>
    <button value="ok">Delete</button>
  </form>
</dialog>
<script>
  document.getElementById("confirm").showModal();
</script>
```
`.showModal()` traps focus + adds backdrop. `<form method="dialog">` closes with the button's `value` as `dialog.returnValue` — no JS handler needed.

## Common pitfalls

- **Block-vs-inline nesting** — `<div>` inside `<p>` is invalid; the parser closes the `<p>` early and you get unexpected DOM. `<p>` only accepts phrasing content (`<span>`, `<a>`, `<strong>`).
- **Nested forms forbidden** — a `<form>` cannot contain another `<form>`. The inner one is silently dropped. Use `form="id"` on inputs to associate with a sibling form instead.
- **Missing or wrong `alt`** — every `<img>` needs `alt`. Decorative images get `alt=""` (empty, not missing). Don't write "image of..." — screen readers already announce it's an image.
- **`autocomplete="off"` ignored on passwords** — modern browsers override this for password managers. Use `autocomplete="new-password"` or `"current-password"` to actually steer the manager.
- **Void elements and self-closing slashes** — `<img>`, `<br>`, `<input>`, `<meta>`, `<link>`, `<hr>` have no closing tag. The XHTML-style `<br />` is allowed but meaningless in HTML5; never write `</img>` or `<div />` (the latter is treated as an open `<div>`).
- **Heading order skips** — jumping from `<h1>` to `<h3>` confuses screen readers and outline tools. Headings define a hierarchy; don't pick by visual size — style with CSS.
- **Click handlers on `<div>`** — a clickable `<div>` is invisible to keyboards and AT. Use `<button type="button">` for actions, `<a href>` for navigation. If you must use `<div>`, add `role="button"`, `tabindex="0"`, and Enter/Space handlers (you'll forget one).
- **Inline event handlers + CSP** — `<button onclick="...">` is blocked by any reasonable Content-Security-Policy. Bind in JS with `addEventListener`.
- **`<button>` defaults to `type="submit"`** — inside a `<form>`, a `<button>` with no `type` submits the form on click. Always set `type="button"` for non-submit buttons.
- **`<table>` for layout** — use CSS Grid / Flexbox. Reserve `<table>` for actual tabular data; screen readers announce row/column counts and treat it as data.
- **Charset declared too late** — `<meta charset>` must appear in the first 1024 bytes of the document. Put it as the first child of `<head>`, before `<title>`.

## See also

- `languages/css.md` — styling
- `languages/javascript.md` — interactivity
- `web/http.md` — content-type, caching
