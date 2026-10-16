-- @trace order:1713-3v3f, order:1702-bpnx
-- @env TILLANDSIAS_HOST_BROWSER_SCAN_ROOTS
--
-- check-no-host-browser-launch.lua — Tillandsias never launches or drives a
-- host browser. Refuse any call in crates/ that can hand a URL to the host's
-- browser, except the sites listed in ALLOW below, each at its exact count.
--
-- WHY (operator, 2026-10-14 and 2026-10-16): the early ShellExecute and
-- native-browser calls were a proof of concept, and "no native browser
-- anywhere". Windows open in the dev browser (host-browser browser.open, a
-- container the agent can drive). The ONE hand-off to the user's real browser
-- is the dev app's link toast (1702-bpnx): "This link wants to open <url>",
-- with a choice of dev browser or host browser, run only on the user's click.
-- When that toast lands, its call site is added to ALLOW as the single
-- `handoff` entry. Cloudflare sign-in is QR first, with the device-login URL
-- printed for the user to click; the CLI opens nothing itself.
--
-- A LAUNCH SITE is one line, after `//` comments are stripped (a `//` inside a
-- string literal, such as https://, is kept), that names a browser launcher:
-- ShellExecute, open::that / open::with, webbrowser::, NSWorkspace openURL,
-- url.dll / rundll32, or a launcher program as a string literal: always for
-- "xdg-open", "/usr/bin/open", "explorer.exe", "sensible-browser" and
-- "x-www-browser"; for the generic words "open", "explorer", "gio" and "start"
-- only in launcher context (see in_context). Test code is not shipped, so it
-- is skipped: files under a tests/ directory, and everything from a file's
-- first #[cfg(test)] line on.
--
-- Population: crates/**/*.rs. TILLANDSIAS_HOST_BROWSER_SCAN_ROOTS is a test
-- seam: space-separated repo-relative directories that replace crates/, with
-- ALLOW paths read relative to the same root.
--
-- Verdicts:
--   ok:no-host-browser-launch:files=<n>:sites=<n>:allowed=<n>              exit 0
--   violation:no-host-browser-launch:unlisted=<n>:count-mismatch=<n>       exit 1
--   could-not-run:no-host-browser-launch:<why>                             exit 3

local function words(s) local t = {}; for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end; return t end
local seam = env.get("TILLANDSIAS_HOST_BROWSER_SCAN_ROOTS") or ""
local ROOTS = seam ~= "" and words(seam) or { "crates" }

-- Launcher-shaped sites that do NOT open a URL. Each is pinned by file,
-- pattern and exact count: a second site in the same file is refused too.
-- `rel` is relative to the scan root, so a fixture root can reuse the table.
local ALLOW = {
    { rel = "tillandsias-windows-tray/src/notify_icon.rs", pat = '"explorer.exe"', n = 1,
      why = "Open log: explorer.exe /select,<tray log path>, a file path, never a URL" },
    { rel = "tillandsias-macos-tray/src/action_host.rs", pat = '"/usr/bin/open"', n = 1,
      why = "Open log: open <tray log file or its folder>, a file path, never a URL" },
    { rel = "tillandsias-macos-tray/src/terminal_attach.rs", pat = '"/usr/bin/open"', n = 1,
      why = "open -a Warp, the terminal app chosen for attach, never a URL" },
}

local PATTERNS = {
    { pat = "ShellExecute", plain = true },
    { pat = "open::that", plain = true },
    { pat = "open::with", plain = true },
    { pat = "webbrowser::", plain = true },
    { pat = "openURL", plain = true },
    { pat = "url.dll", plain = true },
    { pat = "rundll32", plain = true },
    { pat = '"xdg-open"', plain = true },
    { pat = '"open"', plain = true, ctx = "program" },
    { pat = '"/usr/bin/open"', plain = true },
    { pat = '"explorer.exe"', plain = true },
    { pat = '"explorer"', plain = true, ctx = "program" },
    { pat = '"start"', plain = true, ctx = "shell" },
    { pat = '"sensible-browser"', plain = true },
    { pat = '"x-www-browser"', plain = true },
    { pat = '"gio"', plain = true, ctx = "program" },
}

-- A generic word ("open", "start", ...) is a launch site only in launcher
-- context: "program" = the line spawns it (Command::new) or is nothing but the
-- literal (a program name chosen into a variable, as an if/else arm);
-- "shell" = the line also names cmd or /c (cmd /c start <url>).
local function in_context(ctx, line, pat)
    if not ctx then return true end
    local t = text.trim(line):gsub(",$", "")
    if line:find("Command::new(" .. pat, 1, true) then return true end
    if ctx == "program" then return t == pat end
    if ctx == "shell" then return line:find('"cmd', 1, true) ~= nil or line:find('"/c"', 1, true) ~= nil end
    return false
end

-- Strip a `//` comment that is not inside a string literal.
local function strip_comment(line)
    local in_str, esc = false, false
    for i = 1, #line do
        local c = line:sub(i, i)
        if esc then esc = false
        elseif c == "\\" and in_str then esc = true
        elseif c == '"' then in_str = not in_str
        elseif not in_str and c == "/" and line:sub(i + 1, i + 1) == "/" then
            return line:sub(1, i - 1)
        end
    end
    return line
end

local files = {}
for _, root in ipairs(ROOTS) do
    local ok, list = pcall(fs.walk, root, { suffix = ".rs" })
    if ok and list then
        for _, f in ipairs(list) do
            local norm = f:gsub("\\", "/")
            if not norm:find("/tests/", 1, true) then files[#files + 1] = { path = norm, root = root:gsub("\\", "/") } end
        end
    end
end
if #files == 0 then
    verdict.could_not_run("no-host-browser-launch", "no .rs files under " .. table.concat(ROOTS, " "))
end

-- sites[rel][pat] = { "path:line: text", ... }
local sites, total = {}, 0
for _, f in ipairs(files) do
    local ok, src = pcall(fs.read, f.path)
    if ok and src then
        local rel = f.path:sub(#f.root + 2)
        for i, raw in ipairs(text.lines(src)) do
            if raw:find("#[cfg(test)]", 1, true) then break end
            local line = strip_comment(raw)
            for _, p in ipairs(PATTERNS) do
                if line:find(p.pat, 1, p.plain) and in_context(p.ctx, line, p.pat) then
                    sites[rel] = sites[rel] or {}
                    sites[rel][p.pat] = sites[rel][p.pat] or {}
                    table.insert(sites[rel][p.pat], f.path .. ":" .. i .. ": " .. text.trim(raw))
                    total = total + 1
                end
            end
        end
    end
end

local allowed_n, unlisted, mismatch = 0, {}, {}
local allow_index = {}
for _, a in ipairs(ALLOW) do allow_index[a.rel .. "\0" .. a.pat] = a end
for rel, by_pat in pairs(sites) do
    for pat, hits in pairs(by_pat) do
        local a = allow_index[rel .. "\0" .. pat]
        if not a then
            for _, h in ipairs(hits) do unlisted[#unlisted + 1] = h end
        elseif #hits ~= a.n then
            mismatch[#mismatch + 1] = { a = a, hits = hits }
        else
            allowed_n = allowed_n + #hits
        end
    end
end
-- An ALLOW entry whose site is gone is a mismatch too: the list must stay true.
for _, a in ipairs(ALLOW) do
    local hits = sites[a.rel] and sites[a.rel][a.pat]
    if not hits and seam == "" then mismatch[#mismatch + 1] = { a = a, hits = {} } end
end

if #unlisted == 0 and #mismatch == 0 then
    verdict.emit("ok:no-host-browser-launch:files=" .. #files .. ":sites=" .. total .. ":allowed=" .. allowed_n, 0)
end
table.sort(unlisted)
for _, h in ipairs(unlisted) do out.line("unlisted: " .. h) end
for _, m in ipairs(mismatch) do
    out.line("count-mismatch: " .. m.a.rel .. " " .. m.a.pat .. " expected " .. m.a.n .. " got " .. #m.hits
        .. " (" .. m.a.why .. ")")
    for _, h in ipairs(m.hits) do out.line("  at: " .. h) end
end
out.line("why: Tillandsias never launches or drives a host browser (1713-3v3f); windows open in the dev"
    .. " browser through host-browser browser.open, and the only hand-off to the real browser is the"
    .. " dev app's link toast on a user click (1702-bpnx)")
out.line("remedy: remove the launch (print the URL for the user, or use browser.open), or, if it opens"
    .. " a file or an app and never a URL, add it to ALLOW in scripts/lua/check-no-host-browser-launch.lua"
    .. " with its exact count and the reason")
verdict.emit("violation:no-host-browser-launch:unlisted=" .. #unlisted .. ":count-mismatch=" .. #mismatch, 1)
