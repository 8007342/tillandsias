# Tasks — OpenSpec CLI version pin (order 1441-myz3)

## 1. Record the pin
- [x] 1.1 `openspec/cli-version` = 1.13.2 (the version forges were already running, and the newest published)

## 2. Forge installs the pin
- [x] 2.1 `openspec_pin_marker` + `ensure_openspec_pinned` in `images/default/lib-common.sh`
- [x] 2.2 `ensure_forge_harnesses` skips the `@latest` openspec refresh while the pin marker exists
- [x] 2.3 the four forge entrypoints call `ensure_openspec_pinned "$PROJECT_DIR"` before `openspec_init_if_absent`

## 3. Coordinator moves it deliberately
- [x] 3.1 `scripts/openspec-pin.sh` with `pin`, `check`, `drift`, `install` and `bump`
- [x] 3.2 meta-orchestration "Mutable Linux Coordinator Duties" step 6

## 4. Prove it
- [x] 4.1 `scripts/test-openspec-pin.sh` (hermetic: stub npm and stub CLI; fails on the pre-fix tree)
- [x] 4.2 `litmus:openspec-cli-pin-shape`, bound to `meta-orchestration`
- [ ] 4.3 the re-levelling commit made BY the step (`bump --to 1.13.2`), after which `drift` is ok on the live tree
- [ ] 4.4 after landing and an image rebuild: a fresh forge launch runs openspec at the pin and `git status --porcelain` is empty at t=0 (host-side check)

## 5. Close
- [ ] 5.1 sync this delta into `openspec/specs/` and archive the change once 4.3 and 4.4 hold
