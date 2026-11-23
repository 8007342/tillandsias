-- @trace spec:tray-ux, order:792-77bt, order:628-c7qd, order:2094-ay52
--
-- check-tray-string-corpus-drift.lua — tray string corpus drift report.
-- (Ported from scripts/check-tray-string-corpus-drift.sh: the shell-to-lua item
-- order 2094-ay52 carried. History: `git log -- scripts/check-tray-string-corpus-drift.sh`.)
--
-- THE QUESTION: 628-c7qd wants a BYTE-IDENTICAL refactor resolving every tray
-- string from locales/en.toml, possible only if en.toml already holds what the
-- trays render. This measures by how much it does not, so the direction is
-- decided by a reproducible number.
--
-- WHAT IT MEASURES: for each simple quoted en.toml value, does the QUOTED
-- literal "<value>" appear in the PRODUCTION text of the tray sources
-- (`//` line comments dropped, each file truncated at its first column-0
-- `#[cfg(test)]`)? Rust escapes are not decoded, so `rendered` is a lower bound
-- and `unmatched` an upper bound. The inverse direction (shipped literals with
-- no key) is deliberately NOT measured: no regex classifies user-visible text
-- honestly.
--
-- A REPORT: exits 0 whatever the ratio (the pinned assertion lives in
-- tillandsias-host-shell's tests). An unreadable en.toml or no tray sources is
-- could-not-run, exit 3 (the .sh printed a bare message and exited 2).
--
-- Grammar (one line on stdout; with --list the unmatched entries precede it):
--   ok:tray-string-drift:en_keys=<N> rendered=<N> unmatched=<N> rendered_pct=<N>   exit 0
-- (the .sh's line had no ok: prefix; the runtime's grammar requires one)
--   could-not-run:tray-string-drift (reason on stderr)                            exit 3

local LIST = false
for _, a in ipairs(arg or {}) do
    if a == "--list" then LIST = true end
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("tray-string-drift", "not-a-git-work-tree")
end

local EN = ROOT .. "/locales/en.toml"
local ok_en, en_body = pcall(fs.read, EN)
if not ok_en or not en_body then verdict.could_not_run("tray-string-drift", "cannot-read-locales-en-toml") end

local DIRS = {
    "crates/tillandsias-macos-tray/src",
    "crates/tillandsias-windows-tray/src",
    "crates/tillandsias-host-shell/src",
    "crates/tillandsias-headless/src/tray",
}
local sources = {}
for _, d in ipairs(DIRS) do
    local ok, found = pcall(fs.walk, ROOT .. "/" .. d, { suffix = ".rs" })
    if ok and found then
        for _, f in ipairs(found) do sources[#sources + 1] = f end
    end
end
if #sources == 0 then verdict.could_not_run("tray-string-drift", "no-tray-sources-found") end
table.sort(sources)

-- One haystack, one pass.
local parts = {}
for _, f in ipairs(sources) do
    local body = fs.read(f) or ""
    for _, line in ipairs(text.lines(body)) do
        if line:sub(1, 11) == "#[cfg(test)" and line:match("^#%[cfg%(test%)%]") then break end
        if line:match("^%s*//") then line = "" end
        parts[#parts + 1] = line
    end
end
local corpus = table.concat(parts, "\n")

local total, rendered, unmatched_list = 0, 0, {}
for _, line in ipairs(text.lines(en_body)) do
    local first = line:sub(1, 1)
    if line ~= "" and first ~= "#" and first ~= "[" then
        local s, e = line:find(" = ", 1, true)
        if s then
            local key = line:sub(1, s - 1)
            local value = line:sub(e + 1)
            if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
                value = value:sub(2, -2)
                if value ~= "" then
                    total = total + 1
                    if corpus:find('"' .. value .. '"', 1, true) then
                        rendered = rendered + 1
                    else
                        unmatched_list[#unmatched_list + 1] = "  " .. key .. ' = "' .. value .. '"'
                    end
                end
            end
        end
    end
end

local unmatched = total - rendered
local pct = 0
if total > 0 then pct = (rendered * 100) // total end

if LIST then
    log.raw("en.toml values that appear NOWHERE in the tray sources:")
    for _, l in ipairs(unmatched_list) do log.raw(l) end
end
verdict.ok("tray-string-drift", "en_keys=" .. total .. " rendered=" .. rendered
    .. " unmatched=" .. unmatched .. " rendered_pct=" .. pct)
