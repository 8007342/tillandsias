# Tasks — proc-detach (2294-dtch)

- [x] Red-first tests: crates/tillandsias-exec/tests/detach.rs fails to compile without `detach`; with `detach` accepted and ignored, the two "survives" tests and the refusal fail
- [x] `Command::detach` skips the exit reap on the direct and managed paths; the deadline and cancel still kill the group; the managed scope refuses detach without group
- [x] Lua `detach` field on proc.run / proc.spawn, validated; added to the invalid-spec table
- [x] Correct the `group()` doc comment
- [x] Migrate test-fleet-run arm 10 (real green, mutant red)
- [ ] After landing: switch PR #1471's vz-orphan port from the perl fork+setsid wrapper to `detach = true` (measured: it reds the outlive mutant without perl)
