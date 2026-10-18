-- @env TILLANDSIAS_LITMUS_DIR
-- @read-env TILLANDSIAS_LITMUS_DIR
-- @trace spec:litmus-framework, spec:methodology-accountability
-- @trace order:972-cvdg, order:1247-ngc5
--
-- check-litmus-steps-can-fail.lua — PORTED from check-litmus-steps-can-fail.sh
-- (the shell-to-lua carried obligation, paid by 1247-ngc5). Refuse a litmus
-- step whose success and failure branches print the SAME token, because such
-- a step passes whether the system works or not.
--
-- THE DEFECT THIS EXISTS FOR, found by the tillandsias.org forge while writing
-- the public explainer and confirmed line by line. Five steps in
-- litmus-podman-idiomatic-security-flags.yaml — a `severity: critical` test of
-- the container hardening envelope — were written as:
--
--     ... | grep -q 'keep-id' && echo 'USERNS_KEEP_ID_SET' || echo 'USERNS_KEEP_ID_SET'
--
-- with `USERNS_KEEP_ID_SET` as the step's `expected_behavior`. The grep decides
-- nothing: both branches emit the token the harness is looking for. The test
-- reported PASS on every run for as long as it existed, and would have reported
-- PASS with the hardening flags removed entirely.
--
-- WHY A GUARD AND NOT A FIX. Fixing those five lines takes a minute; nothing
-- stops the sixth being written tomorrow, and the failure is invisible by
-- construction — a test that cannot fail looks exactly like a test that passes.
-- No run, no log and no verdict distinguishes them, so a reviewer is the only
-- control and reviewers were what missed these.
--
-- THE SHAPE IS NARROW ON PURPOSE. `cmd && echo A || echo B` with DIFFERENT
-- tokens is a legitimate and common idiom — it is how a step reports which of
-- two states it found. Only identical tokens are refused, because only then is
-- the branch a decoration. A guard that flagged the general idiom would be
-- noise, and noise is how a guard stops being run.
--
-- Verdict grammar, one line on stdout, unchanged from the .sh:
--   ok:litmus-steps-can-fail:<n> file(s) checked        exit 0
--   violation:litmus-steps-cannot-fail:<n> step(s)      exit 1
--   blocked:<reason>                                    exit 2
-- TILLANDSIAS_LITMUS_DIR (default openspec/litmus-tests) is the fixture seam;
-- @read-env lets fs.walk/fs.read reach a temp corpus outside the checkout.

local DIR = env.get("TILLANDSIAS_LITMUS_DIR")
if DIR == nil or DIR == "" then DIR = "openspec/litmus-tests" end

local ok_walk, walked = pcall(fs.walk, DIR, { suffix = ".yaml" })
if not ok_walk or type(walked) ~= "table" then
    log.raw("  why: the litmus corpus " .. DIR .. " could not be listed, so no step was judged")
    log.raw("  remedy: run from a checkout that has openspec/litmus-tests, or point TILLANDSIAS_LITMUS_DIR at an existing directory")
    verdict.emit("blocked:litmus-dir-missing:" .. DIR, 2)
end

-- The .sh globbed "$DIR"/*.yaml, so only the corpus's own top level counts.
local files = {}
for _, p in ipairs(walked) do
    local rel = p
    if rel:sub(1, #DIR + 1) == DIR .. "/" then rel = rel:sub(#DIR + 2) end
    if not rel:find("/", 1, true) then files[#files + 1] = rel end
end
table.sort(files)

-- Normalise a branch's payload to the bare token it prints.
--
-- ALL quote and backslash characters are deleted rather than one matching pair
-- stripped, and the fixture is why: inside a YAML double-quoted command the two
-- branches can legitimately be spelled `'SAME'` and `\"SAME\"`, which a
-- pair-stripping version compared as different and let through. A guard that can
-- be evaded by changing a quote style is a guard against typos, not against the
-- defect.
--
-- Only the FIRST word survives, so trailing shell (`; fi`, a closing quote, a
-- redirect) cannot make two identical tokens compare unequal — that direction
-- fails OPEN, which is the one failure this guard must not have.
local function branch_token(s)
    s = s:gsub("[\\\"']", "")
    return s:match("^%s*(%S*)") or ""
end

local function last_find(s, needle)
    local at, from = nil, 1
    while true do
        local i = s:find(needle, from, true)
        if not i then return at end
        at, from = i, i + 1
    end
end

local AND, OR = "&& echo ", "|| echo "
local violations, checked = 0, 0
for _, name in ipairs(files) do
    local path = DIR .. "/" .. name
    checked = checked + 1
    local okr, body = pcall(fs.read, path)
    if okr and type(body) == "string" then
        for lineno, line in ipairs(text.lines(body)) do
            local a = line:find(AND, 1, true)
            -- `*'&& echo '*'|| echo '*`: some `|| echo ` after some `&& echo `.
            if a and line:find(OR, a + #AND, true) then
                -- The LAST `&& echo ... || echo ...` on the line is the one whose
                -- value reaches stdout, and these commands routinely chain several.
                local tail_expr = line:sub(last_find(line, AND) + #AND)
                local o = tail_expr:find(OR, 1, true)
                if o then
                    local ok_branch = branch_token(tail_expr:sub(1, o - 1))
                    local fail_branch = branch_token(tail_expr:sub(o + #OR))
                    if ok_branch ~= "" and ok_branch == fail_branch then
                        log.raw("  " .. path .. ":" .. lineno)
                        log.raw("    both branches print '" .. ok_branch .. "' — this step passes whether")
                        log.raw("    the check succeeded or failed. Give the failure branch a")
                        log.raw("    distinct token, or drop the fallback so the step exits non-zero.")
                        violations = violations + 1
                    end
                end
            end
        end
    end
end

if violations > 0 then
    verdict.emit("violation:litmus-steps-cannot-fail:" .. violations .. " step(s)", 1)
end
verdict.emit("ok:litmus-steps-can-fail:" .. checked .. " file(s) checked", 0)
