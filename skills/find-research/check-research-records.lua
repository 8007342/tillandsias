-- @trace spec:research-records
-- @trace order:1809-dwqf
-- @env TILLANDSIAS_RESEARCH_DIR
--
-- check-research-records.lua — validate every research record under a
-- research/ tree (the shared library, or a project's own store) and refuse
-- one without provenance.
--
-- A RECORD is research/<domain>/<slug>.md with YAML frontmatter. The fields it
-- MUST carry, and why the validator insists on each:
--   id            equals <domain>/<slug>, so a citation `research:<id>` resolves
--                 to exactly one file by path, the way `cheatsheet:<path>` does
--   claim         the one sentence an agent cites; a record without one is a
--                 bookmark, not research
--   applies_to    non-empty list, so the record can be found from the
--                 situation an agent is in, not only from the paper's title
--   sources       non-empty list; each entry needs url, kind, retrieved and
--                 archived. `archived` is an archive URL or `pending: <why>`;
--                 an absent one is refused because the live URL is the part
--                 that rots (the ranitas field report: 403/502/503 on half the
--                 pages the project had cited)
--   authority     primary | secondary | tertiary
--   strength      established | replicated | single-study | expert-opinion | contested
--   last_verified ISO date, the staleness signal
--   status        current | superseded | retracted
--   origin        shared | project
-- and the body MUST carry a `## Provenance` section, the human-readable copy
-- of the chain, so the record reads the same way a cheatsheet does.
--
-- --write-index regenerates <dir>/INDEX.md (one line per record, grouped by
-- domain), the way scripts/regenerate-cheatsheet-index.sh does for cheatsheets.
--
-- Verdicts (last line of stdout):
--   ok:research-records:records=<n>:domains=<k>                     exit 0
--   violation:research-records:<path>:<field>:<reason>              exit 1
--   could-not-run:research-records:empty-population:<dir>           exit 3
--   could-not-run:research-records:no-dir:<dir>                     exit 3

local DIR = env.get("TILLANDSIAS_RESEARCH_DIR") or ""
if DIR == "" then DIR = "research" end

local write_index = false
for _, a in ipairs(arg or {}) do
    if a == "--write-index" then write_index = true end
end

local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end

local KINDS = { ["peer-reviewed"] = true, standard = true, ["primary-report"] = true,
                ["expert-secondary"] = true, tertiary = true }
local AUTHORITY = { primary = true, secondary = true, tertiary = true }
local STRENGTH = { established = true, replicated = true, ["single-study"] = true,
                   ["expert-opinion"] = true, contested = true }
local STATUS = { current = true, superseded = true, retracted = true }
local ORIGIN = { shared = true, project = true }

if not fs.exists(DIR) then
    verdict.emit("could-not-run:research-records:no-dir:" .. DIR, 3,
        "no research directory at " .. DIR .. " (set TILLANDSIAS_RESEARCH_DIR)")
end

local ok_walk, files = pcall(fs.walk, DIR, { suffix = ".md" })
if not ok_walk then files = {} end
local records = {}
for _, f in ipairs(files) do
    local rel = f
    if text.starts_with(rel, DIR .. "/") then rel = rel:sub(#DIR + 2) end
    -- A record lives one directory down: <domain>/<slug>.md. README, TEMPLATE
    -- and INDEX at the top are not records.
    if rel:find("/", 1, true) and rel ~= "TEMPLATE.md" then records[#records + 1] = { path = f, rel = rel } end
end
table.sort(records, function(a, b) return a.rel < b.rel end)

if #records == 0 then
    verdict.emit("could-not-run:research-records:empty-population:" .. DIR, 3,
        "no <domain>/<slug>.md records under " .. DIR)
end

local violations = {}
local function fail(rec, field, reason)
    violations[#violations + 1] = "violation:research-records:" .. rec.rel .. ":" .. field .. ":" .. reason
end

local function nonempty_string(v) return type(v) == "string" and text.trim(v) ~= "" end
local function nonempty_list(v) return type(v) == "table" and #v > 0 end
local function iso_date(v) return type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end
local function is_url(v) return type(v) == "string" and (text.starts_with(v, "https://") or text.starts_with(v, "http://")) end

local by_domain = {}
for _, rec in ipairs(records) do
    local body = read(rec.path) or ""
    local fm, rest = body:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
    if not fm then
        fail(rec, "frontmatter", "no YAML frontmatter block")
    else
        local ok_y, doc = pcall(yaml.parse, fm)
        if not ok_y or type(doc) ~= "table" then
            fail(rec, "frontmatter", "unparseable")
        else
            local want_id = rec.rel:gsub("%.md$", "")
            if doc.id ~= want_id then fail(rec, "id", "must equal " .. want_id) end
            if not nonempty_string(doc.claim) then fail(rec, "claim", "missing") end
            if not nonempty_list(doc.applies_to) then fail(rec, "applies_to", "empty") end
            if not nonempty_list(doc.sources) then
                fail(rec, "sources", "missing-provenance")
            else
                for i, s in ipairs(doc.sources) do
                    local tag = "sources[" .. i .. "]"
                    if type(s) ~= "table" then fail(rec, tag, "not-a-map")
                    else
                        if not is_url(s.url) then fail(rec, tag .. ".url", "missing") end
                        if not KINDS[s.kind or ""] then fail(rec, tag .. ".kind", "not-in-vocabulary") end
                        if not iso_date(s.retrieved) then fail(rec, tag .. ".retrieved", "not-an-iso-date") end
                        local a = s.archived
                        if not (is_url(a) or (type(a) == "string" and text.starts_with(a, "pending:") and text.trim(a:sub(9)) ~= "")) then
                            fail(rec, tag .. ".archived", "missing-archived-link")
                        end
                    end
                end
            end
            if not AUTHORITY[doc.authority or ""] then fail(rec, "authority", "not-in-vocabulary") end
            if not STRENGTH[doc.strength or ""] then fail(rec, "strength", "not-in-vocabulary") end
            if not iso_date(doc.last_verified) then fail(rec, "last_verified", "not-an-iso-date") end
            if not iso_date(doc.since) then fail(rec, "since", "not-an-iso-date") end
            if not STATUS[doc.status or ""] then fail(rec, "status", "not-in-vocabulary") end
            if not ORIGIN[doc.origin or ""] then fail(rec, "origin", "not-in-vocabulary") end
            if not text.contains("\n" .. rest, "\n## Provenance") then fail(rec, "body", "no-provenance-section") end
            local domain = rec.rel:match("^([^/]+)/")
            by_domain[domain] = by_domain[domain] or {}
            local cl = type(doc.claim) == "string" and text.trim(doc.claim):gsub("%s+", " ") or ""
            if #cl > 110 then cl = cl:sub(1, 107) .. "..." end
            by_domain[domain][#by_domain[domain] + 1] =
                string.format("- %s — %s [%s, %s]", rec.rel, cl, tostring(doc.authority), tostring(doc.strength))
        end
    end
end

if #violations > 0 then
    -- Every violation on its own line; the last one is also the verdict line.
    for i = 1, #violations - 1 do out.line(violations[i]) end
    verdict.emit(violations[#violations], 1)
end

local domains = {}
for d in pairs(by_domain) do domains[#domains + 1] = d end
table.sort(domains)

if write_index then
    local lines = {
        "# Research Index", "",
        "@trace spec:research-records", "",
        "> AUTO-GENERATED by `scripts/lua/check-research-records.lua --write-index`. Do NOT hand-edit.",
        "> Source of truth = the YAML frontmatter on each record.", "",
        "One line per record: `<domain>/<slug>.md — <claim> [<authority>, <strength>]`.",
        "Cite as `research:<domain>/<slug>`. Agents inside the forge find this file at",
        "`$TILLANDSIAS_RESEARCH/INDEX.md` (`/opt/research/INDEX.md`).", "",
    }
    for _, d in ipairs(domains) do
        lines[#lines + 1] = "## " .. d
        lines[#lines + 1] = ""
        for _, l in ipairs(by_domain[d]) do lines[#lines + 1] = l end
        lines[#lines + 1] = ""
    end
    fs.write(DIR .. "/INDEX.md", table.concat(lines, "\n"))
    out.line("wrote:" .. DIR .. "/INDEX.md")
end

verdict.ok("research-records", "records=" .. #records, "domains=" .. #domains)
