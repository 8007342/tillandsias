-- @trace order:1860-auhm, spec:web-studio-lane
--
-- The studio registry: every visual web studio a project can be opened in,
-- declared once. Pure data — evaluated with an empty environment, so it can
-- call nothing. scripts/lua/build-studio-registry.lua turns it into
-- crates/tillandsias-headless/data/studios.json, which the launcher embeds;
-- the Rust side only consumes it (design.md, "The Lua side owns the registry").
--
-- Fields:
--   id              stable id; the image is studio-<id>, the route studio.<label>
--   name, brief     what the choice list shows
--   good_for, not_for  2026-ggu8: the kinds of content and work this studio is
--                   better and worse at, in the user's terms, so an agent can
--                   pick or recommend one when detection names no framework or
--                   the request is about content rather than a framework.
--                   Required, non-empty lists of short phrases.
--   edits           2026-ggu8: what a save changes in the project, one sentence.
--   license         SPDX id of the studio itself
--   frameworks      the detected frameworks this studio is RECOMMENDED for, in
--                   order; the first studio listing a detected framework wins
--   detector        which project files mean which framework (see FRAMEWORKS)
--   entry           command the studio image runs behind the front, as argv
--   port            the port the front listens on inside the forge
--   save_adapter    "endpoint" (saves POST to the front's /__studio/save) or
--                   "own-writer" (the studio writes files itself; the front's
--                   watcher still passes every changed path through the guard)
--   write_allowlist globs, relative to the checkout, a save may touch
--   status          "planned" until its lane packet lands the image; a planned
--                   studio is listed but refused at launch, naming the packet
--   packet          the lane's order
--   needs_cloud_account  true: listed, never recommended (Onlook until 1865)
--   kind            "forge" (default): the studio runs IN the forge, from its own
--                   image stacked on the forge base, behind the studio front, and
--                   edits the checkout. "sibling" (1921-2krx): the studio runs in
--                   its OWN container next to the forge, from `image`, never sees
--                   the checkout (entry is the image's own; write_allowlist must
--                   be empty), and is reached only through the router's OTP
--                   route studio.<label> -> tillandsias-<project>-studio:<port>.
--   image           sibling only: the image the sibling runs (built on first use)
--
-- Silex is deliberately absent (operator ruling 2026-10-25).

return {
  frameworks = {
    -- Detection signals, checked in this order; the first that matches names
    -- the project's framework.
    { id = "next-tailwind", package_deps_all = { "next", "tailwindcss" } },
    { id = "react",         package_deps_any = { "react" } },
    { id = "markdown-ssg",  files_any = { "hugo.toml", "hugo.yaml", "config.toml", "_config.yml",
                                          "astro.config.mjs", ".eleventy.js", "eleventy.config.js" } },
    { id = "plain-html",    files_any = { "index.html" } },
  },
  studios = {
    {
      id = "grapesjs", name = "GrapesJS", license = "BSD-3-Clause",
      brief = "Drag-and-drop page builder for plain HTML and CSS sites.",
      good_for = { "landing pages and one-page marketing sites",
                   "laying out sections, columns and blocks by drag and drop",
                   "restyling an existing static page (colours, spacing, fonts) without touching code" },
      not_for = { "blog posts or other long-form markdown content",
                  "React, Vue or other component-based apps",
                  "pages produced by a build step (it edits the HTML it is given, not a template)" },
      edits = "The page's .html and .css files directly; every save is a commit.",
      -- 2041-jb57: egress tiers (curated-egress-tiers); runs in the forge, so it has the forge's tiers.
      egress = { "siblings", "registries", "assets", "providers", "research" },
      frameworks = { "plain-html" },
      entry = { "/usr/local/bin/studio-grapesjs" }, port = 4096,
      save_adapter = "endpoint",
      write_allowlist = { "*.html", "**/*.html", "*.css", "**/*.css", ".tillandsias/studio/grapesjs/**" },
      status = "ready", packet = "1861-nmpp",
    },
    {
      id = "decap", name = "Decap CMS", license = "MIT",
      brief = "Content editor for markdown sites (Hugo, Jekyll, Astro, 11ty).",
      good_for = { "writing and editing blog posts, docs pages and other markdown entries",
                   "frontmatter fields (title, date, tags, images) through forms",
                   "collections of similar entries, and uploading images to the site's media folder" },
      not_for = { "page layout or visual design",
                  "composing pages from components",
                  "plain HTML sites with no static site generator" },
      edits = "Markdown files and their frontmatter under the content folders, plus uploads under static/; scaffolds admin/config.yml when it is missing.",
      -- 2041-jb57: egress tiers (curated-egress-tiers); runs in the forge, so it has the forge's tiers.
      egress = { "siblings", "registries", "assets", "providers", "research" },
      frameworks = { "markdown-ssg" },
      entry = { "/usr/local/bin/studio-decap" }, port = 4096,
      save_adapter = "own-writer",
      write_allowlist = { "content/**", "_posts/**", "src/content/**", "static/**", "admin/config.yml", "admin/index.html" },
      status = "ready", packet = "1862-wrx5",
    },
    {
      id = "tina", name = "TinaCMS", license = "Apache-2.0",
      brief = "Visual content editing for Next.js, Astro and Hugo, in local mode.",
      good_for = { "editing page text and structured content inline, on a live preview of the running site",
                   "Next.js, Astro or Hugo sites whose content lives in markdown, MDX or JSON",
                   "people who would rather click on the page than fill in a form" },
      not_for = { "building a layout from scratch",
                  "plain HTML sites with no build",
                  "changing component code or styles" },
      edits = "Content files under content/ (markdown, MDX or JSON) and the tina/config schema.",
      -- 2041-jb57: egress tiers (curated-egress-tiers); runs in the forge, so it has the forge's tiers.
      egress = { "siblings", "registries", "assets", "providers", "research" },
      frameworks = { "next-tailwind" },
      entry = { "/usr/local/bin/studio-tina" }, port = 4096,
      save_adapter = "own-writer",
      write_allowlist = { "content/**", "tina/config.ts", "tina/config.js", ".gitignore" },
      status = "ready", packet = "1863-dmke",
    },
    {
      id = "puck", name = "Puck", license = "MIT",
      brief = "Visual editor for React sites, built from the site's own components.",
      good_for = { "composing pages from the React components the site already has, by drag and drop",
                   "landing and marketing pages inside a React app",
                   "letting non-developers rearrange sections without writing JSX" },
      not_for = { "markdown or blog content",
                  "creating or changing the components themselves",
                  "sites that are not React" },
      edits = "Only the page layout data (which components, in what order, with what props) under .tillandsias/studio/puck/; never component source.",
      -- 2041-jb57: egress tiers (curated-egress-tiers); runs in the forge, so it has the forge's tiers.
      egress = { "siblings", "registries", "assets", "providers", "research" },
      frameworks = { "react" },
      entry = { "/usr/local/bin/studio-puck" }, port = 4096,
      save_adapter = "endpoint",
      write_allowlist = { ".tillandsias/studio/puck/**" },
      status = "ready", packet = "1864-ay3x",
    },
    {
      -- 1865-dn5h DEGRADED (measured 2026-11-02, plan/issues/onlook-offline-viability-2026-11-02-yoga.md):
      -- needs a CodeSandbox account, so listed with its reason and never recommended.
      -- RECHECK: revisit when Onlook ships a local runner or an open desktop app.
      id = "onlook", name = "Onlook", license = "Apache-2.0",
      brief = "Visual editor for Next.js and Tailwind. Needs a CodeSandbox account: its projects run in a cloud sandbox, not offline in the forge (measured, 1865-dn5h).",
      good_for = { "visually editing the layout and Tailwind styles of a Next.js app, written back to code" },
      not_for = { "offline use: it needs a CodeSandbox account and runs projects in a cloud sandbox",
                  "markdown content",
                  "sites that are not Next.js" },
      edits = "The app's own source under app/, src/ and components/ (not available offline in the forge).",
      -- 2041-jb57: egress tiers (curated-egress-tiers); runs in the forge, so it has the forge's tiers.
      egress = { "siblings", "registries", "assets", "providers", "research" },
      frameworks = {},
      entry = { "/usr/local/bin/studio-onlook" }, port = 4096,
      save_adapter = "own-writer",
      write_allowlist = { "app/**", "src/**", "components/**", "public/**" },
      status = "planned", packet = "1865-dn5h", needs_cloud_account = true,
    },
    {
      -- 1874-zry8 builds the image; 1921-2krx opens it as a studio. Not
      -- recommended for any site framework: it makes images, not pages.
      id = "comfyui", name = "ComfyUI", license = "GPL-3.0-only",
      brief = "Node-based image generation on the local models, outputs to the lane's scratch volume.",
      good_for = { "generating or editing images: hero art, illustrations, icons, sprites, textures",
                   "image-to-image and inpainting with the local models",
                   "building a repeatable image workflow the agent can rerun with studio.run_workflow" },
      not_for = { "editing site pages, text or code",
                  "anything that must change files in the checkout directly" },
      edits = "Nothing in the checkout: outputs land in the lane's scratch volume (/work/tmp/imagegen), and the agent commits the ones the user keeps.",
      -- 2041-jb57: egress tiers (curated-egress-tiers); sibling container: model weights plus the front's assets.
      egress = { "siblings", "model-hubs", "assets" },
      frameworks = {},
      kind = "sibling", image = "imagegen-studio",
      entry = {}, port = 8188,
      save_adapter = "own-writer",
      write_allowlist = {},
      status = "ready", packet = "1921-2krx",
    },
  },
}
