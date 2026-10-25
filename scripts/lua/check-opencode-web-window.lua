-- @env TILLANDSIAS_OPENCODE_WINDOW_SRC
-- @read-env TILLANDSIAS_OPENCODE_WINDOW_SRC
-- @trace order:1802-9xix, spec:opencode-web-session-otp, spec:browser-isolation-tray-integration
--
-- check-opencode-web-window.lua — 1802-9xix. The tray's OpenCode Web window
-- is an app window on the confined per-window network that browser.open uses,
-- and it signs in over the router's TLS site and lands on the project:
--
--   window   start_app_window makes an --internal network; app_window_spec
--            joins it with the *.<label>.localhost resolver rules and the
--            preview-CA SPKI pin, and never asks for host networking
--   tls      the router writes an https://<sub>.localhost:8443 site with the
--            project's preview leaf in front of the OTP-gated OpenCode route
--   landing  the window URL is https://opencode.<label>.localhost:<tls port>/,
--            the login form carries the project's session landing for
--            /home/forge/src/<project>, and the sidecar follows `next` only
--            through is_safe_landing_path, which refuses //host
--
-- Seam for the fixture: TILLANDSIAS_OPENCODE_WINDOW_SRC is a dir holding
-- main.rs, browser_open.rs, http.rs and otp.rs (default: the crate sources).
--
-- Usage: tillandsias-plan script run scripts/lua/check-opencode-web-window.lua

local seam = env.get("TILLANDSIAS_OPENCODE_WINDOW_SRC")
local paths = {
    main = seam and (seam .. "/main.rs") or "crates/tillandsias-headless/src/main.rs",
    browser = seam and (seam .. "/browser_open.rs") or "crates/tillandsias-headless/src/browser_open.rs",
    http = seam and (seam .. "/http.rs") or "crates/tillandsias-router-sidecar/src/http.rs",
    otp = seam and (seam .. "/otp.rs") or "crates/tillandsias-otp/src/lib.rs",
}
local src = {}
for k, p in pairs(paths) do
    local ok, t = pcall(fs.read, p)
    if not ok then verdict.emit("could-not-run:opencode-web-window:no-source:" .. p, 2) end
    src[k] = t
end

local function body(text, decl)
    local s = text:find(decl, 1, true)
    if not s then return nil end
    local e = text:find("\n}\n", s, true) or text:find("\n    }\n", s, true)
    return text:sub(s, e or #text)
end

local function has(t, needle) return t ~= nil and t:find(needle, 1, true) ~= nil end

local bad = 0
local function need(cond, what)
    if cond then
        out.line("ok: " .. what)
    else
        log.raw("  violation: " .. what)
        bad = bad + 1
    end
end

-- window: the confined network.
local start = body(src.browser, "pub(crate) fn start_app_window(")
local spec = body(src.browser, "pub(crate) fn app_window_spec(")
need(has(start, '"--internal"'), "start_app_window creates the window network --internal")
need(has(spec, ".network(&handle.network_name)"), "app_window_spec joins the window's own network")
need(has(spec, "--host-resolver-rules=") and has(spec, "host_resolver_rules(project_label)"),
    "app_window_spec maps only the project's *.<label>.localhost names")
need(has(spec, "--ignore-certificate-errors-spki-list="), "app_window_spec pins the preview CA SPKI")
need(spec ~= nil and not spec:find('"host"', 1, true) and not spec:find("pasta", 1, true)
    and not spec:find("--network=host", 1, true), "app_window_spec never asks for host networking or pasta")

-- tls: the router site with the preview leaf in front of the OTP gate.
local s = src.main:find('"https://{subdomain}.localhost:8443 {{\\n    \\\n', 1, true)
local site = s and src.main:sub(s, s + 600) or ""
need(has(site, "tls /etc/tillandsias/preview/{preview_project}.crt"), "the router's TLS site serves the project's preview leaf")
need(has(site, "forward_auth localhost:9090") and has(site, "handle /_auth/login"),
    "the TLS site keeps the OTP login and the forward_auth gate")

-- landing: the window signs in over TLS and lands on the project.
need(has(src.main, '"https://opencode.{project_label}.localhost:{}/"'), "the window URL is the router's TLS OpenCode site")
-- The window lands on "/": the forge's sse-keepalive proxy seeds the checkout
-- into the web app's project list and redirects / to its route (its node tests
-- are this litmus's own step), so no forge path is derived from a host name.
need(has(src.main, 'const OPENCODE_WEB_WINDOW_LANDING: &str = "/";'),
    "the landing is the bare root the forge's proxy redirects to the checkout")
need(has(src.main, "OPENCODE_WEB_WINDOW_LANDING,\n        &otp,"), "the login form carries that landing")
local login = src.http:find('parse_form_field(&body, "next")', 1, true)
need(login ~= nil and src.http:sub(login, login + 120):find("is_safe_landing_path", 1, true) ~= nil,
    "the sidecar follows next only through is_safe_landing_path")
local safe = body(src.otp, "pub fn is_safe_landing_path(")
need(has(safe, "starts_with('/')") and has(safe, 'starts_with("//")'),
    "is_safe_landing_path takes a same-origin path and refuses //host")

if bad > 0 then
    log.raw("  remedy: keep the OpenCode Web window on the confined --internal network, its route on the router's TLS site, and its landing behind is_safe_landing_path (1802-9xix)")
    verdict.emit("violation:opencode-web-window:" .. bad, 1)
end
verdict.emit("ok:opencode-web-window", 0)
