-- @trace order:1060-wxdh, order:2217-ab8h, order:2401-prg5
--
-- test-plan-binary-copy-refresh.lua — a plan binary that does not RUN must never
-- be installed over a canonical copy. Ported from test-plan-binary-copy-refresh.sh
-- (2401-prg5); same arms, in its order.
--
-- HOW THIS WAS FOUND: BY CAUSING IT, 2026-09-05. Proving the 1058-fenk locus-skew
-- detector meant running cycle-preflight with TILLANDSIAS_PLAN_BIN=<stub exiting
-- 127>; preflight's expert refresh then installed the stub over
-- ~/.local/bin/tillandsias-plan and the next `next-order` answered
-- `/lib64/libm.so.6: version GLIBC_2.44 not found`.
--
-- WHY THE FUNCTION AND NOT A PREFLIGHT RUN: redirecting HOME for a preflight run
-- also redirects the podman store, and with-tillandsias-builder.sh provisioned a
-- whole second builder toolbox inside the scratch dir. The decision lives in
-- refresh_plan_binary_copy (scripts/plan-binary-probe.sh), exercised here in
-- milliseconds on SCRATCH files only: no HOME redirect, no containers, no
-- network, and never the shared target/ binary or an installed copy.
-- Arms 5 and 8 pin that cycle-preflight refreshes only through that function.
--
-- TILLANDSIAS_* is unset for every child: inside a gate the caller exports its
-- frozen diff base, a sha the scratch repos lack, and the refresh then read every
-- scratch checkout as off-trunk (land run 32 evicted #1330 on the CONTROL arm).
--
-- GRAMMAR ok:plan-binary-copy-refresh:<n> arms | violation:plan-binary-copy-refresh:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("plan-binary-copy-refresh")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local UNSET = { "TILLANDSIAS_*" }

local W = T:scratch()
-- A "runnable" binary answers `capabilities` 0 — the evidence the probe itself uses.
fs.write(W.rel .. "/good", '#!/usr/bin/env bash\n[ "${1:-}" = "capabilities" ] && { echo fixture-capability; exit 0; }\nexit 0\n')
fs.write(W.rel .. "/stub", "#!/usr/bin/env bash\necho \"$0: /lib64/libm.so.6: version \\`GLIBC_2.44' not found\" >&2\nexit 127\n")
fs.write(W.rel .. "/refresh.sh", '. "$1/scripts/plan-binary-probe.sh"\nshift\nrefresh_plan_binary_copy "$@"\n')
T:must{ "chmod", "+x", W.abs .. "/good", W.abs .. "/stub" }
local GOOD, STUB = W.abs .. "/good", W.abs .. "/stub"
local DEST_REL, DEST = W.rel .. "/canonical", W.abs .. "/canonical"

local function refresh(src, root)
    local argv = { SH, W.abs .. "/refresh.sh", ROOT, src, DEST }
    if root then argv[#argv + 1] = root end
    argv.cwd, argv.env_unset = ROOT, UNSET
    return text.trim(T:run(argv).stdout or "")
end
local function dest() return fs.exists(DEST_REL) and fs.read(DEST_REL) or nil end
local function stale() fs.write(DEST_REL, "stale\n"); T:must{ "chmod", "0755", DEST } end

-- 1. THE INCIDENT: an unrunnable source must not overwrite.
fs.write(DEST_REL, fs.read(W.rel .. "/good")); T:must{ "chmod", "0755", DEST }
local before = dest()
local v = refresh(STUB)
T:arm("an unrunnable source leaves the canonical copy byte-identical", dest() == before, "copy now: " .. tostring(dest()))
T:arm("and it says so: refresh-refused-not-runnable", v == "refresh-refused-not-runnable", "got '" .. v .. "'")

-- 2. CONTROL: a runnable source still refreshes a STALE copy (else "never install" passes arm 1).
stale()
v = refresh(GOOD)
T:arm("CONTROL: a runnable source still refreshes a stale canonical copy",
    v == "refreshed" and dest() == fs.read(W.rel .. "/good"), "got '" .. v .. "'")

-- 3. An identical copy is reported current.
v = refresh(GOOD)
T:arm("an identical copy reports current", v == "current", "got '" .. v .. "'")

-- 4. An ABSENT destination is left absent.
T:must{ "rm", "-f", DEST }
v = refresh(GOOD)
T:arm("an absent canonical copy is not created", v == "absent" and not fs.exists(DEST_REL), "got '" .. v .. "'")

-- 5. cycle-preflight refreshes ONLY through the function (comments stripped).
local pf_lines = {}
for _, l in ipairs(text.lines(fs.read("scripts/cycle-preflight.sh") or "")) do
    local hash = l:find("#", 1, true)
    pf_lines[#pf_lines + 1] = hash and l:sub(1, hash - 1) or l
end
local pf = table.concat(pf_lines, "\n")
T:arm("cycle-preflight refreshes through the guarded function", text.contains(pf, "refresh_plan_binary_copy"), "no call")
local direct = false
for _, l in ipairs(pf_lines) do if l:find("install %-m0755 .*expert_bin") then direct = true end end
T:arm("cycle-preflight has no direct install over the expert copy", not direct, "a direct install bypasses the runnability check")

-- 6. ORDER 2217-ab8h: OFF TRUNK the copy is left alone, by name.
local R = T:git_repo("checkout")
T:must{ "git", "-C", R.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
T:must{ "git", "-C", R.abs, "commit", "-q", "--allow-empty", "-m", "a work-branch commit" }
stale()
before = dest()
v = refresh(GOOD, R.abs)
T:arm("OFF TRUNK: a work-branch build is not installed over the PATH copy, and the answer says why (2217-ab8h)",
    v == "refresh-skipped-off-trunk" and dest() == before, "got '" .. v .. "', copy " .. (dest() == before and "untouched" or "REPLACED"))

-- 7. CONTROL for 6: ON TRUNK the refresh still happens (799-m2vk).
T:must{ "git", "-C", R.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
v = refresh(GOOD, R.abs)
T:arm("CONTROL: with HEAD contained in the trunk ref the copy is still refreshed",
    v == "refreshed" and dest() == fs.read(W.rel .. "/good"), "got '" .. v .. "'")

-- 8. cycle-preflight hands the guard its checkout.
T:arm("cycle-preflight hands the guard its checkout",
    text.contains(pf, 'refresh_plan_binary_copy "$plan_bin" "$expert_bin" "$ROOT"'), "called without its checkout")

T:finish()
