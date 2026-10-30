-- @trace order:1921-qqfz, order:1874-bair
-- @env TILLANDSIAS_IMAGEGEN_TIERS TILLANDSIAS_HF_API HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy SSL_CERT_FILE CURL_CA_BUNDLE
--
-- check-imagegen-tier-sources-ungated.lua — refuse an imagegen tier row whose
-- licence_source Hugging Face repo is gated. The fetcher holds no token (no
-- plaintext credentials at rest), so a gated repo cannot be fetched however
-- permissive its licence: black-forest-labs/FLUX.1-schnell is apache-2.0 and
-- gated:auto (verified 2026-10-28).
--
-- Reads the Hugging Face model API, so it needs egress (the forge proxy). An
-- unreachable API is could-not-run, never ok.
--
--   tillandsias-plan script run scripts/lua/check-imagegen-tier-sources-ungated.lua
--
-- Verdicts:
--   ok:imagegen-tier-sources-ungated:rows=<n>                      exit 0
--   refused:imagegen-tier-sources-ungated:<tier>:<repo>:gated=<v>  exit 1
--   could-not-run:imagegen-tier-sources-ungated:<tier>:<why>       exit 3

local TABLE = env.get("TILLANDSIAS_IMAGEGEN_TIERS") or ""
if TABLE == "" then TABLE = "images/imagegen/tiers.tsv" end
local API = env.get("TILLANDSIAS_HF_API") or ""
if API == "" then API = "https://huggingface.co/api" end

-- `script run` hands a child a scrubbed environment; the forge reaches the
-- internet only through its proxy, so pass the proxy variables through.
local PENV = {}
for _, k in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
                     "SSL_CERT_FILE", "CURL_CA_BUNDLE" }) do
    local v = env.get(k)
    if v and v ~= "" then PENV[k] = v end
end

local function afford(why, remedy)
    io.stderr:write("  why: " .. why .. "\n  remedy: " .. remedy .. "\n")
end

local ok_read, body = pcall(fs.read, TABLE)
if not ok_read then
    afford("the tier table " .. TABLE .. " could not be read", "run from the checkout root or set TILLANDSIAS_IMAGEGEN_TIERS")
    verdict.emit("could-not-run:imagegen-tier-sources-ungated:no-table", 3)
end

local rows, refused, unknown = 0, {}, {}
for line in (body .. "\n"):gmatch("(.-)\n") do
    if line ~= "" and line:sub(1, 1) ~= "#" then
        local cols = {}
        for c in (line .. "\t"):gmatch("(.-)\t") do cols[#cols + 1] = c end
        local tier, source = cols[1], cols[7] or ""
        rows = rows + 1
        local owner, name = source:match("^https://huggingface%.co/([^/]+)/([^/]+)")
        if not owner then
            unknown[#unknown + 1] = tier .. ":not-a-hugging-face-source"
        else
            local repo = owner .. "/" .. name
            local r = proc.run({ argv = { "curl", "-fsS", "-m", "30", API .. "/models/" .. repo }, env = PENV, timeout_ms = 40000 })
            local out = r.stdout or ""
            if r.status ~= "exited" or r.code ~= 0 then
                unknown[#unknown + 1] = tier .. ":" .. repo .. ":api-unreachable"
            elseif out:find('"gated":false', 1, true) then
                io.stderr:write("ok:imagegen-tier-sources-ungated:" .. tier .. ":" .. repo .. "\n")
            else
                local v = out:match('"gated":([^,}]*)') or "absent"
                refused[#refused + 1] = tier .. ":" .. repo .. ":gated=" .. v
            end
        end
    end
end

if #refused > 0 then
    for i = 1, #refused - 1 do print("refused:imagegen-tier-sources-ungated:" .. refused[i]) end
    afford("a gated repo needs a login the fetcher never holds",
        "point licence_source at an ungated copy pinned with /tree/<sha> (FLUX: second-state/FLUX.1-schnell-GGUF)")
    verdict.emit("refused:imagegen-tier-sources-ungated:" .. refused[#refused], 1)
end
if #unknown > 0 then
    afford("the gated flag could not be read for " .. table.concat(unknown, ", "),
        "re-run with egress to huggingface.co (the forge proxy)")
    verdict.emit("could-not-run:imagegen-tier-sources-ungated:" .. unknown[1], 3)
end
verdict.emit("ok:imagegen-tier-sources-ungated:rows=" .. rows, 0)
