# Tasks — litmus-parameterised-lua-deciders

- [x] 1.1 (1800-rutz) Write scripts/lua/test-litmus-decide.lua first: a fake cargo; arm 1 is the 1799-5kvy shape (a FAILED test must be NAMED, stdout non-empty)
- [x] 1.2 (1800-rutz) scripts/lua/litmus-decide.lua: LIB (args, affordances, transient-only retries, tree-state cache, tool-missing, empty-population) + families cargo-test and file-grep
- [x] 1.3 (1800-rutz) Convert envelope-citability step 20 to `cargo-test`; lower its floor line 16 → 15; the fixture runs in ./build.sh --check
- [x] 1.4 (1800-rutz) scripts/lua/census-litmus-pipes.lua prints piped= and per-family counts on every --check
- [x] 1.5 (1800-nvsc) methodology/convergence.yaml: the litmus-piped-commands backlog, advisory
- [ ] 2.1 (1800-93qs) file-grep: convert the 421 census members in batches, floor lines lowered per batch; findings for steps that turn red
- [ ] 3.1 (1800-juv4) script-output family + convert its 205
- [ ] 4.1 (1800-8uzh) structured-field family (json.query over a file or a producer) + convert its 88
- [ ] 5.1 (1800-s44f) podman-probe family (absent podman is could-not-run; retries on a locked store) + convert its 66
- [ ] 6.1 (1800-h7rt) remaining cargo-test (27) and cargo-other (37) on the shared cache
- [ ] 7.1 (1800-vq33) process, plan-query, git-query, text-transform families + their 105
- [ ] 8.1 (1800-f56m) check-carried-obligations.lua reads the census as the litmus-piped-commands counter (paid / waived / silent); check-shell-ratchet.lua warns by name when a diff edits a piped command: line and keeps the pipe
- [ ] 9.1 Sync deltas into openspec/specs once each slice's closure holds
