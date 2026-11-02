-- @trace order:1958-yfib, order:1958-jyfk
-- @env TILLANDSIAS_CARGO_METADATA
--
-- build-stack-ledger.lua — THE STACK LEDGER. Generate docs/credits/stack.v1.json,
-- the machine-readable graph of every third-party thing Tillandsias wires in,
-- FROM the sources of truth and never from a hand-typed licence:
--
--   Rust crates ........ `cargo metadata` (direct, transitive, optional, dev/build)
--   container images ... images/*/Containerfile*, observatorium/Containerfile
--                        (FROM base images, distro packages, pip/npm installs,
--                        git clones; ARG pins carried as the version)
--   npm bundles ........ package-lock.json next to each Containerfile that npm-installs
--   media models ....... images/models/licence-register.tsv (+ models.tsv tiers)
--   web studios ........ crates/tillandsias-headless/data/studios.json
--   studio plugins ..... images/imagegen-studio/custom-nodes.toml
--   vendored files ..... crates/tillandsias-core/data/devices/upstream/*-LICENSE
--                        (licence read from the licence TEXT, by signature)
--   bundled docs ....... cheatsheets/license-allowlist.toml
--   external services .. hosts that appear in crates/, scripts/ or images/
--
-- A licence is what the upstream declares in that source; when no source
-- declares one the node says "unknown". NEVER a guess. Distro packages are
-- "unknown" because no file in this tree declares them (the rpm/apk/deb inside
-- the image does, and that is not read here).
--
-- Output is canonical (sorted keys, two-space indent, this file's own encoder,
-- no timestamps), so a re-run on the same inputs is byte-identical:
--   tillandsias-plan script run scripts/lua/build-stack-ledger.lua                 (write)
--   tillandsias-plan script run scripts/lua/build-stack-ledger.lua -- --check      (verify)
--   ... -- --metadata <cargo-metadata.json> --out <path>                          (fixtures)
-- Verdicts (one line on stdout):
--   ok:stack-ledger:written:nodes=<n>:edges=<m>        exit 0
--   ok:stack-ledger:fresh:nodes=<n>:edges=<m>          exit 0
--   violation:stack-ledger:stale                       exit 1   (--check; regenerate)
--   could-not-run:stack-ledger:<why>                   exit 3

local OUT = "docs/credits/stack.v1.json"
local META_FILE = env.get("TILLANDSIAS_CARGO_METADATA") or ""
local check = false
do
    local i = 1
    while i <= #(arg or {}) do
        local a = arg[i]
        if a == "--check" then check = true
        elseif a == "--metadata" then META_FILE = arg[i + 1] or ""; i = i + 1
        elseif a == "--out" then OUT = arg[i + 1] or OUT; i = i + 1
        end
        i = i + 1
    end
end

local function afford(why, remedy)
    io.stderr:write("  why: " .. why .. "\n  remedy: " .. remedy .. "\n")
end
local function read(path)
    local ok, body = pcall(fs.read, path)
    if ok and body then return body end
    return nil
end
local function lines(s) return text.lines(s or "") end
-- json.parse hands a JSON null back as userdata; read every optional field through this.
local function nn(v) if type(v) == "userdata" then return nil end return v end
local function str(v) v = nn(v); if v == nil then return nil end return tostring(v) end
local function trim(s) return text.trim(s or "") end

-- ---------------------------------------------------------------------------
-- Licence families. A family is a reading of an SPDX expression for the page's
-- rings; the raw expression is kept beside it, untouched.
--   permissive | weak-copyleft | strong-copyleft | model | restricted | unknown
-- An OR expression offers a choice, so it takes the most permissive branch; an
-- AND expression binds every term, so it takes the most restrictive.
local RANK = { permissive = 1, ["weak-copyleft"] = 2, ["strong-copyleft"] = 3, model = 4, restricted = 5, unknown = 6 }
local function family_of_id(id)
    local l = id:lower():gsub("%s+", "")
    if l == "" then return "unknown" end
    if l:match("^gpl") or l:match("^agpl") then return "strong-copyleft" end
    if l:match("^lgpl") or l:match("^mpl") or l:match("^epl") or l:match("^cddl") then return "weak-copyleft" end
    if l:match("openrail") or l:match("^creativeml") then return "model" end
    if l == "busl-1.1" or l:match("non%-commercial") or l:match("^cc%-by%-nc") or l:match("research")
        or l:match("^licenseref") or l:match("eula") or l:match("community") or l:match("^qwen") or l:match("^gemma") then
        return "restricted"
    end
    if l:match("^mit") or l:match("^apache") or l:match("^bsd") or l == "isc" or l:match("^zlib") or l:match("^unicode")
        or l == "unlicense" or l:match("^cc0") or l == "0bsd" or l:match("^bsl%-1%.0$") or l:match("^openssl")
        or l == "ietf-trust-legal-provisions" or l:match("^cc%-by%-4") or l:match("^cc%-by%-sa") or l:match("^w3c")
        or l:match("^python") or l:match("^psf") or l:match("^artistic") or l:match("^ofl") or l:match("^wtfpl") then
        return "permissive"
    end
    return "unknown"
end
local function family(expr)
    if not expr or expr == "" or expr == "unknown" then return "unknown" end
    local e = expr:gsub("[()]", " "):gsub("/", " OR ")
    local best
    for alt in (e .. " OR "):gmatch("(.-)%s+OR%s+") do
        alt = trim(alt)
        if alt ~= "" then
            local worst
            for term in (alt .. " AND "):gmatch("(.-)%s+AND%s+") do
                term = trim(term):gsub("%s+WITH%s+.*$", "")
                if term ~= "" then
                    local f = family_of_id(term)
                    if not worst or RANK[f] > RANK[worst] then worst = f end
                end
            end
            worst = worst or "unknown"
            if not best or RANK[worst] < RANK[best] then best = worst end
        end
    end
    return best or "unknown"
end

-- ---------------------------------------------------------------------------
-- Canonical JSON: sorted keys, two-space indent, lists kept in order.
local function is_list(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end
local function jstr(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\t" then return "\\t" elseif c == "\r" then return "\\r"
        else return string.format("\\u%04x", c:byte()) end
    end)
    return '"' .. s .. '"'
end
local function not_empty(t) for _ in pairs(t) do return true end return false end
local LIST = {} -- tables registered as lists even when empty
local function L(t) LIST[t] = true; return t end
local function enc(v, ind, out)
    local t = type(v)
    if v == nil then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "number" then out[#out + 1] = string.format("%d", v)
    elseif t == "string" then out[#out + 1] = jstr(v)
    elseif t == "table" then
        local pad, pad2 = string.rep("  ", ind), string.rep("  ", ind + 1)
        if LIST[v] or (not_empty(v) and is_list(v)) then
            if #v == 0 then out[#out + 1] = "[]"; return end
            out[#out + 1] = "[\n"
            for i, x in ipairs(v) do
                out[#out + 1] = pad2; enc(x, ind + 1, out)
                out[#out + 1] = (i < #v) and ",\n" or "\n"
            end
            out[#out + 1] = pad .. "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            if #keys == 0 then out[#out + 1] = "{}"; return end
            table.sort(keys)
            out[#out + 1] = "{\n"
            for i, k in ipairs(keys) do
                out[#out + 1] = pad2 .. jstr(k) .. ": "; enc(v[k], ind + 1, out)
                out[#out + 1] = (i < #keys) and ",\n" or "\n"
            end
            out[#out + 1] = pad .. "}"
        end
    end
end
local function encode(v) local out = {}; enc(v, 0, out); return table.concat(out) .. "\n" end

-- ---------------------------------------------------------------------------
-- The graph.
local components, nodes, edges = {}, {}, {}
local function component(id, title, kind, description)
    if not components[id] then components[id] = { id = id, title = title, kind = kind, description = description } end
    return id
end
-- link: how Tillandsias is joined to the thing (static-link | dynamic-link |
--       separate-process | container-image | runtime-download | bundled-file | service)
local function node(id, fields)
    local n = nodes[id]
    if not n then
        n = { id = id, pulled_by = L({}) }
        nodes[id] = n
    end
    for k, v in pairs(fields) do if n[k] == nil then n[k] = v end end
    return n
end
local function pulled(id, comp)
    local n = nodes[id]
    for _, c in ipairs(n.pulled_by) do if c == comp then return end end
    n.pulled_by[#n.pulled_by + 1] = comp
end
local edge_seen = {}
local function edge(from, to, kind, optional)
    local key = from .. "\0" .. to .. "\0" .. kind
    if edge_seen[key] then
        if optional == false then edge_seen[key].optional = false end
        return
    end
    local e = { from = from, to = to, kind = kind, optional = optional and true or false }
    edge_seen[key] = e
    edges[#edges + 1] = e
end
local function finish(id, lic, extra)
    local n = nodes[id]
    n.license = lic or "unknown"
    n.license_family = family(n.license)
    for k, v in pairs(extra or {}) do n[k] = v end
end

-- ---------------------------------------------------------------------------
-- 1. Rust crates from cargo metadata.
local meta_src
if META_FILE ~= "" then
    meta_src = read(META_FILE)
    if not meta_src then
        afford("the cargo metadata file " .. META_FILE .. " could not be read", "pass a readable --metadata path")
        verdict.emit("could-not-run:stack-ledger:no-metadata-file", 3)
    end
else
    local r = proc.run({ argv = { "cargo", "metadata", "--format-version", "1", "--locked", "--offline" }, timeout_ms = 180000 })
    if not r or not r.ok or (r.stdout or "") == "" then
        afford("`cargo metadata --locked --offline` did not answer: " .. trim((r and r.stderr or ""):sub(1, 300)),
            "run inside the builder toolbox (cargo on PATH, registry cached), or pass --metadata <file>")
        verdict.emit("could-not-run:stack-ledger:no-cargo-metadata", 3)
    end
    meta_src = r.stdout
end
local okp, meta = pcall(json.parse, meta_src)
if not okp or type(meta) ~= "table" or not meta.packages then
    verdict.emit("could-not-run:stack-ledger:metadata-unparseable", 3)
end
local by_id, ws = {}, {}
for _, p in ipairs(meta.packages) do by_id[p.id] = p end
for _, id in ipairs(meta.workspace_members or {}) do ws[id] = true end
local function crate_node_id(p) return "cargo:" .. p.name .. "@" .. p.version end
local function homepage_of(p)
    if str(p.homepage) and str(p.homepage) ~= "" then return str(p.homepage), "declared" end
    if str(p.repository) and str(p.repository) ~= "" then return str(p.repository), "repository" end
    return "https://crates.io/crates/" .. p.name, "registry"
end
-- Every workspace crate is a component; every external package is a node.
for id, p in pairs(by_id) do
    if ws[id] then
        component("crate:" .. p.name, p.name, "rust-crate", trim(str(p.description) or ""))
    else
        local hp, hk = homepage_of(p)
        local n = node(crate_node_id(p), {
            name = p.name, version = p.version, homepage = hp, homepage_kind = hk,
            source = "cargo-metadata", link = "static-link",
            link_note = "Rust crate compiled into a Tillandsias binary; a *-sys crate may also dynamically link the system library it wraps",
        })
        finish(n.id, str(p.license))
    end
end
-- Resolve graph: direct edges from workspace crates, transitive between packages.
local resolve_nodes = {}
for _, rn in ipairs((meta.resolve or {}).nodes or {}) do resolve_nodes[rn.id] = rn end
for id, p in pairs(by_id) do
    local rn = resolve_nodes[id]
    if rn then
        local from = ws[id] and ("crate:" .. p.name) or crate_node_id(p)
        -- optional flags come from the DECLARATION, matched by crate name.
        local optional_by_name, dev_only = {}, {}
        for _, d in ipairs(p.dependencies or {}) do
            local nm = str(d.rename) or d.name
            if nn(d.optional) then optional_by_name[nm] = true end
            dev_only[nm] = (dev_only[nm] == nil or dev_only[nm]) and str(d.kind) == "dev"
        end
        for _, dep in ipairs(rn.deps or {}) do
            local tp = by_id[dep.pkg]
            if tp then
                local to = ws[dep.pkg] and ("crate:" .. tp.name) or crate_node_id(tp)
                local kinds = {}
                for _, dk in ipairs(dep.dep_kinds or {}) do kinds[str(dk.kind) or "normal"] = true end
                local kind = ws[id] and "direct" or "transitive"
                if kinds.dev and not kinds.normal and not kinds.build then kind = kind .. "-dev"
                elseif kinds.build and not kinds.normal then kind = kind .. "-build" end
                local opt = optional_by_name[tp.name] or optional_by_name[dep.name] or false
                edge(from, to, kind, opt)
                if not ws[dep.pkg] then
                    if ws[id] then pulled(to, from) end
                    local tn = nodes[to]
                    if tn.optional == nil then tn.optional = opt elseif not opt then tn.optional = false end
                end
            end
        end
    end
end
-- A crate reached only through other crates is pulled by whichever workspace
-- crates reach it; walk the graph once so every node names its puller(s).
do
    local adj = {}
    for _, e in ipairs(edges) do adj[e.from] = adj[e.from] or {}; table.insert(adj[e.from], e.to) end
    for cid in pairs(components) do
        local seen, stack = {}, { cid }
        while #stack > 0 do
            local cur = table.remove(stack)
            for _, nxt in ipairs(adj[cur] or {}) do
                if not seen[nxt] then
                    seen[nxt] = true
                    if nodes[nxt] then pulled(nxt, cid) end
                    stack[#stack + 1] = nxt
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 2. Container images.
local function image_homepage(ref)
    local r = ref:gsub("@sha256:.*$", "")
    local repo, tag = r:match("^(.-):([^/:]+)$")
    repo = repo or r
    if repo:match("^docker%.io/library/") then
        return "https://hub.docker.com/_/" .. repo:gsub("^docker%.io/library/", ""), tag
    elseif repo:match("^docker%.io/") then
        return "https://hub.docker.com/r/" .. repo:gsub("^docker%.io/", ""), tag
    elseif repo:match("^registry%.fedoraproject%.org/") then
        return "https://quay.io/organization/fedora", tag
    elseif repo:match("^ghcr%.io/") then
        return "https://" .. repo, tag
    end
    return "https://" .. repo, tag
end
local DISTRO_INDEX = {
    microdnf = { "fedora", "https://packages.fedoraproject.org/pkgs/%s/" },
    dnf = { "fedora", "https://packages.fedoraproject.org/pkgs/%s/" },
    apk = { "alpine", "https://pkgs.alpinelinux.org/packages?name=%s" },
    ["apt-get"] = { "debian", "https://packages.debian.org/search?keywords=%s" },
}
local function parse_containerfile(path, comp, imgname)
    local src = read(path)
    if not src then return end
    local args = {}
    -- join `\` continuations so a RUN is one logical line
    local logical = src:gsub("\\\r?\n", " ")
    local stage_base = {}
    local function expand(str_)
        return (str_:gsub("%${([%w_]+)}", function(k) return args[k] or ("${" .. k .. "}") end)
                    :gsub("%$([%w_]+)", function(k) return args[k] or ("$" .. k) end))
    end
    for _, line in ipairs(lines(logical)) do
        local l = trim(line)
        local a, v = l:match("^ARG%s+([%w_]+)=(.*)$")
        if a then args[a] = v:gsub('^"(.*)"$', "%1") end
        local from = l:match("^FROM%s+(%S+)")
        if from and not from:match("^%$") and not from:match("^scratch$") then
            local hp, tag = image_homepage(from)
            local id = "oci:" .. from:gsub("@sha256:.*$", "")
            node(id, { name = from:gsub("@sha256:.*$", ""), version = tag or "unknown", homepage = hp, homepage_kind = "registry",
                source = path, link = "container-image", link_note = "base image layer of a Tillandsias-built image" })
            finish(id, nil)
            nodes[id].optional = nodes[id].optional and true or false
            pulled(id, comp)
            edge(comp, id, "base-image", false)
            stage_base[#stage_base + 1] = id
        elseif from and from:match("^%$") then
            -- FROM ${BASE_IMAGE}: another Tillandsias image, named by the arg.
            edge(comp, "image:default-base", "base-image", false)
        end
        if l:match("^RUN%s") then
            local body = l:gsub("^RUN%s+", "")
            for seg in (body .. " && "):gmatch("(.-)%s*&&%s*") do
                seg = trim(seg)
                local mgr = seg:match("^(microdnf)%s+install") or seg:match("^(dnf)%s+%-?y?%s*install") or seg:match("^(apk)%s+add")
                    or seg:match("^(apt%-get)%s+install")
                if mgr then
                    local di = DISTRO_INDEX[mgr]
                    local rest = seg:gsub("^%S+%s+%S+%s*", "")
                    for tok in rest:gmatch("%S+") do
                        if not tok:match("^%-") and tok:match("^[%w][%w%.%+%-_]*$") and not tok:match("^y$") then
                            local id = "pkg:" .. di[1] .. ":" .. tok
                            node(id, { name = tok, version = "unknown", homepage = string.format(di[2], tok), homepage_kind = "package-index",
                                source = path, link = "container-image",
                                link_note = "distro package installed into the image by " .. mgr .. "; licence is declared by the package inside the image, not by a file in this tree" })
                            finish(id, nil)
                            pulled(id, comp)
                            edge(comp, id, "package", false)
                        end
                    end
                end
                local pipm = seg:match("^pip3?%s+install%s+(.*)$")
                if pipm then
                    for spec in pipm:gmatch('"?([%w_%-%.%[%]]+==[^"%s]+)"?') do
                        local nm, ver = spec:match("^([%w_%-%.%[%]]+)==(.+)$")
                        if nm then
                            ver = expand(ver)
                            local id = "pypi:" .. nm
                            node(id, { name = nm, version = ver, homepage = "https://pypi.org/project/" .. nm:gsub("%[.*%]", "") .. "/",
                                homepage_kind = "registry", source = path, link = "container-image" })
                            finish(id, nil)
                            pulled(id, comp)
                            edge(comp, id, "package", false)
                        end
                    end
                    local req = pipm:match("%-r%s+(%S+)")
                    if req then
                        local id = "pypi:requirements:" .. imgname
                        node(id, { name = "python requirements (" .. req .. ")", version = "unknown", homepage = nil, homepage_kind = "none",
                            source = path, link = "container-image",
                            link_note = "a requirements file resolved at image build; its members are not enumerated in this tree" })
                        finish(id, nil)
                        pulled(id, comp)
                        edge(comp, id, "package", false)
                    end
                end
                local npmg = seg:match("^npm%s+install%s+(.*)$")
                if npmg and npmg:match("%-g") then
                    for tok in npmg:gmatch("%S+") do
                        tok = tok:gsub('^"(.*)"$', "%1")
                        if not tok:match("^%-") and tok ~= "" then
                            tok = expand(tok)
                            local nm, ver = tok:match("^(@?[^@]+)@([^@]+)$")
                            if not nm then nm, ver = tok, "unknown" end
                            local id = "npm:" .. nm .. "@" .. ver
                            node(id, { name = nm, version = ver, homepage = "https://www.npmjs.com/package/" .. nm, homepage_kind = "registry",
                                source = path, link = "container-image", link_note = "npm package installed globally into the image" })
                            finish(id, nil)
                            pulled(id, comp)
                            edge(comp, id, "package", false)
                        end
                    end
                end
                local clone = seg:match("^git%s+clone%s+(.*)$")
                if clone then
                    local url = clone:match("(https?://%S+)")
                    local ref = clone:match("%-%-branch%s+\"?([^\"%s]+)")
                    if url then
                        url = expand(url)
                        ref = expand(ref or "unknown")
                        if not clone:match("%-%-branch") then
                            -- `git clone URL dir` then a separate checkout of an ARG: the ARG whose
                            -- name is the repository's name (COMFYUI_REF <-> ComfyUI) is the pin.
                            local repo_key = (url:match("([^/]+)/?$") or ""):gsub("%.git$", ""):lower():gsub("[^%w]", "")
                            for k, v in pairs(args) do
                                local kk = k:lower():gsub("_ref$", ""):gsub("_tag$", ""):gsub("_version$", ""):gsub("[^%w]", "")
                                if kk ~= "" and kk == repo_key then ref = v end
                            end
                        end
                        local id = "src:" .. url:gsub("%.git$", "")
                        node(id, { name = url:gsub("^https?://", ""):gsub("%.git$", ""), version = ref, homepage = url:gsub("%.git$", ""),
                            homepage_kind = "repository", source = path, link = "container-image",
                            link_note = "source cloned and built inside the image" })
                        finish(id, nil)
                        pulled(id, comp)
                        edge(comp, id, "source-build", false)
                    end
                end
                local curl = seg:match("^curl%s+.*%-o%s+%S+%s+\"?(https?://[^\"%s]+)")
                if curl then
                    local url = expand(curl)
                    local host = url:match("^https?://([^/]+)")
                    local id = "download:" .. url:gsub("^https?://", ""):gsub("[?#].*$", "")
                    node(id, { name = url:gsub("^https?://", ""):gsub("[?#].*$", ""), version = "unknown", homepage = "https://" .. host,
                        homepage_kind = "host", source = path, link = "container-image", link_note = "archive fetched at image build" })
                    finish(id, nil)
                    pulled(id, comp)
                    edge(comp, id, "download", false)
                end
            end
        end
    end
    return args
end
-- Which images the launcher needs for any project (required) and which it pulls
-- for a feature a user turns on (optional). DECLARED HERE, not derived: the
-- launcher's pull-on-first-use logic is not a file this generator reads.
local IMAGE_OPTIONAL = {
    default = false, ["default-base"] = false, builder = false, git = false, proxy = false, router = false, vault = false, web = false,
    inference = true, imagegen = true, ["imagegen-cuda"] = true, ["imagegen-studio"] = true, chromium = true, webkit = true,
    flutter = true, warp = true, ["web-wrangler"] = true, ["web-studio-grapesjs"] = true, observatorium = true,
}
local containerfiles = fs.walk("images", { suffix = "" })
table.sort(containerfiles)
local image_count = 0
for _, f in ipairs(containerfiles) do
    local dir, fname = f:match("^images/([^/]+)/(Containerfile[^/]*)$")
    if dir and fname then
        image_count = image_count + 1
        local suffix = fname:match("^Containerfile%.(.+)$")
        local imgname = dir .. (suffix and ("-" .. suffix) or "")
        if dir == "default" and suffix == "base" then imgname = "default-base" end
        local comp = component("image:" .. imgname, "tillandsias-" .. imgname .. " image", "container-image", "built from " .. f)
        components[comp].optional = IMAGE_OPTIONAL[imgname]
        components[comp].optional_source = "generator-table"
        parse_containerfile(f, comp, imgname)
    end
end
if read("observatorium/Containerfile") then
    image_count = image_count + 1
    local comp = component("image:observatorium", "observatorium image", "container-image", "built from observatorium/Containerfile")
    components[comp].optional = true
    components[comp].optional_source = "generator-table"
    parse_containerfile("observatorium/Containerfile", comp, "observatorium")
end
if image_count == 0 then
    afford("no images/*/Containerfile* was found — the generator inspected no image", "run from the checkout root")
    verdict.emit("could-not-run:stack-ledger:no-containerfiles", 3)
end
-- optional flag on image-pulled nodes follows the image
for _, n in pairs(nodes) do
    if n.optional == nil then
        local opt = true
        for _, c in ipairs(n.pulled_by) do
            local comp = components[c]
            if comp and comp.optional == false then opt = false end
        end
        n.optional = opt
    end
end

-- ---------------------------------------------------------------------------
-- 3. npm lockfiles beside Containerfiles (the pinned members of an npm ci).
local function parse_lock(path, comp)
    local src = read(path)
    if not src then return end
    local okl, lock = pcall(json.parse, src)
    if not okl or type(lock) ~= "table" or type(lock.packages) ~= "table" then return end
    local keys = {}
    for k in pairs(lock.packages) do if k ~= "" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local p = lock.packages[k]
        local nm = k:gsub("^.*node_modules/", "")
        local id = "npm:" .. nm .. "@" .. (str(p.version) or "unknown")
        local direct = not k:match("node_modules/.*node_modules/")
        node(id, { name = nm, version = (str(p.version) or "unknown"), homepage = "https://www.npmjs.com/package/" .. nm,
            homepage_kind = "registry", source = path, link = "container-image",
            link_note = "npm package installed into the image from its lockfile" })
        finish(id, str(p.license))
        nodes[id].optional = components[comp].optional and true or false
        pulled(id, comp)
        edge(comp, id, direct and "direct" or "transitive", nn(p.optional) and true or false)
        if nn(p.dev) then nodes[id].dev_only = true end
    end
end
parse_lock("images/web-wrangler/package-lock.json", "image:web-wrangler")
if components["image:observatorium"] then parse_lock("observatorium/package-lock.json", "image:observatorium") end

-- ---------------------------------------------------------------------------
-- 4. Media models: the licence register is the source; models.tsv names tiers.
do
    local reg = read("images/models/licence-register.tsv")
    if reg then
        local comp = component("media:imagegen-models", "image-generation models", "media-models",
            "weights fetched at first use from the Hugging Face Hub, each pinned by revision and sha256 in images/models/licence-register.tsv")
        components[comp].optional = true
        components[comp].optional_source = "generator-table"
        local tiers = {}
        local mt = read("images/imagegen/models.tsv")
        if mt then
            for _, l in ipairs(lines(mt)) do
                if not l:match("^#") and l ~= "" then
                    local c = {}
                    for f in (l .. "\t"):gmatch("([^\t]*)\t") do c[#c + 1] = f end
                    if c[3] then tiers[c[3]] = tiers[c[3]] or {}; tiers[c[3]][c[1]] = true end
                end
            end
        end
        for _, l in ipairs(lines(reg)) do
            if not l:match("^#") and l ~= "" then
                local c = {}
                for f in (l .. "\t"):gmatch("([^\t]*)\t") do c[#c + 1] = f end
                local name, repo, rev, _, _, lic, gated, url = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
                if repo and repo ~= "" then
                    local id = "model:" .. repo
                    local tl = {}
                    for t in pairs(tiers[repo] or {}) do tl[#tl + 1] = t end
                    table.sort(tl)
                    node(id, { name = name, version = rev, homepage = (url and url ~= "") and url or ("https://huggingface.co/" .. repo),
                        homepage_kind = "model-card", source = "images/models/licence-register.tsv", link = "runtime-download",
                        link_note = "model weights downloaded on first use after the user accepts the tier; never shipped in a release",
                        gated = (gated == "true"), tiers = L(tl) })
                    finish(id, lic)
                    nodes[id].optional = true
                    pulled(id, comp)
                    edge(comp, id, "runtime-download", true)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 5. Web studios (separate containers; the registry declares each licence).
do
    local src = read("crates/tillandsias-headless/data/studios.json")
    local oks, reg = pcall(json.parse, src or "")
    if oks and type(reg) == "table" then
        local comp = component("studio:web-studios", "web studios", "studios",
            "visual editors launched as separate containers beside a project, chosen by the user")
        components[comp].optional = true
        components[comp].optional_source = "generator-table"
        for _, s in ipairs(reg.studios or {}) do
            local id = "studio:" .. s.id
            node(id, { name = str(s.name), version = "unknown", homepage = nil, homepage_kind = "none",
                source = "crates/tillandsias-headless/data/studios.json", link = "separate-process",
                link_note = "runs unmodified in its own container; " .. (str(s.brief) or ""), status = str(s.status) })
            finish(id, str(s.license))
            nodes[id].optional = true
            pulled(id, comp)
            edge(comp, id, "runtime-image", true)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 6. ComfyUI custom nodes (studio plugins) from the manifest.
do
    local src = read("images/imagegen-studio/custom-nodes.toml")
    if src and components["image:imagegen-studio"] then
        local cur
        for _, l in ipairs(lines(src)) do
            l = trim(l)
            if l == "[[node]]" then cur = {}
            elseif cur then
                local k, v = l:match('^([%w_]+)%s*=%s*"(.-)"%s*$')
                if k then cur[k] = v end
                if cur.name and cur.repo and cur.license and not cur.done then
                    cur.done = true
                    local id = "src:" .. cur.repo:gsub("%.git$", "")
                    node(id, { name = cur.name, version = cur.commit or "unknown", homepage = cur.repo, homepage_kind = "repository",
                        source = "images/imagegen-studio/custom-nodes.toml", link = "container-image",
                        link_note = "ComfyUI custom node cloned at a pinned commit into the studio image" })
                    finish(id, cur.license)
                    nodes[id].optional = true
                    pulled(id, "image:imagegen-studio")
                    edge("image:imagegen-studio", id, "plugin", true)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 7. Vendored files: the licence is read from the LICENSE text beside them.
local function licence_from_text(body)
    local b = (body or ""):lower()
    if b:match("apache license") and b:match("version 2%.0") then return "Apache-2.0" end
    if b:match("permission is hereby granted, free of charge") then return "MIT" end
    if b:match("redistribution and use in source and binary forms") then
        if b:match("neither the name") then return "BSD-3-Clause" end
        return "BSD-2-Clause"
    end
    if b:match("gnu general public license") and b:match("version 3") then return "GPL-3.0-only" end
    if b:match("mozilla public license") and b:match("2%.0") then return "MPL-2.0" end
    return nil
end
do
    local dir = "crates/tillandsias-core/data/devices/upstream"
    local files = fs.walk(dir, { suffix = "LICENSE" })
    table.sort(files)
    for _, f in ipairs(files) do
        local base = f:match("([^/]+)%-LICENSE$")
        if base then
            local lic = licence_from_text(read(f))
            local hp = ({ devtools = "https://github.com/ChromeDevTools/devtools-frontend", playwright = "https://github.com/microsoft/playwright" })[base]
            local id = "vendored:" .. base .. "-device-descriptors"
            node(id, { name = base .. " device descriptors", version = "unknown", homepage = hp, homepage_kind = hp and "repository" or "none",
                source = f, link = "bundled-file",
                link_note = "data file copied into the tree with its upstream LICENSE; licence read from that text by signature" })
            finish(id, lic, { license_source = lic and "licence-text-match" or "licence-text-unrecognised" })
            nodes[id].optional = false
            pulled(id, "crate:tillandsias-core")
            edge("crate:tillandsias-core", id, "vendored", false)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 8. Bundled documentation sources (cheatsheets allowlist).
do
    local src = read("cheatsheets/license-allowlist.toml")
    if src then
        local comp = component("docs:cheatsheets", "bundled reference cheatsheets", "documentation",
            "third-party reference material summarised for agents; the allowlist classifies each publisher's redistribution terms")
        components[comp].optional = false
        components[comp].optional_source = "generator-table"
        local cur, dom
        local function flush()
            if dom and cur then
                local id = "docs:" .. dom
                node(id, { name = cur.publisher or dom, version = "unknown", homepage = "https://" .. dom, homepage_kind = "host",
                    source = "cheatsheets/license-allowlist.toml", link = "bundled-file",
                    link_note = "redistribution=" .. tostring(cur.redistribution) .. "; tier=" .. tostring(cur.default_tier),
                    license_url = cur.license_url })
                finish(id, cur.license)
                nodes[id].optional = false
                pulled(id, comp)
                edge(comp, id, "bundled", false)
            end
        end
        for _, l in ipairs(lines(src)) do
            local d = l:match('^%[domains%."([^"]+)"%]')
            if d then flush(); dom = d; cur = {}
            elseif cur then
                local k, v = l:match('^([%w_]+)%s*=%s*"(.-)"')
                if k then cur[k] = v end
            end
        end
        flush()
    end
end

-- ---------------------------------------------------------------------------
-- 9. External services: emitted only when the host appears in the tree.
do
    local SERVICES = {
        { "github.com", "GitHub", "https://github.com", "source hosting, releases, the fleet's pull requests" },
        { "api.github.com", "GitHub API", "https://docs.github.com/rest", "release lookup and pull-request automation" },
        { "opencode.ai", "OpenCode", "https://opencode.ai", "the hosted model gateway the forge's agent talks to" },
        { "models.dev", "models.dev", "https://models.dev", "model catalogue read by OpenCode" },
        { "api.anthropic.com", "Anthropic API", "https://docs.anthropic.com", "an optional hosted model provider" },
        { "huggingface.co", "Hugging Face Hub", "https://huggingface.co", "model weights, pinned by revision" },
        { "cloudflare.com", "Cloudflare", "https://www.cloudflare.com", "optional tunnels, DNS and Workers deploys" },
        { "registry.npmjs.org", "npm registry", "https://www.npmjs.com", "JavaScript packages at image build" },
        { "nodejs.org", "Node.js downloads", "https://nodejs.org", "Node.js archives at image build" },
        { "crates.io", "crates.io", "https://crates.io", "Rust crates at build" },
        { "pypi.org", "PyPI", "https://pypi.org", "Python packages at image build" },
        { "download.pytorch.org", "PyTorch wheels", "https://pytorch.org", "CUDA torch wheels for the imagegen studio" },
        { "docker.io", "Docker Hub", "https://hub.docker.com", "base images" },
        { "registry.fedoraproject.org", "Fedora registry", "https://registry.fedoraproject.org", "Fedora base images" },
        { "storage.googleapis.com", "Google Cloud Storage", "https://cloud.google.com/storage", "Flutter SDK archives" },
    }
    local comp = component("services:external", "external services", "services",
        "network endpoints Tillandsias contacts; each has its own terms, none is software we redistribute")
    components[comp].optional = false
    components[comp].optional_source = "generator-table"
    local hay = {}
    for _, root in ipairs({ "crates", "scripts", "images" }) do
        for _, f in ipairs(fs.walk(root, { suffix = "" })) do
            if f:match("%.rs$") or f:match("%.sh$") or f:match("%.lua$") or f:match("Containerfile") or f:match("%.tsv$") or f:match("%.toml$") then
                hay[#hay + 1] = f
            end
        end
    end
    local corpus = {}
    for _, f in ipairs(hay) do corpus[#corpus + 1] = read(f) or "" end
    local big = table.concat(corpus, "\n")
    for _, s in ipairs(SERVICES) do
        local host, name, hp, why = s[1], s[2], s[3], s[4]
        local pat = host:gsub("%.", "%%.")
        if big:find(pat) then
            local id = "service:" .. host
            node(id, { name = name, version = "unknown", homepage = hp, homepage_kind = "declared", source = "host appears in crates/, scripts/ or images/",
                link = "service", link_note = why })
            finish(id, "not-applicable", { license_family = "service" })
            nodes[id].license_family = "service"
            nodes[id].optional = not (host == "github.com" or host == "api.github.com" or host == "docker.io" or host == "registry.fedoraproject.org" or host == "crates.io")
            pulled(id, comp)
            edge(comp, id, "service", nodes[id].optional)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Emit.
local comp_list, node_list = {}, {}
for _, c in pairs(components) do comp_list[#comp_list + 1] = c end
for _, n in pairs(nodes) do
    table.sort(n.pulled_by)
    node_list[#node_list + 1] = n
end
table.sort(comp_list, function(a, b) return a.id < b.id end)
table.sort(node_list, function(a, b) return a.id < b.id end)
table.sort(edges, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    if a.to ~= b.to then return a.to < b.to end
    return a.kind < b.kind
end)
local fam_counts = {}
for _, n in ipairs(node_list) do fam_counts[n.license_family] = (fam_counts[n.license_family] or 0) + 1 end
local doc = {
    schema = "tillandsias-stack/v1",
    project = { name = "Tillandsias", license = "GPL-3.0-or-later", homepage = "https://tillandsias.org",
        source = "https://github.com/8007342/tillandsias" },
    honesty = L({
        "Every licence here is copied from what the upstream source declares (cargo metadata, a lockfile, a model card recorded in the register, a LICENSE text). None was typed by hand.",
        "unknown means no file in this tree declares the licence; distro packages carry theirs inside the image and are listed so you can look.",
        "optional means a user turns the feature on and the dependency is pulled then; required ships with every install.",
        "Licence families are a reading of the SPDX expression for the page's rings; the raw expression is beside each node.",
    }),
    inputs = L({ "cargo metadata (Cargo.lock)", "images/*/Containerfile*", "observatorium/Containerfile", "images/web-wrangler/package-lock.json",
        "observatorium/package-lock.json", "images/models/licence-register.tsv", "images/imagegen/models.tsv",
        "crates/tillandsias-headless/data/studios.json", "images/imagegen-studio/custom-nodes.toml",
        "crates/tillandsias-core/data/devices/upstream/*-LICENSE", "cheatsheets/license-allowlist.toml" }),
    generator = "scripts/lua/build-stack-ledger.lua",
    components = L(comp_list),
    nodes = L(node_list),
    edges = L(edges),
    summary = { components = #comp_list, nodes = #node_list, edges = #edges, license_families = fam_counts },
}
local body = encode(doc)
local tail = string.format("nodes=%d:edges=%d", #node_list, #edges)
if check then
    local cur = read(OUT)
    if cur == body then verdict.emit("ok:stack-ledger:fresh:" .. tail, 0) end
    afford(OUT .. " does not match what the sources of truth produce now",
        "tillandsias-plan script run scripts/lua/build-stack-ledger.lua, then commit " .. OUT)
    verdict.emit("violation:stack-ledger:stale", 1)
end
local dir = OUT:match("^(.*)/[^/]+$")
if dir then pcall(fs.mkdir, dir) end
fs.write(OUT, body)
verdict.emit("ok:stack-ledger:written:" .. tail, 0)
