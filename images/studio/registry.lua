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
      frameworks = { "plain-html" },
      entry = { "/usr/local/bin/studio-grapesjs" }, port = 4096,
      save_adapter = "endpoint",
      write_allowlist = { "*.html", "**/*.html", "*.css", "**/*.css", ".tillandsias/studio/grapesjs/**" },
      status = "planned", packet = "1861-nmpp",
    },
    {
      id = "decap", name = "Decap CMS", license = "MIT",
      brief = "Content editor for markdown sites (Hugo, Jekyll, Astro, 11ty).",
      frameworks = { "markdown-ssg" },
      entry = { "/usr/local/bin/studio-decap" }, port = 4096,
      save_adapter = "own-writer",
      write_allowlist = { "content/**", "_posts/**", "src/content/**", "static/**", "admin/config.yml", "admin/index.html" },
      status = "planned", packet = "1862-wrx5",
    },
    {
      id = "tina", name = "TinaCMS", license = "Apache-2.0",
      brief = "Visual content editing for Next.js, Astro and Hugo, in local mode.",
      frameworks = { "next-tailwind" },
      entry = { "/usr/local/bin/studio-tina" }, port = 4096,
      save_adapter = "own-writer",
      write_allowlist = { "content/**", "tina/config.ts", "tina/config.js", ".gitignore" },
      status = "planned", packet = "1863-dmke",
    },
    {
      id = "puck", name = "Puck", license = "MIT",
      brief = "Visual editor for React sites, built from the site's own components.",
      frameworks = { "react" },
      entry = { "/usr/local/bin/studio-puck" }, port = 4096,
      save_adapter = "endpoint",
      write_allowlist = { ".tillandsias/studio/puck/**" },
      status = "planned", packet = "1864-ay3x",
    },
    {
      id = "onlook", name = "Onlook", license = "Apache-2.0",
      brief = "Visual editor for Next.js and Tailwind that edits the code directly.",
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
      frameworks = {},
      kind = "sibling", image = "imagegen-studio",
      entry = {}, port = 8188,
      save_adapter = "own-writer",
      write_allowlist = {},
      status = "ready", packet = "1921-2krx",
    },
  },
}
