-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_TEST_FORGE_IMAGE
-- @trace order:1863-dmke, order:1860-auhm, order:2347-dufz
--
-- test-studio-tina.lua — the TinaCMS studio LANE in LOCAL mode (no Tina Cloud, telemetry
-- off) on a Next.js markdown checkout, built and run as common.studio_lane says. A
-- document saved through Tina's local GraphQL, reached through the studio front, lands in
-- content/posts/hello.md as a `studio(tina): save` commit touching nothing else; the files
-- tinacms dev writes at startup are left alone (a write OUTSIDE the allowlist being put
-- back is front arm 5, test-studio-front.lua). Tina's servers listen on loopback only and
-- there is no egress. Ported from the .sh (2347-dufz).
--
-- Verdict: ok:studio-tina:<n> arms | violation:studio-tina:<why>
--        | could-not-run:studio-tina:<why> (exit 3)

local fixture = require "common.fixture"
local lane = require "common.studio_lane"
local T = fixture.new("studio-tina")
local CONFIG = [[
import { defineConfig } from "tinacms";
export default defineConfig({
  branch: "main",
  clientId: null,
  token: null,
  build: { outputFolder: "admin", publicFolder: "public" },
  media: { tina: { mediaRoot: "", publicFolder: "public" } },
  schema: {
    collections: [
      {
        name: "post",
        label: "Posts",
        path: "content/posts",
        format: "md",
        fields: [
          { type: "string", name: "title", label: "Title", isTitle: true, required: true },
          { type: "rich-text", name: "body", label: "Body", isBody: true },
        ],
      },
    ],
  },
});
]]
lane.run(T, "tina", { wait_s = 180, files = {
    ["package.json"] = '{ "name": "fixture", "private": true, "dependencies": { "next": "15.0.0", "react": "19.0.0", "tinacms": "3.15.1" } }\n',
    ["content/posts/hello.md"] = "---\ntitle: Before\n---\nThe old body.\n",
    ["tina/config.ts"] = CONFIG,
} }, function(L)
    local got = L:post("/graphql", '{query:"{ postConnection { edges { node { _sys { relativePath } title } } } }"}')
    T:arm("Tina lists the post", got:find("hello.md", 1, true), got)
    out.line("startup-changes=" .. L:git("status", "--porcelain"):gsub("\n", " "))
    got = L:post("/graphql", '{query:"mutation($r:String!,$p:DocumentUpdateMutation!){ updateDocument(collection:\\"post\\", relativePath:$r, params:$p){ __typename } }",'
        .. 'variables:{r:"hello.md",p:{post:{title:"After",body:{type:"root",children:[{type:"p",children:[{type:"text",text:"The new body, saved through Tina."}]}]}}}}}')
    local saved = L:git("rev-parse", "HEAD")
    T:arm("updateDocument is accepted", got:find('"updateDocument":{"__typename":"Post"}', 1, true), got)
    local post = fs.read(L.rel .. "/content/posts/hello.md")
    T:arm("the saved document reached content/posts/hello.md", post:find("title: After", 1, true) and post:find("saved through Tina", 1, true), post)
    got = L:git("log", "-1", "--format=%s", saved)
    T:arm("the front committed the document", got == "studio(tina): save content/posts/hello.md", got)
    got = L:git("diff", "--name-only", L.base, saved)
    T:arm("the save commit touches only the document", got == "content/posts/hello.md", got)

    local rows, leaks = L:listeners(function(port) return port ~= "1000" end)  -- 4096 is the front's own
    T:arm("tinacms dev listens", #rows > 0, "no listener")
    T:arm("Tina's servers listen on loopback only", #leaks == 0, table.concat(leaks, " "))
    got = L:egress("https://content.tinajs.io/")
    T:arm("the studio has no egress", got == "blocked", got)
end)
