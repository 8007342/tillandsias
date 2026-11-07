-- @trace order:1958-yfib
--
-- check-own-licence-declarations.lua — Tillandsias is GPL-3.0-or-later
-- (LICENSE, Cargo.toml [workspace.package].license). Refuse any OTHER licence
-- declared on our own files, and refuse an image that declares none.
--
-- WHY THE IMAGE RULE. An OCI image inherits every LABEL of its base layer.
-- MEASURED 2026-11-01 on the operator's host: localhost/tillandsias-inference
-- carried org.opencontainers.image.licenses=MIT and vendor="Fedora Project"
-- (fedora-minimal's labels), tillandsias-router carried Apache-2.0 (caddy's).
-- Nothing in this tree said MIT; the base image did, and we shipped it as ours.
-- So every Containerfile that builds a Tillandsias image must set the label.
--
-- DECLARATION SITES CHECKED, over `git ls-files` (tracked files only):
--   Cargo.toml            `license = "<x>"`           x must be GPL-3.0-or-later (or .workspace)
--   package.json          `"license": "<x>"`          x must be GPL-3.0-or-later
--   any tracked text      an SPDX licence header   its identifier must start with GPL-3.0
--   Containerfile*        LABEL org.opencontainers.image.licenses  present AND starts with GPL-3.0-or-later,
--                         OR the final FROM is one of OUR OWN labelled images (localhost/tillandsias-<name>,
--                         named directly or through an ARG default): the label is inherited from a layer
--                         we label. The name resolves to its Containerfile through image_build_paths in
--                         crates/tillandsias-core/src/image_builder.rs, then images/<name>/Containerfile or
--                         images/<dir>/Containerfile.<suffix>. A third-party base still needs its own label.
--                         (an image that is mostly third-party software carries a COMPOUND label naming
--                         ours AND theirs, operator ruling 2026-11-01: vault "GPL-3.0-or-later AND BUSL-1.1",
--                         CUDA "… AND LicenseRef-NVIDIA-CUDA-EULA", ComfyUI "… AND GPL-3.0-only")
--   LICENSE*/COPYING*     outside the root: only under a VENDORED path
-- A VENDORED path keeps its upstream licence and is credited in
-- docs/credits/stack.v1.json instead; the list is below, each with its reason.
--
-- A ZERO COUNT IS A FAILURE, NOT A PASS: a tree with no Containerfile and no
-- Cargo.toml was not inspected.
--
-- Grammar (one line on stdout):
--   ok:own-licence-declarations:checked=<n>            exit 0
--   violation:own-licence-declarations:<k>             exit 1  (one `refused:<path>:<reason>` line per finding above it)
--   could-not-run:own-licence-declarations:<why>       exit 3

local OURS = "GPL-3.0-or-later"

-- path prefix -> why it may carry another licence
local VENDORED = {
    { "crates/tillandsias-core/data/devices/upstream/", "upstream device descriptors copied with their LICENSE (Chrome DevTools BSD-3-Clause, Playwright Apache-2.0); credited in the stack ledger" },
    { "openspec/litmus-tests/groundtruth/fixtures/", "fixture projects imitating third-party repositories; not shipped" },
    { "cheatsheets/", "third-party reference material; each sheet cites its own licence in Provenance, the allowlist classifies the publisher" },
    { "images/default/cheatsheets/", "the same allowlist, staged into the forge image" },
    { "crates/tillandsias-headless/data/studios.json", "the studio registry records each UPSTREAM studio's licence (GrapesJS, Decap, Tina, Puck, Onlook)" },
    { "images/studio/registry.lua", "source of the studio registry above" },
    { "images/imagegen-studio/custom-nodes.toml", "each ComfyUI custom node's upstream licence, pinned by commit" },
    { "images/models/licence-register.tsv", "the media model licence register: upstream model-card licences" },
    { "images/imagegen/models.tsv", "the imagegen download manifest, same licences" },
    { "images/imagegen/tiers.tsv", "the tier table, same licences" },
    { "cheatsheets/license-allowlist.toml", "publisher licence classification" },
    { "docs/credits/stack.v1.json", "the generated ledger of upstream licences" },
}
local function vendored(path)
    for _, v in ipairs(VENDORED) do
        if path:sub(1, #v[1]) == v[1] then return v[2] end
    end
    return nil
end

local function afford(why, remedy)
    io.stderr:write("  why: " .. why .. "\n  remedy: " .. remedy .. "\n")
end
local function read(path)
    local ok, body = pcall(fs.read, path)
    if ok and body then return body end
    return nil
end

-- Our image names -> Containerfiles, read from the Rust builder's own table.
local OWN = {}
do
    local rs = read("crates/tillandsias-core/src/image_builder.rs")
    if rs then
        for name, path in rs:gmatch('"([%w%-]+)"%s*=>%s*format!%("{root_dir}/([^"]+)"%)') do OWN[name] = path end
    end
end
local function own_containerfile(name)
    if OWN[name] then return OWN[name] end
    local direct = "images/" .. name .. "/Containerfile"
    if read(direct) then return direct end
    for i = 1, #name do
        if name:sub(i, i) == "-" then
            local q = "images/" .. name:sub(1, i - 1) .. "/Containerfile." .. name:sub(i + 1)
            if read(q) then return q end
        end
    end
    return nil
end
local function label_in(src)
    return src:match('org%.opencontainers%.image%.licenses%s*=%s*"([^"]*)"')
        or src:match("org%.opencontainers%.image%.licenses%s*=%s*([^%s\\]+)")
end
-- The label a Containerfile declares or inherits: (label, how) or (nil, reason).
local function effective_label(src, depth)
    local own = label_in(src)
    if own then return own, "declared" end
    if depth > 4 then return nil, "image-base-chain-too-deep" end
    local args, final = {}, nil
    for _, l in ipairs(text.lines(src:gsub("\\\r?\n", " "))) do
        local a, v = l:match("^%s*ARG%s+([%w_]+)=(.*)$")
        if a then args[a] = text.trim(v):gsub('^"(.*)"$', "%1") end
        local f = l:match("^%s*FROM%s+(%S+)")
        if f then final = f end
    end
    if not final then return nil, "image-has-no-from" end
    final = final:gsub("%${([%w_]+)}", function(k) return args[k] or ("${" .. k .. "}") end)
                 :gsub("%$([%w_]+)", function(k) return args[k] or ("$" .. k) end)
    if final:match("%$") then return nil, "image-base-unresolved:" .. final end
    local name = final:match("^localhost/tillandsias%-([%w%-]+)")
    if not name then return nil, "image-inherits-base-licence-label" end
    name = name:gsub("[:@].*$", "")
    local cf = own_containerfile(name)
    if not cf then return nil, "image-base-is-ours-but-unresolved:" .. name end
    local base_src = read(cf)
    if not base_src then return nil, "image-base-is-ours-but-unreadable:" .. cf end
    local lbl, how = effective_label(base_src, depth + 1)
    if lbl then return lbl, "inherited-from:" .. cf end
    return nil, how
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 10000 })
local root = text.trim(top and top.stdout or "")
if root == "" then
    verdict.emit("could-not-run:own-licence-declarations:not-a-git-checkout", 3)
end
local ls = proc.run({ argv = { "git", "ls-files" }, cwd = root, timeout_ms = 60000 })
local tracked = text.lines(ls and ls.stdout or "")
if #tracked == 0 or (#tracked == 1 and tracked[1] == "") then
    verdict.emit("could-not-run:own-licence-declarations:no-tracked-files", 3)
end

local findings, checked = {}, 0
local function refuse(path, reason)
    findings[#findings + 1] = "refused:" .. path .. ":" .. reason
end
local function is_text_candidate(p)
    return p:match("%.rs$") or p:match("%.sh$") or p:match("%.lua$") or p:match("%.py$") or p:match("%.js$") or p:match("%.mjs$")
        or p:match("%.ts$") or p:match("%.toml$") or p:match("%.yaml$") or p:match("%.yml$") or p:match("%.json$")
        or p:match("%.md$") or p:match("%.html$") or p:match("%.css$") or p:match("Containerfile") or p:match("%.ps1$") or p:match("%.swift$")
end

local containerfiles, manifests = 0, 0
for _, p in ipairs(tracked) do
    if p ~= "" and not p:match("^%.claude/worktrees/") and not p:match("^scratch/") then
        local why_vendored = vendored(p)
        local base = p:match("([^/]+)$") or p
        -- 1. Cargo.toml license field
        if base == "Cargo.toml" and not why_vendored then
            local src = read(p)
            if src then
                manifests = manifests + 1
                checked = checked + 1
                for _, l in ipairs(text.lines(src)) do
                    local v = l:match('^%s*license%s*=%s*"([^"]*)"')
                    if v and v ~= OURS then refuse(p, "cargo-license-not-gpl:" .. v) end
                    local lf = l:match('^%s*license%-file%s*=%s*"([^"]*)"')
                    if lf then refuse(p, "cargo-license-file-instead-of-spdx:" .. lf) end
                end
            end
        end
        -- 2. package.json license field (our own packages only)
        if base == "package.json" and not why_vendored and not p:match("node_modules/") then
            local src = read(p)
            if src then
                checked = checked + 1
                local v = src:match('"license"%s*:%s*"([^"]*)"')
                if v and v ~= OURS then refuse(p, "package-json-license-not-gpl:" .. v) end
            end
        end
        -- 3. SPDX headers anywhere in our own text files
        if is_text_candidate(p) and not why_vendored and not p:match("node_modules/") and not p:match("package%-lock%.json$") then
            local src = read(p)
            if src then
                checked = checked + 1
                local v = src:match("SPDX%-License%-Identifier:%s*([%w%.%-%+ ]+)")
                if v then
                    v = text.trim(v)
                    if v:sub(1, 7) ~= "GPL-3.0" then refuse(p, "spdx-header-not-gpl:" .. v) end
                end
                -- 4. an image must declare its own licence label, and it must be ours
                if base:match("^Containerfile") and (p:match("^images/[^/]+/Containerfile") or p == "observatorium/Containerfile") then
                    containerfiles = containerfiles + 1
                    local label, how = effective_label(src, 0)
                    if not label then
                        refuse(p, how)
                    elseif label:sub(1, #OURS) ~= OURS then
                        refuse(p, "image-licence-label-not-gpl:" .. label)
                    end
                end
            end
        end
        -- 5. a LICENSE/COPYING file outside the root must be vendored
        if p ~= "LICENSE" and (base:match("^LICEN[CS]E") or base:match("^COPYING")) and not why_vendored and not p:match("node_modules/") then
            refuse(p, "licence-file-outside-vendored-paths")
        end
    end
end

if containerfiles == 0 or manifests == 0 then
    afford(string.format("inspected %d Containerfiles and %d Cargo.toml manifests — an empty population says nothing", containerfiles, manifests),
        "run from the checkout root of the tillandsias repository")
    verdict.emit("could-not-run:own-licence-declarations:empty-population", 3)
end

if #findings > 0 then
    table.sort(findings)
    for _, f in ipairs(findings) do io.stdout:write(f .. "\n") end
    io.stdout:flush()
    afford("a file of ours declares a licence other than " .. OURS .. ", or an image leaves the label to its base image (which ships MIT/Apache-2.0 as if it were ours)",
        "set `license.workspace = true` / \"" .. OURS .. "\" / LABEL org.opencontainers.image.licenses=\"" .. OURS .. "\"; a third-party file keeps its licence and joins the VENDORED list in this guard with its reason")
    verdict.emit("violation:own-licence-declarations:" .. #findings, 1)
end
verdict.emit("ok:own-licence-declarations:checked=" .. checked, 0)
