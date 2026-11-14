# preview.reload after the pinned app_dir was deleted (order 2065-pu7j)

Filed 2026-11-09 from the demon_attack forge session (demon-attack-3e,
Flutter + ComfyUI, several agents), relayed by macuahuitl-fedora.

## What happened

A preview was started with `app_dir` set to a Flutter `build/web`. Later a
clean deleted that directory. `preview.reload` then failed with
`invalid_app_dir: "build/web" is not a directory in the project`, and the
site returned 404.

## Why

`reload_inner` (crates/tillandsias-headless/src/local_web_preview.rs)
republishes the app_dir recorded in the preview's label (1667-6rtp, 1723-2fiq).
`live_app_dir` then refuses it because the directory no longer exists. The
message reads as if the caller had passed a bad argument to reload, which
takes no arguments.

## Fixed in this slice

`explain_reload_app_dir` adds what happened and the way out: reload
republishes the recorded app_dir, that directory is gone, so rebuild it or
call `preview.start` with the current app_dir. The `invalid_app_dir: ` prefix
is kept. Test: `a_reload_whose_recorded_app_dir_vanished_says_so`.

## Not done (left open on the row)

Falling back to the `assets.directory` in `wrangler.jsonc` when the recorded
dir is gone. That changes what gets published without the agent asking, so
it is a design choice. Proposed rule: fall back only for the `wrangler`
profile, only when the assets dir exists and passes `live_app_dir`, and say
so in the reply.
