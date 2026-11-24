-- @env PATH HOME
-- @trace order:317, order:2278-x4tw, spec:default-image
--
-- test-brew-shim-tier2-warning.lua — the brew shim's owned aarch64 Tier-2 policy
-- line (order 317, scope item 3), ported from the .sh of the same name
-- (2278-x4tw); same eight checks, same verdict words.
--
-- Homebrew on aarch64 Linux (every macOS-hosted guest) has no supported bottles,
-- so on-demand installs can degrade to slow source builds; the shim states that
-- in ONE line before attempting the install.
--
-- Behavioral (634-39ik): the shim RUNS under a shimmed uname with a fixture
-- allowlist and a stub brew prefix. The line must appear on the aarch64 install
-- path, must NOT appear on x86_64 (per-arch control), and must NOT appear on the
-- already-installed exec path (install-scope control). A mutant with the arch
-- test neutered loses it on aarch64 and changes nothing on x86_64.
--
-- Usage: tillandsias-plan script run scripts/lua/test-brew-shim-tier2-warning.lua
-- Verdict: ok:brew-shim-tier2-warning-fixture:8 | violation:...

local fixture = require "common.fixture"
local T = fixture.new("brew-shim-tier2-warning-fixture")
local SH = fixture.posix_shell()
local REL = "images/default/brew-shim-exec.sh"
local SHIM = fixture.repo_root() .. "/" .. REL
local S = T:scratch()
fs.mkdir(S.rel .. "/shims"); fs.mkdir(S.rel .. "/prefix/bin")
local function exe(p, body) fs.write(S.rel .. "/" .. p, body); T:must{ "chmod", "+x", S.abs .. "/" .. p } end
exe("shims/uname", '#!/bin/sh\ncase "${1:-}" in -s) echo Linux;; -m) echo "$UNAME_M";; *) echo Linux;; esac\n')
-- A brew that "succeeds" without a network; the shim then finds no tool and
-- exits 127, far enough to prove where the line is printed.
exe("prefix/bin/brew", "#!/bin/sh\nexit 0\n")
fs.write(S.rel .. "/allowlist.txt", "mytool mytool\n")

local function shim(arch, path)
    local r = proc.run{ argv = { SH, path or SHIM, "mytool", "mytool" }, timeout_ms = 60000,
        env = { PATH = S.abs .. "/shims:" .. env.get("PATH"), HOME = env.get("HOME"), UNAME_M = arch,
                TILLANDSIAS_BREW_PREFIX = S.abs .. "/prefix", TILLANDSIAS_BREW_ALLOWLIST = S.abs .. "/allowlist.txt",
                TILLANDSIAS_PROJECT_CACHE = S.abs .. "/cache" } }
    return r.stderr or ""
end
local has = text.contains

T:arm("1 the shim parses", T:run{ SH, "-n", SHIM }.code == 0, "bash -n refused it")
local o = shim("aarch64")
T:arm("2 the aarch64 install path states the policy", has(o, "Tier 2 (no bottles)"), o)
T:arm("3 the line cites its order", has(o, "order 317"), o)
o = shim("x86_64")
T:arm("4 CONTROL the x86_64 install path stays silent", not has(o, "Tier 2"), o)
exe("prefix/bin/mytool", "#!/bin/sh\necho ran\n")
o = shim("aarch64")
T:arm("5 CONTROL the aarch64 exec path stays silent", not has(o, "Tier 2"), o)
T:must{ "rm", "-f", S.abs .. "/prefix/bin/mytool" }
local mut, n = fs.read(REL):gsub('= "aarch64" %]', '= "NEVERMATCH" ]')
fs.write(S.rel .. "/mutant.sh", mut)
T:arm("6 MUTANT the arch test was found and neutered", n >= 1, "n=" .. n)
o = shim("aarch64", S.abs .. "/mutant.sh")
T:arm("7 MUTANT the neutered arch test loses the line on aarch64", not has(o, "Tier 2"), o)
o = shim("x86_64", S.abs .. "/mutant.sh")
T:arm("8 MUTANT x86_64 is unchanged", not has(o, "Tier 2"), o)
T:finish{ ok = function(p) return "ok:brew-shim-tier2-warning-fixture:" .. p end }
