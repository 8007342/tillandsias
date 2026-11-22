-- @trace order:2220-yj8f, spec:spec-traceability
--
-- local-ci-strict-specs.lua — local-ci.sh to Lua, slice 2 (2220-yj8f): the
-- --strict-all spec selection. Prints every ACTIVE spec_id of the bindings
-- file, one per line, in file order, minus the specs named in --ignore.
-- It replaces get_all_active_specs, spec_in_list and normalize_spec_list
-- (and get_all_active_specs' jq / yq / awk fallbacks): the plan binary that
-- runs this script parses the YAML itself.
--
-- Run as a HELPER (`script run --helper`): stdout is the list and nothing
-- else, because local-ci.sh captures it as CI_FILTER_SPEC_LIST /
-- CI_STRICT_SPEC_LIST. A bindings file that cannot be read or parsed is an
-- error on stderr with an empty list, as the bash fallbacks gave.
--
-- Usage: script run --helper scripts/lua/local-ci-strict-specs.lua
--          -- [--ignore <list>] [--bindings <repo-relative path>]
-- The ignore list is separated by colons, commas or whitespace, as
-- normalize_spec_list read it.

local ignore_raw, bindings = "", "openspec/litmus-bindings.yaml"
local i = 1
while arg[i] do
    if arg[i] == "--ignore" then ignore_raw = arg[i + 1] or ""; i = i + 2
    elseif arg[i] == "--bindings" then bindings = arg[i + 1] or bindings; i = i + 2
    else error("local-ci-strict-specs: unknown argument '" .. arg[i] .. "'") end
end

local ignore = {}
for item in ignore_raw:gmatch("[^:,%s]+") do ignore[item] = true end

local doc = yaml.parse(fs.read(bindings) or "")
local specs = (type(doc) == "table" and type(doc.specs) == "table") and doc.specs or {}
for _, s in ipairs(specs) do
    if type(s) == "table" and s.status == "active" and type(s.spec_id) == "string"
        and s.spec_id ~= "" and not ignore[s.spec_id] then
        out.line(s.spec_id)
    end
end
