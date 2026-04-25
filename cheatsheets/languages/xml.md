# XML

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: XML 1.0 (5th ed) — what virtually all tools target. XML 1.1 exists but is rarely used. Forge ships `xmllint` (libxml2) and `xmlstarlet`.
**Use when**: parsing or producing XML — `pom.xml`, SVG, RSS/Atom, Android manifests, legacy SOAP/SAML, anything in the Java enterprise stack.

## Quick reference

| Construct | Syntax |
|-----------|--------|
| Prolog | `<?xml version="1.0" encoding="UTF-8"?>` (optional but recommended) |
| Element | `<tag>text</tag>` or self-closing `<tag/>` |
| Attribute | `<tag key="value"/>` (always quoted, single or double) |
| Comment | `<!-- text -->` (no `--` inside, cannot nest) |
| CDATA | `<![CDATA[ raw <chars> & stuff ]]>` (no escaping inside, except `]]>`) |
| Namespace | `<x:foo xmlns:x="urn:ex"/>` or default `<foo xmlns="urn:ex"/>` |
| Entity refs | `&lt;` `&gt;` `&amp;` `&quot;` `&apos;` `&#65;` `&#x41;` |
| Processing instr. | `<?target data?>` (e.g. `<?xml-stylesheet ...?>`) |
| DOCTYPE | `<!DOCTYPE root SYSTEM "x.dtd">` (avoid — XXE risk) |

**XPath axes** (most-used): `/` root, `//` descendant, `.` self, `..` parent, `@attr` attribute, `[n]` 1-indexed predicate, `[@k='v']` attribute filter, `*` any element, `text()` text node.

**Well-formed** (parser accepts) ≠ **valid** (matches a DTD/XSD). All valid XML is well-formed; not vice versa.

## Common patterns

### Validate well-formedness, pretty-print
```bash
xmllint --noout file.xml                # well-formed check (silent on success)
xmllint --format file.xml               # pretty-print to stdout
xmllint --format --output out.xml in.xml
```

### XPath query
```bash
xmllint --xpath '//dependency/artifactId/text()' pom.xml
xmlstarlet sel -t -v '//book[@id="1"]/title' -n catalog.xml
```
With **default namespaces**, XPath needs an explicit prefix mapping:
```bash
xmllint --xpath '//*[local-name()="title"]' atom.xml         # quick & dirty
xmlstarlet sel -N a=http://www.w3.org/2005/Atom -t -v '//a:title' atom.xml
```

### Validate against XSD / DTD / RelaxNG
```bash
xmllint --schema schema.xsd --noout file.xml      # XSD
xmllint --dtdvalid grammar.dtd --noout file.xml   # DTD
xmllint --relaxng schema.rng --noout file.xml     # RelaxNG
```

### Escape special chars in text and attributes
Five mandatory escapes: `&` -> `&amp;`, `<` -> `&lt;`. In attributes also escape the quote you're using (`"` -> `&quot;` inside `"..."`). `>` and the other quote are optional but conventional. Or wrap raw text in `<![CDATA[ ... ]]>`.

### Edit in place with xmlstarlet
```bash
xmlstarlet ed -L -u '//version' -v '1.2.3' pom.xml
xmlstarlet ed -L -s '/project/dependencies' -t elem -n dependency \
  -s '$prev' -t elem -n groupId -v 'org.example' pom.xml
```

## Common pitfalls

- **Unescaped `&`** — a bare `&` in text or attribute value is a fatal parse error. Always `&amp;`. Same for `<` in text (`&lt;`).
- **Default namespace breaks XPath** — `<feed xmlns="http://www.w3.org/2005/Atom">` means `//title` matches **nothing**. You must bind a prefix and query `//atom:title`, or use `local-name()`.
- **Case sensitivity** — `<Foo>` and `<foo>` are different elements. HTML habits don't apply.
- **Well-formed ≠ valid** — `xmllint` without `--schema`/`--dtdvalid`/`--relaxng` only checks well-formedness. A `pom.xml` can parse fine and still be a broken Maven build.
- **Mixed content surprises** — `<p>hello <b>world</b>!</p>` has three children: text `"hello "`, element `<b>`, text `"!"`. XPath `text()` returns multiple nodes; serialisers may collapse whitespace.
- **CDATA is not encryption** — it skips entity processing but the content is still plain text in the document. Don't put `]]>` inside.
- **DTDs enable XXE** — external entity references in a DOCTYPE can read local files or trigger SSRF. Disable DTD loading in any parser handling untrusted input (`xmllint --nonet --noent` is **not** enough; prefer `--nonet --nodtd` or a parser with `disable_entity_loader`).
- **Encoding mismatch** — the prolog declares the encoding of the bytes. If the file is actually UTF-16 but says UTF-8, parsers fail or mojibake. Save as UTF-8 without BOM unless you have a reason.
- **Whitespace is significant in mixed content** — pretty-printing a document with mixed content can change its meaning. Only re-format pure element trees.
- **Attribute order is not preserved by spec** — round-tripping through a DOM may reorder attributes. Don't rely on order for diffs or signatures (use Canonical XML / c14n if you need a stable byte-form).

## When NOT to use XML

For new internal config or APIs, prefer JSON, YAML, or TOML — XML is verbose, namespace-heavy, and ecosystem-specific. Reach for XML only when something forces it: Maven `pom.xml`, SVG, Android resources, legacy SOAP/SAML, RSS/Atom feeds, or Java enterprise tooling. Inside Tillandsias, `postcard` is the IPC format and TOML is the user-config format — XML appears only when bridging external systems.

## See also

- `languages/json.md`, `languages/yaml.md`, `languages/toml.md` — modern alternatives for new work
- `utils/jq.md` — JSON sibling of `xmllint`/`xmlstarlet` for transforms
