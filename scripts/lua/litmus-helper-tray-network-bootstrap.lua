-- @env PATH HOME CARGO_HOME RUSTUP_HOME CARGO_TARGET_DIR
-- @trace spec:tray-network-bootstrap
--
-- litmus-helper-tray-network-bootstrap.lua — PORTED from
-- litmus-helper-tray-network-bootstrap.sh (2111-y8ch, lenovinha shell slice).
-- Source-shape probes over the spawn paths in crates/tillandsias-headless and
-- the podman client, plus one behavioural arm (the CDI classifier tests).
--
-- Grammar (stdout), unchanged for the litmus steps:
--   ok: <what>                          exit 0
--   FAIL: <what>                        exit 1
--   Usage: ...                          exit 2
--
-- Usage: tillandsias-plan script run scripts/lua/litmus-helper-tray-network-bootstrap.lua -- <mode>

local MAIN = "crates/tillandsias-headless/src/main.rs"
local CLIENT = "crates/tillandsias-podman/src/client.rs"

local function lines_of(path)
    local body = fs.read(path)
    if not body then
        out.line("FAIL: cannot read " .. path)
        verdict.emit("could-not-run:tray-network-bootstrap:read", 1)
    end
    return text.lines(body)
end

local function s(v) return v and tostring(v) or "" end
local function starts(l, p) return l:sub(1, #p) == p end
local function has(l, needle) return l:find(needle, 1, true) ~= nil end
local function ok(msg) out.line("ok: " .. msg); verdict.emit("ok:tray-network-bootstrap", 0) end
local function fail(msg) out.line("FAIL: " .. msg); verdict.emit("violation:tray-network-bootstrap", 1) end

-- awk: /^fn <name>/{in_fn=1} in_fn&&/ensure_router_running/{er=NR; in_fn=2}
--      in_fn==2&&/run_container_observed/{rc=NR; exit} /^fn /&&in_fn&&!/<name>/{exit}
local function router_before_container(name)
    local in_fn, er, rc = 0, nil, nil
    for nr, l in ipairs(lines_of(MAIN)) do
        if l:sub(1, #("fn " .. name)) == "fn " .. name then in_fn = 1 end
        if in_fn ~= 0 and has(l, "ensure_router_running") then er = nr; in_fn = 2 end
        if in_fn == 2 and has(l, "run_container_observed") then rc = nr; break end
        if l:sub(1, 3) == "fn " and in_fn ~= 0 and not has(l, name) then break end
    end
    return er, rc
end

local function is_fn_start(l, want)
    for _, p in ipairs({ "fn ", "pub fn ", "pub(crate) fn " }) do
        if want then
            if l:sub(1, #(p .. want .. "(")) == p .. want .. "(" then return true end
        elseif l:sub(1, #p) == p then
            return true
        end
    end
    return false
end

-- awk: /<start>/{in_fn=1} in_fn&&/<needle>/{found=1; exit} <close>&&in_fn{exit}
local function called_within(path, start, needle, close)
    local in_fn = false
    for _, l in ipairs(lines_of(path)) do
        if has(l, start) then in_fn = true end
        if in_fn and has(l, needle) then return true end
        if l == close and in_fn then return false end
    end
    return false
end

local mode = arg[1] or "help"

if mode == "check-run_opencode_mode-ordering" then
    local er, rc = router_before_container("run_opencode_mode")
    if er and rc and er < rc then
        ok("ensure_router_running@" .. er .. " before run_container_observed@" .. rc)
    end
    fail("ensure_router_running missing or after run_container_observed (er=" .. s(er) .. " rc=" .. s(rc) .. ")")

elseif mode == "check-run_observatorium_mode-ordering" then
    local er, rc = router_before_container("run_observatorium_mode")
    if er and rc and er < rc then
        ok("observatorium ensure_router_running@" .. er .. " before run_container_observed@" .. rc)
    end
    fail("observatorium router-ordering wrong (er=" .. s(er) .. " rc=" .. s(rc) .. ")")

elseif mode == "check-ensure_enclave_for_project-ordering" then
    -- The first container this function causes is in the mirror helper it calls.
    -- Assert each link: nothing launches inside the function before the router,
    -- the router precedes the helper, and the helper really launches a container.
    local f, h = false, false
    local er, early, gi, rc
    for nr, l in ipairs(lines_of(MAIN)) do
        if starts(l, "pub(crate) fn ensure_enclave_for_project(") then f = true end
        if f and has(l, "ensure_router_running(") and not er then er = nr end
        if f and has(l, "run_container_observed") and not er then early = nr end
        if f and has(l, "ensure_shared_git_and_inference_for_launch(") and not gi then gi = nr end
        if f and l == "}" then f = false end
        if starts(l, "async fn ensure_shared_git_and_inference_for_launch(") then h = true end
        if h and has(l, "run_container_observed") and not rc then rc = nr end
        if h and l == "}" then h = false end
    end
    if er and gi and rc and not early and er < gi then
        ok("ensure_enclave_for_project router@" .. er .. " before container@" .. rc)
    end
    fail("ensure_enclave_for_project router-ordering wrong (er=" .. s(er) .. " gi=" .. s(gi)
        .. " rc=" .. s(rc) .. " early=" .. s(early) .. ")")

elseif mode == "check-ensure_enclave_network-present" then
    local src = lines_of(MAIN)
    for _, want in ipairs({ "run_opencode_mode", "run_observatorium_mode", "ensure_enclave_for_project" }) do
        local in_fn, found = false, false
        for _, l in ipairs(src) do
            local starts_want = is_fn_start(l, want)
            if starts_want then in_fn = true end
            if in_fn and has(l, "ensure_enclave_network") then found = true; break end
            if is_fn_start(l) and in_fn and not starts_want then break end
        end
        if not found then fail(want .. " missing ensure_enclave_network") end
        out.line("ok: " .. want .. " ensure_enclave_network present")
    end
    verdict.emit("ok:tray-network-bootstrap", 0)

elseif mode == "check-format_observed_launch_failure-classifier" then
    if called_within(CLIENT, "async fn format_observed_launch_failure", "classify_typed_launch_failure", "}") then
        ok("classify_typed_launch_failure threaded into format_observed_launch_failure")
    end
    fail("classify_typed_launch_failure missing from format_observed_launch_failure body")

elseif mode == "check-cdi-classification-arms" then
    -- ORDER 665-zddn. BEHAVIOURAL: run the real classifier against the real
    -- measured stderr. THE COUNT IS THE POINT: `cargo test -- <filter>` exits 0
    -- when the filter matches nothing, so assert how many ran.
    local r = proc.run{
        argv = { "cargo", "test", "-q", "-p", "tillandsias-podman", "--lib", "--",
            "a_stale_nvidia_cdi_spec_is_classified_at_the_oci_runtime_exit_status",
            "an_unresolvable_cdi_device_names_both_causes_of_the_identical_message",
            "the_stale_driver_version_parser_refuses_rather_than_guesses",
            "an_unrecognized_oci_runtime_failure_still_falls_through" },
        env = { PATH = env.get("PATH") or "", HOME = env.get("HOME") or "",
            CARGO_HOME = env.get("CARGO_HOME"), RUSTUP_HOME = env.get("RUSTUP_HOME"),
            CARGO_TARGET_DIR = env.get("CARGO_TARGET_DIR") },
    }
    local all = (r.stdout or "") .. (r.stderr or "")
    local ls = text.lines(all)
    local function tail20()
        for i = math.max(1, #ls - 19), #ls do out.line(ls[i]) end
    end
    if not (r.status == "exited" and r.code == 0) then
        out.line("FAIL: CDI classification arms did not pass"); tail20()
        verdict.emit("violation:tray-network-bootstrap", 1)
    end
    local ran
    for _, l in ipairs(ls) do
        ran = l:match("^test result: ok%. (%d+) passed")
        if ran then break end
    end
    if not ran then
        out.line("FAIL: could not read a test-result count"); tail20()
        verdict.emit("violation:tray-network-bootstrap", 1)
    end
    if tonumber(ran) ~= 4 then
        fail("expected 4 CDI classification arms, " .. ran .. " ran (renamed or deleted?)")
    end
    ok("cdi-classification-arms:4 passed")

elseif mode == "check-launch-breadcrumb-wired" then
    -- ORDER 665-zddn EC4: the breadcrumb helper is only worth anything if the
    -- failure path CALLS it.
    if called_within(CLIENT, "async fn format_observed_launch_failure", "write_launch_breadcrumb(", "    }") then
        ok("write_launch_breadcrumb called from format_observed_launch_failure")
    end
    fail("the launch breadcrumb has no caller in format_observed_launch_failure")

else
    out.line("Usage: litmus-helper-tray-network-bootstrap.lua -- {check-run_opencode_mode-ordering|"
        .. "check-run_observatorium_mode-ordering|check-ensure_enclave_for_project-ordering|"
        .. "check-ensure_enclave_network-present|check-format_observed_launch_failure-classifier|"
        .. "check-cdi-classification-arms|check-launch-breadcrumb-wired}")
    verdict.emit("could-not-run:tray-network-bootstrap:usage", 2)
end
