# Markdown

@trace spec:agent-cheatsheets

**Version baseline**: CommonMark 0.31 + GitHub Flavored Markdown (GFM) extensions
**Use when**: writing READMEs, cheatsheets, OpenSpec docs, anything in this repo.

## Quick reference

| Syntax | Renders as |
|--------|------------|
| `# H1` ... `###### H6` | Headings (ATX style; prefer over Setext `===`/`---`) |
| `**bold**` / `*italic*` | Strong / emphasis (underscores `__`/`_` also work) |
| `~~strike~~` | Strikethrough (GFM) |
| `` `code` `` | Inline code; double backticks if content has a backtick |
| ` ```lang ` ... ` ``` ` | Fenced code block with language hint |
| `- item` / `* item` / `1. item` | Bullet / ordered list |
| `- [ ]` / `- [x]` | Task list (GFM) |
| `> quote` | Blockquote (stack `>>` for nesting) |
| `[text](url)` / `[text](url "title")` | Inline link |
| `[text][ref]` ... `[ref]: url` | Reference-style link |
| `![alt](url)` | Image |
| `<https://...>` / `<a@b.com>` | Autolink |
| `---` on its own line | Horizontal rule (also `***`, `___`) |
| `\|col\|col\|` + `\|---\|---\|` | Table (GFM) with header separator row |
| `:---` / `:---:` / `---:` | Table column align: left / center / right |
| `text[^1]` ... `[^1]: note` | Footnote (GFM) |
| `\*` `\_` `\\` `\|` | Backslash-escape literal markdown chars |

## Common patterns

### Fenced code block with language
````markdown
```rust
fn main() { println!("hi"); }
```
````
The language tag enables syntax highlighting on GitHub and most renderers. Use ` ```text ` for plain output to suppress highlighting.

### Aligned table
```markdown
| Name | Count | Price |
|:-----|:-----:|------:|
| apple |  3   |  1.20 |
| pear  | 12   | 14.40 |
```
Colons in the separator row set alignment. Pipes don't need to line up — renderer normalizes whitespace.

### Reference-style links for repeated URLs
```markdown
See the [spec][os] and the [issue tracker][os].

[os]: https://github.com/8007342/tillandsias
```
Keeps prose readable when the same URL appears many times. Reference labels are case-insensitive and live anywhere in the document.

### Task lists (GFM)
```markdown
- [x] write spec
- [ ] implement
- [ ] @trace annotations
```
Render as interactive checkboxes on GitHub. Used in OpenSpec `tasks.md` files.

### Footnotes (GFM)
```markdown
Tillandsias never blocks the tray[^1].

[^1]: See `tokio::select!` in `src-tauri/src/tray.rs`.
```
Footnote labels can be any string; renderer assigns numeric superscripts.

## Common pitfalls

- **Paragraph break needs a blank line** — single newlines collapse to a space. Two consecutive lines of text render as one paragraph. Insert a blank line to start a new paragraph.
- **Hard line break syntax** — to break a line inside a paragraph without a new paragraph, end the line with two trailing spaces or a backslash (`\`). Trailing spaces are invisible and easy to delete; prefer the backslash.
- **List indentation is finicky** — nested list items must indent by the width of the parent marker (2 spaces for `- `, 3 for `1. `). Mixing tabs and spaces, or under-indenting, breaks the nesting silently and the renderer flattens the list.
- **Pipes inside table cells** — a literal `|` inside a cell ends the cell. Escape as `\|`, or use HTML `&#124;`. Same trap with backticks containing pipes — wrap in HTML if needed.
- **Autolink eats `@mentions` and `#issues`** — on GitHub, `@user` and `#123` in raw text become links. Wrap in backticks (`` `@user` ``) or escape the leading char (`\@user`) when you mean the literal text.
- **Code fence language label is parser-dependent** — GitHub recognizes `rust`, `ts`, `sh`, `console`, `text`, etc., but obscure aliases (`rustlang`, `bash-session`) silently fall back to no highlighting. Stick to the common short names.
- **Heading needs space after `#`** — `#Heading` is not a heading; it's literal text. Always `# Heading` with a space.
- **Setext underline collides with horizontal rule** — `---` under a line of text becomes an `<h2>`, not a rule. Put a blank line between the paragraph and the `---` if you wanted a divider.
- **Indented code blocks vs lists** — 4-space indent is a code block at the top level, but inside a list it's a continuation of the list item. Mixing the two confuses the parser; prefer fenced code blocks everywhere.
- **HTML inside markdown disables markdown** — once you open a block-level HTML tag (`<div>`), markdown syntax inside it is ignored until the block closes. Inline HTML (`<span>`, `<br>`) is fine.

## See also

- `languages/html.md` — markdown compiles to HTML; understand the target
- `agents/openspec.md` — OpenSpec specs are markdown with strict scenario format
