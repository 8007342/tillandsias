-- @trace order:2005-ccli
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_FORGE_IMAGE
--
-- test-tillandsias-impact-in-image.lua — 2005-ccli exit criterion for slice 2,
-- in a BUILT forge image with no host checkout and no network:
--   1 HELP   `tillandsias-impact --help` answers the usage
--   2 PLAN   one real plan for a docs site (not tillandsias) writes its report
--            and names a rerender of the edited page only
--   3 REFUSE a graph with no outputs refuses impact_graph_invalid, exit 2
-- The image is $TILLANDSIAS_FORGE_IMAGE, else the newest localhost/tillandsias-forge;
-- could-not-run when neither exists here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-impact-in-image.lua

local function base_env()
    return {
        PATH = env.get("PATH") or "/usr/bin:/bin",
        HOME = env.get("HOME") or "",
        XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") or "",
    }
end

local IMG = env.get("TILLANDSIAS_FORGE_IMAGE")
local imgs = IMG and { status = "exited", code = 0, stdout = IMG } or proc.run({
    argv = { "podman", "images", "--format", "{{.Repository}}:{{.Tag}}", "--filter", "reference=localhost/tillandsias-forge" },
    env = base_env(), timeout_ms = 60000,
})
if imgs.status ~= "exited" or imgs.code ~= 0 then
    verdict.could_not_run("tillandsias-impact-in-image", "podman images did not answer")
end
IMG = (imgs.stdout or ""):match("([^\n]+)")
if not IMG or IMG == "" then
    verdict.could_not_run("tillandsias-impact-in-image", "no localhost/tillandsias-forge image is built on this host")
end

local function in_image(script)
    local r = proc.run({
        argv = { "podman", "run", "--rm", "--network", "none", "--entrypoint", "/bin/sh", IMG, "-c", script },
        env = base_env(), timeout_ms = 120000,
    })
    return r.code, r.stdout or "", r.stderr or ""
end

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end

local c, o, e = in_image("tillandsias-impact --help")
arm("1 HELP answers the usage in " .. IMG, c == 0 and has(o, "Usage: tillandsias-impact plan"), c .. " " .. o .. e)

c, o, e = in_image([[
set -e
d="$(mktemp -d /tmp/ti.XXXXXX)"
printf '{"pages":{"intro":{"title":"Intro"},"faq":{"title":"FAQ"}}}' > "$d/old.json"
printf '{"pages":{"intro":{"title":"Welcome"},"faq":{"title":"FAQ"}}}' > "$d/new.json"
printf '{"outputs":[{"id":"intro.html","depends_on":["pages.intro.**"]},{"id":"faq.html","depends_on":["pages.faq.**"]}]}' > "$d/graph.json"
printf '{"modes":["none","rerender"],"default":"rerender"}' > "$d/rules.json"
tillandsias-impact plan --graph "$d/graph.json" --from "$d/old.json" --to "$d/new.json" --rules "$d/rules.json" --report "$d/report.json"
cat "$d/report.json"
]])
arm("2 PLAN writes a report naming only the edited page", c == 0 and has(o, '"report_path"')
    and has(o, '"none": 1') and has(o, '"rerender": 1'), c .. " " .. o .. e)

c, o, e = in_image([[
d="$(mktemp -d /tmp/ti.XXXXXX)"
printf '{}' > "$d/x.json"
printf '{"outputs":[]}' > "$d/g.json"
printf '{"modes":["none"]}' > "$d/r.json"
tillandsias-impact plan --graph "$d/g.json" --from "$d/x.json" --to "$d/x.json" --rules "$d/r.json" --report "$d/rep.json"
]])
arm("3 REFUSE an empty graph refuses impact_graph_invalid, exit 2",
    c == 2 and has(e, "refused:tillandsias-impact:impact_graph_invalid"), c .. " " .. o .. e)

if #failed > 0 then
    verdict.emit("violation:tillandsias-impact-in-image:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-impact-in-image", passed .. " arms in " .. IMG)
