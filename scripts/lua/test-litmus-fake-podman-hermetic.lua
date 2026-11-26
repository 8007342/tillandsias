-- @trace spec:litmus-framework, order:611-kqpf, order:797-p2xa, order:1096-p3tn, order:2399-lrg3
-- @env PATH HOME TMPDIR
--
-- test-litmus-fake-podman-hermetic.lua — safety fixtures for 611-kqpf: the DISPLAYED fake-mode
-- command (LITMUS_PODMAN_MODE=fake scripts/test-image-build-convergence.sh proxy, as
-- litmus:image-build-convergence-shape advertises it) is safe in a plain shell. Ported from
-- test-litmus-fake-podman-hermetic.sh (2399-lrg3); same six scenarios (seven checks: 3 splits rc from residue), in its order.
--
--   1  in real mode the guard (test-support/litmus-fake-podman-guard.sh) is a no-op
--   2  the displayed command, in a sanitized plain shell, passes and a real-podman SPY is at 0
--   3  an injected mid-fixture failure fails the fixture, leaves no residue a plain rm cannot
--      remove, and the spy is at 0
--   4  a runner-style shim (target/litmus-runtime/bin, exec podman-mock.sh) and the direct run
--      give the same verdict, and the spy is at 0
--   5  (797-p2xa) podman-mock fails CLOSED on an unknown subcommand, naming it
--   6  control for 5: a subcommand the mock implements still works
--
-- Hermetic: every PATH a child sees starts with the SPY, which records and fails if reached;
-- litmus shim dirs are stripped from it, and LITMUS_* / TILLANDSIAS_PODMAN_* / CONTAINER_HOST
-- are unset. The timing log is named into scratch (1096-p3tn).
--
-- GRAMMAR ok:litmus-fake-podman-hermetic:<n> arms | violation:litmus-fake-podman-hermetic:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-fake-podman-hermetic")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
local TLOG = W.abs .. "/timing-FIXTURES.jsonl"
local UNSET = { "LITMUS_*", "TILLANDSIAS_PODMAN_*", "CONTAINER_HOST", "TILLANDSIAS_TIMING_LOG" }

-- Sanitized PATH: what a plain shell would have (no litmus shim dirs).
local parts = {}
for d in ((env.get("PATH") or "") .. ":"):gmatch("([^:]*):") do
    if d ~= "" and not d:find("/target/litmus%-runtime/bin$") and not d:find("/litmus%-fake%-podman%-bin$") then
        parts[#parts + 1] = d
    end
end
local SANITIZED = table.concat(parts, ":")

-- The real-podman spy.
local SPY_DIR, SPY_LOG = W.abs .. "/spy-bin", W.abs .. "/spy-calls.log"
fs.mkdir(W.rel .. "/spy-bin")
fs.write(W.rel .. "/spy-calls.log", "")
fs.write(W.rel .. "/spy-bin/podman", table.concat({ "#!/usr/bin/env bash",
    [[{ printf 'REAL-PODMAN-REACHED:'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"]] .. SPY_LOG .. '"',
    'echo "SPY: real podman reached in fake mode" >&2', "exit 1", "" }, "\n"))
T:must{ "chmod", "755", W.abs .. "/spy-bin/podman" }
local function spy_calls() return fs.read(W.rel .. "/spy-calls.log") or "" end
local function spy_reset() fs.write(W.rel .. "/spy-calls.log", "") end

-- The displayed command, exactly, under a given PATH and extra env.
local function displayed(path, extra)
    local e = { PATH = path, TILLANDSIAS_TIMING_LOG = TLOG, LITMUS_PODMAN_MODE = "fake" }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ SH, "scripts/test-image-build-convergence.sh", "proxy", cwd = ROOT, stdin = "",
        env = e, env_unset = UNSET, timeout_ms = 120000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local CONVERGED = "ok: image build convergence sequence"
local function tail(s)
    local l, k = text.lines(s), {}
    for i = math.max(1, #l - 4), #l do k[#k + 1] = l[i] end
    return table.concat(k, " | ")
end

-- 1: real-mode no-op.
fs.write(W.rel .. "/guard.sh", table.concat({
    'before="$(command -v podman || true)"', '. "$1/scripts/test-support/litmus-fake-podman-guard.sh"',
    'after="$(command -v podman || true)"', '[ "$before" = "$after" ] && echo same || echo "changed $before -> $after"', "" }, "\n"))
local g = T:run{ SH, W.abs .. "/guard.sh", ROOT, cwd = ROOT, env_unset = UNSET, env = { TILLANDSIAS_TIMING_LOG = TLOG } }
T:arm("real-mode-guard-is-a-noop", text.trim(g.stdout or "") == "same", (g.stdout or "") .. (g.stderr or ""))

-- 2: displayed command hermetic in a plain shell, spy at zero.
local rc2, out2 = displayed(SPY_DIR .. ":" .. SANITIZED)
T:arm("displayed-command-hermetic-and-spy-zero", rc2 == 0 and text.contains(out2, CONVERGED) and spy_calls() == "",
    "rc=" .. tostring(rc2) .. " tail=" .. tail(out2) .. " spy=" .. spy_calls())

-- 3: injected failure leaves no residue. The residue scan is the .sh's: new entries of the
-- named shapes directly under TMPDIR, each of which must be removable by a plain rm.
spy_reset()
local marker = W.abs .. "/marker"
fs.write(W.rel .. "/residue.sh", table.concat({
    'bad=0',
    'while IFS= read -r entry; do',
    '  [ -e "$entry" ] || continue',
    '  case "$entry" in "$2"*) continue ;; esac',
    '  if rm -rf "$entry" 2>/dev/null; then echo "note: removed plain-rm-able leftover $entry"',
    '  else echo "RESIDUE: $entry"; bad=1; fi',
    [[done < <(find "${TMPDIR:-/tmp}" -mindepth 1 -maxdepth 1 -newer "$1" \( -name 'tmp.*' -o -name 'litmus-fake-podman*' -o -name 'containers*' -o -name 'podman*' \) 2>/dev/null)]],
    'exit $bad', "" }, "\n"))
fs.write(W.rel .. "/marker", "")
local rc3, out3 = displayed(SPY_DIR .. ":" .. SANITIZED, { LITMUS_FAKE_PODMAN_FAIL_ON = "build" })
local res = T:run{ SH, W.abs .. "/residue.sh", marker, W.abs, cwd = ROOT, env_unset = UNSET }
T:arm("injected-failure-fails-the-fixture", rc3 ~= 0, "rc=" .. tostring(rc3) .. " tail=" .. tail(out3))
T:arm("injected-failure-no-residue-and-spy-zero", res.code == 0 and spy_calls() == "",
    (res.stdout or "") .. " spy=" .. spy_calls())

-- 4: verdict parity, runner-style vs direct.
local RB = W.rel .. "/target/litmus-runtime/bin"
fs.mkdir(RB)
fs.write(RB .. "/podman", table.concat({ "#!/usr/bin/env bash", "set -euo pipefail",
    'calls_file="${LITMUS_PODMAN_CALLS_FILE:-' .. W.abs .. '/runner-calls.log}"',
    'mkdir -p "$(dirname "$calls_file")"',
    [[{ printf '%s\tpodman' "$(date -u +%FT%TZ)"; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$calls_file"]],
    'exec "' .. ROOT .. '/scripts/test-support/podman-mock.sh" "$@"', "" }, "\n"))
T:must{ "chmod", "755", W.abs .. "/target/litmus-runtime/bin/podman" }
spy_reset()
local rc4, out4 = displayed(W.abs .. "/target/litmus-runtime/bin:" .. SPY_DIR .. ":" .. SANITIZED)
T:arm("runner-and-direct-verdicts-agree",
    rc4 == 0 and text.contains(out4, CONVERGED) and text.contains(out2, CONVERGED) and spy_calls() == "",
    "runner rc=" .. tostring(rc4) .. " tail=" .. tail(out4) .. " spy=" .. spy_calls())

-- 5 and 6 (797-p2xa): the mock fails CLOSED, naming what it refused; and still handles what
-- it implements (the control for the control).
local m = T:run{ SH, "scripts/test-support/podman-mock.sh", "definitely-not-a-subcommand", "--weird", cwd = ROOT,
    env_unset = UNSET }
local mo = (m.stdout or "") .. (m.stderr or "")
T:arm("unrecognized-subcommand-refused-loudly", m.code ~= 0 and text.contains(mo, "definitely-not-a-subcommand"),
    "rc=" .. tostring(m.code) .. " out=" .. mo)
local kv = T:run{ SH, "scripts/test-support/podman-mock.sh", "version", cwd = ROOT, env_unset = UNSET }
T:arm("known-subcommand-still-handled", kv.code == 0, "rc=" .. tostring(kv.code))

T:finish()
