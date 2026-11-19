// @trace order:2108-dptd
// The page a GrapesJS save writes: the ORIGINAL document with only what is
// inside <body> replaced. Everything outside <body> (doctype, <html lang>,
// <head> with its title, meta, OG tags, inline <style>/<script>, and the
// <body> open tag's attributes) is kept byte for byte. The one exception is a
// managed stylesheet link, added before </head> only when the editor's CSS
// changed and the head does not link it yet.
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
    return { before: doc.slice(0, start), after: doc.slice(close.index) };
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
    const tag = `<link rel="stylesheet" href="${href}">\n`;
    return head ? before.slice(0, head.index) + tag + before.slice(head.index) : before;
  }
  function rebuild(doc, editorHtml, cssHref) {
    const inner = innerOf(editorHtml);
    const parts = split(String(doc || ""));
    if (!parts) {
      const link = cssHref ? `<link rel="stylesheet" href="${cssHref}">\n` : "";
      return `<!doctype html>\n<html>\n<head>\n<meta charset="utf-8">\n${link}</head>\n<body>\n${inner}\n</body>\n</html>\n`;
    }
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
  const api = { rebuild, innerOf, split, canvasLook };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.StudioPage = api;
})(typeof window !== "undefined" ? window : globalThis);
