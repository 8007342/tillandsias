-- @trace spec:forge-as-only-runtime, order:2327-ahqf
--
-- test-forge-no-raw-podman.lua — the headless crate launches podman through the idiomatic layer
-- (crates/tillandsias-podman), never by constructing the command itself. Moved here from a step
-- of litmus-forge-as-only-runtime.yaml that declared `phase: pre-build` on the STEP, where the
-- runner does not read it, so no pre-build run executed it. A line marked `allowed-bootstrap` is
-- a documented exception.
--
--   1 PREMISE the sources are read           2 the tree has no raw podman command
--   3 a planted one is found, by line        4 so is one split over two lines
--   5 CONTROL allowed-bootstrap is accepted  6 CONTROL so is another program
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-no-raw-podman.lua
-- Verdict: ok:forge-no-raw-podman:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("forge-no-raw-podman")
-- Returns the number of files read and the hits as file:line.
local function scan(dir)
    local hits, files = {}, fs.walk(dir, { suffix = ".rs" })
    table.sort(files)
    for _, f in ipairs(files) do
        local s = fs.read(f):gsub("\r", "")
        local at = 1
        while true do
            local a, z = s:find('Command::new%(%s*"podman"', at)
            if not a then break end
            local from = #(s:sub(1, a):match("([^\n]*)$"))
            local line = s:sub(a - from + 1, (s:find("\n", z, true) or #s + 1) - 1)
            local _, n = s:sub(1, a):gsub("\n", "")
            if not line:find("allowed-bootstrap", 1, true) then hits[#hits + 1] = f:match("[^/]*$") .. ":" .. (n + 1) end
            at = z + 1
        end
    end
    return #files, hits
end
local n, hits = scan("crates/tillandsias-headless/src")
T:arm("1 PREMISE the headless sources are read", n > 0, "files=" .. n)
T:arm("2 no raw podman command outside the idiomatic layer", #hits == 0, "route through tillandsias_podman::PodmanClient, or mark the line allowed-bootstrap: " .. table.concat(hits, " "))
local function planted(body)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/src"); fs.write(d.rel .. "/src/x.rs", body)
    local _, h = scan(d.rel .. "/src")
    return table.concat(h, " ")
end
local RAW = 'Command::new("podman")'
local got = planted("fn a() {}\n// two\nlet _ = " .. RAW .. ";\n")
T:arm("3 a planted raw command is found by line", got == "x.rs:3", got)
got = planted('let _ = std::process::Command::new(\n    "podman",\n);\n')
T:arm("4 one split over two lines is found", got == "x.rs:1", got)
got = planted("let _ = " .. RAW .. "; // allowed-bootstrap: reason\n")
T:arm("5 CONTROL a line marked allowed-bootstrap is accepted", got == "", got)
got = planted('let _ = Command::new("git");\nlet _ = Command::new("podman-compose");\nlet _ = Command::new("podman")\n')
T:arm("6 CONTROL another program is accepted, beside one that is not", got == "x.rs:3", got)
T:finish()
