# Tasks — windows-git-mirror-cred-isolation

## Phase 1: Daemon ownership exemption

- [x] Add system-wide safe.directory bootstrap in
      `ensure_git_service_running_wsl` (runs as root before daemon spawn,
      idempotent on re-run).
- [x] Manual smoke verification that `git ls-remote git://127.0.0.1:9418/<project>`
      returns refs from both `tillandsias-git` and `podman-machine-default`
      under mirrored networking.

## Phase 2: Host-side fetch credential isolation

- [x] In `ensure_mirror`, gate the existing-mirror fetch on
      `cfg(target_os = "windows")`:
  - Set `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=Never`.
  - Reset credential helpers via `-c credential.helper=`.
  - Append shell credential-helper that reads `TILLANDSIAS_FETCH_TOKEN`
    from env (token never on disk, never on cmdline).
  - Token sourced via `secrets::retrieve_github_token()`; missing token
    means no helper is appended and fetch may fail silently for private
    repos (acceptable — daemon-mediated push from forge handles writes).

## Phase 3: Smoke + audit

- [x] Full smoke: `tillandsias.exe <project> --opencode --diagnostics`
      attaches and reaches opencode startup without GUI credential
      prompt. Verified 2026-04-28 on `wsl-on-windows` with
      `C:\Users\bullo\src\visual-chess` — TUI rendered, project loaded
      at `~/src/visual-chess:main`.
- [x] `git config --system --get-all safe.directory` in tillandsias-git
      shows `*` after first daemon spawn (verified post-smoke).
- [x] Process audit during attach: `git-credential-manager.exe`
      processes spawned by Tillandsias MUST be zero (verified — no
      processes during attach).
- [ ] Process audit during attach: `tasklist /FI "IMAGENAME eq git.exe"`
      during fetch shows the env helper, no command-line token leak.
      (Deferred — fetch completes too fast to inspect mid-flight on
      the smoke test; will validate via static review of the env-helper
      string in handlers.rs.)

## Phase 4: Trace coverage

- [x] `@trace spec:windows-git-mirror-cred-isolation, spec:secrets-management`
      annotated in handlers.rs at both touch points.
- [ ] `@cheatsheet runtime/wsl-mount-points.md` cited at the
      safe.directory bootstrap (drvfs ownership rationale).
- [ ] `@cheatsheet runtime/secrets-management.md` cited at the host-side
      fetch wrapper (env-only credential pattern).
