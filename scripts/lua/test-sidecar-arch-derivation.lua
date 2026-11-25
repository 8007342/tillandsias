-- @trace order:723-ji4v, spec:ci-release, order:2340-psb5
-- @env PATH
--
-- test-sidecar-arch-derivation.lua — the router sidecar's per-arch build and its
-- guest-side guard (order 723-ji4v). Ported from test-sidecar-arch-derivation.sh
-- (2340-psb5); same seventeen checks.
--
-- What was broken, measured on the first Apple-Silicon host 2026-08-23:
-- build-sidecar.sh pinned TARGET=x86_64-unknown-linux-musl unconditionally, an x86-64
-- ELF was staged for an aarch64 guest, and images/router/entrypoint.sh respawned the
-- ENOEXEC binary once a second while Caddy 502'd.
--
--   1-2   both scripts parse
--   3-7   TARGET derivation (--print-target) under a shimmed uname: x86_64, arm64 and
--         aarch64 map to their musl triples, an unknown machine is a loud rc 2, and the
--         env override wins
--   8     the entrypoint's ELF e_machine guard is extracted by its begin/end markers
--   9-12  the guard on CRAFTED 20-byte headers: wrong arch refuses, right arch passes,
--         x86-64 passes on x86-64, an unknown guest machine degrades open
--   13-17 mutation controls: each mutant is checked to differ from its subject, the
--         neutered arm64 arm goes red on arm64 alone, the neutered comparison lets the
--         wrong-arch breach through
--
-- GRAMMAR ok:sidecar-arch-derivation:17 arms | violation:sidecar-arch-derivation:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("sidecar-arch-derivation")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local BUILD = "scripts/build-sidecar.sh"
local ENTRY = "images/router/entrypoint.sh"
local W = T:scratch()

local function parses(path)
    return proc.run{ argv = { SH, "-n", ROOT .. "/" .. path }, timeout_ms = 30000 }.code == 0
end
T:arm("1 build-sidecar.sh parses", parses(BUILD))
T:arm("2 entrypoint.sh parses", parses(ENTRY))

-- A uname shim: -m answers UNAME_M, anything else answers Linux.
fs.mkdir(W.rel .. "/shims")
fs.write(W.rel .. "/shims/uname", '#!/bin/sh\ncase "${1:-}" in -m) echo "${UNAME_M:-x86_64}";; *) echo "${UNAME_S:-Linux}";; esac\n')
T:must{ "chmod", "+x", W.abs .. "/shims/uname" }
local PATH = W.abs .. "/shims:" .. (env.get("PATH") or "/usr/bin:/bin")

local function derive(machine, script, extra)
    local e = { UNAME_M = machine, PATH = PATH }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, script or (ROOT .. "/" .. BUILD), "--print-target" }, env = e,
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    return text.trim(r.stdout or ""), r.code
end

local got, rc = derive("x86_64")
T:arm("3 an x86_64 machine derives the x86-64 musl triple", got == "x86_64-unknown-linux-musl", got)
got = derive("arm64")
T:arm("4 an arm64 machine derives the aarch64 musl triple", got == "aarch64-unknown-linux-musl", got)
got = derive("aarch64")
T:arm("5 an aarch64 machine derives the aarch64 musl triple", got == "aarch64-unknown-linux-musl", got)
got, rc = derive("riscv64")
T:arm("6 an unknown machine fails loud with rc 2", rc == 2, "rc=" .. tostring(rc) .. " out=" .. got)
got = derive("riscv64", nil, { TILLANDSIAS_SIDECAR_TARGET = "powerpc64le-unknown-linux-musl" })
T:arm("7 an explicit TILLANDSIAS_SIDECAR_TARGET wins", got == "powerpc64le-unknown-linux-musl", got)

-- The guard, cut from the entrypoint by its markers.
local entry = fs.read(ENTRY)
local s = entry:find("# --- 723-ji4v sidecar-executability guard begin ---", 1, true)
local _, e = entry:find("# --- 723-ji4v sidecar-executability guard end ---", 1, true)
local guard = (s and e) and entry:sub(s, e) .. "\n" or ""
T:arm("8 the guard is extracted and reads e_machine", text.contains(guard, "e_machine"), "markers not found")

-- 20 bytes: ELF magic, padding, then e_machine little-endian at bytes 18-19.
local function elf(machine)
    local p = W.rel .. "/bin-" .. machine
    fs.write(p, "\127ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000" .. string.char(machine) .. "\000")
    return W.abs .. "/bin-" .. machine
end
-- The guard names its binary absolutely; point that one line at the crafted file.
local function run_guard(machine, e_machine, body)
    local g = (body or guard):gsub("/usr/local/bin/tillandsias%-router%-sidecar", elf(e_machine))
    fs.write(W.rel .. "/guard-run.sh", "set -eu\n" .. g .. "echo GUARD_PASSED\n")
    local r = proc.run{ argv = { SH, W.abs .. "/guard-run.sh" }, env = { UNAME_M = machine, PATH = PATH }, timeout_ms = 30000 }
    return text.contains(r.stdout or "", "GUARD_PASSED")
end
T:arm("9 a wrong-arch (x86-64) sidecar is refused on aarch64", not run_guard("aarch64", 62))
T:arm("10 a right-arch (aarch64) sidecar passes on aarch64", run_guard("aarch64", 183))
T:arm("11 an x86-64 sidecar passes on x86_64", run_guard("x86_64", 62))
T:arm("12 an unknown guest machine degrades open", run_guard("riscv64", 62))

-- Mutation controls. Each mutant must DIFFER from its subject, or a red arm below
-- would be measuring an edit that never applied.
local build = fs.read(BUILD)
local mutant = build:gsub("arm64|aarch64%)", "NEVER-A|NEVER-B)")
T:arm("13 the derivation mutant applied", mutant ~= build)
fs.write(W.rel .. "/build-mutant.sh", mutant)
got, rc = derive("arm64", W.abs .. "/build-mutant.sh")
T:arm("14 CONTROL with the arm64 arm neutered, arm64 fails with rc 2", rc == 2, "rc=" .. tostring(rc) .. " out=" .. got)
got = derive("x86_64", W.abs .. "/build-mutant.sh")
T:arm("15 CONTROL the same mutant still derives x86-64", got == "x86_64-unknown-linux-musl", got)
local gmutant = guard:gsub('"%$e_machine" != "%$want_machine"', '"NEVER" = "MATCHES"')
T:arm("16 the guard mutant applied", gmutant ~= guard)
T:arm("17 CONTROL with the comparison neutered, the wrong-arch breach passes", run_guard("aarch64", 62, gmutant))

T:finish()
