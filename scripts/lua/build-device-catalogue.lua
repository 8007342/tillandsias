-- @trace order:1643-q3at
--
-- build-device-catalogue.lua — merge the vendored device sources into ONE
-- committed catalogue, crates/tillandsias-core/data/devices/catalogue.json,
-- which the `devices` resolver embeds.
--
-- Inputs (crates/tillandsias-core/data/devices/):
--   upstream/playwright-deviceDescriptorsSource.json  base (Apache-2.0)
--   upstream/devtools-EmulatedDevices.ts              merged in (BSD-3-Clause):
--                                                     safe areas, UA client
--                                                     hints, devices Playwright
--                                                     lacks (laptops, Surface…)
--   overlay.yaml                                      hand-written, from
--                                                     manufacturer spec pages
--   released.yaml                                     launch months, flagship
--                                                     lines, extra aliases
--
-- Semantics. For a mobile device viewport is the PORTRAIT CSS screen
-- (device-mode emulation: the page owns the whole screen); Playwright's smaller
-- viewport, which subtracts the mobile browser's own UI, is kept as
-- browser_viewport. For a desktop the viewport is the browser window
-- (Playwright's viewport) and screen is the display. A landscape view is
-- the resolver's job (it swaps w/h), so landscape source entries are skipped.
--
-- The output is canonical (sorted keys, one device per line) and written by
-- this script's own encoder, not json.encode, so a re-run is byte-identical:
--   tillandsias-plan script run scripts/lua/build-device-catalogue.lua            (write)
--   tillandsias-plan script run scripts/lua/build-device-catalogue.lua -- --check (verify)
--   … -- --check --against <file>   verify another copy (the litmus negative control)
-- Verdicts: ok:device-catalogue:written:<n> | ok:device-catalogue:fresh:<n> |
--           violation:device-catalogue:stale (exit 1) | refused:device-catalogue:<why> (exit 1)

local DIR = "crates/tillandsias-core/data/devices"
local OUT = DIR .. "/catalogue.json"
local check, against = false, nil
for i = 1, #arg do
    if arg[i] == "--check" then check = true end
    if arg[i] == "--against" then against = arg[i + 1] end
end

local function read(p)
    local ok, s = pcall(fs.read, p)
    if not ok or not s then verdict.emit("refused:device-catalogue:unreadable:" .. p, 1) end
    return s
end

-- ── canonical JSON ─────────────────────────────────────────────────────────
local function is_array(t)
    if getmetatable(t) == json.array({}) then return true end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return false end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end
local function enc_str(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\t" then return "\\t"
        else return string.format("\\u%04x", c:byte()) end
    end)
    return '"' .. s .. '"'
end
local function enc_num(x)
    if math.type(x) == "integer" then return tostring(x) end
    if x == math.floor(x) and math.abs(x) < 1e15 then return string.format("%d", x) end
    local s = string.format("%.10g", x)
    return s
end
local function enc(v)
    local t = type(v)
    if t == "string" then return enc_str(v)
    elseif t == "number" then return enc_num(v)
    elseif t == "boolean" then return tostring(v)
    elseif v == nil or v == json.null then return "null"
    elseif t == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do parts[i] = enc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = enc_str(k) .. ":" .. enc(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

-- ── the DevTools TypeScript literal → JSON ─────────────────────────────────
-- emulatedDevices is a plain literal: single-quoted strings, // and /* */
-- comments, trailing commas. Strings are re-quoted, comments dropped, and a
-- comma before ] or } removed. Anything else in the literal is a refusal.
local function ts_to_json(src)
    -- DevTools marks a few values as i18n calls with a plain-literal fallback:
    -- /* DEVICE-LIST-IF-JS */ <js> /* DEVICE-LIST-ELSE <plain> DEVICE-LIST-END-IF */
    -- keep the plain branch.
    src = src:gsub("/%* DEVICE%-LIST%-IF%-JS %*/.-/%* DEVICE%-LIST%-ELSE(.-)DEVICE%-LIST%-END%-IF %*/", "%1")
    local out, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        local two = src:sub(i, i + 1)
        if two == "//" then
            local j = src:find("\n", i, true) or n
            i = j
        elseif two == "/*" then
            local _, j = src:find("*/", i + 2, true)
            i = (j or n) + 1
        elseif c == "'" or c == '"' then
            local q, j, buf = c, i + 1, {}
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then
                    local e = src:sub(j + 1, j + 1)
                    if e == "'" then buf[#buf + 1] = "'" else buf[#buf + 1] = "\\" .. e end
                    j = j + 2
                elseif d == q then break
                else
                    if d == '"' then buf[#buf + 1] = '\\"' else buf[#buf + 1] = d end
                    j = j + 1
                end
            end
            out[#out + 1] = '"' .. table.concat(buf) .. '"'
            i = j + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    local s = table.concat(out)
    s = s:gsub(",(%s*[%]}])", "%1")
    return s
end

-- ── naming ─────────────────────────────────────────────────────────────────
local function slug(s)
    s = s:lower():gsub("%+", "-plus"):gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    return s
end
-- brand/family from the display name; the order matters (first match wins).
local NAMING = {
    { "^Samsung Galaxy ", "samsung", "galaxy", "Galaxy " },
    { "^Galaxy ", "samsung", "galaxy", nil },
    { "^iPhone", "apple", "iphone", nil },
    { "^iPad", "apple", "ipad", nil },
    { "^Pixel", "google", "pixel", nil },
    { "^Nexus", "google", "nexus", nil },
    { "^Nest Hub", "google", "nest", nil },
    { "^Moto ", "motorola", "moto", nil },
    { "^Nokia Lumia", "nokia", "lumia", nil },
    { "^Nokia ", "nokia", "nokia", nil },
    { "^Microsoft Lumia", "microsoft", "lumia", nil },
    { "^Surface", "microsoft", "surface", nil },
    { "^Blackberry", "blackberry", "blackberry", "BlackBerry" },
    { "^BlackBerry", "blackberry", "blackberry", nil },
    { "^Kindle", "amazon", "kindle", nil },
    { "^LG ", "lg", "optimus", nil },
    { "^JioPhone", "jio", "jiophone", nil },
    { "^Asus ", "asus", "zenbook", nil },
    { "^Laptop", "generic", "laptop", nil },
    { "^Desktop", "desktop", "desktop", nil },
}
local function naming(title)
    for _, r in ipairs(NAMING) do
        if title:find(r[1]) then
            local model = title
            if r[4] then model = title:gsub(r[1], r[4]) end
            return r[2], r[3], model
        end
    end
    return nil
end
local SKIP = { ["Facebook on Android"] = true }
-- id: brand-model, unless the model already names the brand (Desktop Chrome)
-- or the brand is a placeholder (generic laptops).
local function make_id(brand, model)
    local m = slug(model)
    if brand == "generic" or m:sub(1, #brand + 1) == brand .. "-" then return m end
    return slug(brand .. " " .. model)
end

local function os_of(ua, family)
    ua = ua or ""
    local v = ua:match("iPhone OS (%d+[_%d]*)") or ua:match("CPU OS (%d+[_%d]*)")
    if v then return { name = (family == "ipad") and "ipados" or "ios", version = (v:gsub("_", ".")) } end
    v = ua:match("Android (%d+[%.%d]*)")
    if v then return { name = "android", version = v } end
    if ua:find("Windows Phone") then return { name = "windows-phone", version = ua:match("Windows Phone (%d+[%.%d]*)") or "" } end
    if ua:find("Windows NT") then return { name = "windows", version = ua:match("Windows NT (%d+[%.%d]*)") or "" } end
    if ua:find("Mac OS X") then return { name = "macos", version = ((ua:match("Mac OS X (%d+[_%.%d]*)") or ""):gsub("_", ".")) } end
    if ua:find("CrOS") then return { name = "chromeos", version = "" } end
    if ua:find("Linux") then return { name = "linux", version = "" } end
    if ua:find("BlackBerry") or ua:find("BB10") or ua:find("PlayBook") then return { name = "blackberry", version = "" } end
    return { name = "unknown", version = "" }
end
local ENGINE = { webkit = "webkit", chromium = "blink", firefox = "gecko" }
local function engine_of(pw_type, ua)
    if pw_type then return ENGINE[pw_type] or pw_type end
    if (ua or ""):find("Firefox/") then return "gecko" end
    if (ua or ""):find("Chrome/") then return "blink" end
    return "webkit"
end
local function form_of(title, family, mobile, devtools_type)
    local t = title:lower()
    if family == "desktop" then return "desktop" end
    if t:find("fold") and not t:find("cover") then return "foldable" end
    if devtools_type == "laptop" or devtools_type == "notebook" or family == "laptop" then return "laptop" end
    if devtools_type == "tablet" or family == "ipad" or t:find("tab ") or t:find("playbook")
        or t:find("kindle") or t:find("nexus 7") or t:find("nexus 10") or family == "surface" then
        if t:find("duo") then return "foldable" end
        return "tablet"
    end
    if devtools_type == "desktop" then return "desktop" end
    return mobile and "phone" or "desktop"
end

-- ── sources ────────────────────────────────────────────────────────────────
local pw = json.parse(read(DIR .. "/upstream/playwright-deviceDescriptorsSource.json"))
local ts = read(DIR .. "/upstream/devtools-EmulatedDevices.ts")
local a = ts:find("const emulatedDevices = [", 1, true)
if not a then verdict.emit("refused:device-catalogue:devtools-literal-not-found", 1) end
local b = ts:find("\n];", a, true)
local ok_dt, dt = pcall(json.parse, ts_to_json(ts:sub(a + #"const emulatedDevices = ", b + 1)))
if not ok_dt then verdict.emit("refused:device-catalogue:devtools-literal-not-json:" .. tostring(dt):sub(1, 200), 1) end
local overlay = yaml.parse(read(DIR .. "/overlay.yaml"))
local rel = yaml.parse(read(DIR .. "/released.yaml"))

local SOURCES = {
    playwright = { kind = "playwright", license = "Apache-2.0",
        url = "https://github.com/microsoft/playwright/blob/606f017a1b51530df6a0f711babcf2c6add21bc5/packages/isomorphic/deviceDescriptorsSource.json" },
    devtools = { kind = "chrome-devtools", license = "BSD-3-Clause",
        url = "https://github.com/ChromeDevTools/devtools-frontend/blob/b0d3487640f473652bb3d4eddd68c6f5d1f1352a/front_end/models/emulation/EmulatedDevices.ts" },
}

local devices, by_id = {}, {}
local function add(d)
    if by_id[d.id] then verdict.emit("refused:device-catalogue:duplicate-id:" .. d.id, 1) end
    by_id[d.id] = d
    devices[#devices + 1] = d
end

-- Playwright: the base.
local pw_names = {}
for name in pairs(pw) do pw_names[#pw_names + 1] = name end
table.sort(pw_names)
for _, name in ipairs(pw_names) do
    local e = pw[name]
    if not name:find(" landscape$") and not SKIP[name] then
        local brand, family, model = naming(name)
        if not brand then verdict.emit("refused:device-catalogue:unnamed-playwright-device:" .. name, 1) end
        local scr = e.screen or e.viewport
        local w, h = scr.width, scr.height
        if w > h and e.isMobile then w, h = h, w end
        -- A mobile page owns the whole screen; a desktop page gets the window.
        local vw, vh = w, h
        if not e.isMobile then vw, vh = e.viewport.width, e.viewport.height end
        add({
            id = make_id(brand, model), brand = brand, family = family, model = model,
            aliases = json.array({ model:lower() }),
            form = form_of(name, family, e.isMobile, nil),
            os = os_of(e.userAgent, family),
            engine = engine_of(e.defaultBrowserType, e.userAgent),
            screen = { w = w, h = h },
            viewport = { w = vw, h = vh },
            browser_viewport = { w = e.viewport.width, h = e.viewport.height },
            dpr = e.deviceScaleFactor,
            ua = e.userAgent,
            mobile = e.isMobile and true or false,
            touch = e.hasTouch and true or false,
            max_touch_points = e.hasTouch and 5 or 0,
            source = { kind = "playwright", url = SOURCES.playwright.url, license = "Apache-2.0" },
        })
    end
end

-- DevTools: enrich a Playwright twin, or add the device.
local function insets(m)
    local s = m and m["safe-area-insets"]
    if not s then return nil end
    return { top = s.top or 0, right = s.right or 0, bottom = s.bottom or 0, left = s.left or 0 }
end
for _, e in ipairs(dt) do
    local title = e.title
    if title and not SKIP[title] then
        local brand, family, model = naming(title)
        if not brand then verdict.emit("refused:device-catalogue:unnamed-devtools-device:" .. title, 1) end
        local id = make_id(brand, model)
        local safe = {}
        for _, m in ipairs(e.modes or {}) do
            if m.orientation == "vertical" and not safe.portrait then safe.portrait = insets(m) end
            if m.orientation == "horizontal" and not safe.landscape then safe.landscape = insets(m) end
        end
        local meta = e["user-agent-metadata"]
        local d = by_id[id]
        if d then
            if not table.is_empty(safe) then d.safe_area = safe end
            if meta then d.ua_metadata = meta end
            d.merged = json.array({ "chrome-devtools" })
        else
            local caps = {}
            for _, cap in ipairs(e.capabilities or {}) do caps[cap] = true end
            -- Phones/tablets are described portrait; a laptop or desktop in its
            -- natural landscape (the vertical mode is only a rotation).
            local v = e.screen.vertical
            if not caps.mobile and (e.type == "laptop" or e.type == "notebook" or e.type == "desktop") then
                v = e.screen.horizontal
            end
            local w, h = v.width, v.height
            add({
                id = id, brand = brand, family = family, model = model,
                aliases = json.array({ model:lower() }),
                form = form_of(title, family, caps.mobile, e.type),
                os = os_of(e["user-agent"], family),
                -- DevTools emulates in Chromium; an empty UA means "Chrome's own".
                engine = ((e["user-agent"] or "") == "") and "blink" or engine_of(nil, e["user-agent"]),
                screen = { w = w, h = h }, viewport = { w = w, h = h },
                dpr = e.screen["device-pixel-ratio"],
                ua = e["user-agent"],
                ua_metadata = meta,
                safe_area = (not table.is_empty(safe)) and safe or nil,
                mobile = caps.mobile and true or false,
                touch = caps.touch and true or false,
                max_touch_points = caps.touch and 5 or 0,
                source = { kind = "chrome-devtools", url = SOURCES.devtools.url, license = "BSD-3-Clause" },
            })
        end
    end
end

-- Overlay: manufacturer spec pages.
for _, o in ipairs(overlay.devices) do
    add({
        id = o.id, brand = o.brand, family = o.family, model = o.model,
        aliases = json.array(o.aliases), form = o.form, os = o.os, engine = o.engine,
        screen = { w = o.viewport.w, h = o.viewport.h }, viewport = { w = o.viewport.w, h = o.viewport.h },
        screen_px = o.screen_px, panel = o.panel,
        dpr = o.dpr, ua = overlay.ua_android_reduced,
        ua_metadata = { platform = "Android", platformVersion = o.os.version, architecture = "", model = "", mobile = true },
        mobile = o.mobile, touch = o.touch, max_touch_points = o.max_touch_points,
        source = { kind = o.source.kind, url = o.source.url, license = o.source.license,
            note = o.source.note, derivation = overlay.derivation },
    })
end

-- Launch months, flagship lines, extra aliases.
for id, r in pairs(rel.released) do
    local d = by_id[id]
    if not d then verdict.emit("refused:device-catalogue:released-names-unknown-id:" .. id, 1) end
    d.released = r.released
    if r.flagship then d.flagship = true end
end
for alias, id in pairs(rel.aliases) do
    local d = by_id[id]
    if not d then verdict.emit("refused:device-catalogue:alias-names-unknown-id:" .. id, 1) end
    local al = d.aliases
    al[#al + 1] = alias
end
for _, d in ipairs(devices) do table.sort(d.aliases) end
table.sort(devices, function(x, y) return x.id < y.id end)

-- ── write ──────────────────────────────────────────────────────────────────
local lines = {
    "{",
    '"generated_by":"scripts/lua/build-device-catalogue.lua (order 1643-q3at)",',
    '"semantics":' .. enc_str("mobile: viewport = portrait CSS screen (device-mode emulation), browser_viewport = Playwright's viewport minus the mobile browser UI; desktop: viewport = the browser window, screen = the display; landscape = the resolver swaps w/h") .. ",",
    '"sources":' .. enc({ SOURCES.playwright, SOURCES.devtools,
        { kind = "manufacturer-spec", license = "manufacturer-published facts; overlay file GPL-3.0-or-later", url = DIR .. "/overlay.yaml" },
        { kind = "released", license = "GPL-3.0-or-later (public launch months)", url = DIR .. "/released.yaml" } }) .. ",",
    '"devices":[',
}
for i, d in ipairs(devices) do
    lines[#lines + 1] = enc(d) .. (i < #devices and "," or "")
end
lines[#lines + 1] = "]"
lines[#lines + 1] = "}"
local text_out = table.concat(lines, "\n") .. "\n"

if check then
    local ok, cur = pcall(fs.read, against or OUT)
    if ok and cur == text_out then verdict.ok("device-catalogue", "fresh", tostring(#devices)) end
    log.raw("  remedy: tillandsias-plan script run scripts/lua/build-device-catalogue.lua, then commit " .. OUT)
    verdict.emit("violation:device-catalogue:stale", 1)
end
fs.write(OUT, text_out)
verdict.ok("device-catalogue", "written", tostring(#devices))
