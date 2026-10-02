-- @env TILLANDSIAS_TRAY_REFRESH_SOURCE
-- @read-env TILLANDSIAS_TRAY_REFRESH_SOURCE
-- @trace order:147, order:1533-ew3n
-- Static-only Windows source audit.  `body` is deliberately a small Rust-aware
-- lexer, not a brace counter: braces in comments, strings, chars and raw strings
-- do not delimit a function body.
local src = arg[1] or env.get("TILLANDSIAS_TRAY_REFRESH_SOURCE") or "crates/tillandsias-windows-tray/src/notify_icon.rs"
local ok, source = pcall(fs.read, src)
if not ok then verdict.emit("blocked:tray-refresh-no-polling:unreadable:" .. src, 2) end
local function mask_rust(source)
    local i, state, block_depth, raw_hashes, out = 1, "code", 0, 0, {}
    while i <= #source do
        local c, n = source:sub(i, i), source:sub(i + 1, i + 1)
        if state == "line" then
            out[#out + 1] = c == "\n" and "\n" or " "
            if c == "\n" then state = "code" end
        elseif state == "block" then
            out[#out + 1] = c == "\n" and "\n" or " "
            if c == "/" and n == "*" then block_depth = block_depth + 1; out[#out + 1] = " "; i = i + 1
            elseif c == "*" and n == "/" then block_depth = block_depth - 1; out[#out + 1] = " "; i = i + 1; if block_depth == 0 then state = "code" end end
        elseif state == "string" then
            out[#out + 1] = c == "\n" and "\n" or " "
            if c == "\\" then out[#out + 1] = n == "\n" and "\n" or " "; i = i + 1
            elseif c == '"' then state = "code" end
        elseif state == "char" then
            out[#out + 1] = c == "\n" and "\n" or " "
            if c == "\\" then out[#out + 1] = n == "\n" and "\n" or " "; i = i + 1
            elseif c == "'" then state = "code" end
        elseif state == "raw" then
            out[#out + 1] = c == "\n" and "\n" or " "
            if c == '"' and source:sub(i + 1, i + raw_hashes) == string.rep("#", raw_hashes) then
                for _ = 1, raw_hashes do out[#out + 1] = " " end
                i = i + raw_hashes; state = "code"
            end
        else
            if c == "/" and n == "/" then out[#out + 1] = "  "; i = i + 1; state = "line"
            elseif c == "/" and n == "*" then out[#out + 1] = "  "; i = i + 1; state = "block"
            elseif c == '"' then out[#out + 1] = " "; state = "string"
            -- A Rust lifetime (`'static`) is code, not a character literal.
            elseif c == "'" and not n:match("[A-Za-z_]") then out[#out + 1] = " "; state = "char"
            elseif c == "r" and (n == '"' or n == "#") then
                local j = i + 1
                while source:sub(j, j) == "#" do j = j + 1 end
                if source:sub(j, j) == '"' then
                    raw_hashes = j - i - 1; out[#out + 1] = string.rep(" ", j - i + 1); i = j; state = "raw"
                else out[#out + 1] = c end
            else
                out[#out + 1] = c
            end
        end
        i = i + 1
    end
    return table.concat(out)
end
local code = mask_rust(source)
local function code_body(signature)
    local at = code:find(signature, 1, true)
    if not at then return nil end
    local open = code:find("{", at, true)
    if not open then return nil end
    local depth, i = 0, open
    while i <= #code do
        local c = code:sub(i, i)
        if c == "{" then depth = depth + 1
        elseif c == "}" then depth = depth - 1; if depth == 0 then return source:sub(at, i), code:sub(at, i) end end
        i = i + 1
    end
    return nil
end
local violations, checked = 0, 0
checked = checked + 1
if not text.is_match(code, "(?m)^static LIVE_CLIENT[[:space:]]*:") then
    log.raw("  the live client is no longer a static: a per-call client reconnects on every refresh,")
    log.raw("  which is the reconnect-per-tick shape order 147 audits (it looks like a transport fault).")
    violations = violations + 1
end
checked = checked + 1
local _, lcr = code_body("async fn live_client_request")
if not lcr or (not lcr:find("live_client_mutex()", 1, true) and not lcr:find("LIVE_CLIENT", 1, true)) then
    log.raw("  live_client_request no longer reaches the persistent client (neither")
    log.raw("  live_client_mutex() nor LIVE_CLIENT appears in its body): the fast path")
    log.raw("  is building a connection per call.")
    violations = violations + 1
end
checked = checked + 1
local _, acc = code_body("fn live_client_mutex")
if not acc then
    log.raw("  live_client_mutex() is gone; the accessor arm above cannot mean anything.")
    violations = violations + 1
elseif not acc:find("LIVE_CLIENT", 1, true) then
    log.raw("  live_client_mutex() no longer returns the LIVE_CLIENT static — the accessor")
    log.raw("  is there but it is not backed by a persistent client.")
    violations = violations + 1
end
for _, fn in ipairs({ "async fn refresh_vm_status", "async fn refresh_github_login" }) do
    checked = checked + 1
    local original, body = code_body(fn)
    if not body then
        log.raw("  " .. fn .. " not found in " .. src .. " — the guard cannot see the function it pins.")
        violations = violations + 1
    else
        local bad, n = {}, 0
        local original_lines = text.lines(original)
        for line_no, line in ipairs(text.lines(body)) do
            if text.is_match(line, "\\b(loop|while)\\b|sleep\\(") then
                n = n + 1; if n <= 3 then bad[#bad + 1] = line_no .. ":" .. original_lines[line_no] end
            end
        end
        if n > 0 then
            log.raw("  " .. fn .. " contains a loop or a sleep; it must be single-shot (order 147):")
            for _, line in ipairs(bad) do log.raw("    " .. line) end
            violations = violations + 1
        end
    end
end
if violations > 0 then verdict.emit("violation:tray-refresh-polling:" .. violations, 1) end
verdict.emit("ok:tray-refresh-no-polling:" .. checked .. " checked", 0)
