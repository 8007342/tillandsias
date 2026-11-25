-- @trace order:1118-d3b6, order:2332-rxkr
--
-- test-inference-engine-pinned-and-npu-honest.lua — the inference engine is pinned and its
-- digest verified before it is executed, and NPU state is reported. Ported from the .sh of
-- the same name (2332-rxkr). STATIC over images/inference/entrypoint.sh, code only (a comment
-- quoting the old URL is not the defect); no download.
--
--   1 no releases/latest download          2 a concrete version, and the URL uses it
--   3 every accepted arch has a digest     4 checksummed, three refusals, no skip
--   5 verified before unpacking            6 NPU state is a computed value
--   7 CONTROL the spec still has NPU rows
--
-- Usage: tillandsias-plan script run scripts/lua/test-inference-engine-pinned-and-npu-honest.lua
-- Verdict: ok:inference-engine-pinned-and-npu-honest:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("inference-engine-pinned-and-npu-honest")
local lines = {}
for l in (fs.read("images/inference/entrypoint.sh"):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
    if not l:match("^%s*#") then lines[#lines + 1] = l end
end
local CODE = "\n" .. table.concat(lines, "\n") .. "\n"
local function has(s) return text.contains(CODE, s) end
local function at(s) return CODE:find(s, 1, true) end

T:arm("1 no releases/latest download in live code", not has("releases/latest/download"), "found")
T:arm("2a a concrete engine version is pinned", CODE:find('OLLAMA_VERSION="v%d+%.%d+%.%d+"') ~= nil, "no pinned OLLAMA_VERSION")
T:arm("2b the download URL is built from it", has("releases/download/${OLLAMA_VERSION}/"), "the pin does not reach the fetch")
local arches, bare = 0, {}
for arch in CODE:gmatch('%) *OLLAMA_ARCH="([a-z0-9]+)"') do
    arches = arches + 1
    local hex = CODE:match("\n%s*" .. arch .. '%)%s*OLLAMA_SHA256="([0-9a-f]+)"')
    if not hex or #hex ~= 64 then bare[#bare + 1] = arch end
end
T:arm("3 every accepted arch carries a 64-hex digest", arches >= 2 and #bare == 0, "arches=" .. arches .. " without: " .. table.concat(bare, " "))
T:arm("4a the payload is checksummed", has("sha256sum"), "no sha256sum")
for _, s in ipairs{ "no pinned SHA-256 for arch", "sha256sum unavailable", "engine digest mismatch" } do
    T:arm("4b refuses: " .. s, has(s), "that path falls through and executes the payload")
end
T:arm("4c a missing verifier is not skipped", not has("skipping checksum verification"), "found")
local v, x = at("engine digest mismatch"), at("zstd -dc")
T:arm("5 the digest is checked before the archive is unpacked", v ~= nil and x ~= nil and v < x, "verify=" .. tostring(v) .. " extract=" .. tostring(x))
T:arm("6 NPU state is a computed value the banner reports", CODE:find("\n%s*NPU_STATUS=") ~= nil and CODE:find("%${?NPU_STATUS") ~= nil, "no NPU_STATUS computed and printed")
T:arm("7 CONTROL the spec still has NPU rows", fs.read("openspec/specs/inference-container/spec.md"):upper():find("NPU", 1, true) ~= nil, "arm 6 pins telemetry for a removed requirement")
T:finish()
