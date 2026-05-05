# Tasks for forge-opencode-methodology-overhaul

## 1. Create Sub-Files

- [x] 1.1 Create `images/default/config-overlay/opencode/instructions/forge-discovery.md` (150–200 lines)
- [x] 1.2 Create `images/default/config-overlay/opencode/instructions/cache-discipline.md` (150–200 lines)
- [x] 1.3 Create `images/default/config-overlay/opencode/instructions/nix-first.md` (150–200 lines)
- [x] 1.4 Create `images/default/config-overlay/opencode/instructions/openspec-workflow.md` (150–200 lines)

## 2. Rewrite Methodology Index

- [x] 2.1 Rewrite `images/default/config-overlay/opencode/instructions/methodology.md` as ~15-line index pointing to the 4 sub-files

## 3. Update Config

- [x] 3.1 Update `images/default/config-overlay/opencode/config.json` to list all 5 instruction files

## 4. Validate and Archive

- [x] 4.1 Run `openspec validate --change forge-opencode-methodology-overhaul --strict` and resolve all warnings/errors
- [x] 4.2 Archive the change with `openspec archive --change forge-opencode-methodology-overhaul`
