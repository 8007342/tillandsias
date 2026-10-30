-- @env GH_TOKEN GITHUB_TOKEN HOME PATH
-- @read-env GH_TOKEN GITHUB_TOKEN
-- @trace spec:ci-release
--
-- litmus-helper-nix-cache-size.lua — PORTED from litmus-helper-nix-cache-size.sh
-- (1118-fqfk carry). Is the repository's nix Actions cache near GitHub's 10 GiB
-- LRU limit? Over 8 GiB (80%) the warm workflow should run to purge it.
--
-- The shell version summed one page: `gh api --paginate --jq` prints the jq
-- result once PER PAGE, so a repository with more than 100 caches handed the
-- shell `-gt` test several lines and failed it. This sums every page.
--
-- Grammar (stdout), unchanged for the litmus step:
--   SKIP: no GH_TOKEN available ...      exit 0
--   nix cache total: N bytes (threshold: T), then
--   nix cache size ok                    exit 0
--   WARN: nix cache exceeds ...          exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/litmus-helper-nix-cache-size.lua -- check-live-cache

local REPO = "8007342/tillandsias"
local THRESHOLD_BYTES = 8 * 1024 * 1024 * 1024

if arg[1] ~= "check-live-cache" then
    log.raw("usage: litmus-helper-nix-cache-size.lua -- check-live-cache")
    verdict.emit("could-not-run:nix-cache-size:usage", 2)
end

local token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
if token == "" then
    out.line("SKIP: no GH_TOKEN available (run in CI or export GH_TOKEN to check live cache size)")
    verdict.emit("ok:nix-cache-size:skip-no-token", 0)
end

local r = proc.run{
    argv = {
        "gh", "api", "--paginate",
        "/repos/" .. REPO .. "/actions/caches?per_page=100",
        "--jq", '[.actions_caches[] | select(.key | contains("nix")) | .size_in_bytes] | add // 0',
    },
    env = { GH_TOKEN = token, HOME = env.get("HOME") or "", PATH = env.get("PATH") or "" },
}
-- As before, an unanswered query counts as an empty cache: the step is a size
-- signal, not a reachability check.
local total = 0
if r.status == "exited" and r.code == 0 then
    for _, l in ipairs(text.lines(r.stdout or "")) do
        total = total + (tonumber(text.trim(l)) or 0)
    end
end

out.line(("nix cache total: %d bytes (threshold: %d)"):format(total, THRESHOLD_BYTES))
if total > THRESHOLD_BYTES then
    out.line("WARN: nix cache exceeds 80% of LRU limit — trigger nix-cache-warm.yml to purge")
    verdict.emit("violation:nix-cache-size:over-threshold", 1)
end
out.line("nix cache size ok")
verdict.emit("ok:nix-cache-size:under-threshold", 0)
