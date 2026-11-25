-- @trace spec:subdomain-routing-via-reverse-proxy, order:2380-psba
-- @env PATH HOME
--
-- test-subdomain-routing.lua — contract pin on images/proxy/squid.conf: Squid forwards
-- .localhost requests to the router via cache_peer (enclave-internal routing for browser
-- isolation) and never resolves them through public DNS. Ported from
-- test-subdomain-routing.sh (2380-psba); same eight arms. Each arm is a line-anchored
-- regex (grep -E) or a literal (grep -F) over the config.
--
--   1  acl localhost_subdomain dstdomain .localhost
--   2  http_access allow localhost_subdomain
--   3  cache_peer named tillandsias-router
--   4  cache_peer uses the router network alias on port 8080
--   5  cache_peer_access allows only localhost_subdomain
--   6  cache_peer_access denies all other traffic
--   7  never_direct allow localhost_subdomain (no public DNS for .localhost)
--   8  the @trace spec:subdomain-routing-via-reverse-proxy annotation is in the config
--
-- GRAMMAR ok:subdomain-routing:<n> arms | violation:subdomain-routing:<n>-failed
--       | refused:subdomain-routing:no-squid-conf

local fixture = require "common.fixture"
local T = fixture.new("subdomain-routing")
local CONF = "images/proxy/squid.conf"
if not fs.exists(CONF) then T:refuse("no-squid-conf", "Squid config not found at " .. CONF) end
local C = fs.read(CONF)

local function rx(name, pat)   -- grep -qE, line-anchored
    T:arm(name, text.is_match(C, "(?m)" .. pat), "pattern not found: " .. pat)
end
local function lit(name, s)     -- grep -qF
    T:arm(name, text.contains(C, s), "pattern not found: " .. s)
end

rx("1 ACL localhost_subdomain defines .localhost dstdomain rule", [[^acl localhost_subdomain dstdomain \.localhost$]])
rx("2 http_access allows localhost_subdomain traffic", [[^http_access allow localhost_subdomain$]])
lit("3 cache_peer routes to tillandsias-router", "name=tillandsias-router")
rx("4 cache_peer uses router network alias on port 8080", [[^cache_peer router parent 8080]])
rx("5 cache_peer_access allows only localhost_subdomain traffic", [[^cache_peer_access tillandsias-router allow localhost_subdomain$]])
rx("6 cache_peer_access denies all other traffic", [[^cache_peer_access tillandsias-router deny all$]])
rx("7 never_direct prevents public DNS for .localhost", [[^never_direct allow localhost_subdomain$]])
lit("8 @trace spec:subdomain-routing-via-reverse-proxy appears in config", "spec:subdomain-routing-via-reverse-proxy")

T:finish()
