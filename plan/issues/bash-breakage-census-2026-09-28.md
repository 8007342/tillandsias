# Shell-specific breakage census — 2026-09-28 (order 1459-mqvd)

Breakages whose root cause is shell as an implementation language, swept from
`plan/index.d`, `plan/archive`, `plan/issues` and `git log`. Statuses are from
`tillandsias-plan status` on 2026-09-28. **Guarded** means a blocking decider
that examines the live tree in the gate (inline in `build.sh`, or a
`scripts/gate-steps.d` fixture with a live-tree arm). Fixing one instance does
not count as guarding its class.

| # | Class | Instances | Open rows | Guard |
|---|---|---|---|---|
| 1 | SIGPIPE / pipefail / `if !` verdicts | 9 | none | **guarded**: `check-sigpipe-verdict-pipelines-added.sh` (build.sh), `check-no-spawn-in-if-not.sh` |
| 2 | Quoting / expansion / backticks | 7 (+3 in ledger args) | 1256-t3w8, 1215-8jui, 1117-66qv | **unguarded**; the structural fix is the argv door, 1443-8pur |
| 3 | bash-3.2 dialect | 9 | 964-zgga | **guarded**: `check-bash-dialect.sh` (build.sh), with rules added one incident at a time |
| 4 | BSD vs GNU tools | ~14 | 1353-ryhq, 1135-z8gn | **partial**: `check-portability-idioms.sh` warns by design (build.sh:3894); 1135-z8gn owns the 37 standing idioms |
| 5 | grep/sed over YAML/JSON | 10 | 1283-tpd5, 1287-myx8, 1238-u84w | **guarded**: jq ratchet (step 432, live arm 1), ledger readers (`litmus:no-unprotected-plan-ledger-readers`), order citations; quoted scalars are fixed by 1283-tpd5 |
| 6 | Exit status lost or misread | 11 | 1260-2qgi, 1256-cqsy, 923-ys2t | **partial**: only stderr of backgrounded jobs is guarded; the Lua port of these deciders is 1384-ddua |
| 7 | pkill / pgrep self-match | 4 | 1266-75tr, 1365-tjav | **guarded as of 1459-mqvd** for litmus steps: gate step 590, `tillandsias-litmus-rust litmus-self-match`; shell scripts are still advisory (`bash-hazards`) |
| 8 | Exec bits / CRLF | 8 | none | **guarded**: `check-script-exec-bits.sh`; CRLF via step 035 (live arm 7) |

Instances per class:

1. 702-pwhc 795-imz3 1069-c9w6 1070-a4gc 1084-nzqc 1075-yuxt 1293-wka4 1307-ermc 1339-had5
2. 1256-t3w8 1215-8jui 773-fx3u 627-wtrp 875-v7hv 1117-66qv, plus backticks executed inside double-quoted ledger arguments (three occurrences, lenovinha)
3. 196 761-g36m 805-pr3p 813-9n54 1373-sr9g 1374-4u6i 1413-8bee 1399-wtpq 964-zgga
4. 766-tdij 784-dwkh 803-bqte 812-64j7 841-ruh9 886-yizb 923-mp4w 1279-a7b6 1454-ssg3 1375-8g5t 1352-vmbc 1353-ryhq 1135-z8gn 1130-i6xj
5. 1283-tpd5 1287-myx8 1238-u84w 1303-2d5g 1370-tjme 870-fv7k 925-erjs 773-f5ma 1375-tsfu 914-ahsy
6. 1260-2qgi 1256-cqsy 923-ys2t 1175-wuwr 731-pc5r 316 256 643-bnag 1155-jurn 1018-5f5a 1354-dw8x
7. 1098-q7bk 943-3xyf 1266-75tr 1365-tjav
8. 731-d89b 770-dyqr 1116-vps5 889-8tcb 1321-2ixp 1049-s35z 1393-aa7v 752-8hqx

## What this says about the Lua question

- **Classes 1, 2, 3, 6 and 7 are properties of the shell itself:** pipeline
  exit status, string-assembled argv, dialect drift, `$?` and subshell scope,
  and argv-matching process tools. A language with argv vectors and typed
  results does not have them. That is 40 of the ~72 instances.
- **Class 5 does not disappear with a language change.** It needs a parser,
  and neither a bare shell host nor a bare Lua host has a YAML parser built
  in.
- **Classes 4 and 8 are platform differences** that any language meets at the
  process boundary.

## Remaining gaps

- **Class 2** has no decider; it is owned by 1443-8pur.
- **Class 6** has no decider; it is owned by 1384-ddua and 1260-2qgi.
- **Class 4** warns rather than blocks, by design; it is owned by 1135-z8gn.

A new row is needed only if one of those owners is dropped.
