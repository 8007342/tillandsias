-- @trace spec:default-image, spec:inference-container, spec:browser-isolation-core, spec:browser-isolation-framework, spec:proxy-container, spec:git-mirror-service, spec:web-image, spec:subdomain-routing-via-reverse-proxy, order:2067-dwqd
--
-- check-container-bases.lua — enforce container base-image policy. Ported
-- from check-container-bases.sh (paid as 2067-dwqd's shell-to-lua carried
-- obligation).
--
-- The project intentionally mixes Fedora and Alpine:
--   - Fedora/glibc for agent, browser, inference, and SELinux-sensitive roles.
--   - Alpine/musl only for small appliance roles with narrow runtime behavior.
--
-- Same checks, same ERROR: lines, same exit codes as the .sh:
--   1 each listed Containerfile exists and has a FROM line
--   2 every FROM image is one of that file's allowed bases, and none is :latest
--   3 no mutable :latest tag in scripts/, images/, docs/cheatsheets/,
--     openspec/specs/ or the two Rust files that name images, outside the
--     fixtures that must name the freshest local build
-- THE DIFFERENCES: the summary line is a verdict (ok:container-base-policy:<n>
-- or violation:container-base-policy:errors=<e>:checked=<n>) where the .sh
-- printed "container-base-policy: ok (<n> Containerfile(s) checked)"; no
-- caller parses that line. Scan 3 uses `git grep --untracked`, so a file
-- ignored by .gitignore is not scanned (the .sh's grep -R read it).
--
-- Usage: tillandsias-plan script run scripts/lua/check-container-bases.lua

local errors, checked = 0, 0
local function fail(m) out.line("ERROR: " .. m); errors = errors + 1 end

local function expect_base(file, allowed)
    if not fs.exists(file) then fail(file .. " is missing"); return end
    local froms = {}
    for _, l in ipairs(text.lines(fs.read(file))) do
        if l:match("^%s*FROM%s+") then froms[#froms + 1] = l end
    end
    if #froms == 0 then fail(file .. " has no FROM line"); return end
    checked = checked + 1
    for _, l in ipairs(froms) do
        local image = l:match("^%s*FROM%s+(%S+)") or ""
        if image == "latest" or image:sub(-7) == ":latest" then
            fail(file .. " uses unpinned latest tag: " .. image)
        end
        local match = false
        for _, a in ipairs(allowed) do if image == a then match = true; break end end
        if not match then
            fail(file .. " uses '" .. image .. "'; expected one of: " .. table.concat(allowed, " "))
        end
    end
end

local FEDORA = "registry.fedoraproject.org/fedora-minimal:44"
expect_base("images/default/Containerfile", { FEDORA, "${BASE_IMAGE}" })
expect_base("images/default/Containerfile.base", { FEDORA })
expect_base("images/inference/Containerfile", { FEDORA })
expect_base("images/chromium/Containerfile.core", { FEDORA })
expect_base("images/chromium/Containerfile.framework", { "tillandsias-chromium-core:${CHROMIUM_CORE_TAG}", "${CHROMIUM_CORE_IMAGE}" })

-- order 782-9jfg: proxy alone moves to 3.22 for squid-6.12 (3.20 is frozen at
-- the 6.9 build behind 263 SIGSEGVs). The other Alpine images stay on 3.20
-- deliberately: this is a targeted change, not a fleet-wide base bump, and a
-- per-image pin is exactly what this gate exists to keep honest.
expect_base("images/proxy/Containerfile", { "docker.io/library/alpine:3.22" })
expect_base("images/git/Containerfile", { "docker.io/library/alpine:3.20", "docker.io/hashicorp/vault:1.18" })
expect_base("images/web/Containerfile", { "docker.io/library/alpine:3.20" })
expect_base("images/router/Containerfile", { "docker.io/library/caddy:2-alpine" })

-- test-running-image-freshness.sh is excluded: that fixture must name the
-- freshest local build. The three mirror-identity fixtures (749-54pv/2fqj/6uby)
-- are excluded for the same reason: each rebuilds and probes the CURRENT
-- local git image. Excluded by basename anywhere, as grep --exclude did.
local EXCLUDE = {
    "check-container-bases.sh", "check-container-bases.lua", "build-image.sh",
    "test-running-image-freshness.sh", "test-mirror-host-cert-and-sshd.sh",
    "test-mirror-receive-wrapper.sh", "test-mirror-sshd-posture.sh", "test-ssh-lane-sidecar.sh",
}
local argv = { "git", "grep", "--untracked", "-I", "-n", "-E",
    "tillandsias-[a-z0-9_-]+:latest|docker\\.io/library/[a-z0-9_-]+:latest|alpine:latest|nixos/nix:latest",
    "--", "scripts", "images", "docs/cheatsheets", "openspec/specs",
    "crates/tillandsias-core/src/container_profile.rs", "crates/tillandsias-podman/src/client.rs" }
for _, x in ipairs(EXCLUDE) do argv[#argv + 1] = ":(exclude,glob)**/" .. x end
local g = proc.run({ argv = argv, timeout_ms = 120000 })
-- git grep: 0 = hits, 1 = none; anything else is a scan that did not run,
-- never an empty (passing) answer.
if g.code ~= 0 and g.code ~= 1 then
    out.line("ERROR: the latest-tag scan did not run: git grep exited " .. tostring(g.code) .. " " .. text.trim(g.stderr or ""))
    verdict.emit("could-not-run:container-base-policy:scan", 2)
end
local hits = text.trim(g.stdout or "")
if hits ~= "" then
    fail("runtime/build docs or scripts contain mutable latest tags:")
    for _, h in ipairs(text.lines(hits)) do if h ~= "" then out.line("  " .. h) end end
end

if errors > 0 then
    out.line("container-base-policy: " .. errors .. " error(s), " .. checked .. " Containerfile(s) checked")
    verdict.emit("violation:container-base-policy:errors=" .. errors .. ":checked=" .. checked, 1)
end
verdict.emit("ok:container-base-policy:" .. checked, 0)
