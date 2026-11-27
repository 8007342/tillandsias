-- @trace order:2262-iyyu
-- @env PATH
--
-- test-builder-installs-follow-their-pins.lua — an edit to the host-escape shim, or
-- a nextest pin bump, in with-tillandsias-builder.sh reaches an ALREADY initialised
-- host. The real functions are cut out (the script execs on load) and run under
-- `set -euo pipefail` with stub toolbox and curl and a scratch HOME.
--   S1 FRESH    no stamp: podman and nix shims installed, stamped
--   S2 CURRENT  the same shim: toolbox is not called
--   S3 EDITED   a changed shim is installed again.  PRE-FIX: never.
--   S4 FAILED   an install that fails leaves no stamp, says so, and is retried
--   N1 ABSENT   installed at the pin, stamped;  N2 CURRENT: curl is not called
--   N3 BUMP     a new pin replaces the copy we installed.  PRE-FIX: never.
--   N4 BROKEN   a failed refresh keeps the working copy, says so, is not retried
--               at once;  N5 NEXT: yet another pin is tried at once
--   N6 FOREIGN  an unstamped copy of another version is left alone, and named
--   N7 ADOPT    an unstamped copy at the pin is adopted, without a download
--   N8 BADSHA   an asset that does not match the pin is never installed
--
-- Verdict: ok:builder-installs-follow-their-pins:<n> arms | violation:...:<n>-failed
--          | skip:builder-installs-follow-their-pins:linux-only:<uname>

local fixture = require "common.fixture"
local T = fixture.new("builder-installs-follow-their-pins")
local uname = text.trim(proc.run{ argv = { "uname", "-s" }, timeout_ms = 10000 }.stdout or "")
if uname ~= "Linux" then T:skip("linux-only:" .. uname) end
local BASH = fixture.posix_shell("/bin/bash")
local W = T:scratch()

local src = fs.read("scripts/with-tillandsias-builder.sh") or ""
local a = src:find("SHIM_STAMP=", 1, true)
local b = src:find("# ── Ensure toolbox exists and is initialized", 1, true)
if not (a and b and b > a) then T:refuse("functions-not-found", "the install helpers moved in with-tillandsias-builder.sh") end
local CUT = src:sub(a, b - 1)

fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/home"); fs.mkdir(W.rel .. "/installed"); fs.mkdir(W.rel .. "/assets")
fs.write(W.rel .. "/bin/toolbox", '#!/bin/bash\necho "toolbox $*" >> "$W/calls"\n[ ! -e "$W/toolbox-fails" ] || exit 1\n'
    .. 'src="${@: -2:1}"; dst="${@: -1}"\ncp "$src" "$W/installed/${dst##*/}"\n')
fs.write(W.rel .. "/bin/curl", '#!/bin/bash\necho "curl" >> "$W/calls"\n[ ! -e "$W/curl-fails" ] || exit 22\n'
    .. 'o=""; while [ $# -gt 0 ]; do [ "$1" != -o ] || o="$2"; shift; done\ncp "$W/assets/next.tgz" "$o"\n')
-- asset.sh <name> <version>: a tarball holding a cargo-nextest that answers it
fs.write(W.rel .. "/asset.sh", 'set -e; d="$W/mk-$1"; mkdir -p "$d"\n'
    .. 'printf \'#!/bin/bash\\necho "cargo-nextest %s (stub)"\\n\' "$2" > "$d/cargo-nextest"; chmod +x "$d/cargo-nextest"\n'
    .. 'tar -czf "$W/assets/$1.tgz" -C "$d" cargo-nextest\nsha256sum "$W/assets/$1.tgz"\n')
-- run.sh <fn>: the cut helpers under the script's own shell options
fs.write(W.rel .. "/run.sh", 'set -euo pipefail\nTOOLBOX_NAME=tb\n. "$W/cut.sh"\n"$1"\necho "rc=0"\n')
fs.write(W.rel .. "/put.sh", 'set -e; mkdir -p "$W/home/.cargo/bin"; cp "$W/mk-$1/cargo-nextest" "$W/home/.cargo/bin/cargo-nextest"\n')
fs.write(W.rel .. "/wipe.sh", 'rm -rf "$W/home"; mkdir -p "$W/home/.cache/tillandsias" "$W/home/.cargo/bin"\n')
T:must{ "chmod", "-R", "+x", W.abs .. "/bin" }
local E = { W = W.abs, HOME = W.abs .. "/home", PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin") }
local function sh(f, ...)
    local argv = { BASH, W.abs .. "/" .. f, ... }
    local r = proc.run{ argv = argv, env = E, timeout_ms = 60000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local function read(p) local good, s = pcall(fs.read, W.rel .. "/" .. p); return good and s or "" end
local function touch(p, on)
    if on then fs.write(W.rel .. "/" .. p, "1") else proc.run{ argv = { "rm", "-f", W.abs .. "/" .. p }, timeout_ms = 10000 } end
end
local function go(fn) fs.write(W.rel .. "/calls", ""); local o = sh("run.sh", fn); return o, read("calls") end
local function count(s, w) return select(2, s:gsub(w, "")) end

-- Shims
sh("wipe.sh")
fs.write(W.rel .. "/cut.sh", CUT)
local o, calls = go("_ensure_host_escape_shims")
local stamp1 = read("home/.cache/tillandsias/host-escape-shim.tb.stamp")
T:arm("S1 FRESH installs podman and nix, and stamps", count(calls, "toolbox run") == 2 and stamp1:find("^%x+\n$") ~= nil
    and read("installed/podman"):find("--host", 1, true) ~= nil and read("installed/nix") ~= "" and o:find("rc=0", 1, true) ~= nil, o .. calls)
o, calls = go("_ensure_host_escape_shims")
T:arm("S2 CURRENT does not call toolbox", calls == "" and o == "rc=0\n", o .. calls)
fs.write(W.rel .. "/cut.sh", (CUT:gsub("exec flatpak%-spawn %-%-host", "EDITED=1; exec flatpak-spawn --host", 1)))
touch("toolbox-fails", true)
o, calls = go("_ensure_host_escape_shims")
T:arm("S4 FAILED leaves the old stamp, says so, and does not abort the caller",
    read("home/.cache/tillandsias/host-escape-shim.tb.stamp") == stamp1 and o:find("could not be installed", 1, true) ~= nil and o:find("rc=0", 1, true) ~= nil, o)
touch("toolbox-fails", false)
o, calls = go("_ensure_host_escape_shims")
T:arm("S3 EDITED shim is installed again (and the failed run is retried)", count(calls, "toolbox run") == 2
    and read("installed/podman"):find("EDITED=1", 1, true) ~= nil and read("home/.cache/tillandsias/host-escape-shim.tb.stamp") ~= stamp1, o .. calls)

-- nextest: v1/v2/v3 assets; pin(name, version) rewrites the cut's pin to match.
local sha = {}
for n, v in pairs({ v1 = "0.1.0", v2 = "0.2.0", v3 = "0.3.0" }) do sha[n] = (sh("asset.sh", n, v)):match("^(%x+)") or "none" end
local function pin(n, v)
    local c = CUT:gsub("_nx_ver=[%d.]+", "_nx_ver=" .. v, 1)
    c = c:gsub("_nx_sha=%x+", "_nx_sha=" .. sha[n])
    fs.write(W.rel .. "/cut.sh", c)
    proc.run{ argv = { "cp", W.abs .. "/assets/" .. n .. ".tgz", W.abs .. "/assets/next.tgz" }, timeout_ms = 10000 }
end
local function bin() return read("home/.cargo/bin/cargo-nextest") end
sh("wipe.sh")
pin("v1", "0.1.0"); o, calls = go("_ensure_nextest")
T:arm("N1 ABSENT is installed at the pin", bin():find("0.1.0", 1, true) ~= nil and count(calls, "curl") == 1 and o:find("installed (sha256 verified)", 1, true) ~= nil, o)
o, calls = go("_ensure_nextest")
T:arm("N2 CURRENT is silent and does not call curl", calls == "" and o == "rc=0\n", o .. calls)
pin("v2", "0.2.0"); o, calls = go("_ensure_nextest")
T:arm("N3 BUMP replaces the copy we installed", bin():find("0.2.0", 1, true) ~= nil, o .. bin())
pin("v3", "0.3.0"); touch("curl-fails", true); o, calls = go("_ensure_nextest")
local again, calls2 = go("_ensure_nextest")
T:arm("N4 BROKEN refresh keeps the working copy, says so, and is not retried at once", bin():find("0.2.0", 1, true) ~= nil
    and o:find("already installed stays", 1, true) ~= nil and o:find("rc=0", 1, true) ~= nil and calls2 == "", o .. again .. calls2)
touch("curl-fails", false); pin("v1", "0.1.0"); o, calls = go("_ensure_nextest")
T:arm("N5 NEXT another pin is tried at once", bin():find("0.1.0", 1, true) ~= nil, o .. calls)
sh("wipe.sh"); sh("put.sh", "v3"); pin("v1", "0.1.0"); o, calls = go("_ensure_nextest")
T:arm("N6 FOREIGN is left alone and named", bin():find("0.3.0", 1, true) ~= nil and calls == "" and o:find("0.3.0", 1, true) ~= nil and o:find("left as it is", 1, true) ~= nil, o .. calls)
sh("wipe.sh"); sh("put.sh", "v1"); o, calls = go("_ensure_nextest")
T:arm("N7 ADOPT an unstamped copy at the pin", calls == "" and read("home/.cache/tillandsias/cargo-nextest.installed"):find(sha.v1, 1, true) ~= nil, o .. calls)
sh("wipe.sh"); pin("v1", "0.1.0")
proc.run{ argv = { "cp", W.abs .. "/assets/v2.tgz", W.abs .. "/assets/next.tgz" }, timeout_ms = 10000 }
o, calls = go("_ensure_nextest")
T:arm("N8 BADSHA is never installed", bin() == "" and o:find("refused", 1, true) ~= nil and o:find("rc=0", 1, true) ~= nil, o .. bin())

T:finish()
