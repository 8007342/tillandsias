-- @trace order:1280-58kq, order:2111-inst
--
-- test-install-macos-announces-its-pin.lua — ORDER 1280-58kq. Ported from
-- scripts/test-install-macos-announces-its-pin.sh (2111-inst) onto the
-- scratch.* door, with the same seven checks. The harness and block are a
-- scratch FILE run by bash, where the shell passed them as a `bash -c` string.
--
-- install-macos.sh derives CHANNEL_BASE from $CHANNEL and then lets
-- TILLANDSIAS_RELEASE_BASE override it. The announcement did not follow: a
-- pinned install logged "channel: stable" / "resolving latest release", a path
-- it never took (measured on macneo, the v56.9.19.1 and .2 smokes). Both
-- installs were correct; only the lines lied (the 1260-2qgi family).
--
-- The fixture runs the installer's resolution block (cut by anchor, so it
-- cannot drift silently) with a stub say/die and the two variables it reads;
-- nothing else from the installer runs.
--   1 PINNED: names the pin; never "resolving latest release"; never "channel: stable"
--   2 UNPINNED (regression guard): today's two lines, and no "pinned"
--   3 MUTANT: with the pinned branch removed, arm 1's property reds
--
-- USAGE   tillandsias-plan script run scripts/lua/test-install-macos-announces-its-pin.lua
-- GRAMMAR ok:install-macos-announces-its-pin:7 (exit 0) | violation:...:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("install-macos-announces-its-pin")

local SRC_REL = "scripts/install-macos.sh"
if not fs.exists(SRC_REL) then verdict.could_not_run("install-macos-announces-its-pin", "no " .. SRC_REL) end

-- The block: from `    BASE="$RELEASE_BASE_LATEST"` up to (not including)
-- the first column-0 `fi` (the shell's awk range minus its last line).
local block, inside = {}, false
for _, l in ipairs(text.lines(fs.read(SRC_REL))) do
    if not inside and l == '    BASE="$RELEASE_BASE_LATEST"' then inside = true end
    if inside then
        if l == "fi" then break end
        block[#block + 1] = l
    end
end
if #block == 0 then
    verdict.could_not_run("install-macos-announces-its-pin", "anchor-not-found: install-macos.sh resolution block changed shape")
end

local PRELUDE = table.concat({
    "set -uo pipefail",
    'say() { printf "%s\\n" "$*"; }',
    'die() { printf "die: %s\\n" "$*"; exit 1; }',
    'REPO="8007342/tillandsias"',
    'CHANNEL="${CHANNEL:-stable}"',
    'case "$CHANNEL" in',
    '    stable)   CHANNEL_BASE="https://github.com/${REPO}/releases/latest/download" ;;',
    '    unstable) CHANNEL_BASE="https://github.com/${REPO}/releases/download/unstable" ;;',
    "esac",
    'RELEASE_BASE_LATEST="${TILLANDSIAS_RELEASE_BASE:-$CHANNEL_BASE}"',
}, "\n") .. "\n"

local w = T:scratch()
local n = 0
-- Runs PRELUDE + `body` (then a closing `fi`, as in the installer) under bash;
-- `pin` set means TILLANDSIAS_RELEASE_BASE is set, nil means it is UNSET.
local function run_block(body, pin)
    n = n + 1
    local f = w.leaf .. "/h" .. n .. ".sh"
    -- The runner's child env INHERITS the caller's TILLANDSIAS_* (measured: a
    -- caller's TILLANDSIAS_RELEASE_BASE reached the child and redded arm 2), so
    -- the harness itself unsets what this arm must not see, as the shell did.
    local unset = "unset CHANNEL" .. (pin and "" or " TILLANDSIAS_RELEASE_BASE") .. "\n"
    scratch.write(f, unset .. PRELUDE .. "if true; then\n" .. body .. "\nfi\n")
    local env = { PATH = "/usr/bin:/bin" }
    if pin then env.TILLANDSIAS_RELEASE_BASE = pin end
    local r = proc.run{ argv = { "bash", w.abs .. "/h" .. n .. ".sh" }, env = env, timeout_ms = 30000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local PIN = "https://example.invalid/releases/download/v9.9.9.9"
local B = table.concat(block, "\n")

-- ARM 1: pinned.
local o = run_block(B, PIN)
T:arm("ARM 1: a pinned base is announced as the pin, naming it", text.contains(o, "channel: pinned " .. PIN), o)
T:arm("ARM 1: does NOT claim 'resolving latest release' under a pin", not text.contains(o, "resolving latest release"), o)
T:arm("ARM 1: does NOT claim a channel it did not resolve", not text.contains(o, "channel: stable"), o)

-- ARM 2: unpinned, the regression guard.
o = run_block(B, nil)
T:arm("ARM 2 (regression guard): unpinned output is unchanged",
    text.contains(o, "channel: stable") and text.contains(o, "resolving latest release"), o)
T:arm("ARM 2: does not announce a pin when nothing is pinned", not text.contains(o, "pinned"), o)

-- ARM 3: MUTANT — the branch removed; arm 1's property must red.
local MUTANT = '    BASE="$RELEASE_BASE_LATEST"\n    say "channel: $CHANNEL"\n    say "resolving latest release"'
o = run_block(MUTANT, PIN)
T:arm("ARM 3 MUTANT: without the branch the pinned arm reproduces the defect",
    text.contains(o, "resolving latest release") and not text.contains(o, "pinned"), o)
T:arm("ARM 3 MUTANT: the mutant differs from the real block", MUTANT ~= B, "the cut block IS the mutant")

T:finish()
