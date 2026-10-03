-- @trace order:1527-v7cy, order:1027-539s, order:998-qrwu
-- @env TILLANDSIAS_STATE_ROOT_LITERAL_BASELINE
--
-- check-state-root-literals.lua — PORTED from check-state-root-literals.sh,
-- byte for byte. The state ROOT may be declared once (images/default/ca-path.txt)
-- and derived everywhere else; this counts RUST literals of it outside the
-- declaration and its readers and refuses a rise. See the .sh's header for the
-- full rationale (concept A, the XDG state dir, vs concept B, the manifest
-- root, which is this guard's only subject) — not restated here, because
-- restating a single-sourced fact in prose is exactly the defect this guard
-- exists to catch.
--
-- CODE ONLY: a line whose trimmed content starts with "//" or "*" is a
-- comment and does not count, replicating the .sh's
-- `grep -vE ':[[:space:]]*(///|//!|//|\*)'` filter over `grep -rn` output —
-- here applied directly to each source line's own trimmed text rather than to
-- grep's synthetic "path:line:text" format, which is unobservable on real
-- source (no file/line number ever coincidentally reproduces a comment
-- marker right after a colon).
--
-- Verdict grammar (unchanged, legacy):
--   ok:state-root-literals:<n> of <baseline>             exit 0
--   violation:state-root-literals-grew:<n> of <baseline>  exit 1
local baseline_env = env.get("TILLANDSIAS_STATE_ROOT_LITERAL_BASELINE")
local BASELINE = tonumber(baseline_env) or 0

local LITERAL = ".local/state/tillandsias"
local LITERAL_PAT = "%.local/state/tillandsias"

local EXCLUDE = {
    ["ca_path.rs"] = true,
    ["config.rs"] = true,
    ["event_collector.rs"] = true,
}

local count = 0
local ok_walk, files = pcall(fs.walk, "crates", { suffix = ".rs" })
if ok_walk then
    for _, f in ipairs(files) do
        local base = f:match("([^/]+)$")
        if not EXCLUDE[base] then
            local ok_read, content = pcall(fs.read, f)
            if ok_read then
                for _, line in ipairs(text.lines(content)) do
                    if text.contains(line, LITERAL) then
                        local trimmed = line:match("^%s*(.*)$")
                        if not (trimmed:sub(1, 2) == "//" or trimmed:sub(1, 1) == "*") then
                            for _ in line:gmatch(LITERAL_PAT) do
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

if count > BASELINE then
    log.raw("")
    log.raw("  A new Rust literal of the state root was added. The root is DECLARED in")
    log.raw("  images/default/ca-path.txt and every consumer must DERIVE from it:")
    log.raw("      tillandsias_core::ca_path::state_root_expanded(&home)")
    log.raw("  A second literal is 998-qrwu's defect returning — that packet removed 38")
    log.raw("  copies of one path, and 1019-ivia reintroduced the root at N=2.")
    log.raw("")
    log.raw("  If your site is the XDG STATE DIR (platform-idiomatic, honours")
    log.raw("  XDG_STATE_HOME, ~/Library/Logs on macOS) it is a DIFFERENT CONCEPT that")
    log.raw("  merely coincides on a default Linux host. Do not point it at the")
    log.raw("  manifest root — see this script's header for why that breaks macOS.")
    verdict.emit("violation:state-root-literals-grew:" .. count .. " of " .. BASELINE, 1)
end

verdict.emit("ok:state-root-literals:" .. count .. " of " .. BASELINE, 0)
