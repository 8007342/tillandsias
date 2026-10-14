-- @trace spec:proxy-container, order:245, order:1663-6mns
-- @env TILLANDSIAS_PROXY_CONF TILLANDSIAS_PROXY_CONSUMER_ROOT
--
-- check-proxy-permissive-port-routing.lua — keep images/proxy/squid.conf
-- HONEST about whether anything actually uses the permissive port. (Ported
-- from scripts/check-proxy-permissive-port-routing.sh, the shell-to-lua item
-- 1663-6mns carried; same rule, grammar, knobs and stderr detail.)
--
-- THE DEFECT THIS EXISTS FOR, measured 2026-08-30. squid.conf described :3129
-- flatly as "PERMISSIVE (image builds)", declared `http_port 3129 ssl-bump`,
-- carried an `acl build_port localport 3129`, and entrypoint.sh announced
-- `permissive: :3129` at startup — while the string `3129` appeared NOWHERE in
-- crates/. Image builds egressed directly through `--dns 8.8.8.8`. A reader
-- asking "are image builds proxied?" found four pieces of configuration saying
-- yes and a build path that said no. Order 245 §5 P6 asks for the port to be
-- either wired or deleted.
--
-- WHAT THIS CHECKS — the AGREEMENT, not the decision:
--   * if NO consumer references 3129, squid.conf must say so (the phrase
--     NOT ROUTED), and
--   * if a consumer DOES reference 3129, that caveat must be gone.
-- Either state is legal; being in one and documenting the other is not.
--
-- SCOPE: crates/ only, on purpose. build.sh names 3129 for a DIFFERENT proxy
-- (`_ensure_dev_proxy` runs tillandsias-dev-proxy from squid:6.1 and publishes
-- 3129 on the host for dev tooling). Searching it would answer a different
-- question and report the port as routed when it is not.
--
-- A CONSUMER is Rust that names the port: a published port, a proxy URL, an
-- argument. squid.conf declaring its own listener is not a consumer.
--
-- Verdict grammar, one line on stdout (detail on stderr):
--   ok:proxy-permissive-port:unrouted-and-documented     exit 0
--   ok:proxy-permissive-port:routed:<n> consumer(s)      exit 0
--   violation:proxy-permissive-port:<reason>             exit 1
--   blocked:<reason>                                     exit 2

local CONF = env.get("TILLANDSIAS_PROXY_CONF") or "images/proxy/squid.conf"
local CONSUMER_ROOT = env.get("TILLANDSIAS_PROXY_CONSUMER_ROOT") or "crates"

local ok_conf, conf = pcall(fs.read, CONF)
if not ok_conf or not conf then verdict.emit("blocked:proxy-conf-unreadable:" .. CONF, 2) end
-- fs.walk answers {} for a missing directory, so existence is asked first.
if not fs.exists(CONSUMER_ROOT) then verdict.emit("blocked:consumer-root-missing:" .. CONSUMER_ROOT, 2) end
local ok_walk, files = pcall(fs.walk, CONSUMER_ROOT)
if not ok_walk or type(files) ~= "table" then verdict.emit("blocked:consumer-root-missing:" .. CONSUMER_ROOT, 2) end

local consumers = {}
for _, f in ipairs(files) do
    if f:sub(-3) == ".rs" then
        local ok, body = pcall(fs.read, f)
        if ok and body and body:find("3129", 1, true) then consumers[#consumers + 1] = f end
    end
end
table.sort(consumers)

-- The caveat must be present as a phrase, not merely the word "3129": the
-- config mentions the port many times by construction.
local documented_unrouted = conf:find("NOT ROUTED", 1, true) ~= nil

if #consumers == 0 then
    if documented_unrouted then verdict.emit("ok:proxy-permissive-port:unrouted-and-documented", 0) end
    log.raw("  " .. CONF .. " describes the permissive port without saying it is unrouted,")
    log.raw("  and no .rs under " .. CONSUMER_ROOT .. " references 3129 — so nothing sends")
    log.raw("  traffic to it. Say so in the header (the phrase NOT ROUTED), or wire")
    log.raw("  a build path through it and delete the caveat. Order 245 P6.")
    verdict.emit("violation:proxy-permissive-port:undocumented-unrouted", 1)
end

if documented_unrouted then
    log.raw("  " .. CONF .. " still says the permissive port is NOT ROUTED, but " .. #consumers)
    log.raw("  consumer(s) now reference 3129:")
    for _, c in ipairs(consumers) do log.raw("    " .. c) end
    log.raw("  P6 has been acted on — remove the NOT ROUTED caveat in the same")
    log.raw("  commit that wired it, or the config understates what it does.")
    verdict.emit("violation:proxy-permissive-port:stale-unrouted-caveat", 1)
end

verdict.emit("ok:proxy-permissive-port:routed:" .. #consumers .. " consumer(s)", 0)
