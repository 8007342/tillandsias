-- @trace order:1956-bh6j (spec: openspec/changes/studio-asset-pipeline, design D4)
--
-- test-studio-node-pins.lua — the ComfyUI studio's custom nodes and the
-- weights they load are pinned and licence-checked, offline, from the files
-- as they stand:
--
--   * every [[node]] in images/imagegen-studio/custom-nodes.toml names a
--     40-hex commit, a lock file that exists, and a licence;
--   * no row of images/imagegen/models.tsv or images/models/licence-register.tsv
--     names RMBG (BRIA, custom non-commercial) or InsightFace (non-commercial);
--     the studio matte is BiRefNet-only and IP-Adapter is non-FaceID only;
--   * every aux row of models.tsv (role lora, controlnet:<name> or
--     studio:<kind>) has its tier folder listed in the studio's
--     extra_model_paths.yaml, because the studio has no egress: a weight the
--     yaml does not map is one a node would try to download.
--
-- Each rule is first proven on synthetic rows (a refused arm and a passing
-- arm), then applied to the live files. Pure fs reads, no spawn, no scratch.
--
-- Verdicts:
--   ok:studio-node-pins:<arms> arms:nodes=<n>   exit 0
--   refused:studio-node-pins:<passed>/<total>    exit 1
--   could-not-run:studio-node-pins:<why>         exit 3

local TOML = "images/imagegen-studio/custom-nodes.toml"
local MODELS = "images/imagegen/models.tsv"
local REG = "images/models/licence-register.tsv"
local PATHS = "images/imagegen-studio/extra_model_paths.yaml"

local function read(path)
    local ok, body = pcall(fs.read, path)
    if not ok or not body then
        verdict.emit("could-not-run:studio-node-pins:cannot-read:" .. path, 3)
    end
    return body
end

-- The [[node]] tables of a custom-nodes.toml: name, repo, commit, license, lock.
-- Values are the double-quoted strings the manifest uses; a bare key is kept
-- as its raw text so a missing quote still counts as present-but-odd.
local function parse_nodes(body)
    local nodes, cur = {}, nil
    for _, raw in ipairs(text.lines(body)) do
        local line = raw:gsub("#.*$", "")
        line = text.trim(line)
        if line == "[[node]]" then
            cur = {}
            nodes[#nodes + 1] = cur
        elseif cur and line ~= "" then
            local k, v = line:match('^([%w_]+)%s*=%s*"(.-)"%s*$')
            if not k then k, v = line:match("^([%w_]+)%s*=%s*(.-)%s*$") end
            if k then cur[k] = v end
        end
    end
    return nodes
end

-- One refusal line per node that is not fully pinned.
local function check_nodes(nodes, exists)
    local out = {}
    for i, n in ipairs(nodes) do
        local name = n.name or ("node#" .. i)
        if not n.commit or n.commit == "" then
            out[#out + 1] = "refused:node:" .. name .. ":no-commit"
        elseif not (#n.commit == 40 and n.commit:match("^%x+$")) then
            out[#out + 1] = "refused:node:" .. name .. ":commit-not-40-hex"
        end
        if not n.lock or n.lock == "" then
            out[#out + 1] = "refused:node:" .. name .. ":no-lock"
        elseif not exists("images/imagegen-studio/" .. n.lock) then
            out[#out + 1] = "refused:node:" .. name .. ":lock-missing:" .. n.lock
        end
        if not n.license or n.license == "" then
            out[#out + 1] = "refused:node:" .. name .. ":no-licence"
        end
        if not n.repo or n.repo == "" then
            out[#out + 1] = "refused:node:" .. name .. ":no-repo"
        end
    end
    return out
end

-- The non-comment, non-empty rows of a TSV, each split on tabs.
local function rows_of(body)
    local rows = {}
    for _, line in ipairs(text.lines(body)) do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local c = {}
            for f in (line .. "\t"):gmatch("(.-)\t") do c[#c + 1] = f end
            rows[#rows + 1] = c
        end
    end
    return rows
end

local BANNED = { "rmbg", "insightface" }

-- One refusal per weight row naming a banned family, in any column.
local function check_weights(body, label)
    local out = {}
    for _, c in ipairs(rows_of(body)) do
        local joined = table.concat(c, "\t"):lower()
        for _, word in ipairs(BANNED) do
            if joined:find(word, 1, true) then
                out[#out + 1] = "refused:weight:" .. label .. ":" .. (c[1] or "?") .. ":names-" .. word
            end
        end
    end
    return out
end

-- The folders the studio yaml maps: every indented line that is not a key.
local function yaml_folders(body)
    local set = {}
    for _, line in ipairs(text.lines(body)) do
        local t = text.trim((line:gsub("#.*$", "")))
        if t ~= "" and not t:find(":", 1, true) then set[t] = true end
    end
    return set
end

local function is_aux_role(role)
    return role == "lora" or role:find("^controlnet:") ~= nil or role:find("^studio:") ~= nil
end

-- One refusal per aux row whose tier folder the studio yaml does not map.
local function check_folders(models_body, yaml_body)
    local folders, out = yaml_folders(yaml_body), {}
    for _, c in ipairs(rows_of(models_body)) do
        local tier, role = c[1] or "", c[2] or ""
        if is_aux_role(role) and not folders[tier] then
            out[#out + 1] = "refused:folder:" .. tier .. ":not-in-extra_model_paths.yaml"
        end
    end
    return out
end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        failed = failed + 1
        out.line("FAIL: " .. name .. " — " .. tostring(why))
    end
end
local function has(list, needle)
    for _, l in ipairs(list) do if l:find(needle, 1, true) then return true end end
    return false
end

-- ARMS on synthetic input. The lock-exists probe is a table, never the fs.
local HEX = string.rep("a", 40)
local present = { ["images/imagegen-studio/locks/Good.txt"] = true }
local function fake_exists(p) return present[p] == true end
local good = '[[node]]\nname = "Good"\nrepo = "https://example.invalid/good"\ncommit = "'
    .. HEX .. '"\nlicense = "MIT"\nlock = "locks/Good.txt"\n'
local no_commit = '[[node]]\nname = "NoCommit"\nrepo = "https://example.invalid/x"\nlicense = "MIT"\nlock = "locks/Good.txt"\n'
local short_commit = '[[node]]\nname = "Short"\nrepo = "https://example.invalid/x"\ncommit = "abc123"\nlicense = "MIT"\nlock = "locks/Good.txt"\n'
local no_lock = '[[node]]\nname = "NoLock"\nrepo = "https://example.invalid/x"\ncommit = "' .. HEX .. '"\nlicense = "MIT"\n'
local lock_missing = '[[node]]\nname = "Gone"\nrepo = "https://example.invalid/x"\ncommit = "' .. HEX .. '"\nlicense = "MIT"\nlock = "locks/Gone.txt"\n'
local no_licence = '[[node]]\nname = "NoLicence"\nrepo = "https://example.invalid/x"\ncommit = "' .. HEX .. '"\nlock = "locks/Good.txt"\n'

check("a fully pinned node passes", #check_nodes(parse_nodes(good), fake_exists) == 0,
    table.concat(check_nodes(parse_nodes(good), fake_exists), " "))
check("a node without a commit is refused", has(check_nodes(parse_nodes(no_commit), fake_exists), "NoCommit:no-commit"), "not refused")
check("a node with a short commit is refused", has(check_nodes(parse_nodes(short_commit), fake_exists), "Short:commit-not-40-hex"), "not refused")
check("a node without a lock is refused", has(check_nodes(parse_nodes(no_lock), fake_exists), "NoLock:no-lock"), "not refused")
check("a node whose lock file is missing is refused", has(check_nodes(parse_nodes(lock_missing), fake_exists), "Gone:lock-missing"), "not refused")
check("a node without a licence is refused", has(check_nodes(parse_nodes(no_licence), fake_exists), "NoLicence:no-licence"), "not refused")

local SHA = string.rep("b", 64)
local w_ok = "#tier\trole\n" .. table.concat({ "I1/birefnet", "studio:birefnet", "ZhengPeng7/BiRefNet", HEX, "model.safetensors", SHA, "1", "mit" }, "\t") .. "\n"
local w_rmbg = table.concat({ "I1/birefnet", "studio:birefnet", "briaai/RMBG-2.0", HEX, "model.safetensors", SHA, "1", "mit" }, "\t") .. "\n"
local w_face = table.concat({ "I1/ipadapter", "studio:ipadapter", "h94/IP-Adapter-FaceID", HEX, "ip-adapter-faceid_sdxl.safetensors", SHA, "1", "apache-2.0" }, "\t")
    .. "\n# a comment naming InsightFace is fine\n"
    .. table.concat({ "insightface-buffalo", "deepinsight/insightface", HEX, "buffalo_l.safetensors", SHA, "mit", "false", "https://example.invalid" }, "\t") .. "\n"
check("a BiRefNet weight row passes", #check_weights(w_ok, "fixture") == 0, table.concat(check_weights(w_ok, "fixture"), " "))
check("a weight row naming RMBG is refused", has(check_weights(w_rmbg, "fixture"), "names-rmbg"), "not refused")
local face = check_weights(w_face, "fixture")
check("a weight row naming InsightFace is refused, the comment is not", has(face, "names-insightface") and #face == 1,
    table.concat(face, " "))

local y_ok = "tillandsias:\n  base_path: /models\n  controlnet: |\n    I1/controlnet-union\n  birefnet: |\n    I1/birefnet\n"
local m_two = w_ok .. table.concat({ "I1/controlnet-union", "controlnet:union", "xinsir/x", HEX, "d.safetensors", SHA, "1", "apache-2.0" }, "\t") .. "\n"
    .. table.concat({ "I1", "model", "a/b", HEX, "m.safetensors", SHA, "1", "openrail++" }, "\t") .. "\n"
local m_unmapped = m_two .. table.concat({ "I1/layer_model", "studio:layer_model", "LayerDiffusion/x", HEX, "l.safetensors", SHA, "1", "creativeml-openrail-m" }, "\t") .. "\n"
check("aux rows whose folders the yaml maps pass; a base row needs no mapping", #check_folders(m_two, y_ok) == 0,
    table.concat(check_folders(m_two, y_ok), " "))
check("an aux row the yaml does not map is refused", has(check_folders(m_unmapped, y_ok), "I1/layer_model:not-in-extra_model_paths.yaml"), "not refused")

-- THE LIVE FILES.
local nodes = parse_nodes(read(TOML))
check("custom-nodes.toml has at least one node", #nodes > 0, "no [[node]] table")
local live_nodes = check_nodes(nodes, fs.exists)
for _, l in ipairs(live_nodes) do out.line(l) end
check("every live node is pinned (commit, lock, licence)", #live_nodes == 0, #live_nodes .. " refusal(s) above")
local models_body, reg_body = read(MODELS), read(REG)
local live_w = check_weights(models_body, "models.tsv")
for _, l in ipairs(check_weights(reg_body, "register")) do live_w[#live_w + 1] = l end
for _, l in ipairs(live_w) do out.line(l) end
check("no live weight row names RMBG or InsightFace", #live_w == 0, #live_w .. " refusal(s) above")
local live_f = check_folders(models_body, read(PATHS))
for _, l in ipairs(live_f) do out.line(l) end
check("every live aux weight has its folder in the studio yaml", #live_f == 0, #live_f .. " refusal(s) above")

if failed > 0 then
    verdict.emit("refused:studio-node-pins:" .. passed .. "/" .. (passed + failed), 1)
end
verdict.emit("ok:studio-node-pins:" .. passed .. " arms:nodes=" .. #nodes, 0)
