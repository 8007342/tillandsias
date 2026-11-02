// @trace order:1864-ay3x
// The Puck editor page, bundled at image build time with React 19 (esbuild,
// build stage only). It loads the page data from the studio server and hands
// what onPublish gives it to the studio front's /__studio/save, which guards
// the path against the lane allowlist and commits it. PAGE comes from ?page=<name>.
import { createRoot } from "react-dom/client";
import { Puck } from "@measured/puck";

const page = (new URLSearchParams(location.search).get("page") || "home").replace(/[^a-z0-9_-]/gi, "-");
const path = `.tillandsias/studio/puck/pages/${page}.json`;

const config = {
  components: {
    Heading: {
      fields: { title: { type: "text" } },
      defaultProps: { title: "Heading" },
      render: ({ title }) => <h1>{title}</h1>,
    },
    Paragraph: {
      fields: { text: { type: "textarea" } },
      defaultProps: { text: "Text" },
      render: ({ text }) => <p>{text}</p>,
    },
  },
};

async function publish(data) {
  const r = await fetch("/__studio/save", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path, content: `${JSON.stringify(data, null, 2)}\n` }),
  });
  if (!r.ok) alert(`not saved: ${JSON.stringify(await r.json())}`);
}

fetch(`/__studio/load?path=${encodeURIComponent(path)}`)
  .then((r) => r.json())
  .catch(() => ({}))
  .then((stored) => {
    const data = stored && stored.content ? stored : { content: [], root: { props: {} } };
    createRoot(document.getElementById("puck")).render(
      <Puck config={config} data={data} onPublish={publish} />,
    );
  });
