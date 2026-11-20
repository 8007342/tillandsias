// @trace order:1864-ay3x, order:2110-pk4s
// The Puck editor page. Bundled either at image build time against the demo
// config (demo-config.jsx, @measured/puck) or, when the site has its own
// puck.config, at studio start against THAT config and the site's own deps
// (build-site.mjs), so the editor shows the site's own components. The two
// names below are esbuild aliases: "studio-config" is the config module and
// "studio-puck" is the site's Puck package (@puckeditor/core or @measured/puck).
//
// Saving (operator ruling, 2108-dptd and 2110-pk4s): an explicit Save, one
// commit per click through the studio front's /__studio/save; a change only
// marks the page dirty; a Save with no change posts nothing; leaving with
// unsaved changes warns; the only automatic write is a crash-recovery draft in
// this browser's storage, never a commit. PAGE comes from ?page=<name>.
import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Puck } from "studio-puck";
import config from "studio-config";

const page = (new URLSearchParams(location.search).get("page") || "home").replace(/[^a-z0-9_-]/gi, "-");
const path = `.tillandsias/studio/puck/pages/${page}.json`;
const draftKey = `studio-draft:${path}`;
const siteCss = [].concat(window.__STUDIO_SITE_CSS || []);
const empty = { content: [], root: { props: {} } };
const text = (data) => `${JSON.stringify(data, null, 2)}\n`;
const draftStore = {
  get() { try { return JSON.parse(localStorage.getItem(draftKey) || "null"); } catch { return null; } },
  set(v) { try { localStorage.setItem(draftKey, JSON.stringify(v)); } catch {} },
  clear() { try { localStorage.removeItem(draftKey); } catch {} },
};

function Studio({ initial, stored }) {
  const latest = useRef(initial);
  const saved = useRef(text(stored));
  const [dirty, setDirty] = useState(text(initial) !== saved.current);
  const [state, setState] = useState("");
  const draftTimer = useRef(0);

  useEffect(() => {
    document.documentElement.setAttribute("data-studio-dirty", String(dirty));
    if (!dirty) return undefined;
    const warn = (e) => { e.preventDefault(); e.returnValue = ""; };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);

  const onChange = (data) => {
    latest.current = data;
    const d = text(data) !== saved.current;
    setDirty(d);
    clearTimeout(draftTimer.current);
    draftTimer.current = setTimeout(() => {
      if (d) draftStore.set({ base: saved.current, data, at: Date.now() });
      else draftStore.clear();
    }, 1000);
  };

  const save = async () => {
    const content = text(latest.current);
    if (content === saved.current) { setDirty(false); return; } // a no-op Save posts nothing
    setState("saving");
    try {
      const r = await fetch("/__studio/save", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ path, content }),
      });
      if (!r.ok) throw new Error(JSON.stringify(await r.json().catch(() => ({ status: r.status }))));
      saved.current = content;
      setDirty(false);
      draftStore.clear();
      setState("saved");
      document.documentElement.setAttribute("data-studio-save", "saved");
    } catch (e) {
      setState("error");
      document.documentElement.setAttribute("data-studio-save", "error");
      alert(`Not saved: ${e.message || e}`);
    }
  };

  return (
    <Puck
      config={config}
      data={initial}
      onChange={onChange}
      overrides={{
        // Save replaces Publish: Publish committed on every click with no
        // dirty state. Only this click writes.
        headerActions: () => (
          <button
            type="button"
            data-studio-save-button=""
            onClick={save}
            disabled={state === "saving"}
            title="Save (one commit)"
            style={{
              padding: "6px 14px", borderRadius: 6, border: "1px solid #888", cursor: "pointer",
              background: dirty ? "#ffca6f" : "transparent", fontWeight: dirty ? 600 : 400,
            }}
          >
            {state === "saving" ? "Saving…" : dirty ? "Save" : "Saved"}
          </button>
        ),
        // The site's own CSS reaches the canvas only, never the editor chrome.
        iframe: ({ children, document: doc }) => {
          useEffect(() => {
            if (!doc || doc.querySelector("link[data-studio-site-css]")) return;
            for (const href of siteCss) {
              const link = doc.createElement("link");
              link.rel = "stylesheet";
              link.href = href;
              link.setAttribute("data-studio-site-css", "");
              doc.head.appendChild(link);
            }
          }, [doc]);
          return children;
        },
      }}
    />
  );
}

fetch(`/__studio/load?path=${encodeURIComponent(path)}`)
  .then((r) => r.json())
  .catch(() => ({}))
  .then((loaded) => {
    const stored = loaded && loaded.content ? loaded : empty;
    let initial = stored;
    const d = draftStore.get();
    if (d && d.base === text(stored) && text(d.data) !== text(stored)
        && confirm(`Restore your unsaved studio changes from ${new Date(d.at).toLocaleString()}?`)) {
      initial = d.data;
    } else if (d) {
      draftStore.clear();
    }
    createRoot(document.getElementById("puck")).render(<Studio initial={initial} stored={stored} />);
  });
