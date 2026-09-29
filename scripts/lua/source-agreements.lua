-- @trace order:1475-j9kv
--
-- Pure, shadow-only agreement evaluator.  It deliberately reads an explicit
-- manifest and its explicitly named sources: no directory walk, command,
-- clock, environment lookup, or write is part of the evaluator's result.

local function result(id, operation, exit_code, verdict, diagnostic)
    return {
        id = id,
        operation = operation,
        exit = exit_code,
        ok = exit_code == 0,
        verdict = verdict,
        diagnostic = diagnostic or verdict,
    }
end

local function read(path, blocked)
    local ok, value = pcall(fs.read, path)
    if ok then return value end
    return nil, "blocked:" .. blocked .. ":" .. path
end

local function tray_process_naming(case)
    local source = read(case.source, "source-unreadable")
    -- The Bash guard treats an unreadable target as one violation, rather than
    -- calling it a passing empty source.
    if not source then
        return result(case.id, case.operation, 1,
            "violation:tray-process-naming:1")
    end

    local violations = 0
    if source:find("pub vm_owner_live:", 1, true) then violations = violations + 1 end
    if source:find("fn live_tray_owns_vm", 1, true) then violations = violations + 1 end
    if not source:find("pub tray_process_running: bool,", 1, true) then
        violations = violations + 1
    end
    if violations == 0 then
        return result(case.id, case.operation, 0, "ok:tray-process-naming:3 checked")
    end
    return result(case.id, case.operation, 1,
        "violation:tray-process-naming:" .. tostring(violations))
end

local function model_from_hook(source)
    return source:match('export TILLANDSIAS_EMBED_MODEL="([^"]*)"')
end

local function model_from_ensure(source)
    return source:match('EMBED_MODEL="%${TILLANDSIAS_EMBED_MODEL:%-([^}]*)}"')
end

local function dev_embed_model_agreement(case)
    local hook = read(case.hook, "hook-unreadable") or ""
    local ensure = read(case.ensure, "ensure-unreadable") or ""
    local hook_model = model_from_hook(hook) or ""
    local ensure_model = model_from_ensure(ensure) or ""
    if hook_model == "" or ensure_model == "" then
        return result(case.id, case.operation, 1,
            "violation:dev-embed-model-mismatch:could not read a default (hook='"
                .. hook_model .. "' ensure='" .. ensure_model .. "')")
    end
    if hook_model ~= ensure_model then
        return result(case.id, case.operation, 1,
            "violation:dev-embed-model-mismatch:hook=" .. hook_model .. " ensure=" .. ensure_model)
    end
    return result(case.id, case.operation, 0,
        "ok:dev-embed-model-agreement:" .. hook_model)
end

local function dev_container_name(source)
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        local name = line:match('^DEV_CONTAINER="([^"]*)"')
        if name then return name end
    end
    return nil
end

local function candidate_names(source)
    -- The Rust type itself contains a semicolon (`[&str; N]`), so stopping at
    -- the first semicolon silently selects the type rather than the value.
    -- Match the two balanced bracket groups around the assignment instead.
    local declaration = source:match(
        "const%s+INFERENCE_CONTAINER_CANDIDATES%s*:%s*%b[]%s*=%s*(%b[])")
    if not declaration then return nil end
    local names = {}
    for name in declaration:gmatch('"([a-z0-9%-]+)"') do
        names[#names + 1] = name
    end
    return names
end

local function inference_container_name_agreement(case)
    local script = read(case.script, "script-unreadable")
    if not script then
        return result(case.id, case.operation, 2,
            "blocked:script-unreadable:" .. case.script)
    end
    local probe = read(case.probe, "probe-unreadable")
    if not probe then
        return result(case.id, case.operation, 2,
            "blocked:probe-unreadable:" .. case.probe)
    end
    local creator = dev_container_name(script)
    if not creator or creator == "" then
        return result(case.id, case.operation, 2,
            "blocked:no-dev-container-assignment-in:" .. case.script)
    end
    local candidates = candidate_names(probe)
    if not candidates then
        return result(case.id, case.operation, 2,
            "blocked:no-candidate-list-in:" .. case.probe)
    end
    for _, candidate in ipairs(candidates) do
        if candidate == creator then
            return result(case.id, case.operation, 0,
                "ok:inference-container-name-agreement:" .. creator)
        end
    end
    return result(case.id, case.operation, 1,
        "violation:inference-container-name-drift:creates=" .. creator
            .. ":candidates=" .. table.concat(candidates, ","))
end

local operations = {
    tray_process_naming = tray_process_naming,
    dev_embed_model_agreement = dev_embed_model_agreement,
    inference_container_name_agreement = inference_container_name_agreement,
}

-- Kept separately so mutation tests can drive malformed, empty, and duplicate
-- manifests without giving the evaluator any host capability.
function source_agreements_text(text)
    local parsed, manifest = pcall(yaml.parse, text)
    if not parsed or type(manifest) ~= "table" then
        return { ok = false, cases = {}, error = "blocked:manifest-malformed" }
    end
    if type(manifest.cases) ~= "table" or #manifest.cases == 0 then
        return { ok = false, cases = {}, error = "blocked:manifest-empty" }
    end

    local seen, cases, ok = {}, {}, true
    for _, case in ipairs(manifest.cases) do
        if type(case) ~= "table" or type(case.id) ~= "string" or case.id == "" then
            return { ok = false, cases = {}, error = "blocked:case-id-missing" }
        end
        if seen[case.id] then
            return { ok = false, cases = {}, error = "blocked:duplicate-case-id:" .. case.id }
        end
        seen[case.id] = true
    end

    local required_fields = {
        tray_process_naming = { "source" },
        dev_embed_model_agreement = { "hook", "ensure" },
        inference_container_name_agreement = { "script", "probe" },
    }
    for _, case in ipairs(manifest.cases) do
        local operation = operations[case.operation]
        local outcome
        if not operation then
            outcome = result(case.id, case.operation or "", 2,
                "blocked:unknown-operation:" .. tostring(case.operation))
        else
            local missing
            for _, field in ipairs(required_fields[case.operation]) do
                if type(case[field]) ~= "string" or case[field] == "" then
                    missing = field
                    break
                end
            end
            if missing then
                outcome = result(case.id, case.operation, 2,
                    "blocked:case-field-missing:" .. case.id .. ":" .. missing)
            else
                outcome = operation(case)
            end
        end
        cases[#cases + 1] = outcome
        if not outcome.ok then ok = false end
    end
    return { ok = ok, cases = cases }
end

function source_agreements(manifest_path)
    local text, error = read(manifest_path, "manifest-unreadable")
    if not text then return { ok = false, cases = {}, error = error } end
    return source_agreements_text(text)
end
