# Tasks: the installer asks a HARD reset's per-run question

## 1. Installer (1559-sqzp)

- [x] 1.1 `scripts/install-windows.ps1` decides the reset kind before any download (`BEGIN-RESET-KIND`), shows the reset's exact prompt at a console, forwards a typed `HARD` as `--approve-hard-reset`, never sets `TILLANDSIAS_HARD_RESET_APPROVED`, and runs the tray with stdin from NUL.
- [x] 1.2 `scripts/test-installer-reset-kind.sh` runs the real block over 9 arms, including that the block never assigns the variable; bound as gate step `770-1559-sqzp`.

## 2. Spec

- [ ] 2.1 Sync this delta into `openspec/specs/host-state-lifecycle/spec.md` when the change is archived.
