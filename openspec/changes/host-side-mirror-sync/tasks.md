# Tasks — host-side-mirror-sync

## Phase 1: Mark current implementation as INTERIM

- [x] Acknowledge token-in-URL is a credential leak (this proposal)
- [ ] Add @tombstone marker on `embed_github_token_in_url` in handlers.rs
- [ ] Update `windows-wsl-runtime` spec to flag the gap and reference this change

## Phase 2: Implement host-side daemon

- [ ] Add `crates/tillandsias-mirror-sync/` workspace member
- [ ] Filesystem watcher via `notify` crate on `%LOCALAPPDATA%/tillandsias/mirrors/`
- [ ] Polling fallback (10s) for filesystems without inotify equivalent
- [ ] `sync_one(mirror_path) -> Result<SyncOutcome, SyncError>`:
  - Read token via `secrets::retrieve_github_token()`
  - Spawn `git.exe -C <mirror> push --mirror origin` with `GIT_ASKPASS` script
  - Token never touches disk; lives in tray RAM only
  - On success: remove marker, log accountability event
  - On failure: retain marker, log warning, send notification
- [ ] Wire daemon into tray startup (event_loop.rs)

## Phase 3: Refactor post-receive hook

- [ ] Strip `git push --mirror origin` from `images/git/post-receive-hook.sh`
- [ ] Hook only touches `<mirror>/.tillandsias-pending-sync` and echoes a
      "queued" message
- [ ] Apply to both Linux and Windows distro contexts

## Phase 4: Refactor mirror origin URL

- [ ] In `handlers.rs::ensure_mirror`, set origin to clean `https://github.com/...`
      (no token embedded)
- [ ] Remove `embed_github_token_in_url` and `redact_url_for_log` (tombstone)
- [ ] On every attach, ensure the URL is clean (token rotation case)

## Phase 5: Diagnostics + cheatsheet

- [ ] Add `[mirror-sync]` source to `src-tauri/src/diagnostics.rs`
- [ ] Write `cheatsheets/runtime/git-mirror-credential-flow.md` with
      diagram + provenance from Microsoft Credential Manager docs
- [ ] Update `cheatsheets/runtime/wsl-mount-points.md` cross-reference

## Phase 6: Smoke + audit

- [ ] Smoke test: forge git push → marker → sync → GitHub
- [ ] Audit: `grep -r 'oauth2:' /mnt/c/Users/bullo/AppData/Local/tillandsias/mirrors/`
      MUST return zero matches
- [ ] Check: agent in forge cannot grep the token from /mnt/c/...
