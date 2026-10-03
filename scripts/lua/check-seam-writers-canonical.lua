-- @trace order:1251-54p3, order:1384-ddua
-- check-seam-writers-canonical.lua — every writer of a process-global seam
-- variable (default TILLANDSIAS_PODMAN_BIN) in a crate takes the canonical lock
-- (default podman_seam_lock), so two tests cannot race on one env var.
--
-- PORTED from check-seam-writers-canonical.sh (1384-ddua). The shell form was
-- `grep -rln … | while read f; do sed 's://.*::' "$f" | grep -cE …` and, in its
-- own words, "worked by the ABSENCE of pipefail" (795-imz3/792-ksr8): under
-- pipefail an early-exiting grep could turn a match into a failure. Here there
-- is no pipe to break: text.count_lines returns an integer, not a status, and
-- the walk and the regex are the binary's on every host (no GNU/BSD `grep -r`).
--
-- Verdicts, byte-identical to the .sh at its parent commit:
--   ok:seam-writers-canonical:<n>                 exit 0
--   refused:seam-writer-uncanonical:<file>        one per file, exit 1
--   refused:seam-var-has-no-writers:<var>         exit 1
-- Usage: tillandsias-plan script run scripts/lua/check-seam-writers-canonical.lua [-- CRATE VAR CANON]
local crate = arg[1] or "crates/tillandsias-headless/src"
local var = arg[2] or "TILLANDSIAS_PODMAN_BIN"
local canon = arg[3] or "podman_seam_lock"

local writer_re = [[(set_var|remove_var)\("]] .. text.escape(var) .. [["]]
local canon_re = text.escape(canon)

local writers = {}
for _, f in ipairs(fs.walk(crate, { suffix = ".rs" })) do
    if text.count_lines(text.strip_line_comments(fs.read(f), "//"), writer_re) > 0 then
        writers[#writers + 1] = f
    end
end
if #writers == 0 then
    verdict.refused("seam-var-has-no-writers:" .. var)
end

local bad = {}
for _, f in ipairs(writers) do
    if text.count_lines(text.strip_line_comments(fs.read(f), "//"), canon_re) == 0 then
        bad[#bad + 1] = f
    end
end
for i = 1, #bad - 1 do
    out.line("refused:seam-writer-uncanonical:" .. bad[i])
end
if #bad > 0 then
    verdict.refused("seam-writer-uncanonical:" .. bad[#bad])
end
verdict.ok("seam-writers-canonical", #writers)
