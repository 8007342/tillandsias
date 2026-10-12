-- @trace order:1043-kvvn, order:1545-qdb5
--
-- check-unique-bin-names.lua — PORTED from check-unique-bin-names.sh (carried
-- obligation shell->lua, paid by the 1545-qdb5 / 1553-x8js / 1553-kvmf stack).
-- No two workspace crates may declare the same [[bin]] name.
--
-- WHY THIS IS NOT A STYLE RULE. Cargo writes every bin target to
-- target/<profile>/<name>, so two crates sharing a name write the SAME FILE and
-- whichever links last wins. Nothing warns. MEASURED 2026-09-05: the macOS and
-- Windows trays both declared `tillandsias-tray`, and in a full-workspace build
-- the macOS tray's CLI tests ran the WINDOWS stub. It never appeared under
-- `cargo test -p`, so isolation hid it every time. The SHIPPED name is a
-- separate contract and deliberately not checked here.
--
-- A ZERO COUNT IS A FAILURE, NOT A PASS: a guard that inspected zero manifests
-- must not report the same verdict as one that inspected all of them.
--
-- Grammar (one line on stdout, unchanged):
--   ^(ok:unique-bin-names:[0-9]+ checked|violation:duplicate-bin-name:[0-9]+)$
-- The .sh's awk, as Lua: `[[bin]]` opens a bin table, any other `[` header
-- closes it, and a `name = "<x>"` line inside one is a bin name.

local ok_walk, files = pcall(fs.walk, "crates")
local manifests = {}
if ok_walk and files then
    for _, f in ipairs(files) do
        -- crates/*/Cargo.toml exactly, as the .sh's glob (one directory deep).
        if f:match("^crates/[^/]+/Cargo%.toml$") then manifests[#manifests + 1] = f end
    end
end
table.sort(manifests)

local entries = {} -- { name, manifest } in manifest order, as the .sh's TMP file
for _, m in ipairs(manifests) do
    local ok, src = pcall(fs.read, m)
    if ok and src then
        local inbin = false
        for _, line in ipairs(text.lines(src)) do
            if line:match("^%[%[bin%]%]") then
                inbin = true
            elseif line:match("^%[") then
                inbin = false
            elseif inbin and line:match("^[ \t]*name[ \t]*=") then
                local name = line:gsub("^[ \t]*name[ \t]*=[ \t]*\"", "", 1):gsub("\".*$", "", 1)
                entries[#entries + 1] = { name, m }
            end
        end
    end
end

if #entries == 0 then
    log.raw("  no [[bin]] targets were found in crates/*/Cargo.toml — this guard inspected nothing and must not report ok (1043-kvvn)")
    verdict.emit("violation:duplicate-bin-name:0", 1)
    return
end

local counts = {}
for _, e in ipairs(entries) do counts[e[1]] = (counts[e[1]] or 0) + 1 end
local dups = {}
for name, n in pairs(counts) do
    if n > 1 then dups[#dups + 1] = name end
end
table.sort(dups)

if #dups > 0 then
    for _, d in ipairs(dups) do
        local where = {}
        for _, e in ipairs(entries) do
            if e[1] == d then where[#where + 1] = e[2] .. " " end
        end
        log.raw(("  [[bin]] name '%s' is declared by: %s"):format(d, table.concat(where)))
        log.raw(("    Both write target/<profile>/%s; the last link wins and the other crate's tests run the wrong binary (1043-kvvn)."):format(d))
    end
    verdict.emit(("violation:duplicate-bin-name:%d"):format(#dups), 1)
    return
end
verdict.emit(("ok:unique-bin-names:%d checked"):format(#entries), 0)
