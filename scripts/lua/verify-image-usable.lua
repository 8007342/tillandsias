-- @trace order:1073-dqtx, order:2006-me5t
-- @env-profile podman
-- @env TILLANDSIAS_PODMAN
-- @env TILLANDSIAS_PODMAN_ARGS
--
-- verify-image-usable.lua <image-tag> — an image EXISTS is not an image WORKS.
-- Ported from scripts/verify-image-usable.sh (2006-me5t, paid by 2026-ggu8):
-- same grammar, same stderr, same exit codes, on `tillandsias-plan script run`.
--
-- THE DEFECT. On tlatoanis-macbook-air 2026-09-05 a forge build produced three
-- independent green signals over an artifact that could not start:
--
--   scripts/build-image.sh forge      -> exit 0, 121s
--   podman image exists <tag>         -> exit 0
--   podman images                     -> the tag, 3.03 GB
--   podman inspect <tag>              -> EXIT 125, faccessat
--                                        .../overlay/1854a58890…: no such file
--   podman run <tag>                  -> same, container never started
--
-- REPRODUCED HERMETICALLY on yoga 2026-09-06 (isolated --root, `FROM scratch`
-- plus a COPY, then the image's own overlay directory removed through
-- `podman unshare`):
--
--   signal              intact   layer dir removed
--   image exists          0            0     <- fooled
--   images (size)       shows        shows   <- fooled
--   image tree            0            0     <- fooled
--   image inspect         0          125     <- CATCHES IT
--   run                   0          125     <- catches it, costs a container
--
-- `image inspect` is the cheapest signal that actually touches the layers.
-- `image tree` reads metadata and is fooled, though it LOOKS layer-aware.
--
-- ONE IMPLEMENTATION ON PURPOSE. build-image.sh and with-nix-builder.sh call
-- this, scripts/test-image-usability-check.sh tests it; any other caller that
-- needs a usability assertion calls it rather than re-deriving one (1081-gynk).
--
-- Environment: TILLANDSIAS_PODMAN (the podman to run, default `podman`) and
-- TILLANDSIAS_PODMAN_ARGS (extra args such as --root/--runroot for a hermetic
-- test store, whitespace-split, exactly as the shell version split them).
--
-- Grammar (one line on stdout):
--   ok:image-usable:<tag>                          exit 0
--   violation:image-not-usable:<tag>:inspect-rc=<n> exit 1
--   skip:image-usable:<reason>                     exit 0
--   usage on stderr                                exit 2

local tag = (arg or {})[1] or ""
if tag == "" then
    -- The one arm not byte-identical to the .sh: the runner requires a verdict
    -- line, so usage prints refused:image-usable:usage on stdout (the .sh
    -- printed nothing there). Same exit code; every caller passes a tag.
    log.raw("usage: verify-image-usable.lua <image-tag>")
    verdict.emit("refused:image-usable:usage", 2)
end

local podman = env.get("TILLANDSIAS_PODMAN") or ""
if podman == "" then podman = "podman" end

local argv = { podman }
for a in (env.get("TILLANDSIAS_PODMAN_ARGS") or ""):gmatch("%S+") do argv[#argv + 1] = a end
argv[#argv + 1] = "image"
argv[#argv + 1] = "inspect"
argv[#argv + 1] = tag

local r = proc.run({ argv = argv, timeout_ms = 120000 })

-- A host without podman cannot answer, and must not answer "clean"
-- (1024-c3h3). Skip with the reason named.
if r.status == "spawn_failed" then
    verdict.emit("skip:image-usable:no-podman-on-this-host", 0)
end

if r.status == "exited" and r.code == 0 then
    verdict.emit("ok:image-usable:" .. tag, 0)
end

-- Anything else is not usable: a non-zero exit, a signal or a timeout. A
-- timeout has no exit code; it is reported as 124, timeout(1)'s convention.
local rc = r.code
if rc == nil then rc = (r.status == "timed_out") and 124 or 1 end
log.raw("  The image EXISTS and cannot be inspected — it is not runnable.")
log.raw("  podman image inspect exit " .. rc .. ":")
for line in ((r.stderr or "") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then log.raw("    " .. line) end
end
log.raw("  'podman image exists', a size in 'podman images' and 'image tree'")
log.raw("  can all agree while a referenced overlay layer is missing from")
log.raw("  storage (1073-dqtx). They read metadata; only inspect and run")
log.raw("  touch the layers.")
log.raw("  REMEDY: rebuild without layer reuse —")
log.raw("    TILLANDSIAS_BUILD_NO_CACHE=1 scripts/build-image.sh <name> --force")
verdict.emit("violation:image-not-usable:" .. tag .. ":inspect-rc=" .. rc, 1)
