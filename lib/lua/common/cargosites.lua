-- @trace order:1005-m6rz, order:876-irn7, order:2383-j7bp
--
-- common/cargosites.lua — THE ONE PLACE THE CARGO ASSUMPTION IS WRITTEN DOWN, and the resolver those
-- sites share. Moved here from scripts/lib-cargo-sites.sh (2383-j7bp), which no shell script sourced.
--
--   local cs = require "common.cargosites"
--   cs.SITES                 -- the registry, one repo path per entry
--   cs.resolve(runs)         -- "cargo", or an absolute path, or nil; runs(bin) says whether bin runs
--
--
-- Four scripts have independently assumed `cargo` is on the non-interactive
-- PATH. Each was found on the floor, one at a time, by a host where it was not:
--
--   scripts/cycle-preflight.sh          876-irn7. Declared cargo-absent on a host
--                                       carrying cargo 1.98.0, because rustup
--                                       writes its PATH edit into ~/.bashrc and
--                                       no agent tool call is a login shell.
--                                       CANONICAL: it carries the resolution loop
--                                       inline and is pinned by
--                                       test-cycle-preflight-cargo-resolution.lua.
--   scripts/lua/check-cheatsheet-tiers.lua 1005-m6rz. Printed a bare
--                                       `cargo: command not found` as a
--                                       validation ERROR on the commit hook.
--   scripts/host-capability-probe.sh    1005-m6rz. Refuses without a runnable
--                                       tillandsias binary, so a cargo-less host
--                                       cannot publish its capability row.
--   build.sh (gate)                     Refuses at the container boundary before
--                                       reaching a compiler at all; see the
--                                       toolbox note below.
--   scripts/check-host-tools.sh         1004-x9ua. THE FIFTH SITE, added here per
--                                       the instruction below rather than found on
--                                       a floor host. Reported
--                                       missing:host-tools:macos:timeout,cargo,rustc,pkg-config
--                                       on tlatoanis-macbook-air with all four
--                                       installed, and printed each one a remedy
--                                       to install what was already there.
--
-- ADD TO THIS LIST WHEN YOU FIND THE NEXT ONE. That is the whole point: the
-- packet's exit criterion is that the next site is added here rather than
-- discovered on a floor host mid-cycle, and a list nobody has to touch to add a
-- site is a list that goes stale. `M.SITES` below is read by the fixture,
-- so an entry that stops being true fails a test rather than misleading a reader.
--
-- WHY THIS IS A MODULE AND NOT A COMMENT BLOCK. A doc listing four scripts is
-- advisory; a shared resolver those scripts CALL is load-bearing. Requiring this
-- gets a site the same resolution cycle-preflight has, so "add the next site"
-- means "call resolve" rather than "copy nine lines and hope".
--
-- CHECK-HOST-TOOLS DELIBERATELY DOES NOT USE THIS EITHER, for a different
-- reason than cycle-preflight's, and the reason is worth stating because "why
-- didn't you just call the shared resolver" is the obvious review question.
--
-- It resolves TWO prefix families, not one. Its false positives were cargo and
-- rustc (~/.cargo/bin) AND timeout and pkg-config (/opt/homebrew/bin), so
-- the shared resolver closes half of them. More decisively, its fixture must be able to
-- CONSTRUCT the genuinely-absent case, and every prefix but the cargo ones is an
-- absolute path — a host that really has /opt/homebrew/bin cannot hide it. So
-- check-host-tools resolves through a list that its fixture can override
-- (TILLANDSIAS_HOST_TOOL_PREFIXES). The resolver reads $HOME directly and
-- ignores that seam, so sourcing it would make "a tool absent from PATH and every
-- prefix still fails" unprovable — the arm would pass because cargo is really
-- installed, not because the check works.
--
-- The registry entry above is the load-bearing part: the next reader looking for
-- "where does this assumption live" finds all five, which is what the criterion
-- asks for.
--
-- CYCLE-PREFLIGHT DELIBERATELY DOES NOT SOURCE THIS. Its loop is pinned by a
-- fixture that greps the shipped script for the literal loop
-- (test-cycle-preflight-cargo-resolution.lua), because 876-irn7's lesson was that
-- a test pinning a paraphrase pins nothing. Refactoring it to call this would
-- delete that pin to save nine lines. The duplication is the price of the pin
-- and is recorded here so it reads as a decision rather than an oversight.
--
-- A TOOLCHAIN IN A TOOLBOX IS NOT ON THE HOST. On a host whose gate re-execs
-- into a container (Silverblue, CachyOS with tillandsias-builder, Windows with
-- the WSL2 distro), a host-side `cargo` and the gate's `cargo` are different
-- programs, and a host-built binary may not even RUN in the container: measured
-- on pirria 2026-09-05, a host-built tillandsias-plan gave
-- `/lib64/libm.so.6: version 'GLIBC_2.44' not found` inside fedora-toolbox:42.
-- So resolving cargo here answers "can THIS process compile", never "is the gate
-- able to run".

local M = {}

-- ADD TO THIS LIST WHEN YOU FIND THE NEXT ONE (see above). test-cycle-preflight-cargo-resolution.lua
-- reads it, so an entry that stops being true fails a test rather than misleading a reader.
M.SITES = {
    "scripts/cycle-preflight.sh",
    "scripts/lua/check-cheatsheet-tiers.lua",
    "scripts/host-capability-probe.sh",
    "scripts/check-host-tools.sh",
    "build.sh",
}

-- On PATH, else $CARGO_HOME/bin, else $HOME/.cargo/bin. rustup writes its PATH edit into ~/.bashrc
-- and no agent tool call is a login shell (876-irn7). An unset CARGO_HOME is exactly "/bin", and an
-- unset HOME "/.cargo/bin": neither is probed, or some unrelated cargo there would pass.
function M.resolve(runs)
    if runs("cargo") then return "cargo" end
    for _, d in ipairs{ (env.get("CARGO_HOME") or "") .. "/bin", (env.get("HOME") or "") .. "/.cargo/bin" } do
        if d ~= "/bin" and d ~= "/.cargo/bin" and runs(d .. "/cargo") then return d .. "/cargo" end
    end
    return nil
end

return M
