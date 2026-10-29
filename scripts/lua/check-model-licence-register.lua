-- @trace order:1921-h4gv, order:1874-h9ns
-- @env TILLANDSIAS_MODEL_LICENCE_REGISTER
--
-- check-model-licence-register.lua — refuse a media model register row a
-- shipped product may not fetch: a non-commercial, revenue-capped or
-- custom-terms licence, a licence not on the allow list, a gated repo, or a row
-- that does not pin a revision and a sha256. Offline: it reads the register
-- (images/models/licence-register.tsv) and nothing else; the Hub's answers were
-- recorded into the row when it was written.
--
-- One line per refused row on stdout, each with its own reason:
--   refused-row:<name>:<reason>:<detail>
-- reasons: non-commercial | revenue-capped | custom-terms | unknown-licence |
--          gated | unpinned
--
-- Verdicts:
--   ok:model-licence-register:rows=<n>                 exit 0
--   refused:model-licence-register:refused=<k>:rows=<n> exit 1
--   could-not-run:model-licence-register:<why>          exit 3

local REG = env.get("TILLANDSIAS_MODEL_LICENCE_REGISTER") or ""
if REG == "" then REG = "images/models/licence-register.tsv" end

local ALLOWED = {
    ["apache-2.0"] = true, ["mit"] = true, ["bsd-3-clause"] = true, ["unlicense"] = true,
    ["openrail++"] = true, ["creativeml-openrail-m"] = true,
}
-- Licence ids read on the cards of the 2026-10-28 deny list, by class.
local DENIED = {
    ["flux-1-dev-non-commercial-license"] = "non-commercial",
    ["cc-by-nc-4.0"] = "non-commercial",
    ["cc-by-nc-sa-4.0"] = "non-commercial",
    ["cc-by-nc-nd-4.0"] = "non-commercial",
    ["qwen-research"] = "non-commercial",
    ["bria-rmbg-1.4"] = "non-commercial",
    ["bria-rmbg-2.0"] = "non-commercial",
    ["sdxl-turbo-research"] = "non-commercial",
    ["stabilityai-ai-community"] = "revenue-capped",
    ["stable-audio-community"] = "revenue-capped",
    ["qwen"] = "revenue-capped",
    ["gemma"] = "custom-terms",
    ["dinov3-license"] = "custom-terms",
    ["minicpm-model-license"] = "custom-terms",
    ["insightface-non-commercial"] = "non-commercial",
}

local function afford(why, remedy)
    io.stderr:write("  why: " .. why .. "\n  remedy: " .. remedy .. "\n")
end

local ok_read, body = pcall(fs.read, REG)
if not ok_read then
    afford("the register " .. REG .. " could not be read", "run from the checkout root or set TILLANDSIAS_MODEL_LICENCE_REGISTER")
    verdict.emit("could-not-run:model-licence-register:no-register", 3)
end

-- The reason a row is refused, or nil when it may ship.
local function refusal(spdx, gated, revision, sha)
    local lic = (spdx or ""):lower()
    if DENIED[lic] then return DENIED[lic], lic end
    if not ALLOWED[lic] then return "unknown-licence", (lic == "" and "-" or lic) end
    if gated ~= "false" then return "gated", "gated=" .. (gated or "") end
    if not (revision or ""):match("^%x+$") or #revision ~= 40 then return "unpinned", "revision=" .. (revision or "") end
    if not (sha or ""):match("^%x+$") or #sha ~= 64 then return "unpinned", "sha256=" .. (sha or "") end
    return nil
end

local rows, refused = 0, 0
for line in (body .. "\n"):gmatch("(.-)\n") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
        local c = {}
        for f in (line .. "\t"):gmatch("(.-)\t") do c[#c + 1] = f end
        rows = rows + 1
        local reason, detail = refusal(c[6], c[7], c[3], c[5])
        if reason then
            refused = refused + 1
            print("refused-row:" .. (c[1] or "?") .. ":" .. reason .. ":" .. detail)
        end
    end
end

if rows == 0 then
    afford("the register has no rows, so nothing was vouched for", "add the rows the fetcher pins")
    verdict.emit("could-not-run:model-licence-register:empty", 3)
end
if refused > 0 then
    afford("a shipped product may fetch only permissive, ungated, pinned weights (1921-h4gv)",
        "drop each refused-row above, or replace it with an allowed, ungated copy pinned by revision and sha256")
    verdict.emit("refused:model-licence-register:refused=" .. refused .. ":rows=" .. rows, 1)
end
verdict.emit("ok:model-licence-register:rows=" .. rows, 0)
