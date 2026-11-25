-- @env PATH HOME
-- @trace order:1248-j6vd, order:2330-sn77
--
-- test-nvidia-cdi-stale-hostpath.lua — nvidia-cdi-ensure.sh notices a CDI spec that mounts a
-- file which no longer exists, not only a driver that moved. Ported from the .sh of the same
-- name (2330-sn77). Measured on macuahuitl: the host moved to libnvidia-egl-gbm 1.1.4 under
-- an unchanged driver, the check said current, and every GPU container start died on the
-- missing bind source. No GPU or toolkit: nvidia-smi and nvidia-ctk are stubs.
--
--   1 stamp matches, every hostPath exists: current, nothing regenerated
--   2 one hostPath gone: not current   3 the path is named   4 regenerated once
--   5 stdout is still one verdict line 6 the installed spec is the regenerated one
--   7 CONTROL a driver move regenerates, with no stale note
--   8 quoted hostPath values are read the same
--
-- Usage: tillandsias-plan script run scripts/lua/test-nvidia-cdi-stale-hostpath.lua
-- Verdict: ok:nvidia-cdi-stale-hostpath:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("nvidia-cdi-stale-hostpath")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GBM = "/lib/libnvidia-egl-gbm.so.1.1."

-- paths: function of the scratch lib dir's spelling to a list of hostPath values.
local function run(live, stamp, paths)
    local d = T:scratch()
    for _, p in ipairs{ "bin", "cdi", "lib" } do fs.mkdir(d.rel .. "/" .. p) end
    fs.write(d.rel .. "/lib/libnvidia-ml.so.1", ""); fs.write(d.rel .. GBM .. "4", ""); fs.write(d.rel .. "/ctk-calls", "")
    fs.write(d.rel .. "/bin/nvidia-smi", "#!/usr/bin/env bash\necho " .. live .. "\n")
    local spec = "cdiVersion: 0.7.0\nkind: nvidia.com/gpu\ncontainerEdits:\n  mounts:\n"
    fs.write(d.rel .. "/bin/nvidia-ctk", '#!/usr/bin/env bash\necho call >>"' .. d.abs .. '/ctk-calls"\nout=""\nfor a in "$@"; do case "$a" in --output=*) out="${a#--output=}" ;; esac; done\n'
        .. "cat >\"$out\" <<'SPEC'\n" .. spec .. "  - hostPath: " .. d.abs .. GBM .. "4\n    containerPath: /usr/lib64/regenerated\nSPEC\n")
    local body = spec
    for _, p in ipairs(paths(d.abs)) do body = body .. "  - hostPath: " .. p .. "\n    containerPath: /x\n" end
    fs.write(d.rel .. "/cdi/nvidia.yaml", body); fs.write(d.rel .. "/cdi/.nvidia-driver-version", stamp .. "\n")
    local r = T:run{ SH, "-s", "--", ROOT .. "/scripts/nvidia-cdi-ensure.sh", cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        stdin = 'chmod +x bin/*\nexport PATH="$PWD/bin:$PATH" TILLANDSIAS_CDI_DIR="$PWD/cdi"\nexec bash "$1" </dev/null\n' }
    local o, e = (r.stdout or ""):gsub("\r", ""), (r.stderr or ""):gsub("\r", "")
    local _, calls = fs.read(d.rel .. "/ctk-calls"):gsub("call", "")
    local _, lines = o:gsub("[^\n]+", "")
    return { all = "\n" .. o .. "\n" .. e .. "\n", lines = lines, calls = calls, abs = d.abs, spec = fs.read(d.rel .. "/cdi/nvidia.yaml"),
        why = "rc=" .. tostring(r.code) .. " calls=" .. calls .. " " .. o .. e }
end
local function has(x, line) return text.contains(x.all, "\n" .. line .. "\n") end

local x = run("610.57.04", "610.57.04", function(a) return { a .. "/lib/libnvidia-ml.so.1", a .. GBM .. "4" } end)
T:arm("1 every hostPath exists: current, nothing regenerated", has(x, "ok:nvidia-cdi:current:610.57.04") and x.calls == 0, x.why)
x = run("610.57.04", "610.57.04", function(a) return { a .. "/lib/libnvidia-ml.so.1", a .. GBM .. "3" } end)
T:arm("2 a missing hostPath is not reported current", not text.contains(x.all, "\nok:nvidia-cdi:current:"), x.why)
T:arm("3 the missing path is named", has(x, "note:nvidia-cdi:stale-hostpath:" .. x.abs .. GBM .. "3"), x.why)
T:arm("4 regenerated once", has(x, "ok:nvidia-cdi:generated:610.57.04") and x.calls == 1, x.why)
T:arm("5 stdout is exactly one verdict line", x.lines == 1, x.why)
T:arm("6 the installed spec is the regenerated one", text.contains(x.spec, "/usr/lib64/regenerated") and not text.contains(x.spec, GBM .. "3"), x.spec)
x = run("611.00.01", "610.57.04", function(a) return { a .. "/lib/libnvidia-ml.so.1" } end)
T:arm("7 CONTROL a driver move regenerates with no stale note", has(x, "ok:nvidia-cdi:generated:611.00.01") and not text.contains(x.all, "stale-hostpath"), x.why)
x = run("610.57.04", "610.57.04", function(a) return { '"' .. a .. '/lib/libnvidia-ml.so.1"', "'" .. a .. "/lib/gone.so'" } end)
T:arm("8 quoted hostPath values are read, and only the missing one is named", has(x, "note:nvidia-cdi:stale-hostpath:" .. x.abs .. "/lib/gone.so")
    and not text.contains(x.all, "libnvidia-ml.so.1\n"), x.why)
T:finish()
