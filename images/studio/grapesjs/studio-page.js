// @trace order:2108-dptd
// The page a GrapesJS save writes: the ORIGINAL document with only what the
// editor changed inside <body> replaced. Everything outside <body> (doctype,
// <html lang>, <head> with its title, meta, OG tags, inline <style>/<script>,
// and the <body> open tag's attributes) is kept byte for byte. The one
// exception is a managed stylesheet link, added before </head> only when the
// editor's CSS changed and the head does not link it yet.
//
// v4 (operator test on tlatoani.net):
//  - <script>, <noscript> and <template> inside <body> never reach the editor
//    (GrapesJS drops scripts): protect() swaps each for a comment marker, and
//    rebuild() puts the original bytes back; a marker the editor lost is
//    re-added at the end of <body>, so a kept block is never dropped.
//  - only what changed is rewritten: the original body, the editor's view of it
//    at load (baseline) and its view now are walked together; any node whose
//    serialisation did not change since load keeps its ORIGINAL bytes, so a
//    one-word edit diffs one line, not the whole body.
//  - ids GrapesJS invented are dropped unless a rule in the editor's CSS uses
//    them.
// Loaded by editor.html (window.StudioPage) and required by the selftest.
(function (root) {
  "use strict";
  function split(doc) {
    const open = /<body\b[^>]*>/i.exec(doc);
    const closeRe = /<\/body\s*>/gi;
    let close = null;
    for (let m; (m = closeRe.exec(doc)); ) close = m;
    if (!open || !close || close.index < open.index + open[0].length) return null;
    const start = open.index + open[0].length;
    return { before: doc.slice(0, start), inner: doc.slice(start, close.index), after: doc.slice(close.index) };
  }
  // GrapesJS getHtml() wraps the content in its own <body ...>; the page's
  // own open tag is the one kept.
  function innerOf(editorHtml) {
    const s = String(editorHtml || "");
    const m = /^\s*<body\b[^>]*>([\s\S]*)<\/body>\s*$/i.exec(s);
    return m ? m[1] : s;
  }
  function withLink(before, href) {
    if (!href) return before;
    const esc = href.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    if (new RegExp(`<link\\b[^>]*href=["']?${esc}["'\\s>]`, "i").test(before)) return before;
    const head = /<\/head\s*>/i.exec(before);
    if (!head) return before;
    const tag = `<link rel="stylesheet" href="${href}">`;
    // Match the head's own layout: on a line of its own, indented like the
    // line above </head> (or </head>'s own indent plus nothing, if none).
    const lineStart = before.lastIndexOf("\n", head.index - 1) + 1;
    const lead = before.slice(lineStart, head.index);
    if (/^[ \t]*$/.test(lead)) {
      const prevEnd = lineStart > 0 ? lineStart - 1 : 0;
      const prevStart = before.lastIndexOf("\n", prevEnd - 1) + 1;
      const indent = (/^[ \t]*/.exec(before.slice(prevStart, prevEnd)) || [""])[0];
      return before.slice(0, lineStart) + indent + tag + "\n" + before.slice(lineStart);
    }
    return before.slice(0, head.index) + tag + before.slice(head.index);
  }

  // --- A small, lossless HTML fragment parser: every node keeps its raw text.
  const VOID = /^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/i;
  const RAW = /^(script|style|textarea|title)$/i;
  function parse(s) {
    const top = { children: [] };
    const stack = [top];
    let i = 0;
    const cur = () => stack[stack.length - 1];
    const text = (a, b) => { if (b > a) cur().children.push({ type: "text", raw: s.slice(a, b), start: a, end: b }); };
    while (i < s.length) {
      const lt = s.indexOf("<", i);
      if (lt < 0) { text(i, s.length); break; }
      text(i, lt);
      if (s.startsWith("<!--", lt)) {
        const e = s.indexOf("-->", lt + 4);
        const end = e < 0 ? s.length : e + 3;
        cur().children.push({ type: "comment", raw: s.slice(lt, end), start: lt, end });
        i = end;
        continue;
      }
      const close = /^<\/([A-Za-z][\w:-]*)\s*>/.exec(s.slice(lt, lt + 200));
      if (close) {
        const name = close[1].toLowerCase();
        let k = stack.length - 1;
        while (k > 0 && stack[k].tag !== name) k--;
        if (k > 0) {
          while (stack.length - 1 > k) finish(stack.pop(), lt, lt);
          finish(stack.pop(), lt, lt + close[0].length);
        }
        i = lt + close[0].length;
        continue;
      }
      const open = /^<([A-Za-z][\w:-]*)(?:\s+(?:[^>"']|"[^"]*"|'[^']*')*)?\s*(\/?)>/.exec(s.slice(lt));
      if (!open) { text(lt, lt + 1); i = lt + 1; continue; }
      const tag = open[1].toLowerCase();
      const node = { type: "el", tag, open: open[0], start: lt, children: [] };
      cur().children.push(node);
      i = lt + open[0].length;
      if (open[2] || VOID.test(tag)) { node.close = ""; node.end = i; node.raw = s.slice(lt, i); continue; }
      if (RAW.test(tag)) {
        const m = new RegExp(`</${tag}\\s*>`, "i").exec(s.slice(i));
        const ci = m ? i + m.index : s.length;
        if (ci > i) node.children.push({ type: "text", raw: s.slice(i, ci), start: i, end: ci });
        const ce = m ? ci + m[0].length : s.length;
        node.close = s.slice(ci, ce); node.end = ce; node.raw = s.slice(lt, ce);
        i = ce;
        continue;
      }
      stack.push(node);
    }
    while (stack.length > 1) finish(stack.pop(), s.length, s.length);
    return top.children;
    function finish(node, closeAt, end) {
      node.close = s.slice(closeAt, end); node.end = end; node.raw = s.slice(node.start, end);
    }
  }
  const blank = (n) => n.type === "text" && /^\s*$/.test(n.raw);
  const sig = (kids) => kids.filter((n) => !blank(n));
  // Attribute sets compared without order or quoting style.
  function attrKey(open) {
    const out = [];
    String(open).replace(/^<[\w:-]+/, "").replace(/\/?>$/, "")
      .replace(/([^\s=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g, (_, k, a, b, c) => { out.push(k.toLowerCase() + "=" + (a ?? b ?? c ?? "")); return ""; });
    return out.sort().join("\u0000");
  }
  const textKey = (raw) => raw.replace(/\s+/g, " ").trim();
  function same(b, n) {
    if (b.type !== n.type) return false;
    if (b.type === "text") return textKey(b.raw) === textKey(n.raw);
    if (b.type === "comment") return b.raw === n.raw;
    if (b.tag !== n.tag || attrKey(b.open) !== attrKey(n.open)) return false;
    const bk = sig(b.children), nk = sig(n.children);
    return bk.length === nk.length && bk.every((x, i) => same(x, nk[i]));
  }
  function mergeKids(o, b, n) {
    const os = sig(o), bs = sig(b), ns = sig(n);
    if (os.length !== bs.length || bs.length !== ns.length) return null;
    let out = "";
    let i = 0;
    for (const node of o) {
      if (blank(node)) { out += node.raw; continue; }
      const m = mergeNode(node, bs[i], ns[i]);
      if (m === null) return null;
      out += m;
      i++;
    }
    return out;
  }
  function mergeNode(o, b, n) {
    if (same(b, n)) return o.raw;
    if (o.type === "el" && b.type === "el" && n.type === "el" && o.tag === b.tag && b.tag === n.tag) {
      const sameOpen = attrKey(b.open) === attrKey(n.open);
      const inner = mergeKids(o.children, b.children, n.children);
      const kids = inner !== null ? inner : n.children.map((c) => c.raw).join("");
      return (sameOpen ? o.open : n.open) + kids + (n.close === "" && o.close === "" ? "" : o.close || n.close);
    }
    return n.raw;
  }
  // The body's inner HTML with what the editor changed, everything else as it was.
  function mergeInner(origInner, baseInner, newInner) {
    const m = mergeKids(parse(origInner), parse(baseInner), parse(newInner));
    return m === null ? newInner : m;
  }

  const KEEP = /<(script|noscript|template)\b[\s\S]*?<\/\1\s*>/gi;
  const marker = (i) => `<!--studio-keep:${i}-->`;
  // The body's inner HTML for the editor: kept blocks swapped for markers.
  function protect(inner) {
    const kept = [];
    const html = String(inner || "").replace(KEEP, (m) => { kept.push(m); return marker(kept.length - 1); });
    return { html, kept };
  }
  function restore(html, kept) {
    let out = html;
    const lost = [];
    kept.forEach((block, i) => {
      const at = out.indexOf(marker(i));
      if (at < 0) lost.push(block);
      else out = out.slice(0, at) + block + out.slice(at + marker(i).length);
    });
    if (lost.length) out = out.replace(/\s*$/, (ws) => "\n" + lost.join("\n") + (ws || "\n"));
    return out;
  }
  // Drop id="…" GrapesJS invented: not in the original page, not used by css.
  function dropUnusedIds(html, doc, css) {
    const known = new Set();
    String(doc || "").replace(/\bid\s*=\s*["']?([^"'\s>]+)/gi, (_, v) => { known.add(v); return ""; });
    return html.replace(/\s+id\s*=\s*"([^"]*)"/g, (m, v) => {
      if (known.has(v)) return m;
      const esc = v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      return new RegExp(`#${esc}(?![\\w-])`).test(String(css || "")) ? m : "";
    });
  }

  // opts: { baseline: the editor's getHtml() right after load, css: getCss() }.
  // Without a baseline (old callers), the editor's body replaces the inner.
  function rebuild(doc, editorHtml, cssHref, opts) {
    opts = opts || {};
    const parts = split(String(doc || ""));
    if (!parts) {
      const link = cssHref ? `<link rel="stylesheet" href="${cssHref}">\n` : "";
      return `<!doctype html>\n<html>\n<head>\n<meta charset="utf-8">\n${link}</head>\n<body>\n${innerOf(editorHtml)}\n</body>\n</html>\n`;
    }
    const { html: origProtected, kept } = protect(parts.inner);
    let inner = innerOf(editorHtml);
    if (opts.baseline != null) inner = mergeInner(origProtected, innerOf(opts.baseline), inner);
    inner = dropUnusedIds(inner, doc, opts.css);
    inner = restore(inner, kept);
    return withLink(parts.before, cssHref) + inner + parts.after;
  }
  // What the canvas needs to render the page as it looks, never saved: the
  // head's inline <style> text, its stylesheet links (relative ones resolved
  // under `siteBase`), and the <body> open tag's attributes.
  function canvasLook(doc, siteBase) {
    const parts = split(String(doc || ""));
    const head = parts ? parts.before : "";
    const styles = [];
    const links = [];
    head.replace(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi, (_, css) => { styles.push(css); return ""; });
    head.replace(/<link\b[^>]*>/gi, (tag) => {
      if (!/\brel\s*=\s*["']?stylesheet/i.test(tag)) return "";
      const m = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(tag);
      const href = m && (m[1] || m[2] || m[3]);
      if (!href || /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(href)) return ""; // no remote stylesheet: the enclave cannot fetch it
      links.push(siteBase + href.replace(/^\.?\//, ""));
      return "";
    });
    const attrs = {};
    const open = /<body\b([^>]*)>/i.exec(head);
    if (open) open[1].replace(/([^\s=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g, (_, k, a, b, c) => {
      attrs[k] = a ?? b ?? c ?? "";
      return "";
    });
    return { styles, links, attrs };
  }
  const api = { rebuild, innerOf, split, canvasLook, protect, restore, parse, mergeInner, dropUnusedIds };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StudioPage = api;
})(typeof window !== "undefined" ? window : globalThis);
