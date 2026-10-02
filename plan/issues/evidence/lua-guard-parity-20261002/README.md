# Independently executed guard parity

@trace order:1533-ew3n

These are actual retrospective comparisons of immutable Bash guards at
`8c7af3886` and the production Lua runner. They are **not** measurements taken
before deletion and do not substitute expected fixture values for executions.
Both variants read the same scratch input root and path spellings. No output
normalization was applied.

| Receipt | Candidate | Core byte parity | Supplemental result |
|---|---|---|---|
| `before-crlf-fix.json` | `5700c7c4` | 15/15 | Two CRLF diagnostic mismatches, plus spoof diagnostic difference |
| `after-crlf-fix.json` | `bc33176e` | 15/15 | Missing/unreadable, CRLF and space-path controls match; spoof diagnostic differs |
| `final-raw-parity.json` | `bc33176e` | 15/15 | 7/8 supplementary tuples match exactly, including both guest CRLF controls |

The remaining supplementary difference is intentional: both implementations
return exit 1 and `violation:tray-refresh-polling:1` for a spoofed signature
comment followed by real polling code. Bash reports that it cannot find the
function; repaired Lua identifies the real loop. The initial Lua candidate's
false-green result is separately retained under
`plan/issues/evidence/lua-guard-parent-review-20261002/` after integration.
No core fixture diagnostic contract changed.

Final receipt SHA-256:
`2c3d6f8ad058768de76e02fcbec2896ca9a89ca975362d258a57a75c685f4a0d`.
The JSON records binary/source/harness identities and both raw byte streams
(base64 plus readable text), statuses and input hashes. Version 1 reproduces
the first two receipts; version 2 adds guest CRLF controls. The source-data
`*.py.source.txt` files are non-executable archival data, not project harness
entrypoints. Reproduction materializes them only in external scratch; no
interpreter dependency or guard exception is introduced.

The earlier `1533-ew3n-retroactive-parity/raw.json` is a historical incomplete
placeholder, superseded by these executed receipts. It is not counted as
evidence of 15 comparisons. Native macOS/Windows runtime behavior, guard speed
and process counts are unmeasured; these are Linux static-source controls.

The later `absolute-root-symlink-before.json` control is a new blocker outside
those 23 cases: Bash follows a starting search-root symlink and refuses the
direct command; candidate `bc33176e` returns a false-green empty scan. The
candidate is not ready until the typed listing follows only the explicit
starting symlink and the regression is measured. The reproduced source data
is retained as `review-root-symlink.py.source.txt`.

## Starting-root fix independently verified

`4c21f133` adds typed `test -e` and `find -H` for an absolute starting path.
`absolute-root-symlink-after.json` proves that the exact output/status tuple
now matches Bash, including the space-bearing symlink diagnostic path.
The broken-start negative and existing fixture arms pass. `find -H` follows
only the explicit starting argument; it does not follow interior symlinks.

`root-link-fixed-parity.json` reruns the original 23 case pairs at that
candidate: 15/15 core tuples and 7/8 supplementary tuples match exactly;
the same intentional spoof-signature diagnostic difference remains.
Receipt SHA-256:
`406891051c546c4a62d99c880e4d9fda4601334e07f10fb8dba6d86cc5fb5eb0`.
Parent independently reran published fixtures: guest 3/3, tray 10/10,
Podman 11/11. Full integration gate and remote landing remain required.
