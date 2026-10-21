-- @trace plan/issues/forge-build-check-tooling-gap-2026-07-08.md
--
-- Pin the build.sh forge check-only branch without running a full cargo build.
-- PORTED from scripts/test-build-sh-forge-check-only.sh (667-kfyn carry:
-- shell-to-lua): the same five string pins plus `bash -n build.sh`.

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.emit("could-not-run:forge-check-only:no-repo-root", 3) end

local src = fs.read("build.sh")
local function has(s) return src:find(s, 1, true) ~= nil end
local function fail(why)
    out.line("forge-check-only test failed: " .. why)
    verdict.emit("refused:forge-check-only:" .. why:gsub("%s", "-"), 1)
end

if not has("_forge_check_only_without_host_podman_setup()") then fail("missing forge check-only predicate") end
if not has("Skipping host Podman registry setup for forge check-only build") then fail("registry setup skip message missing") end
if not has("Skipping host dev cache setup for forge check-only build") then fail("dev cache skip message missing") end
if has("for tool in cargo rustc rustfmt clippy-driver gcc pkg-config file;") then
    fail("file is still required for all host build checks")
end
if not has('[[ "$FLAG_INSTALL" == true ]] && ! command -v file') then fail("install-only file requirement missing") end

local n = proc.run({ argv = { "bash", "-n", ROOT .. "/build.sh" }, timeout_ms = 60000 })
if n.code ~= 0 then fail("build.sh does not parse: " .. text.trim(n.stderr or "")) end

out.line("forge-check-only: ok")
verdict.emit("ok:forge-check-only", 0)
