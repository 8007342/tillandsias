-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_TEST_FORGE_IMAGE
-- @trace order:1864-ay3x, order:1860-auhm, order:2347-dufz
--
-- test-studio-puck.lua — the Puck studio LANE on a throwaway React checkout, built (esbuild
-- bundles Puck + React 19 in a DISCARDED builder stage) and run as common.studio_lane says.
-- The page data onPublish hands over, posted to /__studio/save through the studio front,
-- lands under .tillandsias/studio/puck/ as a `studio(puck): save` commit; a write anywhere
-- else (source files, a path escaping the checkout, an absolute path) is refused and changes
-- nothing. Build-time-only rule: the final image has no esbuild and no node_modules under
-- /opt, and React exists only inside the bundle. Ported from the .sh (2347-dufz).
--
-- Verdict: ok:studio-puck:<n> arms | violation:studio-puck:<why>
--        | could-not-run:studio-puck:<why> (exit 3)

local fixture = require "common.fixture"
local lane = require "common.studio_lane"
local T = fixture.new("studio-puck")
local PAGE = ".tillandsias/studio/puck/pages/home.json"
lane.run(T, "puck", { wait_s = 60, files = {
    ["package.json"] = '{ "name": "fixture", "private": true, "dependencies": { "react": "19.0.0", "react-dom": "19.0.0" } }\n',
    ["src/App.jsx"] = "export default function App() { return <h1>Before</h1>; }\n",
} }, function(L)
    -- What the editor's publish() posts: the onPublish data, as JSON text.
    local function save(path)
        return L:post("/__studio/save", '{path:"' .. path .. '",content:JSON.stringify({content:[{type:"Heading",props:{id:"Heading-1",title:"After"}}],root:{props:{title:"Home"}}},null,2)+"\\n"}')
    end
    local got = save(PAGE)
    local saved = L:git("rev-parse", "HEAD")
    T:arm("the onPublish save under the allowlist is accepted", got:find("^200 "), got)
    local stored = fs.exists(L.rel .. "/" .. PAGE) and fs.read(L.rel .. "/" .. PAGE) or ""
    T:arm("the page data JSON is in the checkout", stored:find('"title": "After"', 1, true), stored)
    got = L:git("log", "-1", "--format=%s", saved)
    T:arm("the front committed the page data", got == "studio(puck): save " .. PAGE, got)

    for _, p in ipairs{ "src/App.jsx", "src/page.json", ".tillandsias/studio/puck/../../src/App.json", "/etc/passwd.json" } do
        got = save(p)
        T:arm("a write to " .. p .. " is refused", got:find('^403 {"refused":"'), got)
        if p == "src/page.json" then T:arm("the refusal names the allowlist", got:find('"refused":"not-allowlisted"', 1, true), got) end
    end
    got = L:git("diff", "--name-only", L.base, "HEAD")
    T:arm("the history changed only by the one allowed file", got == PAGE, got)
    got = L:git("rev-parse", "HEAD")
    T:arm("a refused write is not committed", got == saved, got)
    got = L:git("diff", "--name-only", "--", "src")
    T:arm("a refused write leaves src/ unchanged", got == "", got)
    T:arm("a refused write creates no file", not fs.exists(L.rel .. "/src/page.json") and not fs.exists(L.rel .. "/src/App.json"), "src/page.json or src/App.json exists")

    got = L:fetch("/__studio/load?path=" .. PAGE)
    T:arm("/__studio/load returns the stored page", got:find('"After"', 1, true), got)
    got = L:egress("https://registry.npmjs.org/")
    T:arm("the studio has no egress", got == "blocked", got)
    got = L:fetch("/", nil, 'r.status,/https?:\\/\\//.test(t)?"external-url":"self-contained"')
    T:arm("the editor page references no external URL", got == "200 self-contained", got)
    got = L:fetch("/editor.js", nil, 'r.status,t.length>100000?"big":"small",/react\\.dev\\/errors|Minified React error/.test(t)?"react-inside":"no-react",/onPublish/.test(t)?"puck-inside":"no-puck"')
    T:arm("the bundle carries Puck and React", got == "200 big react-inside puck-inside", got)
    -- find walks the FINAL image's filesystem; a container that cannot run it is not clean.
    local r = T:run{ "podman", "run", "--rm", "--network", "none", "--entrypoint", "find", L.tag, "/", "-xdev",
        "(", "-path", "/proc", "-o", "-path", "/sys", ")", "-prune", "-o", "(", "-iname", "*esbuild*",
        "-o", "(", "-name", "node_modules", "-path", "/opt/*", ")", "-o", "(", "-name", "react-dom", "-type", "d", ")", ")", "-print" }
    T:arm("the final image carries no build-time-only file", (r.code == 0 or r.code == 1) and text.trim(r.stdout or "") == "", "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or ""):sub(1, 300))
end)
