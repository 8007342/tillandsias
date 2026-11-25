-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_TEST_FORGE_IMAGE
-- @trace order:1862-wrx5, order:1860-auhm, order:2347-dufz
--
-- test-studio-decap.lua — the Decap CMS studio LANE on a throwaway Hugo checkout, built
-- and run as common.studio_lane says. Through the studio front it must serve the vendored
-- admin UI (no CDN), point Decap's backend at the studio and list the Hugo posts; a
-- persistEntry lands in content/posts/hello.md as a `studio(decap): save` commit; one
-- writing outside the allowlist is put back and commits nothing. decap-server listens on
-- loopback only, and there is no egress. Ported from the .sh (2347-dufz).
--
-- Verdict: ok:studio-decap:<n> arms | violation:studio-decap:<why>
--        | could-not-run:studio-decap:<why> (exit 3: no podman, no local forge image,
--          the build cannot reach the npm registry)

local fixture = require "common.fixture"
local lane = require "common.studio_lane"
local T = fixture.new("studio-decap")
lane.run(T, "decap", { wait_s = 60, files = {
    ["hugo.toml"] = 'baseURL = "https://example.invalid/"\ntitle = "fixture"\n',
    ["content/posts/hello.md"] = "---\ntitle: Before\ndate: 2026-11-01T00:00:00Z\n---\nThe old body.\n",
} }, function(L)
    local function api(body) return L:post("/api/v1", body) end
    local function persist(path, slug, raw)
        return api('{action:"persistEntry",params:{branch:"main",dataFiles:[{slug:"' .. slug .. '",path:"' .. path .. '",raw:' .. json.encode(raw)
            .. '}],assets:[],options:{collectionName:"posts",commitMessage:"Update ' .. slug .. '",useWorkflow:false,status:"draft"}}}')
    end
    local got = L:fetch("/admin/decap-cms.js", nil, 'r.status,t.length>1000000?"big":"small"')
    T:arm("the vendored decap-cms.js is served through the front", got == "200 big", got)
    got = L:fetch("/admin/", nil, 'r.status,/https?:\\/\\//.test(t)?"external-url":"self-contained"')
    T:arm("the admin page references no external URL", got == "200 self-contained", got)
    got = L:fetch("/admin/config.yml")
    T:arm("config.yml points the backend at the studio", got:find("proxy_url: /api/v1", 1, true), got)
    got = api('{action:"entriesByFolder",params:{branch:"main",folder:"content/posts",extension:"md",depth:1}}')
    T:arm("entriesByFolder lists the Hugo post", got:find("content/posts/hello.md", 1, true), got)

    got = persist("content/posts/hello.md", "hello", "---\ntitle: After\ndate: 2026-11-02T00:00:00Z\n---\nThe new body, saved through Decap.\n")
    local saved = L:git("rev-parse", "HEAD")
    T:arm("persistEntry is accepted", got:find("^200 "), got)
    local post = fs.read(L.rel .. "/content/posts/hello.md")
    T:arm("the saved entry reached content/posts/hello.md", post:find("title: After", 1, true) and not post:find("Before", 1, true), post)
    got = L:git("log", "-1", "--format=%s", saved)
    T:arm("the front committed the entry", got == "studio(decap): save content/posts/hello.md", got)
    got = L:git("diff", "--name-only", L.base, saved)
    T:arm("the save commit touches only the entry", got == "content/posts/hello.md", got)

    got = persist("notes.md", "notes", "---\ntitle: Off the allowlist\n---\n")
    T:arm("a write outside the allowlist is refused", got:find("^403 "), got)
    T:arm("a write outside the allowlist is put back", not fs.exists(L.rel .. "/notes.md"), "notes.md exists")
    got = L:git("rev-parse", "HEAD")
    T:arm("the off-allowlist write is not committed", got == saved, got)
    got = L:logs()
    T:arm("the refused write is evented", got:find("event:studio%.save_refused [^\n]*path=notes%.md"), got:sub(-400))

    local rows, leaks = L:listeners(function(port) return port == "1F91" end)  -- 8081
    T:arm("decap-server listens", #rows > 0, "no listener on 8081")
    T:arm("decap-server listens on loopback only", #leaks == 0, table.concat(leaks, " "))
    got = L:egress("https://registry.npmjs.org/")
    T:arm("the studio has no egress", got == "blocked", got)
    -- .cache/ is the command-policy audit log of a forge image older than 1788-qlwq slice 7.
    local left = {}
    for l in L:git("status", "--porcelain"):gmatch("[^\n]+") do if l ~= "?? .cache/" then left[#left + 1] = l end end
    T:arm("the lane left no files in the checkout", #left == 0, table.concat(left, " "))
end)
